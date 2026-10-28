-- luacheck: ignore 122 143
require("commonrequire")
local Device = require("device")
local Input = require("device/input")
local Screensaver = require("ui/screensaver")
local UIManager = require("ui/uimanager")

describe("Suspend lifecycle regressions", function()
    it("dispatches batched Kindle arguments in input order", function()
        local original_open = io.open
        io.open = function(path, mode)
            if path == "/proc/usid" then
                return { read = function() return "G000G1XX" end, close = function() end }
            end
            return original_open(path, mode)
        end
        local loaded, Kindle = pcall(dofile, "frontend/device/kindle/device.lua")
        io.open = original_open
        assert.is_true(loaded)
        local input = Input:new{ device = Device, input = Device.input.input }
        local device = setmetatable({ input = input }, { __index = Kindle })
        local ui = { event_handlers = {} }
        device:UIManagerReady(ui)
        device:setEventHandlers(ui)
        for event, spec in pairs{
            IntoSS = { 10000, "intoScreenSaver" }, OutOfSS = { 10001, "outofScreenSaver" },
            ReadyToSuspend = { 10031, "readyToSuspend" }, WakeupFromSuspend = { 10030, "wakeupFromSuspend" },
        } do
            local received, queued = {}, {}
            device[spec[2]] = function(_, value) received[#received + 1] = value end
            for _, value in ipairs{ 2, 4, 6 } do
                queued[#queued + 1] = input:handleKeyBoardEv{ code = spec[1], value = value, fd = 0 }
            end
            for _, name in ipairs(queued) do ui.event_handlers[name](name) end
            assert.same({ 2, 4, 6 }, received, event)
        end
    end)

    it("keeps the sleeping screen after a second suspend, then resumes normally", function()
        local previous_delay = G_reader_settings:readSetting("screensaver_delay")
        local ok, err = pcall(function()
            G_reader_settings:saveSetting("screensaver_delay", "3")
            Screensaver.ui = {}
            Screensaver.screensaver_type = "disable"
            Screensaver.show_message = false
            Screensaver.prefix = ""
            Screensaver.overlay_message = "Synthetic sleep screen"
            Screensaver.screensaver_background = "none"
            Screensaver:show()
            local widget = Screensaver.screensaver_widget
            Screensaver:close()
            widget:onResume()
            widget:onSuspend()
            fastforward_ui_events()
            assert.is_true(UIManager:isWidgetShown(widget))
            assert.is_true(Device.screen_saver_mode)
            assert.is_false(Device.screen_saver_lock)
            Screensaver:close()
            widget:onResume()
            fastforward_ui_events()
            assert.is_false(UIManager:isWidgetShown(widget))
            assert.is_false(Device.screen_saver_mode)
        end)
        UIManager:unschedule(Screensaver.close_widget)
        Screensaver:close_widget()
        Screensaver:cleanup()
        Screensaver.ui = nil
        G_reader_settings:saveSetting("screensaver_delay", previous_delay)
        if not ok then error(err, 0) end
    end)
end)
