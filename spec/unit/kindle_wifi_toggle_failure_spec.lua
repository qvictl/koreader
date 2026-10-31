-- luacheck: ignore 122 -- restored synthetic io/os boundary overrides
-- Only the hardware boundary is synthetic: no LIPC call, shell command or
-- network operation may reach the host while exercising the real Kindle backend.
describe("Kindle Wi-Fi toggle failures", function()
    local Kindle, manager, failure, writes, closed, scheduled, shown, reconnected, commands
    local saved_open, saved_execute, saved_modules, saved_preload
    local fail_close, command_status
    local module_names = { "liblipclua", "libopenlipclua", "ffi/framebuffer_mxcfb", "device/kindle/device" }

    local function handle()
        return {
            get_string_property = function() return "screensaver" end,
            get_int_property = function() return 0 end,
            register_int_property = function() return {} end,
            set_int_property = function(_, source, property, value)
                writes[#writes + 1] = { source, property, value }
                if failure == "write" .. #writes then error("Lipc error: 3:lipcErrNoSuchSource") end
            end,
            close = function()
                closed = closed + 1
                if failure == "close" or fail_close then error("injected close failure") end
            end,
        }
    end

    local function installBindings()
        package.loaded["liblipclua"] = {
            init = function()
                if failure == "init throw" then error("injected init failure") end
                if failure == "init nil" then return nil end
                return handle()
            end,
        }
    end

    setup(function()
        require("commonrequire")
        saved_open, saved_execute = io.open, os.execute
        saved_modules, saved_preload = {}, package.preload["liblipclua"]
        for _, name in ipairs(module_names) do saved_modules[name] = package.loaded[name] end
        writes, closed = {}, 0
        installBindings()
        package.loaded["libopenlipclua"] = { open_no_name = handle }
        package.loaded["ffi/framebuffer_mxcfb"] = { new = function() return {} end }
        io.open = function(path, ...)
            if path == "/proc/usid" then return { read = function() return "G000G1XX" end, close = function() end } end
            return saved_open(path, ...)
        end
        package.loaded["device/kindle/device"] = nil
        Kindle = require("device/kindle/device")
        io.open = saved_open
    end)

    teardown(function()
        io.open, os.execute = saved_open, saved_execute
        package.preload["liblipclua"] = saved_preload
        for _, name in ipairs(module_names) do package.loaded[name] = saved_modules[name] end
    end)

    before_each(function()
        failure, writes, closed, scheduled, shown, reconnected, commands = nil, {}, 0, {}, {}, 0, {}
        installBindings()
        fail_close, command_status = false, {}
        os.execute = function(command)
            commands[#commands + 1] = command
            return command_status[command] or 0 -- record the legacy path, never execute it
        end
        Kindle:UIManagerReady({
            scheduleIn = function(_, delay, fn) scheduled[#scheduled + 1] = { delay, fn } end,
            show = function(_, widget) shown[#shown + 1] = widget end,
        })
        manager = {
            reconnectOrShowNetworkMenu = function(_, callback, interactive)
                reconnected = reconnected + 1
                return "requested", callback, interactive
            end,
        }
        Kindle:initNetworkManager(manager)
    end)

    it("preserves the two-step enable order and the reconnect contract", function()
        local callback = function() end
        local result, forwarded, interactive = manager:turnOnWifi(callback, true)
        assert.equals("requested", result)
        assert.equals(callback, forwarded)
        assert.is_true(interactive)
        assert.same({
            { "com.lab126.cmd", "wirelessEnable", 1 },
            { "com.lab126.wifid", "enable", 1 },
        }, writes)
        assert.equals(1, closed)
        assert.equals(1, reconnected)
        assert.equals(0, #commands)
    end)

    it("preserves disable order and delays completion until the accepted request", function()
        local completed = 0
        manager:turnOffWifi(function() completed = completed + 1 end)
        assert.same({
            { "com.lab126.wifid", "enable", 0 },
            { "com.lab126.cmd", "wirelessEnable", 0 },
        }, writes)
        assert.equals(1, closed)
        assert.equals(0, completed)
        assert.equals(2, scheduled[1][1])
        scheduled[1][2]()
        assert.equals(1, completed)
    end)

    for _, operation in ipairs({ "turnOnWifi", "turnOffWifi", "restoreWifiAsync" }) do
        for _, failed_write in ipairs({ 1, 2 }) do
            it("closes and fails " .. operation .. " when LIPC write " .. failed_write .. " throws", function()
                failure = "write" .. failed_write
                local completed = 0
                local status = manager[operation](manager, function() completed = completed + 1 end)
                assert.is_false(status)
                assert.equals(failed_write, #writes)
                assert.equals(1, closed)
                assert.equals(0, completed)
                assert.equals(0, #scheduled)
                assert.equals(0, reconnected)
                assert.equals(0, #commands)
            end)
        end
    end

    for _, init_failure in ipairs({ "init throw", "init nil" }) do
        it("does not switch to shell after binding initialization failure: " .. init_failure, function()
            failure = init_failure
            assert.is_false(manager:turnOnWifi())
            assert.equals(0, #writes)
            assert.equals(0, closed)
            assert.equals(0, reconnected)
            assert.equals(0, #commands)
        end)
    end

    it("reports close failure without closing twice or reconnecting", function()
        failure = "close"
        assert.is_false(manager:turnOnWifi())
        assert.equals(2, #writes)
        assert.equals(1, closed)
        assert.equals(0, reconnected)
    end)

    it("closes once even if both the write and close throw, then permits a fresh retry", function()
        failure, fail_close = "write1", true
        assert.is_false(manager:turnOnWifi())
        assert.equals(1, closed)
        assert.equals(0, reconnected)
        failure, fail_close = nil, false
        assert.equals("requested", manager:turnOnWifi())
        assert.equals(2, closed)
        assert.equals(1, reconnected)
    end)

    it("reports an interactive enable failure without claiming a connection", function()
        failure = "write1"
        assert.is_false(manager:turnOnWifi(nil, true))
        assert.equals(1, #shown)
        assert.equals(require("gettext")("Unable to communicate with the Wi-Fi backend"), shown[1].text)
        assert.equals(0, reconnected)
    end)

    it("reports accepted asynchronous restore", function()
        assert.is_true(manager:restoreWifiAsync())
        assert.equals(2, #writes)
        assert.equals(1, closed)
    end)

    it("retains the legacy no-binding path without running host commands", function()
        package.loaded["liblipclua"] = nil
        package.preload["liblipclua"] = function() error("synthetic unavailable binding") end
        Kindle:initNetworkManager(manager)
        local completed = 0
        manager:turnOnWifi(function() completed = completed + 1 end)
        assert.same({ "lipc-set-prop -i com.lab126.wan enable 0", "lipc-set-prop -i com.lab126.wifid enable 1" }, commands)
        assert.equals(1, completed)
        assert.equals(0, reconnected)
    end)
    it("does not mistake a missing WAN service for a failed legacy Wi-Fi request", function()
        package.loaded["liblipclua"] = nil
        package.preload["liblipclua"] = function() error("synthetic unavailable binding") end
        command_status["lipc-set-prop -i com.lab126.wan enable 0"] = 256
        Kindle:initNetworkManager(manager)
        local completed = 0
        manager:turnOnWifi(function() completed = completed + 1 end)
        assert.equals(1, completed)
        assert.equals(2, #commands)
    end)

    it("reports a failed legacy wifid command without scheduling completion", function()
        package.loaded["liblipclua"] = nil
        package.preload["liblipclua"] = function() error("synthetic unavailable binding") end
        command_status["lipc-set-prop -i com.lab126.wifid enable 0"] = 256
        Kindle:initNetworkManager(manager)
        assert.is_false(manager:turnOffWifi(function() error("unexpected completion") end))
        assert.equals(0, #scheduled)
    end)

end)
