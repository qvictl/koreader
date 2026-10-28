describe("Screensaver overlay message", function()
    local Blitbuffer, Device, Screensaver, UIManager

    setup(function()
        require("commonrequire")
        Blitbuffer = require("ffi/blitbuffer")
        Device = require("device")
        Screensaver = require("ui/screensaver")
        UIManager = require("ui/uimanager")
    end)

    local orig_mode
    before_each(function()
        orig_mode = Device.screen_saver_mode
        stub(UIManager, "show")
    end)

    after_each(function()
        UIManager.show:revert()
        Screensaver:cleanup()
        Screensaver.ui = nil
        Device.screen_saver_mode = orig_mode
    end)

    local function countDarkPixels(widget)
        local size = widget:getSize()
        local w, h = math.max(size.w, 1), math.max(size.h, 1)
        local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        bb:fill(Blitbuffer.COLOR_WHITE)
        widget:paintTo(bb, 0, 0)
        local dark = 0
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                if bb:getPixel(x, y):getColor8().a < 0x80 then
                    dark = dark + 1
                end
            end
        end
        bb:free()
        return dark
    end

    it("is painted on poweroff with an as-is screensaver and no message", function()
        -- What Screensaver:setup("poweroff", "Powered off") ends up with in that configuration
        Screensaver.ui = {}
        Screensaver.screensaver_type = "disable"
        Screensaver.show_message = false
        Screensaver.prefix = "poweroff_"
        Screensaver.event_message = "Powered off"
        Screensaver.overlay_message = "Powered off"
        Screensaver.screensaver_background = "none"

        Screensaver:show()

        assert.is_truthy(Screensaver.screensaver_widget)
        local overlay = Screensaver.screensaver_widget.widget
        assert.is_truthy(overlay[1])
        assert.is_true(overlay:getSize().h > 0)
        assert.is_true(countDarkPixels(overlay) > 0)
    end)
end)
