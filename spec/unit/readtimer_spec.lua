describe("ReadTimer elapsed-time scheduling", function()
    local UIManager, HookContainer, Notification, time, ReadTimer
    local saved, timers, tasks, events, boot, mono, registered_trigger, broadcast_callback, shown

    setup(function()
        require("commonrequire")
        UIManager = require("ui/uimanager")
        HookContainer = require("ui/hook_container")
        Notification = require("ui/widget/notification")
        time = require("ui/time")
    end)

    before_each(function()
        saved = { now = time.now, elapsed = time.boottime_or_realtime_coarse,
            hook = UIManager.event_hook, settings = G_reader_settings:readSetting("readtimer"), ui = {},
            notifications = Notification._shown_list }
        Notification._shown_list = {}
        timers, tasks, events, shown = {}, {}, {}, {}
        broadcast_callback = nil
        boot, mono, registered_trigger = time.s(1000), time.s(100), nil
        time.now = function() return mono end
        time.boottime_or_realtime_coarse = function() return boot end
        for _, key in ipairs({ "scheduleIn", "unschedule", "broadcastEvent", "show" }) do
            saved.ui[key] = rawget(UIManager, key)
        end
        UIManager.event_hook = HookContainer:new()
        UIManager.scheduleIn = function(_, seconds, action, ...)
            tasks[#tasks + 1] = { seconds = seconds, action = action, args = { ... } }
        end
        UIManager.unschedule = function(_, action)
            for i = #tasks, 1, -1 do if tasks[i].action == action then table.remove(tasks, i) end end
        end
        UIManager.broadcastEvent = function(_, event)
            events[#events + 1] = event.handler
            if broadcast_callback then broadcast_callback(event) end
        end
        UIManager.show = function(_, widget) shown[#shown + 1] = widget end
        G_reader_settings:saveSetting("readtimer", { show_on_expiry = "nothing" })
        ReadTimer = dofile("plugins/readtimer.koplugin/main.lua")
    end)

    after_each(function()
        for _, timer in ipairs(timers) do pcall(timer.onCloseWidget, timer) end
        time.now, time.boottime_or_realtime_coarse = saved.now, saved.elapsed
        UIManager.event_hook = saved.hook
        for _, key in ipairs({ "scheduleIn", "unschedule", "broadcastEvent", "show" }) do UIManager[key] = saved.ui[key] end
        G_reader_settings:saveSetting("readtimer", saved.settings)
        Notification._shown_list = saved.notifications
        for _, widget in ipairs(shown) do widget:free() end
    end)

    local function timer()
        local widget = ReadTimer:new{
            onDispatcherRegisterActions = function() end,
            ui = {
                bookinfo = { expandString = function(_, text) return text end },
                menu = { registerToMainMenu = function() end },
                profiles = { registerAutoExecTrigger = function(_, trigger) registered_trigger = trigger end },
                registerPostInitCallback = function(_, callback) callback() end,
            },
        }
        timers[#timers + 1] = widget
        return widget
    end

    local function alarmTasks(widget)
        local result = {}
        for _, task in ipairs(tasks) do if task.action == widget.alarm_callback then result[#result + 1] = task end end
        return result
    end

    it("counts elapsed standby time even when the UI clock does not advance", function()
        local widget = timer()
        widget:rescheduleIn(900)
        boot = boot + time.s(480)
        assert.equals(420, widget:remaining())
    end)

    it("expires once on resume after its elapsed deadline", function()
        local widget = timer()
        widget:rescheduleIn(900)
        boot = boot + time.s(901)
        widget:onResume()
        widget:onResume()
        assert.is_false(widget:scheduled())
        assert.same({ "onReadTimerExpired" }, events)
    end)

    it("keeps an automatically repeated interval alive after overdue resume", function()
        local widget = timer()
        widget.settings.auto_reschedule_interval = true
        widget.last_interval_time = 900
        widget:rescheduleIn(900)
        -- Advance both clocks so this also exposes the existing post-callback
        -- unschedule bug independently of the clock-source correction.
        boot, mono = boot + time.s(901), mono + time.s(901)
        widget:onResume()
        assert.is_true(widget:scheduled())
        assert.equals(900, widget:remaining())
        assert.same({ "onReadTimerExpired" }, events)
    end)

    it("uses the actual input hook when a device supplies no Resume event", function()
        local widget = timer()
        widget:rescheduleIn(900)
        boot = boot + time.s(901)
        UIManager.event_hook:execute("InputEvent")
        assert.is_false(widget:scheduled())
        assert.same({ "onReadTimerExpired" }, events)
        assert.equals("ReadTimerExpired", registered_trigger.event)
    end)

    it("reconciles repeated input without postponing the elapsed deadline", function()
        local widget = timer()
        widget:rescheduleIn(900)
        local deadline = widget.time
        boot = boot + time.s(480)
        UIManager.event_hook:execute("InputEvent")
        UIManager.event_hook:execute("InputEvent")
        assert.equals(deadline, widget.time)
        assert.equals(1, #alarmTasks(widget))
        assert.equals(420, alarmTasks(widget)[1].seconds)
        assert.same({}, events)
    end)

    it("retains the deadline when resuming before it is due", function()
        local widget = timer()
        widget:rescheduleIn(900)
        local deadline = widget.time
        boot = boot + time.s(480)
        widget:onResume()
        assert.equals(deadline, widget.time)
        assert.equals(420, widget:remaining())
        assert.equals(1, #alarmTasks(widget))
    end)

    it("removes the old hook and transfers only the live timer across views", function()
        local old = timer()
        old.last_interval_time = 900
        old:rescheduleIn(900)
        local deadline = old.time
        old:onCloseWidget()
        assert.equals(0, UIManager.event_hook:execute("InputEvent"))
        assert.equals(0, #alarmTasks(old))
        boot = boot + time.s(480)
        local current = timer()
        assert.equals(deadline, current.time)
        assert.equals(900, current.last_interval_time)
        assert.equals(420, current:remaining())
        assert.equals(1, UIManager.event_hook:execute("InputEvent"))
        current:onCloseWidget()
        assert.equals(0, UIManager.event_hook:execute("InputEvent"))
    end)

    it("expires a restored overdue timer once if input beats its queued zero-delay callback", function()
        local old = timer()
        old:rescheduleIn(900)
        old:onCloseWidget()
        boot = boot + time.s(901)
        local current = timer()
        assert.equals(0, alarmTasks(current)[1].seconds)
        UIManager.event_hook:execute("InputEvent")
        current:alarm_callback()
        assert.is_false(current:scheduled())
        assert.same({ "onReadTimerExpired" }, events)
        assert.equals(0, #alarmTasks(current))
    end)

    it("refreshes visible timer fields after removing an expired status task", function()
        local widget = timer()
        widget.settings.show_value_in_header, widget.settings.show_value_in_footer = true, true
        widget:rescheduleIn(900)
        events = {}
        boot = boot + time.s(901)
        UIManager.event_hook:execute("InputEvent")
        assert.same({ "onReadTimerExpired", "onUpdateHeader", "onRefreshAdditionalContent" }, events)
        assert.equals(0, #tasks)
    end)

    it("does not report expiry from a stale UI deadline after the fallback clock moves back", function()
        local widget = timer()
        widget:rescheduleIn(900)
        boot, mono = boot - time.s(60), mono + time.s(900)
        widget:alarm_callback()
        assert.is_true(widget:scheduled())
        assert.equals(960, widget:remaining())
        assert.equals(1, #alarmTasks(widget))
        assert.equals(960, alarmTasks(widget)[1].seconds)
        assert.same({}, events)
    end)

    it("keeps exactly one repeated timer after input expiry and a stale callback", function()
        local widget = timer()
        widget.settings.auto_reschedule_interval = true
        widget.last_interval_time = 900
        widget:rescheduleIn(900)
        boot = boot + time.s(901)
        UIManager.event_hook:execute("InputEvent")
        widget:alarm_callback()
        assert.equals(900, widget:remaining())
        assert.equals(1, #alarmTasks(widget))
        assert.same({ "onReadTimerExpired" }, events)
    end)

    it("does not replace a timer started synchronously by an expiry profile", function()
        local widget = timer()
        widget.settings.auto_reschedule_interval = true
        widget.last_interval_time = 900
        widget:rescheduleIn(900)
        broadcast_callback = function(event)
            if event.handler == "onReadTimerExpired" then widget:rescheduleIn(60) end
        end
        boot, mono = boot + time.s(901), mono + time.s(901)
        widget:onResume()
        assert.equals(60, widget:remaining())
        assert.equals(1, #alarmTasks(widget))
    end)

    it("does not access a closed view after a synchronous expiry profile closes it", function()
        local widget = timer()
        widget.settings.show_on_expiry = "notification"
        widget:rescheduleIn(900)
        broadcast_callback = function(event)
            if event.handler == "onReadTimerExpired" then
                widget:onCloseWidget()
                widget.ui = nil
            end
        end
        boot, mono = boot + time.s(901), mono + time.s(901)
        widget:onResume()
        assert.equals(0, #shown)
        assert.equals(0, UIManager.event_hook:execute("InputEvent"))
    end)

    it("keeps ordinary running-clock expiry and repeated stale callbacks idempotent", function()
        local widget = timer()
        widget:rescheduleIn(60)
        boot, mono = boot + time.s(60), mono + time.s(60)
        widget:alarm_callback()
        widget:alarm_callback()
        UIManager.event_hook:execute("InputEvent")
        assert.is_false(widget:scheduled())
        assert.same({ "onReadTimerExpired" }, events)
    end)

    it("stops explicitly and does not transfer a stopped timer to the next view", function()
        local widget = timer()
        widget:rescheduleIn(60)
        widget:unschedule()
        widget:onCloseWidget()
        local current = timer()
        assert.is_false(current:scheduled())
        boot = boot + time.s(120)
        UIManager.event_hook:execute("InputEvent")
        assert.same({}, events)
        assert.equals(0, #tasks)
    end)

    it("preserves the notification and its automatic repeat", function()
        local widget = timer()
        widget.settings.show_on_expiry = "notification"
        widget.settings.auto_reschedule_interval = true
        widget.last_interval_time = 60
        widget:rescheduleIn(60)
        boot = boot + time.s(61)
        widget:onResume()
        assert.equals(1, #shown)
        assert.equals("Time is up", shown[1].text)
        assert.equals(60, widget:remaining())
        assert.equals(1, #alarmTasks(widget))
    end)

    it("preserves the real interval popup's snooze and repeat callbacks", function()
        local widget = timer()
        widget.settings.show_on_expiry = nil
        widget.settings.snooze_minutes = 3
        widget.last_interval_time = 60
        widget:rescheduleIn(60)
        boot = boot + time.s(61)
        widget:onResume()
        assert.equals(1, #shown)
        assert.is_false(widget:scheduled())
        shown[1].choice1_callback()
        assert.equals(180, widget:remaining())
        widget:unschedule()
        shown[1].choice2_callback()
        assert.equals(60, widget:remaining())
    end)

    it("does not request catch-up alarms for every interval missed during sleep", function()
        local widget = timer()
        widget.settings.auto_reschedule_interval = true
        widget.last_interval_time = 60
        widget:rescheduleIn(60)
        boot = boot + time.s(3600)
        UIManager.event_hook:execute("InputEvent")
        assert.same({ "onReadTimerExpired" }, events)
        assert.equals(60, widget:remaining())
        assert.equals(1, #alarmTasks(widget))
    end)

    it("removes a status task when an expiry profile closes an already expired view", function()
        local widget = timer()
        widget.settings.show_value_in_header = true
        widget:rescheduleIn(60)
        -- The real UI dispatcher removes a task before invoking its callback.
        UIManager:unschedule(widget.alarm_callback)
        broadcast_callback = function(event)
            if event.handler == "onReadTimerExpired" then widget:onCloseWidget() end
        end
        boot = boot + time.s(61)
        widget:alarm_callback()
        assert.equals(0, #tasks)
        assert.equals(0, UIManager.event_hook:execute("InputEvent"))
    end)

    it("restores one display tick if the fallback clock moves back between expiry checks", function()
        local widget = timer()
        widget.settings.show_value_in_header = true
        widget:rescheduleIn(60)
        local deadline = widget.time
        local reads = 0
        time.boottime_or_realtime_coarse = function()
            reads = reads + 1
            return deadline + time.s(reads == 1 and 1 or -30)
        end
        events = {}
        widget:expireIfDue()
        assert.equals(deadline, widget.time)
        assert.equals(30, widget:remaining())
        assert.equals(1, #alarmTasks(widget))
        local display_tasks = 0
        for _, task in ipairs(tasks) do if task.action == widget.update_status_bars then display_tasks = display_tasks + 1 end end
        assert.equals(1, display_tasks)
        assert.same({ "onUpdateHeader" }, events)
    end)

    it("reschedules resume if the fallback clock moves back at its expiry boundary", function()
        local widget = timer()
        widget:rescheduleIn(900)
        local deadline = widget.time
        local reads = 0
        time.boottime_or_realtime_coarse = function()
            reads = reads + 1
            return deadline + time.s(reads == 1 and 1 or -30)
        end
        widget:onResume()
        assert.equals(deadline, widget.time)
        assert.equals(30, widget:remaining())
        assert.equals(1, #alarmTasks(widget))
        assert.equals(30, alarmTasks(widget)[1].seconds)
        assert.same({}, events)
    end)
end)
