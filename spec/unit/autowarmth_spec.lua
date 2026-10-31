-- Exercise production scheduling and the generic power driver's real conversion.
-- Sun/time and task-queue boundaries are synthetic; no light or night mode is set.
describe("AutoWarmth native-step scheduling", function()
    local Device, BasePowerD, DeviceListener, SunTime, UIManager
    local original_package_path, original_has_natural_light, original_powerd
    local saved_sun, saved_ui, saved_timezone, saved_night_mode
    local native_writes, night_modes
    local sun_methods = { "setPosition", "setAdvanced", "setDate", "calculateTimes", "getTimeInSec", "getTimezoneOffset" }

    setup(function()
        require("commonrequire")
        original_package_path = package.path
        package.path = "plugins/autowarmth.koplugin/?.lua;" .. package.path
        Device = require("device")
        BasePowerD = require("device/generic/powerd")
        DeviceListener = require("device/devicelistener")
        SunTime = require("suntime")
        UIManager = require("ui/uimanager")
        original_has_natural_light = rawget(Device, "hasNaturalLight")
        original_powerd = Device.powerd
    end)

    teardown(function()
        package.path = original_package_path
    end)

    before_each(function()
        saved_timezone = G_reader_settings:readSetting("autowarmth_timezone")
        saved_night_mode = rawget(DeviceListener, "onSetNightMode")
        native_writes, night_modes = {}, {}
        DeviceListener.onSetNightMode = function(_, enabled) night_modes[#night_modes + 1] = enabled end
        saved_sun, saved_ui = {}, {}
        for _, key in ipairs(sun_methods) do
            saved_sun[key] = rawget(SunTime, key)
            SunTime[key] = function() end
        end
        SunTime.getTimezoneOffset = function() return 0 end
        SunTime.getTimeInSec = function(_, hours) return hours and hours * 3600 or 0 end
        for _, key in ipairs({ "scheduleIn", "unschedule", "broadcastEvent" }) do
            saved_ui[key] = rawget(UIManager, key)
            UIManager[key] = function() end
        end
    end)

    after_each(function()
        Device.hasNaturalLight = original_has_natural_light
        Device.powerd = original_powerd
        DeviceListener.onSetNightMode = saved_night_mode
        for _, key in ipairs(sun_methods) do SunTime[key] = saved_sun[key] end
        for _, key in ipairs({ "scheduleIn", "unschedule", "broadcastEvent" }) do UIManager[key] = saved_ui[key] end
        G_reader_settings:saveSetting("autowarmth_timezone", saved_timezone)
    end)

    local function schedule(native_max, first, last, has_light, start_h, end_h, control_warmth)
        Device.hasNaturalLight = function() return has_light ~= false end
        -- Do not instantiate a real device driver or mutate BasePowerD's class scale.
        Device.powerd = setmetatable({
            device = Device, fl_warmth_max = native_max, warmth_scale = 100 / native_max,
            setWarmthHW = function(_, value) native_writes[#native_writes + 1] = value end,
            stateChanged = function() end,
        }, { __index = BasePowerD })
        local AutoWarmth = dofile("plugins/autowarmth.koplugin/main.lua")
        local widget = setmetatable({
            activate = 2, easy_mode = false, location = "", latitude = 0,
            longitude = 0, timezone = 0, altitude = 0,
            scheduler_times = { start_h or 0, end_h or 1 }, warmth = { first, last },
            control_warmth = control_warmth ~= false, control_nightmode = true,
            scheduleNextWarmthChange = function() end,
            scheduleToggleFrontlight = function() end,
            toggleFrontlight = function() end,
        }, { __index = AutoWarmth })
        widget:scheduleMidnightUpdate()
        assert.equals(first, widget.sched_warmths[1])
        assert.equals(last, widget.sched_warmths[#widget.sched_warmths])
        assert.equals((start_h or 0) * 3600, widget.sched_times_s[1])
        assert.equals((end_h or 1) * 3600, widget.sched_times_s[#widget.sched_times_s])
        return widget
    end

    local function assertNativeSteps(widget, first, last)
        local direction = last > first and 1 or -1
        assert.equals(math.abs(last - first) + 1, #widget.sched_warmths)
        for i, warmth in ipairs(widget.sched_warmths) do
            assert.equals(first + direction * (i - 1), Device.powerd:toNativeWarmth(warmth))
            if i > 1 then assert.is_true(widget.sched_times_s[i] > widget.sched_times_s[i - 1]) end
        end
    end

    for _, native_max in ipairs({ 10, 24, 100 }) do
        it("covers every native level on the descending " .. native_max .. "-step range", function()
            assertNativeSteps(schedule(native_max, 100, 0), native_max, 0)
        end)
        it("covers every native level on the ascending " .. native_max .. "-step range", function()
            assertNativeSteps(schedule(native_max, 0, 100), 0, native_max)
        end)
    end

    it("covers the reported 90-to-20 Kindle range without duplicating its endpoint level", function()
        assertNativeSteps(schedule(24, 90, 20), 22, 5)
    end)

    it("covers the reverse partial Kindle range", function()
        assertNativeSteps(schedule(24, 20, 90), 5, 22)
    end)

    it("retains configured anchors when both percentages map to the same level", function()
        local widget = schedule(24, 50, 51)
        assert.same({ 50, 51 }, widget.sched_warmths)
    end)

    it("does not add intermediates to a constant segment", function()
        assert.same({ 50, 50 }, schedule(24, 50, 50).sched_warmths)
    end)

    it("does not interpolate a zero-duration segment", function()
        assert.same({ 100, 0 }, schedule(24, 100, 0, true, 1, 1).sched_warmths)
    end)

    it("does not interpolate backwards in time", function()
        assert.same({ 100, 0 }, schedule(24, 100, 0, true, 2, 1).sched_warmths)
    end)

    it("uses integer-percentage input resolution rather than claiming all 256 native levels", function()
        local widget = schedule(255, 100, 0)
        assert.equals(101, #widget.sched_warmths)
        for i, warmth in ipairs(widget.sched_warmths) do assert.equals(101 - i, warmth) end
    end)

    it("preserves night-only timing when an unexposed warmth driver has a 24-step scale", function()
        -- KindlePowerD declares 24 even on Kindles without natural light.
        -- Night-mode-only UI entries can retain the percentage plus the 1000 flag.
        local widget = schedule(24, 1100, 0, false)
        assert.equals(101, #widget.sched_warmths)
        assert.equals(99, widget.sched_warmths[2])
        assert.equals(36, widget.sched_times_s[2])
    end)

    it("preserves explicit night-mode anchors without inventing a flagged ramp", function()
        assert.same({ 1100, 1000 }, schedule(24, 1100, 1000).sched_warmths)
    end)

    it("does not introduce a reverse hardware step when leaving a flagged 90-percent anchor", function()
        local widget = schedule(24, 1090, 20)
        for _, warmth in ipairs(widget.sched_warmths) do widget:setWarmth(warmth) end
        assert.same({ 22, 18, 12, 6, 5 }, native_writes)
        assert.same({ true, false, false, false, false }, night_modes)
        assert.same({ 1090, 75, 50, 25, 20 }, widget.sched_warmths)
    end)

    it("does not overshoot the actual hardware level of a flagged endpoint", function()
        local widget = schedule(24, 0, 1090)
        for _, warmth in ipairs(widget.sched_warmths) do widget:setWarmth(warmth) end
        assert.same({ 0, 6, 12, 18, 22 }, native_writes)
        assert.same({ false, false, false, false, true }, night_modes)
        assert.same({ 0, 25, 50, 75, 1090 }, widget.sched_warmths)
    end)

    it("preserves the old filtering when only night-mode control is enabled", function()
        local widget = schedule(24, 1090, 20, true, 0, 1, false)
        for _, warmth in ipairs(widget.sched_warmths) do widget:setWarmth(warmth) end
        assert.same({}, native_writes)
        assert.same({ true, false, false, false, false }, night_modes)
        assert.same({ 1090, 75, 50, 25, 20 }, widget.sched_warmths)
    end)

    it("also preserves plain percentage scheduling when warmth control is disabled", function()
        local widget = schedule(24, 90, 20, true, 0, 1, false)
        for _, warmth in ipairs(widget.sched_warmths) do widget:setWarmth(warmth) end
        assert.same({}, native_writes)
        assert.same({ false, false, false, false, false }, night_modes)
        assert.same({ 90, 75, 50, 25, 20 }, widget.sched_warmths)
        assert.is_true(math.abs(widget.sched_times_s[2] - (3600 / 70) * 15) < 1e-9)
    end)
end)
