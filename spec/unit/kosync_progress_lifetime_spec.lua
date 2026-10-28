require("commonrequire")
local saved_path = package.path
package.path = "plugins/kosync.koplugin/?.lua;" .. package.path
local Queue = require("KOSyncQueue")
local Client = require("KOSyncClient")
local KOSync = dofile("plugins/kosync.koplugin/main.lua")
package.path = saved_path
local UIManager = require("ui/uimanager")
local time = require("ui/time")

describe("KOSync pull response lifetime", function()
    local pending, applied, shown
    before_each(function()
        Queue:clear()
        pending, applied, shown = nil, nil, {}
        stub(UIManager, "getElapsedTimeSinceBoot", function() return time.s(100) end)
        stub(UIManager, "show", function(_, widget) shown[#shown + 1] = widget end)
        stub(Client, "new", function()
            return { get_progress = function(_, _, _, _, callback) pending = callback end }
        end)
    end)
    after_each(function()
        UIManager.getElapsedTimeSinceBoot:revert()
        UIManager.show:revert()
        Client.new:revert()
        Queue:clear()
    end)
    local function plugin()
        local document = { file = "synthetic.epub" }
        return setmetatable({
            path = "plugins/kosync.koplugin", pull_timestamp = 0, last_page_turn_timestamp = 1,
            settings = { username = "synthetic", userkey = "key", sync_backward = 2, sync_forward = 2 },
            ui = { document = document }, view = { document = document },
            getDocumentDigest = function() return "current-book" end,
            getLastProgress = function(self)
                assert(self.ui.document, "closed document accessed")
                return "fresh-local"
            end,
            getLastPercent = function() return 0.5 end,
            syncToProgress = function(_, progress) applied = progress end,
        }, { __index = KOSync })
    end
    local function reply(forward)
        pending(true, { progress = "old-remote", percentage = 0.1, timestamp = forward and 2 or 0,
            device = "Synthetic remote", device_id = "synthetic-remote" })
    end
    it("still applies a valid response for the open document", function()
        plugin():getProgress(false, false)
        reply()
        assert.are.equal("old-remote", applied)
    end)
    it("does not read a document after it closes", function()
        local sync = plugin()
        sync:getProgress(false, false)
        sync.ui.document = nil
        reply()
        assert.is_nil(applied)
    end)
    it("does not apply an old response to a replacement document", function()
        local sync = plugin()
        sync:getProgress(false, false)
        sync.ui.document = { file = "replacement.epub" }
        reply()
        assert.is_nil(applied)
    end)
    it("does not apply an old account response after logout", function()
        local sync = plugin()
        sync:getProgress(false, false)
        sync:logout()
        reply()
        assert.is_nil(applied)
    end)
    for _, mode in ipairs{ "interactive", "backward", "forward" } do
        it("does not apply " .. mode .. " progress after a failed upload is queued", function()
            local sync = plugin()
            sync:getProgress(false, mode == "interactive")
            Queue:push{ document = "current-book", progress = "fresh-local" }
            reply(mode == "forward")
            assert.is_nil(applied)
            assert.are.equal(1, Queue:count())
        end)
    end
    for _, direction in ipairs{ "backward", "forward" } do
        it("rechecks pending uploads before confirming a " .. direction .. " sync", function()
            local sync = plugin()
            sync.settings["sync_" .. direction] = 1
            sync:getProgress(false, false)
            reply(direction == "forward")
            local dialog = shown[#shown]
            assert.is_function(dialog.ok_callback)
            Queue:push{ document = "current-book", progress = "fresh-local" }
            dialog.ok_callback()
            assert.is_nil(applied)
            assert.are.equal(1, Queue:count())
        end)
    end
    it("does not block a valid response because another document is pending", function()
        local sync = plugin()
        sync:getProgress(false, false)
        Queue:push{ document = "other-book", progress = "other" }
        reply()
        assert.are.equal("old-remote", applied)
    end)

end)
