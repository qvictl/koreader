-- luacheck: ignore 122 -- restored synthetic io/os boundary overrides
-- Real network menu, messages, event dispatch and timer queue; only the Kindle
-- hardware/LIPC boundary is synthetic. Never issue a Wi-Fi command to the host.
return {
    name = "Kindle Wi-Fi backend failure is dismissible and retryable",
    timeout = 45,
    settings = { language = "en", auto_disable_wifi = false, auto_restore_wifi = true },
    run = function(T)
        local Device = require("device")
        local NetworkMgr = require("ui/network/manager")
        local UIManager = require("ui/uimanager")
        local TouchMenu = require("ui/widget/touchmenu")
        local WidgetContainer = require("ui/widget/container/widgetcontainer")
        local _ = require("gettext")
        local fm = T:fileManager()
        local saved = { manager = {}, caps = {}, modules = {}, open = io.open, execute = os.execute,
            wifi = G_reader_settings:readSetting("wifi_was_on") }
        local module_names = { "liblipclua", "libopenlipclua", "ffi/framebuffer_mxcfb", "device/kindle/device" }
        local caps = { "hasWifiToggle", "hasWifiRestore", "isKindle", "hasSeamlessWifiToggle" }
        for key, value in pairs(NetworkMgr) do saved.manager[key] = value end
        for _, key in ipairs(caps) do saved.caps[key] = rawget(Device, key) end
        for _, key in ipairs(module_names) do saved.modules[key] = package.loaded[key] end
        local failure, wifi_on, opened, closed, reconnects = false, true, 0, 0, 0
        local disconnected, connected, completions = 0, 0, {}
        local menu, observer, listener
        local function handle()
            return {
                get_string_property = function() return "screensaver" end,
                get_int_property = function() return 0 end,
                register_int_property = function() return {} end,
                set_int_property = function(_, source, property, value)
                    if failure then error("Lipc error: 3:lipcErrNoSuchSource") end
                    if source == "com.lab126.wifid" and property == "enable" then wifi_on = value == 1 end
                end,
                close = function() closed = closed + 1 end,
            }
        end
        local function dismissError()
            local message = T:waitUntil(function()
                local top = T:topWidget()
                return top and top.text == _("Unable to communicate with the Wi-Fi backend") and top
            end, 5, "backend failure message")
            T:repaint()
            T:tapWidget(message, "dismiss backend failure")
            T:check(not UIManager:isWidgetShown(message), "failure message dismisses normally")
        end
        local function tapWifi()
            T:repaint()
            local item = T:findWidget(menu, function(w) return w.item and w.item.text == _("Wi-Fi connection") end)
            T:tapWidget(item, "network menu Wi-Fi connection")
        end
        local ok, err = pcall(function()
            T:run(function()
                os.execute = function() error("host shell execution forbidden in synthetic Wi-Fi scenario") end
                package.loaded["liblipclua"] = { init = function() opened = opened + 1; return handle() end }
                package.loaded["libopenlipclua"] = { open_no_name = handle }
                package.loaded["ffi/framebuffer_mxcfb"] = { new = function() return {} end }
                io.open = function(path, ...)
                    if path == "/proc/usid" then
                        return { read = function() return "G000G1XX" end, close = function() end }
                    end
                    return saved.open(path, ...)
                end
                package.loaded["device/kindle/device"] = nil
                local Kindle = require("device/kindle/device")
                io.open = saved.open
                Kindle:UIManagerReady({
                    show = function(_, ...) return UIManager:show(...) end,
                    scheduleIn = function(_, delay, fn)
                        completions[#completions + 1] = fn
                        return UIManager:scheduleIn(delay, fn)
                    end,
                })
                Kindle:initNetworkManager(NetworkMgr)
                Device.hasWifiToggle = function() return true end
                Device.hasWifiRestore = function() return true end
                Device.isKindle = function() return true end
                Device.hasSeamlessWifiToggle = function() return true end
                NetworkMgr.isWifiOn = function() return wifi_on end
                NetworkMgr.isConnected = function() return wifi_on end
                NetworkMgr.getCurrentNetwork = function() return { ssid = "synthetic-network" } end
                -- Scanning/association is a hardware boundary, not a host network request.
                NetworkMgr.reconnectOrShowNetworkMenu = function(_, callback)
                    reconnects = reconnects + 1
                    if callback then callback() end
                    return true
                end
                NetworkMgr:unscheduleConnectivityCheck()
                NetworkMgr.pending_connection = false
                NetworkMgr.wifi_was_on = true
                NetworkMgr.lease_ssid = "synthetic-network"
                G_reader_settings:makeTrue("wifi_was_on")
                listener = dofile("frontend/ui/network/networklistener.lua"):new{}
                observer = WidgetContainer:new{
                    onNetworkDisconnected = function()
                        disconnected = disconnected + 1
                        listener:onNetworkDisconnected()
                    end,
                    onNetworkConnected = function()
                        connected = connected + 1
                        listener:onNetworkConnected()
                    end,
                }
                UIManager:show(observer)
                menu = TouchMenu:new{
                    width = T.screen_w,
                    tab_item_table = { { icon = "network", NetworkMgr:getWifiToggleMenuTable() } },
                }
                UIManager:show(menu)
                opened, closed, failure = 0, 0, true
            end)
            tapWifi()
            T:eq(disconnected, 0, "failed shutdown emits no disconnected event")
            T:eq(#completions, 0, "failed shutdown queues no delayed completion")
            T:eq(NetworkMgr.lease_ssid, "synthetic-network", "failed shutdown preserves the known lease")
            T:check(NetworkMgr.wifi_was_on and G_reader_settings:isTrue("wifi_was_on"),
                "failed interactive shutdown preserves restore intent")
            T:eq(opened, closed, "failed request closes its LIPC handle")
            dismissError()
            T:check(T:topWidget() == menu, "dismissing failure returns to the usable network menu")

            T:run(function() failure = false end)
            tapWifi()
            T:waitUntil(function() return disconnected == 1 end, 5, "accepted retry's real delayed completion")
            T:eq(#completions, 1, "accepted shutdown schedules exactly one completion")
            T:check(not NetworkMgr.wifi_was_on and G_reader_settings:isFalse("wifi_was_on"),
                "accepted interactive shutdown clears restore intent")
            T:eq(NetworkMgr.lease_ssid, nil, "accepted shutdown releases the cached lease")

            T:run(function() failure = true end)
            tapWifi()
            T:eq(reconnects, 0, "failed enable never starts scanning or association")
            T:check(not NetworkMgr.pending_connection and not NetworkMgr.pending_connectivity_check,
                "failed enable leaves no stuck connection or polling task")
            dismissError()
            T:run(function() failure = false end)
            tapWifi()
            T:waitUntil(function() return connected == 1 end, 5, "accepted enable completes real connectivity polling")
            T:eq(reconnects, 1, "retry reaches the association boundary exactly once")
            T:check(NetworkMgr.wifi_was_on, "successful retry restores the on preference")
            T:run(function() UIManager:close(menu) end)

            -- The action/gesture listener must not replace an error with 'Wi-Fi off.'.
            T:run(function() failure = true; listener:onInfoWifiOff() end)
            dismissError()
            T:eq(disconnected, 1, "failed listener action does not falsely disconnect")
            T:check(T:topWidget() == observer, "no false Wi-Fi off popup remains after dismissing failure")
            T:run(function() wifi_on = false; listener:onResume() end)
            T:check(NetworkMgr.wifi_was_on, "failed resume retains the user's restore intent")
            T:check(not NetworkMgr.pending_connectivity_check, "failed resume starts no pointless polling")
            T:run(function() failure = false; listener:onResume() end)
            T:waitUntil(function() return connected == 2 end, 5, "later resume retries and reconnects")
            T:eq(opened, closed, "all failed and successful requests close exactly one handle")
        end)

        -- Cancel our exact callbacks before restoring backends, even after an assertion failure.
        local cleanup_ok, cleanup_err = pcall(function()
            T:run(function()
                for _, fn in ipairs(completions) do UIManager:unschedule(fn) end
                NetworkMgr:unscheduleConnectivityCheck()
                if listener then listener:_unscheduleActivityCheck() end
                while T:topWidget() and T:topWidget() ~= fm do UIManager:close(T:topWidget()) end
            end)
        end)
        io.open, os.execute = saved.open, saved.execute
        for _, key in ipairs(caps) do Device[key] = saved.caps[key] end
        for _, key in ipairs(module_names) do package.loaded[key] = saved.modules[key] end
        for key in pairs(NetworkMgr) do NetworkMgr[key] = nil end
        for key, value in pairs(saved.manager) do NetworkMgr[key] = value end
        G_reader_settings:saveSetting("wifi_was_on", saved.wifi)
        local errors = {}
        local function describe(e) return tostring(type(e) == "table" and e.msg or e) end
        if not ok then errors[#errors + 1] = "scenario: " .. describe(err) end
        if not cleanup_ok then errors[#errors + 1] = "cleanup: " .. describe(cleanup_err) end
        if #errors > 0 then error(table.concat(errors, "\n")) end
        T:check(T:topWidget() == fm, "cleanup returns to the original file manager")
    end,
}
