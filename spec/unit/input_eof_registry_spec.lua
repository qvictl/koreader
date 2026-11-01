describe("native input EOF registry", function()
    local Input, Device, C, time, saved_devices
    setup(function()
        require("commonrequire")
        Input = require("device/input")
        Device = require("device")
        C = require("ffi").C
        time = require("ui/time")
    end)
    before_each(function()
        saved_devices = Input.opened_devices
        Input.opened_devices = {}
    end)
    after_each(function() Input.opened_devices = saved_devices end)

    for _, with_timer in ipairs({ false, true }) do
        for _, with_events in ipairs({ false, true }) do
            it("forgets retired fds before dispatch, timers=" .. tostring(with_timer)
                    .. ", final events=" .. tostring(with_events), function()
                local closed = {}
                local backend = {
                    fdopen = function() end,
                    close = function(fd) closed[#closed + 1] = fd; return true end,
                    open = function() return 77 end,
                    waitForEvent = function()
                        if with_events then
                            return true, {{ type = C.EV_KEY, code = 30, value = 1,
                                fd = 42, time = { sec = 0, usec = 0 } }}, nil, 42
                        end
                        return false, C.EPIPE, nil, 42
                    end,
                }
                local input = Input:new{ device = Device, input = backend, event_map = { [30] = "A" } }
                input:fdopen(42, "ended")
                Input.opened_devices.alias = 42
                input:fdopen(43, "still-live")
                if with_timer then
                    input.timer_callbacks = {{ deadline = time.now() + time.s(10),
                        callback = function() error("EOF must not fire a future gesture timer") end }}
                end
                local adjusted = false
                input.eventAdjustHook = function()
                    adjusted = true
                    assert.is_nil(Input.opened_devices.ended)
                    assert.is_nil(Input.opened_devices.alias)
                    assert.are.equal(43, Input.opened_devices["still-live"])
                end
                local now = time.now()
                local events = input:waitEvent(now, now)
                assert.is_nil(Input.opened_devices.ended)
                assert.is_nil(Input.opened_devices.alias)
                assert.are.equal(43, Input.opened_devices["still-live"])
                assert.are.equal(with_events, adjusted)
                assert.are.equal(with_events and "onKeyPress" or "onInputError", events[1].handler)
                if not with_events then assert.are.equal(tonumber(C.EPIPE), events[1].args[1]) end
                -- Model immediate reuse of the retired descriptor by another input.
                input:fdopen(42, "replacement")
                input:close("ended")
                assert.are.equal(0, #closed)
                assert.are.equal(42, Input.opened_devices.replacement)
                -- The old path can be reopened instead of being suppressed by stale state.
                assert.are.equal(77, input:open("ended"))
                assert.are.equal(77, Input.opened_devices.ended)
                input:close("ended")
                assert.are.same({ 77 }, closed)
            end)
        end
    end

    it("keeps registered devices on legacy backends without retirement metadata", function()
        local backend = { fdopen = function() end, waitForEvent = function() return false, C.ETIME end }
        local input = Input:new{ device = Device, input = backend, event_map = {} }
        input:fdopen(42, "live")
        local now = time.now()
        assert.is_nil(input:waitEvent(now, now))
        assert.are.equal(42, Input.opened_devices.live)
    end)
end)
