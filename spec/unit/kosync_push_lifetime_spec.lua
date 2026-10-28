require("commonrequire")
local saved_path = package.path
package.path = "plugins/kosync.koplugin/?.lua;" .. package.path
local Queue = require("KOSyncQueue")
local Client = require("KOSyncClient")
local KOSync = dofile("plugins/kosync.koplugin/main.lua")
package.path = saved_path
local UIManager = require("ui/uimanager")
local Device = require("device")
local time = require("ui/time")

describe("KOSync push response lifetime", function()
    local requests, shown
    local function reply(index, ok, status)
        local request = requests[index]
        assert.is_false(request.replied)
        request.replied = true
        request.callback(ok, status)
    end
    before_each(function()
        Queue:clear()
        stub(Device, "hasWifiManager", function() return false end)
        requests, shown = {}, {}
        stub(UIManager, "getElapsedTimeSinceBoot", function() return time.s(100) end)
        stub(UIManager, "show", function(_, widget) shown[#shown + 1] = widget end)
        stub(Client, "new", function()
            return { update_progress = function(_, _, _, _, _, _, _, _, _, callback)
                requests[#requests + 1] = { callback = callback, replied = false }
            end }
        end)
    end)
    after_each(function()
        for index, request in ipairs(requests) do
            if not request.replied then pcall(reply, index, false, 503) end
        end
        UIManager.getElapsedTimeSinceBoot:revert()
        UIManager.show:revert()
        Client.new:revert()
        Device.hasWifiManager:revert()
        Queue:clear()
    end)
    local function plugin(document_id, progress)
        local document = { file = "synthetic.epub" }
        return setmetatable({
            path = "plugins/kosync.koplugin", push_timestamp = 0, device_id = "synthetic-device",
            settings = { username = "synthetic", userkey = "key", auto_sync = false },
            ui = { document = document }, view = { document = document },
            progress = progress or "first-page",
            getDocumentDigest = function() return document_id or "current-book" end,
            getMetadata = function() return "Synthetic metadata" end,
            getLastProgress = function(self) return self.progress end,
            getLastPercent = function() return 0.5 end,
        }, { __index = KOSync })
    end
    local function close(sync)
        sync.ui.document = nil
        sync.view = setmetatable({}, { __index = function() error("closed view accessed") end })
    end
    it("queues a failed push while its document is open", function()
        plugin():updateProgress(false, false)
        reply(1, false, 503)
        assert.are.equal(1, Queue:count())
        assert.are.equal("first-page", Queue:load()[1].progress)
    end)
    it("does not queue an authentication rejection", function()
        plugin():updateProgress(false, true)
        reply(1, false, 401)
        assert.are.equal(0, Queue:count())
        assert.are.equal(1, #shown)
    end)
    it("keeps a failed manual push after closing with automatic sync disabled", function()
        local sync = plugin()
        sync:updateProgress(false, true)
        close(sync)
        reply(1, false, 503)
        assert.are.equal(1, Queue:count())
        assert.are.equal("first-page", Queue:load()[1].progress)
        assert.are.equal(0, #shown)
    end)
    it("does not show a late success on a closed reader", function()
        local sync = plugin()
        sync:updateProgress(false, true)
        close(sync)
        reply(1, true, 200)
        assert.are.equal(0, Queue:count())
        assert.are.equal(0, #shown)
    end)
    it("does not restore old-account progress after logout", function()
        local sync = plugin()
        sync:updateProgress(false, true)
        sync:logout()
        Queue:push{ document = "new-account-book", progress = "new-account-page" }
        reply(1, false, 503)
        assert.are.equal(1, Queue:count())
        assert.are.equal("new-account-book", Queue:load()[1].document)
        assert.are.equal(0, #shown)
    end)
    it("preserves the new server's progress when an old request fails", function()
        local sync = plugin()
        sync:updateProgress(false, true)
        sync:setCustomServer("https://new-sync.example.invalid")
        Queue:push{ document = "current-book", progress = "new-server-page" }
        reply(1, false, 503)
        assert.are.equal(1, Queue:count())
        assert.are.equal("new-server-page", Queue:load()[1].progress)
        assert.are.equal(0, #shown)
    end)
    it("preserves a newer pending snapshot when a push fails late", function()
        plugin():updateProgress(false, false)
        Queue:push{ document = "current-book", progress = "newer-closed-page" }
        reply(1, false, 503)
        assert.are.equal(1, Queue:count())
        assert.are.equal("newer-closed-page", Queue:load()[1].progress)
    end)
    it("replaces an unchanged older pending snapshot with the failed new push", function()
        Queue:push{ document = "current-book", progress = "older-pending-page" }
        plugin(nil, "newer-requested-page"):updateProgress(false, false)
        reply(1, false, 503)
        assert.are.equal(1, Queue:count())
        assert.are.equal("newer-requested-page", Queue:load()[1].progress)
    end)
    it("rejects an earlier failure after the same reader accepts a newer push", function()
        local sync = plugin(nil, "first-request")
        sync:updateProgress(false, true)
        sync.progress = "second-request"
        sync:updateProgress(false, true)
        reply(1, false, 503)
        assert.are.equal(0, Queue:count())
        assert.are.equal(0, #shown)
        reply(2, false, 503)
        assert.are.equal("second-request", Queue:load()[1].progress)
        assert.are.equal(1, #shown)
    end)
    it("does not leave stale progress behind a reopened reader's successful push", function()
        local first = plugin(nil, "old-reader-page")
        first:updateProgress(false, true)
        close(first)
        plugin(nil, "new-reader-page"):updateProgress(false, true)
        reply(1, false, 503)
        assert.are.equal(0, Queue:count())
        reply(2, true, 200)
        assert.are.equal(0, Queue:count())
        assert.are.equal(1, #shown)
    end)
    it("keeps a closed book's failed manual push while another book is syncing", function()
        local first = plugin("first-book", "closed-first-page")
        first:updateProgress(false, true)
        close(first)
        plugin("second-book", "open-second-page"):updateProgress(false, true)
        reply(1, false, 503)
        reply(2, true, 200)
        assert.are.equal(1, Queue:count())
        assert.are.equal("first-book", Queue:load()[1].document)
        assert.are.equal("closed-first-page", Queue:load()[1].progress)
        assert.are.equal(1, #shown)
    end)
    it("keeps the latest closed reader's failed push for the same document", function()
        local first = plugin(nil, "old-reader-page")
        first:updateProgress(false, true)
        close(first)
        local second = plugin(nil, "latest-reader-page")
        second:updateProgress(false, true)
        close(second)
        reply(1, false, 503)
        assert.are.equal(0, Queue:count())
        reply(2, false, 503)
        assert.are.equal(1, Queue:count())
        assert.are.equal("latest-reader-page", Queue:load()[1].progress)
        assert.are.equal(0, #shown)
    end)
    for _, outcome in ipairs{ "success", "failure", "replacement" } do
        it("persists a suspend snapshot before HTTP and handles " .. outcome, function()
            plugin():updateProgress(false, false, true)
            assert.are.equal(1, Queue:count())
            assert.are.equal("first-page", Queue:load()[1].progress)
            if outcome == "replacement" then
                Queue:push{ document = "current-book", progress = "later-closed-page" }
            end
            reply(1, outcome ~= "failure", outcome == "failure" and 503 or 200)
            if outcome == "success" then
                assert.are.equal(0, Queue:count())
            else
                assert.are.equal(1, Queue:count())
                assert.are.equal(outcome == "replacement" and "later-closed-page" or "first-page",
                    Queue:load()[1].progress)
            end
            assert.are.equal(0, #shown)
        end)
    end
end)
