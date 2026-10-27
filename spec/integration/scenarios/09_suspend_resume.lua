-- Suspend / resume with a book open: the power button path (emulator: screensaver), and the
-- generic Device suspend hooks (Suspend/Resume events, input inhibition, memory release).
return {
    name = "Suspend / resume",
    timeout = 120,
    settings = {
        screensaver_type = "disable",
    },
    run = function(T)
        local Device = require("device")
        local UIManager = require("ui/uimanager")
        local WidgetContainer = require("ui/widget/container/widgetcontainer")
        local MemoryTuning = require("memorytuning")

        local ui = T:openBook(T:fixture("books/en.epub"))
        T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
        T:waitUntil(function() return ui:getCurrentPage() == 2 end, 5, "page 2")

        local events = {}
        local listener = WidgetContainer:new{
            name = "it_suspend_listener",
            onSuspend = function() table.insert(events, "Suspend") end,
            onResume = function() table.insert(events, "Resume") end,
        }
        T:run(function() UIManager:show(listener) end)
        local release = T:spy(MemoryTuning, "releaseMemory")

        -- Power button (emulator only: the desktop SDL device can't suspend).
        if Device:canSuspend() and UIManager.event_handlers.PowerRelease then
            T:run(function() UIManager.event_handlers.PowerRelease() end)
            T:wait(0.5)
            T:check(Device.screen_saver_mode, "power button: in screensaver mode")
            T:run(function() UIManager.event_handlers.PowerRelease() end)
            T:wait(0.5)
            T:check(not Device.screen_saver_mode, "power button again: resumed")
        else
            T:log("device can't suspend (not the emulator): skipping the power button part")
        end

        -- Generic suspend/resume hooks.
        events = {}
        local t0 = T:now()
        T:run(function() Device:_beforeSuspend() end)
        T:budget("before_suspend_ms", T:now() - t0, 3000, "ms")
        T:check(Device.input._abs_ev_handler ~= nil, "touch input inhibited while suspended")
        local released_on_suspend = false
        for _, args in ipairs(release.args) do
            if args[2] == "suspend" then released_on_suspend = true end
        end
        T:check(released_on_suspend, "memory released on suspend")
        T:wait(0.3)
        T:run(function() Device:_afterResume() end)
        T:wait(0.3)
        T:check(Device.input._abs_ev_handler == nil, "touch input restored after resume")
        T:eq(events, { "Suspend", "Resume" }, "Suspend and Resume events broadcast")
        release.restore()
        T:run(function() UIManager:close(listener) end)

        -- The book is still usable, at the same page.
        T:eq(ui:getCurrentPage(), 2, "still on page 2 after resume")
        T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
        T:waitUntil(function() return ui:getCurrentPage() == 3 end, 5, "page turn after resume")
        T:closeBook()
    end,
}
