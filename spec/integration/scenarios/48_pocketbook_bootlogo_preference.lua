-- luacheck: ignore 122 -- restored synthetic os.execute boundary
-- Real ReaderUI, native image decode/write and cover plugin lifecycle hooks.
-- Only PocketBook capability/SDK and device command execution are synthetic.
return {
    name = "PocketBook cover export respects the firmware boot-logo preference",
    timeout = 60,
    settings = { cover_image_enabled = false, cover_image_fallback = false },
    run = function(T)
        local Device = require("device")
        local DocSettings = require("docsettings")
        local ffi = require("ffi")
        local ffiUtil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local util = require("util")
        local base = os.getenv("KO_HOME") .. "/pocketbook-bootlogo"
        local book = base .. "/synthetic.epub"
        local output = base .. "/exported cover.bmp"
        local saved = { pocketbook = Device.isPocketBook, execute = os.execute,
            inkview = package.loaded["ffi/inkview"], metadata = G_reader_settings:readSetting("document_metadata_folder") }
        local preference, read_failure, reads, commands = "@default_boot_logo", false, 0, {}
        local config, plugin = {}, nil
        assert(not lfs.attributes(base), "private fixture directory must be new")
        local function export(hook)
            T:run(function()
                -- Scope the capability override to this plugin hook, not other device operations.
                Device.isPocketBook = function() return true end
                local ok, err = pcall(hook)
                Device.isPocketBook = saved.pocketbook
                if not ok then error(err, 0) end
            end)
        end
        local function checkExport()
            local bytes = assert(util.readFromFile(output))
            T:check(#bytes > 100 and bytes:sub(1, 2) == "BM", "native cover export writes a real BMP")
        end
        local ok, err = pcall(function()
            T:run(function()
                util.makePath(base .. "/cache")
                assert(not ffiUtil.copyFile(T:fixture("books/en.epub"), book))
                local sidecar = DocSettings:getSidecarDir(book, "doc")
                util.makePath(sidecar)
                assert(not ffiUtil.copyFile("resources/koreader.png", sidecar .. "/cover.png"))
                G_reader_settings:saveSetting("document_metadata_folder", "doc")
                package.loaded["ffi/inkview"] = {
                    GetGlobalConfig = function() return config end,
                    ReadString = function(actual, key, default)
                        assert(actual == config and key == "bootlogo" and default == "@default_boot_logo")
                        reads = reads + 1
                        if read_failure then error("synthetic missing SDK symbol") end
                        return ffi.new("char[?]", #preference + 1, preference)
                    end,
                }
                os.execute = function(command)
                    assert(command == "sync" or command:find("^iv2sh WriteStartupLogo "), "unexpected host command")
                    commands[#commands + 1] = command -- never execute anything
                    return 0
                end
            end)
            local ui = T:openBook(book)
            plugin = assert(ui.coverimage, "real cover-image plugin is attached to ReaderUI")
            T:run(function()
                plugin.cover = true
                plugin.cover_image_path = output
                plugin.cover_image_cache_path = base .. "/cache/"
                plugin.cover_image_background = "none"
                plugin.cover_image_format = "bmp"
                plugin.fallback = false
            end)
            export(function() plugin:onReaderReady(ui.doc_settings) end)
            checkExport()
            T:eq(#commands, 0, "default firmware logo is not replaced when a cover is exported")
            T:eq(reads, 1, "reader-ready export reads the current firmware preference")

            preference = "@cover_logo"
            export(function() plugin:onSetRotationMode(Device.screen:getRotationMode()) end)
            checkExport()
            T:eq(reads, 2, "cached rotation export re-reads the preference")
            T:eq(commands, { "sync", "iv2sh WriteStartupLogo " .. util.shell_escape({ output }) .. " &" },
                "explicit cover selection retains the original escaped background update")

            preference = "@current_page"
            export(function() plugin:onSetRotationMode(Device.screen:getRotationMode()) end)
            checkExport()
            T:eq(reads, 3, "preference changes are not cached")
            T:eq(#commands, 2, "changing away from cover stops boot-logo writes")

            read_failure = true
            export(function() plugin:onReaderReady(ui.doc_settings) end)
            T:eq(#commands, 2, "unreadable firmware settings leave the logo untouched")
            local page = ui:getCurrentPage()
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return ui:getCurrentPage() == page + 1 end, 5, "reading remains responsive after SDK failure")
            T:check(T:topWidget() == ui, "optional logo failure creates no blocking popup")

            read_failure, preference = false, "@cover_logo"
            export(function() plugin:onReaderReady(ui.doc_settings) end)
            T:eq(#commands, 4, "a later readable cover preference can update normally")
            local before = reads
            T:run(function() plugin:onReaderReady(ui.doc_settings) end) -- real emulator, not PocketBook
            checkExport()
            T:eq(reads, before, "non-PocketBook cover export does not query InkView")
            T:eq(#commands, 4, "non-PocketBook export issues no device commands")
            T:closeBook()
            ui = T:openBook(book)
            T:eq(ui:getCurrentPage(), page + 1, "normal close and reopen preserve the reading position")
            T:closeBook()
        end)

        -- Restore hardware boundaries even if body/close fails. Private regular-file
        -- inputs remain in this isolated KO_HOME for normal workers/process teardown.
        Device.isPocketBook, os.execute = saved.pocketbook, saved.execute
        package.loaded["ffi/inkview"] = saved.inkview
        G_reader_settings:saveSetting("document_metadata_folder", saved.metadata)
        if plugin then plugin.cover, plugin.fallback = false, false end
        local cleanup_ok, cleanup_err = pcall(function() T:closeBook() end)
        local errors = {}
        local function describe(e) return tostring(type(e) == "table" and e.msg or e) end
        if not ok then errors[#errors + 1] = "scenario: " .. describe(err) end
        if not cleanup_ok then errors[#errors + 1] = "cleanup: " .. describe(cleanup_err) end
        if #errors > 0 then error(table.concat(errors, "\n")) end
        T:check(not T:reader() and T:topWidget() == T:fileManager(), "scenario returns to the file manager")
    end,
}
