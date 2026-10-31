-- Real write/close failures in a disposable child; the UI process keeps its limits.
return {
    name = "Sidecar copies retain sources after real kernel write and close failures",
    timeout = 60,
    run = function(T)
        local ffi = require("ffi")
        assert(ffi.os == "Linux", "requires Linux RLIMIT_FSIZE")
        ffi.cdef[[
            struct sidecar_test_rlimit { unsigned long current; unsigned long maximum; };
            int setrlimit(int resource, const void *rlim);
            void (*signal(int sig, void (*handler)(int)))(int);
        ]]
        local DocSettings = require("docsettings")
        local ffiutil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local util = require("util")
        local base = os.getenv("KO_HOME") .. "/sidecar-copy-io"
        local book = base .. "/owned.epub"
        local destination = DocSettings:getSidecarDir(book, "dir")
        local old_setting = G_reader_settings:readSetting("document_metadata_folder")
        local pid, fd
        local function write(path, bytes)
            local file = assert(io.open(path, "wb"))
            assert(file:write(bytes))
            assert(file:close())
        end
        local ok, err = pcall(function()
            T:run(function()
                util.makePath(base)
                assert(not ffiutil.copyFile(T:fixture("books/en.epub"), book))
                G_reader_settings:saveSetting("document_metadata_folder", "doc")
            end)
            local ui = T:openBook(book)
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return ui:getCurrentPage() == 2 end, 5, "page two before I/O failure")
            T:run(function()
                ui.bookmark:onToggleBookmark()
                ui.annotation.annotations[1].note = "Keep this I/O-failure note"
            end)
            T:closeBook()
            local source = DocSettings:getSidecarDir(book, "doc")
            local cover = assert(util.readFromFile("resources/koreader.png"))
            local custom = 'return { custom_props = { title = "Retained custom title" } }' .. string.rep(" ", 1024)
            T:check(#cover > 8192 and #custom < 4096, "fixtures exercise write and buffered-close failures")
            write(source .. "/cover.png", cover)
            write(source .. "/custom_metadata.lua", custom)
            T:run(function()
                G_reader_settings:saveSetting("document_metadata_folder", "dir")
                pid, fd = ffiutil.runInSubProcess(function(_, output)
                    local settings = DocSettings:open(book)
                    local original_write = util.writeToFile
                    local armed = false
                    -- Persist the main settings normally, then fail only custom-file I/O.
                    -- Return the real writer's result; no copy/write result is fabricated.
                    util.writeToFile = function(data, file, ...)
                        local written = original_write(data, file, ...)
                        if written and file == destination .. "/metadata.epub.lua" then
                            local limit = ffi.new("struct sidecar_test_rlimit", { 0, 0 })
                            assert(ffi.C.setrlimit(1, limit) == 0)
                            ffi.C.signal(25, ffi.cast("void (*)(int)", 1))
                            armed = true
                        end
                        return written
                    end
                    assert(settings:flush() == destination)
                    assert(armed)
                    assert(ffiutil.writeToFD(output, "finished", true))
                end, true)
                assert(pid and fd)
            end)
            T:waitUntil(function() return ffiutil.isSubProcessDone(pid) end, 5, "limited child to exit")
            pid = nil
            local result = ffiutil.readAllFromFD(fd)
            fd = nil
            T:eq(result, "finished", "real metadata migration completed in the child")
            T:check(util.readFromFile(source .. "/cover.png") == cover, "write failure preserves every source-cover byte")
            T:eq(util.readFromFile(source .. "/custom_metadata.lua"), custom, "close failure preserves original custom metadata")
            T:eq(lfs.attributes(destination .. "/cover.png"), nil, "partial cover is not left discoverable")
            T:eq(lfs.attributes(destination .. "/custom_metadata.lua"), nil, "partial custom metadata is not left discoverable")
            T:eq(DocSettings:open(book):readSetting("annotations")[1].note, "Keep this I/O-failure note", "successfully saved main sidecar retains the bookmark")
            T:run(function() assert(DocSettings:open(book):flush() == destination) end)
            T:check(util.readFromFile(destination .. "/cover.png") == cover, "unrestricted retry copies complete cover")
            T:eq(util.readFromFile(destination .. "/custom_metadata.lua"), custom, "retry copies complete custom metadata")
            T:eq(lfs.attributes(source), nil, "successful retry removes the empty old directory")
            ui = T:openBook(book)
            T:eq(ui:getCurrentPage(), 2, "ReaderUI restores the saved reading position")
            T:eq(ui.annotation.annotations[1].note, "Keep this I/O-failure note", "ReaderUI restores retained annotation")
            T:eq(ui.doc_props.display_title, "Retained custom title", "ReaderUI loads retained custom metadata")
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return ui:getCurrentPage() == 3 end, 5, "reader remains usable after recovery")
            T:closeBook()
        end)
        if pid then
            ffiutil.terminateSubProcess(pid)
            for _ = 1, 200 do
                if ffiutil.isSubProcessDone(pid) then break end
                ffiutil.usleep(25000)
            end
        end
        if fd then ffi.C.close(fd) end
        if T:reader() then T:closeBook() end
        G_reader_settings:saveSetting("document_metadata_folder", old_setting)
        if lfs.attributes(destination) then ffiutil.purgeDir(destination) end
        ffiutil.purgeDir(base)
        if not ok then error(err, 0) end
    end,
}
