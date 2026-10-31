-- luacheck: ignore 122 -- restored synthetic host-command boundary
-- Exercise the real manager/listener lifecycle with an entirely synthetic backend.
describe("Asynchronous Wi-Fi restore concurrency", function()
    local Device, UIManager, manager, listener
    local saved, backend, tasks, events, saved_settings
    local caps = { "initNetworkManager", "hasWifiToggle", "hasWifiRestore", "hasWifiManager",
        "hasSeamlessWifiToggle", "isKindle", "isAndroid", "isEmulator" }
    local ui_methods = { "scheduleIn", "nextTick", "unschedule", "broadcastEvent", "show", "close" }
    local settings_keys = { "wifi_was_on", "auto_restore_wifi", "auto_disable_wifi" }

    setup(function()
        require("commonrequire")
        Device, UIManager = require("device"), require("ui/uimanager")
    end)

    before_each(function()
        saved = { execute = os.execute, manager = package.loaded["ui/network/manager"],
            listener = package.loaded["ui/network/networklistener"], device = {}, ui = {} }
        for _, key in ipairs(caps) do saved.device[key] = rawget(Device, key) end
        for _, key in ipairs(ui_methods) do saved.ui[key] = rawget(UIManager, key) end
        saved_settings = {}
        for _, key in ipairs(settings_keys) do
            saved_settings[key] = G_reader_settings:readSetting(key)
            G_reader_settings:delSetting(key)
        end
        backend = { restores = 0, enables = 0, disables = 0, on = false, connected = false }
        tasks, events = {}, {}
        os.execute = function() error("unexpected host command in synthetic restore test") end
        Device.hasWifiToggle = function() return true end
        Device.hasWifiRestore = function() return true end
        Device.hasWifiManager = function() return false end
        Device.hasSeamlessWifiToggle = function() return true end
        Device.isKindle = function() return true end -- abort does not invoke pkill
        Device.isAndroid = function() return false end
        Device.isEmulator = function() return false end
        Device.initNetworkManager = function(_, mgr)
            mgr.getNetworkInterfaceName = function() return "synthetic0" end
            mgr.isWifiOn = function() return backend.on end
            mgr.isConnected = function() return backend.connected end
            mgr.getCurrentNetwork = function() return { ssid = "Synthetic" } end
            mgr.restoreWifiAsync = function()
                backend.restores = backend.restores + 1
                backend.guard_seen = mgr.pending_connection
                if backend.restore_error then error(backend.restore_error) end
                return backend.restore_result
            end
            mgr.turnOnWifi = function()
                backend.enables = backend.enables + 1
                return true
            end
            mgr.turnOffWifi = function(_, callback)
                backend.disables = backend.disables + 1
                backend.on, backend.connected = false, false
                if callback then callback() end
            end
        end
        UIManager.scheduleIn = function(_, delay, fn, ...)
            tasks[#tasks + 1] = { delay = delay, fn = fn, args = table.pack(...) }
        end
        UIManager.nextTick = function(_, fn, ...) UIManager:scheduleIn(0, fn, ...) end
        UIManager.unschedule = function(_, fn)
            for i = #tasks, 1, -1 do if tasks[i].fn == fn then table.remove(tasks, i) end end
        end
        UIManager.broadcastEvent = function(_, event) events[#events + 1] = event.handler end
        UIManager.show, UIManager.close = function() end, function() end
        package.loaded["ui/network/manager"], package.loaded["ui/network/networklistener"] = nil, nil
        manager = require("ui/network/manager")
        listener = require("ui/network/networklistener")
    end)

    after_each(function()
        os.execute = saved.execute
        for _, key in ipairs(caps) do Device[key] = saved.device[key] end
        for _, key in ipairs(ui_methods) do UIManager[key] = saved.ui[key] end
        for _, key in ipairs(settings_keys) do G_reader_settings:saveSetting(key, saved_settings[key]) end
        package.loaded["ui/network/manager"], package.loaded["ui/network/networklistener"] = saved.manager, saved.listener
    end)

    local function allowRestore()
        manager.wifi_was_on = true
        G_reader_settings:makeTrue("wifi_was_on")
        G_reader_settings:makeTrue("auto_restore_wifi")
    end
    local function runTask()
        local task = assert(table.remove(tasks, 1))
        task.fn(unpack(task.args, 1, task.args.n))
    end

    it("blocks an interactive connection while startup restore owns the backend", function()
        allowRestore()
        manager:init()
        assert.equals(1, backend.restores)
        local status = manager:requestToTurnOnWifi(nil, true)
        assert.equals(0, backend.enables)
        assert.equals(16, status)
        assert.is_true(manager.pending_connection)
        assert.equals(1, #tasks)
    end)

    it("blocks an interactive connection and duplicate resume while restore is pending", function()
        allowRestore()
        listener:onResume()
        listener:onResume()
        assert.equals(1, backend.restores)
        assert.equals(1, #tasks)
        assert.equals(16, manager:requestToTurnOnWifi(nil, true))
        assert.equals(0, backend.enables)
    end)

    it("does not start restore over an existing interactive attempt or replace its poll", function()
        allowRestore()
        assert.is_true(manager:requestToTurnOnWifi(nil, true))
        manager:scheduleConnectivityCheck(function() end)
        local task = tasks[1]
        listener:onResume()
        assert.equals(0, backend.restores)
        assert.equals(1, #tasks)
        assert.is_true(tasks[1] == task)
        assert.is_true(manager.pending_connection)
    end)

    it("keeps restore intent and releases a rejected request for a fresh nil-status retry", function()
        allowRestore()
        backend.restore_result = false
        manager.lease_ssid = "Previous"
        listener:onResume()
        assert.is_false(manager.pending_connection)
        assert.equals(0, #tasks)
        assert.is_true(manager.wifi_was_on)
        assert.is_true(G_reader_settings:isTrue("wifi_was_on"))
        assert.equals("Previous", manager.lease_ssid)
        assert.equals(0, backend.disables)
        backend.restore_result = nil
        listener:onResume()
        assert.equals(2, backend.restores)
        assert.is_true(manager.pending_connection)
        assert.equals(1, #tasks)
    end)

    it("acquires ownership before calling an accepted true-status backend", function()
        allowRestore()
        backend.restore_result = true
        assert.is_true(manager:requestToRestoreWifi())
        assert.is_true(backend.guard_seen)
        assert.is_true(manager.pending_connection)
        assert.is_true(manager.pending_connectivity_check)
        assert.equals(1, #tasks)
        assert.same({}, events) -- restoration has not connected, no new event contract
    end)

    it("releases its guard on backend exceptions without losing restore intent or the lease", function()
        allowRestore()
        manager.lease_ssid = "Previous"
        backend.restore_error = "synthetic restore failure"
        assert.is_false(manager:requestToRestoreWifi())
        assert.is_false(manager.pending_connection)
        assert.equals(0, #tasks)
        assert.is_true(manager.wifi_was_on)
        assert.is_true(G_reader_settings:isTrue("wifi_was_on"))
        assert.equals("Previous", manager.lease_ssid)
        assert.equals(0, backend.disables)
        backend.restore_error = nil
        assert.is_true(manager:requestToRestoreWifi())
        assert.equals(2, backend.restores)
        assert.equals(1, #tasks)
    end)

    it("does not mistake an existing passive poll or stale cached connectivity for a connection owner", function()
        allowRestore()
        manager:scheduleConnectivityCheck()
        local passive = tasks[1]
        manager.is_connected = true -- stale Lua cache after resume, not a new state query
        assert.is_true(manager:requestToRestoreWifi())
        assert.equals(1, backend.restores)
        assert.is_true(manager.pending_connection)
        assert.is_true(tasks[1] == passive)
        -- Existing passive polling semantics are unchanged, not a new shared-poll design.
        assert.equals(2, #tasks)
    end)

    it("releases the restore guard after actual connectivity polling succeeds", function()
        allowRestore()
        listener:onResume()
        assert.is_true(manager.pending_connection)
        backend.on, backend.connected = true, true
        runTask()
        assert.is_false(manager.pending_connection)
        assert.is_false(manager.pending_connectivity_check)
        assert.equals(0, #tasks)
        assert.equals("Synthetic", manager.lease_ssid)
        assert.equals("onNetworkConnected", events[#events])
        assert.is_true(manager:requestToTurnOnWifi(nil, true))
        assert.equals(1, backend.enables)
    end)

    it("releases the restore guard on polling timeout without introducing another attempt", function()
        allowRestore()
        listener:onResume()
        assert.is_true(manager.pending_connection)
        for _ = 1, 180 do runTask() end
        assert.is_false(manager.pending_connection)
        assert.is_false(manager.pending_connectivity_check)
        assert.equals(0, #tasks)
        assert.equals(1, backend.restores)
        assert.equals(1, backend.disables)
        assert.is_true(manager:requestToTurnOnWifi(nil, true))
    end)

    it("cancels the restore and releases ownership when Wi-Fi is disabled", function()
        allowRestore()
        listener:onResume()
        assert.is_true(manager.pending_connection)
        manager:disableWifi()
        assert.is_false(manager.pending_connection)
        assert.is_false(manager.pending_connectivity_check)
        assert.equals(0, #tasks)
        assert.equals(1, backend.disables)
        assert.is_true(manager:requestToTurnOnWifi(nil, true))
    end)
end)
