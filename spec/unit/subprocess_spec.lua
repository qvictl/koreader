-- Unit tests for the subprocess helpers of base's ffi/util.lua
-- (runInSubProcess, isSubProcessDone, terminateSubProcess, readAllFromFD):
-- the failure paths a dismissed or stuck child takes, with real forked
-- processes (synchronised via a pipe or flag files, no fixed sleeps).
describe("ffi/util subprocess helpers", function()
    local ffiutil, ffi, C, lfs
    local pids, tmp_files

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

    -- Poll cond() for up to ~2s.
    local function eventually(cond)
        for _ = 1, 400 do
            if cond() then return true end
            ffiutil.usleep(5000)
        end
        return cond()
    end

    -- A child that runs until its flag file appears (or ~10s, so that a
    -- failing test never leaves it behind for long).
    local function startWaitingChild(flag, on_tick)
        local pid = ffiutil.runInSubProcess(function()
            for _ = 1, 2000 do
                if lfs.attributes(flag, "mode") then return end
                if on_tick then on_tick() end
                ffiutil.usleep(5000)
            end
        end)
        assert.is_number(pid)
        table.insert(pids, pid)
        return pid
    end

    setup(function()
        require("commonrequire")
        ffiutil = require("ffi/util")
        ffi = require("ffi")
        C = ffi.C
        lfs = require("libs/libkoreader-lfs")
        -- Not in base's posix_h.lua.
        pcall(ffi.cdef, "pid_t getpgid(pid_t pid);")
    end)

    before_each(function()
        pids, tmp_files = {}, {}
    end)

    after_each(function()
        for _, path in ipairs(tmp_files) do
            touch(path)
        end
        for _, pid in ipairs(pids) do
            C.kill(pid, 9)
            ffiutil.isSubProcessDone(pid, true)
        end
        for _, path in ipairs(tmp_files) do
            os.remove(path)
        end
    end)

    describe("isSubProcessDone", function()
        it("returns false while the child runs, true once it exited", function()
            local flag = tmpPath()
            local pid = startWaitingChild(flag)
            assert.is_false(ffiutil.isSubProcessDone(pid))
            assert.is_false(ffiutil.isSubProcessDone(pid)) -- does not block nor reap
            assert.are.equal(0, C.kill(pid, 0))
            touch(flag)
            assert.is_true(eventually(function() return ffiutil.isSubProcessDone(pid) end))
            -- reaped: no zombie left
            assert.are_not.equal(0, C.kill(pid, 0))
            -- and asking again about a reaped pid does not block
            assert.is_true(ffiutil.isSubProcessDone(pid))
        end)

        it("waits for the child with wait = true", function()
            local flag = tmpPath()
            local pid = startWaitingChild(flag)
            touch(flag)
            assert.is_true(ffiutil.isSubProcessDone(pid, true))
            assert.are_not.equal(0, C.kill(pid, 0))
        end)
    end)

    describe("terminateSubProcess", function()
        it("kills a still running child (via its process group)", function()
            local flag = tmpPath() -- never created
            local pid = startWaitingChild(flag)
            -- runInSubProcess gives the child its own process group
            assert.are.equal(pid, C.getpgid(pid))
            assert.is_false(ffiutil.isSubProcessDone(pid))
            ffiutil.terminateSubProcess(pid)
            assert.is_true(eventually(function() return ffiutil.isSubProcessDone(pid) end))
            assert.are_not.equal(0, C.kill(pid, 0))
        end)

        it("kills the child itself when its process group is gone", function()
            local flag = tmpPath() -- never created
            local my_pgid = C.getpgid(0)
            -- The child (repeatedly, as the parent also sets its process group
            -- right after fork) moves itself back into our process group, so
            -- that kill(-pid) fails (no such group) and the fallback is needed.
            local pid = startWaitingChild(flag, function()
                C.setpgid(0, my_pgid)
            end)
            assert.is_true(eventually(function() return C.getpgid(pid) == my_pgid end))
            assert.is_false(ffiutil.isSubProcessDone(pid))
            ffiutil.terminateSubProcess(pid)
            assert.is_true(eventually(function() return ffiutil.isSubProcessDone(pid) end))
            assert.are_not.equal(0, C.kill(pid, 0))
        end)

        it("does nothing for an already exited child", function()
            local flag = tmpPath()
            touch(flag)
            local pid = startWaitingChild(flag)
            assert.is_true(ffiutil.isSubProcessDone(pid, true))
            -- must neither block nor kill anything else
            ffiutil.terminateSubProcess(pid)
            assert.is_true(ffiutil.isSubProcessDone(pid))
        end)
    end)

    describe("readAllFromFD", function()
        it("reads everything the child wrote, then closes the fd", function()
            local size = 300 * 1024 -- more than a pipe buffer
            local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
                ffiutil.writeToFD(write_fd, string.rep("w", size), true)
            end, true)
            assert.is_number(pid)
            table.insert(pids, pid)
            local data = ffiutil.readAllFromFD(fd)
            assert.are.equal(string.rep("w", size), data)
            assert.is_true(ffiutil.isSubProcessDone(pid, true))
            -- fd was closed
            assert.are_not.equal(0, C.close(fd))
        end)

        it("stops on a read error, returning what it has, and still closes the fd", function()
            local pipe = ffi.new("int[2]")
            assert.are.equal(0, C.pipe(pipe))
            local read_end, write_end = pipe[0], pipe[1]
            local printed = {}
            local orig_print = _G.print
            _G.print = function(...) table.insert(printed, table.concat({ ... }, " ")) end
            -- reading from the write end of a pipe fails with EBADF
            local ok, data = pcall(ffiutil.readAllFromFD, write_end)
            _G.print = orig_print
            assert.is_true(ok, data)
            assert.are.equal("", data)
            assert.are.equal(1, #printed)
            assert.truthy(printed[1]:find("readAllFromFD() error", 1, true))
            -- the bad fd was closed anyway (no fd leak)
            assert.are_not.equal(0, C.close(write_end))
            C.close(read_end)
        end)

        it("returns an empty string for an invalid fd", function()
            local orig_print = _G.print
            local printed = 0
            _G.print = function() printed = printed + 1 end
            local ok, data = pcall(ffiutil.readAllFromFD, -1)
            _G.print = orig_print
            assert.is_true(ok, data)
            assert.are.equal("", data)
            assert.are.equal(1, printed)
        end)
    end)
end)
