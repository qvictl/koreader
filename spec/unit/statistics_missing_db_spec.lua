describe("Statistics plugin with a deleted database", function()
    local ReaderStatistics, UIManager, SQ3, lfs
    local db_location, settings_dir
    local shown

    local function listBackups()
        local bkps = {}
        for f in lfs.dir(settings_dir) do
            if f:find("statistics.sqlite3.bkp", 1, true) then
                table.insert(bkps, f)
            end
        end
        return bkps
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        package.path = "plugins/statistics.koplugin/?.lua;" .. package.path
        ReaderStatistics = dofile("plugins/statistics.koplugin/main.lua")
        UIManager = require("ui/uimanager")
        SQ3 = require("lua-ljsqlite3/init")
        lfs = require("libs/libkoreader-lfs")
        settings_dir = require("datastorage"):getSettingsDir()
        db_location = settings_dir .. "/statistics.sqlite3"
    end)

    before_each(function()
        os.remove(db_location)
        for _, f in ipairs(listBackups()) do
            os.remove(settings_dir .. "/" .. f)
        end
        shown = {}
        stub(UIManager, "show", function(_, widget) table.insert(shown, widget) end)
    end)

    after_each(function()
        UIManager.show:revert()
        os.remove(db_location)
    end)

    it("offers to create a new DB without trying to migrate the empty one", function()
        local stats = setmetatable({ settings = { convert_to_db = true } }, { __index = ReaderStatistics })
        assert.has_no.errors(function() stats:checkInitDatabase() end)

        assert.are.equal(1, #shown)
        assert.is_function(shown[1].ok_callback)
        -- No pointless backup of the empty DB.
        assert.are.same({}, listBackups())

        -- Accepting the dialog creates a usable, up-to-date DB.
        shown[1].ok_callback()
        local conn = SQ3.open(db_location)
        assert.is_truthy(conn:exec("PRAGMA table_info('page_stat_data');"))
        local version = tonumber(conn:rowexec("PRAGMA user_version;"))
        conn:close()
        assert.is_true(version > 0)

        -- And the next check is silent.
        shown = {}
        stats:checkInitDatabase()
        assert.are.same({}, shown)
        assert.are.same({}, listBackups())
    end)
end)
