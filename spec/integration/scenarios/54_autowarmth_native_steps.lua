-- Real activation menu and UI task queue; solar time and light hardware are synthetic.
return {
    name = "AutoWarmth schedules reachable native steps without changing night-flag ramps",
    timeout = 45,
    settings = { language = "en", autowarmth_activate = 0 },
    run = function(T)
        local Device = require("device")
        local BasePowerD = require("device/generic/powerd")
        local UIManager = require("ui/uimanager")
        local TouchMenu = require("ui/widget/touchmenu")
        local WidgetContainer = require("ui/widget/container/widgetcontainer")
        local DataStorage = require("datastorage")
        local lfs = require("libs/libkoreader-lfs")
        local ffiUtil = require("ffi/util")
        local _ = require("gettext")
        local fm = T:fileManager()
        local saved = { powerd = Device.powerd, natural = rawget(Device, "hasNaturalLight"),
            path = package.path, settings = {}, sun = {} }
        local setting_keys = { "autowarmth_activate", "autowarmth_timezone" }
        local sun_keys = { "setPosition", "setAdvanced", "setDate", "calculateTimes", "getTimeInSec", "getTimezoneOffset", "date" }
        for _, key in ipairs(setting_keys) do saved.settings[key] = G_reader_settings:readSetting(key) end
        local SunTime, plugin, menu, observer
        local clock_s, applied, events = 0, {}, 0
        local restored = false
        local function ownedTasks()
            local count = 0
            if plugin then
                for _, task in ipairs(UIManager._task_queue) do
                    if task.action == plugin.scheduleNextWarmthChange or task.action == plugin.scheduleMidnightUpdate
                        or task.action == plugin.setWarmth or task.action == plugin.setFrontlight then count = count + 1 end
                end
            end
            return count
        end
        local function restoreBoundaries()
            if restored then return end
            Device.powerd, Device.hasNaturalLight = saved.powerd, saved.natural
            if SunTime then for _, key in ipairs(sun_keys) do SunTime[key] = saved.sun[key] end end
            package.path = saved.path
            for _, key in ipairs(setting_keys) do G_reader_settings:saveSetting(key, saved.settings[key]) end
            restored = true
        end
        local function applyQueuedStep(index)
            local before = #applied
            T:run(function()
                clock_s = plugin.sched_times_s[index]
                -- Advance only the synthetic solar clock, then dispatch the real
                -- callback through UIManager instead of waiting hours of wall time.
                UIManager:unschedule(plugin.scheduleNextWarmthChange)
                UIManager:nextTick(plugin.scheduleNextWarmthChange, plugin, false)
            end)
            T:waitUntil(function() return #applied > before end, 5, "queued warmth callback reaches the synthetic driver")
        end
        local ok, err = pcall(function()
            T:run(function()
                package.path = "plugins/autowarmth.koplugin/?.lua;" .. package.path
                SunTime = require("suntime")
                for _, key in ipairs(sun_keys) do saved.sun[key] = rawget(SunTime, key) end
                for _, key in ipairs({ "setPosition", "setAdvanced", "setDate", "calculateTimes" }) do
                    SunTime[key] = function() end
                end
                SunTime.getTimezoneOffset = function() return 0 end
                SunTime.getTimeInSec = function(_, hours)
                    return type(hours) == "number" and hours * 3600 or clock_s
                end
                SunTime.date = os.date("*t")
                Device.hasNaturalLight = function() return true end
                Device.powerd = setmetatable({
                    device = Device, fl_warmth_max = 24, warmth_scale = 100 / 24, fl_warmth = -1,
                    setWarmthHW = function(_, value) applied[#applied + 1] = value end,
                    stateChanged = function() end,
                }, { __index = BasePowerD })
                local AutoWarmth = dofile("plugins/autowarmth.koplugin/main.lua")
                plugin = setmetatable({
                    activate = 0, easy_mode = false, location = "", latitude = 0, longitude = 0,
                    timezone = 0, altitude = 0, scheduler_times = { 0, 1 }, warmth = { 100, 0 },
                    control_warmth = true, control_nightmode = false, fl_off_during_day = false,
                }, { __index = AutoWarmth })
                observer = WidgetContainer:new{
                    onAutoWarmthActivated = function() events = events + 1 end,
                }
                UIManager:show(observer)
                local tab = plugin:getActivateMenu()
                tab.icon = "light"
                menu = TouchMenu:new{ width = T.screen_w, tab_item_table = { tab } }
                UIManager:show(menu)
            end)
            T:repaint()
            local item = T:findWidget(menu, function(w)
                return w.item and w.item.text == _("According to the fixed schedule")
            end)
            T:tapWidget(item, "activate the actual fixed-schedule menu entry")
            T:eq(plugin.activate, 2, "real menu callback enables the fixed schedule")
            T:eq(G_reader_settings:readSetting("autowarmth_activate"), 2, "activation uses the normal preference")
            T:eq(#plugin.sched_warmths, 25, "24-step range includes every reachable level exactly once")
            T:eq(applied[1], 24, "initial callback uses the real generic native conversion")
            T:check(ownedTasks() >= 2, "real midnight and next-step tasks are queued")
            for index = 2, #plugin.sched_warmths do
                applyQueuedStep(index)
                T:eq(applied[#applied], 25 - index, "queued callback visits descending native level " .. (25 - index))
            end
            T:eq(#applied, 25, "the endpoint has no duplicate native write")
            T:eq(events, 25, "real activation events accompany the generated updates")
            T:eq(plugin.sched_times_s[1], 0, "start anchor timing is unchanged")
            T:eq(plugin.sched_times_s[#plugin.sched_times_s], 3600, "end anchor timing is unchanged")
            T:run(function() plugin:_onSuspend() end)
            T:eq(ownedTasks(), 0, "suspend cancels the private schedule callbacks")

            T:run(function()
                clock_s, applied = 0, {}
                Device.powerd.fl_warmth = -1
                plugin.warmth = { 1090, 20 } -- valid 90% plus night flag; do not change the actual screen's night mode
                plugin:scheduleMidnightUpdate()
            end)
            T:eq(#plugin.sched_warmths, 5, "flagged anchors keep the existing interpolation policy")
            T:eq(applied[1], 22, "production setWarmth masks the flagged 90-percent anchor")
            applyQueuedStep(2)
            T:eq(applied[2], 18, "the next flagged-ramp update does not reverse upward to level 23")
            T:run(function()
                plugin:_onSuspend()
                while T:topWidget() and T:topWidget() ~= fm do UIManager:close(T:topWidget()) end
            end)
            T:eq(ownedTasks(), 0, "all private tasks are gone before restoring the power driver")
            restoreBoundaries()
            T:check(Device.powerd == saved.powerd, "the emulator's original power driver is restored")

            local directory = DataStorage:getDataDir() .. "/it-autowarmth-native"
            local book = directory .. "/reading.epub"
            assert(not lfs.attributes(directory), "private reading fixture must be new")
            assert(lfs.mkdir(directory))
            assert(not ffiUtil.copyFile(T:fixture("books/en.epub"), book))
            local ui = T:openBook(book)
            local page = ui:getCurrentPage()
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return ui:getCurrentPage() == page + 1 end, 5, "ordinary reading remains usable")
            T:closeBook()
            ui = T:openBook(book)
            T:eq(ui:getCurrentPage(), page + 1, "normal close and reopen preserve reading progress")
            T:closeBook()
            -- Retain private inputs through background worker/process teardown.
        end)
        local tasks_ok, tasks_err = pcall(function()
            T:run(function()
                if plugin then plugin:_onSuspend() end
            end)
        end)
        -- Restore hardware/time/settings before independently protected reader
        -- cleanup; never substitute closing its window for ReaderUI:onClose().
        restoreBoundaries()
        local reader_ok, reader_err = pcall(function() if T:reader() then T:closeBook() end end)
        local cleanup_ok, cleanup_err = pcall(function()
            T:run(function()
                while T:topWidget() and T:topWidget() ~= T:fileManager() and T:topWidget() ~= T:reader() do
                    UIManager:close(T:topWidget())
                end
            end)
        end)
        local errors = {}
        local function describe(e) return tostring(type(e) == "table" and e.msg or e) end
        if not ok then errors[#errors + 1] = "scenario: " .. describe(err) end
        if not tasks_ok then errors[#errors + 1] = "tasks: " .. describe(tasks_err) end
        if not cleanup_ok then errors[#errors + 1] = "cleanup: " .. describe(cleanup_err) end
        if not reader_ok then errors[#errors + 1] = "reader: " .. describe(reader_err) end
        if #errors > 0 then error(table.concat(errors, "\n")) end
        T:check(T:fileManager() and T:topWidget() == T:fileManager(), "cleanup leaves the current file manager usable")
    end,
}
