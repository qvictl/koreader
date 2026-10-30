require("commonrequire")
local saved_path = package.path
package.path = "plugins/kosync.koplugin/?.lua;" .. package.path
local Queue = require("KOSyncQueue")
local Client = require("KOSyncClient")
local KOSync = dofile("plugins/kosync.koplugin/main.lua")
package.path = saved_path
local Device = require("device")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local gettext = require("gettext")

describe("KOSync device identity", function()
    local published, pending, applied, shown
    before_each(function()
        Queue:clear()
        published, pending, applied, shown = nil, nil, nil, {}
        stub(UIManager, "getElapsedTimeSinceBoot", function() return time.s(100) end)
        stub(UIManager, "show", function(_, widget) shown[#shown + 1] = widget end)
        stub(Client, "new", function()
            return {
                update_progress = function(_, _, _, _, _, progress, percentage, device, device_id, callback)
                    published = { progress = progress, percentage = percentage, device = device, device_id = device_id }
                    callback(true, 200)
                end,
                get_progress = function(_, _, _, _, callback) pending = callback end,
            }
        end)
    end)
    after_each(function()
        UIManager.getElapsedTimeSinceBoot:revert()
        UIManager.show:revert()
        Client.new:revert()
        Queue:clear()
    end)
    local function plugin(hostname)
        local document = { file = "synthetic.epub" }
        return setmetatable({
            path = "plugins/kosync.koplugin", device_id = "local-device",
            push_timestamp = 0, pull_timestamp = 0, last_page_turn_timestamp = 1,
            settings = { username = "synthetic", userkey = "key", kosync_hostname = hostname,
                sync_backward = 2, sync_forward = 2 },
            ui = { document = document }, view = { document = document },
            progress = "published-position", percentage = 0.1,
            getDocumentDigest = function() return "current-book" end,
            getMetadata = function() end,
            getLastProgress = function(self) return self.progress end,
            getLastPercent = function(self) return self.percentage end,
            syncToProgress = function(_, progress) applied = progress end,
        }, { __index = KOSync })
    end
    for _, name in ipairs{ "custom", "default" } do
        for _, mode in ipairs{ "interactive", "automatic" } do
            for _, identity in ipairs{ "same", "different" } do
                it("handles " .. identity .. " device IDs with a " .. name .. " name on " .. mode .. " pull", function()
                    local hostname = name == "custom" and "My reader" or nil
                    local sync = plugin(hostname)
                    sync:updateProgress(false, false)
                    assert.are.equal(hostname or Device.model, published.device)
                    assert.are.equal(sync.device_id, published.device_id)
                    sync.progress, sync.percentage = "newer-local-position", 0.5
                    if identity == "different" then published.device_id = "other-device" end
                    local interactive = mode == "interactive"
                    sync:getProgress(false, interactive)
                    pending(true, published)
                    if identity == "same" then
                        assert.is_nil(applied)
                        assert.are.equal(interactive and 1 or 0, #shown)
                        if interactive then
                            assert.are.equal(gettext("Latest progress is coming from this device."), shown[1].text)
                        end
                    else
                        assert.are.equal("published-position", applied)
                    end
                end)
            end
        end
    end
    it("still requires the device name to match as well as the ID", function()
        local sync = plugin("My reader")
        sync:getProgress(false, true)
        pending(true, { progress = "remote-position", percentage = 0.9,
            device = "Another reader", device_id = sync.device_id })
        assert.are.equal("remote-position", applied)
    end)
end)
