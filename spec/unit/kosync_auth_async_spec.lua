require("commonrequire")
local saved_path = package.path
package.path = "plugins/kosync.koplugin/?.lua;" .. package.path
local Queue = require("KOSyncQueue")
local Client = require("KOSyncClient")
local KOSync = dofile("plugins/kosync.koplugin/main.lua")
package.path = saved_path
local UIManager = require("ui/uimanager")
local Device = require("device")
describe("KOSync asynchronous authentication", function()
    local jobs, shown, calls, raises, accepted, response
    before_each(function()
        Queue:clear()
        jobs, shown, calls, raises, accepted, response = {}, {}, {}, false, true, { message = "synthetic" }
        stub(UIManager, "show", function(_, widget) shown[#shown + 1] = widget end)
        stub(UIManager, "isWidgetShown", function(_, widget) return widget.alive end)
        stub(Device, "setIgnoreInput")
        stub(Client, "new", function()
            local c = {}
            function c:_runInSubprocess(task, done, text) jobs[#jobs + 1] = { task = task, done = done, text = text } end
            for _, method in ipairs{ "register", "authorize" } do
                c[method] = function(_, username, key)
                    calls[#calls + 1] = { method = method, username = username, key = key }
                    if raises then error("synthetic authentication failure") end
                    return accepted, response
                end
            end
            return c
        end)
    end)
    after_each(function()
        UIManager.show:revert()
        UIManager.isWidgetShown:revert()
        Device.setIgnoreInput:revert()
        Client.new:revert()
        Queue:clear()
    end)
    local function plugin()
        return setmetatable({ path = "plugins/kosync.koplugin", settings = {},
            ui = { document = { file = "synthetic.epub" } } }, { __index = KOSync })
    end
    local function finish(job)
        local result = table.pack(job.task())
        job.done(true, unpack(result, 1, result.n))
    end
    for _, method in ipairs{ "doLogin", "doRegister" } do
        it("applies " .. method .. " only after parent delivery", function()
            local sync = plugin()
            sync[method](sync, "synthetic", "secret")
            assert.are.equal(0, #calls)
            local result = table.pack(jobs[1].task())
            assert.are_not.equal("secret", calls[1].key)
            assert.is_nil(sync.settings.userkey)
            jobs[1].done(true, unpack(result, 1, result.n))
            assert.are.equal("synthetic", sync.settings.username)
            assert.are.equal(calls[1].key, sync.settings.userkey)
            assert.is_true(sync.updated)
            assert.stub(Device.setIgnoreInput).was_not_called()
        end)
    end
    for _, change in ipairs{ "close", "replace", "logout", "server" } do
        it("rejects credentials after " .. change, function()
            local sync = plugin()
            sync:doLogin("synthetic", "secret")
            if change == "close" then sync.ui.document = nil
            elseif change == "replace" then sync.ui = { document = { file = "other.epub" } }
            elseif change == "logout" then sync:logout()
            else sync:setCustomServer("https://synthetic.invalid") end
            finish(jobs[1])
            assert.is_nil(sync.settings.userkey)
            assert.is_nil(sync.updated)
            assert.are.equal(0, #shown)
        end)
    end
    for _, alive in ipairs{ false, true } do
        it("updates an authentication menu only when shown: " .. tostring(alive), function()
            local sync, updates = plugin(), 0
            local menu = { alive = alive, updateItems = function() updates = updates + 1 end }
            sync[alive and "doRegister" or "doLogin"](sync, "synthetic", "secret", menu)
            finish(jobs[1])
            assert.are.equal(alive and 1 or 0, updates)
            assert.are.equal("synthetic", sync.settings.username)
        end)
    end
    it("ignores cancellation and allows a successful retry", function()
        local sync = plugin()
        sync:doLogin("synthetic", "secret")
        jobs[1].done(false)
        assert.is_nil(sync.settings.userkey)
        assert.are.equal(0, #shown)
        sync:doLogin("synthetic", "secret")
        finish(jobs[2])
        assert.are.equal("synthetic", sync.settings.username)
    end)
    for _, reason in ipairs{ "start_failed", "read_failed", "busy" } do
        it("reports " .. reason .. " without saving credentials", function()
            local sync = plugin()
            sync:doLogin("synthetic", "secret")
            jobs[1].done(false, nil, reason)
            assert.is_nil(sync.settings.userkey)
            assert.are.equal(1, #shown)
        end)
    end
    it("reports an authentication exception", function()
        local sync = plugin()
        raises = true
        sync:doLogin("synthetic", "secret")
        finish(jobs[1])
        assert.is_nil(sync.settings.userkey)
        assert.is_truthy(shown[1].text:find("synthetic authentication failure", 1, true))
    end)
    it("reports a registration exception", function()
        local sync = plugin()
        raises = true
        sync:doRegister("synthetic", "secret")
        finish(jobs[1])
        assert.is_nil(sync.settings.userkey)
        assert.is_truthy(shown[1].text:find("synthetic authentication failure", 1, true))
    end)
    for _, method in ipairs{ "doLogin", "doRegister" } do
        for _, has_body in ipairs{ false, true } do
            it("reports " .. method .. " rejection with response body: " .. tostring(has_body), function()
                local sync = plugin()
                accepted, response = false, has_body and { message = "synthetic rejection" } or nil
                sync[method](sync, "synthetic", "secret")
                finish(jobs[1])
                assert.is_nil(sync.settings.userkey)
                assert.are.equal(1, #shown)
                if has_body then assert.are.equal("synthetic rejection", shown[1].text) end
            end)
        end
        it("reports " .. method .. " without a returned exception message", function()
            local sync = plugin()
            sync[method](sync, "synthetic", "secret")
            jobs[1].done(true, false, nil)
            assert.is_nil(sync.settings.userkey)
            assert.is_truthy(shown[1].text:find("unknown error", 1, true))
        end)
    end

end)
