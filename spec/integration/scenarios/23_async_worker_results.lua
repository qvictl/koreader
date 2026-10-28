return {
    name = "Partial worker results and inherited pipes stay responsive",
    timeout = 60,
    run = function(T)
        local ffi = require("ffi")
        local util = require("ffi/util")
        local Trapper = require("ui/trapper")
        local UIManager = require("ui/uimanager")
        local C = ffi.C
        local lfs = require("libs/libkoreader-lfs")
        local raw_write = util.writeToFD
        local marker = os.getenv("IT_RESULT") .. ".writing"
        local release = os.getenv("IT_RESULT") .. ".release"
        local heartbeat, max_gap, previous = true, 0, T:now()
        local function beat()
            if not heartbeat then return end
            local now = T:now()
            max_gap = math.max(max_gap, now - previous)
            previous = now
            UIManager:scheduleIn(0.1, beat)
        end
        local function pipe_count()
            local n = 0
            for _ in T:fdList():gmatch("=pipe:") do n = n + 1 end
            return n
        end
        local before = pipe_count()
        local ok, err = xpcall(function()
            UIManager:scheduleIn(0.1, beat)
            -- Slow only the worker's transport. The UI and process lifecycle are real.
            util.writeToFD = function(fd, data, close)
                raw_write(fd, data:sub(1, 4096), false)
                local f = assert(io.open(marker, "w")); f:close()
                util.usleep(1200000)
                return raw_write(fd, data:sub(4097), close)
            end
            local payload = string.rep("complete-result-", 150000)
            local done, completed, value = false
            local started = T:now()
            T:run(function()
                Trapper:wrap(function()
                    completed, value = Trapper:dismissableRunInSubprocess(function()
                        return payload
                    end, "Receiving worker result", true)
                    done = true
                end)
            end)
            T:waitUntil(function() return done end, 20, "complete slow result")
            T:check(completed, "slow worker completed")
            T:check(value == payload, "multi-megabyte result is complete")
            T:metric("result_transfer_ms", T:now() - started, "ms")
            T:wait(0.1) -- Include any heartbeat delayed by the final read.
            T:budget("slow_writer_heartbeat_ms", max_gap, 800, "ms")
            util.writeToFD = raw_write
            os.remove(marker)

            -- A descendant holds the pipe open until released or its bounded timeout.
            done, completed, value = false, nil, nil
            started = T:now()
            T:run(function()
                Trapper:wrap(function()
                    completed, value = Trapper:dismissableRunInSubprocess(function()
                        local pid = C.fork()
                        if pid == 0 then
                            for _ = 1, 1000 do
                                if lfs.attributes(release) then C._exit(0) end
                                util.usleep(2000)
                            end
                            C._exit(0)
                        end
                        assert(pid > 0)
                        return "direct child finished"
                    end, "Waiting for worker", true)
                    done = true
                end)
            end)
            T:waitUntil(function() return done end, 5, "direct worker completion")
            T:check(completed, "worker completes without descendant EOF")
            T:eq(value, "direct child finished", "result survives inherited writer")
            T:budget("inherited_writer_completion_ms", T:now() - started, 800, "ms")
            local release_file = assert(io.open(release, "w")); release_file:close()

            -- Cancel after the prefix, with a real gesture on the painted widget.
            done, completed, value = false, nil, nil
            util.writeToFD = function(fd, data, close)
                raw_write(fd, data:sub(1, 4096), false)
                local f = assert(io.open(marker, "w")); f:close()
                util.usleep(2000000)
                return raw_write(fd, data:sub(4097), close)
            end
            T:run(function()
                Trapper:wrap(function()
                    completed, value = Trapper:dismissableRunInSubprocess(function()
                        return payload
                    end, "Cancel partial worker result", true)
                    done = true
                end)
            end)
            T:waitUntil(function() return lfs.attributes(marker) end, 5, "result prefix")
            T:wait(0.2) -- Let the worker-result poll consume the prefix first.
            T:check(not done, "partial output does not complete the task")
            T:repaint()
            started = T:now()
            T:tapWidget(T:topWidget(), "worker cancellation")
            T:waitUntil(function() return done end, 5, "cancelled worker")
            T:check(not completed and value == nil, "partial result discarded on cancellation")
            T:budget("partial_result_cancel_ms", T:now() - started, 800, "ms")
            util.writeToFD = raw_write
            T:waitUntil(function() return #T:children() == 0 end, 10, "worker collection")
            T:eq(pipe_count(), before, "worker result pipes are closed")
        end, debug.traceback)
        heartbeat = false
        UIManager:unschedule(beat)
        util.writeToFD = raw_write
        local f = io.open(release, "w"); if f then f:close() end
        os.remove(marker)
        if not ok then error(err, 0) end
    end,
}
