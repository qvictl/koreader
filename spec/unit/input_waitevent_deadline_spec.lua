-- Input:waitEvent must hand control back to UIManager once the UI deadline (next scheduled task,
-- nextTick, PM early return...) is reached, even when a gesture timer (hold, double_tap) is pending
-- further away. It used to keep polling with a zero timeout until the gesture timer expired:
-- scheduled tasks were delayed by up to the hold interval while the CPU spun.
describe("Input:waitEvent UI deadline with pending gesture timers", function()
    local Input, time, ffi, C
    local saved_now, fake_now

    setup(function()
        require("commonrequire")
        ffi = require("ffi")
        C = ffi.C
        require("ffi/posix_h")
        require("ffi/linux_input_h")
        Input = require("device/input")
        time = require("ui/time")
    end)

    before_each(function()
        saved_now = time.now
        fake_now = time.s(1000)
        time.now = function() return fake_now end
    end)

    after_each(function()
        time.now = saved_now
    end)

    -- A backend whose poll "sleeps" for its timeout on our fake clock, and never sees any input.
    -- A non-blocking poll still costs 1ms, so a busy loop always ends up reaching the timer deadline.
    local function newInput(with_timerfd)
        local backend = { polls = {} }
        local armed = {}
        function backend.waitForEvent(sec, usec)
            local timeout = sec and (time.s(sec) + time.us(usec)) or nil
            table.insert(backend.polls, timeout or false)
            local wake = fake_now + (timeout and math.max(timeout, time.ms(1)) or time.s(3600))
            -- A kernel timer expiring before the poll timeout wakes us up early
            for i, t in ipairs(armed) do
                if t.deadline <= wake then
                    fake_now = math.max(fake_now, t.deadline)
                    table.remove(armed, i)
                    return false, C.ETIME, t.fd
                end
            end
            fake_now = wake
            return false, C.ETIME
        end
        if with_timerfd then
            function backend.setTimer(_, sec, usec)
                local fd = "timerfd" .. (#armed + 1)
                table.insert(armed, { fd = fd, deadline = time.s(sec) + time.us(usec) })
                return fd
            end
            function backend.clearTimer() end
        end
        local inp = Input:new{
            device = {
                isSDL = function() return false end,
                screen = { scaleByDPI = function(_, v) return v end },
            },
            input = backend,
            event_map = {},
            modifiers = {},
            fake_event_args = {},
        }
        inp.gesture_detector.active_contacts = {}
        inp.gesture_detector.clock_id = C.CLOCK_MONOTONIC
        return inp, backend
    end

    for _, with_timerfd in ipairs({ false, true }) do
        local backend_name = with_timerfd and "timerfd" or "poll timeout"
        describe("with the " .. backend_name .. " backend", function()
            it("returns at the UI deadline when a later gesture timer is pending", function()
                local inp, backend = newInput(with_timerfd)
                local fired = false
                inp:setTimeout(0, "hold", function() fired = true end, fake_now, time.ms(500))
                local start = fake_now

                assert.is_nil(inp:waitEvent(fake_now, start + time.ms(100)))

                assert.are.equal(start + time.ms(100), fake_now)
                assert.is_false(fired)
                assert.are.equal(1, #backend.polls)
                -- The timer is still there for the next call...
                assert.are.equal(1, #inp.timer_callbacks)
                -- ...and fires once its deadline is reached
                assert.is_nil(inp:waitEvent(fake_now, start + time.s(5)))
                assert.is_true(fired)
                assert.are.equal(start + time.ms(500), fake_now)
                assert.are.equal(0, #inp.timer_callbacks)
            end)

            it("returns immediately for a blown UI deadline (e.g., nextTick) while a timer is pending", function()
                local inp, backend = newInput(with_timerfd)
                inp:setTimeout(0, "hold", function() end, fake_now, time.ms(500))
                local start = fake_now

                assert.is_nil(inp:waitEvent(fake_now, start))

                assert.are.equal(1, #backend.polls)
                assert.are.equal(0, backend.polls[1])
                assert.is_true(fake_now - start <= time.ms(1))
                assert.are.equal(1, #inp.timer_callbacks)
            end)
        end)
    end

    it("still consumes a gesture timer that expired by the time the UI deadline is reached", function()
        local inp = newInput(false)
        local fired = false
        inp:setTimeout(0, "hold", function() fired = true end, fake_now, time.ms(50))
        -- The timer deadline is earlier: it is polled for, then consumed
        assert.is_nil(inp:waitEvent(fake_now, fake_now + time.ms(100)))
        assert.is_true(fired)
    end)
end)
