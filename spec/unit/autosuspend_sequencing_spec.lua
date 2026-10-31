-- AutoSuspend: suspend / shutdown / standby / Kindle t1 timers around suspend & resume,
-- charging, network state and repeated Suspend events (no timer leaks, balanced
-- preventStandby / allowStandby), the "suspend gave up" notice, and the timeout menus.
-- UIManager's task queue and standby counters are recorded; Device capabilities and
-- PowerD are stubbed.
describe("AutoSuspend sequencing", function()
    local Device, UIManager, NetworkMgr, PluginShare, time
    local scheduled, shown, prevent, allow, suspends, poweroffs
    local now
    local caps, power
    local orig = {}
    local AutoSuspend

    local function load(is_kindle)
        caps.isKindle = is_kindle or false
        AutoSuspend = dofile("plugins/autosuspend.koplugin/main.lua")
        return AutoSuspend
    end

    local function new(settings)
        for k, v in pairs(settings or {}) do
            G_reader_settings:saveSetting(k, v)
        end
        return AutoSuspend:new{}
    end

    local function tasksFor(fn)
        local t = {}
        for _, s in ipairs(scheduled) do
            if s.fn == fn then table.insert(t, s.delay) end
        end
        return t
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        Device = require("device")
        UIManager = require("ui/uimanager")
        NetworkMgr = require("ui/network/manager")
        PluginShare = require("pluginshare")
        time = require("ui/time")
        for _, k in ipairs{"canSuspend", "canStandby", "canPowerOff", "isKindle", "hasAuxBattery",
                           "canPowerSaveWhileCharging", "isKobo", "hasReliableMxcWaitFor", "standby"} do
            orig[k] = Device[k]
        end
        for _, k in ipairs{"scheduleIn", "unschedule", "show", "suspend", "poweroff_action", "preventStandby",
                           "allowStandby", "getElapsedTimeSinceBoot", "getNextTaskTime", "shiftScheduledTasksBy",
                           "consumeInputEarlyAfterPM"} do
            orig["UI" .. k] = UIManager[k]
        end
        orig.getWifiState = NetworkMgr.getWifiState
        caps = {}
        for _, k in ipairs{"canSuspend", "canStandby", "canPowerOff", "isKindle", "hasAuxBattery",
                           "canPowerSaveWhileCharging", "isKobo", "hasReliableMxcWaitFor"} do
            Device[k] = function() return caps[k] end
        end
    end)

    teardown(function()
        for k, v in pairs(orig) do
            if k:sub(1, 2) == "UI" then
                UIManager[k:sub(3)] = v
            elseif k == "getWifiState" then
                NetworkMgr.getWifiState = v
            else
                Device[k] = v
            end
        end
        for _, k in ipairs{"auto_suspend_timeout_seconds", "autoshutdown_timeout_seconds",
                           "auto_standby_timeout_seconds"} do
            G_reader_settings:delSetting(k)
        end
        PluginShare.pause_auto_suspend = nil
        PluginShare.keepalive = nil
    end)

    before_each(function()
        caps.canSuspend, caps.canStandby, caps.canPowerOff = true, true, true
        caps.hasAuxBattery, caps.canPowerSaveWhileCharging = false, true
        caps.isKobo, caps.hasReliableMxcWaitFor = true, true
        scheduled, shown = {}, {}
        prevent, allow, suspends, poweroffs = 0, 0, 0, 0
        now = time.s(1000)
        power = { charging = false, charged = false, aux_connected = false, aux_charging = false, aux_charged = false,
                  t1_resets = 0 }
        local powerd = Device:getPowerDevice()
        orig.powerd_isCharging = orig.powerd_isCharging or powerd.isCharging
        powerd.isCharging = function() return power.charging end
        powerd.isCharged = function() return power.charged end
        powerd.isAuxBatteryConnected = function() return power.aux_connected end
        powerd.isAuxCharging = function() return power.aux_charging end
        powerd.isAuxCharged = function() return power.aux_charged end
        powerd.resetT1Timeout = function() power.t1_resets = power.t1_resets + 1 end

        UIManager.scheduleIn = function(_, delay, fn) table.insert(scheduled, { delay = delay, fn = fn }) end
        UIManager.unschedule = function(_, fn)
            for i = #scheduled, 1, -1 do
                if scheduled[i].fn == fn then table.remove(scheduled, i) end
            end
        end
        UIManager.show = function(_, w) table.insert(shown, w) end
        UIManager.suspend = function() suspends = suspends + 1 end
        UIManager.poweroff_action = function() poweroffs = poweroffs + 1 end
        UIManager.preventStandby = function() prevent = prevent + 1 end
        UIManager.allowStandby = function() allow = allow + 1 end
        UIManager.getElapsedTimeSinceBoot = function() return now end
        NetworkMgr.getWifiState = function() return false end
        PluginShare.pause_auto_suspend = nil
        PluginShare.keepalive = nil
        G_reader_settings:saveSetting("auto_suspend_timeout_seconds", 600)
        G_reader_settings:saveSetting("autoshutdown_timeout_seconds", 3600)
        G_reader_settings:saveSetting("auto_standby_timeout_seconds", 5)
        Device.wakeup_mgr = nil
        load(false)
    end)

    describe("suspend & shutdown timers", function()
        it("schedules both checks at their full delay on start", function()
            local as = new()
            assert.are.same({ 600, 3600 }, tasksFor(as.task))
        end)

        it("suspends once the delay elapsed since the last input, shuts down first when both are due", function()
            local as = new()
            scheduled = {}
            now = now + time.s(601)
            as:_schedule()
            assert.are.equal(1, suspends)
            assert.are.equal(0, poweroffs)
            now = now + time.s(3600)
            as:_schedule()
            assert.are.equal(1, poweroffs)
            assert.are.equal(1, suspends)
        end)

        it("counts from the last input event", function()
            local as = new()
            scheduled = {}
            now = now + time.s(500)
            as:onInputEvent()
            now = now + time.s(200)
            as:_schedule()
            assert.are.equal(0, suspends)
            assert.are.same({ 400, 3400 }, tasksFor(as.task))
        end)

        it("restarts the full delays while charging (main or aux battery) or paused", function()
            local as = new()
            for _, setup_fn in ipairs{
                function() power.charging = true end,
                function() caps.hasAuxBattery = true; power.aux_connected = true; power.aux_charging = true end,
                function() PluginShare.pause_auto_suspend = true end,
            } do
                power.charging, caps.hasAuxBattery, power.aux_connected, power.aux_charging = false, false, false, false
                PluginShare.pause_auto_suspend = nil
                setup_fn()
                scheduled = {}
                now = now + time.s(10000)
                as:_schedule()
                assert.are.equal(0, suspends)
                assert.are.same({ 600, 3600 }, tasksFor(as.task))
            end
            -- Fully charged: back to normal, suspends.
            PluginShare.pause_auto_suspend = nil
            power.charging, power.charged = true, true
            now = now + time.s(10000)
            as:_schedule()
            assert.are.equal(1, poweroffs + suspends)
        end)

        it("does nothing when disabled", function()
            local as = new{ auto_suspend_timeout_seconds = -1, autoshutdown_timeout_seconds = -1 }
            assert.are.equal(0, #tasksFor(as.task))
            as:_schedule()
            assert.are.equal(0, #scheduled - #tasksFor(as.standby_task))
            caps.canPowerOff = false
            as = new{ auto_suspend_timeout_seconds = 600, autoshutdown_timeout_seconds = 3600 }
            assert.are.same({ 600 }, tasksFor(as.task))
        end)

        it("onCloseWidget drops every timer", function()
            local as = new()
            assert.is_true(#scheduled > 0)
            as:onCloseWidget()
            assert.are.equal(0, #scheduled)
            assert.is_nil(as.task)
            assert.is_nil(as.standby_task)
        end)
    end)

    describe("suspend / resume", function()
        it("unschedules on suspend, arms the shutdown alarm, and restarts on resume", function()
            local wm = { addTask = spy.new(function() end), removeTasks = spy.new(function() end) }
            Device.wakeup_mgr = wm
            local as = new()
            as:onSuspend()
            assert.are.equal(0, #tasksFor(as.task))
            assert.are.equal(0, #tasksFor(as.standby_task))
            assert.spy(wm.addTask).was.called_with(wm, 3600, UIManager.poweroff_action)
            as:onResume()
            assert.spy(wm.removeTasks).was.called_with(wm, nil, UIManager.poweroff_action)
            assert.are.same({ 600, 3600 }, tasksFor(as.task))
            -- First standby check after resume uses the fixed 4 s delay.
            assert.are.same({ 4 }, tasksFor(as.standby_task))
            Device.wakeup_mgr = nil
        end)

        it("keeps preventStandby / allowStandby balanced over a series of Suspend events", function()
            local as = new()
            assert.are.equal(1, prevent) -- the standby timer
            as:onSuspend() -- Power button
            as:onSuspend() -- then Charging
            as:onSuspend() -- then SleepCover
            -- Unscheduling standby released it once, suspend prevented it once.
            assert.are.equal(2, prevent)
            assert.are.equal(1, allow)
            as:onResume()
            -- Resume releases the suspend hold, and the new standby timer holds again.
            assert.are.equal(3, prevent)
            assert.are.equal(2, allow)
            assert.is_false(as.going_to_suspend)
        end)

        it("doesn't schedule standby while going to suspend", function()
            local as = new()
            as:onSuspend()
            scheduled = {}
            as:_schedule_standby()
            assert.are.equal(0, #scheduled)
        end)

        it("after giving up on suspend, only re-arms shutdown and tells the user on the next resume", function()
            local as = new()
            as:onUnexpectedWakeupLimit()
            assert.are.same({ 3600 }, tasksFor(as.task))
            assert.is_true(as.suspend_gave_up)
            as:onResume()
            assert.are.equal(1, #shown)
            assert.is_truthy(shown[1].text:find("could not suspend"))
            assert.is_nil(as.suspend_gave_up)
            as:onResume()
            assert.are.equal(1, #shown)
        end)

        it("re-engages both timers when unplugged", function()
            local as = new()
            as:onUnexpectedWakeupLimit()
            as:onNotCharging()
            assert.are.same({ 600, 3600 }, tasksFor(as.task))
        end)
    end)

    describe("standby", function()
        it("waits the full delay on the first check, then allows standby once the deadline passed", function()
            local as = new()
            assert.are.same({ 5 }, tasksFor(as.standby_task))
            assert.are.equal(1, prevent)
            now = now + time.s(6)
            scheduled = {}
            as:_schedule_standby()
            assert.are.equal(1, allow)
            assert.is_false(as.is_standby_scheduled)
            -- A fresh cycle that already blew the deadline (woken by an alarm): full delay again.
            now = now + time.s(60)
            as:_schedule_standby()
            assert.are.same({ 5 }, tasksFor(as.standby_task))
        end)

        it("is postponed by the full delay while Wi-Fi is on, or while charging on devices that can't save power then", function()
            local as = new()
            now = now + time.s(60)
            NetworkMgr.getWifiState = function() return true end
            as:_schedule_standby()
            assert.are.equal(0, allow)
            NetworkMgr.getWifiState = function() return false end
            power.charging = true
            caps.canPowerSaveWhileCharging = false
            as:_schedule_standby()
            assert.are.equal(0, allow)
            caps.canPowerSaveWhileCharging = true
            as:_schedule_standby()
            assert.are.equal(1, allow)
        end)

        it("isn't scheduled when disabled or unsupported", function()
            local as = new{ auto_standby_timeout_seconds = -1 }
            assert.are.equal(0, #tasksFor(as.standby_task))
            assert.is_nil(as.onAllowStandby)
            as:_schedule_standby()
            assert.are.equal(0, #tasksFor(as.standby_task))
            caps.canStandby = false
            G_reader_settings:saveSetting("auto_standby_timeout_seconds", 5)
            as = new()
            assert.are.equal(0, #tasksFor(as.standby_task))
        end)

        it("network events: no standby while connected, back to normal once disconnected", function()
            local as = new()
            as:onNetworkConnected()
            assert.are.same({ math.huge }, tasksFor(as.standby_task))
            as:onNetworkDisconnected()
            assert.are.same({ 5 }, tasksFor(as.standby_task))
            assert.are.equal(prevent - 1, allow) -- balanced, one hold for the current timer
        end)

        it("enters standby until the next task, then shifts the task queue by the time spent", function()
            local as = new()
            assert.are.equal(as.AllowStandbyHandler, as.onAllowStandby)
            local standby = spy.new(function() Device.last_standby_time = time.s(30) end)
            Device.standby = standby
            local shifted
            UIManager.getNextTaskTime = function() return time.s(12.5) end
            UIManager.shiftScheduledTasksBy = function(_, d) shifted = d end
            UIManager.consumeInputEarlyAfterPM = spy.new(function() end)
            as:onAllowStandby()
            assert.spy(standby).was.called_with(Device, 13)
            assert.are.equal(-time.s(30), shifted)
            assert.spy(UIManager.consumeInputEarlyAfterPM).was.called_with(UIManager, true)
            -- Nothing scheduled: wake up whenever.
            UIManager.getNextTaskTime = function() return nil end
            as:onAllowStandby()
            assert.spy(standby).was.called_with(Device, math.huge)
            -- Next task (already due) in less than a second: don't bother, check again right after it.
            UIManager.getNextTaskTime = function() return -time.s(0.5) end
            scheduled = {}
            as.is_standby_scheduled = false
            as:onAllowStandby()
            assert.spy(standby).was.called(2)
            assert.are.same({ 0.1 }, tasksFor(as.standby_task))
            as:toggleStandbyHandler(false)
            assert.is_nil(as.onAllowStandby)
        end)
    end)

    describe("Kindle t1 timeout", function()
        before_each(function()
            load(true)
        end)

        it("resets powerd's t1 timeout every 4 minutes while autosuspend is further away", function()
            local as = new()
            -- (The first reset happens right away: none since boot.)
            assert.are.equal(1, power.t1_resets)
            assert.are.same({ 240 }, tasksFor(as.kindle_task))
            now = now + time.s(241)
            as:onInputEvent()
            scheduled = {}
            as:_schedule_kindle()
            assert.are.equal(2, power.t1_resets)
            assert.are.same({ 240 }, tasksFor(as.kindle_task))
            -- Not due yet: just reschedule for the remainder.
            now = now + time.s(100)
            scheduled = {}
            as:_schedule_kindle()
            assert.are.equal(2, power.t1_resets)
            assert.are.same({ 140 }, tasksFor(as.kindle_task))
        end)

        it("doesn't reset it when autosuspend is due anyway, with KeepAlive, or while charging", function()
            local as = new()
            local resets = power.t1_resets
            now = now + time.s(601)
            as:_schedule_kindle()
            assert.are.equal(resets, power.t1_resets)
            now = time.s(1000) + time.s(300)
            PluginShare.keepalive = true
            scheduled = {}
            as:_schedule_kindle()
            assert.are.equal(0, #scheduled)
            PluginShare.keepalive = nil
            power.charging = true
            as:_schedule_kindle()
            assert.are.equal(0, #scheduled)
            assert.are.equal(resets, power.t1_resets)
        end)

        it("stops on suspend and when disabled", function()
            local as = new()
            as:onSuspend()
            assert.are.equal(0, #tasksFor(as.kindle_task))
            as:onResume()
            assert.are.equal(1, #tasksFor(as.kindle_task))
            as:onCloseWidget()
            local disabled = new{ auto_suspend_timeout_seconds = -1 }
            assert.are.equal(0, #tasksFor(disabled.kindle_task))
            disabled:_schedule_kindle()
            assert.are.equal(0, #tasksFor(disabled.kindle_task))
        end)

        it("defers overdue t1 checks when powerd has not acknowledged suspend", function()
            local as = new()
            local last_reset, resets = as.last_t1_reset_time, power.t1_resets
            now = now + time.s(601)
            for _ = 1, 3 do
                scheduled = {}
                as:_schedule_kindle()
                assert.are.same({ 240 }, tasksFor(as.kindle_task))
                assert.are.equal(resets, power.t1_resets)
                assert.are.equal(last_reset, as.last_t1_reset_time)
                now = now + time.s(240)
            end
            -- New user input makes the old t1 reset eligible again.
            as:onInputEvent()
            scheduled = {}
            as:_schedule_kindle()
            assert.are.equal(resets + 1, power.t1_resets)
            assert.are.equal(now, as.last_t1_reset_time)
            assert.are.same({ 240 }, tasksFor(as.kindle_task))
        end)

        it("defers a zero t1 delay without extending a still-positive remainder", function()
            local as = new()
            local resets = power.t1_resets
            now = now + time.s(600)
            as.last_t1_reset_time = now - time.s(240)
            scheduled = {}
            as:_schedule_kindle()
            assert.are.same({ 240 }, tasksFor(as.kindle_task))
            assert.are.equal(now - time.s(240), as.last_t1_reset_time)
            assert.are.equal(resets, power.t1_resets)

            as.last_t1_reset_time = now - time.s(100)
            scheduled = {}
            as:_schedule_kindle()
            assert.are.same({ 140 }, tasksFor(as.kindle_task))
            assert.are.equal(now - time.s(100), as.last_t1_reset_time)
            assert.are.equal(resets, power.t1_resets)
        end)
    end)

    describe("menus", function()
        it("sets, defaults and disables the timeouts through the time picker", function()
            local as = new()
            local menu = {}
            as:addToMainMenu(menu)
            assert.is_truthy(menu.autosuspend.text_func():find("Autosuspend timeout"))
            assert.is_true(menu.autosuspend.checked_func())
            assert.is_true(menu.autoshutdown.checked_func())
            assert.is_true(menu.autostandby.checked_func())
            assert.is_truthy(menu.autostandby.help_text:find("Standby"))
            local tm = { updateItems = spy.new(function() end) }

            -- autosuspend: hour:min picker
            menu.autosuspend.callback(tm)
            local picker = shown[#shown]
            picker.default_callback()
            picker.callback({ hour = 0, min = 30 })
            assert.are.equal(1800, G_reader_settings:readSetting("auto_suspend_timeout_seconds"))
            assert.are.same({ 1800, 3600 }, tasksFor(as.task))
            assert.spy(tm.updateItems).was.called(1)
            -- Clamped to the allowed range
            picker.callback({ hour = 0, min = 0 })
            assert.are.equal(60, as.auto_suspend_timeout_seconds)
            picker.extra_callback(picker)
            assert.are.equal(-1, G_reader_settings:readSetting("auto_suspend_timeout_seconds"))
            assert.is_false(menu.autosuspend.checked_func())
            assert.are.equal("Autosuspend timeout", menu.autosuspend.text_func())

            -- autoshutdown: day:hour picker
            menu.autoshutdown.callback(tm)
            picker = shown[#shown]
            picker.default_callback()
            picker.callback({ day = 2, hour = 3 })
            assert.are.equal((2 * 24 + 3) * 3600, as.autoshutdown_timeout_seconds)
            assert.is_truthy(menu.autoshutdown.text_func():find("Autoshutdown timeout:"))

            -- autostandby: min:sec picker, toggles the AllowStandby handler
            menu.autostandby.callback(tm)
            picker = shown[#shown]
            picker.default_callback()
            picker.extra_callback(picker)
            assert.is_nil(as.onAllowStandby)
            assert.are.equal("Autostandby timeout", menu.autostandby.text_func())
            picker.callback({ min = 0, sec = 7 })
            assert.are.equal(7, as.auto_standby_timeout_seconds)
            assert.are.equal(as.AllowStandbyHandler, as.onAllowStandby)
            assert.are.same({ 7 }, tasksFor(as.standby_task))
            assert.is_truthy(menu.autostandby.text_func():find("Autostandby timeout:"))
        end)

        it("warns about unreliable Kobos", function()
            caps.hasReliableMxcWaitFor = false
            local menu = {}
            new():addToMainMenu(menu)
            assert.is_truthy(menu.autostandby.help_text:find("unreliable"))
        end)

        it("is disabled on devices that can't suspend", function()
            caps.canSuspend = false
            assert.is_true(load(false).disabled)
        end)
    end)
end)
