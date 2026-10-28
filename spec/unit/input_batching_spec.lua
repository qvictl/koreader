-- Input: evdev batching, touch protocols, key handling, timers & waitEvent, input inhibition.
--
-- Every test builds its own Input instance on top of a fake device & a scripted input backend
-- (Input:init keeps a pre-set `input` backend, c.f., "stubbed by the testsuite"), so nothing leaks
-- into the global Device.input used by the rest of the testsuite.
describe("Input batching", function()
    local Input, Event, UIManager, MockTime, time, framebuffer, ffi, C
    local T0 -- event timestamps are relative to this (set in setup, once time is loaded)

    setup(function()
        require("commonrequire")
        ffi = require("ffi")
        C = ffi.C
        require("ffi/posix_h")
        require("ffi/linux_input_h")
        Input = require("device/input")
        Event = require("ui/event")
        UIManager = require("ui/uimanager")
        time = require("ui/time")
        framebuffer = require("ffi/framebuffer")
        MockTime = require("mock_time")
        T0 = time.s(1000)
    end)

    -- Scripted backend: each waitForEvent call pops the next result from the queue
    -- ({ true, { evs } }, { false, errno[, timerfd] } or { nil }); an empty queue times out.
    local function newBackend()
        local backend = { queue = {}, calls = {}, timers = {}, cleared = {} }
        function backend.waitForEvent(sec, usec)
            table.insert(backend.calls, { sec = sec, usec = usec })
            local r = table.remove(backend.queue, 1)
            if not r then
                return false, C.ETIME
            end
            if r.before then r.before() end
            return r[1], r[2], r[3]
        end
        return backend
    end

    local function newDevice(opts)
        local rotation = opts.rotation or framebuffer.DEVICE_ROTATED_UPRIGHT
        local screen = {
            DEVICE_ROTATED_UPRIGHT = 0,
            DEVICE_ROTATED_CLOCKWISE = 1,
            DEVICE_ROTATED_UPSIDE_DOWN = 2,
            DEVICE_ROTATED_COUNTER_CLOCKWISE = 3,
            scaleByDPI = function(_, value) return value end,
            getRotationMode = function() return rotation end,
            setRotationMode = function(_, mode) rotation = mode end,
            getTouchRotation = function() return opts.touch_rotation or 0 end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        }
        return {
            screen = screen,
            key_repeat = opts.key_repeat,
            isSDL = function() return opts.sdl or false end,
            hasEinkScreen = function() return opts.eink ~= false end,
            isAlwaysFullscreen = function() return opts.always_fullscreen or false end,
            isGSensorLocked = function() return opts.gsensor_locked or false end,
        }
    end

    local function newInput(opts)
        opts = opts or {}
        local backend = opts.backend or newBackend()
        local inp = Input:new{
            device = newDevice(opts),
            input = backend,
            event_map = opts.event_map or {},
            event_map_adapter = opts.event_map_adapter,
            hw_text_layout = opts.hw_text_layout,
            pressure_event = opts.pressure_event,
            -- Instance-local keyboard state, so we never touch the shared class tables
            modifiers = {
                Alt = false, AltGr = false, Ctrl = false, Shift = false,
                Super = false, Sym = false, Meta = false, ScreenKB = false,
            },
            fake_event_args = { UsbDevicePlugIn = {}, UsbDevicePlugOut = {} },
            rotation_ignored_fds = {},
            disable_double_tap = opts.disable_double_tap ~= false,
        }
        local gd = inp.gesture_detector
        gd.active_contacts = {}
        gd.contact_count = 0
        gd.previous_tap = {}
        gd.clock_id = opts.clock_id or C.CLOCK_MONOTONIC
        return inp, backend
    end

    local function tv(ms)
        local sec, usec = time.split_s_us(T0 + time.ms(ms or 0))
        return { sec = sec, usec = usec }
    end
    local function abs(code, value) return { type = C.EV_ABS, code = code, value = value, time = tv(0) } end
    local function key(code, value, ms) return { type = C.EV_KEY, code = code, value = value, time = tv(ms) } end
    local function syn(ms, code) return { type = C.EV_SYN, code = code or C.SYN_REPORT, value = 0, time = tv(ms) } end
    -- A protocol B contact down in the current slot (a list of events, flattened by batch)
    local function contact(id, x, y)
        return { abs(C.ABS_MT_TRACKING_ID, id), abs(C.ABS_MT_POSITION_X, x), abs(C.ABS_MT_POSITION_Y, y) }
    end
    -- A single read() worth of events, as returned by the backend
    local function batch(...)
        local evs = {}
        for _, v in ipairs({...}) do
            if v.type then
                table.insert(evs, v)
            else
                for _, ev in ipairs(v) do
                    table.insert(evs, ev)
                end
            end
        end
        return { true, evs }
    end

    local function gestures(events)
        local t = {}
        for _, e in ipairs(events or {}) do
            if e.handler == "onGesture" then
                table.insert(t, e.args[1])
            end
        end
        return t
    end
    local function gesNames(events)
        local t = {}
        for _, g in ipairs(gestures(events)) do
            table.insert(t, g.ges)
        end
        return t
    end

    describe("touch frames", function()
        it("turns a whole tap batched in a single read into touch + tap", function()
            local inp, backend = newInput()
            table.insert(backend.queue, batch(
                contact(5, 100, 200), syn(0),
                abs(C.ABS_MT_TRACKING_ID, -1), syn(40)
            ))
            local evs = inp:waitEvent(T0, nil)
            assert.are.same({ "touch", "tap" }, gesNames(evs))
            local g = gestures(evs)
            assert.are.equal(100, g[2].pos.x)
            assert.are.equal(200, g[2].pos.y)
            assert.are.equal(T0 + time.ms(40), g[2].time)
            -- The tap cancelled the hold timer, nothing is left pending
            assert.are.equal(0, #inp.timer_callbacks)
            assert.are.equal(0, inp.gesture_detector.contact_count)
        end)

        it("only emits gestures on SYN_REPORT, not on SYN_DROPPED or SYN_MT_REPORT", function()
            local inp = newInput()
            for _, ev in ipairs(contact(1, 10, 20)) do
                assert.is_nil(inp:handleTouchEv(ev))
            end
            assert.is_nil(inp:handleTouchEv(syn(0, C.SYN_MT_REPORT)))
            assert.is_nil(inp:handleTouchEv(syn(0, C.SYN_DROPPED)))
            -- The frame is still pending...
            assert.are.equal(1, #inp.MTSlots)
            -- ...until the actual report
            local evs = inp:handleTouchEv(syn(5))
            assert.are.same({ "touch" }, gesNames(evs))
            assert.are.equal(0, #inp.MTSlots)
        end)

        it("handles a move-only frame without ABS_MT_SLOT/TRACKING_ID and reports a swipe", function()
            local inp, backend = newInput()
            table.insert(backend.queue, batch(contact(1, 100, 300), syn(0)))
            table.insert(backend.queue, batch(abs(C.ABS_MT_POSITION_Y, 100), syn(60)))
            table.insert(backend.queue, batch(abs(C.ABS_MT_TRACKING_ID, -1), syn(100)))
            assert.are.same({ "touch" }, gesNames(inp:waitEvent(T0, nil)))
            local pan = gestures(inp:waitEvent(T0, nil))[1]
            assert.are.equal("pan", pan.ges)
            assert.are.equal("north", pan.direction)
            local swipe = gestures(inp:waitEvent(T0, nil))[1]
            assert.are.equal("swipe", swipe.ges)
            assert.are.equal("north", swipe.direction)
            assert.are.equal(100, swipe.pos.x)
            assert.are.equal(300, swipe.pos.y)
        end)

        it("tracks two protocol B slots in one frame and releases them with TRACKING_ID -1", function()
            local inp, backend = newInput()
            table.insert(backend.queue, batch(
                abs(C.ABS_MT_SLOT, 0), contact(11, 100, 100),
                abs(C.ABS_MT_SLOT, 1), contact(12, 300, 100),
                syn(0)
            ))
            table.insert(backend.queue, batch(
                abs(C.ABS_MT_SLOT, 0), abs(C.ABS_MT_TRACKING_ID, -1),
                abs(C.ABS_MT_SLOT, 1), abs(C.ABS_MT_TRACKING_ID, -1),
                syn(50)
            ))
            assert.are.same({ "touch", "touch" }, gesNames(inp:waitEvent(T0, nil)))
            assert.are.equal(1, inp.cur_slot)
            local g = gestures(inp:waitEvent(T0, nil))
            assert.are.equal(1, #g)
            assert.are.equal("two_finger_tap", g[1].ges)
            assert.are.equal(200, g[1].pos.x)
            assert.are.equal(200, g[1].span)
            assert.are.equal(0, inp.gesture_detector.contact_count)
        end)

        it("drops hovering pen events reported through the pressure event", function()
            local inp = newInput({ pressure_event = C.ABS_MT_PRESSURE })
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 3))
            inp:handleTouchEv(abs(C.ABS_MT_TOOL_TYPE, Input.TOOL_TYPE_PEN))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_X, 10))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_Y, 10))
            inp:handleTouchEv(abs(C.ABS_MT_PRESSURE, 0))
            assert.are.equal(-1, inp:getCurrentMtSlotData("id"))
            -- No gesture for a hover
            assert.are.same({}, gesNames(inp:handleTouchEv(syn(0))))

            -- A finger with zero pressure is left alone
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 4))
            inp:handleTouchEv(abs(C.ABS_MT_TOOL_TYPE, Input.TOOL_TYPE_FINGER))
            inp:handleTouchEv(abs(C.ABS_MT_PRESSURE, 0))
            assert.are.equal(4, inp:getCurrentMtSlotData("id"))
        end)

        it("routes pen slots to the stylus callback and keeps fingers for gestures", function()
            local inp = newInput()
            local seen = {}
            inp:registerStylusCallback(function(_, slot)
                table.insert(seen, { slot = slot.slot, tool = slot.tool, x = slot.x })
                return true
            end)
            inp.stylus_highlighter_active = true
            inp:handleTouchEv(abs(C.ABS_MT_SLOT, 2))
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 9))
            inp:handleTouchEv(abs(C.ABS_MT_TOOL_TYPE, Input.TOOL_TYPE_PEN))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_X, 42))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_Y, 43))
            local evs = inp:handleTouchEv(syn(0))
            assert.are.same({}, gesNames(evs))
            assert.are.same({ { slot = 2, tool = Input.TOOL_TYPE_HIGHLIGHTER, x = 42 } }, seen)
            inp:unregisterStylusCallback()
            assert.is_nil(inp.stylus_callback)
        end)

        it("resetState drops in-flight contacts so a later lift is not a phantom tap", function()
            local inp = newInput()
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 1))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_X, 10))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_Y, 10))
            assert.are.same({ "touch" }, gesNames(inp:handleTouchEv(syn(0))))
            assert.are.equal(1, #inp.timer_callbacks)
            inp:handleTouchEv(abs(C.ABS_MT_SLOT, 1))
            inp:resetState()
            assert.are.equal(0, #inp.timer_callbacks)
            assert.are.equal(0, inp.gesture_detector.contact_count)
            assert.is_nil(inp.gesture_detector:getClockSource())
            assert.are.equal(inp.main_finger_slot, inp.cur_slot)
            assert.are.same({ [0] = { slot = 0 } }, inp.ev_slots)
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, -1))
            assert.are.same({}, gesNames(inp:handleTouchEv(syn(10))))
        end)
    end)

    describe("touch protocol variants", function()
        it("handles the Phoenix (protocol A) TOUCH_MAJOR lift", function()
            local inp, backend = newInput()
            inp.handleTouchEv = inp.handleTouchEvPhoenix
            table.insert(backend.queue, batch(
                abs(C.ABS_MT_TRACKING_ID, 1), abs(C.ABS_MT_TOUCH_MAJOR, 1), abs(C.ABS_MT_WIDTH_MAJOR, 1),
                abs(C.ABS_MT_POSITION_X, 1012), abs(C.ABS_MT_POSITION_Y, 914),
                syn(0, C.SYN_MT_REPORT), syn(0)
            ))
            table.insert(backend.queue, batch(
                abs(C.ABS_MT_TRACKING_ID, 1), abs(C.ABS_MT_TOUCH_MAJOR, 0), abs(C.ABS_MT_WIDTH_MAJOR, 0),
                abs(C.ABS_MT_POSITION_X, 1010), abs(C.ABS_MT_POSITION_Y, 918),
                syn(80, C.SYN_MT_REPORT), syn(80)
            ))
            local g = gestures(inp:waitEvent(T0, nil))
            assert.are.equal("touch", g[1].ges)
            assert.are.equal(1012, g[1].pos.x)
            g = gestures(inp:waitEvent(T0, nil))
            assert.are.equal("tap", g[1].ges)
            assert.are.equal(1010, g[1].pos.x)
            assert.are.equal(918, g[1].pos.y)
        end)

        it("handles the mixed panel + stylus protocol, honoring ABS_X/ABS_Y for pens only", function()
            local inp = newInput()
            inp.handleTouchEv = inp.handleMixedTouchEv
            inp:handleTouchEv(abs(C.ABS_MT_SLOT, 0))
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 1))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_X, 100))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_Y, 200))
            -- Single-touch emulation from the panel must not clobber the MT coordinates
            inp:handleTouchEv(abs(C.ABS_X, 1))
            inp:handleTouchEv(abs(C.ABS_Y, 2))
            local g = gestures(inp:handleTouchEv(syn(0)))
            assert.are.equal(100, g[1].pos.x)
            assert.are.equal(200, g[1].pos.y)

            inp:handleTouchEv(abs(C.ABS_MT_SLOT, 4))
            inp:setCurrentMtSlot("tool", Input.TOOL_TYPE_PEN)
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 4))
            inp:handleTouchEv(abs(C.ABS_X, 300))
            inp:handleTouchEv(abs(C.ABS_Y, 400))
            assert.are.equal(300, inp:getMtSlot(4).x)
            assert.are.equal(400, inp:getMtSlot(4).y)
        end)

        it("handles the snow protocol and lifts every contact on BTN_TOUCH 0", function()
            local inp, backend = newInput()
            inp.snow_protocol = true
            inp.handleTouchEv = inp.handleTouchEvSnow
            table.insert(backend.queue, batch(
                abs(C.ABS_MT_TRACKING_ID, 0), abs(C.ABS_MT_POSITION_X, 50), abs(C.ABS_MT_POSITION_Y, 60),
                -- Ignored on snow: they may belong to any contact
                abs(C.ABS_X, 999), abs(C.ABS_Y, 999),
                syn(0)
            ))
            -- The lift only comes as BTN_TOUCH:0, in a frame of its own
            table.insert(backend.queue, batch(key(C.BTN_TOUCH, 0), syn(40)))
            local g = gestures(inp:waitEvent(T0, nil))
            assert.are.equal("touch", g[1].ges)
            assert.are.equal(50, g[1].pos.x)
            g = gestures(inp:waitEvent(T0, nil))
            assert.are.equal(1, #g)
            assert.are.equal("tap", g[1].ges)
            assert.are.equal(50, g[1].pos.x)
            assert.are.equal(60, g[1].pos.y)
            assert.are.equal(0, inp.gesture_detector.contact_count)
        end)

        it("handles a snow BTN_TOUCH 0 batched with the last ABS events", function()
            local inp = newInput()
            inp.snow_protocol = true
            inp.handleTouchEv = inp.handleTouchEvSnow
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 0))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_X, 50))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_Y, 60))
            inp:handleTouchEv(syn(0))
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 0))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_X, 52))
            assert.is_nil(inp:handleKeyBoardEv(key(C.BTN_TOUCH, 0)))
            assert.are.equal(-1, inp:getMtSlot(0).id)
            local g = gestures(inp:handleTouchEv(syn(30)))
            assert.are.equal("tap", g[1].ges)
            assert.are.equal(52, g[1].pos.x)
            -- BTN_TOUCH:1 is swallowed too
            assert.is_nil(inp:handleKeyBoardEv(key(C.BTN_TOUCH, 1)))
        end)

        it("disables the snow quirks at runtime when the panel sends a sane TRACKING_ID -1", function()
            local inp = newInput()
            inp.snow_protocol = true
            inp.handleTouchEv = inp.handleTouchEvSnow
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, -1))
            assert.is_false(inp.snow_protocol)
            assert.are.equal(Input.handleTouchEv, inp.handleTouchEv)
        end)

        it("handles the Bookeen tracking id offset and TOUCH_MAJOR lifts", function()
            local inp = newInput()
            inp.handleTouchEv = inp.handleBookeenTouchEvent
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 1))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_X, 10))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_Y, 20))
            -- Tracking ids are 1-based on those
            assert.are.equal(0, inp.cur_slot)
            assert.are.same({ "touch" }, gesNames(inp:handleTouchEv(syn(0))))
            inp:handleTouchEv(abs(C.ABS_MT_TOUCH_MAJOR, 0))
            assert.are.same({ "tap" }, gesNames(inp:handleTouchEv(syn(30))))

            inp:handleTouchEv(abs(C.ABS_MT_SLOT, 0))
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 0))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_X, 11))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_Y, 21))
            assert.are.same({ "touch" }, gesNames(inp:handleTouchEv(syn(100))))
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, -1))
            local g = gestures(inp:handleTouchEv(syn(130)))
            assert.are.equal("tap", g[1].ges)
            assert.are.equal(11, g[1].pos.x)
        end)

        it("handles the legacy single-touch protocol, including the Kobo Mk3 axis swap", function()
            local inp = newInput()
            inp.handleTouchEv = inp.handleTouchEvLegacy
            inp:handleTouchEv(abs(C.ABS_X, 100))
            inp:handleTouchEv(abs(C.ABS_Y, 200))
            inp:handleTouchEv(abs(C.ABS_PRESSURE, 1))
            assert.are.same({ "touch" }, gesNames(inp:handleTouchEv(syn(0))))
            inp:handleTouchEv(abs(C.ABS_PRESSURE, 0))
            local g = gestures(inp:handleTouchEv(syn(30)))
            assert.are.equal("tap", g[1].ges)
            assert.are.equal(100, g[1].pos.x)

            inp.touch_kobo_mk3_protocol = true
            inp:handleTouchEv(abs(C.ABS_X, 100))
            inp:handleTouchEv(abs(C.ABS_Y, 200))
            inp:handleTouchEv(abs(C.ABS_PRESSURE, 1))
            inp:handleTouchEv(syn(500))
            inp:handleTouchEv(abs(C.ABS_PRESSURE, 0))
            g = gestures(inp:handleTouchEv(syn(530)))
            assert.are.equal("tap", g[1].ges)
            assert.are.equal(200, g[1].pos.x)
            assert.are.equal(499, g[1].pos.y)
        end)

        it("drops an empty second slot announced by BTN_TOOL_DOUBLETAP", function()
            local inp = newInput()
            inp:handleTouchEv(abs(C.ABS_MT_SLOT, 1))
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 7))
            assert.is_nil(inp:handleKeyBoardEv(key(C.BTN_TOOL_DOUBLETAP, 1)))
            assert.are.equal(-1, inp:getCurrentMtSlotData("id"))
            -- With coordinates, the slot is kept
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 8))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_X, 1))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_Y, 1))
            inp:handleKeyBoardEv(key(C.BTN_TOOL_DOUBLETAP, 1))
            assert.are.equal(8, inp:getCurrentMtSlotData("id"))
        end)

        it("drives the wacom pen slot from BTN_TOOL_* and BTN_TOUCH", function()
            local inp = newInput()
            inp.wacom_protocol = true
            local seen = {}
            inp:registerStylusCallback(function(_, slot)
                table.insert(seen, { id = slot.id, tool = slot.tool })
                return true
            end)
            -- Barrel button held: the pen acts as an eraser
            inp:handleKeyBoardEv(key(C.BTN_STYLUS, 1))
            assert.is_true(inp.stylus_eraser_active)
            inp:handleKeyBoardEv(key(C.BTN_TOOL_PEN, 1))
            assert.are.equal(inp.pen_slot, inp.cur_slot)
            inp:handleKeyBoardEv(key(C.BTN_TOUCH, 1))
            inp:handleTouchEv(abs(C.ABS_X, 10))
            inp:handleTouchEv(abs(C.ABS_Y, 20))
            inp:handleTouchEv(syn(0))
            inp:handleKeyBoardEv(key(C.BTN_TOUCH, 0))
            inp:handleTouchEv(syn(10))
            inp:handleKeyBoardEv(key(C.BTN_TOOL_PEN, 0))
            assert.are.equal(inp.main_finger_slot, inp.cur_slot)
            assert.are.equal(Input.TOOL_TYPE_FINGER, inp:getMtSlot(inp.pen_slot).tool)
            assert.are.same({
                { id = inp.pen_slot, tool = Input.TOOL_TYPE_ERASER },
                { id = -1, tool = Input.TOOL_TYPE_ERASER },
            }, seen)
            inp:handleKeyBoardEv(key(C.BTN_STYLUS2, 1))
            assert.is_true(inp.stylus_highlighter_active)

            -- BTN_TOUCH from a finger slot is left alone
            inp:handleKeyBoardEv(key(C.BTN_TOUCH, 1))
            assert.is_nil(inp:getMtSlot(inp.main_finger_slot).id)
        end)
    end)

    describe("coordinate transforms", function()
        local function absEv(code, value) return { type = C.EV_ABS, code = code, value = value } end

        it("switches, mirrors, scales & translates ABS axes", function()
            local inp = newInput()
            local ev = absEv(C.ABS_X, 10)
            inp:adjustABS_SwitchXY(ev)
            assert.are.equal(C.ABS_Y, ev.code)
            inp:adjustABS_SwitchXY(ev)
            assert.are.equal(C.ABS_X, ev.code)
            ev = absEv(C.ABS_MT_POSITION_X, 10)
            inp:adjustABS_SwitchXY(ev)
            assert.are.equal(C.ABS_MT_POSITION_Y, ev.code)
            inp:adjustABS_SwitchXY(ev)
            assert.are.equal(C.ABS_MT_POSITION_X, ev.code)

            ev = absEv(C.ABS_MT_POSITION_X, 10)
            inp:adjustABS_Scale(ev, { x = 2, y = 3 })
            assert.are.equal(20, ev.value)
            ev = absEv(C.ABS_Y, 10)
            inp:adjustABS_Scale(ev, { x = 2, y = 3 })
            assert.are.equal(30, ev.value)

            ev = absEv(C.ABS_X, 10)
            inp:adjustABS_MirrorX(ev, 599)
            assert.are.equal(589, ev.value)
            ev = absEv(C.ABS_MT_POSITION_Y, 10)
            inp:adjustABS_MirrorX(ev, 599)
            assert.are.equal(10, ev.value)
            inp:adjustABS_MirrorY(ev, 799)
            assert.are.equal(789, ev.value)

            ev = absEv(C.ABS_MT_POSITION_X, 10)
            inp:adjustABS_Translate(ev, { x = 5, y = -5 })
            assert.are.equal(15, ev.value)
            ev = absEv(C.ABS_Y, 10)
            inp:adjustABS_Translate(ev, { x = 5, y = -5 })
            assert.are.equal(5, ev.value)
        end)

        it("switches axes and mirrors the right one", function()
            local inp = newInput()
            local cases = {
                { "adjustABS_SwitchAxesAndMirrorX", C.ABS_X, C.ABS_Y, 10 },
                { "adjustABS_SwitchAxesAndMirrorX", C.ABS_Y, C.ABS_X, 589 },
                { "adjustABS_SwitchAxesAndMirrorX", C.ABS_MT_POSITION_X, C.ABS_MT_POSITION_Y, 10 },
                { "adjustABS_SwitchAxesAndMirrorX", C.ABS_MT_POSITION_Y, C.ABS_MT_POSITION_X, 589 },
                { "adjustABS_SwitchAxesAndMirrorY", C.ABS_X, C.ABS_Y, 589 },
                { "adjustABS_SwitchAxesAndMirrorY", C.ABS_Y, C.ABS_X, 10 },
                { "adjustABS_SwitchAxesAndMirrorY", C.ABS_MT_POSITION_X, C.ABS_MT_POSITION_Y, 589 },
                { "adjustABS_SwitchAxesAndMirrorY", C.ABS_MT_POSITION_Y, C.ABS_MT_POSITION_X, 10 },
            }
            for _, case in ipairs(cases) do
                local ev = absEv(case[2], 10)
                inp[case[1]](inp, ev, 599)
                assert.are.equal(case[3], ev.code)
                assert.are.equal(case[4], ev.value)
            end
            -- Other ABS codes are untouched
            local ev = absEv(C.ABS_PRESSURE, 10)
            inp:adjustABS_SwitchAxesAndMirrorX(ev, 599)
            inp:adjustABS_SwitchAxesAndMirrorY(ev, 599)
            assert.are.equal(C.ABS_PRESSURE, ev.code)
            assert.are.equal(10, ev.value)
        end)

        it("chains event adjust hooks on the raw events of a batch", function()
            local inp, backend = newInput()
            inp:registerEventAdjustHook(inp.adjustTouchSwitchAxesAndMirrorX, 599)
            inp:registerEventAdjustHook(inp.adjustTouchScale, { x = 2, y = 2 })
            inp:registerEventAdjustHook(inp.adjustTouchTranslate, { x = 1, y = 0 })
            table.insert(backend.queue, batch(contact(1, 100, 50), syn(0)))
            local g = gestures(inp:waitEvent(T0, nil))
            -- X <- (599 - 50) * 2 + 1 ; Y <- 100 * 2
            assert.are.equal(1099, g[1].pos.x)
            assert.are.equal(200, g[1].pos.y)
            -- Hooks only touch EV_ABS
            local ev = { type = C.EV_KEY, code = C.ABS_X, value = 3 }
            inp:eventAdjustHook(ev)
            assert.are.equal(3, ev.value)
        end)

        it("chains gesture adjust hooks before rotating gestures", function()
            local inp = newInput({ touch_rotation = 2 })
            local calls = {}
            inp:registerGestureAdjustHook(function(_, ges, tag) table.insert(calls, tag .. ":" .. ges.ges) end, "a")
            inp:registerGestureAdjustHook(function(_, ges, tag) table.insert(calls, tag .. ":" .. ges.ges) end, "b")
            inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 1))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_X, 100))
            inp:handleTouchEv(abs(C.ABS_MT_POSITION_Y, 200))
            local g = gestures(inp:handleTouchEv(syn(0)))
            assert.are.same({ "a:touch", "b:touch" }, calls)
            -- Upside down: 600 - 100, 800 - 200
            assert.are.equal(500, g[1].pos.x)
            assert.are.equal(600, g[1].pos.y)
        end)

        it("can disable the key rotation map", function()
            local inp = newInput({ rotation = framebuffer.DEVICE_ROTATED_CLOCKWISE, event_map = { [103] = "Up" } })
            assert.are.equal("Right", inp:handleKeyBoardEv(key(103, 1)).args[1].key)
            inp:disableRotationMap()
            assert.are.equal("Up", inp:handleKeyBoardEv(key(103, 1)).args[1].key)
        end)
    end)

    describe("keyboard", function()
        local event_map = {
            [30] = "A", [42] = "Shift", [56] = "Alt", [87] = "F11", [62] = "F4",
            [116] = "Power", [109] = "RPgFwd", [103] = "Up", [127] = "Sym", [190] = "ScreenKB",
            [59] = "SleepCover",
        }
        local function kbInput(opts)
            opts = opts or {}
            -- Input:init adds the synthetic events to the map: hand each instance its own copy
            local map = {}
            for k, v in pairs(event_map) do
                map[k] = v
            end
            opts.event_map = map
            return newInput(opts)
        end

        local saved = {}
        before_each(function()
            for _, name in ipairs({ "broadcastEvent", "sendEvent", "nextTick", "quit", "abort", "scheduleIn", "unschedule", "onRotation" }) do
                saved[name] = rawget(UIManager, name)
            end
        end)
        after_each(function()
            for name, fn in pairs(saved) do
                UIManager[name] = fn
            end
            saved = {}
        end)

        it("tracks modifiers across a batch of key events", function()
            local inp, backend = kbInput()
            table.insert(backend.queue, batch(key(42, 1), key(30, 1), key(30, 0), key(42, 0)))
            local evs = inp:waitEvent(T0, nil)
            assert.are.equal(2, #evs)
            assert.are.equal("onKeyPress", evs[1].handler)
            assert.are.equal("A", evs[1].args[1].key)
            assert.is_true(evs[1].args[1].Shift)
            assert.are.equal("onKeyRelease", evs[2].handler)
            assert.is_false(inp.modifiers.Shift)
            -- Unknown keys are dropped
            assert.is_nil(inp:handleKeyBoardEv(key(999, 1)))
        end)

        it("staggers key repeats of page turn & cursor keys only", function()
            MockTime:install()
            local ok, err = pcall(function()
                local inp = kbInput({ key_repeat = { [C.REP_PERIOD] = 200 } })
                assert.are.equal("onKeyPress", inp:handleKeyBoardEv(key(109, 1)).handler)
                assert.are.equal("onKeyRepeat", inp:handleKeyBoardEv(key(109, 2)).handler)
                MockTime:increase(0.1)
                assert.is_nil(inp:handleKeyBoardEv(key(109, 2)))
                MockTime:increase(0.15)
                assert.are.equal("onKeyRepeat", inp:handleKeyBoardEv(key(109, 2)).handler)
                -- Release resets the staggering
                assert.are.equal("onKeyRelease", inp:handleKeyBoardEv(key(109, 0)).handler)
                assert.is_nil(inp.last_repeat_time)
                assert.are.equal("onKeyRepeat", inp:handleKeyBoardEv(key(103, 2)).handler)
                -- Other keys never repeat
                assert.is_nil(inp:handleKeyBoardEv(key(30, 2)))
            end)
            MockTime:uninstall()
            assert(ok, err)
        end)

        it("maps Power presses & releases", function()
            local inp = kbInput()
            assert.are.equal("PowerPress", inp:handleKeyBoardEv(key(116, 1)))
            assert.are.equal("PowerRelease", inp:handleKeyBoardEv(key(116, 0)))
            assert.is_nil(inp:handleKeyBoardEv(key(116, 2)))
        end)

        it("forwards synthetic events and queues their arguments", function()
            local inp = kbInput()
            assert.are.equal("IntoSS", inp:handleKeyBoardEv(key(10000, 1)))
            assert.are.equal("UsbDevicePlugIn", inp:handleKeyBoardEv(key(10040, 7)))
            assert.are.equal("UsbDevicePlugIn", inp:handleKeyBoardEv(key(10040, 8)))
            assert.are.same({ 7, 8 }, inp.fake_event_args.UsbDevicePlugIn)
            assert.are.equal("ReadyToSuspend", inp:handleKeyBoardEv(key(10031, 1)))
        end)

        it("runs event map adapters (e.g., sleep cover)", function()
            local inp = kbInput({ event_map_adapter = {
                SleepCover = function(ev) return ev.value == 1 and "SleepCoverClosed" or "SleepCoverOpened" end,
            } })
            assert.are.equal("SleepCoverClosed", inp:handleKeyBoardEv(key(59, 1)))
            assert.are.equal("SleepCoverOpened", inp:handleKeyBoardEv(key(59, 0)))
        end)

        it("toggles fullscreen on F11 and quits on Alt+F4", function()
            local broadcast = {}
            UIManager.broadcastEvent = function(_, ev) table.insert(broadcast, ev.handler) end
            local ticks = {}
            UIManager.nextTick = function(_, fn) table.insert(ticks, fn) end
            local quit = spy.new(function() end)
            UIManager.quit = quit
            local inp = kbInput()
            inp:handleKeyBoardEv(key(87, 1))
            assert.are.same({ "onToggleFullscreen" }, broadcast)
            inp:handleKeyBoardEv(key(56, 1))
            inp:handleKeyBoardEv(key(62, 1))
            assert.are.same({ "onToggleFullscreen", "onClose" }, broadcast)
            assert.are.equal(1, #ticks)
            ticks[1]()
            assert.spy(quit).was.called(1)

            local fs = kbInput({ always_fullscreen = true })
            broadcast = {}
            fs:handleKeyBoardEv(key(87, 1))
            assert.are.same({}, broadcast)
        end)

        it("surfaces a lone Sym or ScreenKB tap as a dedicated key press", function()
            local inp = kbInput()
            assert.is_nil(inp:handleKeyBoardEv(key(127, 1)))
            assert.is_true(inp.modifiers.Sym)
            local ev = inp:handleKeyBoardEv(key(127, 0))
            assert.are.equal("onKeyPress", ev.handler)
            assert.are.equal("SymPress", ev.args[1].key)
            assert.is_false(inp.modifiers.Sym)

            ev = (inp:handleKeyBoardEv(key(190, 1)) or inp:handleKeyBoardEv(key(190, 0)))
            assert.are.equal("ScreenKBPress", ev.args[1].key)
        end)

        it("does not treat Sym combos or held Sym as a lone tap", function()
            local inp = kbInput()
            -- Sym + key
            inp:handleKeyBoardEv(key(127, 1))
            inp:handleKeyBoardEv(key(30, 1))
            inp:handleKeyBoardEv(key(30, 0))
            assert.is_nil(inp:handleKeyBoardEv(key(127, 0)))
            -- Shift + Sym
            inp:handleKeyBoardEv(key(42, 1))
            inp:handleKeyBoardEv(key(127, 1))
            assert.is_nil(inp:handleKeyBoardEv(key(127, 0)))
            inp:handleKeyBoardEv(key(42, 0))
            -- Held Sym (repeats)
            inp:handleKeyBoardEv(key(127, 1))
            inp:handleKeyBoardEv(key(127, 2))
            assert.is_nil(inp:handleKeyBoardEv(key(127, 0)))
            assert.is_false(inp.modifiers.Sym)
        end)

        it("emits TextInput for printable presses with a hardware layout", function()
            local sent = {}
            UIManager.sendEvent = function(_, ev) table.insert(sent, ev) end
            local inp = kbInput({ hw_text_layout = function(keycode, mods)
                if keycode == "A" then return mods.Shift and "A" or "a" end
            end })
            local ev = inp:handleKeyBoardEv(key(30, 1))
            assert.are.equal("onKeyPress", ev.handler)
            inp:handleKeyBoardEv(key(30, 0))
            inp:handleKeyBoardEv(key(103, 1))
            assert.are.equal(1, #sent)
            assert.are.equal("onTextInput", sent[1].handler)
            assert.are.equal("a", sent[1].args[1])
        end)

        describe("while input is inhibited", function()
            it("only lets power management events through", function()
                local inp = kbInput({ event_map_adapter = {
                    SleepCover = function(ev) return ev.value == 1 and "SleepCoverClosed" or "SleepCoverOpened" end,
                } })
                inp:inhibitInput(true)
                assert.are.equal("SleepCoverClosed", inp:handleKeyBoardEv(key(59, 1)))
                assert.are.equal("PowerPress", inp:handleKeyBoardEv(key(116, 1)))
                assert.are.equal("PowerRelease", inp:handleKeyBoardEv(key(116, 0)))
                assert.is_nil(inp:handleKeyBoardEv(key(116, 2)))
                assert.are.equal("UsbDevicePlugOut", inp:handleKeyBoardEv(key(10041, 3)))
                assert.are.same({ 3 }, inp.fake_event_args.UsbDevicePlugOut)
                assert.is_nil(inp:handleKeyBoardEv(key(30, 1)))
                assert.is_nil(inp:handleKeyBoardEv(key(999, 1)))
                -- Page turn keys are swallowed
                assert.is_nil(inp:handleKeyBoardEv(key(109, 1)))
                assert.is_nil(inp:handleKeyBoardEv(key(109, 0)))
                -- Modifier state stays balanced
                inp:handleKeyBoardEv(key(42, 1))
                assert.is_true(inp.modifiers.Shift)
                inp:handleKeyBoardEv(key(42, 0))
                assert.is_false(inp.modifiers.Shift)
                inp:inhibitInput(false)
                assert.are.equal("onKeyPress", inp:handleKeyBoardEv(key(30, 1)).handler)
            end)

            it("turns page turn releases into PowerRelease with pageturn_power", function()
                G_reader_settings:saveSetting("pageturn_power", true)
                local inp = kbInput()
                inp:inhibitInput(true)
                local ok, err = pcall(function()
                    assert.is_nil(inp:handleKeyBoardEv(key(109, 1)))
                    assert.is_nil(inp:handleKeyBoardEv(key(109, 2)))
                    assert.are.equal("PowerRelease", inp:handleKeyBoardEv(key(109, 0)))
                end)
                G_reader_settings:delSetting("pageturn_power")
                assert(ok, err)
            end)

            it("sends touch, gyro & generic events to the void and resets gesture state", function()
                local inp, backend = kbInput()
                inp:toggleGyroEvents(true)
                inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 1))
                inp:handleTouchEv(abs(C.ABS_MT_POSITION_X, 10))
                inp:handleTouchEv(abs(C.ABS_MT_POSITION_Y, 10))
                inp:handleTouchEv(syn(0))
                assert.are.equal(1, inp.gesture_detector.contact_count)
                inp:inhibitInput(true)
                -- Calling it twice must not lose the original handlers
                inp:inhibitInput(true)
                assert.are.equal(0, inp.gesture_detector.contact_count)
                assert.are.equal(0, #inp.timer_callbacks)
                table.insert(backend.queue, batch(
                    abs(C.ABS_MT_TRACKING_ID, -1), syn(30),
                    { type = C.EV_SW, code = 0, value = 1, time = tv(30) }
                ))
                assert.are.same({}, inp:waitEvent(T0, nil))
                assert.is_nil(inp:handleGyroEv({ value = C.DEVICE_ROTATED_CLOCKWISE }))

                inp:inhibitInput(false)
                assert.are.equal(Input.handleKeyBoardEv, inp.handleKeyBoardEv)
                assert.are.equal(Input.handleTouchEv, inp.handleTouchEv)
                assert.are.equal(Input.handleGenericEv, inp.handleGenericEv)
                assert.are.equal(inp.handleMiscGyroEv, inp.handleGyroEv)
                -- And no phantom tap from the lift that happened while inhibited
                inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, -1))
                assert.are.same({}, gesNames(inp:handleTouchEv(syn(60))))
            end)

            it("filters SDL mouse wheel events but forwards the other SDL events", function()
                local inp = kbInput()
                local forwarded = {}
                inp.handleSdlEv = function(_, ev)
                    table.insert(forwarded, ev.code)
                    return "sdl"
                end
                inp:inhibitInput(true)
                assert.is_nil(inp:handleSdlEv({ code = 1027 }))
                assert.are.equal("sdl", inp:handleSdlEv({ code = 1024 }))
                assert.are.same({ 1024 }, forwarded)
                inp:inhibitInput(false)
                assert.are.equal("sdl", inp:handleSdlEv({ code = 1027 }))
            end)

            it("inhibits for a platform-specific delay and restores itself", function()
                local scheduled = {}
                UIManager.scheduleIn = function(_, delay, fn) table.insert(scheduled, { delay = delay, fn = fn }) end
                local unscheduled = 0
                UIManager.unschedule = function() unscheduled = unscheduled + 1 end

                local eink = kbInput()
                eink:inhibitInputUntil(true)
                assert.are.equal(0.8, scheduled[1].delay)
                assert.are.equal(eink.handlePowerManagementOnlyEv, eink.handleKeyBoardEv)
                -- The scheduled callback restores input
                scheduled[1].fn()
                assert.are.equal(Input.handleKeyBoardEv, eink.handleKeyBoardEv)

                local lcd = kbInput({ eink = false })
                lcd:inhibitInputUntil(true)
                assert.are.equal(0.4, scheduled[2].delay)
                lcd:inhibitInputUntil(2)
                assert.are.equal(2, scheduled[3].delay)
                lcd:inhibitInputUntil(false)
                assert.are.equal(Input.handleKeyBoardEv, lcd.handleKeyBoardEv)
                assert.are.equal(3, #scheduled)
                -- Every call cancels the previous schedule first
                assert.are.equal(5, unscheduled)
            end)
        end)

        describe("gyro", function()
            it("emits SetRotationMode when unlocked", function()
                local inp = kbInput()
                inp:toggleGyroEvents(true)
                local ev = inp:handleGyroEv({ value = C.DEVICE_ROTATED_CLOCKWISE })
                assert.are.equal("onSetRotationMode", ev.handler)
                assert.are.equal(framebuffer.DEVICE_ROTATED_CLOCKWISE, ev.args[1])
                assert.is_nil(inp:handleGyroEv({ value = C.DEVICE_ROTATED_UPRIGHT }))
                assert.is_nil(inp:handleGyroEv({ value = 42 }))
                assert.are.equal("onSetRotationMode", inp:handleGyroEv({ value = C.DEVICE_ROTATED_UPSIDE_DOWN }).handler)
                assert.are.equal("onSetRotationMode", inp:handleGyroEv({ value = C.DEVICE_ROTATED_COUNTER_CLOCKWISE }).handler)
            end)

            it("only flips within the same orientation when locked", function()
                local rotations = 0
                UIManager.onRotation = function() rotations = rotations + 1 end
                local inp = kbInput({ gsensor_locked = true })
                inp:toggleGyroEvents(true)
                assert.is_nil(inp:handleGyroEv({ value = C.DEVICE_ROTATED_CLOCKWISE }))
                assert.are.equal(0, rotations)
                assert.is_nil(inp:handleGyroEv({ value = C.DEVICE_ROTATED_UPSIDE_DOWN }))
                assert.are.equal(1, rotations)
                assert.are.equal(framebuffer.DEVICE_ROTATED_UPSIDE_DOWN, inp.device.screen:getRotationMode())
            end)

            it("toggles gyro handling", function()
                local inp = kbInput()
                inp:toggleGyroEvents(true)
                inp:toggleGyroEvents(true)
                assert.are.equal(inp.handleMiscGyroEv, inp.handleGyroEv)
                inp:toggleGyroEvents(false)
                assert.are.equal(inp.voidEv, inp.handleGyroEv)
                inp:toggleGyroEvents(false)
                assert.are.equal(inp.voidEv, inp.handleGyroEv)
                inp:toggleGyroEvents()
                assert.are.equal(inp.handleMiscGyroEv, inp.handleGyroEv)
                inp:toggleGyroEvents()
                assert.are.equal(inp.voidEv, inp.handleGyroEv)
            end)
        end)
    end)

    describe("waitEvent", function()
        local saved_abort
        before_each(function()
            saved_abort = rawget(UIManager, "abort")
        end)
        after_each(function()
            UIManager.abort = saved_abort
        end)

        it("blocks forever without timers or deadline, and returns nothing on timeout", function()
            local inp, backend = newInput()
            assert.is_nil(inp:waitEvent(T0, nil))
            assert.are.same({ {} }, backend.calls)
        end)

        it("converts the UI deadline into a relative poll timeout", function()
            local inp, backend = newInput()
            inp:waitEvent(T0, T0 + time.ms(1500))
            assert.are.same({ sec = 1, usec = 500000 }, backend.calls[1])
            -- A blown deadline polls without blocking
            inp:waitEvent(T0 + time.s(2), T0 + time.ms(1500))
            assert.are.same({ sec = 0, usec = 0 }, backend.calls[2])
        end)

        it("retries on EINTR", function()
            local inp, backend = newInput()
            table.insert(backend.queue, { false, C.EINTR })
            table.insert(backend.queue, batch(contact(1, 1, 2), syn(0)))
            assert.are.same({ "touch" }, gesNames(inp:waitEvent(T0, T0 + time.s(1))))
            assert.are.equal(2, #backend.calls)
        end)

        it("reports other poll errors as InputError", function()
            local inp, backend = newInput()
            table.insert(backend.queue, { false, C.EINVAL })
            local evs = inp:waitEvent(T0, nil)
            assert.are.equal(1, #evs)
            assert.are.equal("onInputError", evs[1].handler)
            assert.are.equal(C.EINVAL, evs[1].args[1])
        end)

        it("aborts on a catastrophic failure", function()
            local abort = spy.new(function() end)
            UIManager.abort = abort
            local inp, backend = newInput()
            table.insert(backend.queue, { nil })
            local evs = inp:waitEvent(T0, nil)
            assert.spy(abort).was.called(1)
            assert.are.equal("onInputError", evs[1].handler)
            assert.are.equal("Catastrophic", evs[1].args[1])
        end)

        it("dispatches every event type of a batch to its handler", function()
            local inp, backend = newInput({ event_map = { [30] = "A" } })
            inp.handleMiscEv = function(_, ev) return Event:new("Misc", ev.value) end
            inp.handleSdlEv = function(_, ev) return Event:new("Sdl", ev.value) end
            table.insert(backend.queue, batch(
                key(30, 1),
                { type = C.EV_MSC, code = C.MSC_RAW, value = 1, time = tv(0) },
                { type = C.EV_SDL, code = 0, value = 2, time = tv(0) },
                { type = C.EV_SW, code = 0, value = 3, time = tv(0) },
                contact(1, 5, 5), syn(0)
            ))
            local evs = inp:waitEvent(T0, nil)
            local handlers = {}
            for _, e in ipairs(evs) do
                table.insert(handlers, e.handler)
            end
            assert.are.same({ "onKeyPress", "onMisc", "onSdl", "onGenericInput", "onGesture" }, handlers)
        end)

        it("logs every event type in debug mode without choking", function()
            local DEBUG = require("dbg")
            local inp, backend = newInput({ event_map = { [30] = "A" } })
            table.insert(backend.queue, batch(
                key(30, 1), key(C.BTN_TOUCH, 1),
                { type = C.EV_MSC, code = C.MSC_GYRO, value = 1, time = tv(0) },
                { type = C.EV_REP, code = C.REP_DELAY, value = 400, time = tv(0) },
                { type = C.EV_SW, code = 0, value = 1, time = tv(0) },
                contact(1, 5, 5), syn(0)
            ))
            local was_on = DEBUG.is_on
            DEBUG.is_on = true
            local ok, evs = pcall(inp.waitEvent, inp, T0, nil)
            DEBUG.is_on = was_on
            assert.is_true(ok, evs)
            assert.are.same({ "touch" }, gesNames(evs))
        end)

        describe("with gesture timers", function()
            it("polls until the hold deadline and emits hold", function()
                local inp, backend = newInput()
                table.insert(backend.queue, batch(contact(1, 30, 40), syn(0)))
                assert.are.same({ "touch" }, gesNames(inp:waitEvent(T0, nil)))
                assert.are.equal(1, #inp.timer_callbacks)
                assert.are.equal(T0 + time.ms(500), inp.timer_callbacks[1].deadline)
                local evs = inp:waitEvent(T0 + time.ms(100), nil)
                assert.are.same({ sec = 0, usec = 400000 }, backend.calls[2])
                local g = gestures(evs)
                assert.are.equal("hold", g[1].ges)
                assert.are.equal(30, g[1].pos.x)
                assert.are.equal(0, #inp.timer_callbacks)
            end)

            it("hands over input that arrives before the timer deadline", function()
                local inp, backend = newInput()
                inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 1))
                inp:handleTouchEv(abs(C.ABS_MT_POSITION_X, 30))
                inp:handleTouchEv(abs(C.ABS_MT_POSITION_Y, 40))
                inp:handleTouchEv(syn(0))
                table.insert(backend.queue, batch(abs(C.ABS_MT_TRACKING_ID, -1), syn(100)))
                -- The UI deadline is later than the timer: poll until the timer
                local evs = inp:waitEvent(T0 + time.ms(50), T0 + time.s(5))
                assert.are.same({ sec = 0, usec = 450000 }, backend.calls[1])
                assert.are.same({ "tap" }, gesNames(evs))
                assert.are.equal(0, #inp.timer_callbacks)
            end)

            it("consumes a timer whose deadline was blown while serving the UI deadline", function()
                local inp, backend = newInput({ disable_double_tap = false })
                inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 1))
                inp:handleTouchEv(abs(C.ABS_MT_POSITION_X, 30))
                inp:handleTouchEv(abs(C.ABS_MT_POSITION_Y, 40))
                inp:handleTouchEv(syn(0))
                inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, -1))
                assert.are.same({}, gesNames(inp:handleTouchEv(syn(50))))
                -- Both the hold & double_tap timers are pending, sorted by deadline
                assert.are.equal(2, #inp.timer_callbacks)
                assert.are.equal("double_tap", inp.timer_callbacks[1].gesture)
                assert.are.equal(T0 + time.ms(350), inp.timer_callbacks[1].deadline)
                MockTime:install()
                local ok, err = pcall(function()
                    -- time.now() is way past both timers: the UI deadline (earlier) is honored first,
                    -- then the expired timer is consumed on ETIME.
                    MockTime:increase((T0 + time.s(10) - time.now()) / 1e6)
                    local evs = inp:waitEvent(T0 + time.ms(100), T0 + time.ms(200))
                    assert.are.same({ sec = 0, usec = 100000 }, backend.calls[1])
                    assert.are.same({ "tap" }, gesNames(evs))
                end)
                MockTime:uninstall()
                assert(ok, err)
                assert.are.equal(0, #inp.timer_callbacks)
            end)

            it("clears timeouts per slot and gesture", function()
                local inp = newInput()
                local cb = function() end
                inp:setTimeout(0, "hold", cb, T0, time.ms(500))
                inp:setTimeout(0, "double_tap", cb, T0, time.ms(300))
                inp:setTimeout(1, "hold", cb, T0, time.ms(100))
                assert.are.same({ 1, 0, 0 }, {
                    inp.timer_callbacks[1].slot, inp.timer_callbacks[2].slot, inp.timer_callbacks[3].slot,
                })
                inp:clearTimeout(0, "hold")
                assert.are.equal(2, #inp.timer_callbacks)
                inp:clearTimeout(0)
                assert.are.equal(1, #inp.timer_callbacks)
                assert.are.equal(1, inp.timer_callbacks[1].slot)
                inp:clearTimeouts()
                assert.are.equal(0, #inp.timer_callbacks)
            end)

            it("uses the UI clock for deadlines when the event clock is not monotonic", function()
                MockTime:install()
                local ok, err = pcall(function()
                    local now = time.now()
                    local inp = newInput({ clock_id = C.CLOCK_REALTIME })
                    inp:setTimeout(0, "hold", function() end, T0, time.ms(500))
                    assert.are.equal(now + time.ms(500), inp.timer_callbacks[1].deadline)
                end)
                MockTime:uninstall()
                assert(ok, err)
            end)
        end)

        describe("with the timerfd backend", function()
            local function timerfdInput(opts)
                local backend = newBackend()
                local next_fd = 0
                function backend.setTimer(clock, sec, usec)
                    next_fd = next_fd + 1
                    local fd = "timerfd" .. next_fd
                    table.insert(backend.timers, { fd = fd, clock = clock, sec = sec, usec = usec })
                    return fd
                end
                function backend.clearTimer(fd)
                    table.insert(backend.cleared, fd)
                end
                opts = opts or {}
                opts.backend = backend
                return newInput(opts)
            end

            it("arms a kernel timer at the event timestamp and consumes it on expiry", function()
                local inp, backend = timerfdInput()
                inp:handleTouchEv(abs(C.ABS_MT_TRACKING_ID, 1))
                inp:handleTouchEv(abs(C.ABS_MT_POSITION_X, 30))
                inp:handleTouchEv(abs(C.ABS_MT_POSITION_Y, 40))
                inp:handleTouchEv(syn(0))
                assert.are.equal(1, #backend.timers)
                assert.are.equal(C.CLOCK_MONOTONIC, backend.timers[1].clock)
                assert.are.equal(1000, backend.timers[1].sec)
                assert.are.equal(500000, backend.timers[1].usec)
                assert.are.equal("timerfd1", inp.timer_callbacks[1].timerfd)
                table.insert(backend.queue, { false, C.ETIME, "timerfd1" })
                -- No UI deadline: block until the kernel wakes us up
                local g = gestures(inp:waitEvent(T0, nil))
                assert.are.same({}, backend.calls[1])
                assert.are.equal("hold", g[1].ges)
                assert.are.same({ "timerfd1" }, backend.cleared)
                assert.are.equal(0, #inp.timer_callbacks)
            end)

            it("consumes the timer matching the expired timerfd on deadline collisions", function()
                local inp, backend = timerfdInput()
                local fired = {}
                inp:setTimeout(0, "hold", function() table.insert(fired, "a") end, T0, time.ms(100))
                inp:setTimeout(1, "hold", function() table.insert(fired, "b") end, T0, time.ms(100))
                table.insert(backend.queue, { false, C.ETIME, "timerfd2" })
                table.insert(backend.queue, { false, C.ETIME, "timerfd1" })
                -- Neither callback yields a gesture: both get consumed in the same wait
                assert.is_nil(inp:waitEvent(T0, nil))
                assert.are.same({ "b", "a" }, fired)
                assert.are.same({ "timerfd2", "timerfd1" }, backend.cleared)
                assert.are.equal(0, #inp.timer_callbacks)
            end)

            it("closes the timerfds of cleared timeouts", function()
                local inp, backend = timerfdInput()
                inp:setTimeout(0, "hold", function() end, T0, time.ms(100))
                inp:setTimeout(1, "hold", function() end, T0, time.ms(200))
                inp:setTimeout(2, "hold", function() end, T0, time.ms(300))
                inp:clearTimeout(1, "hold")
                assert.are.same({ "timerfd2" }, backend.cleared)
                inp:clearTimeouts()
                assert.are.same({ "timerfd2", "timerfd1", "timerfd3" }, backend.cleared)
                assert.are.equal(0, #inp.timer_callbacks)
            end)

            it("falls back to the UI clock when the event clock is unknown", function()
                MockTime:install()
                local ok, err = pcall(function()
                    local now = time.now()
                    local inp, backend = timerfdInput({ clock_id = -1 })
                    inp:setTimeout(0, "hold", function() end, T0, time.ms(500))
                    assert.are.equal(C.CLOCK_MONOTONIC, backend.timers[1].clock)
                    assert.are.equal(now + time.ms(500), inp.timer_callbacks[1].deadline)
                end)
                MockTime:uninstall()
                assert(ok, err)
            end)

            it("falls back to a poll timeout when the kernel timer cannot be armed", function()
                local backend = newBackend()
                backend.setTimer = function() return nil end
                local inp = newInput({ backend = backend })
                inp:setTimeout(0, "hold", function() end, T0, time.ms(500))
                assert.is_nil(inp.timer_callbacks[1].timerfd)
                assert.are.equal(T0 + time.ms(500), inp.timer_callbacks[1].deadline)
            end)

            it("reports errors while timers are pending", function()
                local inp, backend = timerfdInput()
                inp:setTimeout(0, "hold", function() end, T0, time.ms(100))
                table.insert(backend.queue, { false, C.EINVAL })
                local evs = inp:waitEvent(T0, nil)
                assert.are.equal("onInputError", evs[1].handler)
                assert.are.equal(1, #inp.timer_callbacks)
            end)
        end)
    end)

    describe("device bookkeeping", function()
        local saved_opened
        before_each(function()
            saved_opened = Input.opened_devices
            Input.opened_devices = {}
        end)
        after_each(function()
            Input.opened_devices = saved_opened
        end)

        it("opens each device path only once and forgets it on close", function()
            local backend = newBackend()
            local opened, closed = {}, {}
            backend.open = function(path) table.insert(opened, path); return 10 + #opened end
            local fdopened = {}
            backend.fdopen = function(fd) table.insert(fdopened, fd) end
            backend.close = function(fd)
                table.insert(closed, fd)
                if fd == 12 then return false, C.ENODEV end
                if fd == 13 then return false, C.EINVAL end
                return true
            end
            backend.closeAll = spy.new(function() end)
            local inp = newInput({ backend = backend })
            assert.are.equal(11, inp:open("/dev/input/event0", "touch"))
            assert.is_nil(inp:open("/dev/input/event0"))
            assert.are.equal(12, inp:open("/dev/input/event1"))
            assert.are.same({ "/dev/input/event0", "/dev/input/event1" }, opened)
            assert.are.equal(42, inp:fdopen(42, "/dev/input/event2", "keys"))
            assert.is_nil(inp:fdopen(42, "/dev/input/event2"))
            assert.are.same({ 42 }, fdopened)
            assert.are.equal(13, inp:open("/dev/input/event3"))

            inp:close("/dev/input/event0")
            assert.is_nil(Input.opened_devices["/dev/input/event0"])
            -- ENODEV: the backend already closed it
            inp:close("/dev/input/event1")
            assert.is_nil(Input.opened_devices["/dev/input/event1"])
            -- Other errors keep it around
            inp:close("/dev/input/event3")
            assert.are.equal(13, Input.opened_devices["/dev/input/event3"])
            inp:close("/dev/input/nope")
            assert.are.same({ 11, 12, 13 }, closed)

            inp:teardown()
            assert.spy(backend.closeAll).was.called(1)
            assert.are.same({}, Input.opened_devices)
        end)

        it("delegates to FFI backends", function()
            local backend = newBackend()
            backend.is_ffi = true
            backend.open = function(path, name) return path .. ":" .. tostring(name) end
            backend.close = function(path) return "closed " .. path end
            local inp = newInput({ backend = backend })
            assert.are.equal("/dev/x:pen", inp:open("/dev/x", "pen"))
            assert.are.equal("closed /dev/x", inp:close("/dev/x"))
            assert.are.same({}, Input.opened_devices)
        end)
    end)
end)
