-- luacheck: ignore 122 -- restored synthetic io/os boundary overrides
-- NetworkMgr / NetworkListener flows: connection attempts, connectivity polling and its
-- timeout, the beforeWifiAction / afterWifiAction framework, DNS / route failures,
-- the blocking goOnlineToRun loop, the scan & reconnect logic, and the inactivity timer.
-- A fake Wi-Fi backend is installed through Device:initNetworkManager, and UIManager's
-- task queue / widget stack / event broadcasting are recorded so every step is explicit.
describe("NetworkMgr flows", function()
    local Device, UIManager, Event
    local NetworkMgr
    local backend, scheduled, shown, closed, events
    local orig = {}
    local device_caps
    local saved_execute

    local EBUSY = 16

    local function loadManager()
        package.loaded["ui/network/manager"] = nil
        NetworkMgr = require("ui/network/manager")
        return NetworkMgr
    end

    -- Run the pending task queue (in order), until it's empty or `max` tasks ran.
    local function runScheduled(max)
        local n = 0
        while #scheduled > 0 and (not max or n < max) do
            local task = table.remove(scheduled, 1)
            n = n + 1
            task.fn(unpack(task.args, 1, task.args.n))
        end
        return n
    end

    local function countEvents(name)
        local n = 0
        for _, e in ipairs(events) do
            if e == name then n = n + 1 end
        end
        return n
    end

    local function lastShownText()
        local w = shown[#shown]
        return w and w.text
    end

    setup(function()
        require("commonrequire")
        Device = require("device")
        UIManager = require("ui/uimanager")
        Event = require("ui/event")
        saved_execute = os.execute
        os.execute = function() return 0 end -- no host Wi-Fi scripts/processes in synthetic backend tests

        for _, k in ipairs{"initNetworkManager", "hasWifiToggle", "hasWifiRestore", "hasSeamlessWifiToggle",
                           "hasWifiManager", "isKindle", "isAndroid", "isEmulator"} do
            orig[k] = Device[k]
        end
        for _, k in ipairs{"scheduleIn", "nextTick", "unschedule", "show", "close", "broadcastEvent",
                           "forceRePaint", "askForRestart"} do
            orig["UI" .. k] = UIManager[k]
        end

        device_caps = {}
        for _, k in ipairs{"hasWifiToggle", "hasWifiRestore", "hasSeamlessWifiToggle", "hasWifiManager",
                           "isKindle", "isAndroid", "isEmulator"} do
            Device[k] = function() return device_caps[k] end
        end

        function Device:initNetworkManager(mgr)
            function mgr:turnOnWifi(complete_callback, interactive)
                backend.turn_on_calls = backend.turn_on_calls + 1
                backend.last_interactive = interactive
                if backend.turn_on_result == false then
                    return false
                end
                backend.wifi_on = true
                if backend.connect_on_turn_on then
                    backend.connected = true
                end
                if complete_callback and not backend.defer_complete then
                    complete_callback()
                end
                return backend.turn_on_result
            end
            function mgr:turnOffWifi(complete_callback)
                backend.turn_off_calls = backend.turn_off_calls + 1
                if backend.turn_off_result == false then return false end
                backend.wifi_on = false
                backend.connected = false
                if complete_callback then complete_callback() end
            end
            function mgr:isWifiOn() return backend.wifi_on end
            function mgr:isConnected() return backend.connected end
            function mgr:getNetworkInterfaceName() return backend.interface end
            function mgr:getCurrentNetwork() return backend.current_network end
            function mgr:getConfiguredNetworks() return backend.configured end
            function mgr:getNetworkList()
                backend.scan_calls = backend.scan_calls + 1
                local r = table.remove(backend.scans, 1)
                if r == nil then return nil, "scan failed" end
                return r
            end
            function mgr:authenticateNetwork(network)
                table.insert(backend.auth_attempts, network.ssid)
                return backend.auth_ok[network.ssid] or false, "auth failed for " .. network.ssid
            end
            function mgr:obtainIP() backend.obtain_ip_calls = backend.obtain_ip_calls + 1 end
            function mgr:releaseIP() backend.release_ip_calls = backend.release_ip_calls + 1 end
            function mgr:restoreWifiAsync()
                backend.restore_calls = backend.restore_calls + 1
                return backend.restore_result
            end
        end
    end)

    teardown(function()
        os.execute = saved_execute
        for k, v in pairs(orig) do
            if k:sub(1, 2) == "UI" then
                UIManager[k:sub(3)] = v
            else
                Device[k] = v
            end
        end
        package.loaded["ui/network/manager"] = nil
        package.loaded["ui/network/networklistener"] = nil
    end)

    before_each(function()
        backend = {
            wifi_on = false, connected = false, interface = "wlan0", current_network = nil,
            configured = nil, scans = {}, auth_ok = {}, auth_attempts = {},
            turn_on_calls = 0, turn_off_calls = 0, obtain_ip_calls = 0, release_ip_calls = 0,
            restore_calls = 0, scan_calls = 0,
        }
        device_caps.hasWifiToggle = true
        device_caps.hasWifiRestore = false
        device_caps.hasSeamlessWifiToggle = true
        device_caps.hasWifiManager = false
        device_caps.isKindle = false
        device_caps.isAndroid = false
        device_caps.isEmulator = false

        scheduled, shown, closed, events = {}, {}, {}, {}
        UIManager.scheduleIn = function(_, delay, fn, ...)
            table.insert(scheduled, { delay = delay, fn = fn, args = table.pack(...) })
        end
        UIManager.nextTick = function(_, fn, ...)
            table.insert(scheduled, { delay = 0, fn = fn, args = table.pack(...) })
        end
        UIManager.unschedule = function(_, fn)
            for i = #scheduled, 1, -1 do
                if scheduled[i].fn == fn then table.remove(scheduled, i) end
            end
        end
        UIManager.show = function(_, w) table.insert(shown, w) end
        UIManager.close = function(_, w) table.insert(closed, w) end
        UIManager.broadcastEvent = function(_, ev) table.insert(events, (ev.handler:gsub("^on", ""))) end
        UIManager.forceRePaint = function() end
        UIManager.askForRestart = function() end

        G_reader_settings:delSetting("wifi_was_on")
        G_reader_settings:delSetting("wifi_enable_action")
        G_reader_settings:delSetting("wifi_disable_action")
        G_reader_settings:delSetting("auto_restore_wifi")
        G_reader_settings:delSetting("http_proxy")
        G_reader_settings:delSetting("http_proxy_enabled")
        loadManager()
    end)

    it("does not schedule a known failed restore during initialization or forget restore intent", function()
        device_caps.hasWifiRestore, device_caps.isKindle = true, true
        G_reader_settings:makeTrue("wifi_was_on")
        G_reader_settings:makeTrue("auto_restore_wifi")
        backend.restore_result = false
        loadManager()
        assert.equals(1, backend.restore_calls)
        assert.equals(0, #scheduled)
        assert.is_true(NetworkMgr.wifi_was_on)
        assert.is_true(G_reader_settings:isTrue("wifi_was_on"))
    end)

    describe("connectivity check", function()
        it("succeeds once connected: event, wifi_was_on, lease, widget closed, callback once", function()
            backend.wifi_on, backend.connected = true, true
            backend.current_network = { ssid = "Home" }
            NetworkMgr.pending_connection = true
            local cb = spy.new(function() end)
            local widget = { text = "Connecting" }
            NetworkMgr:scheduleConnectivityCheck(cb, widget)
            assert.is_true(NetworkMgr.pending_connectivity_check)
            assert.are.equal(1, #scheduled)
            assert.are.equal(0.25, scheduled[1].delay)
            runScheduled()
            assert.spy(cb).was.called(1)
            assert.are.equal(1, countEvents("NetworkConnected"))
            assert.is_true(NetworkMgr.wifi_was_on)
            assert.is_true(G_reader_settings:isTrue("wifi_was_on"))
            assert.are.equal("Home", NetworkMgr.lease_ssid)
            assert.are.equal(widget, closed[1])
            assert.is_false(NetworkMgr.pending_connectivity_check)
            assert.is_false(NetworkMgr.pending_connection)
            assert.are.equal(0, #scheduled)
        end)

        it("without callback but with a widget, tells the user to retry the action", function()
            backend.wifi_on, backend.connected = true, true
            NetworkMgr:connectivityCheck(1, nil, { text = "Connecting" })
            assert.is_truthy(lastShownText():find("retry the action"))
            assert.is_nil(NetworkMgr.lease_ssid) -- the backend can't tell the SSID
        end)

        it("keeps polling every 250ms while not connected, then succeeds", function()
            backend.wifi_on = true
            local cb = spy.new(function() end)
            NetworkMgr:scheduleConnectivityCheck(cb)
            assert.are.equal(1, runScheduled(1))
            assert.are.equal(1, #scheduled)
            assert.are.equal(2, scheduled[1].args[2]) -- iter (args: self, iter, callback, widget)
            runScheduled(10)
            assert.spy(cb).was.not_called()
            assert.are.equal(12, scheduled[1].args[2])
            backend.connected = true
            runScheduled()
            assert.spy(cb).was.called(1)
            assert.are.equal(1, countEvents("NetworkConnected"))
        end)

        it("gives up after 180 iterations (45s): aborts, kills Wi-Fi, never runs the callback, leaves no task", function()
            backend.wifi_on = true
            NetworkMgr.pending_connection = true
            NetworkMgr.lease_ssid = "Old"
            G_reader_settings:makeTrue("wifi_was_on")
            local cb = spy.new(function() end)
            local widget = { text = "Connecting" }
            NetworkMgr:scheduleConnectivityCheck(cb, widget)
            local ran = runScheduled(1000)
            assert.are.equal(180, ran)
            assert.are.equal(0, #scheduled)
            assert.spy(cb).was.not_called()
            assert.are.equal(0, countEvents("NetworkConnected"))
            assert.are.equal(1, backend.turn_off_calls)
            assert.is_false(NetworkMgr.wifi_was_on)
            assert.is_false(G_reader_settings:isTrue("wifi_was_on"))
            assert.is_nil(NetworkMgr.lease_ssid)
            assert.is_false(NetworkMgr.pending_connection)
            assert.is_false(NetworkMgr.pending_connectivity_check)
            assert.are.equal(widget, closed[1])
            assert.are.equal("Error connecting to the network", lastShownText())
        end)

        it("on abort, doesn't kill Wi-Fi when it can't be toggled seamlessly", function()
            device_caps.hasSeamlessWifiToggle = false
            NetworkMgr:connectivityCheck(180)
            assert.are.equal(0, backend.turn_off_calls)
            assert.are.equal(0, #shown) -- no widget, no warning
        end)

        it("unscheduleConnectivityCheck drops the pending check", function()
            NetworkMgr:scheduleConnectivityCheck()
            NetworkMgr:unscheduleConnectivityCheck()
            assert.are.equal(0, #scheduled)
            assert.is_false(NetworkMgr.pending_connectivity_check)
        end)
    end)

    describe("init", function()
        it("broadcasts NetworkConnected on the next tick when already connected", function()
            backend.wifi_on, backend.connected = true, true
            loadManager()
            assert.are.equal(1, #scheduled)
            runScheduled()
            assert.are.equal(1, countEvents("NetworkConnected"))
        end)

        it("restores Wi-Fi in the background and polls for it when it was on", function()
            device_caps.hasWifiRestore = true
            G_reader_settings:makeTrue("wifi_was_on")
            G_reader_settings:makeTrue("auto_restore_wifi")
            loadManager()
            assert.are.equal(1, backend.restore_calls)
            assert.is_true(NetworkMgr.pending_connectivity_check)
            assert.are.equal(NetworkMgr.connectivityCheck, scheduled[1].fn)
        end)

        it("doesn't restore Wi-Fi when auto_restore_wifi is off", function()
            device_caps.hasWifiRestore = true
            G_reader_settings:makeTrue("wifi_was_on")
            loadManager()
            assert.are.equal(0, backend.restore_calls)
            assert.are.equal(0, #scheduled)
        end)
    end)

    describe("enableWifi / requestToTurnOnWifi", function()
        it("refuses a second concurrent attempt with EBUSY, without calling the backend again", function()
            backend.defer_complete = true
            assert.is_nil(NetworkMgr:requestToTurnOnWifi(function() end))
            assert.are.equal(EBUSY, NetworkMgr:requestToTurnOnWifi(function() end))
            assert.are.equal(1, backend.turn_on_calls)
            assert.are.equal(1, countEvents("NetworkConnecting"))
        end)

        it("schedules a connectivity check carrying the callback once the backend is done", function()
            local cb = spy.new(function() end)
            backend.connect_on_turn_on = true
            assert.is_true(NetworkMgr:enableWifi(cb, true))
            assert.is_true(backend.last_interactive)
            assert.is_true(NetworkMgr.pending_connectivity_check)
            runScheduled()
            assert.spy(cb).was.called(1)
            assert.are.equal(1, countEvents("NetworkConnected"))
        end)

        it("replaces an already pending connectivity check instead of stacking a second one", function()
            NetworkMgr:scheduleConnectivityCheck()
            NetworkMgr:enableWifi()
            assert.are.equal(1, #scheduled)
        end)

        it("aborts on an explicit backend failure", function()
            backend.turn_on_result = false
            NetworkMgr.lease_ssid = "Old"
            assert.is_false(NetworkMgr:enableWifi(function() error("must not run") end))
            assert.is_false(NetworkMgr.pending_connection)
            assert.is_nil(NetworkMgr.lease_ssid)
            assert.are.equal(1, backend.turn_off_calls)
            assert.are.equal(0, #scheduled)
        end)

        it("drops the callback and warns interactive users when an attempt is already ongoing", function()
            NetworkMgr.pending_connection = true
            local cb = spy.new(function() end)
            assert.is_nil(NetworkMgr:enableWifi(cb, true))
            assert.are.equal(0, backend.turn_on_calls)
            assert.is_truthy(lastShownText():find("previous connection attempt"))
            assert.is_nil(NetworkMgr:enableWifi(cb, false))
            assert.are.equal(1, #shown)
            runScheduled()
            assert.spy(cb).was.not_called()
        end)

        it("kills the async restore script on abort (not on Kindle)", function()
            device_caps.hasWifiRestore = true
            local execute = stub(os, "execute")
            NetworkMgr:_abortWifiConnection()
            assert.stub(execute).was.called(1)
            device_caps.isKindle = true
            NetworkMgr:_abortWifiConnection()
            assert.stub(execute).was.called(1)
            execute:revert()
        end)
    end)

    describe("disableWifi", function()
        it("cancels the pending check and broadcasts Disconnecting then Disconnected", function()
            NetworkMgr.lease_ssid = "Home"
            NetworkMgr.pending_connection = true
            NetworkMgr:scheduleConnectivityCheck()
            G_reader_settings:makeTrue("wifi_was_on")
            NetworkMgr.wifi_was_on = true
            local cb = spy.new(function() end)
            NetworkMgr:disableWifi(cb)
            assert.are.same({ "NetworkDisconnecting", "NetworkDisconnected" }, events)
            assert.spy(cb).was.called(1)
            assert.are.equal(0, #scheduled)
            assert.is_nil(NetworkMgr.lease_ssid)
            assert.is_false(NetworkMgr.pending_connection)
            -- Non-interactive: remember that Wi-Fi was on, for the next restore.
            assert.is_true(NetworkMgr.wifi_was_on)
            assert.is_true(G_reader_settings:isTrue("wifi_was_on"))
        end)

        it("preserves restore intent and lease without a false disconnect on explicit backend failure", function()
            backend.wifi_on, backend.connected, backend.turn_off_result = true, true, false
            NetworkMgr.wifi_was_on, NetworkMgr.lease_ssid = true, "Home"
            G_reader_settings:makeTrue("wifi_was_on")
            local completed = spy.new(function() end)
            assert.is_false(NetworkMgr:disableWifi(completed, true))
            assert.spy(completed).was.not_called()
            assert.same({ "NetworkDisconnecting" }, events)
            assert.is_true(NetworkMgr.wifi_was_on)
            assert.is_true(G_reader_settings:isTrue("wifi_was_on"))
            assert.equals("Home", NetworkMgr.lease_ssid)
            assert.is_true(backend.wifi_on)
            assert.equals("Unable to communicate with the Wi-Fi backend", lastShownText())
        end)

        it("clears the lease before a synchronous completion callback on accepted nil status", function()
            NetworkMgr.lease_ssid = "Home"
            local completed = false
            NetworkMgr:disableWifi(function()
                assert.is_nil(NetworkMgr.lease_ssid)
                completed = true
            end)
            assert.is_true(completed)
            assert.equals(1, countEvents("NetworkDisconnected"))
        end)

        it("forgets wifi_was_on when the user turned it off", function()
            NetworkMgr.wifi_was_on = true
            NetworkMgr:disableWifi(nil, true)
            assert.is_false(NetworkMgr.wifi_was_on)
            assert.is_false(G_reader_settings:isTrue("wifi_was_on"))
        end)

        it("toggleWifiOn / toggleWifiOff show and close their InfoMessage", function()
            NetworkMgr:toggleWifiOn(nil, true, true)
            assert.is_true(NetworkMgr.wifi_toggle_long_press)
            assert.are.equal(shown[1], closed[1])
            NetworkMgr:toggleWifiOff(nil, true)
            assert.are.equal(shown[2], closed[2])
            assert.are.equal(1, backend.turn_on_calls)
            assert.are.equal(1, backend.turn_off_calls)
        end)
    end)

    describe("turnOnWifiAndWaitForConnection", function()
        it("runs the callback right away when connected with a valid lease", function()
            backend.wifi_on, backend.connected = true, true
            local cb = spy.new(function() end)
            assert.is_nil(NetworkMgr:turnOnWifiAndWaitForConnection(cb))
            assert.spy(cb).was.called(1)
            assert.are.equal(0, backend.turn_on_calls)
            assert.are.equal(0, #shown)
        end)

        it("forces a re-DHCP on a stale lease, then reconnects", function()
            backend.wifi_on, backend.connected = true, true
            backend.current_network = { ssid = "Office" }
            NetworkMgr.lease_ssid = "Home"
            local cb = spy.new(function() end)
            local info = NetworkMgr:turnOnWifiAndWaitForConnection(cb)
            assert.are.equal(1, backend.release_ip_calls)
            assert.are.equal(1, backend.turn_on_calls)
            assert.are.equal(shown[1], info)
            assert.spy(cb).was.not_called()
            runScheduled()
            assert.spy(cb).was.called(1)
            assert.are.equal(info, closed[1])
            assert.are.equal("Office", NetworkMgr.lease_ssid)
        end)

        it("returns false and closes its InfoMessage when the backend fails", function()
            backend.turn_on_result = false
            assert.is_false(NetworkMgr:turnOnWifiAndWaitForConnection(function() end))
            assert.are.equal(shown[1], closed[1])
            assert.are.equal(0, #scheduled)
        end)

        it("returns nil and closes its InfoMessage when an attempt is ongoing", function()
            NetworkMgr.pending_connection = true
            assert.is_nil(NetworkMgr:turnOnWifiAndWaitForConnection(function() end))
            assert.are.equal(shown[1], closed[1])
            assert.are.equal(0, backend.turn_on_calls)
        end)

        it("doNothingAndWaitForConnection only polls (stale lease: releases it first)", function()
            backend.wifi_on, backend.connected = true, true
            backend.current_network = { ssid = "Office" }
            NetworkMgr.lease_ssid = "Home"
            local cb = spy.new(function() end)
            NetworkMgr:doNothingAndWaitForConnection(cb)
            assert.are.equal(1, backend.release_ip_calls)
            assert.are.equal(0, backend.turn_on_calls)
            runScheduled()
            assert.spy(cb).was.called(1)
            -- Valid lease: immediate.
            local cb2 = spy.new(function() end)
            NetworkMgr:doNothingAndWaitForConnection(cb2)
            assert.spy(cb2).was.called(1)
        end)
    end)

    describe("beforeWifiAction / afterWifiAction", function()
        it("turn_on: connects and runs the callback", function()
            G_reader_settings:saveSetting("wifi_enable_action", "turn_on")
            backend.connect_on_turn_on = true
            local cb = spy.new(function() end)
            NetworkMgr:beforeWifiAction(cb)
            assert.is_true(NetworkMgr:getBeforeActionFlag())
            runScheduled()
            assert.spy(cb).was.called(1)
        end)

        it("ignore: waits for the system to connect without turning Wi-Fi on", function()
            G_reader_settings:saveSetting("wifi_enable_action", "ignore")
            NetworkMgr:beforeWifiAction(function() end)
            assert.are.equal(0, backend.turn_on_calls)
            assert.is_true(NetworkMgr.pending_connectivity_check)
        end)

        it("prompt (default): asks first, connects on OK", function()
            backend.connect_on_turn_on = true
            local cb = spy.new(function() end)
            NetworkMgr:beforeWifiAction(cb)
            assert.are.equal(0, backend.turn_on_calls)
            local box = shown[1]
            assert.is_truthy(box.text:find("turn on Wi%-Fi"))
            box.ok_callback()
            assert.are.equal(1, backend.turn_on_calls)
            runScheduled()
            assert.spy(cb).was.called(1)
        end)

        it("prompt: shows nothing while an attempt is ongoing", function()
            NetworkMgr.pending_connection = true
            NetworkMgr:beforeWifiAction(function() end)
            assert.are.equal(0, #shown)
        end)

        it("afterWifiAction does nothing unless beforeWifiAction ran", function()
            local cb = spy.new(function() end)
            G_reader_settings:saveSetting("wifi_disable_action", "turn_off")
            NetworkMgr:afterWifiAction(cb)
            assert.spy(cb).was.not_called()
            assert.are.equal(0, backend.turn_off_calls)
        end)

        it("afterWifiAction leave_on / turn_off / prompt", function()
            local cb = spy.new(function() end)
            G_reader_settings:saveSetting("wifi_disable_action", "leave_on")
            NetworkMgr:setBeforeActionFlag()
            NetworkMgr:afterWifiAction(cb)
            assert.spy(cb).was.called(1)
            assert.are.equal(0, backend.turn_off_calls)
            assert.is_nil(NetworkMgr:getBeforeActionFlag())

            G_reader_settings:saveSetting("wifi_disable_action", "turn_off")
            NetworkMgr:setBeforeActionFlag()
            NetworkMgr:afterWifiAction(cb)
            assert.spy(cb).was.called(2)
            assert.are.equal(1, backend.turn_off_calls)

            G_reader_settings:saveSetting("wifi_disable_action", "prompt")
            NetworkMgr:setBeforeActionFlag()
            NetworkMgr:afterWifiAction(cb)
            assert.is_truthy(lastShownText():find("turn off Wi%-Fi"))
            shown[#shown].ok_callback()
            assert.are.equal(2, backend.turn_off_calls)
            assert.spy(cb).was.called(3)
        end)
    end)

    describe("online checks", function()
        local socket

        setup(function()
            socket = require("socket")
        end)

        it("isOnline relies on DNS resolution, and fails when DNS fails", function()
            local toip = stub(socket.dns, "toip")
            toip.returns(nil, "host not found")
            assert.is_false(NetworkMgr:isOnline())
            toip:revert()
            toip = stub(socket.dns, "toip")
            toip.returns("13.107.4.52")
            assert.is_true(NetworkMgr:isOnline())
            toip:revert()
        end)

        it("isOnline / isWifiOn / isConnected are always true without a Wi-Fi toggle (no DNS query)", function()
            local toip = stub(socket.dns, "toip")
            device_caps.hasWifiToggle = false
            assert.is_true(NetworkMgr:isOnline())
            assert.stub(toip).was.not_called()
            toip:revert()
            -- The generic (non-backend) implementations.
            package.loaded["ui/network/manager"] = nil
            local saved = Device.initNetworkManager
            Device.initNetworkManager = function() end
            local generic = require("ui/network/manager")
            assert.is_true(generic:isWifiOn())
            assert.is_true(generic:isConnected())
            device_caps.hasWifiToggle = true
            assert.is_nil(generic:isWifiOn())
            assert.is_nil(generic:isConnected())
            Device.initNetworkManager = saved
        end)

        it("hasDefaultRoute: no socket, no IPv4/IPv6 route, IPv6-only route", function()
            local udp = stub(socket, "udp")
            udp.returns(nil, "too many open files")
            assert.is_nil(NetworkMgr:hasDefaultRoute())
            udp:revert()

            local peers = {}
            local results
            local fake = {
                setpeername = function(_, host)
                    table.insert(peers, host)
                    return table.remove(results, 1), "Network is unreachable"
                end,
                close = spy.new(function() end),
            }
            udp = stub(socket, "udp")
            udp.returns(fake)
            results = { nil, nil }
            assert.is_false(NetworkMgr:hasDefaultRoute())
            assert.are.same({ "203.0.113.1", "2001:db8::1" }, peers)
            peers, results = {}, { false, 1 }
            -- (setpeername returns 1 on success, nil on failure)
            results = { nil, 1 }
            assert.is_true(NetworkMgr:hasDefaultRoute())
            assert.spy(fake.close).was.called(2)
            udp:revert()
        end)

        it("runWhenOnline: checks online asynchronously; when connected but offline, reconnects without queueing the callback", function()
            local cb = spy.new(function() end)
            local online_result = true
            local online = stub(NetworkMgr, "checkOnline", function(_, callback) callback(online_result) end)
            NetworkMgr:runWhenOnline(cb)
            assert.spy(cb).was.called(1)
            online_result = false
            local before = stub(NetworkMgr, "beforeWifiAction")
            backend.connected = false
            NetworkMgr:runWhenOnline(cb)
            assert.stub(before).was.called_with(NetworkMgr, cb)
            backend.connected = true
            NetworkMgr:runWhenOnline(cb)
            assert.stub(before).was.called_with(NetworkMgr)
            assert.spy(cb).was.called(1)

            -- willRerunWhenOnline: same, but tells the caller to abort.
            assert.is_true(NetworkMgr:willRerunWhenOnline(cb))
            backend.connected = false
            assert.is_true(NetworkMgr:willRerunWhenOnline(cb))
            online_result = true
            assert.is_true(NetworkMgr:willRerunWhenOnline(cb))
            assert.stub(before).was.called(4)
            online:revert()
            before:revert()
        end)

        it("runWhenConnected / willRerunWhenConnected", function()
            local cb = spy.new(function() end)
            local before = stub(NetworkMgr, "beforeWifiAction")
            backend.connected = true
            NetworkMgr:runWhenConnected(cb)
            assert.spy(cb).was.called(1)
            assert.is_false(NetworkMgr:willRerunWhenConnected(cb))
            backend.connected = false
            NetworkMgr:runWhenConnected(cb)
            assert.is_true(NetworkMgr:willRerunWhenConnected(cb))
            assert.stub(before).was.called(2)
            assert.spy(cb).was.called(1)
            before:revert()
        end)

        it("isNetworkInfoAvailable", function()
            backend.connected = false
            assert.is_falsy(NetworkMgr:isNetworkInfoAvailable())
            device_caps.isAndroid = true
            assert.is_true(NetworkMgr:isNetworkInfoAvailable())
        end)
    end)

    describe("goOnlineToRun (blocking)", function()
        local Input, wait_events, wait_calls

        before_each(function()
            Input = Device.input
            wait_calls = 0
            wait_events = {}
            stub(Input, "waitEvent", function()
                wait_calls = wait_calls + 1
                local f = wait_events[wait_calls]
                if type(f) == "function" then return f() end
                return f
            end)
            stub(Input, "resetState")
            G_reader_settings:saveSetting("wifi_enable_action", "turn_on")
            backend.defer_complete = true
        end)

        after_each(function()
            Input.waitEvent:revert()
            Input.resetState:revert()
        end)

        it("runs the callback immediately when online", function()
            local online = stub(NetworkMgr, "isOnline")
            online.returns(true)
            local cb = spy.new(function() end)
            assert.is_true(NetworkMgr:goOnlineToRun(cb))
            assert.spy(cb).was.called(1)
            online:revert()
        end)

        it("refuses to go online behind the user's back unless wifi_enable_action is turn_on", function()
            local online = stub(NetworkMgr, "isOnline")
            online.returns(false)
            G_reader_settings:saveSetting("wifi_enable_action", "prompt")
            local cb = spy.new(function() end)
            assert.is_false(NetworkMgr:goOnlineToRun(cb))
            assert.spy(cb).was.not_called()
            assert.are.equal(0, backend.turn_on_calls)
            online:revert()
        end)

        it("waits for the connection, then runs the callback and broadcasts NetworkConnected later", function()
            local online = stub(NetworkMgr, "isOnline")
            online.returns(false)
            wait_events[3] = function() backend.connected = true end
            local cb = spy.new(function() end)
            assert.is_true(NetworkMgr:goOnlineToRun(cb))
            assert.spy(cb).was.called(1)
            assert.are.equal(3, wait_calls)
            assert.stub(Input.resetState).was.called(1)
            assert.is_true(G_reader_settings:isTrue("wifi_was_on"))
            assert.is_false(NetworkMgr.pending_connection)
            -- No connectivity check left behind; the delayed event is the only task.
            assert.are.equal(1, #scheduled)
            assert.are.equal(2, scheduled[1].delay)
            runScheduled()
            assert.are.equal(1, countEvents("NetworkConnected"))
            -- Both InfoMessages ("Connecting…", "Waiting…") were closed.
            assert.are.equal(2, #closed)
            online:revert()
        end)

        it("gives up after 120 polls (30s) and aborts", function()
            local online = stub(NetworkMgr, "isOnline")
            online.returns(false)
            local cb = spy.new(function() end)
            assert.is_false(NetworkMgr:goOnlineToRun(cb))
            assert.spy(cb).was.not_called()
            assert.are.equal(119, wait_calls)
            assert.are.equal("Error connecting to the network", lastShownText())
            assert.is_false(NetworkMgr.pending_connection)
            assert.are.equal(1, backend.turn_off_calls)
            assert.are.equal(0, #scheduled)
            online:revert()
        end)

        it("is aborted by a tap, but not by other input", function()
            local online = stub(NetworkMgr, "isOnline")
            online.returns(false)
            local function gesture(ges)
                return { { handler = "onGesture", args = table.pack({ ges = ges }) } }
            end
            wait_events[1] = gesture("swipe")
            wait_events[2] = { { handler = "onKeyPress", args = table.pack({}) } }
            wait_events[3] = gesture("tap")
            local cb = spy.new(function() end)
            assert.is_false(NetworkMgr:goOnlineToRun(cb))
            assert.are.equal(3, wait_calls)
            assert.spy(cb).was.not_called()
            online:revert()
        end)

        it("fails right away when the backend fails to turn Wi-Fi on", function()
            local online = stub(NetworkMgr, "isOnline")
            online.returns(false)
            backend.turn_on_result = false
            assert.is_false(NetworkMgr:goOnlineToRun(function() end))
            assert.are.equal(0, wait_calls)
            online:revert()
        end)
    end)

    describe("reconnectOrShowNetworkMenu", function()
        local NetworkSetting

        setup(function()
            NetworkSetting = require("ui/widget/networksetting")
        end)

        it("reports a scan failure", function()
            assert.is_false(NetworkMgr:reconnectOrShowNetworkMenu())
            assert.are.equal("scan failed", lastShownText())
        end)

        it("rescans once when the first scan is empty, and fails if the rescan fails", function()
            backend.scans = { {} }
            assert.is_false(NetworkMgr:reconnectOrShowNetworkMenu())
            assert.are.equal(2, backend.scan_calls)
        end)

        it("uses the network wpa_supplicant is already connected to", function()
            backend.scans = { {
                { ssid = "Strong", signal_quality = 90, password = "x" },
                { ssid = "Current", signal_quality = 40, connected = true },
            } }
            local cb = spy.new(function() end)
            assert.is_true(NetworkMgr:reconnectOrShowNetworkMenu(cb))
            assert.are.same({}, backend.auth_attempts)
            assert.are.equal(1, backend.obtain_ip_calls)
            assert.are.equal("Current", NetworkMgr.lease_ssid)
            assert.spy(cb).was.called(1)
            assert.is_truthy(lastShownText():find("Connected to network"))
        end)

        it("tries preferred networks by signal quality until one authenticates", function()
            backend.scans = { {
                { ssid = "Weak", signal_quality = 10, password = "a" },
                { ssid = "Best", signal_quality = 95, password = "b" },
                { ssid = "Open", signal_quality = 80 },
                { ssid = "Mid", signal_quality = 50, password = "c" },
            } }
            backend.auth_ok.Mid = true
            device_caps.isKindle = true
            assert.is_true(NetworkMgr:reconnectOrShowNetworkMenu())
            assert.are.same({ "Best", "Mid" }, backend.auth_attempts)
            assert.are.equal("Mid", NetworkMgr.lease_ssid)
            -- Kindle: authentication is asynchronous.
            assert.is_truthy(lastShownText():find("Connecting to network"))
        end)

        it("non-interactive failure returns false (so the caller tears Wi-Fi down), with the error", function()
            backend.scans = { { { ssid = "Best", signal_quality = 95, password = "b" } } }
            assert.is_false(NetworkMgr:reconnectOrShowNetworkMenu())
            assert.are.equal("auth failed for Best", lastShownText())
            assert.are.equal(0, backend.obtain_ip_calls)
            assert.is_nil(NetworkMgr.lease_ssid)
        end)

        it("interactive failure shows the network list instead", function()
            backend.scans = { { { ssid = "Open", signal_quality = 50 } } }
            local cb = function() end
            assert.is_nil(NetworkMgr:reconnectOrShowNetworkMenu(cb, true))
            local w = shown[#shown]
            assert.are.equal(NetworkSetting, getmetatable(w).__index)
            assert.are.equal(cb, w.connect_callback)
        end)

        it("long-press success shows the network list without callbacks, once", function()
            backend.scans = { { { ssid = "Current", signal_quality = 40, connected = true } } }
            NetworkMgr.wifi_toggle_long_press = true
            assert.is_true(NetworkMgr:reconnectOrShowNetworkMenu())
            local w = shown[#shown]
            assert.are.equal(NetworkSetting, getmetatable(w).__index)
            assert.is_nil(w.connect_callback)
            assert.is_nil(NetworkMgr.wifi_toggle_long_press)
        end)

        it("with a Wi-Fi manager, waits for wpa_supplicant to connect on its own", function()
            device_caps.hasWifiManager = true
            backend.configured = { { id = 0 } }
            backend.current_network = { ssid = "Auto" }
            backend.scans = { { { ssid = "Auto", signal_quality = 30 } } }
            local usleep = stub(require("ffi/util"), "usleep")
            assert.is_true(NetworkMgr:reconnectOrShowNetworkMenu())
            assert.stub(usleep).was.called(1)
            assert.are.equal("Auto", NetworkMgr.lease_ssid)
            usleep:revert()
        end)

        it("with a Wi-Fi manager but no configured network, doesn't wait", function()
            device_caps.hasWifiManager = true
            backend.current_network = { ssid = "Auto" }
            backend.scans = { { { ssid = "Auto", signal_quality = 30 } } }
            local usleep = stub(require("ffi/util"), "usleep")
            assert.is_false(NetworkMgr:reconnectOrShowNetworkMenu())
            assert.stub(usleep).was.not_called()
            usleep:revert()
        end)
    end)

    describe("menus and settings", function()
        local touchmenu

        before_each(function()
            touchmenu = { updateItems = spy.new(function() end) }
        end)

        it("Wi-Fi toggle: off -> connect; connected -> disconnect; on but not connected -> prompt", function()
            local t = NetworkMgr:getWifiToggleMenuTable()
            assert.is_true(t.enabled_func())
            backend.connect_on_turn_on = true
            t.callback(touchmenu)
            assert.are.equal(1, backend.turn_on_calls)
            runScheduled()
            assert.spy(touchmenu.updateItems).was.called(1)
            assert.is_true(t.checked_func())

            t.callback(touchmenu)
            assert.are.equal(1, backend.turn_off_calls)
            assert.spy(touchmenu.updateItems).was.called(2)

            backend.wifi_on, backend.connected = true, false
            NetworkMgr.pending_connection = true
            NetworkMgr.pending_connectivity_check = true
            t.hold_callback(touchmenu)
            local box = shown[#shown]
            assert.is_truthy(box.text:find("connection attempt is currently in progress"))
            assert.is_truthy(box.text:find("waiting for connectivity"))
            assert.is_false(box.choice2_enabled)
            box.choice1_callback()
            assert.are.equal(2, backend.turn_off_calls)
            NetworkMgr.pending_connection = false
            box.choice2_callback()
            assert.are.equal(2, backend.turn_on_calls)
        end)

        it("getWifiMenuTable opens the system settings on Android", function()
            device_caps.isAndroid = true
            NetworkMgr.openSettings = spy.new(function() end)
            local t = NetworkMgr:getWifiMenuTable()
            t.callback()
            assert.spy(NetworkMgr.openSettings).was.called(1)
            device_caps.isAndroid = false
            assert.are.equal("Wi-Fi connection", NetworkMgr:getWifiMenuTable().text)
        end)

        it("HTTP proxy: rejects invalid addresses, enables and disables a valid one", function()
            local http = require("socket.http")
            local t = NetworkMgr:getProxyMenuTable()
            assert.is_false(t.hold_input.callback("not a url"))
            assert.are.equal("Invalid proxy address", lastShownText())
            assert.is_nil(t.hold_input.callback("http://proxy.lan:3128"))
            assert.are.equal("http://proxy.lan:3128", http.PROXY)
            assert.is_true(t.checked_func())
            assert.is_truthy(t.text_func():find("proxy.lan"))
            t.callback() -- disable
            assert.is_nil(http.PROXY)
            assert.is_false(G_reader_settings:isTrue("http_proxy_enabled"))
            t.callback() -- re-enable the saved proxy
            assert.are.equal("http://proxy.lan:3128", http.PROXY)
            NetworkMgr:setHTTPProxy(nil)
            G_reader_settings:delSetting("http_proxy")
            t.callback() -- nothing saved: tip
            assert.is_truthy(lastShownText():find("Long press"))
        end)

        it("before/after Wi-Fi action menus save the chosen action", function()
            local before = NetworkMgr:getBeforeWifiActionMenuTable()
            assert.are.equal(2, #before.sub_item_table)
            assert.is_truthy(before.text_func():find("prompt"))
            before.sub_item_table[1].callback()
            assert.are.equal("turn_on", G_reader_settings:readSetting("wifi_enable_action"))
            assert.is_true(before.sub_item_table[1].checked_func())
            assert.is_truthy(before.text_func():find("turn on"))
            device_caps.isAndroid = true
            assert.are.equal(3, #NetworkMgr:getBeforeWifiActionMenuTable().sub_item_table)

            local after = NetworkMgr:getAfterWifiActionMenuTable()
            after.sub_item_table[2].callback()
            assert.are.equal("turn_off", G_reader_settings:readSetting("wifi_disable_action"))
            assert.is_true(after.sub_item_table[2].checked_func())
            assert.is_false(after.sub_item_table[1].checked_func())
            assert.is_truthy(after.text_func():find("turn off"))
        end)

        it("getMenuTable fills the network entries according to the device", function()
            device_caps.hasWifiRestore = true
            device_caps.hasWifiManager = true
            local common = {}
            NetworkMgr:getMenuTable(common)
            for _, k in ipairs{"network_wifi", "network_proxy", "network_info", "network_powersave",
                               "network_restore", "network_dismiss_scan", "network_before_wifi_action",
                               "network_after_wifi_action"} do
                assert.is_not_nil(common[k], k)
            end
            -- Toggles.
            G_reader_settings:delSetting("auto_disable_wifi")
            common.network_powersave.callback()
            assert.is_true(common.network_powersave.checked_func())
            G_reader_settings:delSetting("auto_disable_wifi")
            common.network_restore.callback()
            assert.is_true(common.network_restore.checked_func())
            assert.is_true(common.network_restore.enabled_func())
            local dismiss = G_reader_settings:nilOrTrue("auto_dismiss_wifi_scan")
            common.network_dismiss_scan.callback()
            assert.are.equal(not dismiss, common.network_dismiss_scan.checked_func())
            common.network_dismiss_scan.callback()
            backend.connected = true
            assert.is_true(common.network_info.enabled_func())
            common.network_info.callback()
            assert.are.equal(1, countEvents("ShowNetworkInfo"))

            device_caps.hasWifiToggle = false
            device_caps.hasWifiRestore = false
            device_caps.hasWifiManager = false
            backend.interface = nil
            common = {}
            NetworkMgr:getMenuTable(common)
            assert.is_nil(common.network_wifi)
            assert.is_nil(common.network_powersave)
            assert.is_nil(common.network_restore)
            assert.is_not_nil(common.network_proxy)
        end)

        it("saves, lists and deletes networks", function()
            NetworkMgr.nw_settings = nil
            NetworkMgr:saveNetwork({ ssid = "Home", password = "secret", flags = 0 })
            NetworkMgr.nw_settings = nil
            assert.are.equal("secret", NetworkMgr:getAllSavedNetworks():readSetting("Home").password)
            NetworkMgr.nw_settings = nil
            NetworkMgr:deleteNetwork({ ssid = "Home" })
            NetworkMgr.nw_settings = nil
            assert.is_nil(NetworkMgr:getAllSavedNetworks():readSetting("Home"))
        end)
    end)

    describe("sysfs helpers", function()
        it("report a missing interface as off / not connected / not operational", function()
            NetworkMgr.interface = "koreader-test-nonexistent0"
            assert.is_false(NetworkMgr:sysfsWifiOn())
            assert.is_false(NetworkMgr:sysfsCarrierConnected())
            assert.is_false(NetworkMgr:sysfsInterfaceOperational())
            assert.is_false(NetworkMgr:ifHasAnAddress())
        end)

        it("ifHasAnAddress finds the loopback address when the interface is up", function()
            NetworkMgr.interface = "lo"
            stub(NetworkMgr, "sysfsInterfaceOperational")
            NetworkMgr.sysfsInterfaceOperational.returns(true)
            assert.is_true(NetworkMgr:ifHasAnAddress())
            NetworkMgr.interface = "koreader-test-nonexistent0"
            assert.is_nil(NetworkMgr:ifHasAnAddress())
            NetworkMgr.sysfsInterfaceOperational:revert()
        end)
    end)

    describe("NetworkListener", function()
        local NetworkListener
        local tx

        before_each(function()
            package.loaded["ui/network/networklistener"] = nil
            G_reader_settings:delSetting("auto_standby_timeout_seconds")
            device_caps.hasWifiRestore = true
            NetworkListener = require("ui/network/networklistener")
            tx = {}
            NetworkListener._getTxPackets = function() return table.remove(tx, 1) end
            NetworkListener._activity_check_scheduled = nil
            NetworkListener._last_tx_packets = nil
            NetworkListener._activity_check_delay_seconds = nil
        end)

        it("schedules the inactivity check on connect only with auto_disable_wifi and an interface", function()
            NetworkListener:onNetworkConnected()
            assert.is_true(NetworkMgr:getWifiState())
            assert.is_true(NetworkMgr:getConnectionState())
            assert.are.equal(0, #scheduled)
            G_reader_settings:makeTrue("auto_disable_wifi")
            tx = { 100 }
            NetworkListener:onNetworkConnected()
            assert.are.equal(1, #scheduled)
            assert.are.equal(300, scheduled[1].delay)
            backend.interface = nil
            NetworkListener:onNetworkConnected()
            assert.are.equal(1, #scheduled) -- no interface to watch: no second check
            G_reader_settings:delSetting("auto_disable_wifi")
        end)

        it("retries the inactivity shutdown after explicit backend failure", function()
            G_reader_settings:makeTrue("auto_disable_wifi")
            backend.wifi_on, backend.connected, backend.turn_off_result = true, true, false
            tx = { 100, 101, 102 }
            NetworkListener:onNetworkConnected()
            runScheduled(1)
            assert.equals(1, backend.turn_off_calls)
            assert.equals(0, countEvents("NetworkDisconnected"))
            assert.equals(1, #scheduled)
            assert.equals(600, scheduled[1].delay)
            backend.turn_off_result = nil -- accepted legacy asynchronous/nil contract
            runScheduled(1)
            assert.equals(2, backend.turn_off_calls)
            assert.equals(1, countEvents("NetworkDisconnected"))
            assert.equals(0, #scheduled)
            G_reader_settings:delSetting("auto_disable_wifi")
        end)

        it("does not announce Wi-Fi off after a rejected interactive request", function()
            backend.wifi_on, backend.connected, backend.turn_off_result = true, true, false
            NetworkListener:onInfoWifiOff()
            assert.equals("Unable to communicate with the Wi-Fi backend", lastShownText())
            assert.equals(0, countEvents("NetworkDisconnected"))
            backend.turn_off_result = nil
            NetworkListener:onInfoWifiOff()
            assert.equals("Wi-Fi off.", lastShownText())
        end)

        it("does not poll a rejected resume restore but accepts a later nil-status request", function()
            NetworkMgr.wifi_was_on = true
            G_reader_settings:makeTrue("wifi_was_on")
            G_reader_settings:makeTrue("auto_restore_wifi")
            backend.restore_result = false
            NetworkListener:onResume()
            assert.equals(1, backend.restore_calls)
            assert.equals(0, #scheduled)
            assert.is_true(NetworkMgr.wifi_was_on)
            assert.is_true(G_reader_settings:isTrue("wifi_was_on"))
            backend.restore_result = nil
            NetworkListener:onResume()
            assert.equals(2, backend.restore_calls)
            assert.equals(1, #scheduled)
        end)

        it("backs off while there is traffic (capped at 30 min), and turns Wi-Fi off when idle", function()
            G_reader_settings:makeTrue("auto_disable_wifi")
            backend.wifi_on, backend.connected = true, true
            tx = { 100, 200, 300, 400, 500, 600, 700, 710 }
            NetworkListener:onNetworkConnected()
            local delays = {}
            for _ = 1, 7 do
                table.insert(delays, scheduled[1].delay)
                runScheduled(1)
            end
            assert.are.same({ 300, 600, 900, 1200, 1500, 1800, 1800 }, delays)
            -- Last check: +10 packets over 30 min <= 12 * 6 noise threshold -> idle.
            assert.are.equal(0, #scheduled)
            assert.are.equal(1, backend.turn_off_calls)
            assert.are.equal(1, countEvents("NetworkDisconnected"))
            G_reader_settings:delSetting("auto_disable_wifi")
        end)

        it("unschedules and resets on disconnect and on suspend", function()
            G_reader_settings:makeTrue("auto_disable_wifi")
            tx = { 1, 2 }
            NetworkListener:onNetworkConnected()
            NetworkMgr:setBeforeActionFlag()
            NetworkListener:onNetworkDisconnected()
            assert.are.equal(0, #scheduled)
            assert.is_nil(NetworkListener._last_tx_packets)
            assert.is_nil(NetworkListener._activity_check_delay_seconds)
            assert.is_nil(NetworkMgr:getBeforeActionFlag())
            assert.is_false(NetworkMgr:getWifiState())

            NetworkListener:onNetworkConnected()
            NetworkMgr:setBeforeActionFlag()
            device_caps.hasWifiManager = true
            backend.wifi_on = true
            NetworkListener:onSuspend()
            assert.are.equal(0, #scheduled)
            assert.are.equal(1, backend.turn_off_calls)
            assert.is_nil(NetworkMgr:getBeforeActionFlag())
            G_reader_settings:delSetting("auto_disable_wifi")
        end)

        it("restores Wi-Fi on resume only if it was on and auto_restore_wifi is set", function()
            NetworkMgr.wifi_was_on = true
            NetworkListener:onResume()
            assert.are.equal(0, backend.restore_calls)
            G_reader_settings:makeTrue("auto_restore_wifi")
            NetworkListener:onResume()
            assert.are.equal(1, backend.restore_calls)
            assert.is_true(NetworkMgr.pending_connectivity_check)
            NetworkMgr.wifi_was_on = false
            NetworkListener:onResume()
            assert.are.equal(1, backend.restore_calls)
        end)

        it("toggles Wi-Fi and reports the connection", function()
            backend.connect_on_turn_on = true
            NetworkListener:onToggleWifi()
            assert.are.equal(1, backend.turn_on_calls)
            assert.is_true(backend.last_interactive)
            NetworkListener:onToggleWifi()
            assert.are.equal(1, backend.turn_off_calls)
            assert.are.equal("Wi-Fi off.", lastShownText())
            NetworkListener:onInfoWifiOff()
            assert.are.equal(2, backend.turn_off_calls)

            local online_result = true
            local online = stub(NetworkMgr, "checkOnline", function(_, callback) callback(online_result) end)
            backend.current_network = { ssid = "Home" }
            NetworkListener:onInfoWifiOn()
            assert.is_truthy(lastShownText():find("Already connected to network"))
            backend.current_network = nil
            NetworkListener:onInfoWifiOn()
            assert.are.equal("Already connected.", lastShownText())
            online_result = false
            NetworkListener:onInfoWifiOn()
            assert.are.equal(2, backend.turn_on_calls)
            online:revert()
        end)

        it("shows the network info, or that it isn't available", function()
            local saved = Device.retrieveNetworkInfo
            Device.retrieveNetworkInfo = false
            NetworkListener:onShowNetworkInfo()
            assert.are.equal("Could not retrieve network info.", lastShownText())
            Device.retrieveNetworkInfo = function() return "IP: 192.0.2.7" end
            NetworkListener:onShowNetworkInfo()
            assert.are.equal("IP: 192.0.2.7", lastShownText())
            Device.retrieveNetworkInfo = saved
        end)

        it("halves the inactivity timeouts when auto-standby is enabled", function()
            package.loaded["ui/network/networklistener"] = nil
            G_reader_settings:saveSetting("auto_standby_timeout_seconds", 30)
            local L = require("ui/network/networklistener")
            G_reader_settings:delSetting("auto_standby_timeout_seconds")
            L._getTxPackets = function() return 1 end
            L._activity_check_delay_seconds = nil
            L._last_tx_packets = nil
            L:_scheduleActivityCheck()
            assert.are.equal(150, scheduled[1].delay)
            L:_unscheduleActivityCheck()
        end)

        it("is inert on devices without a Wi-Fi toggle", function()
            package.loaded["ui/network/networklistener"] = nil
            device_caps.hasWifiToggle = false
            local L = require("ui/network/networklistener")
            assert.is_nil(rawget(L, "onToggleWifi"))
            package.loaded["ui/network/networklistener"] = nil
        end)
    end)

    it("Event names used by the flows exist (sanity)", function()
        assert.are.equal("onNetworkConnected", Event:new("NetworkConnected").handler)
    end)
end)
