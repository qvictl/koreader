-- Real SDL resize, cover extraction and painting; no layout or image mocks.
return {
    name = "Cover list remains usable in a narrow desktop window",
    timeout = 90,
    settings = { cover_image_enabled = false, cover_image_fallback = false },
    run = function(T)
        local BookInfoManager = require("bookinfomanager")
        local Device = require("device")
        local DocSettings = require("docsettings")
        local FileChooser = require("ui/widget/filechooser")
        local ReadCollection = require("readcollection")
        local SDL = require("ffi/SDL3")
        local UIManager = require("ui/uimanager")
        local ffiUtil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local util = require("util")
        -- Test-only binding for an existing SDL3 API, not a synthetic resize event.
        require("ffi").cdef[[bool SDL_SetWindowSize(SDL_Window *window, int w, int h);]]
        local setupMode = T:fileManager().coverbrowser.setupWidgetDisplayMode
        local saved = {
            width = Device.screen:getWidth(), height = Device.screen:getHeight(),
            coll = ReadCollection.coll, settings = ReadCollection.coll_settings,
            perpage = BookInfoManager:getSetting("files_per_page"),
            mode = BookInfoManager:getSetting("collection_display_mode"),
            chooser_perpage = rawget(FileChooser, "files_per_page"),
            instance_perpage = T:fileManager().file_chooser.files_per_page,
        }
        local base = os.getenv("KO_HOME") .. "/narrow-cover-list"
        local file = base .. "/synthetic.epub"
        local menu
        local function closeMenu()
            if menu and UIManager:isWidgetShown(menu) then
                T:run(function() menu.close_callback() end)
            end
            menu = nil
        end
        local function resize(w, h)
            closeMenu()
            T:run(function() assert(SDL.SDL.SDL_SetWindowSize(SDL.screen, w, h)) end)
            T:waitUntil(function()
                return Device.screen:getWidth() == w and Device.screen:getHeight() == h
                    and T:fileManager() and T:fileManager().dimen.w == w
            end, 5, "native window resize reaches the framebuffer and file manager")
            T:repaint()
        end
        local function showCollection()
            T:run(function()
                T:fileManager().collections:onShowColl("favorites")
                menu = T:fileManager().collections.booklist_menu
            end)
            T:repaint()
        end
        local function cachedRow()
            T:run(function() menu:updateItems() end)
            T:repaint()
            local row = T:findWidget(menu, function(w)
                return w.filepath == file and w.bookinfo_found and w._underline_container
            end)
            T:check(row, "the real cached row is painted")
            return row
        end
        local ok, err = pcall(function()
            T:waitUntil(function() return not BookInfoManager:isExtractingInBackground() end, 15, "startup extraction finishes")
            assert(not lfs.attributes(base), "private fixture directory must be new")
            assert(util.makePath(base))
            assert(not ffiUtil.copyFile(T:fixture("books/en.epub"), file))
            local sidecar = DocSettings:getSidecarDir(file, "doc")
            assert(util.makePath(sidecar))
            assert(not ffiUtil.copyFile("resources/koreader.png", sidecar .. "/cover.png"))
            T:run(function()
                -- Mirror the normal item-count settings callback, including its class default.
                FileChooser.files_per_page = 4
                T:fileManager().file_chooser.files_per_page = 4
                BookInfoManager:saveSetting("files_per_page", 4)
                setupMode("collections", "list_image_meta")
                ReadCollection.coll = { favorites = {} }
                ReadCollection.coll_settings = util.tableDeepCopy(saved.settings)
                ReadCollection:addItem(file, "favorites", lfs.attributes(file))
            end)
            resize(228, 816)
            T:eq({ Device.screen:getWidth(), Device.screen:getHeight() }, { 228, 816 }, "upstream narrow-window dimensions")
            showCollection()
            T:waitUntil(function() return BookInfoManager:getBookInfo(file) ~= nil end, 30, "native child extracts the private EPUB and custom cover")
            local info = BookInfoManager:getBookInfo(file)
            T:eq(info.has_meta, "Y", "native EPUB metadata is cached")
            T:check(info.has_cover, "the native PNG cover is cached")
            cachedRow()
            T:eq(menu.perpage, 4, "the valid four-row preference is retained")
            -- Fonts cache their startup scale; also exercise a taller narrow window
            -- to ensure a nonpositive column budget at the default high-DPI startup.
            closeMenu()
            resize(228, 1200)
            showCollection()
            local row = cachedRow()
            T:eq(row._show_cover_image, false, "nonpositive text budget falls back without the cover")
            T:check(row.do_cover_image, "the cover preference was not disabled")
            local title = T:findWidget(row, function(w)
                return w.text and w.text:find("Integration Test Book", 1, true) and w.width
            end)
            T:check(title and title.width > row.width / 2, "title retains readable width rather than a one-pixel clamp")
            T:run(function() Device.screen.bb:writePNG(base .. "/narrow.png") end)
            closeMenu()
            T:check(T:topWidget() == T:fileManager(), "narrow menu closes normally")
            T:waitUntil(function() return not BookInfoManager:isExtractingInBackground() end, 15, "cover worker is reaped before widening")

            resize(800, 1200)
            showCollection()
            row = cachedRow()
            T:check(row._show_cover_image and row._has_cover_image, "widening restores the real image column")
            T:check(row.do_cover_image, "normal image preference survives the fallback")
            T:run(function() Device.screen.bb:writePNG(base .. "/wide.png") end)
            T:eq(BookInfoManager:getSetting("files_per_page"), 4, "row count is unchanged by resizing")
            closeMenu()
            resize(228, 1200)
            showCollection()
            row = cachedRow()
            T:eq(row._show_cover_image, false, "repeated narrowing remains safe with the cached cover")
            closeMenu()
            resize(saved.width, saved.height)
            local ui = T:openBook(file)
            local page = ui:getCurrentPage()
            T:tap(math.floor(Device.screen:getWidth() * 0.9), math.floor(Device.screen:getHeight() * 0.5))
            T:waitUntil(function() return ui:getCurrentPage() == page + 1 end, 5, "page turn after resizing the cover list")
            T:eq(ui:getCurrentPage(), page + 1, "native reader remains responsive")
            T:closeBook()
            ui = T:openBook(file)
            T:eq(ui:getCurrentPage(), page + 1, "normal reopening retains reading position")
            T:closeBook()
        end)
        -- Keep private inputs until process teardown, even if worker cleanup fails.
        -- Restore independent state despite failures in closing a widget or worker.
        local errors = {}
        local function record(label, success, failure)
            if not success then errors[#errors + 1] = label .. tostring(type(failure) == "table" and failure.msg or failure) end
        end
        record("scenario: ", ok, err)
        record("widgets: ", pcall(function() closeMenu(); T:closeBook() end))
        record("workers: ", pcall(function()
            T:run(function() BookInfoManager:terminateBackgroundJobs() end)
            T:waitUntil(function() return not BookInfoManager:isExtractingInBackground() end, 15, "cleanup worker reaping")
        end))
        ReadCollection.coll, ReadCollection.coll_settings = saved.coll, saved.settings
        FileChooser.files_per_page = saved.chooser_perpage
        if T:fileManager() then T:fileManager().file_chooser.files_per_page = saved.instance_perpage end
        record("row preference: ", pcall(function()
            BookInfoManager:saveSetting("files_per_page", saved.perpage)
        end))
        record("display preference: ", pcall(function() setupMode("collections", saved.mode) end))
        record("window: ", pcall(function() resize(saved.width, saved.height) end))
        if #errors > 0 then error(table.concat(errors, "\n")) end
    end,
}
