require("commonrequire")
local saved_path = package.path
package.path = "plugins/kosync.koplugin/?.lua;" .. package.path
local Queue = require("KOSyncQueue")
local Client = require("KOSyncClient")
local KOSync = dofile("plugins/kosync.koplugin/main.lua")
package.path = saved_path
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local gettext = require("gettext")
local Persist = require("persist")

describe("KOSync malformed server recovery", function()
    local shown, saved_looper, new_stub
    local saved_queue, queue_path
    before_each(function()
        saved_queue = { persist = Queue._persist, draining = Queue._draining, generation = Queue._generation }
        queue_path = os.tmpname()
        Queue._persist = Persist:new{ path = queue_path, codec = "dump" }
        Queue:clear()
        shown, saved_looper = {}, UIManager.looper
        stub(UIManager, "show", function(_, widget) shown[#shown + 1] = widget end)
        stub(UIManager, "getElapsedTimeSinceBoot", function() return time.s(100) end)
        stub(Client, "_runInSubprocess", function() error("invalid server must not start HTTP") end)
    end)
    after_each(function()
        if new_stub then new_stub:revert(); new_stub = nil end
        Client._runInSubprocess:revert()
        UIManager.show:revert()
        UIManager.getElapsedTimeSinceBoot:revert()
        UIManager.looper = saved_looper
        Queue:clear()
        Queue._persist, Queue._draining, Queue._generation =
            saved_queue.persist, saved_queue.draining, saved_queue.generation
        os.remove(queue_path)
    end)
    local function client(url)
        return Client:new{ custom_url = url, service_spec = "plugins/kosync.koplugin/api.json" }
    end
    for _, url in ipairs{ "http://", "https://", "example.invalid", "", "://" } do
        it("contains the real Spore constructor failure for '" .. url .. "'", function()
            local c = client(url)
            assert.is_nil(c.client)
            assert.are.equal(gettext("Invalid progress sync server address."), c.init_error)
            for _, mode in ipairs{ "default", "turbo" } do
                UIManager.looper = mode == "turbo" and {} or nil
                local calls = {}
                c:get_progress("synthetic", "key", "book", function(...)
                    calls[#calls + 1] = table.pack(...)
                end)
                c:update_progress("synthetic", "key", "book", nil, "10", 0.1, "Reader", "id", function(...)
                    calls[#calls + 1] = table.pack(...)
                end)
                assert.are.equal(2, #calls)
                assert.are.equal(2, calls[1].n)
                assert.are.equal(3, calls[2].n)
                assert.is_false(calls[1][1])
                assert.is_false(calls[2][1])
            end
            for _, method in ipairs{ "register", "authorize" } do
                local ok, body = c[method](c, "synthetic", "key")
                assert.is_false(ok)
                assert.are.equal(c.init_error, body.message)
            end
        end)
    end
    for _, url in ipairs{ "http://127.0.0.1:1234", "https://sync.example.invalid/path", "http://[::1]:1234" } do
        it("still constructs valid custom server '" .. url .. "' without network", function()
            local c = client(url)
            assert.is_table(c.client)
            assert.is_nil(c.init_error)
        end)
    end
    it("clears failure state when explicitly restoring the default server", function()
        local c = client("https://")
        c.custom_url = nil
        c:init()
        assert.is_table(c.client)
        assert.is_nil(c.init_error)
        c.custom_url = "https://"
        c:init()
        assert.is_nil(c.client)
        assert.is_string(c.init_error)
    end)
    local function plugin()
        local document = { file = "synthetic.epub" }
        return setmetatable({
            path = "plugins/kosync.koplugin", device_id = "local-device",
            push_timestamp = 0, pull_timestamp = 0,
            settings = { username = "synthetic", userkey = "key", custom_server = "https://" },
            ui = { document = document }, view = { document = document },
            getDocumentDigest = function() return "book" end,
            getMetadata = function() end,
            getLastProgress = function() return "newer-local" end,
            getLastPercent = function() return 0.5 end,
        }, { __index = KOSync })
    end
    for _, interactive in ipairs{ false, true } do
        it("keeps the reader on a failed pull, interactive=" .. tostring(interactive), function()
            local sync = plugin()
            sync.syncToProgress = function() error("invalid response must not navigate") end
            sync:getProgress(false, interactive)
            assert.are.equal(interactive and 1 or 0, #shown)
            assert.are.equal("https://", sync.settings.custom_server)
        end)
        it("queues failed progress, interactive=" .. tostring(interactive), function()
            plugin():updateProgress(false, interactive)
            assert.are.equal(1, Queue:count())
            assert.are.equal("newer-local", Queue:load()[1].progress)
            assert.are.equal(interactive and 1 or 0, #shown)
        end)
    end
    it("settles a failed queue drain without discarding progress", function()
        Queue:push{ document = "book", progress = "pending" }
        local sent, calls = nil, 0
        plugin():drainQueue(function(count) sent, calls = count, calls + 1 end)
        assert.are.equal(0, sent)
        assert.are.equal(1, calls)
        assert.is_nil(Queue._draining)
        assert.are.equal("pending", Queue:load()[1].progress)
    end)
    it("persists suspend progress even with a malformed server", function()
        plugin():updateProgress(false, false, true)
        assert.are.equal("newer-local", Queue:load()[1].progress)
        assert.is_nil(Queue._draining)
    end)
    it("lets the custom server menu explicitly restore the default", function()
        local sync, items = plugin(), {}
        sync:addToMainMenu(items)
        local input = items.progress_sync.sub_item_table[1].tap_input_func()
        assert.is_true(input.allow_blank_input)
        assert.are.equal(gettext("Leave empty to use default"), input.hint)
        input.callback("")
        assert.is_nil(sync.settings.custom_server)
        assert.is_true(sync.updated)
        assert.is_table(client(sync.settings.custom_server).client)
    end)
    it("passes the restored default server through the production queue drain", function()
        local sync, options, sent = plugin()
        new_stub = stub(Client, "new", function(_, opts)
            options = opts
            return { update_progress = function(_, _, _, _, _, _, _, _, _, callback)
                callback(true, 200)
            end }
        end)
        sync:setCustomServer("")
        Queue:push{ document = "book", progress = "pending", percentage = 0.5,
            device = "Reader", device_id = "local-device" }
        sync:drainQueue(function(count) sent = count end)
        assert.is_table(options)
        assert.is_nil(options.custom_url)
        assert.are.equal("plugins/kosync.koplugin/api.json", options.service_spec)
        assert.are.equal(1, sent)
        assert.are.equal(0, Queue:count())
    end)
end)
