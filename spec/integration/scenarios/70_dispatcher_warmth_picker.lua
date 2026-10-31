-- Native light hardware is synthetic; menus, numeric input, settings and events are real.
return {
    name = "Warmth actions use the native picker range and preserve saved values",
    timeout = 60,
    settings = { language = "en", notification_sources_to_show_mask = 0 },
    run = function(T)
        local Device = require("device")
        local BasePowerD = require("device/generic/powerd")
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        local Notification = require("ui/widget/notification")
        local TouchMenu = require("ui/widget/touchmenu")
        local SpinWidget = require("ui/widget/spinwidget")
        local WidgetContainer = require("ui/widget/container/widgetcontainer")
        local UIManager = require("ui/uimanager")
        local lfs = require("libs/libkoreader-lfs")
        local fm = assert(T:fileManager(), "scenario starts in FileManager")
        local saved = { powerd = Device.powerd, scale = rawget(BasePowerD, "warmth_scale"),
            frontlight = rawget(Device, "hasFrontlight"), natural = rawget(Device, "hasNaturalLight"),
            source = Notification.notify_source }
        local path = DataStorage:getSettingsDir() .. "/it-warmth-actions.lua"
        assert(not lfs.attributes(path) and not lfs.attributes(path .. ".old"), "private action settings must be absent")
        local owns_file = true
        local menu, spin, input, receiver, dispatcher, driver, native
        local location, caller = {}, {}
        local function closeWidget(widget)
            if widget and UIManager:isWidgetShown(widget) then T:run(function() UIManager:close(widget) end) end
        end
        local function tapText(widget, text)
            T:repaint()
            local button = T:findWidget(widget, function(w) return w.text == text and w.callback end)
            T:check(button, "painted button exists: " .. text)
            T:tapWidget(button, text)
        end
        local function openPicker()
            local items, entry = {}
            dispatcher:_addItem(caller, items, location, "actions", "screen")
            for _, item in ipairs(items) do
                if item.text_func and item.text_func():find("Set frontlight warmth", 1, true) then entry = item break end
            end
            T:check(entry, "warmth action is offered in the real Dispatcher menu")
            T:run(function()
                menu = TouchMenu:new{ width = T.screen_w, tab_item_table = {
                    { icon = "appbar.settings", entry },
                } }
                UIManager:show(menu)
            end)
            T:repaint()
            local item = T:findWidget(menu, function(w) return w.item and w.item.callback == entry.callback end)
            T:check(item, "warmth menu entry is painted")
            T:tapWidget(item, "Set frontlight warmth")
            spin = T:topWidget()
            T:check(getmetatable(spin) == SpinWidget, "real SpinWidget opens")
        end
        local function enterValue(value)
            T:tapWidget(spin.value_widget.text_value, "open actual numeric input")
            input = T:topWidget()
            T:check(type(input.setInputText) == "function", "numeric input opens")
            T:run(function() input:setInputText(tostring(value)) end)
            tapText(input, "OK")
            T:check(not UIManager:isWidgetShown(input), "in-range numeric input is accepted")
            input = nil
            T:eq(spin.value_widget:getValue(), value, "numeric picker keeps entered native value")
        end
        local function applyAndExecute(expected)
            tapText(spin, "Apply")
            T:check(not UIManager:isWidgetShown(spin), "Apply closes the picker")
            spin = nil
            closeWidget(menu); menu = nil
            T:eq(location.actions.set_frontlight_warmth, expected, "action stores native scalar unchanged")
            local settings = LuaSettings:open(path)
            settings:saveSetting("actions", location.actions)
            T:check(settings:flush(), "owned action settings are saved")
            location.actions = LuaSettings:open(path):readSetting("actions")
            T:eq(location.actions.set_frontlight_warmth, expected, "disk reload preserves native action value")
            T:run(function() dispatcher:execute(location.actions) end)
            T:eq(native, expected, "real Dispatcher event and power conversion reach native endpoint")
        end
        local ok, err = pcall(function()
            T:run(function()
                Device.hasFrontlight = function() return true end
                Device.hasNaturalLight = function() return true end
                local controller = dofile("frontend/device/devicelistener.lua"):new{}
                receiver = WidgetContainer:new{
                    onSetFlWarmth = function(_, value) return controller:onSetFlWarmth(value) end,
                }
                UIManager:show(receiver)
            end)
            for _, maximum in ipairs({ 255, 24 }) do
                T:run(function()
                    driver = BasePowerD:new{ device = Device, fl_min = 0, fl_max = 100,
                        fl_warmth_min = 0, fl_warmth_max = maximum,
                        frontlightWarmthHW = function() return 50 end,
                        setWarmthHW = function(_, value) native = value end,
                        stateChanged = function() end,
                    }
                    Device.powerd = driver
                    dispatcher = dofile("frontend/dispatcher.lua")
                end)
                location, caller = {}, {}
                native = driver:toNativeWarmth(50)
                openPicker()
                T:eq(spin.value_min, 0, "minimum is native zero")
                T:eq(spin.value_max, maximum, "maximum follows warmth, not brightness 100")
                T:eq(spin.value_widget:getValue(), 0, "new action defaults to native minimum")
                tapText(spin, "▼")
                T:eq(spin.value_widget:getValue(), 0, "down at minimum stays zero")
                applyAndExecute(0)

                openPicker()
                T:eq(spin.value_widget:getValue(), 0, "reopened action preserves saved zero")
                enterValue(maximum)
                tapText(spin, "▲")
                T:eq(spin.value_widget:getValue(), maximum, "up at maximum stays at native limit")
                applyAndExecute(maximum)

                caller.updated = false
                openPicker()
                T:eq(spin.value_widget:getValue(), maximum, "reopened action preserves saved maximum")
                enterValue(maximum - 1)
                tapText(spin, "Close")
                T:check(not UIManager:isWidgetShown(spin), "Close cancels the picker")
                spin = nil
                closeWidget(menu); menu = nil
                T:eq(location.actions.set_frontlight_warmth, maximum, "Cancel preserves saved action")
                T:check(not caller.updated, "Cancel does not dirty the caller")
                T:eq(native, maximum, "editing and cancelling do not change the light")
            end
        end)
        local errors = {}
        local function cleanup(callback)
            local success, reason = pcall(callback)
            if not success then errors[#errors + 1] = tostring(type(reason) == "table" and reason.msg or reason) end
        end
        cleanup(function() closeWidget(input) end)
        cleanup(function() closeWidget(spin) end)
        cleanup(function() closeWidget(menu) end)
        cleanup(function() closeWidget(receiver) end)
        Device.powerd, BasePowerD.warmth_scale = saved.powerd, saved.scale
        Device.hasFrontlight, Device.hasNaturalLight = saved.frontlight, saved.natural
        Notification.notify_source = saved.source
        cleanup(function()
            if owns_file then
                for _, file in ipairs({ path, path .. ".old" }) do
                    if lfs.attributes(file) then assert(os.remove(file)) end
                end
            end
        end)
        if not ok then table.insert(errors, 1, tostring(type(err) == "table" and err.msg or err)) end
        if #errors > 0 then error(table.concat(errors, "\n"), 0) end
        T:check(not lfs.attributes(path) and not lfs.attributes(path .. ".old"), "owned settings files are removed")
        T:repaint()
        T:check(T:topWidget() == fm, "original FileManager is topmost after all controls close")
    end,
}
