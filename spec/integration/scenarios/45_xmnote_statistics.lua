-- Real exporter/UI and SQLite; only the remote transport and online gate are simulated.
return {
    name = "XMNote exports quoted book titles without corrupting statistics identity",
    timeout = 60,
    run = function(T)
        local DataStorage = require("datastorage")
        local DocSettings = require("docsettings")
        local NetworkMgr = require("ui/network/manager")
        local SQ3 = require("lua-ljsqlite3/init")
        local UIManager = require("ui/uimanager")
        local ffiUtil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local util = require("util")
        local fm = T:fileManager()
        local exporter = assert(fm.exporter)
        local target = exporter.targets.xmnote
        local base = os.getenv("KO_HOME") .. "/xmnote-fixture"
        local book_path = base .. "/quoted-title.epub"
        local database = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
        assert(not lfs.attributes(base), "scenario fixture must be new")
        assert(lfs.attributes(database, "mode") == "file", "statistics plugin initialized the private database")
        local saved_settings, saved_targets = exporter.settings, {}
        local saved_request, saved_online = target.makeJsonRequest, NetworkMgr.runWhenOnline
        local saved_timestamp = target.timestamp
        local saved_open = SQ3.open
        for name, item in pairs(exporter.targets) do saved_targets[name] = item.settings end
        local requests, conn, book_id = {}, nil, nil
        local notes = {
            title = "Reader's 日本語; quoted title",
            author = "Synthetic author",
            file = book_path,
            {{ text = "Synthetic highlighted text", note = "Preserve this note", page = 4, time = 1700000000 }},
        }
        local function dismissMessages()
            T:run(function()
                while T:topWidget() and T:topWidget() ~= fm do UIManager:close(T:topWidget()) end
            end)
        end
        local function exportOnce(index)
            T:run(function() exporter:exportClippings{ synthetic = notes } end)
            T:waitUntil(function() return #requests == index end, 10, "synthetic XMNote request")
            T:repaint()
            local summary = T:topWidget()
            T:check(summary.text and summary.text:find("Exported successfully", 1, true), "real exporter reports success")
            T:check(summary.dimen ~= nil, "export completion summary is painted")
            dismissMessages()
        end
        local ok, err = pcall(function()
            T:run(function()
                util.makePath(base)
                assert(not ffiUtil.copyFile(T:fixture("books/en.epub"), book_path))
                local settings = DocSettings:open(book_path)
                settings:saveSetting("partial_md5_checksum", "synthetic-checksum")
                settings:flush()
                conn = SQ3.open(database)
                assert(conn:rowexec("SELECT count(*) FROM book") == 0, "private statistics fixture starts empty")
                local stmt = conn:prepare("INSERT INTO book (title, authors, md5, pages) VALUES (?, ?, ?, 10)")
                stmt:bind(notes.title, notes.author, "synthetic-checksum"):step()
                stmt:close()
                book_id = tonumber(conn:rowexec("SELECT last_insert_rowid()"))
                stmt = conn:prepare("INSERT INTO page_stat_data VALUES (?, 4, 1700000000, 30, 10)")
                stmt:bind(book_id):step()
                stmt:close()
                conn:close(); conn = nil
                exporter.settings = util.tableDeepCopy(saved_settings)
                exporter.settings.show_messages = true
                for _, item in pairs(exporter.targets) do item.settings = { enabled = false } end
                target.settings = { enabled = true, ip = "127.0.0.1" }
                NetworkMgr.runWhenOnline = function(_, callback) callback() end
                target.makeJsonRequest = function(_, url, method, body)
                    T:eq(url, "http://127.0.0.1:8080/send", "request stays within the simulated endpoint")
                    T:eq(method, "POST", "actual exporter builds a POST")
                    requests[#requests + 1] = body
                    return { code = 200 }
                end
            end)
            exportOnce(1)
            T:eq(requests[1].title, notes.title, "quotes, semicolon and Unicode survive export")
            T:eq(requests[1].fuzzyReadingDurations[1].durationSeconds, 30, "statistics match the literal book identity")
            T:eq(requests[1].entries[1].note, "Preserve this note", "highlight note survives statistics lookup")
            notes.title = "' OR 1=1 --"
            exportOnce(2)
            T:eq(#requests[2].fuzzyReadingDurations, 0, "SQL-like title cannot acquire another book's statistics")
            T:run(function()
                conn = SQ3.open(database)
                local stmt = conn:prepare("DELETE FROM page_stat_data WHERE id_book = ?")
                stmt:bind(book_id):step(); stmt:close()
                conn:close(); conn = nil
                notes.title = "Reader's 日本語; quoted title"
            end)
            exportOnce(3)
            T:eq(#requests[3].fuzzyReadingDurations, 0, "absent reading durations do not abort highlight export")
            T:eq(requests[3].entries[1].text, "Synthetic highlighted text", "highlight text survives empty statistics")

            local closed = 0
            SQ3.open = function(file, mode)
                local connection = saved_open(file, mode)
                if file ~= database or mode ~= "ro" then return connection end
                return {
                    prepare = function(_, ...) return connection:prepare(...) end,
                    close = function()
                        connection:close()
                        closed = closed + 1
                        error("injected optional-statistics close error")
                    end,
                }
            end
            exportOnce(4)
            T:eq(closed, 1, "close failure injection runs after actual SQLite cleanup")
            T:eq(requests[4].entries[1].note, "Preserve this note", "optional close error does not suppress note export")

        end)
        SQ3.open = saved_open
        target.makeJsonRequest, NetworkMgr.runWhenOnline = saved_request, saved_online
        exporter.settings = saved_settings
        target.timestamp = saved_timestamp
        for name, item in pairs(exporter.targets) do item.settings = saved_targets[name] end
        local cleanup_ok, cleanup_err = pcall(function()
            if conn and not conn._closed then conn:close() end
            dismissMessages()
            ffiUtil.purgeDir(base)
            if book_id then
                conn = SQ3.open(database)
                local stmt = conn:prepare("DELETE FROM page_stat_data WHERE id_book = ?")
                stmt:bind(book_id):step(); stmt:close()
                stmt = conn:prepare("DELETE FROM book WHERE id = ?")
                stmt:bind(book_id):step(); stmt:close()
                local remaining = tonumber(conn:rowexec("SELECT count(*) FROM book"))
                conn:close(); conn = nil
                T:eq(remaining, 0, "synthetic statistics are removed")
            end
        end)
        local close_ok, close_err = pcall(function()
            if conn and not conn._closed then conn:close() end
        end)
        if not cleanup_ok or not close_ok then
            local errors = {}
            if not ok then errors[#errors + 1] = tostring(type(err) == "table" and err.msg or err) end
            if not cleanup_ok then errors[#errors + 1] = "fixture cleanup: " .. tostring(type(cleanup_err) == "table" and cleanup_err.msg or cleanup_err) end
            if not close_ok then errors[#errors + 1] = "connection close: " .. tostring(close_err) end
            error(table.concat(errors, "\n"), 0)
        end
        if not ok then error(err, 0) end
        T:eq(lfs.attributes(base), nil, "private EPUB and sidecar are removed")
    end,
}
