describe("ReaderPaging navigation", function()
    local DataStorage, DocSettings, DocumentRegistry, Event, LuaSettings, ReaderUI, Screen, UIManager, time
    local sample_pdf
    local readerui, paging

    -- Lightweight overrides (luassert spies deep-copy their arguments, which is
    -- far too costly with ReaderUI/Document objects as self).
    local restores = {}
    local function override(obj, key, fn)
        local old = rawget(obj, key)
        obj[key] = fn
        table.insert(restores, function() obj[key] = old end)
    end
    local function restore_all()
        for i = #restores, 1, -1 do restores[i]() end
        restores = {}
    end
    local function record_events(ui)
        local names = {}
        local args = {}
        local orig = ui.handleEvent
        override(ui, "handleEvent", function(this, ev)
            table.insert(names, ev.handler:sub(3))
            args[ev.handler:sub(3)] = ev.args
            return orig(this, ev)
        end)
        return names, args
    end
    local function count(list, name)
        local n = 0
        for _, v in ipairs(list) do
            if v == name then n = n + 1 end
        end
        return n
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        DataStorage = require("datastorage")
        DocSettings = require("docsettings")
        DocumentRegistry = require("document/documentregistry")
        Event = require("ui/event")
        LuaSettings = require("luasettings")
        ReaderUI = require("apps/reader/readerui")
        Screen = require("device").screen
        UIManager = require("ui/uimanager")
        time = require("ui/time")
        sample_pdf = DataStorage:getDataDir() .. "/readerpaging_nav.pdf"
        require("ffi/util").copyFile("spec/front/unit/data/sample.pdf", sample_pdf)
        DocSettings:open(sample_pdf):purge()
        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(sample_pdf),
        }
        paging = readerui.paging
    end)

    teardown(function()
        readerui:closeDocument()
        readerui:onClose()
    end)

    after_each(function()
        restore_all()
    end)

    local function set_page_mode(zoom_mode)
        readerui:handleEvent(Event:new("SetScrollMode", false))
        readerui.zooming:setZoomMode(zoom_mode or "page")
    end
    local function set_scroll_mode(zoom_mode)
        readerui:handleEvent(Event:new("SetScrollMode", true))
        readerui.zooming:setZoomMode(zoom_mode or "pagewidth")
    end

    describe("in page mode", function()
        before_each(function()
            set_page_mode("page")
            paging:onGotoPage(10)
        end)

        it("should clamp out-of-range onGotoPage requests", function()
            local nb = readerui.document:getPageCount()
            assert.are.equal(45, nb)
            paging:onGotoPage(nb + 100)
            assert.are.equal(nb, paging.current_page)
            paging:onGotoPage(-3)
            assert.are.equal(1, paging.current_page)
            paging:onGotoPage(0)
            assert.are.equal(1, paging.current_page)
        end)

        it("should resend PageUpdate when going to the current page", function()
            local names = record_events(readerui)
            paging:onGotoPage(10)
            assert.are.equal(10, paging.current_page)
            assert.are.equal(1, count(names, "PageUpdate"))
            assert.is_nil(paging.page_positions[10])
        end)

        it("should clamp onGotoPercent and onGotoPercentage", function()
            paging:onGotoPercent(150)
            assert.are.equal(45, paging.current_page)
            paging:onGotoPercent(0)
            assert.are.equal(1, paging.current_page)
            paging:onGotoPercent(50)
            assert.are.equal(22, paging.current_page)
            paging:onGotoPercentage(2)
            assert.are.equal(45, paging.current_page)
            paging:onGotoPercentage(-1)
            assert.are.equal(1, paging.current_page)
            paging:onGotoPercentage(0.5)
            assert.are.equal(22, paging.current_page)
        end)

        it("should stop onGotoRelativePage at document boundaries", function()
            paging:onGotoPage(40)
            paging:onGotoRelativePage(10)
            assert.are.equal(45, paging.current_page)
            paging:onGotoRelativePage(-100)
            assert.are.equal(1, paging.current_page)
            paging:onGotoRelativePage(3)
            assert.are.equal(4, paging.current_page)
        end)

        it("should turn several pages at once with onGotoViewRel", function()
            assert.is_true(paging:onGotoViewRel(5))
            assert.are.equal(15, paging.current_page)
            paging:onGotoViewRel(-5)
            assert.are.equal(10, paging.current_page)
            -- page position is reset to the top of the page in page mode
            assert.are.equal(0, paging:getTopPosition())
            assert.are.equal(10, paging:getTopPage())
        end)

        it("should emit EndOfBook and stay on page when jumping past the end", function()
            paging:onGotoPage(43)
            local names = record_events(readerui)
            paging:onGotoViewRel(5)
            assert.are.equal(43, paging.current_page)
            assert.are.equal(1, count(names, "EndOfBook"))
        end)

        it("should stay on the first page without EndOfBook when going back at start", function()
            paging:onGotoPage(1)
            local names = record_events(readerui)
            paging:onGotoViewRel(-1)
            paging:onGotoViewRel(-20)
            assert.are.equal(1, paging.current_page)
            assert.are.equal(0, count(names, "EndOfBook"))
        end)

        it("should not turn page when no_page_turn is requested", function()
            assert.is_nil(paging:onGotoViewRel(1, true))
            assert.are.equal(10, paging.current_page)
            -- a key event object as 2nd arg must not be taken as no_page_turn
            assert.is_true(paging:onGotoViewRel(1, { key = "RPgFwd" }))
            assert.are.equal(11, paging.current_page)
        end)

        it("should walk hidden flows page by page", function()
            local doc = readerui.document
            override(doc, "hasHiddenFlows", function() return true end)
            -- pretend even pages are hidden
            override(doc, "getNextPage", function(_, page)
                local p = page + 1
                if p % 2 == 0 then p = p + 1 end
                return p <= 45 and p or 0
            end)
            override(doc, "getPrevPage", function(_, page)
                local p = page - 1
                if p % 2 == 0 then p = p - 1 end
                return p >= 1 and p or 0
            end)
            paging:onGotoPage(11)
            paging:onGotoViewRel(2)
            assert.are.equal(15, paging.current_page)
            paging:onGotoViewRel(-1)
            assert.are.equal(13, paging.current_page)
            paging:onGotoPage(45)
            local names = record_events(readerui)
            paging:onGotoViewRel(1)
            assert.are.equal(45, paging.current_page)
            assert.are.equal(1, count(names, "EndOfBook"))
            paging:onGotoPage(1)
            paging:onGotoViewRel(-1)
            assert.are.equal(1, paging.current_page)
        end)

        it("should go forward whatever the reading direction settings", function()
            local zooming = readerui.zooming
            local configurable = readerui.document.configurable
            local orig_wd = configurable.writing_direction
            finally(function()
                zooming.zoom_direction_vertical = nil
                zooming.zoom_bottom_to_top = nil
                configurable.writing_direction = orig_wd
            end)
            zooming.zoom_direction_vertical = true
            configurable.writing_direction = 1
            zooming.zoom_bottom_to_top = true
            paging:onGotoViewRel(1)
            assert.are.equal(11, paging.current_page)
            zooming.zoom_direction_vertical = false
            paging:onGotoViewRel(1)
            assert.are.equal(12, paging.current_page)
            paging:onGotoViewRel(-1)
            assert.are.equal(11, paging.current_page)
        end)

        it("should turn pages with onGotoPosRel", function()
            assert.is_true(paging:onGotoPosRel(1))
            assert.are.equal(11, paging.current_page)
            paging:onGotoPosRel(-1)
            assert.are.equal(10, paging.current_page)
            -- onPanningRel does nothing in page mode
            assert.is_true(paging:onPanningRel(100))
            assert.are.equal(10, paging.current_page)
        end)

        it("should turn pages on swipe, honoring inverse reading order and disable setting", function()
            assert.is_true(paging:onSwipe(nil, { direction = "west" }))
            assert.are.equal(11, paging.current_page)
            assert.is_true(paging:onSwipe(nil, { direction = "east" }))
            assert.are.equal(10, paging.current_page)
            readerui.view.inverse_reading_order = true
            finally(function() readerui.view.inverse_reading_order = nil end)
            paging:onSwipe(nil, { direction = "west" })
            assert.are.equal(9, paging.current_page)
            paging:onSwipe(nil, { direction = "east" })
            assert.are.equal(10, paging.current_page)
            readerui.view.inverse_reading_order = nil
            G_reader_settings:makeTrue("page_turns_disable_swipe")
            finally(function() G_reader_settings:delSetting("page_turns_disable_swipe") end)
            assert.is_nil(paging:onSwipe(nil, { direction = "west" }))
            assert.is_nil(paging:onSwipe(nil, { direction = "east" }))
            assert.is_nil(paging:onSwipe(nil, { direction = "north" }))
            assert.are.equal(10, paging.current_page)
        end)

        it("should turn one page per mouse wheel step", function()
            paging:onPan(nil, { direction = "north", mousewheel_direction = -1, relative = { x = 0, y = 0 } })
            assert.are.equal(11, paging.current_page)
            paging:onPan(nil, { direction = "south", mousewheel_direction = 1, relative = { x = 0, y = 0 } })
            assert.are.equal(10, paging.current_page)
            -- horizontal pans are ignored
            assert.is_true(paging:onPan(nil, { direction = "east", relative = { x = 10, y = 0 } }))
            assert.are.equal(10, paging.current_page)
        end)

        it("should handle tap zones and the disable tap setting", function()
            local zones = readerui._zones
            assert.truthy(zones.tap_forward)
            zones.tap_forward.handler()
            assert.are.equal(11, paging.current_page)
            zones.tap_backward.handler()
            assert.are.equal(10, paging.current_page)
            zones.paging_swipe.handler({ direction = "west" })
            assert.are.equal(11, paging.current_page)
            G_reader_settings:makeTrue("page_turns_disable_tap")
            finally(function() G_reader_settings:delSetting("page_turns_disable_tap") end)
            assert.is_nil(zones.tap_forward.handler())
            assert.is_nil(zones.tap_backward.handler())
            assert.are.equal(11, paging.current_page)
        end)

        it("should pan inside a page before turning it in content width zoom", function()
            set_page_mode("contentwidth")
            paging:onGotoPage(10)
            local y0 = paging.visible_area.y
            assert.truthy(paging.page_area.h > paging.visible_area.h)
            paging:onGotoViewRel(1)
            assert.are.equal(10, paging.current_page)
            assert.truthy(paging.visible_area.y > y0)
            local turned = false
            for _ = 1, 10 do
                paging:onGotoViewRel(1)
                if paging.current_page == 11 then
                    turned = true
                    break
                end
            end
            assert.is_true(turned)
            -- going back shows the bottom of the previous page
            paging:onGotoViewRel(-1)
            assert.are.equal(10, paging.current_page)
            assert.truthy(paging.visible_area.y > paging.page_area.y)
        end)

        it("should update the dim area with page overlap enabled", function()
            set_page_mode("contentwidth")
            paging:onGotoPage(10)
            readerui.view.page_overlap_enable = true
            finally(function()
                readerui.view.page_overlap_enable = false
                readerui.view.dim_area:clear()
            end)
            paging:onGotoViewRel(1)
            assert.are.equal(10, paging.current_page)
            local dim = readerui.view.dim_area
            assert.truthy(dim.h > 0)
            assert.truthy(dim.h < paging.visible_area.h)
            assert.are.equal(0, dim.y)
            assert.are.equal(0, dim.x)
            -- going back dims the bottom part
            paging:onGotoViewRel(-1)
            assert.truthy(dim.y > 0)
            -- turning to another page clears it
            paging:onGotoPage(20)
            paging:onGotoViewRel(-1)
            assert.are.equal(19, paging.current_page)
            assert.is_true(dim:isEmpty())
        end)

        it("should restore a saved book location", function()
            assert.is_nil(paging:onRestoreBookLocation(nil))
            assert.is_nil(paging:onRestoreBookLocation({}))
            local location = paging:getBookLocation()
            assert.truthy(location and location[1])
            assert.are.equal(10, location[1].page)
            paging:onGotoPage(30)
            assert.is_true(paging:onRestoreBookLocation(location))
            assert.are.equal(10, paging.current_page)
            -- restoring onto the current page still sends a PageUpdate
            local names = record_events(readerui)
            paging:onRestoreBookLocation(location)
            assert.truthy(count(names, "PageUpdate") >= 1)
            assert.are.equal(10, paging.current_page)
        end)

        it("should toggle page flipping mode and flip by gesture distance", function()
            finally(function()
                if paging.page_flipping_mode then paging:onTogglePageFlipping() end
            end)
            local names = record_events(readerui)
            paging:onTogglePageFlipping()
            assert.is_true(paging.page_flipping_mode)
            assert.is_true(readerui.view.flipping_visible)
            assert.are.equal(10, paging.original_page)
            assert.are.equal(1, count(names, "EnterFlippingMode"))
            assert.are.equal(1, count(names, "SetHinting"))
            local w, h = Screen:getWidth(), Screen:getHeight()
            paging:pageFlipping(10, { direction = "west", distance = w / 2 })
            assert.are.equal(15, paging.current_page)
            paging:pageFlipping(15, { direction = "east", distance = w / 2 })
            assert.are.equal(10, paging.current_page)
            paging:pageFlipping(10, { direction = "north", distance = h / 5 })
            assert.are.equal(19, paging.current_page)
            paging:pageFlipping(19, { direction = "south", distance = h / 5 })
            assert.are.equal(10, paging.current_page)
            -- pan in flipping mode flips relative to flipping_page
            paging:onPan(nil, { direction = "west", distance = w / 2, relative = { x = -w / 2, y = 0 } })
            assert.are.equal(15, paging.current_page)
            paging:onPanRelease(nil, {})
            assert.are.equal(15, paging.flipping_page)
            -- a swipe brings back to the original page
            assert.is_true(paging:onSwipe(nil, { direction = "west" }))
            assert.are.equal(10, paging.current_page)
            paging:onTogglePageFlipping()
            assert.is_false(paging.page_flipping_mode)
            assert.is_nil(paging.original_page)
            assert.are.equal(1, count(names, "ExitFlippingMode"))
            assert.are.equal(paging.flipping_zoom_mode, readerui.view.zoom_mode)
        end)

        it("should toggle bookmark flipping mode", function()
            finally(function()
                if paging.bookmark_flipping_mode then paging:onToggleBookmarkFlipping() end
            end)
            local names, args = record_events(readerui)
            paging:onToggleBookmarkFlipping()
            assert.is_true(paging.bookmark_flipping_mode)
            assert.is_true(readerui.view.flipping_visible)
            -- page flipping toggle is ignored while bookmark flipping
            paging:onTogglePageFlipping()
            assert.is_false(paging.page_flipping_mode)
            assert.is_true(paging:onPan(nil, { direction = "west", distance = 100, relative = { x = -100, y = 0 } }))
            paging:onSwipe(nil, { direction = "west" })
            assert.are.equal(1, count(names, "GotoNextBookmark"))
            assert.are.equal(10, args.GotoNextBookmark[1])
            paging:onSwipe(nil, { direction = "east" })
            assert.are.equal(1, count(names, "GotoPreviousBookmark"))
            paging:onGotoPage(20)
            paging:onToggleBookmarkFlipping()
            assert.is_false(paging.bookmark_flipping_mode)
            assert.are.equal(10, paging.current_page)
            assert.falsy(readerui.view.flipping_visible)
        end)

        it("should toggle reflow and request redraw/rezoom", function()
            local configurable = readerui.document.configurable
            local orig = configurable.text_wrap
            local names = record_events(readerui)
            paging:onToggleReflow()
            assert.are.equal(orig == 0 and 1 or 0, configurable.text_wrap)
            assert.are.equal(1, count(names, "RedrawCurrentPage"))
            assert.are.equal(1, count(names, "RestoreZoomMode"))
            assert.are.equal(1, count(names, "InitScrollPageStates"))
            paging:onToggleReflow()
            assert.are.equal(orig, configurable.text_wrap)
        end)

        it("should go to next/previous chapters from the ToC", function()
            local stacked = 0
            override(readerui.link, "addCurrentLocationToStack", function() stacked = stacked + 1 end)
            override(readerui.toc, "getNextChapter", function(_, page) return page + 7 end)
            override(readerui.toc, "getPreviousChapter", function(_, page) return page > 5 and page - 5 or nil end)
            paging:onGotoNextChapter()
            assert.are.equal(17, paging.current_page)
            paging:onGotoPrevChapter()
            assert.are.equal(12, paging.current_page)
            paging:onGotoPage(3)
            paging:onGotoPrevChapter()
            assert.are.equal(3, paging.current_page)
            assert.are.equal(2, stacked)
        end)

        it("should report progress", function()
            assert.are.equal(10, paging:getLastProgress())
            assert.are.near(10 / 45, paging:getLastPercent(), 1e-9)
            local saved = paging.current_page
            paging.current_page = 0
            assert.is_nil(paging:getLastPercent())
            paging.current_page = saved
        end)

        it("should forward color rendering updates", function()
            local called = 0
            override(readerui.document, "updateColorRendering", function() called = called + 1 end)
            paging:onColorRenderingUpdate()
            assert.are.equal(1, called)
        end)

        it("should enter and exit skim mode, restoring view settings", function()
            set_scroll_mode("contentwidth")
            paging:onGotoPage(10)
            paging:enterSkimMode()
            assert.truthy(paging.skim_backup)
            assert.is_false(readerui.view.page_scroll)
            assert.are.equal("page", readerui.view.zoom_mode)
            paging:onGotoPage(10)
            paging:exitSkimMode()
            assert.is_nil(paging.skim_backup)
            assert.is_true(readerui.view.page_scroll)
            assert.are.equal("contentwidth", readerui.view.zoom_mode)
            assert.are.equal(10, paging.current_page)
            -- nothing to back up when already in plain page mode
            set_page_mode("page")
            paging:enterSkimMode()
            assert.is_nil(paging.skim_backup)
            paging:exitSkimMode()
        end)
    end)

    describe("in scroll mode", function()
        before_each(function()
            set_scroll_mode("pagewidth")
            paging:onGotoPage(10)
            paging:onScrollSettingsUpdated(readerui.scrolling.SCROLL_METHOD_CLASSIC, false, 0)
        end)

        it("should scroll a screen with onGotoViewRel and keep the overlap", function()
            local top0 = paging:getTopPosition()
            assert.are.equal(10, paging:getTopPage())
            paging:onGotoViewRel(1)
            local states = readerui.view.page_states
            assert.truthy(#states >= 1)
            local moved = paging:getTopPage() > 10 or paging:getTopPosition() > top0
            assert.is_true(moved)
            -- page_positions are recorded for the top page
            assert.are.equal(paging:getTopPosition(), paging:getPagePosition(paging:getTopPage()))
            paging:onGotoViewRel(-1)
            assert.are.equal(10, paging:getTopPage())
            assert.are.near(top0, paging:getTopPosition(), 0.02)
        end)

        it("should jump several pages at once and honour no_page_turn", function()
            assert.is_true(paging:onScrollPageRel(0))
            assert.is_nil(paging:onScrollPageRel(1, true))
            paging:onGotoViewRel(3)
            assert.are.equal(13, paging.current_page)
            paging:onGotoViewRel(-2.6)
            assert.are.equal(10, paging.current_page)
        end)

        it("should emit EndOfBook at the bottom of the last page", function()
            paging:onGotoPage(45)
            local names = record_events(readerui)
            for _ = 1, 10 do
                paging:onGotoViewRel(1)
            end
            assert.truthy(count(names, "EndOfBook") >= 1)
            assert.are.equal(45, paging.current_page)
        end)

        it("should scroll by distance with onScrollPanRel and stop at document start", function()
            assert.is_true(paging:onScrollPanRel(0))
            paging:onScrollPanRel(200)
            local pos = paging:getTopPosition()
            assert.truthy(pos > 0)
            paging:onScrollPanRel(-100)
            assert.truthy(paging:getTopPosition() < pos)
            paging:onGotoPage(1)
            paging:onScrollPanRel(-500)
            assert.are.equal(1, paging:getTopPage())
            assert.are.equal(0, paging:getTopPosition())
        end)

        it("should scroll with onGotoPosRel and onPanningRel", function()
            paging:onGotoPosRel(1)
            local pos = paging:getTopPosition()
            assert.truthy(pos > 0)
            paging:onPanningRel(-100)
            assert.truthy(paging:getTopPosition() < pos)
        end)

        it("should go to a position inside a page", function()
            paging:onGotoPage(12, { x = 0, y = 300 })
            assert.are.equal(12, paging:getTopPage())
            assert.truthy(paging:getTopPosition() > 0)
            set_page_mode("contentwidth")
            paging:onGotoPage(12, { x = 0, y = 300 })
            assert.are.equal(12, paging.current_page)
            assert.truthy(paging.visible_area.y > 0)
        end)

        it("should update rotation, gamma and saturation of all page states", function()
            assert.is_true(paging:onUpdateScrollPageRotation(90))
            assert.is_true(paging:onUpdateScrollPageGamma(1.5))
            assert.is_true(paging:onUpdateScrollPageSaturation(0.5))
            for _, state in ipairs(readerui.view.page_states) do
                assert.are.equal(90, state.rotation)
                assert.are.equal(1.5, state.gamma)
                assert.are.equal(0.5, state.saturation)
            end
            paging:onUpdateScrollPageRotation(0)
            paging:onUpdateScrollPageGamma(1)
            paging:onUpdateScrollPageSaturation(1)
        end)

        it("should follow the finger with classic pan scrolling", function()
            local t0 = time.s(1000)
            paging:onPan(nil, { direction = "north", relative = { x = 0, y = -10 }, time = t0 })
            assert.is_true(paging._pan_started)
            paging:onPan(nil, { direction = "north", relative = { x = 0, y = -210 }, time = t0 + time.s(1) })
            assert.is_true(paging._pan_has_scrolled)
            assert.truthy(paging:getTopPosition() > 0)
            paging:onPanRelease(nil, { from_mousewheel = true })
            assert.is_false(paging._pan_started)
            assert.is_false(paging._pan_has_scrolled)
            assert.is_false(UIManager.currently_scrolling)
        end)

        it("should restore position when a pan ends up handled as a swipe", function()
            local t0 = time.s(2000)
            local top = paging:getTopPosition()
            paging:onPan(nil, { direction = "north", relative = { x = 0, y = -10 }, time = t0 })
            paging:onPan(nil, { direction = "north", relative = { x = 0, y = -310 }, time = t0 + time.s(1) })
            assert.truthy(paging:getTopPosition() > top)
            assert.is_true(paging:onHandledAsSwipe())
            assert.are.equal(10, paging:getTopPage())
            assert.are.near(top, paging:getTopPosition(), 1e-6)
            assert.is_false(paging._pan_started)
            -- nothing to do when no pan in progress
            assert.is_true(paging:onHandledAsSwipe())
        end)

        it("should treat a swipe after scrolling as a pan release", function()
            local t0 = time.s(3000)
            paging:onPan(nil, { direction = "south", relative = { x = 0, y = 10 }, time = t0 })
            paging:onPan(nil, { direction = "north", relative = { x = 0, y = -200 }, time = t0 + time.s(1) })
            assert.is_true(paging._pan_has_scrolled)
            local page = paging.current_page
            assert.is_true(paging:onSwipe(nil, { direction = "west" }))
            assert.is_false(paging._pan_has_scrolled)
            assert.are.equal(page, paging.current_page)
        end)

        it("should scroll only on release with the on_release method", function()
            paging:onScrollSettingsUpdated(readerui.scrolling.SCROLL_METHOD_ON_RELEASE, false, 0)
            local t0 = time.s(4000)
            paging:onPan(nil, { direction = "north", relative = { x = 0, y = -150 }, time = t0 })
            assert.are.equal(0, paging:getTopPosition())
            assert.are.equal(150, paging._pan_to_scroll_later)
            paging:onPanRelease(nil, { from_mousewheel = true })
            assert.truthy(paging:getTopPosition() > 0)
        end)

        it("should scroll by distance from start with the turbo method", function()
            paging:onScrollSettingsUpdated(readerui.scrolling.SCROLL_METHOD_TURBO, false, 0)
            local t0 = time.s(5000)
            paging:onPan(nil, { direction = "north", relative = { x = 0, y = -50 }, time = t0 })
            local p1 = paging:getTopPosition()
            assert.truthy(p1 > 0)
            paging:onPan(nil, { direction = "north", relative = { x = 0, y = -50 }, time = t0 + time.s(1) })
            assert.truthy(paging:getTopPosition() > p1)
            paging:onPanRelease(nil, { from_mousewheel = true })
        end)

        it("should honour the scroll activation delay and mouse wheel pans", function()
            paging:onScrollSettingsUpdated(readerui.scrolling.SCROLL_METHOD_CLASSIC, false, 500)
            local t0 = time.s(6000)
            paging:onPan(nil, { direction = "north", relative = { x = 0, y = -10 }, time = t0 })
            paging:onPan(nil, { direction = "north", relative = { x = 0, y = -110 }, time = t0 + time.ms(100) })
            -- still within the activation delay: distance is accumulated
            assert.are.equal(0, paging:getTopPosition())
            assert.are.equal(110, paging._pan_to_scroll_later)
            paging:onPan(nil, { direction = "north", relative = { x = 0, y = -120 }, time = t0 + time.ms(700) })
            assert.truthy(paging:getTopPosition() > 0)
            paging:onPanRelease(nil, { from_mousewheel = true })
            -- mouse wheel pans skip the activation delay
            local p = paging:getTopPosition()
            paging:onPan(nil, { direction = "north", mousewheel_direction = -1, relative = { x = 0, y = -60 }, time = t0 + time.s(5) })
            assert.truthy(paging:getTopPosition() > p)
            paging:onPanRelease(nil, { from_mousewheel = true })
        end)

        it("should install inertial scroll callbacks", function()
            local do_scroll, scroll_done
            override(readerui.scrolling, "setInertialScrollCallbacks", function(_, a, b)
                do_scroll, scroll_done = a, b
            end)
            paging:onScrollSettingsUpdated(readerui.scrolling.SCROLL_METHOD_CLASSIC, true, 0)
            assert.is_function(do_scroll)
            assert.is_true(do_scroll(100))
            assert.is_true(UIManager.currently_scrolling)
            scroll_done()
            assert.is_false(UIManager.currently_scrolling)
            -- at the very top, scrolling up does nothing
            paging:onGotoPage(1)
            paging:onScrollPanRel(-1000)
            assert.is_false(do_scroll(-100))
            UIManager.currently_scrolling = false
            paging:onScrollSettingsUpdated(readerui.scrolling.SCROLL_METHOD_CLASSIC, false, 0)
            assert.is_nil(do_scroll)
        end)

        it("should restore a location saved in scroll mode", function()
            paging:onScrollPanRel(150)
            local location = paging:getBookLocation()
            local pos = paging:getTopPosition()
            paging:onGotoPage(25)
            paging:onRestoreBookLocation(location)
            assert.are.equal(10, paging:getTopPage())
            assert.are.near(pos, paging:getTopPosition(), 1e-6)
        end)
    end)

    describe("settings", function()
        it("should save paging settings", function()
            set_page_mode("page")
            paging:onGotoPage(17)
            paging.flipping_zoom_mode = "pagewidth"
            paging.flipping_scroll_mode = true
            paging:setPagePosition(17, 0.25)
            paging:onSaveSettings()
            local ds = readerui.doc_settings
            assert.are.equal(17, ds:readSetting("last_page"))
            assert.are.equal("pagewidth", ds:readSetting("flipping_zoom_mode"))
            assert.is_true(ds:readSetting("flipping_scroll_mode"))
            assert.are.equal(0.25, ds:readSetting("page_positions")[17])
            -- a zero position is not stored
            paging:setPagePosition(17, 0)
            assert.is_nil(paging.page_positions[17])
            assert.are.equal(0, paging:getPagePosition(17.6))
        end)

        it("should read paging settings", function()
            local config = LuaSettings:wrap({
                last_page = 33,
                page_positions = { [33] = 0.5 },
                flipping_zoom_mode = "contentwidth",
                flipping_scroll_mode = true,
            })
            paging:onReadSettings(config)
            assert.are.equal(33, paging.current_page)
            assert.are.equal(0.5, paging:getPagePosition(33))
            assert.are.equal("contentwidth", paging.flipping_zoom_mode)
            assert.is_true(paging.flipping_scroll_mode)
            paging:onReadSettings(LuaSettings:wrap({}))
            assert.are.equal(1, paging.current_page)
            assert.are.equal("page", paging.flipping_zoom_mode)
            assert.is_false(paging.flipping_scroll_mode)
        end)
    end)

    describe("key events", function()
        local Device, BD
        setup(function()
            Device = require("device")
            BD = require("ui/bidi")
        end)
        after_each(function()
            G_reader_settings:delSetting("left_right_keys_turn_pages")
            paging.key_events = {}
            paging:registerKeyEvents()
        end)

        it("should map DPad action keys to page turns when asked", function()
            override(Device, "hasDPad", function() return true end)
            override(Device, "useDPadAsActionKeys", function() return true end)
            G_reader_settings:makeTrue("left_right_keys_turn_pages")
            paging.key_events = {}
            paging:registerKeyEvents()
            assert.truthy(paging.key_events.GotoNextPage)
            assert.are.equal(1, paging.key_events.GotoNextPage.args)
            assert.is_nil(paging.key_events.GotoNextChapter)
        end)

        it("should map DPad left/right keys to chapters by default", function()
            override(Device, "hasDPad", function() return true end)
            override(Device, "useDPadAsActionKeys", function() return true end)
            override(BD, "mirroredUILayout", function() return true end)
            paging.key_events = {}
            paging:registerKeyEvents()
            assert.truthy(paging.key_events.GotoNextChapter)
            -- mirrored layout swaps left and right
            assert.are.equal("Left", paging.key_events.GotoNextChapter[1][1])
            assert.are.equal("Right", paging.key_events.GotoPrevChapter[1][1])
        end)

        it("should map Up/Down keys to position moves on keyed devices", function()
            override(Device, "hasDPad", function() return false end)
            override(Device, "hasKeys", function() return true end)
            paging.key_events = {}
            paging:registerKeyEvents()
            assert.are.equal("GotoPosRel", paging.key_events.GotoNextPos.event)
            assert.are.equal(-1, paging.key_events.GotoPrevPos.args)
            assert.are.equal(100, paging.key_events.Goto99.args)
        end)
    end)
end)
