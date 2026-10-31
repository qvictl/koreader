-- Real FileManager renames, ReaderUI bookmarks and filesystem failures; no I/O stubs.
return {
    name = "Sidecar migration retains annotations and custom files when destinations fail",
    timeout = 90,
    run = function(T)
        local DocSettings = require("docsettings")
        local ffiutil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local util = require("util")
        local base = os.getenv("KO_HOME") .. "/sidecar-migration"
        local original, renamed = base .. "/original.epub", base .. "/renamed.epub"
        local final = base .. "/final.epub"
        local old_setting = G_reader_settings:readSetting("document_metadata_folder")
        local owned_dirs = {}
        local function write(path, bytes)
            local file = assert(io.open(path, "wb"))
            assert(file:write(bytes))
            assert(file:close())
        end
        local function read(path) return util.readFromFile(path) end
        local function renameThroughDialog(path, name, target)
            local fm = T:fileManager()
            T:run(function() fm:showRenameFileDialog(path, true) end)
            local dialog = T:topWidget()
            T:check(dialog and dialog.setInputText, "real file rename input is shown")
            T:run(function() dialog:setInputText(name) end)
            T:repaint()
            local button = T:findWidget(dialog, function(widget)
                return widget.text == require("gettext")("Rename") and widget.callback
            end)
            T:check(button and button.dimen, "rename button is painted")
            T:tapWidget(button, "rename book")
            T:waitUntil(function() return lfs.attributes(target, "mode") == "file" end, 5, "book is renamed")
            T:eq(lfs.attributes(path), nil, "old book path no longer exists")
        end
        local ok, err = pcall(function()
            T:run(function()
                util.makePath(base)
                assert(not ffiutil.copyFile(T:fixture("books/en.epub"), original))
                G_reader_settings:saveSetting("document_metadata_folder", "doc")
            end)
            local ui = T:openBook(original)
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return ui:getCurrentPage() == 2 end, 5, "page two before rename")
            T:run(function()
                ui.bookmark:onToggleBookmark()
                ui.annotation.annotations[1].note = "Keep this migration note"
            end)
            T:closeBook()
            local source = DocSettings:getSidecarDir(original, "doc")
            local cover = assert(read("resources/koreader.png"))
            local custom = 'return { custom_props = { title = "Migration test title" } }'
            write(source .. "/cover.png", cover)
            write(source .. "/custom_metadata.lua", custom)
            local metadata = assert(read(source .. "/metadata.epub.lua"))
            local target = DocSettings:getSidecarDir(renamed, "dir")
            owned_dirs[#owned_dirs + 1] = target
            T:run(function()
                G_reader_settings:saveSetting("document_metadata_folder", "dir")
                util.makePath(target .. "/metadata.epub.lua")
            end)
            renameThroughDialog(original, "renamed.epub", renamed)
            T:check(read(source .. "/metadata.epub.lua") == metadata, "failed main save retains original annotations byte-for-byte")
            T:check(read(source .. "/cover.png") == cover, "failed main save retains original cover")
            T:eq(read(source .. "/custom_metadata.lua"), custom, "failed main save retains custom metadata")
            T:run(function()
                assert(lfs.rmdir(target .. "/metadata.epub.lua"))
                DocSettings.updateLocation(original, renamed)
            end)
            T:eq(lfs.attributes(source), nil, "successful explicit retry removes the old sidecar")
            T:eq(DocSettings:open(renamed):readSetting("annotations")[1].note, "Keep this migration note", "retry restores annotation in renamed sidecar")
            T:check(read(target .. "/cover.png") == cover, "retry copies the original cover")

            -- A later custom-file failure must not purge the source main sidecar either.
            local final_dir = DocSettings:getSidecarDir(final, "dir")
            owned_dirs[#owned_dirs + 1] = final_dir
            metadata = assert(read(target .. "/metadata.epub.lua"))
            T:run(function() util.makePath(final_dir .. "/custom_metadata.lua") end)
            renameThroughDialog(renamed, "final.epub", final)
            T:check(read(target .. "/metadata.epub.lua") == metadata, "failed custom copy retains source annotations")
            T:check(read(target .. "/cover.png") == cover, "failed custom copy retains source cover")
            T:eq(read(target .. "/custom_metadata.lua"), custom, "failed custom copy retains source custom metadata")
            T:run(function()
                assert(lfs.rmdir(final_dir .. "/custom_metadata.lua"))
                DocSettings.updateLocation(renamed, final)
            end)
            T:eq(lfs.attributes(target), nil, "custom-copy retry cleans only the old sidecar")

            -- Extension-only rename shares the .sdr directory: no self-copy or purge.
            local upper = base .. "/final.EPUB"
            renameThroughDialog(final, "final.EPUB", upper)
            T:check(read(final_dir .. "/cover.png") == cover, "shared-directory rename does not truncate the cover")
            T:eq(read(final_dir .. "/custom_metadata.lua"), custom, "shared-directory rename retains custom metadata")
            T:eq(DocSettings:open(upper):readSetting("annotations")[1].note, "Keep this migration note", "shared-directory rename retains annotations")
            renameThroughDialog(upper, "final.epub", final)
            ui = T:openBook(final)
            T:eq(ui:getCurrentPage(), 2, "renamed book reopens at its saved page")
            T:eq(ui.annotation.annotations[1].note, "Keep this migration note", "ReaderUI loads the retained bookmark note")
            T:eq(ui.doc_props.display_title, "Migration test title", "ReaderUI loads retained custom title")
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return ui:getCurrentPage() == 3 end, 5, "reading continues after migrations")
            T:closeBook()
        end)
        if T:reader() then T:closeBook() end
        G_reader_settings:saveSetting("document_metadata_folder", old_setting)
        for _, dir in ipairs(owned_dirs) do
            if lfs.attributes(dir) then ffiutil.purgeDir(dir) end
        end
        ffiutil.purgeDir(base)
        if not ok then error(err, 0) end
    end,
}
