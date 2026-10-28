-- Statistics: long-pressing a book in a period's book list ("This week", "Today", …, and the
-- calendar's day timeline) offers to reset that book's statistics for the period. The
-- book id came straight from SQLite as an int64 cdata, which string.format("%d") rejects:
-- the long-press raised a Lua error instead of showing the confirmation.
describe("Statistics period book list long-press", function()
    local ReaderStatistics, SQ3, UIManager, DataStorage
    local db_path, shown, orig_show

    local function exec(sql)
        local conn = SQ3.open(db_path)
        conn:exec(sql)
        conn:close()
    end

    local function count(sql)
        local conn = SQ3.open(db_path)
        local v = conn:rowexec(sql)
        conn:close()
        return tonumber(v)
    end

    setup(function()
        require("commonrequire")
        package.path = "plugins/statistics.koplugin/?.lua;" .. package.path
        ReaderStatistics = dofile("plugins/statistics.koplugin/main.lua")
        SQ3 = require("lua-ljsqlite3/init")
        UIManager = require("ui/uimanager")
        DataStorage = require("datastorage")
        db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
        os.remove(db_path)
        G_reader_settings:saveSetting("statistics", { min_sec = 5, max_sec = 120, is_enabled = true })
        orig_show = UIManager.show
        UIManager.show = function(_, w) table.insert(shown, w) end
    end)

    teardown(function()
        UIManager.show = orig_show
        G_reader_settings:delSetting("statistics")
        os.remove(db_path)
    end)

    it("asks for confirmation, then resets the book's statistics for the period", function()
        shown = {}
        -- Creates the DB.
        local stats = ReaderStatistics:new{ ui = { menu = { registerToMainMenu = function() end } } }
        assert.is_not_nil(stats)
        exec([[INSERT INTO book (id, title, authors, notes, last_open, highlights, pages, series, language, md5,
                                 total_read_time, total_read_pages)
               VALUES (7, 'Book A', 'Author', 0, 1000, 0, 100, '', 'en', 'md5-a', 0, 0);]])
        exec([[INSERT INTO page_stat_data (id_book, page, start_time, duration, total_pages) VALUES
               (7, 1, 1000, 30, 100), (7, 2, 1100, 40, 100), (7, 3, 5000, 50, 100);]])
        local items = stats:getBooksFromPeriod(0, 2000)
        assert.are.equal(1, #items)
        assert.are.equal("Book A", items[1][1])
        local removed = spy.new(function() end)
        local kv_page = { removeKeyValueItem = removed }
        shown = {}
        items[1].hold_callback(kv_page, items[1])
        local box = shown[#shown]
        assert.is_not_nil(box)
        assert.is_truthy(box.text:find("Book A", 1, true))
        box.ok_callback()
        assert.spy(removed).was.called_with(kv_page, items[1])
        -- Only the period's pages are gone.
        assert.are.equal(1, count("SELECT count(*) FROM page_stat_data WHERE id_book = 7;"))
    end)
end)
