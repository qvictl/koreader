-- Real generic/Android power drivers and gesture conversion; JNI is synthetic.
describe("Android warmth scale", function()
    local Device, BasePowerD, LuaSettings
    local original_settings, original_android, original_scale, original_powerd, original_caps
    local driver, native, writes, standalone, has_warmth

    setup(function()
        require("commonrequire")
        Device = require("device")
        BasePowerD = require("device/generic/powerd")
        LuaSettings = require("luasettings")
    end)

    before_each(function()
        original_settings = _G.G_reader_settings
        original_android = package.loaded.android
        original_scale = rawget(BasePowerD, "warmth_scale")
        original_powerd = Device.powerd
        original_caps = { rawget(Device, "hasFrontlight"), rawget(Device, "hasNaturalLight") }
        _G.G_reader_settings = LuaSettings:wrap({})
        standalone, has_warmth = false, true
        writes = {}
        Device.hasFrontlight = function() return true end
        Device.hasNaturalLight = function() return has_warmth end
    end)

    after_each(function()
        _G.G_reader_settings = original_settings
        package.loaded.android = original_android
        BasePowerD.warmth_scale = original_scale
        Device.powerd = original_powerd
        Device.hasFrontlight, Device.hasNaturalLight = original_caps[1], original_caps[2]
    end)

    local function newDriver(maximum, initial, saved)
        native = { warmth = initial, brightness = 128, warmth_reads = 0 }
        _G.G_reader_settings:saveSetting("frontlight_warmth", saved)
        package.loaded.android = {
            getScreenMinBrightness = function() return 0 end,
            getScreenMaxBrightness = function() return 255 end,
            getScreenBrightness = function() return native.brightness end,
            setScreenBrightness = function(value) native.brightness = value end,
            getScreenMinWarmth = function() return 0 end,
            getScreenMaxWarmth = function() return maximum end,
            getScreenWarmth = function()
                native.warmth_reads = native.warmth_reads + 1
                return native.warmth
            end,
            setScreenWarmth = function(value)
                assert.is_true(value >= 0 and value <= maximum)
                assert.equals(math.floor(value), value)
                native.warmth = value
                writes[#writes + 1] = value
            end,
            enableFrontlightSwitch = function() end,
            hasStandaloneWarmth = function() return standalone end,
        }
        local AndroidPowerD = dofile("frontend/device/android/powerd.lua")
        driver = AndroidPowerD:new{ device = Device, stateChanged = function() end }
        Device.powerd = driver
        return driver
    end

    local function listener()
        local Listener = dofile("frontend/device/devicelistener.lua")
        return Listener:new{ onShowWarmth = function() end }
    end

    for _, maximum in ipairs({ 10, 24, 100, 255 }) do
        it("reads native endpoints as public percentages for range " .. maximum, function()
            newDriver(maximum, maximum)
            assert.equals(100, driver:frontlightWarmth())
            native.warmth = 0
            assert.equals(0, driver:frontlightWarmthHW())
            assert.equals(0, #writes)
        end)

        it("restores standalone warmth using the native range " .. maximum, function()
            standalone = true
            newDriver(maximum, 0)
            driver:setWarmth(75)
            local expected = driver:toNativeWarmth(75)
            assert.equals(expected, native.warmth)
            assert.is_true(driver:turnOffFrontlight())
            assert.equals(0, native.warmth)
            assert.equals(75, driver:frontlightWarmth())
            assert.is_true(driver:turnOnFrontlight())
            assert.equals(expected, native.warmth)
            assert.equals(75, driver:frontlightWarmth())
            assert.same({ expected, 0, expected }, writes)
        end)

        it("clamps native gesture targets to range " .. maximum, function()
            newDriver(maximum, 0)
            local controller = listener()
            controller:onChangeFlWarmth(maximum * 2, 1)
            assert.equals(maximum, native.warmth)
            assert.equals(100, driver:frontlightWarmth())
            controller:onChangeFlWarmth(maximum * 2, -1)
            assert.equals(0, native.warmth)
            assert.equals(0, driver:frontlightWarmth())
        end)
    end

    it("converts a live Android dialog read into the public cache domain", function()
        newDriver(255, 128)
        assert.equals(50, driver:frontlightWarmth())
        native.warmth = 204
        -- Same boundary used by Device:_showLightDialog after Android accepts it.
        driver.fl_warmth = driver:frontlightWarmthHW()
        assert.equals(80, driver:frontlightWarmth())
        listener():onChangeFlWarmth(51, 1)
        assert.equals(255, native.warmth)
    end)

    it("keeps saved settings in percentages and writes them once on startup", function()
        newDriver(255, 0, 80)
        assert.same({ 204 }, writes)
        assert.equals(80, driver:frontlightWarmth())
        assert.equals(80, _G.G_reader_settings:readSetting("frontlight_warmth"))
    end)

    it("allows a real full-distance swipe to reach the 255-step endpoint", function()
        newDriver(255, 0)
        local controller = listener()
        local gesture = { ges = "two_finger_swipe", direction = "east", distance = Device.screen:getWidth() }
        controller:onIncreaseFlWarmth(gesture)
        assert.equals(128, native.warmth)
        controller:onIncreaseFlWarmth(gesture)
        assert.equals(255, native.warmth)
        controller:onDecreaseFlWarmth(gesture)
        assert.equals(128, native.warmth)
    end)

    it("keeps non-standalone warmth unchanged during light off/on", function()
        newDriver(255, 0)
        driver:setWarmth(80)
        driver:turnOffFrontlight()
        driver:turnOnFrontlight()
        assert.same({ 204 }, writes)
        assert.equals(80, driver:frontlightWarmth())
    end)

    it("does not read or write warmth on a device without natural light", function()
        has_warmth = false
        newDriver(255, 0, 80)
        assert.equals(0, driver:frontlightWarmth())
        assert.is_false(driver:setWarmth(80))
        assert.is_true(listener():onChangeFlWarmth(255, 1))
        assert.same({}, writes)
        assert.equals(0, native.warmth_reads)
    end)
end)
