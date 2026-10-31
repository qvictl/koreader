-- Replay protocol-B frames through real Input and GestureDetector, then deliver
-- their gestures to ReaderUI. No touchscreen or native input backend is replaced.
return {
    name = "Incomplete multitouch slots do not crash reading",
    timeout = 60,
    run = function(T)
        local Device = require("device")
        local Input = require("device/input")
        local UIManager = require("ui/uimanager")
        local time = require("ui/time")
        local C = require("ffi").C
        local ui = T:openBook(T:fixture("books/en.epub"))
        local start_x = math.floor(T.screen_w * 0.8)
        local end_x = math.floor(T.screen_w * 0.2)
        local y = math.floor(T.screen_h * 0.5)

        for _, partial_first in ipairs({ true, false }) do
            for _, missing in ipairs({ "both", "x", "y" }) do
                local before = ui:getCurrentPage()
                T:run(function()
                    local input = Input:new{ device = Device, input = Device.input.input }
                    local base = time.now()
                    local names = {}
                    local function frame(ms, slot, id, x, py)
                        local sec, usec = time.split_s_us(base + time.ms(ms))
                        local stamp = { sec = sec, usec = usec }
                        local function event(kind, code, value)
                            return input:handleTouchEv{ type = kind, code = code, value = value, time = stamp }
                        end
                        event(C.EV_ABS, C.ABS_MT_SLOT, slot)
                        if id ~= nil then event(C.EV_ABS, C.ABS_MT_TRACKING_ID, id) end
                        if x ~= nil then event(C.EV_ABS, C.ABS_MT_POSITION_X, x) end
                        if py ~= nil then event(C.EV_ABS, C.ABS_MT_POSITION_Y, py) end
                        local gestures = event(C.EV_SYN, C.SYN_REPORT, 0)
                        for _, gesture in ipairs(gestures) do
                            names[#names + 1] = gesture.args[1].ges
                            UIManager:handleInputEvent(gesture)
                        end
                        return #gestures
                    end
                    local function partial(ms)
                        T:eq(frame(ms, 1, 12, missing == "y" and 100 or nil,
                            missing == "x" and 100 or nil), 0, "partial slot emits no gesture")
                    end
                    if partial_first then
                        partial(0)
                        frame(10, 0, 11, start_x, y)
                    else
                        frame(0, 0, 11, start_x, y)
                        partial(10)
                    end
                    frame(20, 0, nil, end_x, y)
                    frame(30, 0, -1)
                    T:eq(frame(40, 1, -1), 0, "lifting partial slot emits no gesture")
                    T:eq(names, { "touch", "pan", "swipe" }, "valid contact remains a single swipe")
                    T:eq(input.gesture_detector.contact_count, 0, "all contacts released")
                    T:eq(#input.timer_callbacks, 0, "all contact timers released")
                end)
                T:waitUntil(function() return ui:getCurrentPage() == before + 1 end, 5,
                    "page turn with incomplete slot " .. missing .. " (first=" .. tostring(partial_first) .. ")")
                T:check(ui:getCurrentPage() == before + 1, "raw input swipe turns exactly one reader page")
            end
        end
        T:closeBook()
        ui = T:openBook(T:fixture("books/en.epub"))
        local page = ui:getCurrentPage()
        T:tap(math.floor(T.screen_w * 0.9), y)
        T:waitUntil(function() return ui:getCurrentPage() == page + 1 end, 5, "tap after reopening")
        T:check(ui:getCurrentPage() == page + 1, "normal input remains usable after close and reopen")
        T:closeBook()
    end,
}
