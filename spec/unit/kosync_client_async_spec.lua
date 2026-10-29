require("commonrequire")
local saved_path = package.path
package.path = "plugins/kosync.koplugin/?.lua;" .. package.path
local Queue = require("KOSyncQueue")
local Client = require("KOSyncClient")
package.path = saved_path
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local socketutil = require("socketutil")
local ffiUtil = require("ffi/util")

describe("KOSync default HTTP workers", function()
    local workers, requests, deliveries, middleware, mode, status, body, throws, saved_looper
    before_each(function()
        Queue:clear()
        Client._active_worker, Client._pending_worker = nil, nil
        workers, requests, deliveries, middleware = {}, {}, {}, {}
        mode, status, body, throws = "success", 200, { progress = "12", percentage = 0.5 }, false
        saved_looper, UIManager.looper = UIManager.looper, nil
        stub(Trapper, "wrap", function(_, task) workers[#workers + 1] = task end)
        stub(Trapper, "dismissableRunInSubprocess", function(_, task)
            if mode == "cancel" then return false end
            if mode == "start_failed" or mode == "read_failed" then return false, nil, mode end
            if mode == "empty" then return true end
            return true, task()
        end)
        stub(socketutil, "set_timeout")
        stub(socketutil, "reset_timeout")
        stub(UIManager, "setInputTimeout")
    end)
    after_each(function()
        Client._active_worker, Client._pending_worker = nil, nil
        Trapper.wrap:revert()
        Trapper.dismissableRunInSubprocess:revert()
        socketutil.set_timeout:revert()
        socketutil.reset_timeout:revert()
        UIManager.setInputTimeout:revert()
        UIManager.looper = saved_looper
        Queue:clear()
    end)
    local function client()
        local transport = {
            reset_middlewares = function() middleware = {} end,
            enable = function(_, name) middleware[name] = true end,
        }
        for _, method in ipairs{ "get_progress", "update_progress", "authorize", "register" } do
            transport[method] = function(_, params)
                requests[#requests + 1] = { method = method, params = params }
                if throws then error("synthetic HTTP failure") end
                return { status = status, body = body }
            end
        end
        return setmetatable({ client = transport }, { __index = Client })
    end
    local function delivered(...) deliveries[#deliveries + 1] = table.pack(...) end
    local function get(c, callback) c:get_progress("synthetic", "key", "book", callback or delivered) end
    local function put(c, callback)
        c:update_progress("synthetic", "key", "book", { title = "synthetic" }, 12, 0.5,
            "synthetic-device", "device-id", callback or delivered)
    end
    it("defers default GET transport and preserves the two-value callback", function()
        get(client())
        assert.are.equal(0, #requests)
        assert.are.equal(0, #deliveries)
        workers[1]()
        assert.are.equal(1, #requests)
        assert.are.equal("get_progress", requests[1].method)
        assert.are.equal(2, deliveries[1].n)
        assert.is_true(deliveries[1][1])
        assert.are.same(body, deliveries[1][2])
        assert.is_nil(Client._active_worker)
    end)
    it("defers PUT and preserves parameters, HTTP status and body", function()
        put(client())
        assert.are.equal(0, #requests)
        workers[1]()
        assert.are.equal("12", requests[1].params.progress)
        assert.are.equal(0.5, requests[1].params.percentage)
        assert.are.equal("device-id", requests[1].params.device_id)
        assert.are.equal(3, deliveries[1].n)
        assert.is_true(deliveries[1][1])
        assert.are.equal(200, deliveries[1][2])
        assert.are.same(body, deliveries[1][3])
    end)
    it("preserves non-success HTTP response details", function()
        status, body = 503, { message = "unavailable" }
        put(client())
        workers[1]()
        assert.is_false(deliveries[1][1])
        assert.are.equal(503, deliveries[1][2])
        assert.are.same(body, deliveries[1][3])
    end)
    it("delivers transport failures once and resets the worker's timeouts", function()
        throws = true
        get(client())
        workers[1]()
        assert.are.equal(1, #deliveries)
        assert.is_false(deliveries[1][1])
        assert.is_nil(deliveries[1][2])
        assert.stub(socketutil.reset_timeout).was_called(1)
        assert.is_nil(Client._active_worker)
    end)
    for _, failure in ipairs{ "cancel", "start_failed", "read_failed", "empty" } do
        it("cleans up " .. failure .. " and permits a later retry", function()
            mode = failure
            get(client())
            workers[1]()
            assert.are.equal(0, #requests)
            assert.are.equal(1, #deliveries)
            assert.is_false(deliveries[1][1])
            assert.is_nil(Client._active_worker)
            mode = "success"
            get(client())
            workers[2]()
            assert.is_true(deliveries[2][1])
        end)
    end
    it("bounds concurrency across clients to one worker and one pending request", function()
        get(client())
        put(client())
        get(client())
        assert.are.equal(1, #workers)
        assert.are.equal(1, #deliveries)
        assert.is_false(deliveries[1][1])
        workers[1]()
        assert.are.equal(2, #workers)
        assert.are.equal(1, #requests)
        assert.is_truthy(Client._active_worker)
        workers[2]()
        assert.are.equal(2, #requests)
        assert.is_nil(Client._active_worker)
        assert.is_nil(Client._pending_worker)
    end)
    it("rejects busy authentication without queuing additional credentials", function()
        get(client())
        local called, reason
        client():_runInSubprocess(function() called = true end, function(_, _, why) reason = why end, "Login")
        assert.are.equal("busy", reason)
        assert.is_nil(called)
        assert.is_nil(Client._pending_worker)
        workers[1]()
    end)
    it("does not start a queued request from an invalidated account generation", function()
        get(client())
        put(client())
        Queue:clear()
        workers[1]()
        assert.are.equal(1, #workers)
        assert.are.equal(1, #requests)
        assert.are.equal(2, #deliveries)
        assert.is_false(deliveries[2][1])
        assert.is_nil(Client._active_worker)
    end)
    it("releases its slot and advances pending work even if delivery raises", function()
        get(client(), function() error("synthetic callback failure") end)
        get(client())
        workers[1]()
        assert.are.equal(2, #workers)
        workers[2]()
        assert.is_true(deliveries[1][1])
        assert.is_nil(Client._active_worker)
    end)
    it("bounds requests scheduled reentrantly by a completion callback", function()
        get(client(), function() put(client()); get(client()) end)
        workers[1]()
        assert.are.equal(2, #workers)
        assert.are.equal(1, #deliveries)
        assert.is_false(deliveries[1][1])
        workers[2]()
        assert.are.equal(2, #requests)
        assert.is_nil(Client._active_worker)
    end)
    it("fails explicitly without subprocess capability instead of running HTTP inline", function()
        local run = ffiUtil.runInSubProcess
        ffiUtil.runInSubProcess = nil
        local ok, err = pcall(function() get(client()) end)
        ffiUtil.runInSubProcess = run
        assert.is_true(ok, err)
        assert.are.equal(0, #requests)
        assert.are.equal(0, #workers)
        assert.is_false(deliveries[1][1])
        assert.is_nil(Client._active_worker)
    end)
    it("preserves the three-value PUT failure callback on cancellation", function()
        mode = "cancel"
        put(client())
        workers[1]()
        assert.are.equal(3, deliveries[1].n)
        assert.is_false(deliveries[1][1])
        assert.is_nil(deliveries[1][2])
        assert.is_nil(deliveries[1][3])
    end)
    it("preserves the existing Turbo transport path", function()
        UIManager.looper = {}
        get(client())
        assert.are.equal(0, #workers)
        assert.is_true(middleware.AsyncHTTP)
        assert.is_true(deliveries[1][1])
        assert.stub(UIManager.setInputTimeout).was_called(1)
    end)
    it("keeps low-level authorize and register synchronous", function()
        local c = client()
        assert.is_true(c:authorize("synthetic", "key"))
        status = 201
        assert.is_true(c:register("synthetic", "key"))
        assert.are.equal(2, #requests)
        assert.are.equal(0, #workers)
    end)
end)
