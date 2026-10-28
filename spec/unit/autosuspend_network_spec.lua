-- AutoSuspend and network connection attempts: while connecting, the next standby check
-- is postponed by 60 s (NetworkMgr's connectivity check gives up after 45 s); if the
-- attempt fails, no NetworkConnected / NetworkDisconnected event follows, so that check
-- is what re-engages standby. It was scheduled with time.s(60) (an fts value, 60e6)
-- where _start_standby takes seconds: ~694 days, i.e. standby stayed off for good after
-- a failed connection attempt (until the next suspend / resume).
describe("AutoSuspend standby around network connection attempts", function()
    local Device, UIManager, NetworkMgr, time
    local scheduled, prevent, allow
    local orig = {}
    local orig_standby_timeout
    local wifi_on, now

    setup(function()
        require("commonrequire")
        disable_plugins()
        Device = require("device")
        UIManager = require("ui/uimanager")
        NetworkMgr = require("ui/network/manager")
        time = require("ui/time")
        for _, k in ipairs{"canSuspend", "canStandby", "canPowerOff"} do orig[k] = Device[k] end
        for _, k in ipairs{"scheduleIn", "unschedule", "preventStandby", "allowStandby", "getElapsedTimeSinceBoot"} do
            orig["UI" .. k] = UIManager[k]
        end
        orig.getWifiState = NetworkMgr.getWifiState
        Device.canSuspend = function() return true end
        Device.canStandby = function() return true end
        Device.canPowerOff = function() return false end
        UIManager.scheduleIn = function(_, delay, fn) table.insert(scheduled, { delay = delay, fn = fn }) end
        UIManager.unschedule = function(_, fn)
            for i = #scheduled, 1, -1 do
                if scheduled[i].fn == fn then table.remove(scheduled, i) end
            end
        end
        UIManager.preventStandby = function() prevent = prevent + 1 end
        UIManager.allowStandby = function() allow = allow + 1 end
        UIManager.getElapsedTimeSinceBoot = function() return now end
        NetworkMgr.getWifiState = function() return wifi_on end
        orig_standby_timeout = G_reader_settings:readSetting("auto_standby_timeout_seconds")
        G_reader_settings:saveSetting("auto_standby_timeout_seconds", 5)
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
        G_reader_settings:saveSetting("auto_standby_timeout_seconds", orig_standby_timeout)
    end)

    before_each(function()
        scheduled, prevent, allow = {}, 0, 0
        wifi_on = false
        now = time.s(1000)
    end)

    it("re-checks standby 60 seconds after a connection attempt starts", function()
        local AutoSuspend = dofile("plugins/autosuspend.koplugin/main.lua")
        local as = AutoSuspend:new{}
        wifi_on = true
        as:onNetworkConnecting()
        local delays = {}
        for _, s in ipairs(scheduled) do
            if s.fn == as.standby_task then table.insert(delays, s.delay) end
        end
        assert.are.same({ 60 }, delays)
        -- The attempt failed (Wi-Fi off again, no event, no input): 60 s later, the check
        -- finds the usual 5 s timeout long past, and allows standby.
        wifi_on = false
        scheduled, allow = {}, 0
        now = now + time.s(60)
        as:standby_task()
        assert.are.equal(1, allow)
        for _, s in ipairs(scheduled) do
            assert.are_not.equal(as.standby_task, s.fn)
        end
        as:onCloseWidget()
    end)
end)
