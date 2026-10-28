-- Legacy statistics migration, midnight boundaries, and an empty local cloud-sync DB.
-- Uses real SQLite files and the painted reset confirmation in the FileManager.
return {
    name = "Statistics migration, period boundaries and empty sync",
    timeout = 60,
    run = function(T)
        local SQ3 = require("lua-ljsqlite3/init")
        local DataStorage = require("datastorage")
        local util = require("util")
        local stats = T:fileManager().statistics
        T:check(stats, "statistics plugin is attached to FileManager")
        local settings = DataStorage:getSettingsDir()
        local path = settings .. "/statistics.sqlite3"

        T:run(function()
            local legacy_dir = DataStorage:getDataDir() .. "/statistics"
            util.makePath(legacy_dir)
            local file = assert(io.open(legacy_dir .. "/synthetic.stat", "w"))
            file:write([[return {
                title = "Legacy synthetic book", authors = "Synthetic author", pages = 100,
                notes = 0, highlights = 0, series = "", language = "en", total_time = 60,
                details = { { time = 1000, page = 1 }, { time = 1030, page = 2 } },
            }]])
            file:close()
            local ReadHistory = require("readhistory")
            local history = ReadHistory.hist
            ReadHistory.hist = {}
            local conn = SQ3.open(settings .. "/legacy-import.sqlite3")
            local ok, imported = pcall(stats.migrateToDB, stats, conn)
            ReadHistory.hist = history
            local rows = ok and tonumber(conn:rowexec("SELECT count(*) FROM page_stat_data"))
            local title = ok and conn:rowexec("SELECT title FROM book")
            conn:close()
            T:check(ok, "legacy migration succeeds without an open document: " .. tostring(imported))
            T:eq(imported, 1, "legacy book imported")
            T:eq(rows, 3, "legacy readings are stored in the current data table")
            T:eq(title, "Legacy synthetic book", "legacy metadata preserved")

            conn = SQ3.open(path)
            conn:exec([[INSERT INTO book(id, title, authors, pages, md5) VALUES
                (41, 'Synthetic period', 'Synthetic author', 100, 'synthetic-period'),
                (42, 'Next period only', 'Synthetic author', 100, 'synthetic-next');
                INSERT INTO page_stat_data VALUES
                (41, 1, 1000, 20, 100), (41, 2, 2000, 30, 100), (42, 1, 2000, 40, 100);]])
            conn:close()
            local books = stats:getBooksFromPeriod(1000, 2000)
            T:eq(#books, 1, "the period includes its start and excludes its end")
            T:eq(books[1].book_id, 41, "only the current period's book is listed")
            T:eq(books[1].duration, 20, "next period's reading time is excluded")
            stats:resetStatsForBookForPeriod(41, 1000, 2000, false)
        end)
        T:repaint()
        local dialog = T:topWidget()
        local reset = T:findWidget(dialog, function(widget)
            return widget.text == dialog.ok_text and widget.callback
        end)
        T:check(reset, "painted reset button is available")
        T:tapWidget(reset, "reset the statistics period")
        T:waitUntil(function() return T:topWidget() == T:fileManager() end, 5, "reset dialog closes")
        T:run(function()
            local conn = SQ3.open(path)
            T:eq(tonumber(conn:rowexec("SELECT count(*) FROM page_stat_data WHERE start_time = 1000")),
                0, "period start is reset")
            T:eq(tonumber(conn:rowexec("SELECT count(*) FROM page_stat_data WHERE start_time = 2000")),
                2, "readings at the next period's start are preserved")
            conn:close()
            local remote = settings .. "/synthetic-remote.sqlite3"
            conn = SQ3.open(remote)
            stats:createDB(conn)
            conn:close()
            local empty = settings .. "/synthetic-empty.sqlite3"
            T:eq(stats.onSync(empty, settings .. "/synthetic-cached.sqlite3", remote),
                false, "empty local sync database is rejected without throwing")
            conn = SQ3.open(empty)
            T:eq(tonumber(conn:rowexec("PRAGMA schema_version")), 0, "rejected local database remains empty")
            conn:close()
            T:check(stats.onSync(path, settings .. "/legacy-sync-cache.sqlite3", settings .. "/legacy-import.sqlite3"),
                "legacy readings synchronize without a file hash")
            conn = SQ3.open(path)
            T:eq(tonumber(conn:rowexec([[SELECT count(*) FROM page_stat_data p JOIN book b ON b.id = p.id_book
                WHERE b.title = 'Legacy synthetic book' AND b.md5 IS NULL]])), 3,
                "cloud sync retains all legacy reading records")
            conn:close()
            conn = SQ3.open(path)
            local count_before = tonumber(conn:rowexec("SELECT count(*) FROM page_stat_data"))
            conn:exec([[INSERT INTO book(title, authors, pages) VALUES
                ('Legacy synthetic book', 'Synthetic author', 100);]])
            conn:close()
            local ok, message = stats.onSync(path, settings .. "/legacy-sync-cache.sqlite3",
                settings .. "/legacy-import.sqlite3")
            T:eq(ok, false, "ambiguous legacy identities are rejected")
            T:eq(message, require("gettext")("Statistics synchronization stopped: the local database contains duplicate book identities without file hashes."),
                "ambiguous identity refusal explains the database conflict")
            conn = SQ3.open(path)
            T:eq(tonumber(conn:rowexec("SELECT count(*) FROM page_stat_data")), count_before,
                "refused synchronization preserves local readings")
            conn:close()
        end)
    end,
}
