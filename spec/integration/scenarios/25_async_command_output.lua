return {
    name = "Streaming shell commands and cancelled collection keep the UI responsive",
    timeout = 90,
    run = function(T)
        local ffi = require("ffi")
        local util = require("ffi/util")
        local Trapper = require("ui/trapper")
        local UIManager = require("ui/uimanager")
        local lfs = require("libs/libkoreader-lfs")
        local C = ffi.C
        local quote = function(value) return require("util").shell_escape({ value }) end
        local prefix = os.getenv("IT_RESULT") .. ".command"
        local payload_path, marker, finished = prefix .. ".data", prefix .. ".prefix", prefix .. ".done"
        local payload = string.rep("command-output-", 150000)
        local file = assert(io.open(payload_path, "w")); file:write(payload); file:close()
        local heartbeat, max_gap, previous = true, 0, T:now()
        local function beat()
            if not heartbeat then return end
            local now = T:now()
            max_gap = math.max(max_gap, now - previous)
            previous = now
            UIManager:scheduleIn(0.05, beat)
        end
        local function reset_heartbeat() max_gap, previous = 0, T:now() end
        local function responsive(name)
            T:wait(0.1) -- Include the heartbeat delayed by the final read/close.
            T:budget(name, max_gap, 800, "ms")
        end
        local function pipes()
            local count = 0
            for _ in T:fdList():gmatch("=pipe:") do count = count + 1 end
            return count
        end
        local original_start = util.openCommandPipe
        local command_pids = {}
        util.openCommandPipe = function(...)
            local pid, fd = original_start(...)
            if pid then command_pids[#command_pids + 1] = pid end
            return pid, fd
        end
        local before = pipes()
        local active, completed, output
        local function start(command, text)
            active, completed, output = true, nil, nil
            T:run(function()
                Trapper:wrap(function()
                    completed, output = Trapper:dismissablePopen(command, text)
                    active = false
                end)
            end)
        end
        local subreaper_previous, descendant
        local ok, err = xpcall(function()
            UIManager:scheduleIn(0.05, beat)
            reset_heartbeat()
            start("printf prefix; sleep 1.2; cat " .. quote(payload_path), "Receiving command output")
            T:waitUntil(function() return not active end, 10, "complete streaming command")
            T:check(completed and output == "prefix" .. payload, "all streaming command bytes arrive")
            responsive("streaming_command_heartbeat_ms")

            reset_heartbeat()
            start("printf eof; exec 1>&-; sleep 1.2", "Waiting for shell exit")
            T:wait(0.3)
            T:check(active, "stdout EOF alone does not complete the command")
            T:waitUntil(function() return not active end, 5, "shell exit after stdout EOF")
            T:check(completed and output == "eof", "EOF output is retained until the shell exits")
            responsive("eof_before_shell_exit_heartbeat_ms")

            -- Adopt this test's short-lived orphan so the persistent local
            -- emulator container is left without an unreaped descendant.
            ffi.cdef("int prctl(int, unsigned long, unsigned long, unsigned long, unsigned long);")
            subreaper_previous = ffi.new("int[1]")
            T:eq(C.prctl(37, ffi.cast("uintptr_t", subreaper_previous), 0, 0, 0), 0, "read subreaper state")
            T:eq(C.prctl(36, 1, 0, 0, 0), 0, "adopt the test command descendant")
            reset_heartbeat()
            start("(sleep 1.2; printf late) & printf '%s\\n' \"$!\"; exit 0", "Waiting for inherited stdout")
            T:wait(0.3)
            T:check(active, "shell exit alone does not discard an inherited stdout writer")
            T:waitUntil(function() return not active end, 5, "descendant output")
            T:check(completed and output:match("^%d+\nlate$"), "descendant output is collected after shell exit")
            descendant = tonumber(output:match("^(%d+)"))
            local status = ffi.new("int[1]")
            T:waitUntil(function() return C.waitpid(descendant, status, C.WNOHANG) == descendant end,
                5, "test descendant collection")
            descendant = nil
            T:eq(C.prctl(36, subreaper_previous[0], 0, 0, 0), 0, "restore subreaper state")
            subreaper_previous = nil
            responsive("inherited_command_writer_heartbeat_ms")

            reset_heartbeat()
            start("printf start; touch " .. quote(marker) .. "; sleep 1.2; cat " .. quote(payload_path)
                .. "; touch " .. quote(finished), "Cancel streaming command")
            T:waitUntil(function() return lfs.attributes(marker) end, 5, "command prefix")
            T:wait(0.2) -- Let the first output poll consume the prefix.
            T:check(active, "a partial command remains dismissable")
            T:repaint()
            local started = T:now()
            T:tapWidget(T:topWidget(), "cancel streaming command")
            T:waitUntil(function() return not active end, 3, "command cancellation")
            T:check(not completed and output == nil, "cancelled command output is discarded")
            T:budget("streaming_command_cancel_ms", T:now() - started, 800, "ms")
            T:waitUntil(function() return lfs.attributes(finished) end, 20, "cancelled command finishes normally")
            T:check(lfs.attributes(finished), "cancellation did not kill the command")
            T:waitUntil(function() return #T:children() == 0 and pipes() == before end,
                20, "background output drain and shell reap")
            responsive("cancelled_collector_heartbeat_ms")
            T:eq(pipes(), before, "all command pipe readers are closed")
        end, debug.traceback)
        heartbeat = false
        UIManager:unschedule(beat)
        util.openCommandPipe = original_start
        if not ok then
            for _, pid in ipairs(command_pids) do
                -- An unreaped live leader pins its pid/pgid against reuse.
                if not util.isSubProcessDone(pid) then C.kill(-pid, 9) end
            end
            for _, pid in ipairs(command_pids) do util.isSubProcessDone(pid, true) end
        end
        if descendant then C.kill(descendant, 9); C.waitpid(descendant, nil, 0) end
        if subreaper_previous then C.prctl(36, subreaper_previous[0], 0, 0, 0) end
        os.remove(payload_path); os.remove(marker); os.remove(finished)
        if not ok then error(err, 0) end
    end,
}
