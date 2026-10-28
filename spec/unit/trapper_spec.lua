-- Unit tests for frontend/ui/trapper.lua.
--
-- Trapper hides coroutines behind a linear API: the wrapped job yields to
-- UIManager and gets resumed either by a scheduled "go on" poll or by a widget
-- dismiss_callback (a user tap). Here UIManager's scheduler is replaced by a
-- FIFO queue that the tests drive by hand, so that polls and taps happen in a
-- deterministic order. dismissableRunInSubprocess() and dismissablePopen() use
-- real forked processes / shells (short-lived, synchronised via flag files
-- instead of sleeps).
describe("Trapper module", function()
    local Trapper, UIManager, ffiutil, logger, lfs, ffi, C
    local ConfirmBox, InfoMessage, TrapWidget

    local tasks      -- scheduled { delay = s, fn = f } in FIFO order
    local shown      -- widgets passed to UIManager:show()
    local closed     -- widgets passed to UIManager:close()
    local next_ticks -- actions passed to UIManager:nextTick()
    local repaints   -- number of UIManager:forceRePaint() calls
    local saved_ui
    local orig_run_in_subprocess, orig_read_all
    local orig_command_pipe, orig_read_available
    local guard_blocking_reads
    local child_pids, child_fds
    local tmp_files, gate_releases

    local function replaceUI(name, fn)
        saved_ui[name] = UIManager[name]
        UIManager[name] = fn
    end

    local function tmpPath()
        local path = os.tmpname()
        os.remove(path)
        table.insert(tmp_files, path)
        return path
    end

    local function touch(path)
        local f = assert(io.open(path, "w"))
        f:close()
    end

    -- Busy-wait (in the child) for a flag file, capped so that a failing test
    -- never leaves a process behind for long.
    local function waitForFile(path)
        for _ = 1, 2000 do
            if lfs.attributes(path, "mode") then return true end
            ffiutil.usleep(5000)
        end
        return false
    end

    -- A worker waits for an explicit parent release, with no timing assumption.
    local function ipcGate()
        guard_blocking_reads = true
        local pair = ffi.new("int[2]")
        assert.are.equal(0, C.pipe(pair))
        local reader, writer = tonumber(pair[0]), tonumber(pair[1])
        local released = false
        local function release()
            if released then return end
            released = true
            C.write(writer, "x", 1)
            C.close(writer)
            C.close(reader)
        end
        gate_releases[#gate_releases + 1] = release
        return function()
            released = true
            C.close(writer)
            local byte = ffi.new("char[1]")
            local count
            repeat count = C.read(reader, byte, 1) until count >= 0 or ffi.errno() ~= C.EINTR
            C.close(reader)
            assert.are.equal(1, count)
        end, release
    end

    -- Run a function under Trapper:wrap(), recording its return values.
    local function runWrapped(func)
        local res = { done = false }
        res.wrap_ret = table.pack(Trapper:wrap(function()
            res.values = table.pack(func())
            res.done = true
        end))
        return res
    end

    -- Run the next scheduled task (after a short real pause, so that real
    -- subprocesses make progress), with an optional per-iteration hook.
    local function runNextTask(pause_us)
        local t = table.remove(tasks, 1)
        if not t then return false end
        ffiutil.usleep(pause_us or 2000)
        t.fn()
        return t
    end

    local function runUntil(cond, max_iter, hook)
        for i = 1, max_iter or 2000 do
            if cond() then return true end
            if hook then hook(i) end
            if not runNextTask() then break end
        end
        return cond()
    end

    local function isReaped(pid)
        -- kill(pid, 0) succeeds on a live process or an un-reaped zombie
        return C.kill(pid, 0) ~= 0
    end

    setup(function()
        require("commonrequire")
        Trapper = require("ui/trapper")
        UIManager = require("ui/uimanager")
        ffiutil = require("ffi/util")
        logger = require("logger")
        lfs = require("libs/libkoreader-lfs")
        ffi = require("ffi")
        C = ffi.C
        ConfirmBox = require("ui/widget/confirmbox")
        InfoMessage = require("ui/widget/infomessage")
        TrapWidget = require("ui/widget/trapwidget")
    end)

    before_each(function()
        tasks, shown, closed, next_ticks, repaints = {}, {}, {}, {}, 0
        saved_ui = {}
        child_pids, child_fds = {}, {}
        tmp_files, gate_releases = {}, {}
        guard_blocking_reads = false
        orig_read_all = ffiutil.readAllFromFD
        local parent = C.getpid()
        ffiutil.readAllFromFD = function(fd)
            if guard_blocking_reads and C.getpid() == parent then
                local ready = ffi.new("struct pollfd[1]")
                ready[0].fd, ready[0].events = fd, C.POLLIN
                C.poll(ready, 1, 0)
                assert.is_true(bit.band(ready[0].revents, C.POLLHUP) ~= 0,
                    "blocking result read while a writer is gated")
            end
            return orig_read_all(fd)
        end
        replaceUI("scheduleIn", function(_, delay, fn)
            table.insert(tasks, { delay = delay, fn = fn })
        end)
        replaceUI("unschedule", function(_, fn)
            for i = #tasks, 1, -1 do
                if tasks[i].fn == fn then table.remove(tasks, i) end
            end
        end)
        replaceUI("nextTick", function(_, fn) table.insert(next_ticks, fn) end)
        replaceUI("show", function(_, w) table.insert(shown, w) end)
        replaceUI("close", function(_, w) table.insert(closed, w) end)
        replaceUI("forceRePaint", function() repaints = repaints + 1 end)
        replaceUI("preventStandby", spy.new(function() end))
        replaceUI("allowStandby", spy.new(function() end))
        orig_command_pipe = ffiutil.openCommandPipe
        orig_read_available = ffiutil.readAvailableFromFD
        orig_run_in_subprocess = ffiutil.runInSubProcess
        ffiutil.runInSubProcess = function(...)
            local pid, fd = orig_run_in_subprocess(...)
            if pid then
                table.insert(child_pids, pid)
                table.insert(child_fds, fd)
            end
            return pid, fd
        end
        Trapper.current_widget = nil
        Trapper:reset()
    end)

    after_each(function()
        ffiutil.openCommandPipe = orig_command_pipe
        ffiutil.readAvailableFromFD = orig_read_available
        ffiutil.readAllFromFD = orig_read_all
        ffiutil.runInSubProcess = orig_run_in_subprocess
        for name, fn in pairs(saved_ui) do
            UIManager[name] = fn
        end
        -- Never leave a child (or a zombie) behind, and release any shell
        -- still waiting for its flag file (a pending popen() would otherwise
        -- block the final pclose() at exit forever).
        for _, path in ipairs(tmp_files) do
            touch(path)
        end
        for _, release in ipairs(gate_releases) do release() end
        for _, pid in ipairs(child_pids) do
            ffiutil.terminateSubProcess(pid)
            ffiutil.isSubProcessDone(pid, true)
        end
        for _, path in ipairs(tmp_files) do
            os.remove(path)
        end
        Trapper.current_widget = nil
        Trapper:reset()
    end)

    describe("wrap", function()
        it("runs the function in a coroutine and brackets it with standby prevention", function()
            local wrapped_inside
            assert.is_false(Trapper:isWrapped())
            local ok, ret = Trapper:wrap(function()
                wrapped_inside = Trapper:isWrapped()
            end)
            assert.is_true(ok)
            assert.is_true(ret)
            assert.is_true(wrapped_inside)
            assert.spy(UIManager.preventStandby).was.called(1)
            assert.spy(UIManager.allowStandby).was.called(1)
        end)

        it("catches errors in the wrapped function, logs them and still allows standby", function()
            local warn = spy.on(logger, "warn")
            local ok, ret = Trapper:wrap(function() error("job failed") end)
            logger.warn:revert()
            assert.is_true(ok)
            assert.is_false(ret)
            assert.spy(warn).was.called_with("error in wrapped function:", match.is_string())
            assert.spy(UIManager.allowStandby).was.called(1)
        end)

        it("returns at the first yield, the job being resumed later", function()
            local res = runWrapped(function() return Trapper:confirm("Sure?") end)
            assert.is_false(res.done)
            assert.are.same({ true, n = 1 }, res.wrap_ret)
            -- standby is only allowed again once the job is over
            assert.spy(UIManager.allowStandby).was.called(0)
            Trapper.current_widget.ok_callback()
            assert.is_true(res.done)
            assert.spy(UIManager.allowStandby).was.called(1)
        end)
    end)

    describe("when not wrapped", function()
        it("info() and confirm() fall back to non-UI defaults", function()
            assert.is_true(Trapper:info("progress"))
            assert.is_true(Trapper:confirm("Proceed?", "No", "Yes"))
            assert.are.equal(0, #shown)
            assert.are.equal(0, #tasks)
        end)

        it("setPausedText() and clear() do nothing", function()
            Trapper:setPausedText("Paused!", "Stop", "Go")
            assert.is_nil(Trapper.paused_text)
            local w = {}
            Trapper.current_widget = w
            Trapper:clear()
            assert.are.equal(w, Trapper.current_widget)
            assert.are.equal(0, #closed)
        end)

        it("dismissableRunInSubprocess() runs the task in-process, blocking", function()
            local ran_in_this_process = false
            local completed, a, b = Trapper:dismissableRunInSubprocess(function()
                ran_in_this_process = true
                return "a", { b = 2 }
            end, "Working")
            assert.is_true(ran_in_this_process)
            assert.is_true(completed)
            assert.are.equal("a", a)
            assert.are.same({ b = 2 }, b)
            assert.are.equal(0, #shown)
            assert.are.equal(0, #child_pids)
        end)

        it("treats LuaJIT main-thread coroutine reporting as unwrapped", function()
            -- luacheck: push ignore 122
            local running = coroutine.running
            coroutine.running = function() return coroutine.create(function() end), true end
            local ok, err = xpcall(function()
                local completed, result = Trapper:dismissableRunInSubprocess(function() return "direct" end)
                assert.is_true(completed)
                assert.are.equal("direct", result)
                assert.are.equal(0, #child_pids)
                assert.are.equal(0, #shown)
            end, debug.traceback)
            coroutine.running = running
            -- luacheck: pop
            if not ok then error(err, 0) end
        end)

        it("dismissablePopen() falls back to a blocking io.popen()", function()
            local completed, output = Trapper:dismissablePopen("echo hello")
            assert.is_true(completed)
            assert.are.equal("hello\n", output)
            assert.are.equal(0, #shown)
        end)

        it("dismissablePopen() uses the blocking fallback for an explicit main-thread flag", function()
            local running_stub = stub(coroutine, "running", function() return {}, true end)
            local start = spy.on(ffiutil, "openCommandPipe")
            local ok, completed, output = pcall(function()
                return Trapper:dismissablePopen("printf main-thread", "unused")
            end)
            running_stub:revert()
            ffiutil.openCommandPipe:revert()
            assert.is_true(ok)
            assert.is_true(completed)
            assert.are.equal("main-thread", output)
            assert.spy(start).was_not.called()
            assert.are.equal(0, #shown)
        end)

        it("dismissablePopen() reports failure when io.popen() fails", function()
            local orig_popen = io.popen
            io.popen = function() return nil, "cannot fork" end -- luacheck: ignore
            local completed, output = Trapper:dismissablePopen("echo hello")
            io.popen = orig_popen -- luacheck: ignore
            assert.is_false(completed)
            assert.is_nil(output)
        end)
    end)

    describe("clear and reset", function()
        it("clear() closes the left-over widget when wrapped", function()
            local w = {}
            Trapper:wrap(function()
                Trapper.current_widget = w
                Trapper:clear()
            end)
            assert.is_nil(Trapper.current_widget)
            assert.are.same({ w }, closed)
            assert.are.equal(1, repaints)
        end)

        it("reset() clears the paused texts set by setPausedText()", function()
            Trapper:wrap(function()
                Trapper:setPausedText("Paused!", "Stop", "Go")
            end)
            assert.are.equal("Paused!", Trapper.paused_text)
            assert.are.equal("Stop", Trapper.paused_abort_text)
            assert.are.equal("Go", Trapper.paused_continue_text)
            assert.is_true(Trapper:reset())
            assert.is_nil(Trapper.paused_text)
            assert.is_nil(Trapper.paused_abort_text)
            assert.is_nil(Trapper.paused_continue_text)
        end)
    end)

    describe("confirm", function()
        it("shows a ConfirmBox and returns true on OK, closing the previous widget", function()
            local previous = {}
            Trapper.current_widget = previous
            local res = runWrapped(function() return Trapper:confirm("Delete?", "Keep", "Delete") end)
            assert.is_false(res.done)
            local box = Trapper.current_widget
            assert.are.equal(ConfirmBox, getmetatable(box).__index)
            assert.are.same({ previous }, closed)
            assert.are.equal(box, shown[1])
            assert.are.equal("Delete?", box.text)
            assert.are.equal("Delete", box.ok_text)
            assert.are.equal("Keep", box.cancel_text)
            box.ok_callback()
            assert.is_true(res.done)
            assert.are.same({ true, n = 1 }, res.values)
        end)

        it("returns false on Cancel", function()
            local res = runWrapped(function() return Trapper:confirm("Delete?") end)
            Trapper.current_widget.cancel_callback()
            assert.is_true(res.done)
            assert.are.same({ false, n = 1 }, res.values)
        end)
    end)

    describe("info", function()
        it("shows a dismissable InfoMessage without yielding the first time", function()
            local res = runWrapped(function() return Trapper:info("Step 1") end)
            assert.is_true(res.done)
            assert.are.same({ true, n = 1 }, res.values)
            local msg = Trapper.current_widget
            assert.are.equal(InfoMessage, getmetatable(msg).__index)
            assert.is_true(msg.is_infomessage)
            assert.are.equal("Step 1", msg.text)
            assert.are.equal(msg, shown[1])
            assert.are.equal(1, repaints)
            assert.are.equal(0, #tasks)
        end)

        it("polls for a dismissal and replaces the InfoMessage when none happened", function()
            local res = runWrapped(function()
                Trapper:info("Step 1")
                return Trapper:info("Step 2")
            end)
            assert.is_false(res.done)
            local first = Trapper.current_widget
            assert.are.equal(1, #tasks)
            assert.are.equal(0.1, tasks[1].delay)
            runNextTask(0)
            assert.is_true(res.done)
            assert.are.same({ true, n = 1 }, res.values)
            assert.are_not.equal(first, Trapper.current_widget)
            assert.are.equal("Step 2", Trapper.current_widget.text)
            assert.are.same({ first }, closed)
        end)

        it("skips the dismissal poll with skip_dismiss_check", function()
            local res = runWrapped(function()
                Trapper:info("Step 1")
                return Trapper:info("Step 2", false, true)
            end)
            assert.is_true(res.done)
            assert.are.equal(0, #tasks)
            assert.are.equal("Step 2", Trapper.current_widget.text)
        end)

        it("asks for confirmation when dismissed, and aborts on Abort", function()
            local res = runWrapped(function()
                Trapper:setPausedText("Stop the job?", "Stop", "Go on")
                Trapper:info("Step 1")
                return Trapper:info("Step 2")
            end)
            local msg = Trapper.current_widget
            msg.dismiss_callback() -- user tapped the InfoMessage
            -- the pending poll is unscheduled, a ConfirmBox is shown instead
            assert.are.equal(0, #tasks)
            assert.is_false(res.done)
            local box = shown[#shown]
            assert.are.equal(ConfirmBox, getmetatable(box).__index)
            assert.are.equal("Stop the job?", box.text)
            assert.are.equal("Stop", box.ok_text)
            assert.are.equal("Go on", box.cancel_text)
            box.ok_callback()
            assert.is_true(res.done)
            assert.are.same({ false, n = 1 }, res.values)
            assert.are.equal(box, closed[#closed - 1])
            assert.are.equal(msg, closed[#closed])
        end)

        it("uses default Paused/Abort/Continue texts, and resumes on Continue", function()
            local res = runWrapped(function()
                Trapper:info("Step 1")
                return Trapper:info("Step 2")
            end)
            local msg = Trapper.current_widget
            msg.dismiss_callback()
            local box = shown[#shown]
            assert.are.equal("Paused", box.text)
            assert.are.equal("Abort", box.ok_text)
            assert.are.equal("Continue", box.cancel_text)
            local nb_shown = #shown
            box.cancel_callback()
            assert.is_true(res.done)
            assert.are.same({ true, n = 1 }, res.values)
            -- the dismissed InfoMessage was resurrected and shown again before
            -- being replaced by the new one
            assert.are.equal(msg, shown[nb_shown + 1])
            assert.are.equal("Step 2", Trapper.current_widget.text)
        end)

        it("updates the text in place with fast_refresh", function()
            local res = runWrapped(function()
                Trapper:info("Step 1")
                return Trapper:info("Step 2", true, true)
            end)
            assert.is_true(res.done)
            assert.are.same({ true, n = 1 }, res.values)
            -- same widget, new text, no close/show cycle
            assert.are.equal(1, #shown)
            assert.are.equal(0, #closed)
            assert.are.equal(shown[1], Trapper.current_widget)
            assert.are.equal("Step 2", Trapper.current_widget.text)
        end)
    end)

    describe("dismissableRunInSubprocess", function()
        local function runSub(task, trap, simple)
            return runWrapped(function()
                return Trapper:dismissableRunInSubprocess(task, trap, simple)
            end)
        end
        local function done(res) return function() return res.done end end

        it("returns complex results, keeping nil and false values", function()
            local res = runSub(function()
                return { a = 1, nested = { "x", true } }, nil, false, "str", nil
            end, "Working…")
            -- a visible TrapWidget with our text is shown while waiting
            local trap = shown[1]
            assert.are.equal(TrapWidget, getmetatable(trap).__index)
            assert.are.equal("Working…", trap.text)
            assert.is_false(res.done)
            assert.is_true(runUntil(done(res)))
            assert.are.same({ true, { a = 1, nested = { "x", true } }, nil, false, "str", nil, n = 6 }, res.values)
            assert.are.same({ trap }, closed)
            assert.are.equal(2, repaints)
            -- the child was collected
            assert.is_true(runUntil(function() return isReaped(child_pids[1]) end, 500))
        end)

        it("releases transport chunks before decoding results", function()
            local weak = setmetatable({}, { __mode = "v" })
            local concat, decode = table.concat, require("string.buffer").decode
            table.concat = function(chunks, ...) -- luacheck: ignore 122
                weak[1] = chunks
                return concat(chunks, ...)
            end
            local checked = false
            stub(require("string.buffer"), "decode", function(...)
                collectgarbage("collect")
                assert.is_nil(weak[1])
                checked = true
                return decode(...)
            end)
            local ok, err = pcall(function()
                local res = runSub(function() return { payload = "transport" } end)
                assert.is_true(runUntil(done(res)))
                assert.is_true(res.values[1])
                assert.is_true(checked)
            end)
            table.concat = concat -- luacheck: ignore 122
            require("string.buffer").decode:revert()
            assert(ok, err)
        end)

        it("returns a simple string with task_returns_simple_string", function()
            local res = runSub(function() return "plain text" end, nil, true)
            assert.is_true(runUntil(done(res)))
            assert.are.same({ true, "plain text", n = 2 }, res.values)
        end)

        it("returns only completed when a simple-string task returns nil or a non-string", function()
            local res = runSub(function() return nil end, nil, true)
            assert.is_true(runUntil(done(res)))
            assert.are.same({ true, n = 1 }, res.values)
            res = runSub(function() return 42 end, nil, true)
            assert.is_true(runUntil(done(res)))
            assert.are.same({ true, n = 1 }, res.values)
        end)

        it("reads a result larger than the pipe buffer while the child is still writing", function()
            local size = 1024 * 1024
            local res = runSub(function() return string.rep("x", size) end, nil, true)
            assert.is_true(runUntil(done(res)))
            assert.is_true(res.values[1])
            assert.are.equal(size, #res.values[2])
            assert.are.equal(string.rep("x", size), res.values[2])
            assert.is_true(runUntil(function() return #tasks == 0 end, 500))
            assert.is_true(runUntil(function() return isReaped(child_pids[1]) end, 500))
        end)

        it("schedules a reaper when EOF arrives while the worker is alive", function()
            local await_release, release = ipcGate()
            local await_ready, ready = ipcGate()
            local spawn = ffiutil.runInSubProcess
            ffiutil.runInSubProcess = function(_, with_pipe)
                return spawn(function(_, writer)
                    ffiutil.writeToFD(writer, "complete", true)
                    ready()
                    await_release()
                end, with_pipe)
            end
            local res = runSub(function() end, nil, true)
            await_ready()
            assert.is_true(runUntil(done(res)))
            assert.are.same({ true, "complete", n = 2 }, res.values)
            assert.are.equal(1, #tasks)
            assert.are.equal(1, tasks[1].delay)
            release()
            assert.is_true(runUntil(function() return #tasks == 0 end))
            assert.is_true(isReaped(child_pids[1]))
        end)

        it("yields between read budgets and resumes an active transfer promptly", function()
            local await_release, release = ipcGate()
            local await_ready, ready = ipcGate()
            local spawn = ffiutil.runInSubProcess
            ffiutil.runInSubProcess = function(_, with_pipe)
                return spawn(function(_, writer)
                    ffiutil.writeToFD(writer, "prefix", false)
                    ready()
                    await_release()
                end, with_pipe)
            end
            local original_read = ffiutil.readAvailableFromFD
            ffiutil.readAvailableFromFD = function(fd)
                local data, eof, drained, err = original_read(fd)
                if data and #data > 0 then drained = false end
                return data, eof, drained, err
            end
            local ok, err = xpcall(function()
                local res = runSub(function() end, nil, true)
                await_ready()
                runNextTask()
                assert.is_false(res.done)
                assert.are.equal(1, #tasks)
                assert.is_true(tasks[1].delay > 0 and tasks[1].delay <= 0.02)
                release()
                assert.is_true(runUntil(done(res)))
                assert.are.same({ true, "prefix", n = 2 }, res.values)
            end, debug.traceback)
            ffiutil.readAvailableFromFD = original_read
            if not ok then error(err, 0) end
        end)

        it("keeps polling after partial output and remains cancellable", function()
            local ready = tmpPath()
            local await_release, release = ipcGate()
            local spawn = ffiutil.runInSubProcess
            ffiutil.runInSubProcess = function(_, with_pipe)
                return spawn(function(_, writer)
                    ffiutil.writeToFD(writer, "prefix:", false)
                    touch(ready)
                    await_release()
                    ffiutil.writeToFD(writer, "complete", true)
                end, with_pipe)
            end
            local res = runSub(function() end, "Working", true)
            assert.is_true(runUntil(function() return lfs.attributes(ready) ~= nil end))
            runNextTask()
            assert.is_false(res.done)
            release()
            assert.is_true(runUntil(done(res)))
            assert.are.same({ true, "prefix:complete", n = 2 }, res.values)
        end)

        it("does not wait for EOF held open by a worker descendant", function()
            local await_release, release = ipcGate()
            local res = runSub(function()
                local pid = C.fork()
                if pid == 0 then
                    await_release()
                    C._exit(0)
                end
                assert(pid > 0)
                return "complete"
            end, "Working", true)
            assert.is_true(runUntil(done(res)))
            assert.are.same({ true, "complete", n = 2 }, res.values)
            release()
        end)

        it("discards partial results and closes the pipe immediately on cancellation", function()
            local ready = tmpPath()
            local await_release = ipcGate()
            local spawn = ffiutil.runInSubProcess
            ffiutil.runInSubProcess = function(_, with_pipe)
                return spawn(function(_, writer)
                    ffiutil.writeToFD(writer, "partial", false)
                    touch(ready)
                    await_release()
                end, with_pipe)
            end
            local res = runSub(function() end, "Working", true)
            assert.is_true(runUntil(function() return lfs.attributes(ready) ~= nil end))
            runNextTask()
            assert.is_false(res.done)
            shown[#shown].dismiss_callback()
            assert.are.same({ false, n = 1 }, res.values)
            assert.are.equal(-1, C.fcntl(child_fds[1], C.F_GETFL))
            assert.is_true(runUntil(function() return #tasks == 0 end))
            assert.is_true(isReaped(child_pids[1]))
        end)

        it("reports read errors without returning a partial result or leaking its pipe", function()
            local await_release = ipcGate()
            local await_ready, ready = ipcGate()
            local original_read = ffiutil.readAvailableFromFD
            local spawn = ffiutil.runInSubProcess
            ffiutil.runInSubProcess = function(_, with_pipe)
                return spawn(function(_, writer)
                    ffiutil.writeToFD(writer, "partial", false)
                    ready()
                    await_release()
                end, with_pipe)
            end
            local received
            ffiutil.readAvailableFromFD = function(fd)
                if received then return nil, false, false, "read failed" end
                local data, eof, drained, err = original_read(fd)
                if data and #data > 0 then received = data end
                return data, eof, drained, err
            end
            local ok, err = xpcall(function()
                local res = runSub(function() end, "Working", true)
                await_ready()
                assert.is_true(runUntil(done(res)))
                assert.are.equal("partial", received)
                assert.are.same({ false, nil, "read_failed", n = 3 }, res.values)
                assert.are.equal(-1, C.fcntl(child_fds[1], C.F_GETFL))
                assert.is_true(runUntil(function() return #tasks == 0 end))
                assert.is_true(isReaped(child_pids[1]))
            end, debug.traceback)
            ffiutil.readAvailableFromFD = original_read
            if not ok then error(err, 0) end
        end)

        it("does not hang when the child crashes, and reaps it", function()
            local res = runSub(function() error("child crashed") end, "Working")
            assert.is_true(runUntil(done(res)))
            assert.are.same({ true, n = 1 }, res.values)
            assert.is_true(runUntil(function() return isReaped(child_pids[1]) end, 500))
            assert.are.equal(0, #tasks)
        end)

        it("does not hang when the child exits early with a non-zero status", function()
            local res = runSub(function() C._exit(3) end)
            assert.is_true(runUntil(done(res)))
            assert.are.same({ true, n = 1 }, res.values)
            assert.is_true(runUntil(function() return isReaped(child_pids[1]) end, 500))
        end)

        it("returns no values when the child's results cannot be serialized", function()
            local res = runSub(function() return function() end end)
            assert.is_true(runUntil(done(res)))
            assert.are.same({ true, n = 1 }, res.values)
        end)

        it("warns and returns no values on malformed serialized data", function()
            local warn = spy.on(logger, "warn")
            local res = runSub(function()
                -- Only affects the forked child: make it send garbage.
                require("string.buffer").encode = function() return "\255garbage" end
                return 1
            end)
            local ok = runUntil(done(res))
            logger.warn:revert()
            assert.is_true(ok)
            assert.are.same({ true, n = 1 }, res.values)
            assert.spy(warn).was.called_with("malformed serialized data:", match._)
        end)

        it("backs off the polling interval up to 1 second while the child runs", function()
            local flag = tmpPath()
            local res = runSub(function()
                waitForFile(flag)
                return "late"
            end, nil, true)
            local delays = {}
            local ok = runUntil(done(res), 2000, function(i)
                table.insert(delays, tasks[1] and tasks[1].delay)
                if i == 45 then touch(flag) end
            end)
            assert.is_true(ok)
            assert.are.same({ true, "late", n = 2 }, res.values)
            assert.is_true(#delays >= 45)
            for i = 1, 9 do assert.are.equal(0.125, delays[i]) end
            assert.are.equal(0.25, delays[10])
            assert.are.equal(0.5, delays[20])
            assert.are.equal(1, delays[30])
            assert.are.equal(1, delays[#delays])
        end)

        it("kills the child when dismissed by a tap, and collects it later", function()
            local flag = tmpPath() -- never created: the child would wait ~10s
            local terminate = spy.on(ffiutil, "terminateSubProcess")
            local res = runSub(function() waitForFile(flag) return "never" end, "Working")
            local trap = shown[1]
            runNextTask()
            runNextTask()
            assert.is_false(res.done)
            local pid = child_pids[1]
            assert.is_false(isReaped(pid))
            -- user taps the TrapWidget
            trap:onTapDismiss(nil, { ges = "tap" })
            ffiutil.terminateSubProcess:revert()
            assert.is_true(res.done)
            assert.are.same({ false, n = 1 }, res.values)
            assert.spy(terminate).was.called_with(pid)
            -- a visible TrapWidget does not resend the tap
            assert.are.equal(0, #next_ticks)
            -- no more polling, only the collector, scheduled in 5s
            assert.are.equal(1, #tasks)
            assert.are.equal(5, tasks[1].delay)
            assert.is_true(runUntil(function() return #tasks == 0 end, 500))
            assert.is_true(isReaped(pid))
        end)

        it("closes a dismissed writer pipe and reaps it without a scheduling assumption", function()
            local await_release, release = ipcGate()
            local size = 512 * 1024
            local res = runSub(function()
                await_release()
                return string.rep("y", size)
            end, false, true)
            local trap = shown[1]
            assert.is_false(trap.resend_event)
            runNextTask()
            -- let the child fill the pipe, then dismiss before Trapper reads it
            release()
            local fd = child_fds[1]
            local ready = ffi.new("struct pollfd[1]")
            ready[0].fd, ready[0].events = fd, C.POLLIN
            assert.is_true(C.poll(ready, 1, 5000) > 0, "child output did not become ready")
            assert.are_not.equal(0, ffiutil.getNonBlockingReadSize(fd))
            -- Simulate a child that SIGKILL did not reach (yet).
            stub(ffiutil, "terminateSubProcess")
            trap.dismiss_callback()
            ffiutil.terminateSubProcess:revert()
            assert.is_true(res.done)
            assert.are.same({ false, n = 1 }, res.values)
            local pid = child_pids[1]
            assert.is_false(isReaped(pid))
            -- Closing the reader releases the blocked writer. It may exit
            -- before the first collector runs, or need another poll.
            assert.are.equal(-1, C.fcntl(fd, C.F_GETFD))
            runNextTask(0)
            assert.is_true(runUntil(function() return #tasks == 0 end, 500))
            assert.is_true(isReaped(pid))
        end)

        it("resends the dismissing tap with an invisible TrapWidget", function()
            local flag = tmpPath()
            local res = runSub(function() waitForFile(flag) end) -- trap_widget_or_string = nil
            local trap = shown[1]
            assert.is_nil(trap.text)
            assert.is_true(trap.resend_event)
            trap:onTapDismiss(nil, { ges = "tap" })
            assert.is_true(res.done)
            assert.are.same({ false, n = 1 }, res.values)
            assert.are.equal(1, #next_ticks)
            -- an invisible TrapWidget needs no repaint
            assert.are.equal(0, repaints)
        end)

        it("uses a caller-provided widget and restores its dismiss_callback", function()
            local orig_cb = function() end
            local widget = { dismiss_callback = orig_cb }
            local res = runSub(function() return "ok" end, widget, true)
            assert.are_not.equal(orig_cb, widget.dismiss_callback)
            assert.is_true(runUntil(done(res)))
            assert.are.same({ true, "ok", n = 2 }, res.values)
            assert.are.equal(orig_cb, widget.dismiss_callback)
            -- the caller's widget is not ours to show or close
            assert.are.equal(0, #shown)
            assert.are.equal(0, #closed)
        end)

        it("restores the caller's dismiss_callback after a dismissal too", function()
            local flag = tmpPath()
            local orig_cb = function() end
            local widget = { dismiss_callback = orig_cb }
            local res = runSub(function() waitForFile(flag) end, widget)
            widget.dismiss_callback()
            assert.is_true(res.done)
            assert.are.same({ false, n = 1 }, res.values)
            assert.are.equal(orig_cb, widget.dismiss_callback)
        end)

        it("returns false without hanging when the subprocess cannot be started", function()
            ffiutil.runInSubProcess = function() return false, "fork failed: Cannot allocate memory" end
            local warn = spy.on(logger, "warn")
            local res = runSub(function() return "never" end, "Working")
            logger.warn:revert()
            assert.is_true(res.done)
            assert.are.same({ false, nil, "start_failed", n = 3 }, res.values)
            assert.spy(warn).was.called_with("dismissableRunInSubprocess: could not start subprocess:",
                "fork failed: Cannot allocate memory")
            -- the TrapWidget is not left on screen, nothing is scheduled
            assert.are.same({ shown[1] }, closed)
            assert.are.equal(0, #tasks)
        end)
    end)

    describe("dismissablePopen", function()
        local popen_guard
        before_each(function()
            popen_guard = stub(io, "popen", function()
                error("wrapped commands must not reintroduce blocking stdio ownership", 0)
            end)
        end)
        after_each(function() popen_guard:revert() end)

        local function runPopen(cmd, trap)
            return runWrapped(function()
                return Trapper:dismissablePopen(cmd, trap)
            end)
        end
        local function done(res) return function() return res.done end end

        local function shellGate()
            local pipe = ffi.new("int[2]")
            assert.are.equal(0, C.pipe(pipe))
            local released = false
            local function release()
                if released then return end
                released = true
                C.write(pipe[1], "go\n", 3)
                C.close(pipe[1]); C.close(pipe[0])
            end
            gate_releases[#gate_releases + 1] = release
            local run = ffiutil.runInSubProcess
            ffiutil.runInSubProcess = function(func, with_pipe)
                return run(function(pid, fd)
                    assert(C.dup2(pipe[0], 0) == 0)
                    C.close(pipe[1])
                    if pipe[0] ~= 0 then C.close(pipe[0]) end
                    func(pid, fd)
                end, with_pipe)
            end
            return "read ready", release
        end

        it("remains dismissable after a prefix, and its collector never waits for the suffix", function()
            local gate, release = shellGate()
            local saw_prefix = false
            ffiutil.readAvailableFromFD = function(fd)
                local chunk, eof, drained, err = orig_read_available(fd)
                saw_prefix = saw_prefix or chunk == "prefix"
                return chunk, eof, drained, err
            end
            local res = runPopen("printf prefix; " .. gate .. "; printf suffix")
            assert.is_true(runUntil(function() return saw_prefix end))
            assert.is_false(res.done)
            local pid = child_pids[#child_pids]
            shown[1]:onTapDismiss(nil, { ges = "tap" })
            assert.are.same({ false, nil, n = 2 }, res.values)
            runNextTask(0) -- the background drain sees EAGAIN, never read('*all')
            assert.are.equal(1, #tasks)
            assert.are.equal(0, C.kill(pid, 0)) -- cancellation does not kill it
            release()
            assert.is_true(runUntil(function() return #tasks == 0 end))
            assert.is_true(isReaped(pid))
        end)

        it("keeps yielding after stdout EOF until the shell exits", function()
            local gate, release = shellGate()
            local saw_eof = false
            ffiutil.readAvailableFromFD = function(fd)
                local chunk, eof, drained, err = orig_read_available(fd)
                saw_eof = saw_eof or eof
                return chunk, eof, drained, err
            end
            local res = runPopen("exec 1>&-; " .. gate)
            assert.is_true(runUntil(function() return saw_eof end))
            assert.is_false(res.done)
            runNextTask(0) -- no pclose or blocking waitpid after EOF
            assert.is_false(res.done)
            release()
            assert.is_true(runUntil(done(res)))
            assert.are.same({ true, "", n = 2 }, res.values)
        end)

        it("reports a read failure immediately and reaps the live command later", function()
            local gate, release = shellGate()
            ffiutil.readAvailableFromFD = function() return nil, false, false, "expected read error" end
            local res = runPopen(gate)
            assert.is_true(runUntil(done(res)))
            assert.are.same({ false, nil, "read_failed", n = 3 }, res.values)
            local pid = child_pids[#child_pids]
            assert.are.equal(0, C.kill(pid, 0))
            runNextTask(0)
            assert.are.equal(1, #tasks)
            release()
            assert.is_true(runUntil(function() return #tasks == 0 end))
            assert.is_true(isReaped(pid))
        end)

        it("reports spawn failures distinctly from dismissal", function()
            ffiutil.openCommandPipe = function() return false, "expected spawn error" end
            local res = runPopen("printf ignored")
            assert.is_true(res.done)
            assert.are.same({ false, nil, "start_failed", n = 3 }, res.values)
        end)

        it("returns the command output, with a visible TrapWidget", function()
            local res = runPopen("printf 'some output'", "Running")
            local trap = shown[1]
            assert.are.equal(TrapWidget, getmetatable(trap).__index)
            assert.are.equal("Running", trap.text)
            assert.is_true(runUntil(done(res)))
            assert.are.same({ true, "some output", n = 2 }, res.values)
            assert.are.same({ trap }, closed)
            assert.are.equal(2, repaints)
        end)

        it("releases command transport chunks before repainting", function()
            local weak = setmetatable({}, { __mode = "v" })
            local concat = table.concat
            table.concat = function(chunks, ...) -- luacheck: ignore 122
                weak[1] = chunks
                return concat(chunks, ...)
            end
            local checked = false
            UIManager.forceRePaint = function()
                if #closed == 0 then return end
                collectgarbage("collect")
                assert.is_nil(weak[1])
                checked = true
            end
            local ok, err = pcall(function()
                local res = runPopen("printf transport", "Working")
                assert.is_true(runUntil(done(res)))
                assert.are.same({ true, "transport", n = 2 }, res.values)
                assert.is_true(checked)
            end)
            table.concat = concat -- luacheck: ignore 122
            assert(ok, err)
        end)

        it("returns large outputs entirely", function()
            local res = runPopen("head -c 200000 /dev/zero | tr '\\0' z")
            assert.is_true(runUntil(done(res)))
            assert.is_true(res.values[1])
            assert.are.equal(string.rep("z", 200000), res.values[2])
        end)

        it("completes for a nonexistent command when an echo is appended", function()
            local res = runPopen("nonexistent_command_for_trapper_spec 2>/dev/null; echo", false)
            assert.is_true(runUntil(done(res)))
            assert.are.same({ true, "\n", n = 2 }, res.values)
        end)

        it("backs off polling, and restores a caller-provided widget's dismiss_callback", function()
            local flag = tmpPath()
            local orig_cb = function() end
            local widget = { dismiss_callback = orig_cb }
            local res = runPopen("while [ ! -e '" .. flag .. "' ]; do sleep 0.01; done; echo late", widget)
            local delays = {}
            local ok = runUntil(done(res), 2000, function(i)
                table.insert(delays, tasks[1] and tasks[1].delay)
                if i == 25 then touch(flag) end
            end)
            assert.is_true(ok)
            assert.are.same({ true, "late\n", n = 2 }, res.values)
            assert.are.equal(0.125, delays[1])
            assert.are.equal(0.25, delays[10])
            assert.are.equal(0.5, delays[20])
            assert.are.equal(orig_cb, widget.dismiss_callback)
            assert.are.equal(0, #shown)
        end)

        it("returns at once when dismissed, and collects the command output later", function()
            local flag = tmpPath()
            local res = runPopen("while [ ! -e '" .. flag .. "' ]; do sleep 0.01; done; echo late")
            local trap = shown[1]
            assert.is_true(trap.resend_event)
            runNextTask()
            assert.is_false(res.done)
            trap:onTapDismiss(nil, { ges = "tap" })
            assert.is_true(res.done)
            assert.are.same({ false, nil, n = 2 }, res.values)
            assert.are.equal(1, #next_ticks) -- tap resent
            assert.are.equal(1, #tasks)
            assert.are.equal(5, tasks[1].delay)
            -- no output yet: the collector reschedules itself
            runNextTask(0)
            assert.are.equal(1, #tasks)
            -- once the command outputs, the collector reads it and stops
            touch(flag)
            assert.is_true(runUntil(function() return #tasks == 0 end, 500))
        end)
    end)
end)
