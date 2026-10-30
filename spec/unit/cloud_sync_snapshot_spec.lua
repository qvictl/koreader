require("commonrequire")
local Cloud = dofile(os.getenv("CLOUD_SYNC_IMPLEMENTATION") or "plugins/cloudstorage.koplugin/main.lua")
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

describe("Cloud synchronization snapshots", function()
    local dir, path, cloud, provider, observer, messages, uploads, sources
    local old_tick, old_show
    local function count(file)
        local conn = SQ3.open(file, "ro")
        local n = tonumber(conn:rowexec("SELECT count(*) FROM book"))
        conn:close()
        return n
    end
    local function insert(id)
        local conn = SQ3.open(path)
        conn:exec("INSERT INTO book VALUES(" .. id .. ")")
        conn:close()
    end
    local function sync(callback, snapshot, silent)
        cloud:sync({ type = "test", url = "synthetic" }, path,
            callback or function() return true end, silent, nil, snapshot or Cloud.createSQLiteSnapshot)
    end
    local function noScratch()
        for name in lfs.dir(dir) do
            assert.is_nil(name:match("%.sync%."), "snapshot directory leaked: " .. name)
        end
        assert.is_nil(lfs.attributes(path .. ".temp"))
    end
    before_each(function()
        dir = DataStorage:getSettingsDir() .. "/cloud-snapshot's"
        util.makePath(dir)
        path = dir .. "/statistics.sqlite3"
        local conn = SQ3.open(path)
        conn:exec("PRAGMA journal_mode=WAL; CREATE TABLE book(id INTEGER PRIMARY KEY); INSERT INTO book VALUES(1);")
        conn:exec("PRAGMA wal_checkpoint(TRUNCATE)")
        assert.is_nil(ffiUtil.copyFile(path, path .. ".sync"))
        observer = SQ3.open(path)
        observer:exec("BEGIN")
        assert.are.equal(1, tonumber(observer:rowexec("SELECT count(*) FROM book")))
        conn:exec("INSERT INTO book VALUES(2)")
        conn:close()
        messages, uploads, sources = {}, {}, {}
        old_tick, old_show = UIManager.nextTick, UIManager.show
        UIManager.nextTick = function(_, callback) callback() end
        UIManager.show = function(_, widget) messages[#messages + 1] = widget.text end
        provider = {
            run = function(callback) callback() end,
            downloadFile = function(remote, destination)
                assert.are.equal("synthetic/statistics.sqlite3", remote)
                local f = assert(io.open(destination, "w")); f:write("not found"); f:close()
                return 404, "synthetic-etag"
            end,
            uploadFile = function(remote, source, etag, overwrite)
                assert.are.equal("synthetic", remote)
                assert.are.equal("statistics.sqlite3", ffiUtil.basename(source))
                assert.are.equal("synthetic-etag", etag)
                assert.is_true(overwrite)
                uploads[#uploads + 1] = count(source)
                sources[#sources + 1] = source
                return 200
            end,
        }
        cloud = setmetatable({ providers = { test = provider } }, { __index = Cloud })
    end)
    after_each(function()
        UIManager.nextTick, UIManager.show = old_tick, old_show
        if observer then observer:close() end
        ffiUtil.purgeDir(dir)
    end)

    it("uploads committed WAL rows and caches the exact uploaded snapshot", function()
        local upload = provider.uploadFile
        provider.uploadFile = function(...)
            local result = upload(...)
            insert(3) -- A write after the snapshot must belong to the next sync.
            return result
        end
        sync()
        assert.same({ 2 }, uploads)
        assert.are.equal(3, count(path))
        assert.are.equal(2, count(path .. ".sync"))
        local cached = SQ3.open(path .. ".sync", "ro")
        assert.are.equal("delete", cached:rowexec("PRAGMA journal_mode"))
        cached:close()
        assert.are.equal(1, #messages)
        assert.truthy(messages[1]:find("Successfully", 1, true))
        noScratch()
    end)

    it("snapshots the committed merge result", function()
        sync(function()
            insert(3)
            return true
        end)
        assert.same({ 3 }, uploads)
        assert.are.equal(3, count(path .. ".sync"))
        noScratch()
    end)

    it("retains the previous baseline if retrying a conflict fails", function()
        local downloads = 0
        provider.downloadFile = function()
            downloads = downloads + 1
            return downloads == 1 and 404 or 503
        end
        provider.uploadFile = function() return 412 end
        sync()
        assert.are.equal(2, downloads)
        assert.are.equal(1, count(path .. ".sync"))
        assert.are.equal(1, #messages)
        noScratch()
    end)

    it("rebuilds the snapshot after a conditional upload conflict", function()
        local upload = provider.uploadFile
        provider.uploadFile = function(...)
            upload(...)
            if #uploads == 1 then insert(3); return 412 end
            return 204
        end
        local merges = 0
        sync(function()
            merges = merges + 1
            assert.are.equal(1, count(path .. ".sync"))
            return true
        end)
        assert.are.equal(2, merges)
        assert.same({ 2, 3 }, uploads)
        assert.are.equal(3, count(path .. ".sync"))
        noScratch()
    end)

    it("preserves the cache after failed upload", function()
        provider.uploadFile = function() return 500 end
        sync()
        assert.are.equal(1, count(path .. ".sync"))
        assert.are.equal(1, #messages)
        noScratch()
    end)

    it("preserves the cache and cleans up after upload throws", function()
        provider.uploadFile = function() error("synthetic upload exception") end
        sync()
        assert.are.equal(1, count(path .. ".sync"))
        assert.are.equal(1, #messages)
        noScratch()
    end)

    it("does not upload an incomplete snapshot", function()
        sync(nil, function(_, destination)
            local f = assert(io.open(destination, "w")); f:write("partial"); f:close()
            return false, "synthetic snapshot failure"
        end)
        assert.same({}, uploads)
        assert.are.equal(1, count(path .. ".sync"))
        noScratch()
    end)

    it("cleans up after a snapshot callback throws", function()
        sync(nil, function() error("synthetic snapshot exception") end)
        assert.same({}, uploads)
        assert.are.equal(1, count(path .. ".sync"))
        noScratch()
    end)

    it("preserves the cache when atomic replacement fails", function()
        local rename = stub(os, "rename", function() return nil, "synthetic rename failure" end)
        finally(function() rename:revert() end)
        sync()
        assert.same({ 2 }, uploads)
        assert.are.equal(1, count(path .. ".sync"))
        assert.are.equal(1, #messages)
        noScratch()
    end)

    it("cleans up after a failed download", function()
        provider.downloadFile = function(_, destination)
            local f = assert(io.open(destination, "w")); f:write("failed"); f:close()
            return 503
        end
        sync()
        assert.same({}, uploads)
        assert.are.equal(1, count(path .. ".sync"))
        noScratch()
    end)

    it("cleans up after a rejected merge", function()
        sync(function() return false, "synthetic merge failure" end)
        assert.same({}, uploads)
        assert.same({ "synthetic merge failure" }, messages)
        assert.are.equal(1, count(path .. ".sync"))
        noScratch()
    end)

    it("logs silent failures without showing a notification", function()
        provider.uploadFile = function() return 500 end
        sync(nil, nil, true)
        assert.same({}, messages)
        noScratch()
    end)

    it("creates a plain snapshot for non-database callers", function()
        local source = dir .. "/plain.txt"
        local f = assert(io.open(source, "w")); f:write("snapshot contents"); f:close()
        provider.downloadFile = function() return 404 end
        provider.uploadFile = function(_, snapshot)
            assert.are.equal("plain.txt", ffiUtil.basename(snapshot))
            local input = assert(io.open(snapshot, "r"))
            assert.are.equal("snapshot contents", input:read("*a")); input:close()
            f = assert(io.open(source, "w")); f:write("new contents"); f:close()
            return 200
        end
        cloud:sync({ type = "test", url = "synthetic" }, source, function() return true end)
        f = assert(io.open(source .. ".sync", "r"))
        assert.are.equal("snapshot contents", f:read("*a")); f:close()
        noScratch()
    end)

    it("opts the statistics and vocabulary callers into SQLite snapshots", function()
        local old_path = package.path
        local old_db = package.loaded.db
        local old_settings = G_reader_settings:readSetting("vocabulary_builder")
        finally(function()
            package.path = old_path
            package.loaded.db = old_db
            G_reader_settings:saveSetting("vocabulary_builder", old_settings)
        end)
        package.path = "plugins/statistics.koplugin/?.lua;" .. package.path
        local Statistics = dofile("plugins/statistics.koplugin/main.lua")
        local args
        local storage = {
            createSQLiteSnapshot = Cloud.createSQLiteSnapshot,
            sync = function(...) args = { ... } end,
        }
        local stats = setmetatable({
            ui = { cloudstorage = storage },
            settings = { is_enabled = true, sync_server = { type = "test" } },
        }, { __index = Statistics })
        stats:onSyncBookStats()
        assert.are.equal(Cloud.createSQLiteSnapshot, args[7])
        G_reader_settings:saveSetting("vocabulary_builder", { server = { type = "test" } })
        package.path = "plugins/vocabbuilder.koplugin/?.lua;" .. package.path
        package.loaded.db = nil
        local VocabBuilder = dofile("plugins/vocabbuilder.koplugin/main.lua")
        local vocab = setmetatable({ ui = { cloudstorage = storage } }, { __index = VocabBuilder })
        vocab:onSyncVocabBuilder(true)
        assert.are.equal(Cloud.createSQLiteSnapshot, args[7])
        assert.is_false(args[5])
    end)

    it("refuses invalid SQLite files and closes failed snapshot connections", function()
        local invalid = dir .. "/invalid"
        local f = assert(io.open(invalid, "w")); f:write("not a database"); f:close()
        local ok, err = Cloud.createSQLiteSnapshot(invalid, dir .. "/invalid-copy")
        assert.is_false(ok)
        assert.truthy(err)
        ok = Cloud.createSQLiteSnapshot(path, dir .. "/valid-copy")
        assert.is_true(ok)
        assert.are.equal(2, count(dir .. "/valid-copy"))
    end)
end)
