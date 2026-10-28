-- Kindle device support: model detection & per-model init, the powerd-driven
-- suspend / resume sequencing (screensaver, Special Offers devices, hibernation),
-- lipc-backed Wi-Fi (scan, profiles, failures), KindlePowerD (frontlight steps,
-- battery, wakeup alarms), and misc. device helpers.
-- lipc (liblipclua / libopenlipclua), the framebuffer and sysfs are faked.
-- luacheck: ignore 122 143
describe("Kindle device", function()
    local iopen = io.open
    local ilines = io.lines
    local osgetenv = os.getenv
    local ffi, C, lfs
    local mock_fb
    local lipc_props, lipc_calls, lipc_fail, lipc_init_fails
    local hash_props, hash_fail
    local env
    local Input

    -- Fake liblipclua: properties come from `lipc_props`, sets are recorded in `lipc_calls`.
    local function newLipcHandle()
        return {
            get_int_property = function(_, pub, prop)
                if lipc_fail[prop] then error("lipc failure: " .. prop) end
                return lipc_props[pub .. "." .. prop]
            end,
            get_string_property = function(_, pub, prop)
                if lipc_fail[prop] then error("lipc failure: " .. prop) end
                local v = lipc_props[pub .. "." .. prop]
                if type(v) == "table" then return table.remove(v, 1) end
                return v
            end,
            set_int_property = function(_, pub, prop, value)
                table.insert(lipc_calls, { pub .. "." .. prop, value })
            end,
            set_string_property = function(_, pub, prop, value)
                table.insert(lipc_calls, { pub .. "." .. prop, value })
            end,
            register_int_property = function() return {} end,
            close = function() table.insert(lipc_calls, { "close" }) end,
            new_hasharray = function()
                local ha = { destroyed = false }
                function ha:add_hash() self.hash = {} end
                function ha:put_string(_, k, v) self.hash[k] = v end
                function ha:put_int(_, k, v) self.hash[k] = v end
                function ha:destroy() self.destroyed = true end
                return ha
            end,
            access_hash_property = function(_, pub, prop, ha_input)
                if hash_fail[prop] then error("hasharray failure: " .. prop) end
                table.insert(lipc_calls, { pub .. "." .. prop, ha_input.hash })
                local v = hash_props[prop]
                if v == "nil" then return nil end
                return {
                    to_table = function() return v end,
                    destroy = function() end,
                }
            end,
        }
    end

    local function installLipc(with_lipc, with_openlipc)
        package.loaded["liblipclua"] = with_lipc and {
            init = function()
                if lipc_init_fails then return nil end
                return newLipcHandle()
            end,
        } or nil
        package.preload["liblipclua"] = (not with_lipc) and function() error("no liblipclua") end or nil
        package.loaded["libopenlipclua"] = with_openlipc and {
            open_no_name = function()
                if lipc_init_fails then return nil end
                return newLipcHandle()
            end,
        } or nil
        package.preload["libopenlipclua"] = (not with_openlipc) and function() error("no libopenlipclua") end or nil
    end

    local function loadKindle(serial, opts)
        opts = opts or {}
        io.open = function(filename, mode)
            if filename == "/proc/usid" then
                return { read = function() return serial end, close = function() end }
            end
            if opts.files and opts.files[filename] ~= nil then
                local v = opts.files[filename]
                if v == false then return nil end
                return {
                    read = function(_, fmt)
                        if fmt == "*number" or fmt == "*n" then return tonumber(v) end
                        return tostring(v)
                    end,
                    close = function() end,
                }
            end
            return iopen(filename, mode)
        end
        installLipc(opts.lipc ~= false, opts.openlipc ~= false)
        package.loaded["device/kindle/device"] = nil
        package.loaded["device/kindle/powerd"] = nil
        local ok, dev = pcall(require, "device/kindle/device")
        io.open = iopen
        if not ok then error(dev, 0) end
        return dev
    end

    local function initKindle(serial, opts)
        local dev = loadKindle(serial, opts)
        if opts and opts.files then
            io.open = function(filename, mode)
                local v = opts.files[filename]
                if v ~= nil then
                    if v == false then return nil end
                    return {
                        read = function(_, fmt)
                            if fmt == "*number" or fmt == "*n" then return tonumber(v) end
                            return tostring(v)
                        end,
                        close = function() end,
                    }
                end
                return iopen(filename, mode)
            end
        end
        dev:init()
        io.open = iopen
        return dev
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        ffi = require("ffi")
        C = ffi.C
        lfs = require("libs/libkoreader-lfs")
        require("ffi/linux_input_h")
        local fb = require("ffi/framebuffer")
        mock_fb = {
            new = function(_, o)
                return {
                    device = o and o.device,
                    bb = require("ffi/blitbuffer").new(600, 800, 1),
                    getRawSize = function() return {w = 600, h = 800} end,
                    getWidth = function() return 600 end,
                    getHeight = function() return 800 end,
                    getScreenWidth = function() return 600 end,
                    getScreenHeight = function() return 800 end,
                    getDPI = function() return 300 end,
                    setViewport = function() end,
                    getRotationMode = function() return 0 end,
                    getScreenMode = function() return "portrait" end,
                    setRotationMode = function() end,
                    scaleByDPI = fb.scaleByDPI,
                    scaleBySize = fb.scaleBySize,
                    setWindowTitle = function() end,
                    refreshFull = function() end,
                    getHWNightmode = function() return false end,
                    setupDithering = function() end,
                    toggleSWDithering = function() end,
                    toggleHWDithering = function() end,
                    setHWNightmode = function() end,
                    _MTK_ToggleFastMode = function() end,
                }
            end,
        }
        Input = require("device/input")
    end)

    teardown(function()
        io.open = iopen
        io.lines = ilines
        package.loaded["liblipclua"] = nil
        package.loaded["libopenlipclua"] = nil
        package.preload["liblipclua"] = nil
        package.preload["libopenlipclua"] = nil
        package.loaded["device/kindle/device"] = nil
        package.loaded["device/kindle/powerd"] = nil
        package.loaded["ffi/framebuffer_mxcfb"] = nil
        package.loaded["ffi/framebuffer_einkfb"] = nil
    end)

    before_each(function()
        lipc_props, lipc_calls, lipc_fail, hash_props, hash_fail = {}, {}, {}, {}, {}
        lipc_init_fails = false
        env = {}
        package.loaded["ffi/framebuffer_mxcfb"] = mock_fb
        package.loaded["ffi/framebuffer_einkfb"] = mock_fb
        Input.input = {}
        stub(Input, "open")
        stub(Input, "fdopen")
        stub(os, "getenv")
        os.getenv.invokes(function(k)
            if env[k] ~= nil then return env[k] end
            return osgetenv(k)
        end)
        stub(os, "execute")
        os.execute.returns(0)
    end)

    after_each(function()
        io.open = iopen
        io.lines = ilines
        Input.open:revert()
        Input.fdopen:revert()
        os.getenv:revert()
        os.execute:revert()
    end)

    local function lipcSets(prop)
        local t = {}
        for _, c in ipairs(lipc_calls) do
            if c[1] == prop then table.insert(t, c[2]) end
        end
        return t
    end

    describe("model detection", function()
        -- One serial per supported family: {serial, model}
        local models = {
            { "B002XXXX", "Kindle2" }, { "B004XXXX", "Kindle2" }, { "B009XXXX", "KindleDXG" },
            { "B008XXXX", "Kindle3" }, { "B00EXXXX", "Kindle4" }, { "B00FXXXX", "KindleTouch" },
            { "B024XXXX", "KindlePaperWhite" }, { "B0D4XXXX", "KindlePaperWhite2" },
            { "B0C6XXXX", "KindleBasic" }, { "9013XXXX", "KindleVoyage" },
            { "G000G1XX", "KindlePaperWhite3" }, { "G000GCXX", "KindleOasis" },
            { "G000LMXX", "KindleOasis2" }, { "G000DUXX", "KindleBasic2" },
            { "G000PPXX", "KindlePaperWhite4" }, { "G0010LXX", "KindleBasic3" },
            { "G0011LXX", "KindleOasis3" }, { "G001Q0XX", "KindlePaperWhite5" },
            { "G001LGXX", "KindlePaperWhite5SE" }, { "G0022DXX", "KindleBasic4" },
            { "G0027JXX", "KindleScribe" }, { "G003H2XX", "KindleColorSoft" },
            { "G00A89XX", "KindleBasic5" }, { "G0033WXX", "KindlePaperWhite6" },
            { "G003V0XX", "KindleScribe" }, { "G004PGXX", "KindleScribe3" },
            { "G004VXXX", "KindleScribeColorSoft" },
        }

        it("maps serial numbers to models, and every model initializes", function()
            for _, m in ipairs(models) do
                local dev = loadKindle(m[1])
                assert.are.equal(m[2], dev.model, m[1])
                assert.is_true(dev:isKindle())
                dev:init()
                assert.is_not_nil(dev.powerd, m[2])
                assert.is_not_nil(dev.input, m[2])
                assert.is_false(dev.canDeepSleep, m[2])
                -- Touch-capable models are OTA'd as kindle / kindlepw2 / kindlehf, the others as legacy
                local ota, ota_tool = dev:otaModel()
                assert.are.equal("kotasync", ota_tool)
                if dev:isTouchDevice() or dev.model == "Kindle4" then
                    assert.is_truthy(ota == "kindle" or ota == "kindlepw2" or ota == "kindlehf", m[2])
                else
                    assert.are.equal("kindle-legacy", ota, m[2])
                end
            end
        end)

        it("refuses unknown serial numbers", function()
            assert.has_error(function() loadKindle("B0ZZXXXX") end, "unknown Kindle model: B0ZZXX")
            assert.has_error(function() loadKindle("G00ZZZXX") end, "unknown Kindle model: G00ZZZ")
        end)

        it("returns nothing when /proc/usid can't be read (not a Kindle)", function()
            io.open = function(filename, mode)
                if filename == "/proc/usid" then return nil end
                return iopen(filename, mode)
            end
            package.loaded["device/kindle/device"] = nil
            local ok, dev = pcall(require, "device/kindle/device")
            io.open = iopen
            assert.is_true(ok)
            assert.is_true(dev) -- require's placeholder for a module returning nothing
        end)

        it("otaModel tells hardfp, Wario+ and older boards apart", function()
            local util = require("util")
            local dev = loadKindle("G000G1XX")
            dev:init()
            stub(util, "pathExists")
            util.pathExists.returns(true)
            assert.are.equal("kindlehf", (dev:otaModel()))
            util.pathExists.returns(false)
            io.lines = function(path)
                if path == "/proc/cpuinfo" then
                    local lines = { "processor : 0", "Hardware        : Freescale i.MX 6SoloLite based Wario Board" }
                    local i = 0
                    return function() i = i + 1; return lines[i] end
                end
                return ilines(path)
            end
            assert.are.equal("kindlepw2", (dev:otaModel()))
            io.lines = function(path)
                if path == "/proc/cpuinfo" then
                    local lines = { "Hardware        : Freescale MX50 Yoshi Board" }
                    local i = 0
                    return function() i = i + 1; return lines[i] end
                end
                return ilines(path)
            end
            assert.are.equal("kindle", (dev:otaModel()))
            io.lines = function(path)
                if path == "/proc/cpuinfo" then
                    return function() return nil end
                end
                return ilines(path)
            end
            assert.are.equal("kindle", (dev:otaModel()))
            io.lines = ilines
            util.pathExists:revert()
        end)
    end)

    describe("Special Offers", function()
        it("is detected from the loaded blanket modules", function()
            lipc_props["com.lab126.blanket.load"] = "screensaver ad_screensaver splash"
            local dev = loadKindle("G000G1XX")
            assert.is_true(dev.isSpecialOffers)
            assert.is_false(dev:supportsScreensaver())

            lipc_props["com.lab126.blanket.load"] = "screensaver splash"
            dev = loadKindle("G000G1XX")
            assert.is_false(dev.isSpecialOffers)
            assert.is_true(dev:supportsScreensaver())
        end)

        it("is assumed when lipc is unusable (safest: let the system show its screensaver)", function()
            local dev = loadKindle("G000G1XX", { lipc = false })
            assert.is_true(dev.isSpecialOffers)
            lipc_init_fails = true
            dev = loadKindle("G000G1XX")
            assert.is_true(dev.isSpecialOffers)
            lipc_init_fails = false
            lipc_props["com.lab126.blanket.load"] = nil
            dev = loadKindle("G000G1XX")
            assert.is_true(dev.isSpecialOffers)
        end)
    end)

    describe("suspend / resume sequencing", function()
        local dev, Screensaver, UIManager

        before_each(function()
            lipc_props["com.lab126.blanket.load"] = "screensaver"
            dev = loadKindle("G000G1XX")
            dev:init()
            UIManager = require("ui/uimanager")
            dev:UIManagerReady(UIManager)
            dev.powerd:UIManagerReadyHW(UIManager)
            Screensaver = require("ui/screensaver")
            stub(Screensaver, "setup")
            stub(Screensaver, "show", function() dev.screen_saver_mode = true end)
            stub(Screensaver, "close", function() dev.screen_saver_mode = false; return true end)
            stub(dev.powerd, "beforeSuspend")
            stub(dev.powerd, "afterResume")
            stub(UIManager, "nextTick")
            stub(UIManager, "scheduleIn")
        end)

        after_each(function()
            Screensaver.setup:revert()
            Screensaver.show:revert()
            Screensaver.close:revert()
            UIManager.nextTick:revert()
            UIManager.scheduleIn:revert()
        end)

        it("shows our screensaver once, then suspends; closes it and redraws on wakeup", function()
            dev:intoScreenSaver(2)
            assert.stub(Screensaver.show).was.called(1)
            assert.stub(dev.powerd.beforeSuspend).was.called(1)
            -- A stray second goingToScreenSaver (e.g. the hall sensor right after the button)
            -- doesn't show it twice.
            dev:intoScreenSaver(4)
            assert.stub(Screensaver.show).was.called(1)
            assert.stub(dev.powerd.beforeSuspend).was.called(2)

            dev:outofScreenSaver(1)
            assert.stub(Screensaver.close).was.called(1)
            assert.stub(UIManager.nextTick).was.called(1)
            assert.stub(dev.powerd.afterResume).was.called(1)
            -- A stray second outOfScreenSaver doesn't close anything.
            dev:outofScreenSaver(6)
            assert.stub(Screensaver.close).was.called(1)
            assert.stub(dev.powerd.afterResume).was.called(2)
            dev:exitingScreenSaver()
            dev:intoScreenSaver(nil) -- unknown source
            dev:outofScreenSaver(99)
        end)

        it("after hibernation, also refreshes the bottom of the screen (the 'waking up' banner)", function()
            dev.canDeepSleep = true
            dev.hibernationDelay = 3600
            dev.last_suspend_time = require("ui/time").s(2 * 3600)
            local attributes = lfs.attributes
            stub(lfs, "attributes", function(path, what)
                if path == "/var/local/system/powerd/hibernate_session_tracker" then
                    if what == "mode" then return "file" end
                    if what == "modification" then return os.time() - 10 end
                end
                return attributes(path, what)
            end)
            dev:intoScreenSaver(2)
            dev:outofScreenSaver(1)
            assert.stub(UIManager.scheduleIn).was.called(1)
            assert.are.equal(1.5, UIManager.scheduleIn.calls[1].vals[2])
            -- Stale tracker (older than a minute): no extra refresh.
            lfs.attributes:revert()
            stub(lfs, "attributes", function(path, what)
                if path == "/var/local/system/powerd/hibernate_session_tracker" then
                    if what == "mode" then return "file" end
                    if what == "modification" then return os.time() - 3600 end
                end
                return attributes(path, what)
            end)
            dev:intoScreenSaver(2)
            dev:outofScreenSaver(1)
            assert.stub(UIManager.scheduleIn).was.called(1)
            lfs.attributes:revert()
        end)

        it("on Special Offers devices, lets the system show its screensaver and pauses/resumes awesome", function()
            dev.isSpecialOffers = true
            env.AWESOME_STOPPED = "yes"
            dev:intoScreenSaver(2)
            assert.stub(Screensaver.show).was.not_called()
            assert.is_true(dev.screen_saver_mode)
            assert.stub(os.execute).was.called_with("killall -CONT awesome")
            dev:outofScreenSaver(1)
            assert.is_false(dev.screen_saver_mode)
            assert.stub(os.execute).was.called_with("killall -STOP awesome")
            assert.stub(UIManager.scheduleIn).was.called(1)
            assert.are.equal(3, UIManager.scheduleIn.calls[1].vals[2])

            env.AWESOME_STOPPED = nil
            env.CVM_STOPPED = "yes"
            dev:intoScreenSaver(2)
            assert.stub(os.execute).was.called_with("killall -CONT cvm")
            dev:outofScreenSaver(1)
            assert.stub(os.execute).was.called_with("killall -STOP cvm")
        end)

        it("tracks the time spent in suspend", function()
            local time = require("ui/time")
            local now = time.s(1000)
            stub(time, "boottime_or_realtime_coarse", function() return now end)
            stub(dev.powerd, "readyToSuspend")
            stub(dev.powerd, "wakeupFromSuspend")
            dev.total_suspend_time = 0
            dev:readyToSuspend(5)
            assert.are.equal(5, dev.powerd.readyToSuspend.calls[1].vals[2])
            now = time.s(1600)
            dev:wakeupFromSuspend(42)
            assert.are.equal(42, dev.powerd.wakeupFromSuspend.calls[1].vals[2])
            assert.are.equal(time.s(600), dev.last_suspend_time)
            assert.are.equal(time.s(600), dev.total_suspend_time)
            time.boottime_or_realtime_coarse:revert()
        end)

        it("consumes queued power-management arguments in arrival order", function()
            local fake_ui = { event_handlers = {} }
            dev:UIManagerReady(fake_ui)
            dev:setEventHandlers(fake_ui)
            for event, method in pairs{
                IntoSS = "intoScreenSaver", OutOfSS = "outofScreenSaver",
                ReadyToSuspend = "readyToSuspend", WakeupFromSuspend = "wakeupFromSuspend",
            } do
                local received = {}
                stub(dev, method, function(_, argument) received[#received + 1] = argument end)
                dev.input.fake_event_args[event] = { 2, 4, 6 }
                for _ = 1, 3 do fake_ui.event_handlers[event](event) end
                assert.same({ 2, 4, 6 }, received)
                assert.same({}, dev.input.fake_event_args[event])
                dev[method]:revert()
            end
        end)

        it("wires the powerd lipc events to the right handlers, with their argument", function()
            local fake_ui = { event_handlers = {} }
            stub(dev, "intoScreenSaver")
            stub(dev, "outofScreenSaver")
            stub(dev, "wakeupFromSuspend")
            stub(dev, "readyToSuspend")
            stub(dev, "_beforeCharging")
            stub(dev, "_afterNotCharging")
            stub(dev.powerd, "toggleSuspend")
            dev:UIManagerReady(fake_ui)
            dev:setEventHandlers(fake_ui)
            local h = fake_ui.event_handlers
            table.insert(dev.input.fake_event_args.IntoSS, 2)
            h.IntoSS("IntoSS")
            assert.stub(dev.intoScreenSaver).was.called_with(dev, 2)
            table.insert(dev.input.fake_event_args.OutOfSS, 6)
            h.OutOfSS("OutOfSS")
            assert.stub(dev.outofScreenSaver).was.called_with(dev, 6)
            table.insert(dev.input.fake_event_args.ReadyToSuspend, 3)
            h.ReadyToSuspend("ReadyToSuspend")
            assert.stub(dev.readyToSuspend).was.called_with(dev, 3)
            table.insert(dev.input.fake_event_args.WakeupFromSuspend, 7)
            h.WakeupFromSuspend("WakeupFromSuspend")
            assert.stub(dev.wakeupFromSuspend).was.called_with(dev, 7)
            h.Suspend()
            assert.stub(dev.powerd.toggleSuspend).was.called(1)
            h.Charging()
            assert.stub(dev._beforeCharging).was.called(1)
            h.NotCharging()
            assert.stub(dev._afterNotCharging).was.called(1)
            h.ExitingSS()
            dev:UIManagerReady(UIManager)
        end)
    end)

    describe("KindlePowerD", function()
        local dev, powerd, UIManager

        local function make(serial, files)
            lipc_props["com.lab126.blanket.load"] = "screensaver"
            dev = initKindle(serial, { files = files })
            powerd = dev.powerd
            UIManager = require("ui/uimanager")
            powerd:UIManagerReadyHW(UIManager)
            return dev
        end

        it("maps the synthetic 'off' step on devices where lipc step 0 isn't off (<= PW3)", function()
            make("G000G1XX") -- PW3: !canTurnFrontlightOff
            assert.are.equal(25, powerd.fl_max)
            lipc_props["com.lab126.powerd.flIntensity"] = 10
            assert.are.equal(11, powerd:frontlightIntensityHW())
            -- lipc says 0, but the kernel says the light is on (set from the stock UI): report on.
            lipc_props["com.lab126.powerd.flIntensity"] = 0
            stub(powerd, "_readFLIntensity")
            powerd._readFLIntensity.returns(30)
            assert.are.equal(1, powerd:frontlightIntensityHW())
            powerd._readFLIntensity.returns(0)
            assert.are.equal(0, powerd:frontlightIntensityHW())
            assert.is_false(powerd:isFrontlightOnHW())
            powerd._readFLIntensity:revert()

            local writes = {}
            local ffiUtil = require("ffi/util")
            stub(ffiUtil, "writeToSysfs", function(v, f) table.insert(writes, { v, f }) end)
            powerd:setIntensityHW(5)
            assert.are.same({ 4 }, lipcSets("com.lab126.powerd.flIntensity"))
            assert.are.equal(0, #writes)
            powerd:setIntensityHW(0) -- really off: lipc 0 isn't off, so sysfs too
            assert.are.same({ 4, 0 }, lipcSets("com.lab126.powerd.flIntensity"))
            assert.are.same({ { 0, "/sys/class/backlight/max77696-bl/brightness" } }, writes)
            ffiUtil.writeToSysfs:revert()
        end)

        it("uses lipc as is on devices that can turn the light off, and falls back when lipc fails", function()
            make("G001Q0XX") -- PW5
            assert.are.equal(24, powerd.fl_max)
            lipc_props["com.lab126.powerd.flIntensity"] = 7
            assert.are.equal(7, powerd:frontlightIntensityHW())
            lipc_props["com.lab126.powerd.flIntensity"] = nil
            assert.are.equal(0, powerd:frontlightIntensityHW())
            powerd:setIntensityHW(0)
            assert.are.same({ 0 }, lipcSets("com.lab126.powerd.flIntensity"))
            -- Warmth
            lipc_props["com.lab126.powerd.currentAmberLevel"] = 24
            assert.are.equal(100, powerd:frontlightWarmthHW())
            lipc_props["com.lab126.powerd.currentAmberLevel"] = nil
            assert.are.equal(0, powerd:frontlightWarmthHW())
            powerd:setWarmthHW(12)
            assert.are.same({ 12 }, lipcSets("com.lab126.powerd.currentAmberLevel"))
        end)

        it("turnOnFrontlight from the off state goes to the lowest 'on' step", function()
            make("G001Q0XX")
            stub(powerd, "isFrontlightOn")
            powerd.isFrontlightOn.returns(false)
            stub(powerd, "setIntensity")
            powerd.fl_intensity = powerd.fl_min
            local done = spy.new(function() end)
            assert.is_true(powerd:turnOnFrontlight(done))
            assert.are.equal(1, powerd.setIntensity.calls[1].vals[2])
            assert.spy(done).was.called(1)
            powerd.fl_intensity = 12
            powerd:turnOnFrontlight()
            assert.are.equal(12, powerd.setIntensity.calls[2].vals[2])
            powerd.isFrontlightOn.returns(true)
            assert.is_false(powerd:turnOnFrontlight())
            powerd.isFrontlightOn:revert()
            powerd.setIntensity:revert()
        end)

        it("reads battery state from lipc, else sysfs, else gasgauge-info", function()
            make("G001Q0XX")
            lipc_props["com.lab126.powerd.battLevel"] = 77
            lipc_props["com.lab126.powerd.isCharging"] = 1
            assert.are.equal(77, powerd:getCapacityHW())
            assert.is_true(powerd:isChargingHW())
            lipc_props["com.lab126.powerd.isCharging"] = 0
            assert.is_false(powerd:isChargingHW())

            powerd.lipc_handle = nil
            stub(powerd, "read_int_file")
            powerd.read_int_file.returns(55)
            assert.are.equal(55, powerd:getCapacityHW())
            powerd.read_int_file.returns(1)
            assert.is_true(powerd:isChargingHW())
            powerd.read_int_file:revert()
            powerd.batt_capacity_file = nil
            local popen = io.popen
            io.popen = function(cmd)
                assert.are.equal("gasgauge-info -c 2>/dev/null", cmd)
                return { read = function() return 42 end, close = function() end }
            end
            assert.are.equal(42, powerd:getCapacityHW())
            io.popen = function() return { read = function() return nil end, close = function() end } end
            assert.are.equal(0, powerd:getCapacityHW())
            io.popen = function() return nil end
            assert.are.equal(0, powerd:getCapacityHW())
            io.popen = popen

            stub(powerd, "read_str_file")
            powerd.read_str_file.returns("Full")
            assert.is_true(powerd:isChargedHW())
            powerd.batt_status_file = nil
            assert.is_false(powerd:isChargedHW())
            powerd.read_str_file:revert()
        end)

        it("toggles suspend and resets the screensaver timeout through lipc, or the CLI tools", function()
            make("G001Q0XX")
            powerd:toggleSuspend()
            assert.are.same({ 1 }, lipcSets("com.lab126.powerd.powerButton"))
            powerd:resetT1Timeout()
            assert.are.same({ 1 }, lipcSets("com.lab126.powerd.touchScreenSaverTimeout"))
            powerd.lipc_handle = nil
            powerd:toggleSuspend()
            assert.stub(os.execute).was.called_with("powerd_test -p")
            powerd:resetT1Timeout()
            assert.stub(os.execute).was.called_with("lipc-set-prop -i com.lab126.powerd touchScreenSaverTimeout 1")
            assert.is_nil(powerd:getPowerdState())
            powerd:setRtcWakeup(10) -- no lipc: nothing to do
        end)

        it("schedules the RTC wakeup on ReadyToSuspend, drops past alarms, and checks the wakeup reason", function()
            make("G001Q0XX")
            local wm = dev.wakeup_mgr
            assert.is_not_nil(wm)
            stub(wm, "isWakeupAlarmScheduled")
            stub(wm, "getWakeupAlarmEpoch")
            stub(wm, "removeTasks")
            stub(wm, "wakeupAction")
            wm.isWakeupAlarmScheduled.returns(true)
            wm.getWakeupAlarmEpoch.returns(os.time() + 600)
            powerd:readyToSuspend(5)
            local rtc = lipcSets("com.lab126.powerd.rtcWakeup")
            assert.are.equal(1, #rtc)
            assert.is_true(rtc[1] >= 599 and rtc[1] <= 600)
            local past = os.time() - 10
            wm.getWakeupAlarmEpoch.returns(past)
            powerd:readyToSuspend(5)
            assert.stub(wm.removeTasks).was.called_with(wm, past)
            assert.are.equal(1, #lipcSets("com.lab126.powerd.rtcWakeup"))
            wm.isWakeupAlarmScheduled.returns(false)
            powerd:readyToSuspend(5)
            assert.are.equal(1, #lipcSets("com.lab126.powerd.rtcWakeup"))

            stub(UIManager, "scheduleIn")
            powerd:wakeupFromSuspend(0)
            assert.stub(UIManager.scheduleIn).was.called_with(UIManager, 15, powerd.checkUnexpectedWakeup, powerd)
            UIManager.scheduleIn:revert()

            -- Woken by the user (powerd went active): nothing to do.
            lipc_props["com.lab126.powerd.state"] = "active"
            powerd:checkUnexpectedWakeup()
            assert.stub(wm.wakeupAction).was.not_called()
            -- Still in screensaver: run the scheduled action if it's ours.
            lipc_props["com.lab126.powerd.state"] = "screenSaver"
            wm.isWakeupAlarmScheduled.returns(true)
            wm.wakeupAction.returns(true)
            powerd:checkUnexpectedWakeup()
            assert.stub(wm.wakeupAction).was.called_with(wm, 90)
            wm.isWakeupAlarmScheduled.returns(false)
            lipc_props["com.lab126.powerd.state"] = "suspended"
            powerd:checkUnexpectedWakeup()
            assert.stub(wm.wakeupAction).was.called(1)
        end)

        it("restores the frontlight state after resume, losing the race on purpose", function()
            make("G001Q0XX")
            stub(dev, "_afterResume")
            stub(UIManager, "tickAfterNext")
            stub(powerd, "isFrontlightOn")
            stub(powerd, "invalidateCapacityCache")
            stub(powerd, "turnOnFrontlightHW")
            stub(powerd, "turnOffFrontlightHW")
            powerd.isFrontlightOn.returns(true)
            powerd:afterResume()
            assert.stub(dev._afterResume).was.called(1)
            assert.stub(powerd.invalidateCapacityCache).was.called(1)
            UIManager.tickAfterNext.calls[1].vals[2]()
            assert.stub(powerd.turnOnFrontlightHW).was.called(1)
            powerd.isFrontlightOn.returns(false)
            powerd:afterResume()
            UIManager.tickAfterNext.calls[2].vals[2]()
            assert.stub(powerd.turnOffFrontlightHW).was.called(1)
            stub(dev, "_beforeSuspend")
            powerd:beforeSuspend()
            assert.stub(dev._beforeSuspend).was.called(1)
            UIManager.tickAfterNext:revert()
            -- No frontlight: nothing to restore
            dev.hasFrontlight = function() return false end
            powerd:afterResume()
            assert.are.equal(0, powerd:frontlightIntensityHW())
        end)

        it("handles the hall effect sensor setting", function()
            make("G001Q0XX")
            powerd.hall_file = "/tmp/koreader-test-hall"
            assert.is_true(powerd:hasHallSensor())
            local ffiUtil = require("ffi/util")
            stub(ffiUtil, "writeToSysfs")
            stub(powerd, "read_int_file")
            powerd.read_int_file.returns(1)
            assert.is_true(powerd:isHallSensorEnabled())
            powerd:onToggleHallSensor() -- flip: on -> off
            assert.stub(ffiUtil.writeToSysfs).was.called_with(0, "/tmp/koreader-test-hall")
            assert.is_false(G_reader_settings:readSetting("kindle_hall_effect_sensor_enabled"))
            powerd:onToggleHallSensor(true)
            assert.stub(ffiUtil.writeToSysfs).was.called_with(1, "/tmp/koreader-test-hall")
            assert.is_true(G_reader_settings:readSetting("kindle_hall_effect_sensor_enabled"))
            ffiUtil.writeToSysfs:revert()
            powerd.read_int_file:revert()
            G_reader_settings:delSetting("kindle_hall_effect_sensor_enabled")
            powerd:__gc()
            assert.is_nil(powerd.lipc_handle)
        end)

        it("reports the aux battery of the Oasis 2/3 cover", function()
            make("G0011LXX") -- Oasis 3
            if not dev:hasAuxBattery() then return end
            stub(powerd, "read_str_file")
            stub(powerd, "unchecked_read_int_file")
            powerd.unchecked_read_int_file.returns(64)
            assert.are.equal(64, powerd:getAuxCapacityHW())
            powerd.read_str_file.returns(nil)
            assert.is_false(powerd:isAuxBatteryConnectedHW())
            powerd.read_str_file.returns("Charging")
            assert.is_true(powerd:isAuxBatteryConnectedHW())
            assert.is_true(powerd:isAuxChargingHW())
            assert.is_false(powerd:isAuxChargedHW())
            powerd.read_str_file.returns("Full")
            assert.is_true(powerd:isAuxChargedHW())
            powerd.read_str_file.returns("Discharging")
            assert.is_false(powerd:isAuxChargingHW())
        end)

        it("has no wakeup manager without lipc or on Special Offers devices", function()
            lipc_props["com.lab126.blanket.load"] = "ad_screensaver"
            local so = initKindle("G001Q0XX")
            assert.is_nil(so.powerd.lipc_handle and so.wakeup_mgr and nil)
            so.powerd:readyToSuspend(1) -- the dummy implementations
            so.powerd:wakeupFromSuspend(1)
        end)
    end)

    describe("Wi-Fi through lipc", function()
        local dev, NetworkMgr, UIManager

        local function loadNetworkMgr(serial, opts)
            lipc_props["com.lab126.blanket.load"] = "screensaver"
            dev = loadKindle(serial or "G001Q0XX", opts)
            UIManager = require("ui/uimanager")
            dev:UIManagerReady(UIManager)
            NetworkMgr = { reconnectOrShowNetworkMenu = spy.new(function() return true end),
                           sysfsWifiOn = function() end, ifHasAnAddress = function() end }
            dev:initNetworkManager(NetworkMgr)
            return NetworkMgr
        end

        it("turns Wi-Fi on thoroughly (wireless + wifid), then scans/connects", function()
            loadNetworkMgr()
            local cb = function() end
            assert.is_true(NetworkMgr:turnOnWifi(cb, true))
            assert.are.same({ 1 }, lipcSets("com.lab126.cmd.wirelessEnable"))
            assert.are.same({ 1 }, lipcSets("com.lab126.wifid.enable"))
            assert.spy(NetworkMgr.reconnectOrShowNetworkMenu).was.called_with(NetworkMgr, cb, true)
            stub(UIManager, "scheduleIn")
            NetworkMgr:turnOffWifi(cb)
            assert.are.same({ 1, 0 }, lipcSets("com.lab126.wifid.enable"))
            assert.are.same({ 1, 0 }, lipcSets("com.lab126.cmd.wirelessEnable"))
            assert.stub(UIManager.scheduleIn).was.called_with(UIManager, 2, cb)
            NetworkMgr:turnOffWifi()
            assert.stub(UIManager.scheduleIn).was.called(1)
            UIManager.scheduleIn:revert()
            NetworkMgr:restoreWifiAsync()
            assert.are.same({ 1, 0, 0, 1 }, lipcSets("com.lab126.wifid.enable"))
            assert.are.equal("wlan0", NetworkMgr:getNetworkInterfaceName())
            assert.are.equal(NetworkMgr.sysfsWifiOn, NetworkMgr.isWifiOn)
            assert.are.equal(NetworkMgr.ifHasAnAddress, NetworkMgr.isConnected)
        end)

        it("without liblipclua (FW < 5), falls back to lipc-set-prop and no interactive UI", function()
            loadNetworkMgr(nil, { lipc = false })
            local cb = spy.new(function() end)
            NetworkMgr:turnOnWifi(cb)
            assert.spy(cb).was.called(1)
            assert.spy(NetworkMgr.reconnectOrShowNetworkMenu).was.not_called()
            assert.stub(os.execute).was.called_with("lipc-set-prop -i com.lab126.wan enable 0")
            assert.stub(os.execute).was.called_with("lipc-set-prop -i com.lab126.wifid enable 1")
            NetworkMgr:authenticateNetwork({ ssid = "Home" }) -- no lipc: nothing happens
            NetworkMgr:turnOnWifi()
        end)

        it("asks wifid to connect to the chosen network", function()
            loadNetworkMgr()
            assert.is_true(NetworkMgr:authenticateNetwork({ ssid = "Home" }))
            assert.are.same({ "wifi:Home" }, lipcSets("com.lab126.cmd.ensureConnection"))
        end)

        it("saves WPA and open profiles (never sharing the password with Amazon)", function()
            loadNetworkMgr()
            NetworkMgr:saveNetwork({ ssid = "Home", flags = "[WPA2-PSK-CCMP]", password = "pw" })
            NetworkMgr:saveNetwork({ ssid = "Cafe", flags = "[ESS]" })
            local created = lipcSets("com.lab126.wifid.createProfile")
            assert.are.same({ essid = "Home", secured = "yes", psk = "pw", store_nw_user_pref = 0 }, created[1])
            assert.are.same({ essid = "Cafe", secured = "no" }, created[2])
            hash_fail.createProfile = true
            NetworkMgr:saveNetwork({ ssid = "Fail", flags = "" }) -- logged, doesn't throw
        end)

        it("reports the current network, or none", function()
            loadNetworkMgr()
            hash_props.currentEssid = { { essid = "Home", netid = 3 } }
            assert.are.same({ ssid = "Home" }, NetworkMgr:getCurrentNetwork())
            hash_fail.currentEssid = true
            assert.is_nil(NetworkMgr:getCurrentNetwork())
            lipc_init_fails = true
            assert.is_nil(NetworkMgr:getCurrentNetwork())
        end)

        it("scans: waits for wifid to be idle, then lists networks with signal, known passwords and the connected one", function()
            loadNetworkMgr()
            lipc_props["com.lab126.wifid.scanState"] = { "scanning", "idle" }
            lipc_props["com.lab126.wifid.cmState"] = "READY"
            hash_props.scanList = {
                { essid = "Home", netid = 3, known = "yes", signal = 5, signal_max = 5, key_mgmt = "wpa2-psk" },
                { essid = "Old", known = "yes", signal = 2, signal_max = 5, key_mgmt = "wpa-psk" },
                { essid = "Cafe", netid = -1, known = "no", signal = 1, signal_max = 5, key_mgmt = "none" },
                { essid = "", netid = -1, known = "no", signal = 3, signal_max = 5, key_mgmt = "none" },
            }
            hash_props.profileData = {
                { essid = "Home", netid = 3, psk = "homepw" },
                { essid = "Old", psk = "oldpw" }, -- older FW: no netid, matched by essid
            }
            hash_props.currentEssid = { { essid = "Home", netid = 3 } }
            local list, err = NetworkMgr:getNetworkList()
            assert.is_nil(err)
            assert.are.same({ "" }, lipcSets("com.lab126.wifid.scan"))
            assert.are.equal(4, #list)
            assert.are.same({ signal_level = "5/5", signal_quality = 81, connected = true, flags = "wpa2-psk",
                              ssid = "Home", password = "homepw" }, list[1])
            assert.are.equal("oldpw", list[2].password)
            assert.are.equal(6, list[2].signal_quality)
            assert.is_false(list[3].connected)
            assert.is_nil(list[3].password)
            assert.is_false(list[4].ssid) -- hidden network
        end)

        it("scans: when already connected, only lists the current network", function()
            loadNetworkMgr()
            lipc_props["com.lab126.wifid.scanState"] = "idle"
            lipc_props["com.lab126.wifid.cmState"] = "CONNECTED"
            hash_props.currentEssid = { { essid = "Home", netid = 3, signal = 4, signal_max = 5, known = "no" } }
            hash_props.profileData = {}
            local list = NetworkMgr:getNetworkList()
            assert.are.equal(1, #list)
            assert.are.equal("Home", list[1].ssid)
            assert.is_true(list[1].connected)
        end)

        it("scans: survives lipc failures (cmState, scanList, empty results)", function()
            loadNetworkMgr()
            lipc_props["com.lab126.wifid.scanState"] = "idle"
            lipc_fail.cmState = true
            hash_props.scanList = {}
            hash_props.profileData = {}
            hash_props.currentEssid = {}
            assert.are.same({}, NetworkMgr:getNetworkList())
            hash_fail.scanList = true
            assert.are.same({}, NetworkMgr:getNetworkList())
            hash_fail.scanList = nil
            hash_props.scanList = "nil"
            assert.are.same({}, NetworkMgr:getNetworkList())
            hash_props.scanList = nil -- to_table() returns nil
            assert.are.same({}, NetworkMgr:getNetworkList())
            -- profileData failure while listing: no saved passwords
            hash_props.scanList = { { essid = "Home", netid = 1, known = "yes", signal = 3, signal_max = 5 } }
            hash_fail.profileData = true
            local list = NetworkMgr:getNetworkList()
            assert.is_nil(list[1].password)
        end)

        it("scans: reports failures to talk to wifid", function()
            loadNetworkMgr()
            lipc_fail.scanState = true
            local list, err = NetworkMgr:getNetworkList()
            assert.is_nil(list)
            assert.are.equal("Scanning for Wi-Fi networks timed out", err)
            lipc_fail.scanState = nil
            lipc_init_fails = true
            list, err = NetworkMgr:getNetworkList()
            assert.is_nil(list)
            assert.are.equal("Unable to communicate with the Wi-Fi backend", err)
        end)
    end)

    describe("helpers", function()
        local dev

        before_each(function()
            lipc_props["com.lab126.blanket.load"] = "screensaver"
            dev = loadKindle("G001Q0XX")
            dev:init()
        end)

        it("maps the ambient light sensor to 5 levels", function()
            local expected = { [5] = 0, [50] = 1, [150] = 2, [1000] = 3, [40000] = 4 }
            for lux, level in pairs(expected) do
                lipc_props["com.lab126.powerd.alsLux"] = lux
                assert.are.equal(level, dev:ambientBrightnessLevel(), lux)
            end
            lipc_props["com.lab126.powerd.alsLux"] = nil
            assert.are.equal(0, dev:ambientBrightnessLevel())
            lipc_init_fails = true
            assert.are.equal(0, dev:ambientBrightnessLevel())
            package.loaded["liblipclua"] = nil
            package.preload["liblipclua"] = function() error("no liblipclua") end
            assert.are.equal(0, dev:ambientBrightnessLevel())
        end)

        it("sets the date through setdate when available, else date + hwclock", function()
            assert.is_true(dev:setDateTime(2026, 1, 2, nil, nil)) -- nothing to do
            local attributes = lfs.attributes
            stub(lfs, "attributes", function(path, what)
                if path == "/usr/sbin/setdate" then return "file" end
                return attributes(path, what)
            end)
            assert.is_true(dev:setDateTime(2026, 10, 27, 12, 30, 0))
            local cmd = os.execute.calls[#os.execute.calls].vals[1]
            local epoch = os.time{ year = 2026, month = 10, day = 27, hour = 12, min = 30, sec = 0 }
            assert.are.equal(string.format("/usr/sbin/setdate '%d'", epoch), cmd)
            lfs.attributes:revert()
            stub(lfs, "attributes", function(path, what)
                if path == "/usr/sbin/setdate" then return nil end
                return attributes(path, what)
            end)
            assert.is_true(dev:setDateTime(2026, 10, 27, 12, 30, 5))
            assert.stub(os.execute).was.called_with("date -s '2026-10-27 12:30:5' '+%Y-%m-%d %H:%M:%S'")
            assert.stub(os.execute).was.called_with("hwclock -u -w")
            assert.is_true(dev:setDateTime(nil, nil, nil, 7, 5))
            assert.stub(os.execute).was.called_with("date -s '7:5' '+%H:%M'")
            os.execute.returns(1)
            assert.is_false(dev:setDateTime(nil, nil, nil, 7, 5))
            lfs.attributes:revert()
        end)

        it("toggles key repeat by filtering KEY_REPEAT events", function()
            dev.key_repeat = ffi.new("unsigned int[?]", C.REP_CNT)
            assert.is_true(dev:toggleKeyRepeat(false))
            assert.are.equal(0, dev.key_repeat[C.REP_DELAY])
            local ev = { type = C.EV_KEY, value = 2 }
            dev.input:eventAdjustHook(ev)
            assert.are.equal(-1, ev.value)
            local press = { type = C.EV_KEY, value = 1 }
            dev.input:eventAdjustHook(press)
            assert.are.equal(1, press.value)
            assert.is_true(dev:toggleKeyRepeat(true))
            assert.are.equal(400, dev.key_repeat[C.REP_DELAY])
            assert.are.equal(120, dev.key_repeat[C.REP_PERIOD])
            ev = { type = C.EV_KEY, value = 2 }
            dev.input:eventAdjustHook(ev)
            assert.are.equal(2, ev.value)
        end)

        it("compares the active startup script with ours", function()
            local md5 = require("ffi/MD5")
            stub(md5, "sumFile", function(path) return path == "koreader.sh" and "a" or "b" end)
            assert.is_false(dev:isStartupScriptUpToDate())
            md5.sumFile:revert()
            stub(md5, "sumFile", function() return "same" end)
            assert.is_true(dev:isStartupScriptUpToDate())
            md5.sumFile:revert()
            dev:usbPlugIn()
            dev:usbPlugOut()
        end)

        it("detects hibernation support and its delay from appreg.db", function()
            local attributes = lfs.attributes
            stub(lfs, "attributes", function(path, what)
                if path == "/sys/devices/platform/falconblk/uevent" then return "file" end
                return attributes(path, what)
            end)
            local SQ3 = require("lua-ljsqlite3/init")
            local rows
            stub(SQ3, "open", function()
                return {
                    rowexec = function(_, sql)
                        for pattern, v in pairs(rows) do
                            if sql:find(pattern, 1, true) then return v end
                        end
                    end,
                    close = function() end,
                }
            end)
            rows = { ["hibernate.enabled"] = 0, ["'dcc' AND name = 'hibernate.s2h.rtc.secs'"] = "1800" }
            dev:init()
            assert.is_true(dev.canDeepSleep)
            assert.are.equal(1800, dev.hibernationDelay)
            rows = { ["hibernate.enabled"] = 0 }
            dev:init()
            assert.are.equal(3600, dev.hibernationDelay)
            rows = { ["hibernate.enabled"] = 1 }
            dev:init()
            assert.is_false(dev.canDeepSleep)
            SQ3.open:revert()
            lfs.attributes:revert()
        end)

        it("opens the auto-detected input devices, flagging frame taps and rotation devices", function()
            local fbink_input = {}
            local scans = 0
            stub(ffi, "loadlib", function(name)
                if name == "fbink_input" then return fbink_input end
                error("unexpected loadlib " .. tostring(name))
            end)
            local free = C.free
            local devices
            fbink_input.fbink_input_scan = function(_, _, _, count)
                scans = scans + 1
                count[0] = #devices
                local arr = {}
                for i, d in ipairs(devices) do arr[i - 1] = d end
                return arr
            end
            -- C.free can't take our Lua table: swap the whole C namespace lookup.
            local fake_C = setmetatable({ free = function() end }, { __index = C })
            local kindle_mod = package.loaded["device/kindle/device"]
            local getupvalue = debug.getupvalue
            local setupvalue = debug.setupvalue
            local idx
            for i = 1, 60 do
                local n = getupvalue(dev.openInputDevices, i)
                if n == "C" then idx = i break end
                if n == nil then break end
            end
            if not idx then
                ffi.loadlib:revert()
                return -- nothing to patch (C is a global upvalue elsewhere)
            end
            setupvalue(dev.openInputDevices, idx, fake_C)
            devices = {
                { matched = true, fd = 10, path = "/dev/input/event1", name = "touch", type = 0 },
                { matched = true, fd = 11, path = "/dev/input/event2", name = "frame", type = C.INPUT_KINDLE_FRAME_TAP },
                { matched = false, fd = 12, path = "/dev/input/event3", name = "nope", type = 0 },
            }
            stub(ffi, "string", function(s) return s end)
            dev.hasGSensor = function() return true end
            dev:openInputDevices()
            ffi.string:revert()
            assert.is_true(dev:hasFancyTaps())
            assert.are.equal(2, scans)
            assert.is_true(dev.input.rotation_fds[10])
            assert.is_true(dev.input.rotation_fds[11])
            assert.is_nil(dev.input.rotation_fds[12])
            setupvalue(dev.openInputDevices, idx, C)
            ffi.loadlib:revert()
            assert.is_not_nil(kindle_mod)
            assert.is_not_nil(free)
        end)
    end)
end)
