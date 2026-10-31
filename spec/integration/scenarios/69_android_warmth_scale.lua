-- Android JNI is synthetic. The power driver, event queue and light widget are real.
return {
    name = "Android warmth uses one public/native conversion across reading and light controls",
    timeout = 45,
    settings = { language = "en" },
    run = function(T)
        local Device = require("device")
        local BasePowerD = require("device/generic/powerd")
        local Event = require("ui/event")
        local UIManager = require("ui/uimanager")
        local FrontLightWidget = require("ui/widget/frontlightwidget")
        local WidgetContainer = require("ui/widget/container/widgetcontainer")
        T:fileManager()
        local saved = { powerd = Device.powerd, android = package.loaded.android,
            scale = rawget(BasePowerD, "warmth_scale"), warmth = G_reader_settings:readSetting("frontlight_warmth"), caps = {} }
        local cap_names = { "hasFrontlight", "hasNaturalLight", "hasNaturalLightApi", "hasNaturalLightMixer" }
        for _, key in ipairs(cap_names) do saved.caps[key] = rawget(Device, key) end
        local light, receiver, driver, controller
        local native, writes = { warmth = 128, brightness = 128 }, {}
        local standalone = false
        local function closeLight()
            if light then T:run(function() UIManager:close(light) end); light = nil end
        end
        local function showLight()
            T:run(function() light = FrontLightWidget:new{}; UIManager:show(light) end)
            T:repaint()
        end
        local function change(event)
            T:run(function()
                UIManager:sendEvent(Event:new(event, {
                    ges = "two_finger_swipe", direction = "east", distance = T.screen_w,
                }))
            end)
        end
        local ok, err = pcall(function()
            T:run(function()
                Device.hasFrontlight = function() return true end
                Device.hasNaturalLight = function() return true end
                Device.hasNaturalLightApi = function() return true end
                Device.hasNaturalLightMixer = function() return false end
                G_reader_settings:delSetting("frontlight_warmth")
                package.loaded.android = {
                    getScreenMinBrightness = function() return 0 end,
                    getScreenMaxBrightness = function() return 255 end,
                    getScreenBrightness = function() return native.brightness end,
                    setScreenBrightness = function(value) native.brightness = value end,
                    getScreenMinWarmth = function() return 0 end,
                    getScreenMaxWarmth = function() return 255 end,
                    getScreenWarmth = function() return native.warmth end,
                    setScreenWarmth = function(value)
                        assert(value >= 0 and value <= 255 and math.floor(value) == value, "native warmth must be an integer in range")
                        native.warmth = value
                        writes[#writes + 1] = value
                    end,
                    enableFrontlightSwitch = function() end,
                    hasStandaloneWarmth = function() return standalone end,
                }
                local AndroidPowerD = dofile("frontend/device/android/powerd.lua")
                driver = AndroidPowerD:new{ device = Device }
                Device.powerd = driver
                controller = dofile("frontend/device/devicelistener.lua"):new{}
                receiver = WidgetContainer:new{
                    onIncreaseFlWarmth = function(_, gesture) controller:onIncreaseFlWarmth(gesture); return true end,
                    onDecreaseFlWarmth = function(_, gesture) controller:onDecreaseFlWarmth(gesture); return true end,
                }
                UIManager:show(receiver)
            end)
            T:eq(driver:frontlightWarmth(), 50, "native 128 starts as public 50 percent, not 32640")
            T:eq(#writes, 0, "reading initial hardware state does not change it")
            showLight()
            T:eq(light.nl.cur, 128, "painted light dialog displays the reachable native level")
            T:eq(light.nl_level.text, "128", "warmth number is readable in native units")
            T:eq(light.nl.max, 255, "light dialog retains the full native range")
            T:tapWidget(light.layout[5][2], "actual warmth Max button")
            T:eq(native.warmth, 255, "widget Max writes the native endpoint")
            T:eq(driver:frontlightWarmth(), 100, "widget stores public 100 percent")
            T:tapWidget(light.layout[5][1], "actual warmth Min button")
            T:eq(native.warmth, 0, "widget Min writes zero")
            closeLight()
            change("IncreaseFlWarmth")
            T:eq(native.warmth, 128, "first full-distance action passes the old native 100 clamp")
            change("IncreaseFlWarmth")
            T:eq(native.warmth, 255, "second action reaches full native warmth")
            change("DecreaseFlWarmth")
            T:eq(native.warmth, 128, "decrease uses the same native domain")
            showLight()
            T:eq(light.nl.cur, 128, "reopened widget agrees with event-driven changes")
            closeLight()

            T:run(function()
                standalone = true
                driver:setWarmth(80)
            end)
            T:eq(native.warmth, 204, "80 percent is converted once before native write")
            showLight()
            T:tapWidget(light.layout[2][2], "actual frontlight Toggle off")
            T:eq(native.warmth, 0, "standalone light off sets its native minimum")
            T:eq(driver:frontlightWarmth(), 80, "off retains the public warmth for restore")
            T:tapWidget(light.layout[2][2], "actual frontlight Toggle on")
            T:eq(native.warmth, 204, "standalone light on restores native 204, not zero")
            T:eq(driver:frontlightWarmth(), 80, "restore does not corrupt the public cache")
            closeLight()
            showLight()
            T:eq(light.nl.cur, 204, "reopening after toggle keeps consistent displayed warmth")
            closeLight()
            T:run(function() UIManager:close(receiver) end)
            receiver = nil

        end)
        -- Each cleanup is independent. Always restore hardware/module/settings
        -- boundaries, even if closing a widget fails. No temporary files are created.
        Device.powerd, package.loaded.android = saved.powerd, saved.android
        BasePowerD.warmth_scale = saved.scale
        for _, key in ipairs(cap_names) do Device[key] = saved.caps[key] end
        G_reader_settings:saveSetting("frontlight_warmth", saved.warmth)
        local errors = {}
        local function cleanup(callback)
            local clean, cleanup_err = pcall(callback)
            if not clean then errors[#errors + 1] = tostring(type(cleanup_err) == "table" and cleanup_err.msg or cleanup_err) end
        end
        cleanup(closeLight)
        cleanup(function() if receiver then T:run(function() UIManager:close(receiver) end) end end)
        if not ok then table.insert(errors, 1, tostring(type(err) == "table" and err.msg or err)) end
        if #errors > 0 then error(table.concat(errors, "\n"), 0) end
        T:check(Device.powerd == saved.powerd, "original emulator power driver is restored")
        T:repaint()
        T:check(UIManager:isWidgetShown(T:fileManager()), "the original FileManager remains displayed after close")
    end,
}
