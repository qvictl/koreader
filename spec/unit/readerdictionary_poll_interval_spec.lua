require("commonrequire")
local rd = require("apps/reader/modules/readerdictionary")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

describe("ReaderDictionary asynchronous polling latency", function()
    it("should yield but check a ready short lookup within five milliseconds", function()
        local scheduled
        local schedule = stub(UIManager, "scheduleIn", function(_, delay, callback)
            scheduled = { delay = delay, callback = callback }
        end)
        finally(function() schedule:revert() end)
        local completed, output
        local process = {
            poll = function() return true end,
            getOutput = function() return "ready" end,
        }
        local worker = coroutine.create(function()
            completed, output = rd:waitForSdcv(process, { dismiss_callback = function() end })
        end)
        assert.is_true(coroutine.resume(worker))
        assert.are.equal("suspended", coroutine.status(worker))
        assert.is_nil(completed)
        assert.is_true(scheduled.delay > 0 and scheduled.delay <= 0.005)
        scheduled.callback()
        assert.are.equal("dead", coroutine.status(worker))
        assert.is_true(completed)
        assert.are.equal("ready", output)
    end)

    it("should back off long lookups instead of retaining the initial polling rate", function()
        local clock = time.s(10)
        local now = stub(time, "now", function() return clock end)
        local scheduled = {}
        local schedule = stub(UIManager, "scheduleIn", function(_, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end)
        finally(function() schedule:revert(); now:revert() end)
        local ready, completed = false, nil
        local process = {
            poll = function() return ready end,
            getOutput = function() return "ready" end,
        }
        local worker = coroutine.create(function()
            completed = rd:waitForSdcv(process, { dismiss_callback = function() end })
        end)
        assert.is_true(coroutine.resume(worker))
        clock = clock + time.ms(500)
        scheduled[1].callback()
        assert.is_nil(completed)
        assert.is_true(scheduled[2].delay >= 0.05 and scheduled[2].delay <= 0.25)
        clock = clock + time.s(10)
        scheduled[2].callback()
        assert.is_true(scheduled[3].delay >= 0.2 and scheduled[3].delay <= 0.25)
        ready = true
        scheduled[3].callback()
        assert.is_true(completed)
        assert.are.equal("dead", coroutine.status(worker))
    end)

end)
