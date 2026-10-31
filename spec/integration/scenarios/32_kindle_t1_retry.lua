-- Real reader and UI task queue; only Kindle capabilities and powerd are synthetic.
-- Refuse unsafe delays before inserting them, so the old implementation fails
-- without deliberately wedging the emulator in an immediate-task loop.
return {
    name = "An unacknowledged Kindle suspend keeps the reader responsive",
    timeout = 180, -- Includes the driver's startup and open-book waits.
    run = function(T)
        local Device = require("device")
        local UIManager = require("ui/uimanager")
        local PluginShare = require("pluginshare")
        local time = require("ui/time")
        local original_kind, original_suspend = Device.isKindle, Device.canSuspend
        local original_power = Device.getPowerDevice
        local original_schedule = UIManager.scheduleIn
        local original_keepalive = PluginShare.keepalive
        local resets, calls, beats = 0, 0, 0
        local as, heartbeat
        local function countTasks(action)
            local count = 0
            for _, task in ipairs(UIManager._task_queue) do
                if task.action == action then count = count + 1 end
            end
            return count
        end
        local ok, err = xpcall(function()
            local ui = T:openBook(T:fixture("books/en.epub"))
            T:run(function()
                Device.isKindle = function() return true end
                Device.canSuspend = function() return true end
                Device.getPowerDevice = function()
                    return {
                        isCharging = function() return false end,
                        resetT1Timeout = function() resets = resets + 1 end,
                    }
                end
                local AutoSuspend = dofile("plugins/autosuspend.koplugin/main.lua")
                Device.isKindle, Device.canSuspend = original_kind, original_suspend
                Device.getPowerDevice = original_power
                PluginShare.keepalive = nil
                local now = UIManager:getElapsedTimeSinceBoot()
                as = setmetatable({
                    auto_suspend_timeout_seconds = 600,
                    autoshutdown_timeout_seconds = -1,
                    auto_standby_timeout_seconds = -1,
                    last_action_time = now - time.s(601),
                    last_t1_reset_time = now - time.s(601),
                }, { __index = AutoSuspend })
                as.kindle_task = function()
                    calls = calls + 1
                    as:_schedule_kindle()
                end
                UIManager.scheduleIn = function(manager, delay, action, ...)
                    if action == as.kindle_task then
                        T:check(delay > 0, "the overdue check cannot enqueue an immediate task")
                        T:eq(delay, 240, "the retry keeps the existing four-minute interval")
                    end
                    return original_schedule(manager, delay, action, ...)
                end
                local last_reset = as.last_t1_reset_time
                as.kindle_task()
                T:eq(resets, 0, "an ignored suspend does not reset powerd")
                T:eq(as.last_t1_reset_time, last_reset, "deferral does not claim a t1 reset")
                T:eq(countTasks(as.kindle_task), 1, "exactly one future check is queued")
                heartbeat = function()
                    beats = beats + 1
                    UIManager:scheduleIn(0.02, heartbeat)
                end
                UIManager:scheduleIn(0.02, heartbeat)
            end)
            T:waitUntil(function() return beats >= 2 end, 5,
                "the real UI queue continues to service other tasks")
            T:eq(calls, 1, "the overdue t1 check does not spin while idle")
            T:metric("t1_checks_before_input", calls, "count")
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return ui:getCurrentPage() == 2 end, 5, "page turn while a t1 retry is pending")
            T:run(function()
                UIManager:unschedule(as.kindle_task)
                as:onInputEvent()
                as.kindle_task()
                T:eq(resets, 1, "new user input permits the normal overdue t1 reset")
                T:eq(countTasks(as.kindle_task), 1, "normal operation leaves one t1 check")
                as:onSuspend()
                T:eq(countTasks(as.kindle_task), 0, "an acknowledged suspend cancels the deferred timer")
            end)
            T:metric("ui_heartbeats_during_retry", beats, "count")
        end, debug.traceback)
        T:run(function()
            Device.isKindle, Device.canSuspend = original_kind, original_suspend
            Device.getPowerDevice = original_power
            UIManager.scheduleIn = original_schedule
            PluginShare.keepalive = original_keepalive
            if heartbeat then UIManager:unschedule(heartbeat) end
            if as then as:_unschedule_kindle() end
        end)
        if not ok then error(err, 0) end
        T:closeBook()
    end,
}
