-- The picker boundary is synthetic; Dispatcher menu/save/event code is real.
describe("Dispatcher warmth picker native range", function()
    local Device, UIManager, Notification, LuaSettings
    local saved, dispatcher, picker, location, caller, events

    setup(function()
        require("commonrequire")
        Device = require("device")
        UIManager = require("ui/uimanager")
        Notification = require("ui/widget/notification")
        LuaSettings = require("luasettings")
        require("dispatcher") -- Load normal dependencies before private module instances.
    end)

    before_each(function()
        saved = { settings = _G.G_reader_settings, powerd = Device.powerd,
            natural = rawget(Device, "hasNaturalLight"), frontlight = rawget(Device, "hasFrontlight"),
            show = rawget(UIManager, "show"), send = rawget(UIManager, "sendEvent"),
            spin = package.loaded["ui/widget/spinwidget"], source = Notification.notify_source }
        _G.G_reader_settings = LuaSettings:wrap({})
        Device.hasNaturalLight = function() return true end
        Device.hasFrontlight = function() return true end
        package.loaded["ui/widget/spinwidget"] = { new = function(_, options) return options end }
        UIManager.show = function(_, widget) picker = widget end
        events = {}
        UIManager.sendEvent = function(_, event) events[#events + 1] = event end
        picker, location, caller = nil, {}, {}
    end)

    after_each(function()
        _G.G_reader_settings, Device.powerd = saved.settings, saved.powerd
        Device.hasNaturalLight, Device.hasFrontlight = saved.natural, saved.frontlight
        UIManager.show, UIManager.sendEvent = saved.show, saved.send
        package.loaded["ui/widget/spinwidget"] = saved.spin
        Notification.notify_source = saved.source
    end)

    local function menuFor(minimum, maximum, has_warmth)
        Device.powerd = { fl_max = 100, fl_warmth_min = minimum, fl_warmth_max = maximum }
        if has_warmth == false then Device.hasNaturalLight = function() return false end end
        dispatcher = dofile("frontend/dispatcher.lua")
        local menu = {}
        dispatcher:_addItem(caller, menu, location, "actions", "screen")
        for _, item in ipairs(menu) do
            if item.text_func and item.text_func():find("Set frontlight warmth", 1, true) then return item end
        end
    end

    for _, maximum in ipairs({ 10, 24, 100, 255 }) do
        it("uses native endpoints rather than brightness for range " .. maximum, function()
            menuFor(0, maximum).callback()
            assert.equals(0, picker.value_min)
            assert.equals(maximum, picker.value_max)
            assert.equals(0, picker.value)
        end)

        it("saves and dispatches native zero for range " .. maximum, function()
            menuFor(0, maximum).callback()
            -- Exercise the endpoint exposed by the picker, not an out-of-range injection.
            picker.value = picker.value_min
            picker.callback(picker)
            assert.equals(0, location.actions.set_frontlight_warmth)
            assert.is_true(caller.updated)
            dispatcher:execute(location.actions)
            assert.equals(1, #events)
            assert.equals("onSetFlWarmth", events[1].handler)
            assert.equals(0, events[1].args[1])
        end)

        it("saves and dispatches the native maximum for range " .. maximum, function()
            menuFor(0, maximum).callback()
            picker.value = picker.value_max
            picker.callback(picker)
            assert.equals(maximum, location.actions.set_frontlight_warmth)
            dispatcher:execute(location.actions)
            assert.equals(1, #events)
            assert.equals("onSetFlWarmth", events[1].handler)
            assert.equals(maximum, events[1].args[1])
        end)
    end

    it("uses a nonzero native minimum without changing an existing saved value", function()
        location.actions = { set_frontlight_warmth = 9 }
        menuFor(2, 24).callback()
        assert.equals(2, picker.value_min)
        assert.equals(24, picker.value_max)
        assert.equals(9, picker.value)
        assert.is_nil(caller.updated)
        assert.equals(9, location.actions.set_frontlight_warmth)
    end)

    it("keeps a saved zero instead of replacing it with a default", function()
        location.actions = { set_frontlight_warmth = 0 }
        menuFor(0, 255).callback()
        assert.equals(0, picker.value)
        assert.is_nil(caller.updated)
    end)

    it("does not migrate a legacy saved out-of-range value on opening", function()
        location.actions = { set_frontlight_warmth = 100 }
        menuFor(0, 24).callback()
        assert.equals(100, picker.value)
        assert.equals(100, location.actions.set_frontlight_warmth)
        assert.is_nil(caller.updated)
        dispatcher:execute(location.actions)
        assert.equals(100, events[1].args[1])
    end)

    it("leaves brightness and incremental action bounds unchanged", function()
        menuFor(0, 24)
        local actions
        for i = 1, 20 do
            local name, value = debug.getupvalue(dispatcher.registerAction, i)
            if name == "settingsList" then actions = value; break end
        end
        assert.is_table(actions)
        assert.equals(0, actions.set_frontlight.min)
        assert.equals(100, actions.set_frontlight.max)
        assert.equals(1, actions.increase_frontlight_warmth.min)
        assert.equals(24, actions.increase_frontlight_warmth.max)
        assert.equals(1, actions.decrease_frontlight_warmth.min)
        assert.equals(24, actions.decrease_frontlight_warmth.max)
    end)

    it("does not offer warmth on a device without natural light", function()
        assert.is_nil(menuFor(0, 255, false))
        assert.is_nil(picker)
        assert.is_nil(location.actions)
    end)
end)
