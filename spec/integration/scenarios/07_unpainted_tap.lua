-- Taps on buttons that have not been painted yet (e.g. a tap dispatched in the same input
-- batch that opened their parent) must not crash (#16288), must not trigger them, and the
-- buttons must work normally once painted.
return {
    name = "Tap on unpainted buttons",
    timeout = 60,
    settings = {
        flash_ui = true, -- the crash was in the tap feedback highlight
    },
    run = function(T)
        local UIManager = require("ui/uimanager")
        local Button = require("ui/widget/button")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local Geom = require("ui/geometry")
        local IconButton = require("ui/widget/iconbutton")
        local Screen = require("device").screen
        local VerticalGroup = require("ui/widget/verticalgroup")

        local calls = { icon = 0, button = 0 }
        local function makeWindow()
            local icon = IconButton:new{
                icon = "close",
                width = Screen:scaleBySize(40),
                height = Screen:scaleBySize(40),
                callback = function() calls.icon = calls.icon + 1 end,
            }
            local button = Button:new{
                text = "Integration OK",
                width = math.floor(T.screen_w / 2),
                callback = function() calls.button = calls.button + 1 end,
            }
            local window = CenterContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = T.screen_w, h = T.screen_h },
                FrameContainer:new{ VerticalGroup:new{ icon, button } },
            }
            icon.show_parent = window
            button.show_parent = window
            return window, icon, button
        end

        -- Show a window and tap where its (unpainted) buttons' placeholder gesture ranges are,
        -- in the same UI tick: no paint in between.
        for _, target in ipairs({ "icon", "button" }) do
            local window, icon, button = makeWindow()
            T:run(function()
                UIManager:show(window)
                local w = target == "icon" and icon or button
                -- (Before being painted, their gesture ranges are their placeholder dimen, at 0,0.)
                local d = w.dimen
                UIManager:sendEvent(T:tapEvent((d and d.x or 0) + 2, (d and d.y or 0) + 2))
            end)
            T:wait(0.5)
            T:eq(calls[target], 0, "tap on the unpainted " .. target .. " is ignored")
            -- Once painted, the buttons work.
            T:repaint()
            T:tapWidget(target == "icon" and icon.image or button, "painted " .. target)
            T:waitUntil(function() return calls[target] == 1 end, 5, "painted " .. target .. " callback")
            T:run(function() UIManager:close(window) end)
            calls.icon, calls.button = 0, 0
        end

        -- UIManager:widgetInvert on a never painted widget (no dimen) is a no-op.
        local _, icon = makeWindow()
        T:run(function() UIManager:widgetInvert(icon.image) end)
        T:check(true, "widgetInvert on an unpainted widget did not crash")

        -- widgetInvert of a button inside a scrolling ButtonDialog (whose ScrollableContainer is
        -- its cropping_widget): only the visible part is inverted, and inverting twice restores it.
        local ButtonDialog = require("ui/widget/buttondialog")
        local rows = {}
        for i = 1, 60 do -- (taller than the screen: it scrolls)
            table.insert(rows, { { text = "Row " .. i, callback = function() end } })
        end
        local dialog = ButtonDialog:new{ title = "Scrolling dialog", buttons = rows }
        T:run(function() UIManager:show(dialog) end)
        T:repaint()
        T:check(dialog.cropping_widget, "the dialog scrolls (has a cropping widget)")
        local row1 = T:findWidget(dialog.buttontable, function(w)
            return w.text == "Row 1" and w.dimen
        end)
        T:check(row1 and row1.dimen, "first row button painted")
        local bb = require("device").screen.bb
        local function pixel()
            return bb:getPixel(row1.dimen.x + 2, row1.dimen.y + 2):getColor8().a
        end
        local before = pixel()
        T:run(function() UIManager:widgetInvert(row1, row1.dimen.x, row1.dimen.y) end)
        T:check(pixel() ~= before, "button inverted within the cropped area")
        T:run(function() UIManager:widgetInvert(row1, row1.dimen.x, row1.dimen.y) end)
        T:eq(pixel(), before, "inverted back")
        T:run(function() UIManager:close(dialog) end)

        -- And the reader still works after all that.
        local ui = T:openBook(T:fixture("books/en.epub"))
        T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
        T:waitUntil(function() return ui:getCurrentPage() == 2 end, 5, "page turn")
        T:closeBook()
    end,
}
