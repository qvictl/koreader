return {
    name = "Inverted widget frames respect viewport and RGB24 pixel boundaries",
    timeout = 60,
    run = function(T)
        local bit = require("bit")
        local ffi = require("ffi")
        local Blitbuffer = require("ffi/blitbuffer")
        local Font = require("ui/font")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local TextWidget = require("ui/widget/textwidget")
        local original_cbb = Blitbuffer:getUseCBB()
        local formats = {
            { "BB8", Blitbuffer.TYPE_BB8, 1, 1 },
            { "BB8A", Blitbuffer.TYPE_BB8A, 2, 1 },
            { "RGB16", Blitbuffer.TYPE_BBRGB16, 2, 2 },
            { "RGB24", Blitbuffer.TYPE_BBRGB24, 3, 3 },
            { "RGB32", Blitbuffer.TYPE_BBRGB32, 4, 3 },
        }
        local ok, err = xpcall(function()
            for _, use_cbb in ipairs({ false, true }) do
                Blitbuffer:setUseCBB(use_cbb)
                for _, format in ipairs(formats) do
                    local label = format[1] .. (use_cbb and " C" or " Lua")
                    local text = TextWidget:new{ text = "Reader", face = Font:getFace("cfont", 18) }
                    local size = text:getSize()
                    local w, h = size.w + 8, size.h + 8
                    local frame = FrameContainer:new{
                        bordersize = 0, padding = 0, margin = 0, width = w, height = h, text,
                    }
                    local parent = Blitbuffer.new(w + 7, h + 4, format[2])
                    parent:fill(Blitbuffer.Color8(0x65))
                    local viewport = parent:viewport(3, 2, w, h)
                    local initial = Blitbuffer.tostring(parent)
                    local before, observed
                    T:run(function()
                        frame:paintTo(viewport, 0, 0)
                        before = Blitbuffer.tostring(parent)
                        ffi.copy(parent.data, initial, #initial)
                        frame.invert = true
                        frame:paintTo(viewport, 0, 0)
                        observed = Blitbuffer.tostring(parent)
                    end)
                    local expected = ffi.new("uint8_t[?]", #before)
                    ffi.copy(expected, before, #before)
                    for y = 2, h + 1 do
                        for x = 3, w + 2 do
                            local start = tonumber(parent.stride) * y + x * format[3]
                            for channel = 0, format[4] - 1 do
                                expected[start + channel] = bit.bxor(expected[start + channel], 0xFF)
                            end
                        end
                    end
                    T:check(observed == ffi.string(expected, #before),
                        label .. " real frame inversion preserves adjacent pixels and alpha")
                    viewport:invertRect(0, 0, w, h)
                    T:check(Blitbuffer.tostring(parent) == before, label .. " repeated inversion restores text pixels")
                    T:eq(frame.dimen.w, size.w, label .. " child layout width is unchanged")
                    T:eq(frame.dimen.h, size.h, label .. " child layout height is unchanged")
                    frame:free()
                    parent:free()
                end
            end
        end, debug.traceback)
        Blitbuffer:setUseCBB(original_cbb)
        if not ok then error(err, 0) end
        local ui = T:openBook(T:fixture("books/en.epub"))
        local page = ui:getCurrentPage()
        T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
        T:waitUntil(function() return ui:getCurrentPage() == page + 1 end, 5, "page turn after widget rendering")
        T:closeBook()
        ui = T:openBook(T:fixture("books/en.epub"))
        T:eq(ui:getCurrentPage(), page + 1, "reopening retains reading progress after widget rendering")
        T:closeBook()
    end,
}
