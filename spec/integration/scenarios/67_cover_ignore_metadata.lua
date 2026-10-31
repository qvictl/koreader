-- Native EPUB/PNG extraction, SQLite cache and actual file/metadata dialogs.
return {
    name = "Custom text metadata preserves independent cover preferences",
    timeout = 90,
    settings = { language = "en", vk_enabled = false, document_metadata_folder = "doc",
        cover_image_enabled = false, cover_image_fallback = false },
    run = function(T)
        local BookInfoManager = require("bookinfomanager")
        local Device = require("device")
        local DocSettings = require("docsettings")
        local UIManager = require("ui/uimanager")
        local ffiUtil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local util = require("util")
        local fm = T:fileManager()
        local saved = { path = fm.file_chooser.path,
            mode = BookInfoManager:getSetting("filemanager_display_mode"),
            double_tap = rawget(Device.input, "disable_double_tap"),
            concurrent_taps = rawget(Device.input, "allow_concurrent_taps") }
        local base = os.getenv("KO_HOME") .. "/cover-ignore-metadata"
        local file = base .. "/preference-book.epub"
        local info, props, owns_root
        local function tapText(root, text)
            T:repaint()
            local button = T:findWidget(root, function(w) return w.text == text and w.callback end)
            T:check(button, "real button is painted: " .. text)
            T:tapWidget(button, text)
        end
        local function cacheIdentity()
            return table.pack(BookInfoManager.db_conn:rowexec([[SELECT bcid,hex(cover_bb_data),
                cover_w,cover_h,cover_sizetag,filesize,filemtime FROM bookinfo WHERE directory=']]
                .. base:gsub("'", "''") .. [[/' AND filename='preference-book.epub';]]))
        end
        local function sameIdentity(expected, message)
            local actual = cacheIdentity()
            local same = actual.n == expected.n
            for i = 1, expected.n do same = same and actual[i] == expected[i] end
            T:check(same, message) -- Do not embed native cover bytes in the JSON report.
        end
        local function row()
            T:run(function() fm.file_chooser:updateItems() end)
            T:repaint()
            local item = T:findWidget(fm.file_chooser, function(w)
                return w.filepath == file and w.bookinfo_found and w._underline_container
            end)
            T:check(item, "the actual cached file row is painted")
            return item
        end
        local function checkFlags(cover, metadata)
            local cached = assert(BookInfoManager:getBookInfo(file))
            T:eq(cached.ignore_cover, cover and "Y" or nil, "ignore-cover choice remains independent")
            T:eq(cached.ignore_meta, metadata and "Y" or nil, "ignore-metadata choice remains independent")
            local item = row()
            T:eq(not not item._has_cover_image, not cover, "painted row respects the cover choice")
            local expected = metadata and "preference-book" or cached.title
            T:check(T:findWidget(item, function(w)
                return w.text and w.text:find(expected, 1, true)
            end), "painted row respects the metadata choice")
        end
        local function toggle(label)
            T:run(function() fm.file_chooser:onFileHold{ path = file, is_file = true } end)
            tapText(fm.file_chooser.file_dialog, label)
            T:check(T:topWidget() == fm, "ignore preference closes its real file dialog")
        end
        local function showInfo()
            info = fm.bookinfo
            props = info:getDocProps(file)
            T:run(function() fm.file_chooser:onFileHold{ path = file, is_file = true } end)
            tapText(fm.file_chooser.file_dialog, "Book information")
            T:repaint()
            T:check(UIManager:isWidgetShown(info.kvp_widget), "real book information page opens")
        end
        local function closeInfo()
            if info and UIManager:isWidgetShown(info.kvp_widget) then
                T:run(function() info.kvp_widget:onClose() end)
            end
        end
        local function edit(key, text, save)
            T:run(function() info:showCustomDialog(file, props, key) end)
            tapText(T:topWidget(), "Set custom")
            local dialog = T:topWidget()
            T:check(dialog._input_widget, "real metadata input dialog opens")
            T:run(function() dialog:setInputText(text) end)
            tapText(dialog, save and "Save" or "Cancel")
            T:check(not UIManager:isWidgetShown(dialog), "metadata input dialog closes")
        end
        local ok, err = pcall(function()
            T:waitUntil(function() return not BookInfoManager:isExtractingInBackground() end, 15, "startup extraction finishes")
            assert(not lfs.attributes(base), "private fixture directory must be new")
            assert(util.makePath(base)); owns_root = true
            assert(not ffiUtil.copyFile(T:fixture("books/en.epub"), file))
            local sidecar = DocSettings:getSidecarDir(file, "doc")
            assert(util.makePath(sidecar))
            assert(not ffiUtil.copyFile("resources/koreader.png", sidecar .. "/cover.png"))
            T:run(function()
                fm.coverbrowser:setupFileManagerDisplayMode("list_image_meta")
                fm.file_chooser:changeToPath(base)
            end)
            T:repaint()
            T:waitUntil(function() return BookInfoManager:getBookInfo(file) ~= nil end, 30, "native child extracts private EPUB and cover")
            T:waitUntil(function() return not BookInfoManager:isExtractingInBackground() end, 15, "native extraction is reaped before editing")
            local cached = BookInfoManager:getBookInfo(file)
            T:eq(cached.title, "Integration Test Book", "native EPUB metadata is cached")
            T:check(cached.has_cover, "native PNG cover is cached")
            local before = cacheIdentity()
            T:check(before[1] and #before[2] > 0, "native cache identity includes real cover bytes")
            checkFlags(false, false)
            toggle("Ignore cover"); toggle("Ignore metadata")
            checkFlags(true, true)
            showInfo()
            edit("title", "Cancelled title", false)
            T:eq(BookInfoManager:getBookInfo(file).title, "Integration Test Book", "Cancel does not edit cached title")
            T:eq(DocSettings:findCustomMetadataFile(file), nil, "Cancel creates no custom metadata file")
            local started = T:now()
            edit("title", "Private custom title", true)
            T:budget("metadata_edit_ms", T:now() - started, 5000, "ms")
            edit("authors", "Private custom author", true)
            closeInfo()
            cached = BookInfoManager:getBookInfo(file)
            T:eq(cached.title, "Private custom title", "Save updates cached title immediately")
            T:eq(cached.authors, "Private custom author", "Save updates cached author immediately")
            sameIdentity(before, "text edits retain row identity and exact native cover bytes")
            checkFlags(true, true)
            BookInfoManager:closeDbConnection()
            BookInfoManager:openDbConnection()
            sameIdentity(before, "unchanged cover persists across database reopen")
            checkFlags(true, true)
            showInfo()
            T:eq(props.title, "Private custom title", "reopened metadata page reads saved custom title")
            T:run(function() info:showCustomDialog(file, props, "title") end)
            tapText(T:topWidget(), "Reset custom")
            tapText(T:topWidget(), "Cancel")
            T:eq(BookInfoManager:getBookInfo(file).title, "Private custom title", "Cancel reset preserves custom title")
            tapText(T:topWidget(), "Reset custom")
            tapText(T:topWidget(), "Reset")
            closeInfo()
            T:eq(BookInfoManager:getBookInfo(file).title, "Integration Test Book", "Reset restores original native title")
            sameIdentity(before, "Reset text metadata retains native cover bytes")
            checkFlags(true, true)
            toggle("Unignore cover"); toggle("Unignore metadata")
            checkFlags(false, false)
            showInfo(); edit("title", "Second custom title", true); closeInfo()
            checkFlags(false, false)
            sameIdentity(before, "repeated edits preserve the same cache row")
            T:check(DocSettings:findCustomCoverFile(file), "text edits never remove the custom cover file")
            T:run(function() Device.screen.bb:writePNG(base .. "/unignored.png") end)
            local ui = T:openBook(file)
            local page = ui:getCurrentPage()
            T:tap(math.floor(Device.screen:getWidth() * 0.9), math.floor(Device.screen:getHeight() * 0.5))
            T:waitUntil(function() return ui:getCurrentPage() == page + 1 end, 5, "native EPUB remains readable after metadata edits")
            T:closeBook()
            ui = T:openBook(file)
            T:eq(ui:getCurrentPage(), page + 1, "reopening retains actual reading position")
            T:eq(ui.doc_props.title, "Second custom title", "reader loads the saved custom title")
            T:closeBook()
        end)
        local errors = {}
        local function record(label, success, failure)
            if not success then errors[#errors + 1] = label .. tostring(type(failure) == "table" and failure.msg or failure) end
        end
        record("scenario: ", ok, err)
        record("widgets: ", pcall(function()
            closeInfo(); T:closeBook()
            T:run(function()
                while T:topWidget() and T:topWidget() ~= T:fileManager() do UIManager:close(T:topWidget()) end
            end)
        end))
        record("workers: ", pcall(function()
            T:run(function() BookInfoManager:terminateBackgroundJobs() end)
            T:waitUntil(function() return not BookInfoManager:isExtractingInBackground() end, 15, "cleanup reaps native workers")
        end))
        record("file manager: ", pcall(function()
            T:run(function()
                fm = T:fileManager()
                fm.coverbrowser:setupFileManagerDisplayMode(saved.mode)
                fm.file_chooser:changeToPath(saved.path)
            end)
        end))
        Device.input.disable_double_tap = saved.double_tap
        Device.input.allow_concurrent_taps = saved.concurrent_taps
        -- Retain owned inputs/artifacts until process teardown, including on worker errors.
        if owns_root then T:check(lfs.attributes(file), "private input remains available through cleanup") end
        if #errors > 0 then error(table.concat(errors, "\n")) end
    end,
}
