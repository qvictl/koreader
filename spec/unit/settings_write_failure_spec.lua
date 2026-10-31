local io = require("io")

describe("Settings write failure propagation", function()
    local DataStorage, LuaSettings, ReadCollection, ffiUtil, util
    local saved_open, saved_settings_open, saved_write, saved_coll, saved_coll_settings
    local root

    setup(function()
        require("commonrequire")
        DataStorage = require("datastorage")
        LuaSettings = require("luasettings")
        ReadCollection = require("readcollection")
        ffiUtil = require("ffi/util")
        util = require("util")
        root = DataStorage:getDataDir() .. "/settings-write-failure-spec"
    end)

    before_each(function()
        ffiUtil.purgeDir(root)
        saved_open = io.open
        saved_settings_open = LuaSettings.open
        saved_write = util.writeToFile
        saved_coll, saved_coll_settings = ReadCollection.coll, ReadCollection.coll_settings
    end)

    after_each(function()
        io.open = saved_open
        LuaSettings.open = saved_settings_open
        util.writeToFile = saved_write
        ReadCollection.coll, ReadCollection.coll_settings = saved_coll, saved_coll_settings
        ffiUtil.purgeDir(root)
    end)

    local function failedFile(stage)
        local closed = false
        local file = {
            write = function(self)
                if stage == "write" then return nil, "write failed" end
                return self
            end,
            flush = function()
                return nil, "flush failed"
            end,
            close = function()
                closed = true
                if stage == "close" then return nil, "close failed" end
                return true
            end,
        }
        io.open = function() return file end
        return function() return closed end
    end

    it("returns open errors", function()
        io.open = function() return nil, "open failed" end
        local ok, err = util.writeToFile("value", "not-opened")
        assert.is_nil(ok)
        assert.equals("open failed", err)
    end)

    it("returns write errors and still closes the file", function()
        local closed = failedFile("write")
        local ok, err = util.writeToFile("value", "not-opened")
        assert.is_nil(ok)
        assert.equals("write failed", err)
        assert.is_true(closed())
    end)

    it("returns buffer-flush errors before attempting the native sync", function()
        local closed = failedFile("flush")
        local ok, err = util.writeToFile("value", "not-opened", true)
        assert.is_nil(ok)
        assert.equals("flush failed", err)
        assert.is_true(closed())
    end)

    it("returns close errors", function()
        local closed = failedFile("close")
        local ok, err = util.writeToFile("value", "not-opened")
        assert.is_nil(ok)
        assert.equals("close failed", err)
        assert.is_true(closed())
    end)

    it("keeps LuaSettings data after a real open failure and permits a later successful retry", function()
        local path = root .. "/settings.lua"
        local settings = LuaSettings:open(path)
        settings:saveSetting("retained", "value")
        local ok, err = settings:flush()
        assert.is_false(ok)
        assert.is_string(err)
        assert.equals("value", settings:readSetting("retained"))
        util.makePath(root)
        assert.equals(settings, settings:flush()) -- preserve successful chaining
        assert.equals("value", LuaSettings:open(path):readSetting("retained"))
    end)

    it("returns a collection settings failure to its caller", function()
        ReadCollection.coll, ReadCollection.coll_settings = { favorites = {} }, { favorites = {} }
        LuaSettings.open = function()
            return LuaSettings:extend{ data = {}, flush = function() return false, "blocked" end }
        end
        local ok, err = ReadCollection:write({ favorites = true })
        assert.is_false(ok)
        assert.equals("blocked", err)
    end)

    it("preserves a successful collection settings result", function()
        ReadCollection.coll, ReadCollection.coll_settings = { favorites = {} }, { favorites = {} }
        local settings = LuaSettings:extend{ data = {}, flush = function(self) return self end }
        LuaSettings.open = function() return settings end
        assert.equals(settings, ReadCollection:write({ favorites = true }))
    end)

    it("rebuilds previously committed collections after a later write truncates the file", function()
        local Collection = require("apps/filemanager/filemanagercollection")
        local path = root .. "/collection.lua"
        util.makePath(root)
        LuaSettings.open = function() return saved_settings_open(LuaSettings, path) end
        ReadCollection.coll = { first = {}, second = {} }
        ReadCollection.coll_settings = { first = { order = 1 }, second = { order = 2 } }
        local manager = Collection:extend{ updated_collections = { first = true } }
        manager:onFlushSettings()
        assert.is_nil(next(manager.updated_collections))
        manager.updated_collections.second = true
        util.writeToFile = function(_, file)
            assert(io.open(file, "wb")):close() -- reproduce truncation before a write error
            return nil, "simulated write failure"
        end
        manager:onFlushSettings()
        util.writeToFile = saved_write
        manager:onFlushSettings()
        local persisted = saved_settings_open(LuaSettings, path)
        assert.is_table(persisted:readSetting("first"))
        assert.is_table(persisted:readSetting("second"))
        assert.is_nil(next(manager.updated_collections))
    end)
end)
