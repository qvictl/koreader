require("commonrequire")
local Cloud = dofile("plugins/cloudstorage.koplugin/main.lua")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local logger = require("logger")

describe("Cloud synchronization errors", function()
    local cloud, messages, warnings, old_show, old_next_tick, old_warn
    before_each(function()
        messages, warnings = {}, {}
        old_show, old_next_tick, old_warn = UIManager.show, UIManager.nextTick, logger.warn
        UIManager.show = function(_, widget) messages[#messages + 1] = widget.text end
        UIManager.nextTick = function(_, callback) callback() end
        logger.warn = function(_, message) warnings[#warnings + 1] = message end
        cloud = setmetatable({ providers = { test = {
            run = function(callback) callback() end,
            downloadFile = function() return 200, "synthetic-etag" end,
            uploadFile = function() error("a failed merge must not upload") end,
        } } }, { __index = Cloud })
    end)
    after_each(function()
        UIManager.show, UIManager.nextTick, logger.warn = old_show, old_next_tick, old_warn
    end)
    local function sync(callback, silent)
        cloud:sync({ type = "test", url = "synthetic" },
            DataStorage:getSettingsDir() .. "/synthetic-sync.db", callback, silent)
    end
    it("shows an explicit callback error", function()
        sync(function() return false, "Synthetic database identity conflict" end)
        assert.same({ "Synthetic database identity conflict" }, messages)
    end)
    it("preserves the generic error for boolean callbacks", function()
        sync(function() return false end)
        assert.are.equal(1, #messages)
        assert.truthy(messages[1]:find("network connection", 1, true))
    end)
    it("preserves the generic error for callback exceptions", function()
        sync(function() error("synthetic exception") end)
        assert.are.equal(1, #messages)
        assert.truthy(messages[1]:find("network connection", 1, true))
    end)
    it("logs explicit errors without showing silent notifications", function()
        sync(function() return false, "Synthetic database identity conflict" end, true)
        assert.same({}, messages)
        assert.same({ "Synthetic database identity conflict" }, warnings)
    end)
end)
