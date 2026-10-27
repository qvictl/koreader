-- util.runInSubProcess & Trapper: a subprocess function that errors or yields is contained
-- (the child exits, with a failure status, instead of carrying on as a second KOReader
-- running our UI loop), no fd is leaked, and Trapper restores the caller's dismiss_callback.
return {
    name = "Subprocess containment (runInSubProcess, Trapper)",
    timeout = 120,
    run = function(T)
        local ffi = require("ffi")
        local ffiutil = require("ffi/util")
        local C = ffi.C
        local Trapper = require("ui/trapper")
        pcall(ffi.cdef, "int getpid(void);")
        local parent_pid = C.getpid()

        -- Waits for `pid` to exit; returns its exit status (or nil on timeout, after killing it).
        local function waitExit(pid, timeout)
            local status = ffi.new("int[1]")
            local deadline = T:now() + (timeout or 10) * 1000
            while T:now() < deadline do
                local ret = C.waitpid(pid, status, 1) -- WNOHANG
                if ret == pid then
                    local st = tonumber(status[0])
                    if bit.band(st, 0x7f) == 0 then
                        return bit.band(bit.rshift(st, 8), 0xff)
                    end
                    return 128 + bit.band(st, 0x7f)
                end
                T:wait(0.05)
            end
            C.kill(pid, 9)
            C.waitpid(pid, status, 0)
            return nil
        end

        local function pipes()
            local n = 0
            for _ in T:fdList():gmatch("=pipe:") do n = n + 1 end
            return n
        end
        local pipes_before = pipes()
        T:log("fds before:", T:fdList())

        -- 1. Normal task, with a pipe.
        local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
            ffiutil.writeToFD(write_fd, "hello from child", true)
        end, true)
        T:check(pid, "subprocess started")
        local status = waitExit(pid)
        local out = ffiutil.readAllFromFD(read_fd)
        T:eq(out, "hello from child", "output read from the child")
        T:eq(status, 0, "successful task exits with status 0")

        -- 2. Task raising an error: contained, reported through the exit status.
        pid = ffiutil.runInSubProcess(function() error("boom (expected by the test)") end)
        T:check(pid, "subprocess started")
        T:eq(waitExit(pid), 1, "failing task exits with status 1")

        -- 3. Task yielding, with runInSubProcess called from a coroutine (as Trapper does).
        -- Before the fix, the yield went through to our coroutine *in the child*, which would
        -- then go on running this very scenario (and the UI loop) as a second KOReader.
        local escaped_marker = os.getenv("IT_RESULT") .. ".escaped"
        local co = coroutine.create(function()
            return ffiutil.runInSubProcess(function() coroutine.yield("in child") end)
        end)
        local ok, yield_pid = coroutine.resume(co)
        if C.getpid() ~= parent_pid then
            -- We are the child, and we escaped from runInSubProcess: report and die.
            local f = io.open(escaped_marker, "w")
            if f then f:write("child escaped from runInSubProcess\n"); f:close() end
            C._exit(3)
        end
        T:check(ok and type(yield_pid) == "number", "subprocess started from a coroutine")
        local yield_status = waitExit(yield_pid, 10)
        T:check(yield_status ~= nil, "yielding task's child exited (did not keep running)")
        T:check(yield_status ~= 3 and not io.open(escaped_marker, "r"), "child did not escape into the caller's coroutine")
        T:eq(yield_status, 1, "yielding task exits with status 1")

        -- 4. Bidirectional pipes, and double fork (the returned pid is the reaped intermediate
        -- process: terminating it must not fail, there is no such process group anymore).
        local write_fd
        pid, read_fd, write_fd = ffiutil.runInSubProcess(function(_, child_write_fd, child_read_fd)
            local got = ffiutil.readAllFromFD(child_read_fd)
            ffiutil.writeToFD(child_write_fd, "echo:" .. got, true)
        end, "bidi")
        T:check(pid and read_fd and write_fd, "bidi subprocess started")
        ffiutil.writeToFD(write_fd, "ping", true)
        T:eq(ffiutil.readAllFromFD(read_fd), "echo:ping", "bidi pipes round trip")
        T:eq(waitExit(pid), 0, "bidi subprocess exits with status 0")
        local dpid = ffiutil.runInSubProcess(function() end, false, true)
        T:check(dpid, "double-forked subprocess started")
        ffiutil.terminateSubProcess(dpid)
        T:check(ffiutil.isSubProcessDone(dpid), "double fork: nothing left to collect")

        -- 5. Failures to create the pipes (fd limit reached): reported, nothing leaked.
        pcall(ffi.cdef, [[
            struct it_rlimit { unsigned long cur, max; };
            int getrlimit(int, struct it_rlimit *);
            int setrlimit(int, const struct it_rlimit *);
        ]])
        local RLIMIT_NOFILE = 7
        local lim = ffi.new("struct it_rlimit")
        C.getrlimit(RLIMIT_NOFILE, lim)
        local saved_cur = lim.cur
        -- Fill any gap in the fd numbers, so that the limit is exactly "n more fds".
        local fillers, highest = {}, 0
        for f in require("libs/libkoreader-lfs").dir("/proc/self/fd") do
            local n = tonumber(f)
            if n and n > highest then highest = n end
        end
        while true do
            local fd = C.open("/dev/null", 0)
            if fd < 0 or fd > highest then
                if fd >= 0 then C.close(fd) end
                break
            end
            table.insert(fillers, fd)
        end
        local failures = {}
        for _, extra in ipairs({ 0, 2 }) do
            local pipes_now = pipes()
            lim.cur = highest + 1 + extra
            C.setrlimit(RLIMIT_NOFILE, lim)
            local ok_, err = ffiutil.runInSubProcess(function() end, "bidi")
            lim.cur = saved_cur
            C.setrlimit(RLIMIT_NOFILE, lim)
            failures[extra] = { ok = ok_, err = err, leaked = pipes() - pipes_now }
        end
        for _, fd in ipairs(fillers) do C.close(fd) end
        for extra, r in pairs(failures) do
            T:log("fd limit +" .. extra .. ":", tostring(r.ok), tostring(r.err))
            T:check(r.ok == false and tostring(r.err):find("pipe", 1, true), "pipe failure reported (limit +" .. extra .. ")")
            T:eq(r.leaked, 0, "no pipe fd leaked on failure (limit +" .. extra .. ")")
        end

        -- 6. Trapper: the caller's widget gets its dismiss_callback back.
        local orig_cb = function() end
        local widget = { dismiss_callback = orig_cb }
        local done, results = false, {}
        T:run(function()
            Trapper:wrap(function()
                results.sub_completed, results.sub_value = Trapper:dismissableRunInSubprocess(function()
                    return "computed in subprocess"
                end, widget, true)
                results.cb_after_sub = widget.dismiss_callback
                results.popen_completed, results.popen_output = Trapper:dismissablePopen("echo popen-ok", widget)
                results.cb_after_popen = widget.dismiss_callback
                -- A task that errors: returns, the UI goes on.
                results.err_completed = Trapper:dismissableRunInSubprocess(function()
                    error("task error (expected by the test)")
                end, widget, true)
                done = true
            end)
        end)
        T:waitUntil(function() return done end, 30, "Trapper tasks")
        T:check(results.sub_completed, "dismissableRunInSubprocess completed")
        T:eq(results.sub_value, "computed in subprocess", "dismissableRunInSubprocess result")
        T:check(results.cb_after_sub == orig_cb, "dismiss_callback restored after dismissableRunInSubprocess")
        T:check(results.popen_completed, "dismissablePopen completed")
        T:check(results.popen_output and results.popen_output:find("popen-ok", 1, true), "dismissablePopen output")
        T:check(results.cb_after_popen == orig_cb, "dismiss_callback restored after dismissablePopen")
        T:check(results.err_completed ~= nil, "failing Trapper task returned")

        -- No leak, no leftover process.
        local deadline = T:now() + 10000
        while #T:children() > 0 and T:now() < deadline do T:wait(0.1) end
        if #T:children() > 0 then
            local p = io.popen("ps -o pid,stat,etime,wchan:30,args --ppid " .. parent_pid)
            T:log("children left:", p:read("*a"))
            p:close()
        end
        T:eq(#T:children(), 0, "all children are gone")
        T:log("fds after:", T:fdList())
        T:eq(pipes(), pipes_before, "no pipe file descriptor leaked")
    end,
}
