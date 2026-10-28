return {
    name = "Slow DNS keeps the UI responsive and can be cancelled",
    timeout = 30,
    run = function(T)
        local Device = require("device")
        local NetworkMgr = require("ui/network/manager")
        local UIManager = require("ui/uimanager")
        local socket = require("socket")
        local ffi = require("ffi")
        local C = ffi.C
        local ffiUtil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local base = os.getenv("KO_HOME") .. "/synthetic-dns"
        require("util").makePath(base)
        local saved_toggle, saved_toip = Device.hasWifiToggle, socket.dns.toip
        local jobs, heartbeat_count = {}, 0
        local heartbeat
        heartbeat = function()
            heartbeat_count = heartbeat_count + 1
            UIManager:scheduleIn(0.01, heartbeat)
        end
        local function pidOf(job)
            local file = io.open(job.entered, "r")
            if not file then return end
            local pid = tonumber(file:read("*a"))
            file:close()
            return pid
        end
        local function start(tag, action, direct)
            local gate = ffi.new("int[2]")
            assert(C.pipe(gate) == 0)
            local job = { write_fd = tonumber(gate[1]), entered = base .. "/" .. tag .. ".entered",
                returned = base .. "/" .. tag .. ".returned" }
            jobs[#jobs + 1] = job
            socket.dns.toip = function()
                C.close(gate[1])
                local file = assert(io.open(job.entered, "w"))
                file:write(tostring(tonumber(C.getpid())))
                file:close()
                -- The synthetic resolver cannot finish until the parent releases it.
                local byte = ffi.new("char[1]")
                assert(C.read(gate[0], byte, 1) == 1)
                C.close(gate[0])
                file = assert(io.open(job.returned, "w"))
                file:write("resolved")
                file:close()
                return "192.0.2.1"
            end
            if direct then action() else NetworkMgr:runWhenOnline(action) end
            socket.dns.toip = saved_toip
            C.close(gate[0])
            job.widget = T:topWidget()
            return job
        end
        local function release(job)
            assert(C.write(job.write_fd, "x", 1) == 1)
            C.close(job.write_fd)
            job.write_fd = nil
        end
        local ok, err = pcall(function()
            local calls = 0
            local function guardedAction()
                if NetworkMgr:willRerunWhenOnline(guardedAction) then return end
                calls = calls + 1
            end
            local first
            T:run(function()
                Device.hasWifiToggle = function() return true end
                UIManager:scheduleIn(0, heartbeat)
                first = start("success", guardedAction)
            end)
            T:waitUntil(function() return pidOf(first) and heartbeat_count >= 3 end, 5, "DNS waits while UI heartbeats run")
            T:eq(calls, 0, "an unresolved connection does not run the action optimistically")
            T:repaint()
            T:check(first.widget.frame and first.widget.frame.dimen, "the cancellable network check is painted")
            T:run(function() release(first) end)
            T:waitUntil(function() return calls == 1 end, 5, "resolved DNS resumes the guarded action")
            T:eq(calls, 1, "recursive online guard runs once without another resolver")

            local cancelled_calls, cancelled = 0
            local before = heartbeat_count
            T:run(function() cancelled = start("cancelled", function() cancelled_calls = cancelled_calls + 1 end) end)
            T:waitUntil(function() return pidOf(cancelled) and heartbeat_count >= before + 3 end,
                5, "the second resolver waits without freezing the UI")
            T:repaint()
            T:tapWidget(cancelled.widget, "cancel the blocked DNS check")
            T:run(function()
                C.close(cancelled.write_fd)
                cancelled.write_fd = nil
            end)
            T:waitUntil(function() return ffiUtil.isSubProcessDone(pidOf(cancelled)) end, 5, "cancelled resolver exits")
            T:eq(cancelled_calls, 0, "cancellation does not run the online action")
            T:eq(lfs.attributes(cancelled.returned), nil, "cancelled resolver cannot publish a late success")

            local next_calls, next_job = 0
            T:run(function() next_job = start("next", function() next_calls = next_calls + 1 end) end)
            T:waitUntil(function() return pidOf(next_job) end, 5, "a fresh check starts after cancellation")
            T:run(function() release(next_job) end)
            T:waitUntil(function() return next_calls == 1 end, 5, "the fresh check completes")
            T:eq(cancelled_calls, 0, "later completions cannot revive the cancelled action")
            T:eq(next_calls, 1, "the new action runs exactly once")
            T:check(heartbeat_count > before, "UI heartbeats continue throughout DNS checks")

            local info_job
            T:run(function()
                local listener = dofile("frontend/ui/network/networklistener.lua")
                info_job = start("info", function() listener:onInfoWifiOn() end, true)
            end)
            T:waitUntil(function() return pidOf(info_job) end, 5, "Wi-Fi info checks DNS asynchronously")
            T:run(function() release(info_job) end)
            T:waitUntil(function()
                return T:topWidget().text == require("gettext")("Already connected.")
            end, 5, "Wi-Fi info reports the resolved connection")
            T:repaint()
            T:check(T:topWidget().dimen, "the Wi-Fi info result is painted")
            T:tapWidget(T:topWidget(), "dismiss Wi-Fi info")

            local article = "https://example.invalid/synthetic-article"
            local added, article_job
            T:run(function()
                local Wallabag = dofile("plugins/wallabag.koplugin/main.lua")
                local plugin = setmetatable({
                    addArticle = function(_, url) added = url; return true end,
                    addToOfflineQueue = function() error("a resolved online article must not queue") end,
                }, { __index = Wallabag })
                article_job = start("article", function() plugin:onAddWallabagArticle(article) end, true)
            end)
            T:waitUntil(function() return pidOf(article_job) end, 5, "Wallabag checks DNS asynchronously")
            T:eq(added, nil, "Wallabag waits for DNS before attempting upload")
            T:run(function() release(article_job) end)
            T:waitUntil(function() return added == article end, 5, "Wallabag continues after DNS resolves")
            T:repaint()
            T:check(T:topWidget().dimen, "the Wallabag result is painted")
            T:tapWidget(T:topWidget(), "dismiss Wallabag result")
        end)
        T:run(function()
            socket.dns.toip, Device.hasWifiToggle = saved_toip, saved_toggle
            UIManager:unschedule(heartbeat)
            for _, job in ipairs(jobs) do
                if job.widget and UIManager:isWidgetShown(job.widget) then job.widget:_dismissAndResend() end
                local pid = pidOf(job)
                if pid then ffiUtil.terminateSubProcess(pid) end
                if job.write_fd then C.close(job.write_fd) end
            end
            ffiUtil.purgeDir(base)
        end)
        if not ok then error(err, 0) end
    end,
}
