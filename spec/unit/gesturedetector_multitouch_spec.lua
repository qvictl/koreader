-- GestureDetector state machine: single & two-finger gestures, timers, rotation.
--
-- Every test drives a fresh GestureDetector through input frames built the way Input does it:
-- each slot is backed by a *persistent* table that gets mutated in place, and all the slots
-- touched in an input frame are updated before the frame is fed (c.f., Input:handleTouchEv).
-- Timers (hold/double_tap) are captured instead of being scheduled, so tests can fire them
-- deterministically, like Input:waitEvent would once their deadline is blown.
describe("GestureDetector multitouch", function()
    local GestureDetector, time, ffi, C

    setup(function()
        require("commonrequire")
        ffi = require("ffi")
        C = ffi.C
        require("ffi/posix_h")
        GestureDetector = require("device/gesturedetector")
        time = require("ui/time")
    end)

    local function newScreen(rotation)
        return {
            DEVICE_ROTATED_UPRIGHT = 0,
            DEVICE_ROTATED_CLOCKWISE = 1,
            DEVICE_ROTATED_UPSIDE_DOWN = 2,
            DEVICE_ROTATED_COUNTER_CLOCKWISE = 3,
            scaleByDPI = function(_, value) return value end,
            getTouchRotation = function() return rotation or 0 end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        }
    end

    local function newHarness(opts)
        opts = opts or {}
        local h = {
            timers = {},
            slots = {},
            base = time.s(1000),
        }
        local input = {
            main_finger_slot = 0,
            disable_double_tap = not opts.double_tap,
            allow_concurrent_taps = false,
            tap_interval_override = opts.tap_interval and time.ms(opts.tap_interval),
        }
        function input.setTimeout(_, slot, ges, cb, origin, delay)
            table.insert(h.timers, { slot = slot, ges = ges, cb = cb, deadline = origin + delay })
        end
        function input.clearTimeout(_, slot, ges)
            for i = #h.timers, 1, -1 do
                local t = h.timers[i]
                if t.slot == slot and (not ges or t.ges == ges) then
                    table.remove(h.timers, i)
                end
            end
        end
        h.input = input
        h.gd = GestureDetector:new{
            input = input,
            screen = newScreen(opts.rotation),
            active_contacts = {},
            contact_count = 0,
            previous_tap = {},
            clock_id = C.CLOCK_MONOTONIC,
        }
        -- Feed one input frame at t ms (relative to h.base); varargs are per-slot updates.
        function h.frame(t, ...)
            local tevs = {}
            for _, update in ipairs({...}) do
                local s = h.slots[update.slot]
                if not s then
                    s = { slot = update.slot }
                    h.slots[update.slot] = s
                end
                for k, v in pairs(update) do
                    s[k] = v
                end
                s.timev = h.base + time.ms(t)
                table.insert(tevs, s)
            end
            local gestures = h.gd:feedEvent(tevs)
            if opts.adjust then
                for _, ges in ipairs(gestures) do
                    h.gd:adjustGesCoordinate(ges)
                end
            end
            return gestures
        end
        -- Fire the earliest pending timer for that gesture (and slot), as Input:waitEvent would.
        function h.fire(ges, slot)
            for i, t in ipairs(h.timers) do
                if t.ges == ges and (slot == nil or t.slot == slot) then
                    table.remove(h.timers, i)
                    return t.cb()
                end
            end
            error("no pending " .. ges .. " timer")
        end
        function h.pending(ges, slot)
            local n = 0
            for _, t in ipairs(h.timers) do
                if t.ges == ges and (slot == nil or t.slot == slot) then
                    n = n + 1
                end
            end
            return n
        end
        return h
    end

    local function down(slot, id, x, y) return { slot = slot, id = id, x = x, y = y } end
    local function move(slot, x, y) return { slot = slot, x = x, y = y } end
    local function up(slot) return { slot = slot, id = -1 } end

    local function names(gestures)
        local t = {}
        for _, g in ipairs(gestures) do
            table.insert(t, g.ges)
        end
        return t
    end

    local function assertPos(pos, x, y)
        assert.is_not_nil(pos)
        assert.is_near(x, pos.x, 1e-6)
        assert.is_near(y, pos.y, 1e-6)
    end

    describe("single contact", function()
        it("emits touch on contact down and arms a hold timer at the event timestamp", function()
            local h = newHarness()
            local g = h.frame(0, down(0, 7, 100, 120))
            assert.are.same({ "touch" }, names(g))
            assertPos(g[1].pos, 100, 120)
            assert.are.equal(h.base, g[1].time)
            assert.are.equal(1, h.pending("hold", 0))
            assert.are.equal(h.base + h.gd.ges_hold_interval, h.timers[1].deadline)
            assert.are.equal(1, h.gd.contact_count)
        end)

        it("waits for coordinates before starting a contact", function()
            local h = newHarness()
            assert.are.same({}, h.frame(0, { slot = 0, id = 3 }))
            assert.are.equal(0, h.pending("hold"))
            local g = h.frame(10, move(0, 40, 50))
            assert.are.same({ "touch" }, names(g))
            assertPos(g[1].pos, 40, 50)
        end)

        it("drops a lift for a contact it never saw going down (no phantom tap)", function()
            local h = newHarness()
            assert.are.same({}, h.frame(0, { slot = 0, id = -1, x = 10, y = 10 }))
            assert.are.equal(0, h.gd.contact_count)
            assert.is_nil(h.gd:getContact(0))
        end)

        it("tolerates jitter below the pan threshold and reports the tap at the lift position", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 100, 100))
            assert.are.same({}, h.frame(40, move(0, 120, 110)))
            local g = h.frame(80, up(0))
            assert.are.same({ "tap" }, names(g))
            assertPos(g[1].pos, 120, 110)
            -- The lift cancels the pending hold timer
            assert.are.equal(0, #h.timers)
            assert.are.equal(0, h.gd.contact_count)
        end)

        it("turns a held contact into hold then hold_release", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 100, 100))
            local hold = h.fire("hold", 0)
            assert.are.equal("hold", hold.ges)
            assertPos(hold.pos, 100, 100)
            local g = h.frame(900, up(0))
            assert.are.same({ "hold_release" }, names(g))
            assertPos(g[1].pos, 100, 100)
            assert.are.equal(0, h.gd.contact_count)
        end)

        it("ignores the hold timer once the contact has been lifted", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 100, 100))
            local contact = h.gd:getContact(0)
            local timer = h.timers[1]
            h.frame(50, up(0))
            -- The timer was cleared by the lift; even a stale callback must be a no-op.
            assert.are.equal(0, #h.timers)
            assert.is_nil(timer.cb())
            assert.is_nil(h.gd:getContact(0))
            assert.is_nil(contact.pending_hold_timer)
        end)

        it("emits hold_pan when a held contact moves, and hold_release on lift", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 100, 100))
            h.fire("hold", 0)
            assert.are.same({}, h.frame(600, move(0, 120, 100)))
            local g = h.frame(700, move(0, 160, 100))
            assert.are.same({ "hold_pan" }, names(g))
            assert.are.equal("east", g[1].direction)
            assert.are.equal(60, g[1].relative.x)
            assert.are.equal(0, g[1].relative.y)
            assertPos(g[1].start_pos, 100, 100)
            assertPos(g[1].pos, 160, 100)
            g = h.frame(800, up(0))
            assert.are.same({ "hold_release" }, names(g))
            assertPos(g[1].pos, 160, 100)
        end)

        it("emits pan then pan_release when lifted after the swipe interval", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 100, 100))
            local g = h.frame(100, move(0, 200, 100))
            assert.are.same({ "pan" }, names(g))
            assert.are.equal("east", g[1].direction)
            assert.are.equal(100, g[1].distance)
            -- Hold timer firing while panning is harmless
            assert.is_nil(h.fire("hold", 0))
            g = h.frame(300, move(0, 180, 180))
            assert.are.same({ "pan" }, names(g))
            assert.are.equal("southeast", g[1].direction)
            g = h.frame(1500, up(0))
            assert.are.same({ "pan_release" }, names(g))
            assertPos(g[1].pos, 180, 180)
            assert.are.equal(0, #h.timers)
            assert.are.equal(0, h.gd.contact_count)
        end)

        it("drops a pending hold timer when a pan is released", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 100, 100))
            h.frame(100, move(0, 100, 300))
            assert.are.equal(1, h.pending("hold", 0))
            h.frame(1200, up(0))
            assert.are.equal(0, h.pending("hold", 0))
        end)

        it("emits a swipe for a fast flick", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 100, 300))
            assert.are.same({ "pan" }, names(h.frame(50, move(0, 100, 100))))
            local g = h.frame(120, up(0))
            assert.are.same({ "swipe" }, names(g))
            assert.are.equal("north", g[1].direction)
            assert.are.equal(200, g[1].distance)
            assertPos(g[1].pos, 100, 300)
            assertPos(g[1].end_pos, 100, 100)
            assert.is_nil(g[1].multiswipe_directions)
        end)

        it("detects diagonal swipes", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 300, 300))
            h.frame(50, move(0, 200, 200))
            local g = h.frame(100, up(0))
            assert.are.equal("swipe", g[1].ges)
            assert.are.equal("northwest", g[1].direction)
        end)

        it("emits a multiswipe for a chain of directions", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 100, 100))
            h.frame(50, move(0, 200, 100))
            h.frame(100, move(0, 200, 250))
            h.frame(150, move(0, 80, 250))
            local g = h.frame(200, up(0))
            assert.are.same({ "multiswipe" }, names(g))
            assert.are.equal("east south west", g[1].multiswipe_directions)
            assertPos(g[1].pos, 100, 100)
            assertPos(g[1].end_pos, 80, 250)
        end)

        it("collapses repeated segments in the same direction into a plain swipe", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 100, 100))
            h.frame(50, move(0, 200, 100))
            h.frame(100, move(0, 300, 100))
            local g = h.frame(150, up(0))
            assert.are.same({ "swipe" }, names(g))
            assert.are.equal("east", g[1].direction)
        end)

        it("tracks diagonal multiswipes", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 100, 100))
            h.frame(50, move(0, 200, 200))
            h.frame(100, move(0, 300, 100))
            local g = h.frame(150, up(0))
            assert.are.same({ "multiswipe" }, names(g))
            assert.are.equal("southeast northeast", g[1].multiswipe_directions)
        end)

        it("keeps multiswipe tracking in touch coordinates when gestures are rotated in place", function()
            -- Input rotates every emitted gesture in place (adjustGesCoordinate):
            -- the multiswipe bookkeeping must not be affected by that.
            local h = newHarness({ rotation = 1, adjust = true })
            h.frame(0, down(0, 1, 100, 100))
            local pan = h.frame(50, move(0, 200, 100))[1]
            -- touch east -> screen south when rotated clockwise
            assert.are.equal("south", pan.direction)
            assertPos(pan.pos, 600 - 100, 200)
            h.frame(100, move(0, 200, 250))
            local g = h.frame(150, up(0))
            assert.are.equal("multiswipe", g[1].ges)
            assert.are.equal("south west", g[1].multiswipe_directions)
            assertPos(g[1].pos, 500, 100)
            assertPos(g[1].end_pos, 600 - 250, 200)
        end)
    end)

    describe("tap timing", function()
        it("filters tap bounces within the tap interval", function()
            local h = newHarness({ tap_interval = 100 })
            h.frame(0, down(0, 1, 100, 100))
            assert.are.same({ "tap" }, names(h.frame(30, up(0))))
            assert.are.same({ "touch" }, names(h.frame(60, down(0, 2, 102, 101))))
            assert.are.same({}, h.frame(80, up(0)))
            assert.are.equal(0, h.gd.contact_count)
            -- A tap far away is not a bounce, even within the interval
            h.frame(90, down(0, 3, 400, 400))
            assert.are.same({ "tap" }, names(h.frame(100, up(0))))
            -- Out of the interval, a tap at the same spot goes through again
            h.frame(300, down(0, 4, 400, 400))
            assert.are.same({ "tap" }, names(h.frame(320, up(0))))
        end)

        it("does not treat taps with out-of-order timestamps as bounces", function()
            local h = newHarness()
            local earlier = { x = 10, y = 10, timev = time.s(2) }
            local later = { x = 10, y = 10, timev = time.s(1) }
            assert.is_nil((h.gd:isTapBounce(earlier, later, time.ms(100))))
            assert.is_nil((h.gd:isDoubleTap(earlier, later)))
            assert.is_true((h.gd:isTapBounce(later, earlier, time.s(2))))
            assert.is_true((h.gd:isDoubleTap(later, { x = 20, y = 20, timev = later.timev + time.ms(100) })))
        end)

        it("detects a double tap within the interval and distance", function()
            local h = newHarness({ double_tap = true })
            h.frame(0, down(0, 1, 100, 100))
            assert.are.same({}, h.frame(50, up(0)))
            assert.are.equal(1, h.pending("double_tap", 0))
            assert.are.same({}, h.frame(150, down(0, 2, 110, 105)))
            local g = h.frame(200, up(0))
            assert.are.same({ "double_tap" }, names(g))
            assertPos(g[1].pos, 110, 105)
            assert.are.equal(0, #h.timers)
            assert.are.equal(0, h.gd.contact_count)
        end)

        it("downgrades to a single tap once the double tap timer expires", function()
            local h = newHarness({ double_tap = true })
            h.frame(0, down(0, 1, 100, 100))
            h.frame(50, up(0))
            local tap = h.fire("double_tap", 0)
            assert.are.equal("tap", tap.ges)
            assertPos(tap.pos, 100, 100)
            assert.are.equal(0, #h.timers)
            assert.are.equal(0, h.gd.contact_count)
        end)

        it("ignores spurious lift frames while waiting for the second tap", function()
            local h = newHarness({ double_tap = true })
            h.frame(0, down(0, 1, 100, 100))
            h.frame(50, up(0))
            assert.are.same({}, h.frame(60, up(0)))
            assert.is_not_nil(h.gd:getContact(0))
            assert.are.equal("tap", h.fire("double_tap", 0).ges)
        end)

        it("does not emit a single tap from a stale double tap timer", function()
            local h = newHarness({ double_tap = true })
            h.frame(0, down(0, 1, 100, 100))
            h.frame(50, up(0))
            local timer
            for _, t in ipairs(h.timers) do
                if t.ges == "double_tap" then timer = t end
            end
            h.frame(150, down(0, 2, 100, 100))
            h.frame(200, up(0))
            assert.is_nil(timer.cb())
        end)
    end)

    describe("two contacts", function()
        local function twoDown(h)
            local g = h.frame(0, down(0, 1, 100, 100), down(1, 2, 200, 100))
            assert.are.same({ "touch", "touch" }, names(g))
            assert.are.equal(2, h.gd.contact_count)
            assert.are.equal(h.gd:getContact(1), h.gd:getContact(0).buddy_contact)
            assert.are.equal(h.gd:getContact(0), h.gd:getContact(1).buddy_contact)
        end

        it("falls back to a single tap when a contact moved too much for a two_finger_tap", function()
            local h = newHarness()
            twoDown(h)
            assert.are.same({}, h.frame(40, move(0, 125, 100)))
            local g = h.frame(80, up(0))
            assert.are.same({ "tap" }, names(g))
            assertPos(g[1].pos, 125, 100)
            assert.are.same({}, h.frame(90, up(1)))
            assert.are.equal(0, h.gd.contact_count)
        end)

        it("falls back to a single tap when the contacts stayed down too long", function()
            local h = newHarness()
            twoDown(h)
            local g = h.frame(400, up(0))
            assert.are.same({ "tap" }, names(g))
            assert.are.same({}, h.frame(410, up(1)))
            assert.are.equal(0, h.gd.contact_count)
        end)

        it("emits two_finger_hold and two_finger_hold_release", function()
            local h = newHarness()
            twoDown(h)
            local hold = h.fire("hold", 0)
            assert.are.equal("two_finger_hold", hold.ges)
            assertPos(hold.pos, 150, 100)
            assert.are.equal(100, hold.span)
            -- The buddy's own hold timer must not emit a duplicate hold
            assert.is_nil(h.fire("hold", 1))
            local g = h.frame(900, up(0))
            assert.are.same({ "two_finger_hold_release" }, names(g))
            assertPos(g[1].pos, 150, 100)
            assert.are.same({}, h.frame(910, up(1)))
            assert.are.equal(0, h.gd.contact_count)
            assert.are.equal(0, #h.timers)
        end)

        it("emits two_finger_hold_pan and two_finger_hold_pan_release", function()
            local h = newHarness()
            twoDown(h)
            h.fire("hold", 0)
            local g = h.frame(700, move(0, 100, 200), move(1, 200, 200))
            assert.are.same({ "two_finger_hold_pan" }, names(g))
            assert.are.equal("south", g[1].direction)
            assertPos(g[1].pos, 150, 200)
            assertPos(g[1].start_pos, 150, 100)
            g = h.frame(900, up(0), up(1))
            assert.are.same({ "two_finger_hold_pan_release" }, names(g))
            assertPos(g[1].pos, 150, 200)
            assert.are.equal(0, h.gd.contact_count)
        end)

        it("emits two_finger_pan then two_finger_swipe for a fast two-finger flick", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 100, 500), down(1, 2, 300, 500))
            local g = h.frame(100, move(0, 100, 300), move(1, 300, 300))
            assert.are.same({ "two_finger_pan" }, names(g))
            assert.are.equal("north", g[1].direction)
            assertPos(g[1].pos, 200, 300)
            assert.are.equal(0, g[1].relative.x)
            assert.are.equal(-200, g[1].relative.y)
            g = h.frame(200, up(0), up(1))
            assert.are.same({ "two_finger_swipe" }, names(g))
            assert.are.equal("north", g[1].direction)
            assertPos(g[1].pos, 200, 500)
            assertPos(g[1].end_pos, 200, 300)
            assert.is_nil(g[1].relative)
            assert.is_nil(g[1].start_pos)
            assert.are.equal(0, h.gd.contact_count)
        end)

        it("handles a two-finger swipe whose buddy lifts first", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 100, 500), down(1, 2, 300, 500))
            h.frame(50, move(0, 100, 400), move(1, 300, 400))
            h.frame(100, move(0, 100, 300), move(1, 300, 300))
            local g = h.frame(150, up(1))
            assert.are.same({ "two_finger_swipe" }, names(g))
            assert.are.equal("north", g[1].direction)
            assert.are.same({}, h.frame(160, up(0)))
            assert.are.equal(0, h.gd.contact_count)
        end)

        it("emits two_finger_pan_release when lifted after the swipe interval", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 100, 500), down(1, 2, 300, 500))
            h.frame(100, move(0, 100, 300), move(1, 300, 300))
            local g = h.frame(1500, up(0))
            assert.are.same({ "two_finger_pan_release" }, names(g))
            assertPos(g[1].pos, 200, 300)
            assert.are.same({}, h.frame(1510, up(1)))
            assert.are.equal(0, h.gd.contact_count)
            assert.are.equal(0, #h.timers)
        end)

        it("emits inward_pan then pinch", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 100, 400), down(1, 2, 500, 400))
            local g = h.frame(100, move(0, 200, 400), move(1, 400, 400))
            assert.are.same({ "inward_pan" }, names(g))
            assert.are.equal("horizontal", g[1].direction)
            assert.are.equal(200, g[1].distance)
            assert.are.equal(200, g[1].span)
            assert.are.equal(400, g[1].start_span)
            g = h.frame(150, up(0), up(1))
            assert.are.same({ "pinch" }, names(g))
            assert.are.equal("horizontal", g[1].direction)
            assertPos(g[1].pos, 300, 400)
        end)

        it("emits outward_pan then spread", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 300, 200), down(1, 2, 300, 400))
            local g = h.frame(100, move(0, 300, 100), move(1, 300, 500))
            assert.are.same({ "outward_pan" }, names(g))
            assert.are.equal("vertical", g[1].direction)
            assert.are.equal(400, g[1].span)
            assert.are.equal(200, g[1].start_span)
            assertPos(g[1].pos, 300, 300)
            g = h.frame(150, up(0), up(1))
            assert.are.same({ "spread" }, names(g))
            assert.are.equal(400, g[1].span)
        end)

        it("emits a clockwise rotate around the still contact", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 300, 300), down(1, 2, 300, 500))
            h.frame(100, move(0, 500, 500))
            local g = h.frame(150, up(0))
            assert.are.same({ "rotate" }, names(g))
            assert.are.equal("cw", g[1].direction)
            assert.is_near(90, g[1].angle, 1e-6)
            assertPos(g[1].pos, 300, 500)
            assert.are.same({}, h.frame(200, up(1)))
            assert.are.equal(0, h.gd.contact_count)
        end)

        it("emits a counter-clockwise rotate", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 300, 300), down(1, 2, 300, 500))
            h.frame(100, move(0, 100, 500))
            local g = h.frame(150, up(0))
            assert.are.equal("rotate", g[1].ges)
            assert.are.equal("ccw", g[1].direction)
            assert.is_near(-90, g[1].angle, 1e-6)
        end)

        it("emits a rotate when the pivot is lifted before the panning contact", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 300, 500), down(1, 2, 300, 300))
            h.frame(100, move(1, 500, 500))
            local g = h.frame(150, up(0))
            assert.are.same({ "rotate" }, names(g))
            assert.are.equal("cw", g[1].direction)
            assertPos(g[1].pos, 300, 500)
            -- The panning contact is only dropped on its actual lift, without emitting anything
            assert.are.equal(1, h.gd.contact_count)
            assert.are.equal(2, h.slots[1].id)
            assert.are.same({}, h.frame(160, move(1, 520, 520)))
            assert.are.same({}, h.frame(170, up(1)))
            assert.are.equal(0, h.gd.contact_count)
        end)

        it("emits a rotate when a two-finger hold turns into a pan around the held pivot", function()
            local h = newHarness()
            twoDown(h)
            assert.are.equal("two_finger_hold", h.fire("hold", 0).ges)
            -- The buddy moves while the main contact holds still
            assert.are.same({}, h.frame(700, move(1, 100, 200)))
            assert.are.equal("rotate", h.gd:getContact(0).mt_gesture)
            assert.are.equal("pan", h.gd:getContact(1).mt_gesture)
            -- Both lifted in the same frame, pivot first (snow protocol style)
            local g = h.frame(800, up(0), up(1))
            assert.are.same({ "rotate" }, names(g))
            assertPos(g[1].pos, 100, 100)
            assert.is_near(90, g[1].angle, 1e-6)
            assert.are.equal(0, h.gd.contact_count)
        end)

        it("waits for both coordinates before adding a buddy contact", function()
            local h = newHarness()
            assert.are.same({}, h.frame(0, { slot = 1, id = 2 }))
            assert.are.same({ "touch" }, names(h.frame(10, down(0, 1, 100, 100))))
            assert.is_nil(h.gd:getContact(1))
            assert.are.same({ "touch" }, names(h.frame(20, move(1, 200, 100))))
            local g = h.frame(60, up(0), up(1))
            assert.are.same({ "two_finger_tap" }, names(g))
            assertPos(g[1].pos, 150, 100)
            assert.are.equal(100, g[1].span)
        end)
    end)

    describe("incomplete input frames", function()
        for _, first_slot in ipairs({ 0, 1 }) do
            for _, missing in ipairs({ "both", "x", "y" }) do
                it("ignores slot " .. first_slot .. " without " .. missing .. " before a buddy pan", function()
                    local h = newHarness()
                    local incomplete = { slot = first_slot, id = 10 }
                    if missing == "x" then incomplete.y = 100 end
                    if missing == "y" then incomplete.x = 100 end
                    assert.are.same({}, h.frame(0, incomplete))
                    local valid_slot = 1 - first_slot
                    assert.are.same({ "touch" }, names(h.frame(10, down(valid_slot, 20, 200, 200))))
                    assert.are.same({ "pan" }, names(h.frame(20, move(valid_slot, 300, 200))))
                    assert.are.same({ "swipe" }, names(h.frame(30, up(valid_slot))))
                    assert.are.same({}, h.frame(40, up(first_slot)))
                    assert.are.equal(0, h.gd.contact_count)
                    assert.are.equal(0, #h.timers)
                end)

                it("ignores a new slot " .. first_slot .. " without " .. missing .. " beside an existing contact", function()
                    local h = newHarness()
                    local valid_slot = 1 - first_slot
                    h.frame(0, down(valid_slot, 20, 200, 200))
                    local incomplete = { slot = first_slot, id = 10 }
                    if missing == "x" then incomplete.y = 100 end
                    if missing == "y" then incomplete.x = 100 end
                    assert.are.same({}, h.frame(10, incomplete))
                    assert.are.same({ "pan" }, names(h.frame(20, move(valid_slot, 300, 200))))
                    assert.are.same({ "swipe" }, names(h.frame(30, up(valid_slot))))
                    assert.are.same({}, h.frame(40, up(first_slot)))
                    assert.are.equal(0, h.gd.contact_count)
                    assert.are.equal(0, #h.timers)
                end)
            end
        end

        it("does not arm timers or fabricate a hold for a partial slot", function()
            local h = newHarness()
            h.frame(0, { slot = 1, id = 10, x = 0 })
            h.frame(10, down(0, 20, 200, 200))
            assert.are.equal(1, h.pending("hold"))
            assert.are.equal("hold", h.fire("hold", 0).ges)
            assert.are.same({ "hold_release" }, names(h.frame(700, up(0))))
            assert.are.same({}, h.frame(710, up(1)))
            assert.are.equal(0, h.gd.contact_count)
            assert.are.equal(0, #h.timers)
        end)

        it("admits late zero coordinates and retains ordinary two-finger taps", function()
            local h = newHarness()
            h.frame(0, { slot = 1, id = 10, x = 0 })
            h.frame(10, down(0, 20, 100, 0))
            assert.are.same({ "touch" }, names(h.frame(20, { slot = 1, y = 0 })))
            local g = h.frame(30, up(0), up(1))
            assert.are.same({ "two_finger_tap" }, names(g))
            assertPos(g[1].pos, 50, 0)
            assert.are.equal(100, g[1].span)
            assert.are.equal(0, h.gd.contact_count)
            assert.are.equal(0, #h.timers)
        end)
    end)

    describe("partial frame ordering", function()
        it("accepts both late contacts in the same frame without phantom gestures", function()
            local h = newHarness()
            assert.are.same({}, h.frame(0, down(0, 1), down(1, 2)))
            assert.are.equal(0, h.gd.contact_count)
            assert.are.same({ "touch", "touch" }, names(h.frame(10, move(1, 200, 100), move(0, 100, 100))))
            assert.are.same({ "two_finger_tap" }, names(h.frame(30, up(0), up(1))))
            assert.are.equal(0, h.gd.contact_count)
            assert.are.equal(0, #h.timers)
        end)

        it("does not emit a touch when late coordinates arrive after a skipped lift", function()
            local h = newHarness()
            h.frame(0, down(0, 1))
            h.frame(10, up(0))
            assert.are.same({}, h.frame(20, move(0, 100, 100)))
            assert.are.equal(0, h.gd.contact_count)
            assert.are.equal(0, #h.timers)
            assert.are.same({ "touch" }, names(h.frame(30, down(0, 2, 100, 100))))
            assert.are.same({ "tap" }, names(h.frame(40, up(0))))
            assert.are.equal(0, h.gd.contact_count)
        end)

        for _, invalid_first in ipairs({ true, false }) do
            it("keeps mixed-frame pan order safe: " .. tostring(invalid_first), function()
                local h = newHarness()
                h.frame(0, down(0, 1, 100, 100))
                local partial, valid = down(1, 2), move(0, 200, 100)
                local g
                if invalid_first then g = h.frame(10, partial, valid)
                else g = h.frame(10, valid, partial) end
                assert.are.same({ "pan" }, names(g))
                assert.are.same({ "swipe" }, names(h.frame(20, up(1), up(0))))
                assert.are.equal(0, h.gd.contact_count)
                assert.are.equal(0, #h.timers)
            end)
        end

        it("preserves coordinate-first tracking-id-later input", function()
            local h = newHarness()
            assert.are.same({}, h.frame(0, move(1, 200, 100)))
            h.frame(10, down(0, 1, 100, 100))
            assert.are.same({ "touch" }, names(h.frame(20, { slot = 1, id = 2 })))
            assert.are.same({ "two_finger_tap" }, names(h.frame(30, up(0), up(1))))
            assert.are.equal(0, h.gd.contact_count)
            assert.are.equal(0, #h.timers)
        end)
    end)

    describe("bookkeeping", function()
        it("only counts a contact once when it is dropped twice", function()
            local h = newHarness()
            h.frame(0, down(0, 1, 10, 10))
            local contact = h.gd:getContact(0)
            h.gd:dropContact(contact)
            h.gd:dropContact(contact)
            assert.are.equal(0, h.gd.contact_count)
            assert.are.equal(0, #h.timers)
        end)

        it("drops every contact and its timers at once", function()
            local h = newHarness({ double_tap = true })
            h.frame(0, down(0, 1, 10, 10))
            h.frame(30, up(0))
            -- Slot 3 is not a buddy of the main finger slot
            assert.are.same({ "touch" }, names(h.frame(35, down(3, 2, 300, 300))))
            assert.are.equal(1, h.pending("double_tap", 0))
            assert.are.equal(1, h.pending("hold", 3))
            h.gd:dropContacts()
            assert.are.equal(0, h.gd.contact_count)
            assert.are.equal(0, #h.timers)
            assert.is_nil(h.gd:getContact(3))
            -- A later lift of the dropped contact is not turned into a gesture
            assert.are.same({}, h.frame(40, up(3)))
        end)

        it("computes signed rotation angles", function()
            local h = newHarness()
            local Geom = require("ui/geometry")
            local o = Geom:new{ x = 0, y = 0 }
            assert.is_near(90, h.gd:getRotate(o, Geom:new{ x = 0, y = -10 }, Geom:new{ x = 10, y = 0 }), 1e-6)
            assert.is_near(-90, h.gd:getRotate(o, Geom:new{ x = 10, y = 0 }, Geom:new{ x = 0, y = -10 }), 1e-6)
            -- Crossing the -x axis wraps around instead of reporting -340
            assert.is_near(20, h.gd:getRotate(o, Geom:new{ x = -10, y = 1.7632698 }, Geom:new{ x = -10, y = -1.7632698 }), 1e-3)
        end)
    end)

    describe("clock source probing", function()
        local saved
        before_each(function()
            saved = {
                realtime_coarse = time.realtime_coarse,
                monotonic_coarse = time.monotonic_coarse,
                boottime = time.boottime,
            }
            time.realtime_coarse = function() return time.s(1700000000) end
            time.monotonic_coarse = function() return time.s(5000) end
            time.boottime = function() return time.s(9000) end
        end)
        after_each(function()
            for k, v in pairs(saved) do
                time[k] = v
            end
        end)

        local function probe(timev)
            local h = newHarness()
            h.gd:resetClockSource()
            assert.is_nil(h.gd:getClockSource())
            h.gd:probeClockSource(timev)
            return h.gd:getClockSource()
        end

        it("recognizes each clock", function()
            assert.are.equal(C.CLOCK_REALTIME, probe(time.s(1700000001)))
            assert.are.equal(C.CLOCK_MONOTONIC, probe(time.s(5002)))
            assert.are.equal(C.CLOCK_BOOTTIME, probe(time.s(8998)))
        end)

        it("flags an inconclusive probe", function()
            assert.are.equal(-1, probe(time.s(42)))
            -- Outside of the 2.5s window
            assert.are.equal(-1, probe(time.s(5003)))
        end)

        it("skips boottime when the platform reports none", function()
            time.boottime = function() return 0 end
            assert.are.equal(-1, probe(time.s(1)))
        end)

        it("is probed on the first tap", function()
            local h = newHarness()
            h.gd:resetClockSource()
            local base = time.s(5000)
            h.base = base
            h.frame(0, down(0, 1, 10, 10))
            assert.are.equal(C.CLOCK_MONOTONIC, h.gd:getClockSource())
        end)
    end)

    describe("adjustGesCoordinate", function()
        local function rotated(mode)
            return newHarness({ rotation = mode }).gd
        end

        it("leaves gestures alone when upright", function()
            local Geom = require("ui/geometry")
            local ges = { ges = "pan", direction = "east", pos = Geom:new{ x = 1, y = 2 }, relative = { x = 3, y = 4 } }
            rotated(0):adjustGesCoordinate(ges)
            assert.are.equal("east", ges.direction)
            assertPos(ges.pos, 1, 2)
            assert.are.equal(3, ges.relative.x)
        end)

        it("rotates positions, relative motion & directions clockwise", function()
            local Geom = require("ui/geometry")
            local ges = {
                ges = "hold_pan", direction = "northeast",
                pos = Geom:new{ x = 100, y = 200 }, start_pos = Geom:new{ x = 50, y = 60 },
                relative = { x = 10, y = 20 },
            }
            rotated(1):adjustGesCoordinate(ges)
            assertPos(ges.pos, 400, 100)
            assertPos(ges.start_pos, 540, 50)
            assert.are.equal(-20, ges.relative.x)
            assert.are.equal(10, ges.relative.y)
            assert.are.equal("southeast", ges.direction)
        end)

        it("rotates counter-clockwise and swaps pinch axes", function()
            local Geom = require("ui/geometry")
            local ges = { ges = "two_finger_pan", direction = "south", pos = Geom:new{ x = 100, y = 200 }, relative = { x = 10, y = 20 } }
            local gd = rotated(3)
            gd:adjustGesCoordinate(ges)
            assertPos(ges.pos, 200, 700)
            assert.are.equal(20, ges.relative.x)
            assert.are.equal(-10, ges.relative.y)
            assert.are.equal("east", ges.direction)

            local pinch = { ges = "pinch", direction = "horizontal", pos = Geom:new{ x = 0, y = 0 } }
            gd:adjustGesCoordinate(pinch)
            assert.are.equal("vertical", pinch.direction)
            local spread = { ges = "spread", direction = "vertical", pos = Geom:new{ x = 0, y = 0 } }
            gd:adjustGesCoordinate(spread)
            assert.are.equal("horizontal", spread.direction)
            local multi = { ges = "multiswipe", direction = "east", multiswipe_directions = "east north" }
            gd:adjustGesCoordinate(multi)
            assert.are.equal("north", multi.direction)
            assert.are.equal("north west", multi.multiswipe_directions)
        end)

        it("swaps pinch axes when rotated clockwise, but keeps diagonals", function()
            local Geom = require("ui/geometry")
            local gd = rotated(1)
            local ges = { ges = "outward_pan", direction = "vertical", pos = Geom:new{ x = 0, y = 0 } }
            gd:adjustGesCoordinate(ges)
            assert.are.equal("horizontal", ges.direction)
            ges = { ges = "inward_pan", direction = "horizontal", pos = Geom:new{ x = 0, y = 0 } }
            gd:adjustGesCoordinate(ges)
            assert.are.equal("vertical", ges.direction)
            ges = { ges = "pinch", direction = "diagonal", pos = Geom:new{ x = 0, y = 0 } }
            gd:adjustGesCoordinate(ges)
            assert.are.equal("diagonal", ges.direction)
        end)

        it("flips everything upside down, but only positions for taps", function()
            local Geom = require("ui/geometry")
            local gd = rotated(2)
            local ges = {
                ges = "multiswipe", direction = "northwest", multiswipe_directions = "east north",
                pos = Geom:new{ x = 100, y = 200 }, end_pos = Geom:new{ x = 10, y = 20 },
                relative = { x = 10, y = 20 },
            }
            gd:adjustGesCoordinate(ges)
            assertPos(ges.pos, 500, 600)
            assertPos(ges.end_pos, 590, 780)
            assert.are.equal(-10, ges.relative.x)
            assert.are.equal(-20, ges.relative.y)
            assert.are.equal("southeast", ges.direction)
            assert.are.equal("west south", ges.multiswipe_directions)

            local tap = { ges = "tap", pos = Geom:new{ x = 100, y = 200 } }
            gd:adjustGesCoordinate(tap)
            assertPos(tap.pos, 500, 600)
            assert.is_nil(tap.direction)
            local pinch = { ges = "pinch", direction = "horizontal", pos = Geom:new{ x = 0, y = 0 } }
            gd:adjustGesCoordinate(pinch)
            assert.are.equal("horizontal", pinch.direction)
        end)
    end)
end)
