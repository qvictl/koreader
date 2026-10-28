-- Unit tests for plugins/statistics.koplugin/main.lua (ReaderStatistics).
--
-- The plugin runs on every page turn and writes a SQLite DB on the device, so these specs
-- focus on the volatile bookkeeping (onPageUpdate, pause/resume, rerendering), on when and
-- what gets flushed to the DB (insertDB, close, suspend, 50-pageturn batching), on the DB
-- schema creation/migration/backup logic, and on the queries feeding the statistics views.
-- DB contents are asserted with plain SQL queries against $KO_HOME/settings/statistics.sqlite3.
describe("Statistics plugin", function()
    local ReaderStatistics, SQ3, UIManager, DataStorage, DocSettings, ReadHistory, datetime, lfs, util
    local mock_time
    local db_path, settings_dir
    local shown, closed
    local orig_show, orig_close, orig_forceRePaint, orig_tickAfterNext, orig_os_date
    local orig_hist

    -- Fixed "now": a Wednesday at noon, local time.
    local NOW
    local TODAY0

    local sample_epub = "spec/front/unit/data/juliet.epub"

    local function removeDB()
        for suffix in ("|-wal|-shm|-journal|.sync"):gmatch("([^|]*)|?") do
            os.remove(db_path .. suffix)
            -- cloud sync scratch DBs (remote copy and state of the previous sync)
            os.remove(settings_dir .. "/income.sqlite3" .. suffix)
            os.remove(settings_dir .. "/cached.sqlite3" .. suffix)
        end
        for f in lfs.dir(settings_dir) do
            if f:match("^statistics%.sqlite3%.bkp") then
                os.remove(settings_dir .. "/" .. f)
            end
        end
    end

    local function freshSettings(overrides)
        local s = {
            min_sec = 5,
            max_sec = 120,
            freeze_finished_books = false,
            is_enabled = true,
            -- convert_to_db unset: fresh install, the DB gets created
            calendar_start_day_of_week = 2,
            calendar_nb_book_spans = 3,
            calendar_show_histogram = true,
            calendar_browse_future_months = false,
            color = false,
        }
        for k, v in pairs(overrides or {}) do
            if v == "nil" then s[k] = nil else s[k] = v end
        end
        G_reader_settings:saveSetting("statistics", s)
        return s
    end

    local function withConn(path, fn)
        local conn = SQ3.open(path or db_path)
        local r = { fn(conn) }
        conn:close()
        return unpack(r)
    end

    -- First column of the first row, as a Lua number (or nil).
    local function dbNum(sql, path)
        return withConn(path, function(conn)
            local v = conn:rowexec(sql)
            return v ~= nil and tonumber(v) or nil
        end)
    end

    local function dbText(sql, path)
        return withConn(path, function(conn)
            local v = conn:rowexec(sql)
            return v ~= nil and tostring(v) or nil
        end)
    end

    -- All rows of a query, as an array of arrays of Lua values (numbers converted).
    local function dbRows(sql, path)
        return withConn(path, function(conn)
            local res, nb = conn:exec(sql)
            local rows = {}
            if res then
                for i = 1, nb do
                    local row = {}
                    for c = 1, #res do
                        local v = res[c][i]
                        row[c] = (type(v) == "cdata" or type(v) == "number") and tonumber(v) or v
                    end
                    rows[i] = row
                end
            end
            return rows
        end)
    end

    local function dbExec(sql, path)
        withConn(path, function(conn) conn:exec(sql) end)
    end

    local function insertBook(t, path)
        withConn(path, function(conn)
            local stmt = conn:prepare("INSERT INTO book VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);")
            stmt:reset():bind(t.id, t.title, t.authors or "Someone", t.notes or 0, t.last_open or NOW,
                t.highlights or 0, t.pages or 100, t.series or "N/A", t.language or "en", t.md5 or "md5",
                t.total_read_time, t.total_read_pages):step()
            stmt:close()
        end)
    end

    local function insertPageStat(id_book, page, start_time, duration, total_pages, path)
        dbExec(string.format("INSERT INTO page_stat_data VALUES(%d, %d, %d, %d, %d);",
            id_book, page, start_time, duration, total_pages), path)
    end

    local function lastShown(class_name)
        for i = #shown, 1, -1 do
            local w = shown[i]
            if not class_name
                or (class_name == "ConfirmBox" and w.ok_callback and w.cancel_text ~= nil)
                or (class_name == "KeyValuePage" and w.kv_pairs)
                or (class_name == "InfoMessage" and w.text and not w.ok_callback and not w.kv_pairs) then
                return w
            end
        end
    end

    local function newFakeDoc(opts)
        return {
            file = opts.file or "/tmp/statistics_spec_book.epub",
            pages = opts.pages or 100,
            is_pic = opts.is_pic,
            getPageCount = function(self) return self.pages end,
            hasHiddenFlows = function() return opts.hidden_flows and true or false end,
            getPageFlow = function() return opts.flow or 0 end,
            getPageNumberInFlow = function(_, p) return p end,
            getTotalPagesInFlow = function() return opts.flow_pages or 80 end,
        }
    end

    -- Builds a ReaderStatistics instance on a minimal fake ReaderUI.
    local function newStats(opts)
        opts = opts or {}
        local doc = not opts.no_doc and newFakeDoc(opts) or nil
        local footer_updates = 0
        local ui = {
            document = doc,
            menu = { registerToMainMenu = function() end },
            doc_settings = {
                readSetting = function(_, key)
                    if key == "summary" then
                        return opts.summary or { status = "reading" }
                    end
                end,
            },
            doc_props = {
                display_title = opts.title or "Book A",
                authors = opts.authors,
                language = opts.language,
                series = opts.series,
                series_index = opts.series_index,
            },
            annotation = {
                getNumberOfHighlightsAndNotes = function() return opts.highlights or 2, opts.notes or 1 end,
            },
            getCurrentPage = function() return opts.current_page or 1 end,
            paging = opts.paging,
            pagemap = opts.pagemap,
            cloudstorage = opts.cloudstorage,
        }
        if ui.doc_props.authors == nil and not opts.no_authors then
            ui.doc_props.authors = "Author A"
        end
        local view = { footer = { maybeUpdateFooter = function() footer_updates = footer_updates + 1 end } }
        local stats = ReaderStatistics:new{ ui = ui, view = view, document = doc }
        if doc and not opts.not_ready then
            stats:onReaderReady({
                readSetting = function(_, key, default)
                    if key == "partial_md5_checksum" then return opts.md5 or "md5-a" end
                    return default
                end,
            })
        end
        stats._footer_updates = function() return footer_updates end
        return stats
    end

    setup(function()
        require("commonrequire")
        package.path = "plugins/statistics.koplugin/?.lua;" .. package.path
        ReaderStatistics = dofile("plugins/statistics.koplugin/main.lua")
        SQ3 = require("lua-ljsqlite3/init")
        UIManager = require("ui/uimanager")
        DataStorage = require("datastorage")
        DocSettings = require("docsettings")
        ReadHistory = require("readhistory")
        datetime = require("datetime")
        lfs = require("libs/libkoreader-lfs")
        util = require("util")
        mock_time = require("mock_time")
        settings_dir = DataStorage:getSettingsDir()
        db_path = settings_dir .. "/statistics.sqlite3"
        NOW = os.time{ year = 2026, month = 3, day = 18, hour = 12, min = 0, sec = 0 }
        TODAY0 = NOW - 12 * 3600
    end)

    before_each(function()
        removeDB()
        freshSettings()
        shown, closed = {}, {}
        orig_show, orig_close = UIManager.show, UIManager.close
        orig_forceRePaint, orig_tickAfterNext = UIManager.forceRePaint, UIManager.tickAfterNext
        UIManager.show = function(_, w) table.insert(shown, w) end
        UIManager.close = function(_, w) table.insert(closed, w) end
        UIManager.forceRePaint = function() end
        orig_hist = ReadHistory.hist
        ReadHistory.hist = {}
        mock_time:install()
        mock_time:set_realtime(NOW)
        -- mock_time ignores os.time's table argument: keep date conversions working
        local mocked_os_time = os.time
        os.time = function(t) -- luacheck: ignore
            if t then return mock_time.original_os_time(t) end
            return mocked_os_time()
        end
        -- os.date("*t") without a timestamp is not mocked by mock_time: make it follow os.time()
        orig_os_date = os.date
        os.date = function(fmt, ts) -- luacheck: ignore
            return orig_os_date(fmt, ts or os.time())
        end
    end)

    teardown(function()
        removeDB()
    end)

    after_each(function()
        os.date = orig_os_date -- luacheck: ignore
        mock_time:uninstall()
        UIManager.show, UIManager.close = orig_show, orig_close
        UIManager.forceRePaint, UIManager.tickAfterNext = orig_forceRePaint, orig_tickAfterNext
        ReadHistory.hist = orig_hist
        ReaderStatistics.preserved_start_current_period = nil
    end)

    describe("database setup", function()
        it("creates the current schema on first run and marks the conversion as done", function()
            local stats = newStats{ no_doc = true }
            assert.is_true(stats.settings.convert_to_db)
            assert.is_true(G_reader_settings:readSetting("statistics").convert_to_db)
            assert.are.equal(20221111, dbNum("PRAGMA user_version;"))
            assert.are.equal("wal", dbText("PRAGMA journal_mode;"))
            assert.are.equal(1000, dbNum("SELECT count(*) FROM numbers;"))
            assert.are.equal(0, dbNum("SELECT count(*) FROM book;"))
            assert.are.equal(1, dbNum("SELECT count(*) FROM sqlite_master WHERE type='view' AND name='page_stat';"))
            assert.are.equal(1, dbNum("SELECT count(*) FROM sqlite_master WHERE type='index' AND name='book_title_authors_md5';"))
            assert.are.equal(1, dbNum("SELECT count(*) FROM sqlite_master WHERE type='index' AND name='page_stat_data_start_time';"))
            assert.is_nil(lastShown())
            -- No document: nothing to track
            assert.is_falsy(stats:isEnabled())
            assert.is_nil(stats.data)
        end)

        it("does not offer a migration when the only history entry is the quickstart guide", function()
            local _, quickstart = util.splitFilePathName(require("ui/quickstart").quickstart_filename)
            ReadHistory.hist = { { text = quickstart, file = "/nonexistent/" .. quickstart } }
            newStats{ no_doc = true }
            assert.are.equal(20221111, dbNum("PRAGMA user_version;"))
            assert.is_nil(lastShown())
        end)

        it("leaves an up-to-date database alone", function()
            local stats = newStats()
            assert.are.equal(1, stats.id_curr_book)
            newStats{ no_doc = true }
            assert.are.equal(1, dbNum("SELECT count(*) FROM book;"))
            assert.is_nil(lastShown())
            for f in lfs.dir(settings_dir) do
                assert.is_nil(f:match("%.bkp"))
            end
        end)

        it("backs up (once) a database with a newer, unknown schema and keeps using it", function()
            newStats()
            dbExec("PRAGMA user_version=20991231;")
            local bkp = db_path .. ".bkp.20991231-to-20221111"
            newStats{ no_doc = true }
            assert.are.equal("file", lfs.attributes(bkp, "mode"))
            assert.are.equal(1, dbNum("SELECT count(*) FROM book;", bkp))
            -- An existing backup is never overwritten
            dbExec("DELETE FROM book;")
            newStats{ no_doc = true }
            assert.are.equal(1, dbNum("SELECT count(*) FROM book;", bkp))
            assert.are.equal(20991231, dbNum("PRAGMA user_version;"))
        end)

        it("migrates a legacy (pre-2020) schema, merging duplicate books", function()
            freshSettings{ convert_to_db = true }
            dbExec([[
                CREATE TABLE book (id integer PRIMARY KEY autoincrement, title text, authors text,
                    notes integer, last_open integer, highlights integer, pages integer, series text,
                    language text, md5 text, total_read_time integer, total_read_pages integer);
                CREATE TABLE page_stat (id_book integer, page integer NOT NULL, start_time integer NOT NULL,
                    period integer NOT NULL, UNIQUE (page, start_time), FOREIGN KEY(id_book) REFERENCES book(id));
                CREATE INDEX page_stat_id_book ON page_stat(id_book);
                CREATE INDEX book_title_authors_md5 ON book(title, authors, md5);
                CREATE TABLE info (version integer);
                INSERT INTO info VALUES (20180710);
                INSERT INTO book VALUES (1, 'T1', 'A1', 0, 100, 0, 10, 'N/A', 'en', 'm1', 0, 0);
                INSERT INTO book VALUES (2, 'T1', 'A1', 0, 200, 0, 10, 'N/A', 'en', 'm1', 0, 0);
                INSERT INTO book VALUES (3, 'T2', NULL, 0, 300, 0, 20, 'N/A', 'en', 'm2', 0, 0);
                INSERT INTO page_stat VALUES (1, 1, 1000, 30);
                INSERT INTO page_stat VALUES (1, 2, 1100, 40);
                INSERT INTO page_stat VALUES (2, 3, 1200, 50);
                INSERT INTO page_stat VALUES (3, 1, 2000, 60);
            ]])
            assert.are.equal(0, dbNum("PRAGMA user_version;"))

            newStats{ no_doc = true }

            assert.are.equal(20221111, dbNum("PRAGMA user_version;"))
            assert.are.equal("file", lfs.attributes(db_path .. ".bkp.0-to-20221111", "mode"))
            -- old tables are gone, page_stat is now a view on page_stat_data
            assert.are.equal(0, dbNum("SELECT count(*) FROM sqlite_master WHERE name='info';"))
            assert.are.equal("view", dbText("SELECT type FROM sqlite_master WHERE name='page_stat';"))
            -- duplicate book 2 merged into book 1, NULL authors normalized
            assert.are.same({ { 1, "T1", "A1" }, { 3, "T2", "" } }, dbRows("SELECT id, title, authors FROM book ORDER BY id;"))
            assert.are.same({
                { 1, 1, 1000, 30, 10 },
                { 1, 2, 1100, 40, 10 },
                { 1, 3, 1200, 50, 10 },
                { 3, 1, 2000, 60, 20 },
            }, dbRows("SELECT id_book, page, start_time, duration, total_pages FROM page_stat_data ORDER BY start_time;"))
            assert.are.same({ { 3, 120 }, { 1, 60 } }, dbRows("SELECT total_read_pages, total_read_time FROM book ORDER BY id;"))
            -- the index is now unique
            assert.has_error(function()
                dbExec("INSERT INTO book (title, authors, md5) VALUES ('T1', 'A1', 'm1');")
            end)
            local info = lastShown("InfoMessage")
            assert.is_not_nil(info)
            assert.are.equal("Statistics database updated.", info.text)
        end)

        it("only applies the missing steps when migrating from schema 20201022", function()
            -- Build a current DB, then downgrade it to how 20201022 looked (non-unique index)
            newStats{ no_doc = true }
            dbExec([[
                DROP INDEX book_title_authors_md5;
                CREATE INDEX book_title_authors_md5 ON book(title, authors, md5);
                INSERT INTO book VALUES (1, 'T', 'A', 0, 1, 0, 10, 'N/A', 'en', 'm', 0, 0);
                INSERT INTO book VALUES (2, 'T', 'A', 0, 2, 0, 10, 'N/A', 'en', 'm', 0, 0);
                INSERT INTO page_stat_data VALUES (2, 4, 5000, 25, 10);
                PRAGMA user_version=20201022;
            ]])
            newStats{ no_doc = true }
            assert.are.equal(20221111, dbNum("PRAGMA user_version;"))
            assert.are.same({ { 1, 1, 25 } }, dbRows("SELECT id, total_read_pages, total_read_time FROM book;"))
            assert.are.same({ { 1, 4 } }, dbRows("SELECT id_book, page FROM page_stat_data;"))
        end)
    end)

    describe("book identification", function()
        it("registers a new book with its metadata on first open", function()
            local stats = newStats{ title = "Book A", authors = "Author A", language = "fr",
                series = "Saga", series_index = 2, pages = 321, md5 = "abc", highlights = 4, notes = 3 }
            assert.are.equal(1, stats.id_curr_book)
            assert.is_true(stats:isEnabled())
            assert.is_true(stats:isEnabledAndNotFrozen())
            assert.are.equal("Saga #2", stats.data.series)
            assert.are.same({ { "Book A", "Author A", "fr", "Saga #2", "abc", 321, 4, 3, NOW, 0, 0 } },
                dbRows("SELECT title, authors, language, series, md5, pages, highlights, notes, last_open, total_read_time, total_read_pages FROM book;"))
            -- No read data yet: average time per page is initialized to half the max
            assert.are.equal(60, stats.avg_time)
            assert.are.equal(1, stats._footer_updates())
        end)

        it("uses N/A for missing metadata", function()
            local stats = newStats{ no_authors = true }
            assert.are.same({ { "N/A", "N/A", "N/A" } }, dbRows("SELECT authors, language, series FROM book;"))
            assert.are.equal("N/A", stats.data.authors)
        end)

        it("finds the same book again by title, authors and md5, and tells apart other md5s", function()
            local a = newStats{ md5 = "m1" }
            insertPageStat(a.id_curr_book, 1, NOW - 100, 40, 100)
            local again = newStats{ md5 = "m1" }
            assert.are.equal(a.id_curr_book, again.id_curr_book)
            assert.are.equal(1, again.book_read_pages)
            assert.are.equal(40, again.book_read_time)
            assert.are.equal(40, again.avg_time)
            local other = newStats{ md5 = "m2" }
            assert.are_not.equal(a.id_curr_book, other.id_curr_book)
            assert.are.equal(2, dbNum("SELECT count(*) FROM book;"))
        end)

        it("matches legacy NUL-terminated titles and authors for paged documents", function()
            newStats{ no_doc = true }
            insertBook{ id = 7, title = "Paged\0", authors = "Writer\0", md5 = "pdfmd5" }
            local stats = newStats{ paging = true, title = "Paged", authors = "Writer", md5 = "pdfmd5" }
            assert.are.equal(7, stats.id_curr_book)
            assert.are.equal(1, dbNum("SELECT count(*) FROM book;"))
            insertBook{ id = 8, title = "Other", authors = "Writer\0", md5 = "pdf2" }
            stats = newStats{ paging = true, title = "Other", authors = "Writer", md5 = "pdf2" }
            assert.are.equal(8, stats.id_curr_book)
        end)

        it("does not register finished books when their statistics are frozen", function()
            freshSettings{ freeze_finished_books = true }
            local stats = newStats{ summary = { status = "complete", modified = "2026-03-10" } }
            assert.is_nil(stats.id_curr_book)
            assert.is_false(stats:isEnabledAndNotFrozen())
            assert.are.equal(0, dbNum("SELECT count(*) FROM book;"))
            stats:onPageUpdate(1)
            mock_time:increase(30)
            stats:onPageUpdate(2)
            assert.are.same({}, stats.page_stat)
            stats:onCloseDocument()
            assert.are.equal(0, dbNum("SELECT count(*) FROM page_stat_data;"))
        end)

        it("does not track picture documents or disabled statistics", function()
            local pic = newStats{ is_pic = true }
            assert.is_false(pic.is_doc)
            assert.is_nil(pic.id_curr_book)
            freshSettings{ is_enabled = false }
            local off = newStats()
            assert.is_false(off.is_doc)
            off:onPageUpdate(3)
            assert.are.same({}, off.page_stat)
            assert.are.equal(0, dbNum("SELECT count(*) FROM book;"))
            assert.are.equal(0, off._footer_updates())
        end)
    end)

    describe("page turn bookkeeping", function()
        it("records per-page durations, ignoring too short pages and capping too long ones", function()
            local stats = newStats()
            local t0 = NOW
            stats:onPageUpdate(1) -- first page: only a start timestamp
            assert.are.same({ { t0, 0 } }, stats.page_stat[1])
            assert.are.equal(1, stats.curr_page)

            mock_time:increase(30)
            stats:onPageUpdate(2)
            assert.are.same({ { t0, 30 } }, stats.page_stat[1])
            assert.are.same({ { t0 + 30, 0 } }, stats.page_stat[2])
            assert.are.equal(30, stats.mem_read_time)
            assert.are.equal(1, stats.mem_read_pages)
            assert.are.equal(30, stats.avg_time)

            mock_time:increase(2) -- below min_sec: browsing, not reading
            stats:onPageUpdate(3)
            assert.are.same({ { t0 + 30, 0 } }, stats.page_stat[2])
            assert.are.equal(30, stats.mem_read_time)
            assert.are.equal(1, stats.mem_read_pages)

            mock_time:increase(1000) -- above max_sec: fell asleep, capped
            stats:onPageUpdate(2)
            assert.are.same({ { t0 + 32, 120 } }, stats.page_stat[3])
            assert.are.equal(150, stats.mem_read_time)
            assert.are.equal(2, stats.mem_read_pages)
            assert.are.equal(75, stats.avg_time)
            -- re-visiting page 2 appends a new tuple
            assert.are.same({ { t0 + 30, 0 }, { t0 + 1032, 0 } }, stats.page_stat[2])

            mock_time:increase(10)
            stats:onPageUpdate(4)
            assert.are.same({ { t0 + 30, 0 }, { t0 + 1032, 10 } }, stats.page_stat[2])
            assert.are.equal(160, stats.mem_read_time)
            -- re-read page is not counted twice
            assert.are.equal(2, stats.mem_read_pages)

            -- same page again: not a page turn
            local count = stats.pageturn_count
            mock_time:increase(10)
            stats:onPageUpdate(4)
            assert.are.equal(count, stats.pageturn_count)
            assert.are.same({ { t0 + 1042, 0 } }, stats.page_stat[4])
            -- onPosUpdate only forwards actual page changes
            stats:onPosUpdate(1234, 4)
            assert.are.equal(count, stats.pageturn_count)
            stats:onPosUpdate(1234, 5)
            assert.are.equal(5, stats.curr_page)
        end)

        it("honours custom duration limits", function()
            freshSettings{ min_sec = 0, max_sec = 10 }
            local stats = newStats()
            stats:onPageUpdate(1)
            mock_time:increase(1)
            stats:onPageUpdate(2)
            mock_time:increase(50)
            stats:onPageUpdate(3)
            assert.are.equal(1, stats.page_stat[1][1][2])
            assert.are.equal(10, stats.page_stat[2][1][2])
        end)

        it("flushes buffered pages to the DB, dropping placeholders and keeping the current page", function()
            local stats = newStats{ highlights = 5, notes = 2 }
            local t0 = NOW
            stats:onPageUpdate(1)
            mock_time:increase(30)
            stats:onPageUpdate(2)
            mock_time:increase(2)
            stats:onPageUpdate(3)
            mock_time:increase(1000)
            stats:onPageUpdate(4)
            assert.are.equal(0, dbNum("SELECT count(*) FROM page_stat_data;"))

            mock_time:increase(7)
            stats:insertDB()
            assert.are.same({
                { 1, t0, 30, 100 },
                { 3, t0 + 32, 120, 100 },
            }, dbRows("SELECT page, start_time, duration, total_pages FROM page_stat_data ORDER BY start_time;"))
            assert.are.same({ { 2, 150, t0 + 1039, 5, 2, 100 } },
                dbRows("SELECT total_read_pages, total_read_time, last_open, highlights, notes, pages FROM book;"))
            -- volatile stats were reset, keeping the start of the current page
            assert.are.same({ [4] = { { t0 + 1032, 0 } } }, stats.page_stat)
            assert.are.equal(0, stats.mem_read_time)
            assert.are.equal(0, stats.mem_read_pages)
            assert.are.equal(0, stats.pageturn_count)
            assert.are.equal(2, stats.book_read_pages)
            assert.are.equal(150, stats.book_read_time)
            assert.are.equal(75, stats.avg_time)

            -- the current page's duration is accounted on the next turn
            stats:onPageUpdate(5)
            assert.are.same({ { t0 + 1032, 7 } }, stats.page_stat[4])
            -- flushing the same data twice does not duplicate rows
            stats:insertDB()
            stats.page_stat[1] = { { t0, 30 } }
            stats:insertDB()
            assert.are.equal(3, dbNum("SELECT count(*) FROM page_stat_data;"))
        end)

        it("caps the per-page time used for the average while keeping full totals", function()
            local stats = newStats()
            stats:onPageUpdate(1)
            mock_time:increase(100)
            stats:onPageUpdate(2)
            mock_time:increase(100)
            stats:onPageUpdate(1)
            mock_time:increase(100)
            stats:onPageUpdate(2)
            stats:insertDB()
            -- page 1 read twice for 100s: capped to 120 for the average, but stored uncapped
            assert.are.same({ { 2, 300 } }, dbRows("SELECT total_read_pages, total_read_time FROM book;"))
            assert.are.equal(2, stats.book_read_pages)
            assert.are.equal(220, stats.book_read_time)
            assert.are.equal(110, stats.avg_time)
            assert.are.same({ 2, 220 }, { stats:getPageTimeTotalStats(stats.id_curr_book) })
            assert.is_nil(stats:getPageTimeTotalStats(nil))
        end)

        it("schedules a DB flush after 50 page turns, outside of the page turn", function()
            local scheduled = {}
            UIManager.tickAfterNext = function(_, fn) table.insert(scheduled, fn) end
            local stats = newStats()
            for page = 1, 49 do
                stats:onPageUpdate(page)
                mock_time:increase(10)
            end
            assert.are.equal(0, #scheduled)
            assert.are.equal(49, stats.pageturn_count)
            stats:onPageUpdate(50)
            assert.are.equal(1, #scheduled)
            assert.are.equal(0, stats.pageturn_count)
            -- nothing written synchronously during the page turn
            assert.are.equal(0, dbNum("SELECT count(*) FROM page_stat_data;"))
            scheduled[1]()
            assert.are.equal(49, dbNum("SELECT count(*) FROM page_stat_data;"))
            assert.are.equal(490, dbNum("SELECT sum(duration) FROM page_stat_data;"))
            assert.are.same({ [50] = { { NOW + 490, 0 } } }, stats.page_stat)
            -- the next flush needs another 50 turns
            for page = 51, 60 do
                mock_time:increase(10)
                stats:onPageUpdate(page)
            end
            assert.are.equal(1, #scheduled)
        end)

        it("saves the current page duration when the document is closed", function()
            local stats = newStats()
            stats:onPageUpdate(10)
            mock_time:increase(40)
            stats:onCloseDocument()
            assert.are.same({ { 10, NOW, 40 } }, dbRows("SELECT page, start_time, duration FROM page_stat_data;"))
            assert.are.equal(10, stats.curr_page)
            -- auto-save also flushes
            mock_time:increase(20)
            stats:onPageUpdate(11)
            mock_time:increase(20)
            stats:onPageUpdate(12)
            stats:onSaveSettings()
            -- page 10 again (20s after the first flush), and page 11
            assert.are.same({ { 10, NOW + 40, 20 }, { 11, NOW + 60, 20 } },
                dbRows("SELECT page, start_time, duration FROM page_stat_data WHERE start_time > " .. NOW .. " ORDER BY start_time;"))
        end)

        it("flushes stats with the old page count when the document is re-rendered", function()
            local stats = newStats{ pages = 100 }
            stats:onPageUpdate(10)
            mock_time:increase(30)
            stats:onPageUpdate(12) -- new page in the new layout, still unknown page count
            stats.document.pages = 150
            stats:onDocumentRerendered()
            assert.are.equal(150, stats.data.pages)
            assert.are.same({ { 10, 30, 100 } }, dbRows("SELECT page, duration, total_pages FROM page_stat_data;"))
            assert.are.equal(150, dbNum("SELECT pages FROM book;"))
            -- the page_stat view rescales old data to the new page count
            assert.are.same({ { 14, 15 }, { 15, 15 } }, dbRows("SELECT page, duration FROM page_stat ORDER BY page;"))
            mock_time:increase(20)
            stats:onPageUpdate(13)
            stats:insertDB()
            assert.are.same({ { 12, 20, 150 } }, dbRows("SELECT page, duration, total_pages FROM page_stat_data WHERE page = 12;"))
            -- no page count change: no flush
            mock_time:increase(20)
            stats:onPageUpdate(14)
            stats:onDocumentRerendered()
            assert.are.equal(2, dbNum("SELECT count(*) FROM page_stat_data;"))
        end)

        it("stops accounting page turns during partial re-rendering, but still saves on close", function()
            local stats = newStats()
            stats:onPageUpdate(1)
            mock_time:increase(30)
            stats:onDocumentPartiallyRerendered(false) -- not the first one: no-op
            stats:onPageUpdate(2)
            assert.are.equal(2, stats.curr_page)
            stats:onDocumentPartiallyRerendered(true)
            mock_time:increase(30)
            stats:onPageUpdate(3)
            assert.are.equal(2, stats.curr_page)
            assert.is_nil(stats.page_stat[3])
            stats:onCloseDocument()
            assert.are.same({ { 1, 30 }, { 2, 30 } }, dbRows("SELECT page, duration FROM page_stat_data ORDER BY page;"))
        end)

        it("counts added highlights and notes", function()
            local stats = newStats{ highlights = 2, notes = 1 }
            stats:onAnnotationsModified{ nb_highlights_added = 3, nb_notes_added = -1 }
            stats:onAnnotationsModified{}
            assert.are.equal(5, stats.data.highlights)
            assert.are.equal(0, stats.data.notes)
            stats:insertDB()
            assert.are.same({ { 5, 0 } }, dbRows("SELECT highlights, notes FROM book;"))
            stats.settings.is_enabled = false
            stats:onAnnotationsModified{ nb_highlights_added = 1 }
            assert.are.equal(5, stats.data.highlights)
        end)

        it("preserves the current session start across a document reload", function()
            local stats = newStats()
            mock_time:increase(300)
            stats:onPreserveCurrentSession()
            mock_time:increase(300)
            local reloaded = newStats()
            assert.are.equal(NOW, reloaded.start_current_period)
            assert.is_nil(ReaderStatistics.preserved_start_current_period)
            assert.are.equal(NOW + 600, newStats().start_current_period)
        end)
    end)

    describe("suspend and resume", function()
        it("excludes the time spent suspended from the current page", function()
            local stats = newStats()
            stats:onPageUpdate(1)
            mock_time:increase(20)
            stats:onSuspend()
            assert.are.equal(NOW + 20, stats._reading_paused_ts)
            mock_time:increase(3600)
            stats:onSuspend() -- repeated suspend keeps the first pause timestamp
            assert.are.equal(NOW + 20, stats._reading_paused_ts)
            stats:onResume()
            assert.is_nil(stats._reading_paused_ts)
            assert.are.equal(NOW + 3620, stats.start_current_period)
            mock_time:increase(10)
            stats:onPageUpdate(2)
            assert.are.same({ { NOW + 3600, 30 } }, stats.page_stat[1])
            stats:insertDB()
            assert.are.same({ { 1, 30 } }, dbRows("SELECT page, duration FROM page_stat_data;"))
        end)

        it("flushes buffered stats on suspend", function()
            local stats = newStats()
            stats:onPageUpdate(1)
            mock_time:increase(25)
            stats:onPageUpdate(2)
            stats:onSuspend()
            assert.are.equal(1, dbNum("SELECT count(*) FROM page_stat_data;"))
            assert.are.same({ [2] = { { NOW + 25, 0 } } }, stats.page_stat)
        end)

        it("defers page turns made while paused until reading resumes", function()
            local stats = newStats()
            stats:onPageUpdate(1)
            mock_time:increase(15)
            stats:onReadingPaused()
            mock_time:increase(100)
            stats:onPageUpdate(5)
            assert.are.equal(1, stats.curr_page)
            assert.are.equal(5, stats._reading_paused_curr_page)
            stats:onReadingResumed()
            assert.are.equal(5, stats.curr_page)
            assert.is_nil(stats._reading_paused_curr_page)
            -- page 1 got the 15s read before the pause, not the 100s pause
            assert.are.same({ { NOW + 100, 15 } }, stats.page_stat[1])
            assert.are.same({ { NOW + 115, 0 } }, stats.page_stat[5])
        end)

        it("ignores a page turn back to the same page while paused", function()
            local stats = newStats()
            stats:onPageUpdate(1)
            stats:onReadingPaused()
            stats:onPageUpdate(1)
            stats:onReadingResumed()
            assert.are.equal(1, stats.curr_page)
            assert.are.same({ { NOW, 0 } }, stats.page_stat[1])
        end)

        it("does nothing when statistics are disabled", function()
            freshSettings{ is_enabled = false }
            local stats = newStats()
            stats:onSuspend()
            assert.is_nil(stats._reading_paused_ts)
            stats:onResume()
            assert.are.equal(0, dbNum("SELECT count(*) FROM book;"))
        end)
    end)

    describe("toggling", function()
        local Notification, notified
        before_each(function()
            Notification = require("ui/widget/notification")
            notified = {}
            stub(Notification, "notify", function(_, text) table.insert(notified, text) end)
        end)
        after_each(function()
            Notification.notify:revert()
        end)

        it("flushes on disable and re-initializes on enable", function()
            local stats = newStats{ current_page = 7 }
            stats:onPageUpdate(1)
            mock_time:increase(20)
            stats:onPageUpdate(2)
            stats:onToggleStatistics()
            assert.is_false(stats.settings.is_enabled)
            assert.are.equal(1, dbNum("SELECT count(*) FROM page_stat_data;"))
            assert.are.same({ "Statistics disabled" }, notified)
            assert.is_nil((stats:getTimeForPages(10)))
            -- page turns are ignored while disabled
            mock_time:increase(20)
            stats:onPageUpdate(3)
            assert.are.equal(2, stats.curr_page)

            mock_time:increase(50)
            stats:onToggleStatistics(true) -- no notification
            assert.are.equal(1, #notified)
            assert.is_true(stats.settings.is_enabled)
            assert.are.equal(NOW + 90, stats.start_current_period)
            assert.are.equal(7, stats.curr_page)
            assert.are.same({ [7] = { { NOW + 90, 0 } } }, stats.page_stat)
            assert.are.equal(1, stats.book_read_pages)

            -- Dispatcher enable/disable: no-op when already in the requested state
            stats:onToggleStatistics({ true, true })
            assert.are.equal(1, #notified)
            stats:onToggleStatistics({ false, false })
            assert.is_false(stats.settings.is_enabled)
            assert.are.same({ "Statistics disabled", "Statistics disabled" }, notified)
            assert.are.equal(4, stats._footer_updates()) -- ready, disable, enable, disable
        end)
    end)

    describe("book metadata changes", function()
        it("updates the currently opened book", function()
            local stats = newStats{ file = sample_epub }
            stats:onBookMetadataChanged{ filepath = sample_epub, metadata_key_updated = "title",
                doc_props = { display_title = "New title" } }
            assert.are.equal("New title", stats.data.title)
            assert.are.equal("New title", dbText("SELECT title FROM book;"))
            stats:onBookMetadataChanged{ filepath = sample_epub, metadata_key_updated = "series_index",
                doc_props = { display_title = "New title", series = "Cycle", series_index = 3 } }
            assert.are.equal("Cycle #3", dbText("SELECT series FROM book;"))
            stats:onBookMetadataChanged{ filepath = sample_epub, metadata_key_updated = "language",
                doc_props = { display_title = "New title" } }
            assert.are.equal("N/A", dbText("SELECT language FROM book;"))
            stats:onBookMetadataChanged{ filepath = sample_epub, metadata_key_updated = "series",
                doc_props = { display_title = "New title" } }
            assert.are.equal("N/A", dbText("SELECT series FROM book;"))
            -- not stored by the plugin
            stats:onBookMetadataChanged{ filepath = sample_epub, metadata_key_updated = "keywords",
                doc_props = { display_title = "Ignored" } }
            stats:onBookMetadataChanged(nil)
            assert.are.equal("New title", dbText("SELECT title FROM book;"))
        end)

        it("finds a book that is not opened by its md5 and old metadata", function()
            local md5 = util.partialMD5(sample_epub)
            newStats{ title = "Romeo", authors = "Will", md5 = md5 }
            local other = newStats{ title = "Other", file = "/tmp/other.epub", md5 = "x" }
            other:onBookMetadataChanged{ filepath = sample_epub, metadata_key_updated = "authors",
                metadata_value_old = "Will", doc_props = { display_title = "Romeo", authors = "Shakespeare" } }
            assert.are.equal("Shakespeare", dbText("SELECT authors FROM book WHERE id = 1;"))
            other:onBookMetadataChanged{ filepath = sample_epub, metadata_key_updated = "title",
                metadata_value_old = "Romeo", doc_props = { display_title = "Romeo and Juliet", authors = "Shakespeare" } }
            assert.are.equal("Romeo and Juliet", dbText("SELECT title FROM book WHERE id = 1;"))
            assert.are.equal("Other", other.data.title)
        end)

        it("falls back to legacy empty authors, and ignores unknown books", function()
            local md5 = util.partialMD5(sample_epub)
            newStats{ no_doc = true }
            insertBook{ id = 3, title = "juliet", authors = "", md5 = md5 }
            local fm = newStats{ no_doc = true }
            -- empty old title: the display title was built from the file name
            fm:onBookMetadataChanged{ filepath = sample_epub, metadata_key_updated = "title",
                doc_props = { display_title = "Romeo" } }
            assert.are.equal("Romeo", dbText("SELECT title FROM book WHERE id = 3;"))
            fm:onBookMetadataChanged{ filepath = sample_epub, metadata_key_updated = "language",
                doc_props = { display_title = "Unknown title", language = "en" } }
            assert.are.equal("en", dbText("SELECT language FROM book WHERE id = 3;"))
            assert.are.equal(1, dbNum("SELECT count(*) FROM book WHERE language = 'en';"))
        end)

        it("does not crash when the update would duplicate another book", function()
            local stats = newStats{ file = sample_epub, title = "A", authors = "X", md5 = "same" }
            insertBook{ id = 2, title = "B", authors = "X", md5 = "same" }
            stats:onBookMetadataChanged{ filepath = sample_epub, metadata_key_updated = "title",
                doc_props = { display_title = "B" } }
            assert.are.same({ { 1, "A" }, { 2, "B" } }, dbRows("SELECT id, title FROM book ORDER BY id;"))
        end)
    end)

    describe("queries", function()
        local stats
        -- Book A (current, id 1, 100 pages) and book B (id 2, 50 pages)
        before_each(function()
            stats = newStats{ title = "Book A", pages = 100, current_page = 50, highlights = 3, notes = 2 }
            insertBook{ id = 2, title = "Book B", authors = "Author B", pages = 50, last_open = NOW + 10,
                total_read_time = 110, total_read_pages = 1 }
            dbExec(string.format("UPDATE book SET last_open = %d WHERE id = 1;", NOW - 10))
            insertPageStat(1, 1, NOW - 3 * 3600, 60, 100)          -- today 09:00
            insertPageStat(1, 2, NOW - 3 * 3600 + 60, 30, 100)     -- today 09:01
            insertPageStat(1, 1, NOW - 86400, 200, 100)            -- yesterday noon
            insertPageStat(1, 3, NOW - 40 * 86400, 50, 100)        -- 40 days ago (February)
            insertPageStat(2, 1, NOW - 2 * 3600, 100, 50)          -- today 10:00
            insertPageStat(2, 1, NOW, 10, 50)                      -- now (current session)
        end)

        it("computes today's and the current session's reading", function()
            assert.are.same({ 200, 3 }, { stats:getTodayBookStats() })
            assert.are.same({ 10, 1 }, { stats:getCurrentBookStats() })
            assert.are.same({ days = 3, time = 340, pages = 3 }, stats:getStatsBookStatus())
            assert.are.equal(NOW - 40 * 86400, stats:getFirstTimestamp())
        end)

        it("lists reading days of the last week, with drill-down to books", function()
            local res = stats:getDatesFromAll(7, "daily_weekday")
            assert.are.equal(2, #res)
            assert.is_truthy(res[1][1]:find("2026-03-18", 1, true))
            assert.is_truthy(res[1][2]:find("(3 pages)", 1, true))
            assert.is_truthy(res[1][2]:find(datetime.secondsToClockDuration(nil, 200, false), 1, true))
            assert.is_truthy(res[2][1]:find("2026-03-17", 1, true))
            assert.is_truthy(res[2][2]:find("(1 page)", 1, true))

            res[1].callback()
            local kv = lastShown("KeyValuePage")
            assert.are.equal(res[1][1], kv.title)
            assert.are.same({ "Book B", "Book A" }, { kv.kv_pairs[1][1], kv.kv_pairs[2][1] })
            assert.are.same({ 110, 90 }, { kv.kv_pairs[1].duration, kv.kv_pairs[2].duration })
            assert.are.same({ 2, 1 }, { kv.kv_pairs[1].book_id, kv.kv_pairs[2].book_id })

            -- book entry shows the book statistics
            kv.kv_pairs[2].callback()
            local book_kv = lastShown("KeyValuePage")
            assert.are.equal("Book A", book_kv.title)
            assert.are.equal("Book A", book_kv.kv_pairs[1][2])
            book_kv.callback_return()
            assert.are.equal(kv, stats.kv)

            local all = stats:getDatesFromAll(365, "daily")
            assert.are.equal(3, #all)
            assert.are.equal("2026-02-06", all[3][1])
        end)

        it("groups by week and by month", function()
            local weeks = stats:getDatesFromAll(0, "weekly", true)
            assert.are.equal(2, #weeks)
            assert.is_truthy(weeks[1][1]:find("2026", 1, true))
            assert.is_truthy(weeks[1][1]:find("11", 1, true))
            assert.is_truthy(weeks[1][2]:find("(3 pages)", 1, true))
            weeks[1].callback() -- book mode: books of that week
            local kv = lastShown("KeyValuePage")
            assert.are.equal(2, #kv.kv_pairs)

            weeks = stats:getDatesFromAll(365, "weekly")
            weeks[1].callback() -- days of that week
            kv = lastShown("KeyValuePage")
            assert.are.same({ "2026-03-18", "2026-03-17" }, { kv.kv_pairs[1][1], kv.kv_pairs[2][1] })
            -- day entry shows the books of that day
            kv.kv_pairs[2].callback()
            local day_kv = lastShown("KeyValuePage")
            assert.are.equal(1, #day_kv.kv_pairs)
            assert.are.equal("Book A", day_kv.kv_pairs[1][1])

            local months = stats:getDatesFromAll(0, "monthly")
            assert.are.equal(2, #months)
            assert.are.equal("March 2026", months[1][1])
            assert.are.equal("February 2026", months[2][1])
            months[2].callback()
            kv = lastShown("KeyValuePage")
            assert.are.equal("February 2026", kv.title)
            assert.are.equal("2026-02-06", kv.kv_pairs[1][1])
            months = stats:getDatesFromAll(0, "monthly", true)
            months[1].callback()
            kv = lastShown("KeyValuePage")
            assert.are.equal(2, #kv.kv_pairs)
        end)

        it("returns empty lists for periods without data", function()
            assert.are.same({}, stats:getDaysFromPeriod(NOW + 86400, NOW + 2 * 86400))
            assert.are.same({}, stats:getBooksFromPeriod(NOW + 86400, NOW + 2 * 86400))
            assert.are.same({}, stats:getDatesForBook(42))
            dbExec("DELETE FROM page_stat_data;")
            assert.are.same({}, stats:getDatesFromAll(7, "daily"))
            assert.is_nil(stats:getReadingProgressStats(7))
            assert.are.same({ 0, 0 }, { stats:getTodayBookStats() })
            assert.are.same({ 0, 0 }, { stats:getCurrentBookStats() })
            assert.is_nil(stats:getFirstTimestamp())
        end)

        it("provides the last days for the reading progress widget", function()
            local progress = stats:getReadingProgressStats(7)
            assert.are.equal(7, #progress)
            assert.are.same({ 3, 200, "2026-03-18" }, progress[1])
            assert.are.same({ 1, 200, "2026-03-17" }, progress[2])
            assert.are.same({ 0, 0 }, { progress[3][1], progress[3][2] })

            local widget = stats:onShowReaderProgress(true)
            assert.is_not_nil(widget)
            assert.is_true(widget.readonly)
            assert.are.equal(200, widget.today_duration)
            assert.are.equal(1, tonumber(widget.current_pages))
            assert.are.equal(0, #shown)
            stats:onShowReaderProgress()
            assert.are.equal(widget.dates[1][3], shown[#shown].dates[1][3])

            dbExec("DELETE FROM page_stat_data;")
            assert.is_nil(stats:onShowReaderProgress(true))
            stats:onShowReaderProgress()
            assert.is_truthy(shown[#shown].text:find("not available", 1, true))
        end)

        it("lists the reading days of a book, and resets a single day", function()
            local days = stats:getDatesForBook(1)
            assert.are.same({ "2026-03-18", "2026-03-17", "2026-02-06" }, { days[1][1], days[2][1], days[3][1] })
            assert.is_truthy(days[1][2]:find("(2 pages)", 1, true))
            local removed
            local kv_page = { removeKeyValueItem = function(_, item) removed = item end }
            days[2].hold_callback(kv_page, days[2])
            local confirm = lastShown("ConfirmBox")
            assert.is_truthy(confirm.text:find("2026-03-17", 1, true))
            confirm.cancel_callback()
            assert.are.equal(4, dbNum("SELECT count(*) FROM page_stat_data WHERE id_book = 1;"))
            confirm.ok_callback()
            assert.are.equal(days[2], removed)
            assert.are.equal(3, dbNum("SELECT count(*) FROM page_stat_data WHERE id_book = 1;"))
            assert.are.equal(0, dbNum(string.format("SELECT count(*) FROM page_stat_data WHERE start_time = %d;", NOW - 86400)))
        end)

        it("resets the stats of a book for a period", function()
            local reset_done = false
            stats:resetStatsForBookForPeriod(2, TODAY0, TODAY0 + 86400, false, function() reset_done = true end)
            local confirm = lastShown("ConfirmBox")
            assert.is_truthy(confirm.text:find("Book B", 1, true))
            confirm.cancel_callback()
            assert.is_false(reset_done)
            confirm.ok_callback()
            assert.is_true(reset_done)
            assert.are.equal(0, dbNum("SELECT count(*) FROM page_stat_data WHERE id_book = 2;"))
            assert.are.equal(4, dbNum("SELECT count(*) FROM page_stat_data WHERE id_book = 1;"))
            -- the alternate drill-down shows the reading days of the book
            local books = stats:getBooksFromPeriod(TODAY0, TODAY0 + 86400, true)
            books[1].callback()
            local kv = lastShown("KeyValuePage")
            assert.are.equal(3, #kv.kv_pairs)
        end)

        it("summarizes all books, most recently opened first", function()
            local title, list = stats:getTotalStats()
            assert.are.equal("Total time spent reading: " .. datetime.secondsToClockDuration(nil, 450, false), title)
            assert.are.equal(2, #list)
            assert.are.equal("Book B", list[1][1])
            assert.are.equal(datetime.secondsToClockDuration(nil, 340, false), list[2][2])
            list[2].callback()
            assert.are.equal("Book A", lastShown("KeyValuePage").title)
        end)

        it("computes a book's statistics", function()
            local kv = stats:getBookStat(1)
            local by_key = {}
            for _, item in ipairs(kv) do by_key[item[1]] = item end
            assert.are.equal("Book A", by_key["Title"][2])
            assert.are.equal("Author A", by_key["Author(s)"][2])
            assert.are.equal(datetime.secondsToClockDuration(nil, 340, false), by_key["Total time spent on this book"][2])
            assert.are.equal(datetime.secondsToClockDuration(nil, 200, false), by_key["Time spent reading"][2])
            assert.are.equal("3 (3%)", by_key["Pages read"][2])
            -- the last read page is the one with the latest start time
            assert.are.equal("2 / 100 (2%)", by_key["Last read page/Total pages"][2])
            assert.are.equal(3, by_key["Book highlights"][2])
            assert.are.equal(2, by_key["Book notes"][2])
            local days_item = kv[5]
            assert.are.equal(3, days_item[2])
            days_item.callback()
            assert.are.equal(3, #lastShown("KeyValuePage").kv_pairs)
            assert.is_nil(stats:getBookStat(nil))
            -- NULL highlights/notes (old DB bug) are shown as "?"
            dbExec("UPDATE book SET highlights = NULL, notes = NULL, pages = 0 WHERE id = 2;")
            kv = stats:getBookStat(2)
            assert.are.equal("?", kv[#kv][2])
            assert.are.equal("?", kv[#kv - 1][2])
        end)

        it("computes the current book's statistics and estimates", function()
            stats.avg_time = 20
            local kv = stats:getCurrentStat()
            local by_key = {}
            for _, item in ipairs(kv) do
                local key = item[1]:gsub(" ▸$", "")
                key = key:gsub(" ⓘ$", "")
                by_key[key] = item
            end
            assert.are.equal(1, by_key["Pages read this session"][2])
            assert.are.equal(3, by_key["Pages read today"][2])
            assert.are.equal(3, by_key["Days reading this book"][2])
            assert.are.equal("50 / 100 (50%)", by_key["Current page/Total pages"][2])
            assert.are.equal("3 (3%)", by_key["Pages read"][2])
            assert.are.equal(3, by_key["Book highlights"][2])
            -- 50 pages left at the average (capped) rate
            local avg = stats.avg_time
            assert.are.equal(datetime.secondsToClockDuration("classic", 50 * avg, false), by_key["Estimated reading time left"][2])
            by_key["Estimated reading time left"].callback()
            assert.is_truthy(lastShown("InfoMessage").text:find("50 pages", 1, true))
            by_key["Days reading this book"].callback()
            assert.are.equal(3, #lastShown("KeyValuePage").kv_pairs)
        end)

        it("shows page labels and hidden flows in the current book statistics", function()
            stats.ui.pagemap = {
                wantsPageLabels = function() return true end,
                getCurrentPageLabel = function() return "xii", 12, 48 end,
                getLastPageLabel = function() return "300" end,
            }
            local kv = stats:getCurrentStat()
            local found
            for _, item in ipairs(kv) do
                if item[1] == "Current page/Total pages" then found = item[2] end
            end
            assert.are.equal("xii / 300 (25%)", found)

            local flows = newStats{ title = "Book A", current_page = 20, hidden_flows = true, flow = 0, flow_pages = 80 }
            kv = flows:getCurrentStat()
            for _, item in ipairs(kv) do
                if item[1] == "Current page/Total pages" then found = item[2] end
            end
            assert.are.equal("20 // 80 (25%)", found)
            flows = newStats{ title = "Book A", current_page = 20, hidden_flows = true, flow = 2, flow_pages = 40 }
            kv = flows:getCurrentStat()
            for _, item in ipairs(kv) do
                if item[1] == "Current page/Total pages" then found = item[2] end
            end
            assert.are.equal("[20 / 40]2 (50%)", found)
        end)

        it("shows the finished date instead of estimates for frozen books", function()
            freshSettings{ freeze_finished_books = true }
            local frozen = newStats{ title = "Book A", summary = { status = "complete", modified = "2026-03-10" } }
            assert.are.equal(1, frozen.id_curr_book)
            local kv = frozen:getCurrentStat()
            local by_key = {}
            for _, item in ipairs(kv) do by_key[item[1]] = item end
            assert.are.equal("finished", by_key["Estimated reading time left"][2])
            assert.are.equal(datetime.secondsToDate(os.time{ year = 2026, month = 3, day = 10, hour = 0 }, true),
                by_key["Book marked as finished"][2])
        end)

        it("computes the per-page read ratios used by the book map", function()
            local pages = stats:getCurrentBookReadPages()
            assert.are.same({ 1, 30 / 120, 50 / 120 }, { pages[1][1], pages[2][1], pages[3][1] })
            assert.is_nil(pages[4])
            freshSettings{ is_enabled = false }
            assert.is_nil(newStats():getCurrentBookReadPages())
        end)

        it("estimates the reading time of a number of pages", function()
            stats.avg_time = 30
            assert.are.equal(datetime.secondsToClockDuration("classic", 300, true), stats:getTimeForPages(10))
            stats.avg_time = 0 / 0
            assert.is_nil(stats:getTimeForPages(10))
        end)

        it("feeds the calendar with per-hour ratios and books per day", function()
            local per_hour = stats:getReadingRatioPerHourByDay("2026-03")
            assert.are.same({ [10] = 90 / 3600, [11] = 100 / 3600, [13] = 10 / 3600 }, per_hour["2026-03-18"])
            assert.are.same({ [13] = 200 / 3600 }, per_hour["2026-03-17"])
            assert.is_nil(per_hour["2026-02-06"])
            -- with a day start shift of 4h, the 09:00 reading is shown at 05:00
            stats.settings.calendar_use_day_time_shift = true
            stats.settings.calendar_day_start_hour = 4
            per_hour = stats:getReadingRatioPerHourByDay("2026-03")
            assert.are.equal(90 / 3600, per_hour["2026-03-18"][6])
            stats.settings.calendar_use_day_time_shift = nil

            local per_day = stats:getReadBookByDay("2026-03")
            assert.are.same({ { id = 2, title = "Book B" }, { id = 1, title = "Book A" } }, per_day["2026-03-18"])
            assert.are.same({ { id = 1, title = "Book A" } }, per_day["2026-03-17"])
            assert.are.same({ { id = 1, title = "Book A" } }, stats:getReadBookByDay("2026-02")["2026-02-06"])
        end)

        it("builds the daily timeline, merging close page spans", function()
            local per_book = stats:getReadingDurationBySecond(TODAY0)
            assert.are.equal("Book A", per_book[1].title)
            assert.are.same({ { start = 9 * 3600, finish = 9 * 3600 + 90 } }, per_book[1].periods)
            assert.are.same({
                { start = 10 * 3600, finish = 10 * 3600 + 100 },
                { start = 12 * 3600, finish = 12 * 3600 + 10 },
            }, per_book[2].periods)
        end)

        it("continues timeline spans across midnight", function()
            -- Book A read the day before: long before midnight (ignored), then until 23:59:50
            insertPageStat(1, 8, TODAY0 - 100, 20, 100)
            insertPageStat(1, 9, TODAY0 - 60, 50, 100)
            -- then from 23:59:30 to 00:01:00
            insertPageStat(1, 10, TODAY0 - 30, 40, 100)
            insertPageStat(1, 11, TODAY0 + 10, 50, 100)
            -- and from 23:59:00 today, continued at 00:00:05 tomorrow
            insertPageStat(1, 12, TODAY0 + 86400 - 60, 50, 100)
            insertPageStat(1, 13, TODAY0 + 86400 + 5, 40, 100)
            local periods = stats:getReadingDurationBySecond(TODAY0)[1].periods
            assert.are.same({ start = 0, finish = 60 }, periods[1])
            assert.are.same({ start = 86400 - 60, finish = 86400 - 1 }, periods[#periods])
        end)
    end)

    describe("reset and delete", function()
        it("deletes a book and its page stats", function()
            local stats = newStats()
            insertPageStat(1, 1, NOW, 30, 100)
            stats:deleteBook(1)
            assert.are.equal(0, dbNum("SELECT count(*) FROM book;"))
            assert.are.equal(0, dbNum("SELECT count(*) FROM page_stat_data;"))
        end)

        it("resets the current book and re-registers it", function()
            local stats = newStats()
            stats:onPageUpdate(1)
            mock_time:increase(30)
            stats:onPageUpdate(2)
            stats:resetCurrentBook()
            -- flushed before asking
            assert.are.equal(1, dbNum("SELECT count(*) FROM page_stat_data;"))
            local confirm = lastShown("ConfirmBox")
            assert.is_truthy(confirm.text:find("Book A", 1, true))
            confirm.cancel_callback()
            assert.are.equal(1, stats.id_curr_book)
            confirm.ok_callback()
            assert.are.equal(2, stats.id_curr_book)
            assert.are.same({ { 2, "Book A" } }, dbRows("SELECT id, title FROM book;"))
            assert.are.equal(0, dbNum("SELECT count(*) FROM page_stat_data;"))
            assert.are.equal(0, stats.book_read_pages)
            assert.are.equal(60, stats.avg_time)
            assert.are.same({ [2] = { { NOW + 30, 0 } } }, stats.page_stat)
        end)

        it("lists other books for reset", function()
            local stats = newStats()
            insertBook{ id = 5, title = "Old", last_open = NOW - 1000 }
            insertPageStat(5, 1, NOW - 1000, 70, 100)
            stats:resetPerBook()
            local kv = lastShown("KeyValuePage")
            assert.are.equal(1, #kv.kv_pairs)
            assert.are.equal("Old", kv.kv_pairs[1][1])
            local removed
            kv.kv_pairs[1].callback({ removeKeyValueItem = function(_, item) removed = item end }, "item")
            local confirm = lastShown("ConfirmBox")
            confirm.cancel_callback()
            confirm.ok_callback()
            assert.are.equal("item", removed)
            assert.are.equal(0, dbNum("SELECT count(*) FROM book WHERE id = 5;"))
            assert.are.equal(1, dbNum("SELECT count(*) FROM book;"))
        end)

        it("removes books read for less than a given time, except the current one", function()
            local stats = newStats()
            insertBook{ id = 2, title = "Short", total_read_time = 30 }
            insertBook{ id = 3, title = "Long", total_read_time = 600 }
            insertBook{ id = 4, title = "Never", total_read_time = nil }
            insertPageStat(2, 1, NOW, 30, 100)
            stats:deleteBooksByTotalDuration(1)
            local confirm = lastShown("ConfirmBox")
            assert.is_truthy(confirm.text:find("less than 1 minute", 1, true))
            confirm.ok_callback()
            assert.are.same({ { 1 }, { 3 } }, dbRows("SELECT id FROM book ORDER BY id;"))
            assert.are.equal(0, dbNum("SELECT count(*) FROM page_stat_data;"))
            assert.are.equal("Statistics for 2 books removed.", shown[#shown].text)
            stats:deleteBooksByTotalDuration(1)
            lastShown("ConfirmBox").ok_callback()
            assert.are.equal("No statistics removed.", shown[#shown].text)
        end)

        it("compacts the DB after removing many books, also without a document", function()
            newStats{ no_doc = true }
            for i = 1, 12 do
                insertBook{ id = i, title = "B" .. i, total_read_time = 60 }
            end
            local fm = newStats{ no_doc = true }
            fm:deleteBooksByTotalDuration(30)
            lastShown("ConfirmBox").ok_callback()
            assert.are.equal(0, dbNum("SELECT count(*) FROM book;"))
            assert.are.equal("Statistics for 12 books removed.", shown[#shown].text)
        end)

        it("generates the reset menu", function()
            local stats = newStats()
            local items = stats:genResetBookSubItemTable()
            assert.are.equal(7, #items)
            assert.is_truthy(items[1].enabled_func())
            assert.are.equal("Reset stats for books read for < 60 m", items[7].text)
            items[7].callback()
            assert.is_truthy(lastShown("ConfirmBox").text:find("60 minutes", 1, true))
            items[2].callback()
            assert.is_not_nil(lastShown("KeyValuePage"))
            items[1].callback()
            assert.is_truthy(lastShown("ConfirmBox").text:find("Book A", 1, true))
        end)
    end)

    describe("menus and views", function()
        it("registers the main menu with working settings", function()
            local stats = newStats()
            local menu_items = {}
            stats:addToMainMenu(menu_items)
            local sub = menu_items.statistics.sub_item_table
            assert.is_true(sub[1].checked_func())
            local settings = sub[2].sub_item_table
            assert.are.equal("Read page duration limits: 5 s – 120 s", settings[1].text_func())
            local touchmenu = { updateItems = spy.new(function() end) }
            settings[1].callback(touchmenu)
            local spin = shown[#shown]
            spin.callback(10, 300)
            assert.are.same({ 10, 300 }, { stats.settings.min_sec, stats.settings.max_sec })
            assert.spy(touchmenu.updateItems).was.called(1)

            -- freezing finished books
            assert.is_false(settings[2].checked_func())
            settings[2].callback()
            assert.is_true(stats.settings.freeze_finished_books)
            assert.is_true(stats.is_doc_not_frozen) -- book not finished
            settings[2].callback()

            -- calendar settings
            assert.is_truthy(settings[3].text_func():find("Monday", 1, true))
            for i, day in ipairs({ 6, 7, 1, 2 }) do
                settings[3].sub_item_table[i].callback()
                assert.are.equal(day, stats.settings.calendar_start_day_of_week)
                assert.is_true(settings[3].sub_item_table[i].checked_func())
            end
            assert.are.equal("Books per calendar day: 3", settings[4].text_func())
            settings[4].callback(touchmenu)
            shown[#shown].callback({ value = 5 })
            assert.are.equal(5, stats.settings.calendar_nb_book_spans)
            settings[5].callback()
            assert.is_false(settings[5].checked_func())
            settings[6].callback()
            assert.is_true(settings[6].checked_func())
            assert.are.equal("Daily timeline starts at 00:00", settings[7].text_func())
            settings[7].callback(touchmenu)
            shown[#shown].callback({ hour = 4, min = 30 })
            assert.are.equal("Daily timeline starts at 04:30", settings[7].text_func())
            settings[8].callback()
            assert.is_true(settings[8].checked_func())
            -- no cloud storage plugin
            assert.are.equal("Cloud sync: not set", settings[9].text_func())
            assert.is_false(settings[9].enabled_func())

            -- "Current book" is only available for an enabled, opened book
            local current = sub[5]
            assert.is_true(current.enabled_func())
            current.callback()
            assert.are.equal("Current statistics", lastShown("KeyValuePage").title)

            sub[1].callback() -- disable, silently
            assert.is_false(stats.settings.is_enabled)
            assert.is_false(sub[1].checked_func())
        end)

        it("shows the current book statistics only when enabled", function()
            local stats = newStats()
            stats:onShowBookStats()
            assert.are.equal("Current statistics", lastShown("KeyValuePage").title)
            local fm = newStats{ no_doc = true }
            local nb = #shown
            fm:onShowBookStats()
            assert.are.equal(nb, #shown)
            assert.is_nil(fm:getCurrentBookReadPages())
        end)

        it("shows the time range views", function()
            local stats = newStats()
            insertPageStat(1, 1, NOW - 3600, 30, 100)
            stats:onShowTimeRange()
            local top = stats.kv
            assert.are.equal(8, #top.kv_pairs)
            local titles = {}
            for i, item in ipairs(top.kv_pairs) do
                item.callback()
                assert.are_not.equal(top, stats.kv)
                titles[i] = stats.kv.title
                stats.kv.callback_return()
                assert.are.equal(top, stats.kv)
            end
            assert.are.same({
                "Total time spent reading: " .. datetime.secondsToClockDuration(nil, 30, false),
                "Books by week", "Books by month", "Last week", "Last month by day",
                "Last year by day", "Last year by week", "All stats by month",
            }, titles)
        end)

        it("registers dispatcher actions", function()
            local Dispatcher = require("dispatcher")
            local registered = {}
            local orig = Dispatcher.registerAction
            Dispatcher.registerAction = function(_, name) table.insert(registered, name) end
            local ok, err = pcall(newStats)
            Dispatcher.registerAction = orig
            assert(ok, err)
            assert.is_truthy(util.arrayContains(registered, "toggle_statistics"))
            assert.is_truthy(util.arrayContains(registered, "stats_sync"))
            assert.is_truthy(util.arrayContains(registered, "book_statistics"))
        end)
    end)

    describe("cloud sync", function()
        local function makeDB(path)
            os.remove(path)
            local conn = SQ3.open(path)
            ReaderStatistics:createDB(conn)
            conn:close()
        end

        it("only syncs with a cloud storage and a configured server", function()
            local cs = { sync = spy.new(function() end) }
            local stats = newStats{ cloudstorage = cs }
            assert.is_true(stats:canSync(true))
            assert.is_false(stats:canSync())
            stats:onSyncBookStats(true)
            assert.spy(cs.sync).was.called(0)
            stats.settings.sync_server = { type = "webdav", url = "/stats" }
            stats:onSyncBookStats(true)
            assert.spy(cs.sync).was.called(1)
            local args = cs.sync.calls[1].vals
            assert.are.same(stats.settings.sync_server, args[2])
            assert.are.equal(db_path, args[3])
            assert.are.equal(ReaderStatistics.onSync, args[4])
            assert.is_false(args[5]) -- not silent
            args[6]()
            assert.is_truthy(shown[#shown].text:find("Syncing", 1, true))
            -- a periodic, non-interactive sync is silent
            stats:onSyncBookStats()
            args = cs.sync.calls[2].vals
            assert.is_true(args[5])
            assert.is_nil(args[6])
            assert.is_false(newStats():canSync(true))
        end)

        it("treats a missing remote DB as a first sync", function()
            local stats = newStats()
            insertPageStat(stats.id_curr_book, 1, NOW, 30, 100)
            local income = settings_dir .. "/income.sqlite3"
            os.remove(income)
            assert.is_true(ReaderStatistics.onSync(db_path, settings_dir .. "/cached.sqlite3", income))
            assert.are.equal(1, dbNum("SELECT count(*) FROM page_stat_data;"))
        end)

        it("merges a remote DB into the local one", function()
            local stats = newStats{ title = "Shared", md5 = "s" }
            insertPageStat(1, 1, 1000, 30, 100)
            insertPageStat(1, 2, 1100, 40, 100)
            local income = settings_dir .. "/income.sqlite3"
            makeDB(income)
            insertBook({ id = 1, title = "Remote only", authors = "R", md5 = "r", last_open = 5, pages = 50 }, income)
            insertBook({ id = 2, title = "Shared", authors = "Author A", md5 = "s", last_open = NOW + 500 }, income)
            insertPageStat(1, 7, 3000, 20, 50, income)
            insertPageStat(2, 2, 1100, 90, 100, income) -- same page read longer on the other device
            insertPageStat(2, 3, 1200, 15, 100, income)
            local cached = settings_dir .. "/cached.sqlite3"
            os.remove(cached)

            assert.is_true(ReaderStatistics.onSync(db_path, cached, income))

            assert.are.same({ { 1, "Shared", NOW + 500, 3, 135 }, { 2, "Remote only", 5, 1, 20 } },
                dbRows("SELECT id, title, last_open, total_read_pages, total_read_time FROM book ORDER BY id;"))
            assert.are.same({ { 1, 1, 30 }, { 1, 2, 90 }, { 1, 3, 15 }, { 2, 7, 20 } },
                dbRows("SELECT id_book, page, duration FROM page_stat_data ORDER BY id_book, page;"))
            -- the local session keeps working on the same book id
            assert.are.equal(1, stats:getIdBookDB())
            -- syncing again is idempotent
            assert.is_true(ReaderStatistics.onSync(db_path, cached, income))
            assert.are.equal(4, dbNum("SELECT count(*) FROM page_stat_data;"))
        end)

        it("propagates deletions using the DB cached at the previous sync", function()
            newStats{ no_doc = true }
            insertBook{ id = 1, title = "Kept", md5 = "k" }
            insertBook{ id = 2, title = "Deleted remotely", md5 = "dr" }
            insertPageStat(1, 1, 1000, 30, 100)
            insertPageStat(1, 2, 1100, 30, 100)
            insertPageStat(2, 1, 1000, 30, 100)
            -- previous sync state: everything above, plus a book since deleted locally
            local cached = settings_dir .. "/cached.sqlite3"
            os.remove(cached)
            require("ffi/util").copyFile(db_path, cached)
            insertBook({ id = 3, title = "Deleted locally", md5 = "dl" }, cached)
            insertPageStat(3, 1, 1000, 30, 100, cached)
            -- a page stat deleted locally since last sync
            dbExec("DELETE FROM page_stat_data WHERE id_book = 1 AND page = 2;")
            -- remote: deleted "Deleted remotely", still has "Deleted locally" and the deleted page stat
            local income = settings_dir .. "/income.sqlite3"
            makeDB(income)
            insertBook({ id = 10, title = "Kept", md5 = "k" }, income)
            insertBook({ id = 11, title = "Deleted locally", md5 = "dl" }, income)
            insertPageStat(10, 1, 1000, 30, 100, income)
            insertPageStat(10, 2, 1100, 30, 100, income)
            insertPageStat(11, 1, 1000, 30, 100, income)

            assert.is_true(ReaderStatistics.onSync(db_path, cached, income))

            assert.are.same({ { "Kept" } }, dbRows("SELECT title FROM book;"))
            assert.are.same({ { 1, 1 } }, dbRows("SELECT id_book, page FROM page_stat_data;"))
        end)

        it("manages the sync server from the settings dialog", function()
            local cs = {
                getServerNameType = function(_, server) return server and ("srv:" .. server.url) end,
                getReadablePath = function(server) return server.url end,
                onShowCloudStorageList = function(_, cb) cb({ type = "webdav", url = "/new" }) end,
            }
            local stats = newStats{ cloudstorage = cs }
            local touchmenu = { updateItems = spy.new(function() end) }
            stats:setSyncRemoteFolder(touchmenu)
            local dialog = shown[#shown]
            assert.is_truthy(dialog.title:find("not set", 1, true))
            -- Edit: pick a server, dialog re-opened
            dialog.buttons[1][2].callback()
            assert.are.same({ type = "webdav", url = "/new" }, stats.settings.sync_server)
            dialog = shown[#shown]
            assert.is_truthy(dialog.title:find("srv:/new", 1, true))
            -- Changing server forgets the cached sync DB
            local f = io.open(db_path .. ".sync", "w")
            f:write("x")
            f:close()
            cs.onShowCloudStorageList = function(_, cb) cb({ type = "webdav", url = "/other" }) end
            dialog.buttons[1][2].callback()
            assert.is_nil(lfs.attributes(db_path .. ".sync"))
            -- Delete
            dialog = shown[#shown]
            dialog.buttons[1][1].callback()
            lastShown("ConfirmBox").ok_callback()
            assert.is_nil(stats.settings.sync_server)
            dialog.buttons[1][3].callback()
            assert.are.equal(dialog, closed[#closed])
        end)
    end)

    describe("calendar view", function()
        -- NOTE: calendarview.lua caches the first month with data (MIN_MONTH) for the whole
        --       session: the first CalendarView of this file must see the February data.
        local stats

        local function findDay(cal, daynum)
            for _, row in ipairs(cal.layout) do
                for _, day in ipairs(row) do
                    if day.daynum == daynum then return day end
                end
            end
        end

        -- (CalendarWeek decorates read_books entries with span layout fields)
        local function books(day)
            local r = {}
            for i, b in ipairs(day.read_books or {}) do r[i] = { b.id, b.title } end
            return r
        end

        local function countDays(cal)
            local n = 0
            for _, row in ipairs(cal.layout) do n = n + #row end
            return n
        end

        before_each(function()
            stats = newStats{ title = "Book A" }
            insertBook{ id = 2, title = "Book B", pages = 50, last_open = NOW + 10 }
            insertPageStat(1, 1, NOW - 3 * 3600, 60, 100)          -- today 09:00
            insertPageStat(1, 2, NOW - 3 * 3600 + 60, 30, 100)     -- today 09:01
            insertPageStat(1, 1, NOW - 86400, 200, 100)            -- yesterday noon
            insertPageStat(1, 3, NOW - 40 * 86400, 50, 100)        -- 2026-02-06
            insertPageStat(2, 1, NOW - 2 * 3600, 100, 50)          -- today 10:00
        end)

        it("flushes, then shows the current month with the books and hours read per day", function()
            stats:onPageUpdate(5)
            mock_time:increase(30)
            stats:onPageUpdate(6)
            stats:onShowCalendarView()
            assert.are.equal(6, dbNum("SELECT count(*) FROM page_stat_data;"))
            local cal = shown[#shown]
            assert.are.equal(stats, cal.reader_statistics)
            assert.are.equal("2026-03", cal.cur_month)
            assert.are.equal("2026-02", cal.min_month)
            assert.are.equal("2026-03", cal.max_month)
            assert.are.equal("2026-03", cal.page_info_text.text)
            -- March 2026 starts on a Sunday: with weeks starting on Monday, it spans 6 weeks
            assert.are.equal(6, #cal.weeks)
            assert.are.equal(31, countDays(cal))
            local day18 = findDay(cal, 18)
            -- most read book first: A (90s + the 30s just flushed), then B (100s)
            assert.are.same({ { 1, "Book A" }, { 2, "Book B" } }, books(day18))
            assert.are.equal(90 / 3600, day18.ratio_per_hour[10])
            assert.are.equal(100 / 3600, day18.ratio_per_hour[11])
            assert.are.equal(30 / 3600, day18.ratio_per_hour[13])
            assert.are.same({ { 1, "Book A" } }, books(findDay(cal, 17)))
            assert.are.same({}, books(findDay(cal, 16)))
            assert.is_falsy(day18.is_future)
            assert.is_true(findDay(cal, 19).is_future)
            assert.is_false(findDay(cal, 19).callback) -- future days cannot be opened
        end)

        it("starts weeks on the configured day", function()
            local CalendarView = require("calendarview")
            local cal = CalendarView:new{ reader_statistics = stats, start_day_of_week = 1 }
            assert.are.equal(5, #cal.weeks)
            assert.are.equal(31, countDays(cal))
        end)

        it("browses months within the range having data", function()
            stats:onShowCalendarView()
            local cal = shown[#shown]
            cal:nextMonth() -- no future months by default
            assert.are.equal("2026-03", cal.cur_month)
            cal:onPrevMonth()
            assert.are.equal("2026-02", cal.cur_month)
            assert.are.same({ { 1, "Book A" } }, books(findDay(cal, 6)))
            assert.are.equal(28, countDays(cal))
            cal:prevMonth() -- nothing before the first month with data
            assert.are.equal("2026-02", cal.cur_month)
            cal:onSwipe(nil, { direction = "west" })
            assert.are.equal("2026-03", cal.cur_month)
            cal:onSwipe(nil, { direction = "east" })
            assert.are.equal("2026-02", cal.cur_month)
            cal:onNextMonth()
            cal.browse_future_months = true
            cal:nextMonth()
            assert.are.equal("2026-04", cal.cur_month)
            assert.is_true(findDay(cal, 1).is_future)
            cal:goToMonth("2025-12")
            assert.are.equal(31, countDays(cal))
            assert.is_false(cal:onSwipe(nil, { direction = "northeast" }))
            cal:onSwipe(nil, { direction = "south" })
            assert.are.equal(cal, closed[#closed])
            cal:onMultiSwipe()
            assert.are.equal(cal, closed[#closed])
        end)

        it("opens a day's timeline and moves between days", function()
            local scheduled = {}
            UIManager.tickAfterNext = function(_, fn) table.insert(scheduled, fn) end
            stats:onShowCalendarView()
            local cal = shown[#shown]
            findDay(cal, 18).callback()
            local day_view = shown[#shown]
            assert.are.equal(TODAY0, day_view.day_ts)
            assert.are.equal("2026-03-18 (Wednesday)", day_view:getTitle())
            assert.is_true(day_view.is_current_day)
            assert.are.equal(12, day_view.current_day_hour)
            -- books sorted by duration, with their reading periods
            assert.are.same({ "Book B", "Book A" }, { day_view.kv_pairs[1][1], day_view.kv_pairs[2][1] })
            assert.are.same({ { start = 10 * 3600, finish = 10 * 3600 + 100 } }, day_view.kv_pairs[1].periods)
            assert.are.same({ { start = 9 * 3600, finish = 9 * 3600 + 90 } }, day_view.kv_pairs[2].periods)
            assert.are.equal(2, #day_view.book_items)
            -- unchecking a book hides it from the timeline
            day_view.kv_pairs[1]:check_cb()
            assert.is_false(day_view.kv_pairs[1].checked)

            day_view:onPrevPage()
            assert.are.equal(TODAY0 - 86400, day_view.day_ts)
            assert.are.equal("2026-03-17 (Tuesday)", day_view:getTitle())
            assert.is_false(day_view.is_current_day)
            assert.are.equal(1, #day_view.kv_pairs)
            day_view:onSwipe(nil, { direction = "west" })
            assert.are.equal(TODAY0, day_view.day_ts)
            day_view:onNextPage() -- tomorrow is in the future
            assert.are.equal(TODAY0, day_view.day_ts)

            -- closing the day view refreshes the month view (after the repaint)
            cal:goToMonth("2026-02")
            day_view:onClose()
            assert.are.equal(day_view, closed[#closed])
            assert.are.equal(1, #scheduled)
            scheduled[1]()
            assert.are.equal("2026-03", cal.cur_month)
        end)

        it("does not go before the first month with data", function()
            stats:onShowCalendarView()
            local cal = shown[#shown]
            cal:goToMonth("2026-02")
            findDay(cal, 1).callback()
            local day_view = shown[#shown]
            local first_day = day_view.day_ts
            assert.are.equal("2026-02-01 (Sunday)", day_view:getTitle())
            assert.are.same({}, day_view.kv_pairs)
            day_view:onPrevPage()
            assert.are.equal(first_day, day_view.day_ts)
            day_view:onSwipe(nil, { direction = "south" })
            assert.are.equal(day_view, closed[#closed])
        end)

        it("shows today's timeline, honouring the configured start of day", function()
            stats:onShowCalendarDayView()
            local day_view = shown[#shown]
            assert.are.equal(stats, day_view.reader_statistics)
            assert.are.equal(TODAY0, day_view.day_ts)
            assert.are.equal(2, #day_view.kv_pairs)
            -- at 12:00 with days starting at 13:30, we're still in yesterday's timeline
            stats.settings.calendar_day_start_hour = 13
            stats.settings.calendar_day_start_minute = 30
            stats:onShowCalendarDayView()
            day_view = shown[#shown]
            assert.are.equal(TODAY0 - 86400 + 13 * 3600 + 30 * 60, day_view.day_ts)
            assert.are.equal("2026-03-17 (Tuesday)", day_view:getTitle())
            assert.is_true(day_view.is_current_day)
            assert.are.equal(22, day_view.current_day_hour)
            assert.are.equal(30 * 60, day_view.current_hour_second)
        end)
    end)

    describe("with a real ReaderUI", function()
        local readerui
        teardown(function()
            disable_plugins()
        end)

        after_each(function()
            if readerui then
                readerui:onClose()
                readerui = nil
            end
            DocSettings:open(sample_epub):purge()
            os.remove(DocSettings:getHistoryPath(sample_epub))
        end)

        it("tracks page turns of an opened EPUB and saves them on close", function()
            disable_plugins()
            load_plugin("statistics.koplugin")
            local ReaderUI = require("apps/reader/readerui")
            local DocumentRegistry = require("document/documentregistry")
            local Event = require("ui/event")
            readerui = ReaderUI:new{
                dimen = require("device").screen:getSize(),
                document = DocumentRegistry:openDocument(sample_epub),
            }
            local stats = readerui.statistics
            assert.is_not_nil(stats)
            assert.are.equal("Romeo and Juliet", stats.data.title)
            assert.are.equal(util.partialMD5(sample_epub), stats.doc_md5)
            assert.are.equal(1, stats.id_curr_book)
            readerui:handleEvent(Event:new("GotoPage", 5))
            assert.are.equal(5, stats.curr_page)
            mock_time:increase(42)
            readerui:handleEvent(Event:new("GotoPage", 6))
            assert.are.equal(6, stats.curr_page)
            assert.are.equal(42, stats.page_stat[5][#stats.page_stat[5]][2])
            mock_time:increase(17)
            readerui:onClose()
            readerui = nil
            local rows = dbRows("SELECT page, duration FROM page_stat_data ORDER BY page;")
            assert.are.same({ 5, 42 }, rows[#rows - 1])
            assert.are.same({ 6, 17 }, rows[#rows])
            assert.are.equal("Romeo and Juliet", dbText("SELECT title FROM book;"))
        end)
    end)
end)
