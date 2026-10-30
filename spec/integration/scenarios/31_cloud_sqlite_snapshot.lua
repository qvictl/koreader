-- A long-lived SQLite reader must not make statistics cloud uploads lose WAL rows.
return {
    name = "Cloud statistics use one standalone SQLite snapshot",
    timeout = 60,
    run = function(T)
        local SQ3 = require("lua-ljsqlite3/init")
        local DataStorage = require("datastorage")
        local ffiUtil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local UIManager = require("ui/uimanager")
        local fm = T:fileManager()
        local stats, cloud = fm.statistics, fm.cloudstorage
        T:check(stats and cloud, "statistics and cloud plugins are attached")
        local settings = DataStorage:getSettingsDir()
        local path = settings .. "/statistics.sqlite3"
        local uploaded = settings .. "/uploaded-statistics.sqlite3"
        local observer, upload_count, snapshot_path
        local original_providers, original_server = cloud.providers, stats.settings.sync_server
        local function count(file)
            local conn = SQ3.open(file, "ro")
            local value = tonumber(conn:rowexec("SELECT count(*) FROM book"))
            conn:close()
            return value
        end
        local function insert(id)
            local conn = SQ3.open(path)
            conn:exec(string.format([[INSERT INTO book(id,title,authors,pages,md5)
                VALUES(%d,'Synthetic WAL %d','Synthetic author',100,'synthetic-wal-%d')]], id, id, id))
            conn:close()
        end
        local ok, err = pcall(function()
            T:run(function()
                local conn = SQ3.open(path)
                conn:exec("PRAGMA journal_mode=WAL")
                conn:exec("DELETE FROM page_stat_data; DELETE FROM book")
                conn:close()
                insert(101)
                conn = SQ3.open(path)
                conn:exec("PRAGMA wal_checkpoint(TRUNCATE)")
                conn:close()
                observer = SQ3.open(path)
                observer:exec("BEGIN")
                T:eq(tonumber(observer:rowexec("SELECT count(*) FROM book")), 1, "observer holds the old SQLite snapshot")
                insert(102)
                cloud.providers = { synthetic = {
                    run = function(callback) callback() end,
                    downloadFile = function(_, destination)
                        local f = assert(io.open(destination, "w")); f:write("not found"); f:close()
                        return 404
                    end,
                    uploadFile = function(_, source)
                        snapshot_path = source
                        T:eq(ffiUtil.basename(source), "statistics.sqlite3", "provider keeps the remote database name")
                        upload_count = count(source)
                        assert(not ffiUtil.copyFile(source, uploaded))
                        insert(103) -- This write belongs to the next synchronization.
                        return 200
                    end,
                } }
                stats.settings.sync_server = { type = "synthetic", url = "synthetic" }
                stats:onSyncBookStats(true)
            end)
            T:waitUntil(function() return upload_count ~= nil end, 5, "interactive statistics synchronization uploads")
            T:waitUntil(function()
                local widget = T:topWidget()
                return widget and widget.text == require("gettext")("Successfully synchronized.")
            end, 5, "successful statistics synchronization notification")
            T:repaint()
            T:check(T:topWidget().dimen and T:topWidget().dimen.w > 0, "success notification is painted")
            T:eq(upload_count, 2, "upload includes the row committed only to WAL")
            T:eq(count(uploaded), 2, "the standalone uploaded database has both committed rows")
            T:eq(count(path .. ".sync"), 2, "cached baseline equals the upload despite a later live write")
            T:eq(count(path), 3, "the later live write remains for the next sync")
            T:eq(lfs.attributes(snapshot_path), nil, "temporary snapshot is removed after upload")
            T:eq(lfs.attributes(ffiUtil.dirname(snapshot_path)), nil, "temporary snapshot directory is removed")
            T:eq(lfs.attributes(path .. ".temp"), nil, "download scratch file is removed")
            T:run(function()
                UIManager:close(T:topWidget())
            end)
        end)
        cloud.providers = original_providers
        stats.settings.sync_server = original_server
        if observer then pcall(observer.close, observer) end
        os.remove(uploaded)
        if not ok then error(err, 0) end
    end,
}
