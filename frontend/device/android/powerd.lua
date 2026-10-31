local BasePowerD = require("device/generic/powerd")
local _, android = pcall(require, "android")

local AndroidPowerD = BasePowerD:new{
    fl_min = 0,
    fl_max = 100,
}

function AndroidPowerD:frontlightIntensityHW()
    return math.floor(android.getScreenBrightness() / self.bright_diff * self.fl_max)
end

function AndroidPowerD:setIntensityHW(intensity)
    -- If the frontlight switch was off, turn it on.
    android.enableFrontlightSwitch()

    self.fl_intensity = intensity
    android.setScreenBrightness(math.floor(intensity * self.bright_diff / self.fl_max))
    self:_decideFrontlightState()
end

function AndroidPowerD:init()
    local min_bright = android.getScreenMinBrightness()
    self.bright_diff = android.getScreenMaxBrightness() - min_bright

    -- if necessary scale fl_min:
    --    do not use fl_min==0 if getScreenMinBrightness!=0,
    --    because intenstiy==0 would mean to use system intensity
    if min_bright ~= self.fl_min then
        self.fl_min = math.ceil(min_bright * self.fl_max / self.bright_diff)
    end

    if self.device:hasNaturalLight() then
        self.fl_warmth_min = android.getScreenMinWarmth()
        self.fl_warmth_max = android.getScreenMaxWarmth()

        -- BasePowerD only sets warmth_scale after init() returns, c.f. KoboPowerD:init.
        self.warmth_scale = 100 / self.fl_warmth_max

        local warmth = G_reader_settings:readSetting("frontlight_warmth")
        if warmth then
            self.fl_warmth = warmth
            self:setWarmth(warmth, true)
        end
    end
end

function AndroidPowerD:setWarmthHW(warmth)
    android.setScreenWarmth(warmth)
end

function AndroidPowerD:frontlightWarmthHW()
    -- Android returns native units; the public cache stores percentages.
    return self:fromNativeWarmth(android.getScreenWarmth())
end

function AndroidPowerD:getCapacityHW()
    return android.getBatteryLevel()
end

function AndroidPowerD:isChargingHW()
    return android.isCharging()
end

function AndroidPowerD:turnOffFrontlightHW()
    if not self:isFrontlightOnHW() then
        return
    end
    android.setScreenBrightness(self.fl_min)

    if android.hasStandaloneWarmth() then
        android.setScreenWarmth(self.fl_warmth_min)
    end
end

function AndroidPowerD:turnOnFrontlightHW(done_callback)
    if self:isFrontlightOn() and self:isFrontlightOnHW() then
        return
    end
    -- on devices with a software frontlight switch (e.g Tolinos), enable it
    android.enableFrontlightSwitch()

    android.setScreenBrightness(math.floor(self.fl_intensity * self.bright_diff / self.fl_max))

    if android.hasStandaloneWarmth() then
        android.setScreenWarmth(self:toNativeWarmth(self.fl_warmth))
    end
    return false
end

return AndroidPowerD
