return {
    name = "A delayed screensaver survives a second suspend",
    timeout = 30,
    settings = {
        screensaver_type = "disable",
        screensaver_show_message = true,
        screensaver_message = "Synthetic suspend regression",
        screensaver_delay = "0.1",
    },
    run = function(T)
        local Screensaver = require("ui/screensaver")
        local UIManager = require("ui/uimanager")
        local Event = require("ui/event")
        local Device = require("device")
        local ok, err = pcall(function()
            T:run(function()
                Screensaver:setup()
                Screensaver:show()
            end)
            T:repaint()
            local widget = Screensaver.screensaver_widget
            T:check(widget and widget.dimen, "screensaver is painted")
            T:run(function()
                Screensaver:close()
                UIManager:broadcastEvent(Event:new("Resume"))
                T:check(Device.screen_saver_lock, "delayed resume keeps the screensaver locked")
                UIManager:broadcastEvent(Event:new("Suspend"))
            end)
            T:wait(0.3)
            T:check(UIManager:isWidgetShown(widget), "old resume timer cannot close the screen after a second suspend")
            T:check(Device.screen_saver_mode and not Device.screen_saver_lock,
                "second suspend preserves the sleeping screensaver state")
            T:run(function()
                Screensaver:close()
                UIManager:broadcastEvent(Event:new("Resume"))
            end)
            T:waitUntil(function() return not UIManager:isWidgetShown(widget) end, 2, "second resume closes the screensaver")
            T:check(not Device.screen_saver_mode and not Device.screen_saver_lock,
                "normal resume clears both screensaver flags")
        end)
        T:run(function()
            UIManager:unschedule(Screensaver.close_widget)
            Screensaver:close_widget()
            Screensaver:cleanup()
        end)
        if not ok then error(err, 0) end
        T:run(function()
            local original_open = io.open
            io.open = function(path, mode)
                if path == "/proc/usid" then
                    return { read = function() return "G000G1XX" end, close = function() end }
                end
                return original_open(path, mode)
            end
            local loaded, Kindle = pcall(dofile, "frontend/device/kindle/device.lua")
            io.open = original_open
            if not loaded then error(Kindle) end
            local input = require("device/input"):new{ device = Device, input = Device.input.input }
            local device = setmetatable({ input = input }, { __index = Kindle })
            local handlers = { event_handlers = {} }
            device:UIManagerReady(handlers)
            device:setEventHandlers(handlers)
            for event, spec in pairs{
                IntoSS = { 10000, "intoScreenSaver" }, OutOfSS = { 10001, "outofScreenSaver" },
                ReadyToSuspend = { 10031, "readyToSuspend" }, WakeupFromSuspend = { 10030, "wakeupFromSuspend" },
            } do
                local received, queued = {}, {}
                device[spec[2]] = function(_, value) received[#received + 1] = value end
                for _, value in ipairs{ 2, 4, 6 } do
                    queued[#queued + 1] = input:handleKeyBoardEv{ code = spec[1], value = value, fd = 0 }
                end
                for _, name in ipairs(queued) do handlers.event_handlers[name](name) end
                T:eq(table.concat(received, ","), "2,4,6", event .. " arguments retain input arrival order")
            end
        end)
    end,
}
