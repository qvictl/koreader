-- luacheck: ignore 122 -- restored synthetic host-command boundary
-- Real menu, input, messages and connectivity task queue; only radio state and
-- backend requests are synthetic. No host Wi-Fi operation or external network.
return {
    name = "Async Wi-Fi restore shares the interactive connection guard",
    timeout = 45,
    settings = { language = "en", auto_restore_wifi = true, auto_disable_wifi = false },
    run = function(T)
        local Device = require("device")
        local NetworkMgr = require("ui/network/manager")
        local UIManager = require("ui/uimanager")
        local TouchMenu = require("ui/widget/touchmenu")
        local WidgetContainer = require("ui/widget/container/widgetcontainer")
        local _ = require("gettext")
        local fm = T:fileManager()
        local saved = { manager = {}, caps = {}, execute = os.execute,
            wifi = G_reader_settings:readSetting("wifi_was_on") }
        local caps = { "hasWifiToggle", "hasWifiRestore", "hasSeamlessWifiToggle", "hasWifiManager", "isKindle" }
        for key, value in pairs(NetworkMgr) do saved.manager[key] = value end
        for _, key in ipairs(caps) do saved.caps[key] = rawget(Device, key) end
        local backend = { on = false, connected = false, restores = 0, enables = 0, disables = 0 }
        local connected, disconnected = 0, 0
        local menu, observer, listener, installed
        local initial_polls, original_deadline
        local function polls()
            local result = {}
            for _, task in ipairs(UIManager._task_queue) do
                if task.action == NetworkMgr.connectivityCheck then result[#result + 1] = task end
            end
            return result
        end
        local function tapWifi()
            T:repaint()
            local item = T:findWidget(menu, function(w) return w.item and w.item.text == _("Wi-Fi connection") end)
            T:tapWidget(item, "network menu Wi-Fi connection")
        end
        local ok, err = pcall(function()
            T:check(not NetworkMgr.pending_connection and not NetworkMgr.pending_connectivity_check,
                "the private profile has no pre-existing connection attempt")
            T:run(function()
                installed = true
                os.execute = function() error("host shell execution forbidden in synthetic Wi-Fi scenario") end
                Device.hasWifiToggle = function() return true end
                Device.hasWifiRestore = function() return true end
                Device.hasSeamlessWifiToggle = function() return true end
                Device.hasWifiManager = function() return false end -- Kindle delegates suspend to its host
                Device.isKindle = function() return true end -- no host restore-script kill path
                NetworkMgr.isWifiOn = function() return backend.on end
                NetworkMgr.isConnected = function() return backend.connected end
                NetworkMgr.getCurrentNetwork = function() return { ssid = "synthetic-restore" } end
                NetworkMgr.restoreWifiAsync = function()
                    backend.restores = backend.restores + 1
                    return backend.result -- nil is the existing accepted async contract
                end
                NetworkMgr.turnOnWifi = function(_, callback)
                    backend.enables = backend.enables + 1
                    if callback then callback() end
                    return true
                end
                NetworkMgr.turnOffWifi = function(_, callback)
                    backend.disables = backend.disables + 1
                    backend.on, backend.connected = false, false
                    if callback then callback() end
                end
                NetworkMgr.pending_connection = false
                NetworkMgr.wifi_was_on = true
                G_reader_settings:makeTrue("wifi_was_on")
                listener = dofile("frontend/ui/network/networklistener.lua"):new{}
                observer = WidgetContainer:new{
                    onNetworkConnected = function() connected = connected + 1 end,
                    onNetworkDisconnected = function() disconnected = disconnected + 1 end,
                }
                UIManager:show(observer)
                menu = TouchMenu:new{
                    width = T.screen_w,
                    tab_item_table = { { icon = "network", NetworkMgr:getWifiToggleMenuTable() } },
                }
                UIManager:show(menu)
                listener:onResume()
                local first_poll = polls()[1]
                listener:onResume() -- same frame: neither restart nor postpone the attempt
                initial_polls = #polls()
                original_deadline = polls()[1] == first_poll
            end)
            T:eq(backend.restores, 1, "duplicate resume does not restart the backend")
            T:eq(initial_polls, 1, "one actual connectivity task is queued")
            T:check(original_deadline, "duplicate resume retains the original polling deadline")
            T:check(NetworkMgr.pending_connection, "restore owns the pending connection guard")
            tapWifi()
            local busy = T:waitUntil(function()
                local top = T:topWidget()
                return top and top.text == _("A previous connection attempt is still ongoing, this one will be ignored!") and top
            end, 5, "real busy notice after tapping Wi-Fi during restore")
            T:eq(backend.enables, 0, "interactive input never starts a competing backend request")
            T:eq(backend.restores, 1, "the original restore remains the only radio request")
            T:eq(#polls(), 1, "busy input does not add a second polling loop")
            T:repaint()
            T:tapWidget(busy, "dismiss the busy notice")
            T:check(T:topWidget() == menu, "dismissing busy returns to the usable network menu")
            T:eq(connected, 0, "accepted restore is not mistaken for completed connectivity")
            T:run(function()
                NetworkMgr.lease_ssid = "before-suspend"
                listener:onSuspend() -- radio is still off when the restore is interrupted
            end)
            T:check(not NetworkMgr.pending_restore and not NetworkMgr.pending_connection,
                "suspend retires the interrupted restore ownership")
            T:eq(#polls(), 0, "suspend removes stale connectivity polling")
            T:eq(backend.disables, 0, "host-managed suspend does not add a radio shutdown request")
            T:eq(disconnected, 0, "host-managed suspend creates no delayed disconnect callback")
            T:check(NetworkMgr.wifi_was_on and G_reader_settings:isTrue("wifi_was_on"),
                "suspend preserves automatic restore intent")
            T:eq(NetworkMgr.lease_ssid, "before-suspend", "suspend does not claim an unconfirmed lease release")
            T:run(function() listener:onResume() end)
            T:eq(backend.restores, 2, "resume starts a fresh request instead of being blocked by the old guard")
            T:check(NetworkMgr.pending_restore and NetworkMgr.pending_connection,
                "the fresh restore owns both flags")
            T:eq(#polls(), 1, "resume leaves one fresh connectivity poll")
            T:run(function() backend.on, backend.connected = true, true end)
            T:waitUntil(function() return connected == 1 end, 5, "real scheduled poll completes restore")
            T:check(not NetworkMgr.pending_restore and not NetworkMgr.pending_connection and not NetworkMgr.pending_connectivity_check,
                "successful polling releases all pending flags")
            T:eq(NetworkMgr.lease_ssid, "synthetic-restore", "successful restore refreshes the lease identity")
            T:eq(#polls(), 0, "successful restore leaves no polling task")
            T:wait(2.1)
            T:eq(disconnected, 0, "no stale shutdown completion arrives after the new connection")
            T:eq(NetworkMgr.lease_ssid, "synthetic-restore", "the new connection lease survives the old delay window")
            tapWifi()
            T:eq(backend.disables, 1, "normal interactive shutdown still reaches the backend")
            T:eq(disconnected, 1, "normal shutdown sends its completion event")

            T:run(function()
                NetworkMgr.wifi_was_on = true
                G_reader_settings:makeTrue("wifi_was_on")
                NetworkMgr.lease_ssid = "previous-lease"
                backend.result = false
                listener:onResume()
            end)
            T:check(not NetworkMgr.pending_connection and not NetworkMgr.pending_connectivity_check,
                "rejected background restore releases its own guard")
            T:check(NetworkMgr.wifi_was_on and G_reader_settings:isTrue("wifi_was_on"),
                "rejected restore preserves the user's retry intent")
            T:eq(NetworkMgr.lease_ssid, "previous-lease", "rejected restore does not silently discard lease state")
            T:eq(#polls(), 0, "rejected restore schedules no poll")
            T:run(function() backend.result = true; listener:onResume() end)
            T:eq(backend.restores, 4, "a later resume can retry after the explicit failure")
            T:check(NetworkMgr.pending_connection, "accepted retry owns the guard again")
            T:run(function() backend.on, backend.connected = true, true end)
            T:waitUntil(function() return connected == 2 end, 5, "retry completes through the real poll")
            T:check(not NetworkMgr.pending_restore and not NetworkMgr.pending_connection and not NetworkMgr.pending_connectivity_check,
                "retry completion leaves no stuck flags")
            T:run(function() UIManager:close(menu) end)
            T:check(T:topWidget() == observer, "the real network menu closes normally after retry")
        end)
        local cleanup_ok, cleanup_err = pcall(function()
            T:run(function()
                if installed then NetworkMgr:unscheduleConnectivityCheck() end
                if listener then listener:_unscheduleActivityCheck() end
                while T:topWidget() and T:topWidget() ~= fm do UIManager:close(T:topWidget()) end
            end)
        end)
        -- Restore boundaries even if widget/task cleanup fails.
        os.execute = saved.execute
        for _, key in ipairs(caps) do Device[key] = saved.caps[key] end
        for key in pairs(NetworkMgr) do NetworkMgr[key] = nil end
        for key, value in pairs(saved.manager) do NetworkMgr[key] = value end
        G_reader_settings:saveSetting("wifi_was_on", saved.wifi)
        local errors = {}
        local function describe(e) return tostring(type(e) == "table" and e.msg or e) end
        if not ok then errors[#errors + 1] = "scenario: " .. describe(err) end
        if not cleanup_ok then errors[#errors + 1] = "cleanup: " .. describe(cleanup_err) end
        if #errors > 0 then error(table.concat(errors, "\n")) end
        T:check(T:topWidget() == fm, "cleanup restores the original file manager")
    end,
}
