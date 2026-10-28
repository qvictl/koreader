-- Trapper:dismissablePopen() with commands that exit without printing anything.
-- Its pipe polling used to rely only on FIONREAD, which says 0 both for "no output
-- yet" and "the command exited without output": such a command was polled forever
-- (one wakeup per second, never completing), and once dismissed, its collector
-- rescheduled itself every 5 s forever, leaking the pipe and a zombie shell.
describe("Trapper:dismissablePopen and commands without output", function()
    local Trapper, UIManager, ffiutil
    local tasks, saved

    local function runTasks(max)
        local n = 0
        while #tasks > 0 and n < max do
            local t = table.remove(tasks, 1)
            n = n + 1
            ffiutil.usleep(5000) -- let the shell make progress
            t.fn()
        end
        return n
    end

    setup(function()
        require("commonrequire")
        Trapper = require("ui/trapper")
        UIManager = require("ui/uimanager")
        ffiutil = require("ffi/util")
    end)

    before_each(function()
        tasks = {}
        saved = {}
        for _, k in ipairs{"scheduleIn", "unschedule", "show", "close", "forceRePaint"} do
            saved[k] = UIManager[k]
        end
        UIManager.scheduleIn = function(_, delay, fn) table.insert(tasks, { delay = delay, fn = fn }) end
        UIManager.unschedule = function(_, fn)
            for i = #tasks, 1, -1 do
                if tasks[i].fn == fn then table.remove(tasks, i) end
            end
        end
        UIManager.show = function() end
        UIManager.close = function() end
        UIManager.forceRePaint = function() end
    end)

    after_each(function()
        for k, v in pairs(saved) do UIManager[k] = v end
    end)

    it("completes with an empty output when the command exits silently", function()
        local res = {}
        Trapper:wrap(function()
            res.completed, res.output = Trapper:dismissablePopen("true", false)
            res.done = true
        end)
        runTasks(1000)
        assert.is_true(res.done)
        assert.is_true(res.completed)
        assert.are.equal("", res.output)
        assert.are.equal(0, #tasks)
    end)

    it("still returns the output of a command that prints something", function()
        local res = {}
        Trapper:wrap(function()
            res.completed, res.output = Trapper:dismissablePopen("printf done", false)
            res.done = true
        end)
        runTasks(1000)
        assert.is_true(res.completed)
        assert.are.equal("done", res.output)
    end)

    it("collects a dismissed command once it exits silently, and stops polling", function()
        local flag = os.tmpname()
        os.remove(flag)
        finally(function()
            -- (On failure too: let the command exit and its collector close the pipe, then clean up.)
            local fh = io.open(flag, "w")
            if fh then fh:close() end
            runTasks(1000)
            os.remove(flag)
        end)
        local widget = { dismiss_callback = nil }
        local res = {}
        Trapper:wrap(function()
            -- (released by the flag file, which the finally above creates even on failure)
            res.completed, res.output = Trapper:dismissablePopen(
                "while [ ! -e '" .. flag .. "' ]; do sleep 0.01; done", widget)
            res.done = true
        end)
        runTasks(2) -- still running
        assert.is_nil(res.done)
        widget.dismiss_callback() -- the user taps
        assert.is_true(res.done)
        assert.is_false(res.completed)
        local f = io.open(flag, "w")
        f:close()
        -- The 5 s collector runs until the command is done, finds the pipe at EOF, closes it,
        -- and doesn't reschedule itself (it used to, forever).
        runTasks(1000)
        assert.are.equal(0, #tasks)
    end)
end)
