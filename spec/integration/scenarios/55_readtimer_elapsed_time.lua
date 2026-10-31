-- Real timer widgets, lifecycle and task queue; only the timer's elapsed clock is synthetic.
return {
    name = "Read timer counts elapsed standby time and survives view changes",
    timeout = 45,
    settings = { language = "en" },
    run = function(T)
        local UIManager = require("ui/uimanager")
        local Event = require("ui/event")
        local Geom = require("ui/geometry")
        local TouchMenu = require("ui/widget/touchmenu")
        local WidgetContainer = require("ui/widget/container/widgetcontainer")
        local DataStorage = require("datastorage")
        local ffiUtil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local time = require("ui/time")
        local _ = require("gettext")
        local fm = T:fileManager()
        local plugin = assert(fm.readtimer, "ReadTimer must be loaded in FileManager")
        assert(not plugin:scheduled(), "private profile must not have an existing timer")
        local class = getmetatable(plugin)
        local saved = { now = rawget(class, "now"), restore = class.restore_scheduled_time,
            interval = class.restore_last_interval_time, settings = G_reader_settings:readSetting("readtimer") }
        local elapsed, events = time.s(100000), 0
        local instances, observer, menu = { plugin }
        local function alarmCount(timer)
            local count = 0
            for _, task in ipairs(UIManager._task_queue) do
                if task.action == timer.alarm_callback then count = count + 1 end
            end
            return count
        end
        local function tapButton(root, text)
            T:repaint()
            local button = T:findWidget(root, function(w) return w.text == text and w.onTapSelectButton end)
            T:tapWidget(button, text)
        end
        local function closeAboveManager()
            while T:topWidget() and T:topWidget() ~= T:fileManager() and T:topWidget() ~= T:reader() do
                UIManager:close(T:topWidget())
            end
        end
        local ok, err = pcall(function()
            T:run(function()
                class.now = function() return elapsed end
                -- Fresh-profile migrations run before scenarios and may rewrite
                -- legacy timer settings; configure this private fixture afterward.
                local settings = { remain_time_hours = 0, remain_time_minutes = 15,
                    snooze_minutes = 3, show_on_expiry = "message" }
                plugin.settings = settings
                G_reader_settings:saveSetting("readtimer", settings)
                observer = WidgetContainer:new{ onReadTimerExpired = function() events = events + 1 end }
                UIManager:show(observer)
                local items = {}
                plugin:addToMainMenu(items)
                menu = TouchMenu:new{ width = T.screen_w, tab_item_table = {
                    { icon = "clock", items.read_timer },
                } }
                UIManager:show(menu)
            end)
            T:repaint()
            local interval_item = T:findWidget(menu, function(w) return w.item and w.item.text == _("Set interval") end)
            if not interval_item then
                local timer_item = T:findWidget(menu, function(w) return w.item and w.item.sub_item_table end)
                T:tapWidget(timer_item, "open the real read-timer submenu")
                T:repaint()
                interval_item = T:findWidget(menu, function(w) return w.item and w.item.text == _("Set interval") end)
            end
            T:tapWidget(interval_item, "open the real interval picker")
            tapButton(T:topWidget(), _("Start timer"))
            T:check(plugin:scheduled(), "the picker starts the actual plugin timer")
            T:check(plugin:remaining() > 895 and plugin:remaining() <= 900,
                "the selected interval is fifteen minutes")
            T:run(function()
                -- Keep the observer alive while dismissing the ordinary start notice/menu.
                while T:topWidget() and T:topWidget() ~= observer do UIManager:close(T:topWidget()) end
            end)
            local deadline = plugin.time
            T:run(function()
                elapsed = elapsed + time.s(480)
                UIManager.event_hook:execute("InputEvent")
                UIManager.event_hook:execute("InputEvent")
            end)
            T:eq(plugin:remaining(), 420, "eight elapsed minutes count despite no UI-clock advance")
            T:eq(plugin.time, deadline, "input reconciliation does not postpone the deadline")
            T:eq(alarmCount(plugin), 1, "repeated input keeps exactly one alarm task")
            T:eq(events, 0, "the unfinished interval emits no expiry")

            T:run(function()
                elapsed = elapsed + time.s(421)
                UIManager.event_hook:execute("InputEvent")
            end)
            T:waitUntil(function() return events == 1 end, 5, "queued expiry after overdue input")
            T:eq(events, 1, "overdue input emits the actual expiry event without Resume")
            T:check(not plugin:scheduled(), "the expired interval is stopped before showing its choices")
            tapButton(T:topWidget(), "+3 min")
            T:eq(plugin:remaining(), 180, "the real snooze button starts the configured three minutes")
            T:run(function()
                elapsed = elapsed + time.s(181)
                UIManager.event_hook:execute("InputEvent")
            end)
            T:waitUntil(function() return events == 2 end, 5, "queued snooze expiry after input")
            T:eq(events, 2, "the snoozed interval expires once")
            tapButton(T:topWidget(), _("Repeat"))
            T:eq(plugin:remaining(), 900, "repeat retains the original fifteen-minute interval")

            T:run(function()
                plugin.settings.show_on_expiry = "nothing"
                plugin.settings.auto_reschedule_interval = true
                elapsed = elapsed + time.s(901)
                plugin:onResume()
            end)
            T:eq(events, 3, "overdue resume emits one expiry")
            T:eq(plugin:remaining(), 900, "resume does not cancel the newly repeated interval")
            T:eq(alarmCount(plugin), 1, "the repeated interval has exactly one queued alarm")
            deadline = plugin.time
            T:run(function()
                elapsed = elapsed + time.s(120)
                UIManager:close(observer)
                closeAboveManager()
            end)

            local directory = DataStorage:getDataDir() .. "/it-readtimer-elapsed"
            local book = directory .. "/reading.epub"
            assert(not lfs.attributes(directory), "private reading fixture must be new")
            assert(lfs.mkdir(directory))
            assert(not ffiUtil.copyFile(T:fixture("books/en.epub"), book))
            local ui = T:openBook(book)
            local reader_timer = assert(ui.readtimer)
            instances[#instances + 1] = reader_timer
            T:eq(reader_timer.time, deadline, "opening a book transfers the same elapsed deadline")
            T:eq(reader_timer:remaining(), 780, "view transfer retains elapsed time")
            T:eq(alarmCount(plugin), 0, "the old file-manager timer has no alarm task")
            T:check(plugin._closed, "the old timer instance is marked closed")
            local page = ui:getCurrentPage()
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return ui:getCurrentPage() == page + 1 end, 5, "ordinary page turning works")
            T:closeBook()
            local current = assert(T:fileManager().readtimer)
            instances[#instances + 1] = current
            T:eq(current.time, deadline, "closing the book transfers the same deadline back")
            T:eq(current:remaining(), 780, "the timer continues across both view transitions")
            T:eq(alarmCount(reader_timer), 0, "the closed reader's alarm is removed")
            T:eq(alarmCount(current), 1, "only the current view keeps the alarm task")
            T:run(function() current:unschedule() end)
            ui = T:openBook(book)
            instances[#instances + 1] = assert(ui.readtimer)
            T:eq(ui:getCurrentPage(), page + 1, "timer testing does not lose native reading progress")
            T:check(not ui.readtimer:scheduled(), "a stopped timer is not resurrected on the next view")
            local batch_timer = ui.readtimer
            local batch_page = ui:getCurrentPage()
            T:run(function()
                batch_timer.settings.show_on_expiry = "message"
                batch_timer.settings.auto_reschedule_interval = false
                batch_timer.last_interval_time = 60
                batch_timer:rescheduleIn(60)
                elapsed = elapsed + time.s(61)
                -- Same ordering as UIManager:handleInput: hook, then this batch's tap.
                UIManager.event_hook:execute("InputEvent")
                UIManager:handleInputEvent(Event:new("Gesture", {
                    ges = "tap", time = time.now(),
                    pos = Geom:new{ x = math.floor(T.screen_w * 0.9),
                        y = math.floor(T.screen_h * 0.5), w = 0, h = 0 },
                }))
            end)
            T:eq(ui:getCurrentPage(), batch_page + 1, "the wake-up batch tap reaches the original reader")
            T:waitUntil(function() return not batch_timer:scheduled() end, 5, "deferred expiry after input dispatch")
            T:check(T:topWidget() ~= ui and T:topWidget().choice1_callback,
                "the expiry popup survives the same batch's page-turn tap")
            tapButton(T:topWidget(), _("Done"))
            T:eq(alarmCount(batch_timer), 0, "dismissing the deferred expiry leaves no alarm task")
            T:closeBook()
            instances[#instances + 1] = assert(T:fileManager().readtimer)
            -- Retain private input through any background-worker/process teardown.
        end)
        local tasks_ok, tasks_err = pcall(function()
            T:run(function()
                -- A failed open/close may have installed a new instance before
                -- the scenario could record it. Include both live owners too.
                for _, owner in pairs({ reader = T:reader(), manager = T:fileManager() }) do
                    if owner.readtimer then instances[#instances + 1] = owner.readtimer end
                end
                local failures = {}
                for _, timer in ipairs(instances) do
                    local stopped, stop_err = pcall(timer.unschedule, timer)
                    if not stopped then failures[#failures + 1] = tostring(stop_err) end
                end
                class.restore_scheduled_time, class.restore_last_interval_time = nil, nil
                if #failures > 0 then error(table.concat(failures, "\n")) end
            end)
        end)
        -- Restore the timer clock before independent reader/widget cleanup.
        class.now = saved.now
        local reader_ok, reader_err = pcall(function() if T:reader() then T:closeBook() end end)
        local widgets_ok, widgets_err = pcall(function() T:run(closeAboveManager) end)
        class.restore_scheduled_time, class.restore_last_interval_time = saved.restore, saved.interval
        for _, timer in ipairs(instances) do timer.settings = saved.settings or {} end
        if T:fileManager() and T:fileManager().readtimer then
            T:fileManager().readtimer.settings = saved.settings or {}
        end
        G_reader_settings:saveSetting("readtimer", saved.settings)
        local errors = {}
        local function describe(e) return tostring(type(e) == "table" and e.msg or e) end
        if not ok then errors[#errors + 1] = "scenario: " .. describe(err) end
        if not tasks_ok then errors[#errors + 1] = "tasks: " .. describe(tasks_err) end
        if not reader_ok then errors[#errors + 1] = "reader: " .. describe(reader_err) end
        if not widgets_ok then errors[#errors + 1] = "widgets: " .. describe(widgets_err) end
        if #errors > 0 then error(table.concat(errors, "\n")) end
        T:check(T:topWidget() == T:fileManager(), "cleanup leaves the current file manager usable")
    end,
}
