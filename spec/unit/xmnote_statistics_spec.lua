describe("XMNote statistics queries", function()
    local DataStorage, SQ3, XMNote, ffiUtil, util
    local saved_path, saved_base, saved_target, saved_open
    local root, database, opened

    setup(function()
        require("commonrequire")
        DataStorage = require("datastorage")
        SQ3 = require("lua-ljsqlite3/init")
        ffiUtil = require("ffi/util")
        util = require("util")
        root = DataStorage:getDataDir() .. "/xmnote-statistics-spec"
        database = root .. "/statistics.sqlite3"
        saved_path, saved_base, saved_target = package.path, package.loaded.base, package.loaded["target/xmnote"]
        local saved_dir = DataStorage.getSettingsDir
        DataStorage.getSettingsDir = function() return root end
        package.path = "plugins/exporter.koplugin/?.lua;" .. package.path
        package.loaded["target/xmnote"] = nil
        local ok, target = pcall(require, "target/xmnote")
        DataStorage.getSettingsDir = saved_dir
        assert.is_true(ok)
        XMNote = target
    end)

    teardown(function()
        package.path, package.loaded.base, package.loaded["target/xmnote"] = saved_path, saved_base, saved_target
        ffiUtil.purgeDir(root)
    end)

    before_each(function()
        ffiUtil.purgeDir(root)
        util.makePath(root)
        opened, saved_open = {}, SQ3.open
        SQ3.open = function(...)
            local conn = saved_open(...)
            opened[#opened + 1] = conn
            return conn
        end
    end)

    after_each(function()
        SQ3.open = saved_open
        for _, conn in ipairs(opened) do
            if not conn._closed then conn:close() end
        end
        ffiUtil.purgeDir(root)
    end)

    local function fixture(title, md5)
        local conn = saved_open(database)
        conn:exec("CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT, md5 TEXT)")
        conn:exec("CREATE TABLE page_stat (id_book INTEGER, page INTEGER, start_time INTEGER, duration INTEGER)")
        local stmt = conn:prepare("INSERT INTO book VALUES (1, ?, ?)")
        stmt:bind(title, md5):step()
        stmt:close()
        conn:exec("INSERT INTO page_stat VALUES (1, 2, 1700000000, 10), (1, 4, 1700000010, 20)")
        conn:close()
    end

    local function assertClosed()
        assert.equals(1, #opened)
        assert.is_true(opened[1]._closed)
    end

    it("keeps the existing duration aggregation", function()
        fixture("Ordinary", "checksum")
        local result = XMNote:getBookReadingDurationsByDay("Ordinary", "checksum")
        assert.equals(1, #result)
        assert.equals(1700000000000, result[1].date)
        assert.equals(30, result[1].durationSeconds)
        assert.equals(4, result[1].position)
        assertClosed()
    end)

    for _, title in ipairs({ "Reader's 日本語", "First; second", "' OR 1=1 --" }) do
        it("treats the title as literal data: " .. title, function()
            fixture(title, "checksum")
            local result = XMNote:getBookReadingDurationsByDay(title, "checksum")
            assert.equals(1, #result)
            assert.equals(30, result[1].durationSeconds)
            assertClosed()
        end)
    end

    it("does not match another book through SQL syntax in the title", function()
        fixture("Other title", "checksum")
        assert.same({}, XMNote:getBookReadingDurationsByDay("' OR 1=1 --", "different"))
        assertClosed()
    end)

    it("closes the database when a book does not match", function()
        fixture("Ordinary", "checksum")
        assert.same({}, XMNote:getBookReadingDurationsByDay("Missing", "checksum"))
        assertClosed()
    end)

    it("does not export statistics for a different checksum", function()
        fixture("Ordinary", "checksum")
        assert.same({}, XMNote:getBookReadingDurationsByDay("Ordinary", "different"))
        assertClosed()
    end)

    it("keeps missing database behavior without creating a file", function()
        assert.same({}, XMNote:getBookReadingDurationsByDay("Ordinary", "checksum"))
        assert.equals(0, #opened)
        assert.is_nil((util.fileExists(database)))
    end)

    it("closes the database and omits unavailable optional statistics on query failure", function()
        fixture("Ordinary", "checksum")
        local conn = saved_open(database)
        conn:exec("DROP TABLE page_stat")
        conn:close()
        assert.same({}, XMNote:getBookReadingDurationsByDay("Ordinary", "checksum"))
        assertClosed()
    end)

    it("does not abort highlight export when the statistics file is corrupt", function()
        assert(util.writeToFile("not a SQLite database", database))
        assert.same({}, XMNote:getBookReadingDurationsByDay("Ordinary", "checksum"))
        assertClosed()
    end)

    it("handles a database disappearing before read-only open", function()
        fixture("Ordinary", "checksum")
        SQ3.open = function(path, mode)
            assert.equals("ro", mode)
            os.remove(path)
            return saved_open(path, mode)
        end
        assert.same({}, XMNote:getBookReadingDurationsByDay("Ordinary", "checksum"))
        assert.is_nil((util.fileExists(database)))
    end)


    it("closes the database when the matched book has no reading durations", function()
        fixture("Ordinary", "checksum")
        local conn = saved_open(database)
        conn:exec("DELETE FROM page_stat")
        conn:close()
        assert.same({}, XMNote:getBookReadingDurationsByDay("Ordinary", "checksum"))
        assertClosed()
    end)

    it("does not guess a book identity when the checksum is missing", function()
        fixture("Ordinary", "checksum")
        assert.same({}, XMNote:getBookReadingDurationsByDay("Ordinary", nil))
        assertClosed()
    end)

end)
