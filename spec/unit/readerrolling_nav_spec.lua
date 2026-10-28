describe("ReaderRolling navigation and rendering", function()
    local BD, DataStorage, Device, DocSettings, DocumentRegistry, Event, ReaderUI, Screen, UIManager, ffiutil, time
    local sample_epub
    local readerui, rolling

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
        local names, args = {}, {}
        local orig = ui.handleEvent
        override(ui, "handleEvent", function(this, ev)
            local name = ev.handler:sub(3)
            table.insert(names, name)
            args[name] = ev.args
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
    -- Capture widgets shown and tasks scheduled, without running them
    local function capture_show()
        local shown = {}
        override(UIManager, "show", function(_, w) table.insert(shown, w) end)
        return shown
    end
    local function capture_schedule()
        local tasks = {}
        override(UIManager, "scheduleIn", function(_, delay, fn, ...)
            table.insert(tasks, { delay = delay, fn = fn, args = { ... } })
        end)
        return tasks
    end

    local function new_readerui(file)
        local ui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(file),
        }
        -- Have rerenderings be done synchronously (no partial rerendering)
        ui.document:enablePartialRerendering(false)
        return ui
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        BD = require("ui/bidi")
        DataStorage = require("datastorage")
        Device = require("device")
        DocSettings = require("docsettings")
        DocumentRegistry = require("document/documentregistry")
        Event = require("ui/event")
        ReaderUI = require("apps/reader/readerui")
        Screen = Device.screen
        UIManager = require("ui/uimanager")
        ffiutil = require("ffi/util")
        time = require("ui/time")
        sample_epub = DataStorage:getDataDir() .. "/readerrolling_nav.epub"
        ffiutil.copyFile("spec/front/unit/data/juliet.epub", sample_epub)
        DocSettings:open(sample_epub):purge()
        readerui = new_readerui(sample_epub)
        rolling = readerui.rolling
    end)

    teardown(function()
        readerui:onClose()
    end)

    after_each(function()
        restore_all()
    end)

    -- Pretend the document has hidden flows (with everything in flow 0, so
    -- ReaderFooter can still compute its progress)
    local function fake_hidden_flows(doc)
        local nb = doc:getPageCount()
        override(doc, "hasHiddenFlows", function() return true end)
        override(doc, "getPageFlow", function() return 0 end)
        override(doc, "getPageNumberInFlow", function(_, page) return page end)
        override(doc, "getTotalPagesInFlow", function() return nb end)
        override(doc, "getFirstPageInFlow", function() return 1 end)
        return nb
    end

    local function set_view_mode(mode)
        if readerui.view.view_mode ~= mode then
            readerui:handleEvent(Event:new("SetViewMode", mode))
        end
    end

    describe("in page mode", function()
        before_each(function()
            set_view_mode("page")
            rolling:onGotoPage(10)
        end)

        it("should batch a huge forward page turn to the last page and emit EndOfBook once", function()
            local nb = readerui.document:getPageCount()
            local names = record_events(readerui)
            rolling:onGotoViewRel(10000)
            assert.are.equal(nb, rolling.current_page)
            assert.are.equal(0, count(names, "EndOfBook"))
            -- another forward turn at the end is the end of book
            rolling:onGotoViewRel(1)
            assert.are.equal(nb, rolling.current_page)
            assert.are.equal(1, count(names, "EndOfBook"))
            assert.are.equal(readerui.document:getXPointer(), rolling.xpointer)
        end)

        it("should batch a huge backward page turn to the first page without EndOfBook", function()
            local names = record_events(readerui)
            rolling:onGotoViewRel(-10000)
            assert.are.equal(1, rolling.current_page)
            rolling:onGotoViewRel(-1)
            assert.are.equal(1, rolling.current_page)
            assert.are.equal(0, count(names, "EndOfBook"))
        end)

        it("should round fractional page turns away from zero", function()
            rolling:onGotoViewRel(2.3)
            assert.are.equal(13, rolling.current_page)
            rolling:onGotoViewRel(-1.5)
            assert.are.equal(11, rolling.current_page)
        end)

        it("should skip hidden flows when turning pages", function()
            local doc = readerui.document
            local nb = fake_hidden_flows(doc)
            override(doc, "getNextPage", function(_, page)
                local p = page + 1
                if p % 2 == 0 then p = p + 1 end
                return p <= nb and p or 0
            end)
            override(doc, "getPrevPage", function(_, page)
                local p = page - 1
                if p % 2 == 0 then p = p - 1 end
                return p >= 1 and p or 0
            end)
            rolling:onGotoPage(11)
            rolling:onGotoViewRel(2)
            assert.are.equal(15, rolling.current_page)
            rolling:onGotoViewRel(-1)
            assert.are.equal(13, rolling.current_page)
            -- at the end, extra turns are ignored
            rolling:onGotoPage(nb - 2)
            rolling:onGotoViewRel(50)
            assert.truthy(rolling.current_page >= nb - 2)
        end)

        it("should find chapter starts when there are hidden flows", function()
            local doc = readerui.document
            local nb = fake_hidden_flows(doc)
            local stacked = 0
            override(readerui.link, "addCurrentLocationToStack", function() stacked = stacked + 1 end)
            override(doc, "getNextPage", function(_, page) return page < nb and page + 1 or 0 end)
            override(doc, "getPrevPage", function(_, page) return page > 1 and page - 1 or 0 end)
            override(readerui.toc, "isChapterStart", function(_, page) return page % 10 == 1 end)
            rolling:onGotoPage(15)
            assert.is_true(rolling:onGotoNextChapter())
            assert.are.equal(21, rolling.current_page)
            rolling:onGotoPage(15)
            assert.is_true(rolling:onGotoPrevChapter())
            assert.are.equal(11, rolling.current_page)
            -- no chapter start before page 1: stay
            override(readerui.toc, "isChapterStart", function() return false end)
            rolling:onGotoPage(5)
            rolling:onGotoPrevChapter()
            assert.are.equal(5, rolling.current_page)
            rolling:onGotoNextChapter()
            assert.are.equal(5, rolling.current_page)
            assert.are.equal(2, stacked)
        end)

        it("should go to percent and relative pages, updating the xpointer", function()
            local nb = readerui.document:getPageCount()
            assert.is_true(rolling:onGotoPercent(50))
            assert.are.near(nb / 2, rolling.current_page, 2)
            assert.are.equal(readerui.document:getXPointer(), rolling.xpointer)
            local page = rolling.current_page
            rolling:onGotoRelativePage(5)
            assert.are.equal(page + 5, rolling.current_page)
            rolling:onGotoRelativePage(nil)
            assert.are.equal(page + 5, rolling.current_page)
            assert.are.near(rolling.current_page / nb, rolling:getLastPercent(), 1e-9)
            assert.are.equal(rolling.xpointer, rolling:getLastProgress())
        end)

        it("should go to an xpointer and restore book locations", function()
            rolling:onGotoPage(30)
            local location = { xpointer = rolling:getBookLocation() }
            rolling:onGotoPage(60)
            assert.is_true(rolling:onRestoreBookLocation(location))
            assert.are.equal(30, rolling.current_page)
            assert.are.equal(location.xpointer, rolling.xpointer)
        end)

        it("should show then remove a followed-link marker", function()
            local tasks = capture_schedule()
            rolling:onGotoPage(20)
            local xp = rolling.xpointer
            rolling:onGotoPage(40)
            rolling:onGotoXPointer(xp, xp)
            assert.are.equal(20, rolling.current_page)
            assert.are.equal(xp, rolling.xpointer)
            assert.is_function(rolling.mark_func)
            assert.are.equal(1, #tasks)
            assert.are.equal(0.5, tasks[1].delay)
            -- draw the marker: it saves the original content and schedules its removal
            tasks[1].fn()
            assert.is_nil(rolling.mark_func)
            assert.truthy(rolling.mark_orig_content_bb)
            assert.is_function(rolling.unmark_func)
            assert.are.equal(2, #tasks)
            assert.are.equal(1, tasks[2].delay)
            -- a new jump while the marker is shown removes it right away
            rolling:onGotoXPointer(xp, xp)
            assert.is_nil(rolling.unmark_func)
            assert.is_nil(rolling.mark_orig_content_bb)
            assert.is_function(rolling.mark_func)
            -- and a pending marker is replaced on the next jump
            local pending = rolling.mark_func
            rolling:onGotoXPointer(xp, xp)
            assert.are_not.equal(pending, rolling.mark_func)
            -- drawing twice frees the previous saved content
            rolling.mark_func()
            local first_bb = rolling.mark_orig_content_bb
            rolling:onGotoXPointer(xp, xp)
            rolling.unmark_func = nil
            rolling.mark_orig_content_bb = first_bb
            rolling.mark_func()
            assert.are_not.equal(first_bb, rolling.mark_orig_content_bb)
            rolling.unmark_func()
            assert.is_nil(rolling.mark_orig_content_bb)
        end)

        it("should honour the followed_link_marker setting", function()
            local tasks = capture_schedule()
            local xp = rolling.xpointer
            finally(function() G_reader_settings:delSetting("followed_link_marker") end)
            G_reader_settings:saveSetting("followed_link_marker", false)
            rolling:onGotoXPointer(xp, xp)
            assert.is_nil(rolling.mark_func)
            assert.are.equal(0, #tasks)
            G_reader_settings:saveSetting("followed_link_marker", true)
            rolling:onGotoXPointer(xp, xp)
            rolling.mark_func()
            -- permanent marker: nothing scheduled to remove it
            assert.are.equal(1, #tasks)
            assert.is_nil(rolling.unmark_func)
            -- mirrored UI puts the marker in the right margin
            override(BD, "mirroredUILayout", function() return true end)
            rolling:onGotoXPointer(xp, xp)
            assert.is_function(rolling.mark_func)
            rolling.mark_func = nil
        end)

        it("should turn pages with tap zones, swipes and mouse wheel", function()
            local zones = readerui._zones
            zones.tap_forward.handler()
            assert.are.equal(11, rolling.current_page)
            zones.tap_backward.handler()
            assert.are.equal(10, rolling.current_page)
            assert.is_true(zones.rolling_swipe.handler({ direction = "west" }))
            assert.are.equal(11, rolling.current_page)
            assert.is_true(rolling:onSwipe(nil, { direction = "east" }))
            assert.are.equal(10, rolling.current_page)
            readerui.view.inverse_reading_order = true
            finally(function() readerui.view.inverse_reading_order = nil end)
            rolling:onSwipe(nil, { direction = "west" })
            assert.are.equal(9, rolling.current_page)
            rolling:onSwipe(nil, { direction = "east" })
            assert.are.equal(10, rolling.current_page)
            readerui.view.inverse_reading_order = nil
            assert.is_true(zones.rolling_pan.handler({ direction = "north", mousewheel_direction = -1 }))
            assert.are.equal(11, rolling.current_page)
            zones.rolling_pan_release.handler({})
            G_reader_settings:makeTrue("page_turns_disable_tap")
            G_reader_settings:makeTrue("page_turns_disable_swipe")
            finally(function()
                G_reader_settings:delSetting("page_turns_disable_tap")
                G_reader_settings:delSetting("page_turns_disable_swipe")
            end)
            assert.is_nil(zones.tap_forward.handler())
            assert.is_nil(zones.tap_backward.handler())
            assert.is_nil(rolling:onSwipe(nil, { direction = "west" }))
            assert.is_nil(rolling:onSwipe(nil, { direction = "east" }))
            assert.are.equal(11, rolling.current_page)
        end)

        it("should turn a page on panning keys", function()
            assert.is_nil(rolling:onPanning({ 0, 1 }))
            assert.are.equal(11, rolling.current_page)
            rolling:onPanning({ 0, -1 })
            assert.are.equal(10, rolling.current_page)
        end)

        it("should keep the position when switching to scroll mode and back", function()
            local xp = rolling.xpointer
            local names = record_events(readerui)
            set_view_mode("scroll")
            assert.are.equal("scroll", readerui.view.view_mode)
            assert.are.equal(xp, rolling.xpointer)
            assert.are.equal(readerui.document:getPosFromXPointer(xp), rolling.current_pos)
            assert.is_true(rolling:onRedrawCurrentView())
            assert.truthy(count(names, "PosUpdate") >= 1)
            set_view_mode("page")
            assert.are.equal(10, rolling.current_page)
            assert.are.equal(xp, rolling.xpointer)
            assert.is_true(rolling:onRedrawCurrentView())
            assert.truthy(count(names, "PageUpdate") >= 1)
        end)

        it("should defer view mode repositioning when there is no xpointer yet", function()
            -- (this only happens while ReaderUI:init() is still running)
            local xp = rolling.xpointer
            readerui.postInitCallback = {}
            finally(function() readerui.postInitCallback = nil end)
            rolling:onGotoPage(30)
            rolling.xpointer = nil
            rolling:onChangeViewMode()
            assert.are.equal(1, #readerui.postInitCallback)
            assert.are.equal(30, rolling.current_page)
            rolling.xpointer = xp
            table.remove(readerui.postInitCallback)()
            assert.are.equal(10, rolling.current_page)
        end)
    end)

    describe("in scroll mode", function()
        local page_h
        before_each(function()
            set_view_mode("scroll")
            rolling:onGotoPage(10)
            local footer_h = ((readerui.view.footer_visible and not readerui.view.footer.settings.reclaim_height) and 1 or 0)
                             * readerui.view.footer:getHeight()
            page_h = readerui.dimen.h - footer_h
            rolling:onScrollSettingsUpdated(readerui.scrolling.SCROLL_METHOD_CLASSIC, false, 0)
        end)
        teardown(function()
            set_view_mode("page")
        end)

        it("should scroll by a full screen with onGotoViewRel", function()
            local pos = rolling.current_pos
            rolling:onGotoViewRel(1)
            assert.are.equal(pos + page_h, rolling.current_pos)
            assert.are.equal(readerui.document:getXPointer(), rolling.xpointer)
            rolling:onGotoViewRel(-1)
            assert.are.equal(pos, rolling.current_pos)
            assert.is_true(readerui.view.dim_area:isEmpty())
        end)

        it("should keep an overlap and dim it when page overlap is enabled", function()
            readerui.view.page_overlap_enable = true
            finally(function()
                readerui.view.page_overlap_enable = false
                readerui.view.dim_area:clear()
            end)
            local pos = rolling.current_pos
            rolling:onGotoViewRel(1)
            local moved = rolling.current_pos - pos
            assert.truthy(moved > 0 and moved < page_h)
            local dim = readerui.view.dim_area
            assert.are.equal(page_h - moved, dim.h)
            assert.are.equal(0, dim.y)
            rolling:onGotoViewRel(-1)
            assert.are.equal(pos, rolling.current_pos)
            assert.are.equal(page_h - dim.h, dim.y)
        end)

        it("should clamp scrolling at both ends and emit EndOfBook at the end", function()
            local names = record_events(readerui)
            rolling:onGotoViewRel(-10000)
            assert.are.equal(0, rolling.current_pos)
            assert.are.equal(0, count(names, "EndOfBook"))
            rolling:onGotoViewRel(10000)
            local end_pos = rolling.current_pos
            assert.truthy(end_pos > 0)
            assert.are.equal(0, count(names, "EndOfBook"))
            rolling:onGotoViewRel(1)
            assert.are.equal(end_pos, rolling.current_pos)
            assert.are.equal(1, count(names, "EndOfBook"))
        end)

        it("should go to percent and report it", function()
            rolling:onGotoPercent(50)
            local doc_height = readerui.document.info.doc_height
            assert.are.near(doc_height / 2, rolling.current_pos, 1)
            local percent = rolling:getLastPercent()
            assert.truthy(percent > 0.4 and percent < 0.6)
        end)

        it("should scroll by panning steps", function()
            local pos = rolling.current_pos
            assert.is_true(rolling:onPanning({ 0, 1 }))
            assert.are.equal(pos + rolling.panning_steps.normal, rolling.current_pos)
            assert.are.equal(readerui.document:getXPointer(), rolling.xpointer)
        end)

        it("should follow the finger with classic pan scrolling", function()
            local pos = rolling.current_pos
            local t0 = time.s(1000)
            rolling:onPan(nil, { direction = "north", relative = { x = 0, y = -10 }, time = t0 })
            assert.is_true(rolling._pan_started)
            rolling:onPan(nil, { direction = "north", relative = { x = 0, y = -110 }, time = t0 + time.s(1) })
            assert.are.equal(pos + 110, rolling.current_pos)
            assert.is_true(UIManager.currently_scrolling)
            rolling:onPanRelease(nil, { from_mousewheel = true })
            assert.is_false(rolling._pan_started)
            assert.is_false(UIManager.currently_scrolling)
            assert.are.equal(readerui.document:getXPointer(), rolling.xpointer)
        end)

        it("should restore position when a pan ends up handled as a swipe", function()
            local pos = rolling.current_pos
            local t0 = time.s(2000)
            rolling:onPan(nil, { direction = "north", relative = { x = 0, y = -10 }, time = t0 })
            rolling:onPan(nil, { direction = "north", relative = { x = 0, y = -210 }, time = t0 + time.s(1) })
            assert.are.equal(pos + 210, rolling.current_pos)
            assert.is_true(rolling:onHandledAsSwipe())
            assert.are.equal(pos, rolling.current_pos)
            assert.is_false(rolling._pan_started)
            assert.is_true(rolling:onHandledAsSwipe())
        end)

        it("should treat a swipe after scrolling as a pan release", function()
            local t0 = time.s(3000)
            rolling:onPan(nil, { direction = "south", relative = { x = 0, y = 10 }, time = t0 })
            rolling:onPan(nil, { direction = "north", relative = { x = 0, y = -100 }, time = t0 + time.s(1) })
            local pos = rolling.current_pos
            assert.is_true(rolling:onSwipe(nil, { direction = "west" }))
            assert.are.equal(pos, rolling.current_pos)
            assert.is_false(rolling._pan_has_scrolled)
        end)

        it("should scroll only on release with the on_release method", function()
            rolling:onScrollSettingsUpdated(readerui.scrolling.SCROLL_METHOD_ON_RELEASE, false, 0)
            local pos = rolling.current_pos
            rolling:onPan(nil, { direction = "north", relative = { x = 0, y = -150 }, time = time.s(4000) })
            assert.are.equal(pos, rolling.current_pos)
            rolling:onPanRelease(nil, { from_mousewheel = true })
            assert.are.equal(pos + 150, rolling.current_pos)
        end)

        it("should scroll by distance from start with the turbo method", function()
            rolling:onScrollSettingsUpdated(readerui.scrolling.SCROLL_METHOD_TURBO, false, 0)
            local pos = rolling.current_pos
            local t0 = time.s(5000)
            rolling:onPan(nil, { direction = "north", relative = { x = 0, y = -50 }, time = t0 })
            assert.are.equal(pos + 50, rolling.current_pos)
            rolling:onPan(nil, { direction = "north", relative = { x = 0, y = -50 }, time = t0 + time.s(1) })
            assert.are.equal(pos + 100, rolling.current_pos)
            rolling:onPanRelease(nil, { from_mousewheel = true })
        end)

        it("should scroll right away when the pan cancelled an inertial scroll", function()
            rolling:onScrollSettingsUpdated(readerui.scrolling.SCROLL_METHOD_CLASSIC, false, 5000)
            override(readerui.scrolling, "cancelInertialScroll", function() return true end)
            local pos = rolling.current_pos
            rolling:onPan(nil, { direction = "north", relative = { x = 0, y = -30 }, time = time.s(7000) })
            assert.are.equal(pos + 30, rolling.current_pos)
            rolling:onPanRelease(nil, { from_mousewheel = true })
        end)

        it("should notify key selection of page turns", function()
            local turned = 0
            override(readerui.keyselection, "isActive", function() return true end)
            override(readerui.keyselection, "pageTurnDuringSelection", function() turned = turned + 1 end)
            rolling:onGotoViewRel(1)
            assert.are.equal(1, turned)
        end)

        it("should honour the scroll activation delay", function()
            rolling:onScrollSettingsUpdated(readerui.scrolling.SCROLL_METHOD_CLASSIC, false, 500)
            local pos = rolling.current_pos
            local t0 = time.s(6000)
            rolling:onPan(nil, { direction = "north", relative = { x = 0, y = -10 }, time = t0 })
            rolling:onPan(nil, { direction = "north", relative = { x = 0, y = -60 }, time = t0 + time.ms(100) })
            assert.are.equal(pos, rolling.current_pos)
            assert.are.equal(60, rolling._pan_to_scroll_later)
            rolling:onPan(nil, { direction = "north", relative = { x = 0, y = -80 }, time = t0 + time.ms(700) })
            assert.are.equal(pos + 80, rolling.current_pos)
            rolling:onPanRelease(nil, { from_mousewheel = true })
            -- mouse wheel pans are not delayed
            rolling:onPan(nil, { direction = "south", mousewheel_direction = 1, relative = { x = 0, y = 40 }, time = t0 + time.s(5) })
            assert.are.equal(pos + 40, rolling.current_pos)
            rolling:onPanRelease(nil, { from_mousewheel = true })
        end)

        it("should install inertial scroll callbacks", function()
            local do_scroll, scroll_done
            override(readerui.scrolling, "setInertialScrollCallbacks", function(_, a, b)
                do_scroll, scroll_done = a, b
            end)
            rolling:onScrollSettingsUpdated(readerui.scrolling.SCROLL_METHOD_CLASSIC, true, 0)
            local pos = rolling.current_pos
            assert.is_true(do_scroll(100))
            assert.are.equal(pos + 100, rolling.current_pos)
            scroll_done()
            assert.is_false(UIManager.currently_scrolling)
            assert.are.equal(readerui.document:getXPointer(), rolling.xpointer)
            rolling:onGotoViewRel(-10000)
            assert.is_false(do_scroll(-100))
            local doc = readerui.document
            readerui.document = nil
            assert.is_false(do_scroll(100))
            readerui.document = doc
            UIManager.currently_scrolling = false
            rolling:onScrollSettingsUpdated(readerui.scrolling.SCROLL_METHOD_CLASSIC, false, 0)
            assert.is_nil(do_scroll)
        end)
    end)

    describe("in two pages mode", function()
        setup(function()
            readerui:handleEvent(Event:new("SetRotationMode", Screen.DEVICE_ROTATED_CLOCKWISE))
            set_view_mode("page")
            rolling:onSetVisiblePages(2)
        end)
        teardown(function()
            rolling.odd_or_even_first_page = 1
            rolling:onSetVisiblePages(1)
            readerui:handleEvent(Event:new("SetRotationMode", Screen.DEVICE_ROTATED_UPRIGHT))
        end)

        it("should show two pages starting on an odd page", function()
            assert.are.equal(2, readerui.document:getVisiblePageCount())
            assert.are.equal(2, rolling.configurable.visible_pages)
            -- the 2 visible pages share a single page number
            assert.are.equal(1, readerui.document:getVisiblePageNumberCount())
            rolling:onGotoPage(10)
            assert.are.equal(10, rolling.current_page)
            rolling:onGotoViewRel(1)
            assert.are.equal(11, rolling.current_page)
            -- internal page numbers: the left page is kept odd
            local doc = readerui.document
            rolling:_gotoPage(20, nil, true)
            assert.are.equal(19, doc:getCurrentPage(true))
            rolling:_gotoPage(21, nil, true)
            assert.are.equal(21, doc:getCurrentPage(true))
            -- or even if requested
            rolling.odd_or_even_first_page = 2
            rolling:_gotoPage(21, nil, true)
            assert.are.equal(20, doc:getCurrentPage(true))
            rolling:_gotoPage(20, nil, true)
            assert.are.equal(20, doc:getCurrentPage(true))
            rolling.odd_or_even_first_page = 1
            -- unless asked not to enforce it
            rolling:_gotoPage(20, true, true)
            assert.are.equal(20, doc:getCurrentPage(true))
        end)

        it("should place the followed-link marker in the right margin of each page", function()
            local tasks = capture_schedule()
            rolling:onGotoPage(21)
            local doc = readerui.document
            local left_xp = doc:getPageXPointer(21)
            local right_xp = doc:getPageXPointer(22)
            for _, mirrored in ipairs({ false, true }) do
                override(BD, "mirroredUILayout", function() return mirrored end)
                for _, xp in ipairs({ left_xp, right_xp }) do
                    rolling:onGotoXPointer(left_xp, xp)
                    assert.are.equal(21, rolling.current_page)
                    assert.is_function(rolling.mark_func)
                    rolling.mark_func()
                    assert.is_function(rolling.unmark_func)
                    rolling.unmark_func()
                    assert.is_nil(rolling.mark_orig_content_bb)
                end
            end
            assert.are.equal(8, #tasks)
        end)

        it("should rerender when switching to scroll mode", function()
            local names = record_events(readerui)
            local xp = rolling.xpointer
            set_view_mode("scroll")
            assert.are.equal(1, readerui.document:getVisiblePageCount())
            set_view_mode("page")
            assert.are.equal(2, readerui.document:getVisiblePageCount())
            assert.truthy(count(names, "DocumentRerendered") >= 1)
            assert.are.equal(xp, rolling.xpointer)
        end)

        it("should prevent page sync when toggling visible pages with partial rerendering", function()
            local doc = readerui.document
            override(doc, "isPartialRerenderingEnabled", function() return true end)
            local updated = 0
            override(rolling, "onUpdatePos", function() updated = updated + 1 end)
            rolling:onSetVisiblePages(1)
            assert.is_true(doc.no_page_sync)
            assert.are.equal(1, updated)
            doc.no_page_sync = nil
            rolling:onSetVisiblePages(2)
            assert.are.equal(2, updated)
            doc.no_page_sync = nil
        end)
    end)

    describe("rerendering", function()
        before_each(function()
            set_view_mode("page")
            rolling:onGotoPage(10)
        end)

        it("should hold rerendering while batched updates are pending", function()
            local ticks = {}
            override(UIManager, "tickAfterNext", function(_, fn, arg) table.insert(ticks, { fn, arg }) end)
            local names = record_events(readerui)
            rolling:onBatchedUpdate()
            rolling:onBatchedUpdate()
            assert.is_nil(rolling:onUpdatePos(true))
            assert.are.equal(0, count(names, "DocumentRerendered"))
            rolling:onBatchedUpdateDone()
            assert.are.equal(0, #ticks)
            rolling:onBatchedUpdateDone()
            assert.are.equal(1, #ticks)
            assert.are.equal(rolling.onUpdatePos, ticks[1][1])
            -- unbalanced Done calls do not go negative
            rolling:onBatchedUpdateDone()
            assert.are.equal(0, rolling.batched_update_count)
            ticks[1][1](ticks[1][2])
            assert.are.equal(0, count(names, "DocumentRerendered"))
            rolling:onUpdatePos(true)
            assert.are.equal(1, count(names, "DocumentRerendered"))
        end)

        it("should rerender and stay at the same xpointer after a font change", function()
            local tasks = capture_schedule()
            local xp = rolling.xpointer
            local nb = readerui.document:getPageCount()
            local names = record_events(readerui)
            readerui.document:setFontSize(readerui.document.configurable.font_size + 6)
            rolling:onUpdatePos()
            assert.are.equal(1, count(names, "DocumentRerendered"))
            assert.are.equal(xp, rolling.xpointer)
            assert.truthy(readerui.document:getPageCount() > nb)
            assert.are.equal(readerui.document:getPageFromXPointer(xp), rolling.current_page)
            -- a style coherence check is scheduled after the rerendering
            local found
            for _, t in ipairs(tasks) do
                if t.fn == rolling.onCheckDomStyleCoherence then found = t end
            end
            assert.truthy(found)
            -- nothing changed: no rerendering
            rolling:onUpdatePos()
            assert.are.equal(1, count(names, "DocumentRerendered"))
            readerui.document:setFontSize(readerui.document.configurable.font_size)
            rolling:onUpdatePos()
            assert.are.equal(2, count(names, "DocumentRerendered"))
            assert.are.equal(nb, readerui.document:getPageCount())
            assert.are.equal(xp, rolling.xpointer)
        end)

        it("should do nothing in updatePos once the document is gone", function()
            local doc = readerui.document
            readerui.document = nil
            finally(function() readerui.document = doc end)
            assert.is_nil(rolling:updatePos(true))
        end)

        it("should rerender on visible pages, status line and dimensions changes", function()
            local names = record_events(readerui)
            local orig_visible = readerui.document:getVisiblePageCount()
            -- no change: no rerendering
            rolling:onSetVisiblePages(orig_visible)
            assert.are.equal(0, count(names, "DocumentRerendered"))
            rolling:onSetStatusLine(0)
            assert.is_true(rolling.cre_top_bar_enabled)
            local marks
            override(readerui.document, "setHeaderProgressMarks", function(_, pages, ticks) marks = { pages, ticks } end)
            rolling:onUpdateTopStatusBarMarkers()
            assert.are.equal(readerui.document:getPageCount(), marks[1])
            rolling:onSetStatusLine(1)
            assert.is_false(rolling.cre_top_bar_enabled)
            marks = nil
            rolling:onUpdateTopStatusBarMarkers()
            assert.is_nil(marks)
            assert.truthy(count(names, "DocumentRerendered") >= 2)
            local xp = rolling.xpointer
            rolling:onSetDimensions(Screen:getSize())
            assert.are.equal(xp, rolling.xpointer)
            assert.are.equal(readerui.document:getPageFromXPointer(xp), rolling.current_page)
            local colored = 0
            override(readerui.document, "updateColorRendering", function() colored = colored + 1 end)
            rolling:onColorRenderingUpdate()
            assert.are.equal(1, colored)
            rolling:onZoom()
            assert.are.equal(xp, rolling.xpointer)
        end)

        it("should toggle hiding non-linear flows with a forced rerendering", function()
            local names = record_events(readerui)
            local hidden
            override(readerui.document, "setHideNonlinearFlows", function(_, v) hidden = v end)
            local orig = rolling.hide_nonlinear_flows
            rolling:onToggleHideNonlinear()
            assert.are.equal(not orig, rolling.hide_nonlinear_flows)
            assert.are.equal(not orig, hidden)
            assert.are.equal(1, count(names, "DocumentRerendered"))
            rolling:onToggleHideNonlinear()
            assert.are.equal(orig, rolling.hide_nonlinear_flows)
        end)

        it("should suggest a reload when the DOM is stale", function()
            local shown = capture_show()
            local tasks = capture_schedule()
            local stale = false
            override(readerui.document, "isBuiltDomStale", function() return stale end)
            rolling:onCheckDomStyleCoherence()
            assert.are.equal(0, #shown)
            stale = true
            rolling.using_non_normalized_xpointers = true
            override(readerui.annotation, "hasAnnotations", function() return true end)
            finally(function() rolling.using_non_normalized_xpointers = nil end)
            rolling:onCheckDomStyleCoherence()
            assert.are.equal(1, #shown)
            assert.truthy(shown[1].text:find("bookmarks or highlights invalid", 1, true))
            local reloaded = 0
            override(readerui, "reloadDocument", function() reloaded = reloaded + 1 end)
            shown[1].ok_callback()
            assert.are.equal(1, #tasks)
            assert.are.equal(0.5, tasks[1].delay)
            tasks[1].fn()
            assert.are.equal(1, reloaded)
            -- no reload if the document has been closed in the meantime
            local doc = readerui.document
            readerui.document = nil
            tasks[1].fn()
            readerui.document = doc
            assert.are.equal(1, reloaded)
        end)

        it("should notice partial rerenderings done while drawing", function()
            local doc = readerui.document
            local nb_partial = rolling.nb_partial_rerenderings
            local partial_count = nb_partial
            override(doc, "getPartialRerenderingsCount", function() return partial_count end)
            assert.is_nil(rolling:handlePartialRerendering())
            -- partial rerendering happened, still on the right page
            partial_count = nb_partial + 1
            local names = record_events(readerui)
            assert.is_nil(rolling:handlePartialRerendering())
            assert.are.equal(nb_partial + 1, rolling.nb_partial_rerenderings)
            assert.are.equal(1, count(names, "PageUpdate"))
            -- page drifted from the xpointer: repositioned
            partial_count = nb_partial + 2
            local xp = rolling.xpointer
            override(doc, "getPageFromXPointer", function() return 99 end)
            assert.is_true(rolling:handlePartialRerendering())
            doc.getPageFromXPointer = nil
            assert.are.equal(xp, rolling.xpointer)
            -- in scroll mode, a PosUpdate is sent
            restore_all()
            set_view_mode("scroll")
            finally(function() set_view_mode("page") end)
            override(doc, "getPartialRerenderingsCount", function() return nb_partial + 3 end)
            local cur_page = doc:getCurrentPage()
            override(doc, "getPageFromXPointer", function() return cur_page end)
            names = record_events(readerui)
            rolling:handlePartialRerendering()
            assert.truthy(count(names, "PosUpdate") >= 1)
            rolling.nb_partial_rerenderings = nb_partial
        end)

        describe("automation", function()
            local now, top_widget, reloaded, standby, tasks
            before_each(function()
                now = time.s(10000)
                top_widget = { name = "ReaderUI" }
                reloaded, standby = 0, 0
                override(UIManager, "getTime", function() return now end)
                override(UIManager, "getTopmostVisibleWidget", function() return top_widget end)
                override(UIManager, "preventStandby", function() standby = standby + 1 end)
                override(UIManager, "allowStandby", function() standby = standby - 1 end)
                override(UIManager, "unschedule", function() end)
                override(readerui, "reloadDocument", function(_, after_close_callback, seamless)
                    reloaded = reloaded + 1
                    assert.is_nil(after_close_callback)
                    assert.is_true(seamless)
                end)
                tasks = capture_schedule()
            end)
            after_each(function()
                rolling:tearDownRerenderingAutomation()
                rolling.rendering_state = nil
                rolling.valid_cache_rendering_hash = nil
                rolling._current_rerendering_pid = nil
            end)

            local function step()
                rolling._stepRerenderingAutomation()
            end

            it("should go from partial rerendering to a seamless reload when idle", function()
                local names = record_events(readerui)
                override(readerui.document, "isRerenderingDelayed", function() return true end)
                rolling.rendering_hash = -1 -- force "rendering hash changed"
                -- a reusable cache: no background rerendering subprocess
                rolling.valid_cache_rendering_hash = readerui.document:getDocumentRenderingHash(false)
                rolling:updatePos()
                assert.are.equal(1, count(names, "DocumentPartiallyRerendered"))
                assert.is_true(readerui.doc_settings:isTrue("annotations_externally_modified"))
                assert.are.equal(0, count(names, "DocumentRerendered"))
                assert.are.equal(rolling.RENDERING_STATE.PARTIALLY_RERENDERED, rolling.rendering_state)
                assert.are.equal(1, standby)
                assert.are.equal(1, tasks[#tasks].delay)
                -- ReaderUI not on top: wait
                top_widget = { name = "ConfigDialog" }
                step()
                assert.are.equal(rolling.RENDERING_STATE.PARTIALLY_RERENDERED, rolling.rendering_state)
                top_widget = { name = "ReaderUI" }
                step() -- starts counting 3s
                assert.are.equal(rolling.RENDERING_STATE.PARTIALLY_RERENDERED, rolling.rendering_state)
                now = now + time.s(1)
                step()
                assert.are.equal(rolling.RENDERING_STATE.PARTIALLY_RERENDERED, rolling.rendering_state)
                now = now + time.s(3)
                step()
                assert.are.equal(rolling.RENDERING_STATE.FULL_RENDERING_IN_BACKGROUND, rolling.rendering_state)
                assert.is_nil(rolling._current_rerendering_pid)
                step()
                assert.are.equal(rolling.RENDERING_STATE.FULL_RENDERING_READY, rolling.rendering_state)
                -- input just happened: not idle
                rolling._watchInputEvent()
                step()
                assert.are.equal(rolling.RENDERING_STATE.FULL_RENDERING_READY, rolling.rendering_state)
                now = now + time.s(6)
                step()
                assert.are.equal(rolling.RENDERING_STATE.RELOADING_DOCUMENT, rolling.rendering_state)
                -- text selection started meanwhile: back to ready
                readerui.highlight.hold_pos = { x = 1, y = 1 }
                step()
                readerui.highlight.hold_pos = nil
                assert.are.equal(rolling.RENDERING_STATE.FULL_RENDERING_READY, rolling.rendering_state)
                step()
                assert.are.equal(rolling.RENDERING_STATE.RELOADING_DOCUMENT, rolling.rendering_state)
                assert.are.equal(0, reloaded)
                step()
                assert.are.equal(rolling.RENDERING_STATE.DO_RELOAD_DOCUMENT, rolling.rendering_state)
                assert.are.equal(1, reloaded)
                -- a second partial rerendering is not the first one anymore
                rolling.rendering_state = rolling.RENDERING_STATE.PARTIALLY_RERENDERED
                rolling:handleRenderingDelayed()
                assert.are.equal(2, count(names, "DocumentPartiallyRerendered"))
                rolling:tearDownRerenderingAutomation()
                assert.is_nil(rolling._stepRerenderingAutomation)
                assert.is_nil(rolling._watchInputEvent)
                assert.are.equal(0, standby)
            end)

            it("should follow and collect the background rerendering subprocess", function()
                local fake_pid = 424242
                local done, terminated, waited, cores = false, 0, 0, {}
                override(ffiutil, "runInSubProcess", function() return fake_pid end)
                override(ffiutil, "isSubProcessDone", function(pid, wait)
                    assert.are.equal(fake_pid, pid)
                    if wait then waited = waited + 1 return true end
                    return done
                end)
                override(ffiutil, "terminateSubProcess", function() terminated = terminated + 1 end)
                override(Device, "enableCPUCores", function(_, n) table.insert(cores, n) end)
                rolling:setupRerenderingAutomation()
                rolling._stepRerenderingAutomation(rolling.RENDERING_STATE.PARTIALLY_RERENDERED)
                -- setup is idempotent
                local stepper = rolling._stepRerenderingAutomation
                rolling:setupRerenderingAutomation()
                assert.are.equal(stepper, rolling._stepRerenderingAutomation)
                rolling._stepRerenderingAutomation(rolling.RENDERING_STATE.FULL_RENDERING_IN_BACKGROUND)
                assert.are.equal(fake_pid, rolling._current_rerendering_pid)
                assert.are.same({ 2 }, cores)
                -- still rendering
                step()
                assert.are.equal(rolling.RENDERING_STATE.FULL_RENDERING_IN_BACKGROUND, rolling.rendering_state)
                -- the subprocess died: go on as if no rerendering was needed
                done = true
                step()
                assert.is_nil(rolling._current_rerendering_pid)
                assert.are.equal(rolling.RENDERING_STATE.FULL_RENDERING_READY, rolling.rendering_state)
                -- reloading with a subprocess still alive lets it save its cache first
                done = false
                rolling._current_rerendering_pid = fake_pid
                now = now + time.s(10)
                step()
                assert.are.equal(rolling.RENDERING_STATE.RELOADING_DOCUMENT, rolling.rendering_state)
                step()
                assert.are.equal(1, waited)
                assert.are.equal(1, reloaded)
                assert.is_nil(rolling._current_rerendering_pid)
                -- a new setting change while a subprocess runs kills it
                rolling._current_rerendering_pid = fake_pid
                rolling._stepRerenderingAutomation(rolling.RENDERING_STATE.PARTIALLY_RERENDERED)
                assert.are.equal(1, terminated)
                assert.is_nil(rolling._current_rerendering_pid)
                rolling:tearDownRerenderingAutomation()
                assert.are.equal(1, cores[#cores])
            end)

            it("should report subprocess state in _waitOrKillCurrentRerenderingSubprocess", function()
                local done = false
                override(ffiutil, "isSubProcessDone", function(_, wait) return wait and true or done end)
                override(ffiutil, "terminateSubProcess", function() end)
                rolling._current_rerendering_pid = nil
                assert.is_true(rolling:_waitOrKillCurrentRerenderingSubprocess())
                rolling._current_rerendering_pid = 1234
                assert.is_false(rolling:_waitOrKillCurrentRerenderingSubprocess(false))
                assert.are.equal(1234, rolling._current_rerendering_pid)
                assert.is_true(rolling:_waitOrKillCurrentRerenderingSubprocess(true))
                assert.is_nil(rolling._current_rerendering_pid)
                rolling._current_rerendering_pid = 1234
                done = true
                assert.is_true(rolling:_waitOrKillCurrentRerenderingSubprocess(false))
                assert.is_nil(rolling._current_rerendering_pid)
            end)
        end)
    end)

    describe("engine progress", function()
        after_each(function()
            rolling:showEngineProgress()
            G_reader_settings:delSetting("cre_show_progress")
        end)

        it("should show progress only after the initial delay", function()
            rolling:handleEngineCallback("OnLoadFileStart")
            assert.truthy(rolling.engine_progress_update_not_before)
            assert.is_nil(rolling.engine_progress_widget)
            -- still within the initial delay
            rolling:handleEngineCallback("OnLoadFileProgress", 50)
            assert.is_nil(rolling.engine_progress_widget)
            rolling.engine_progress_update_not_before = 0
            rolling:handleEngineCallback("OnLoadFileProgress", 50)
            assert.truthy(rolling.engine_progress_widget)
            assert.are.equal(0.25, rolling.engine_progress_widget.percentage)
            for _, ev in ipairs({ "OnNodeStylesUpdateProgress", "OnFormatStart", "OnFormatProgress",
                                  "OnSaveCacheFileStart", "OnSaveCacheFileProgress" }) do
                rolling.engine_progress_update_not_before = 0
                rolling:handleEngineCallback(ev, 50)
            end
            assert.are.equal(0.5, rolling.engine_progress_widget.percentage)
            rolling:handleEngineCallback("OnNodeStylesUpdateStart")
            rolling:handleEngineCallback("OnSaveCacheFileEnd")
            assert.is_nil(rolling.engine_progress_widget)
            assert.is_nil(rolling.engine_progress_update_not_before)
            rolling:handleEngineCallback("OnLoadFileError", "oops")
            rolling:handleEngineCallback("OnSomethingUnknown")
            rolling:handleEngineCallback("OnDocumentReady")
            assert.is_nil(rolling.engine_progress_widget)
        end)

        it("should be disabled by cre_show_progress=false", function()
            G_reader_settings:makeFalse("cre_show_progress")
            rolling:handleEngineCallback("OnLoadFileStart")
            assert.is_nil(rolling.engine_progress_update_not_before)
        end)

        it("should place the progress bar below the header once rendered", function()
            rolling.current_header_height = 20
            rolling.engine_progress_update_not_before = 0
            rolling:showEngineProgress(0.3)
            assert.truthy(rolling.engine_progress_widget)
            assert.are.equal(0.3, rolling.engine_progress_widget.percentage)
        end)
    end)

    describe("battery state in top status bar", function()
        local powerd
        before_each(function()
            set_view_mode("page")
            powerd = Device:getPowerDevice()
        end)

        it("should report nothing when the top status bar is disabled", function()
            rolling.cre_top_bar_enabled = false
            assert.are.equal(0, rolling:updateBatteryState())
        end)

        it("should report capacity, charging and aux battery", function()
            rolling.cre_top_bar_enabled = true
            finally(function() rolling.cre_top_bar_enabled = false end)
            local set_state
            override(readerui.document, "setBatteryState", function(_, s) set_state = s end)
            override(powerd, "getCapacity", function() return 60 end)
            override(powerd, "isCharging", function() return false end)
            assert.are.equal(60, rolling:updateBatteryState())
            assert.are.equal(60, set_state)
            override(powerd, "isCharging", function() return true end)
            rolling:onResume()
            assert.are.equal(-1, set_state)
            override(powerd, "isCharging", function() return false end)
            override(powerd.device, "hasAuxBattery", function() return true end)
            override(powerd, "isAuxBatteryConnected", function() return true end)
            override(powerd, "isAuxCharging", function() return false end)
            override(powerd, "getAuxCapacity", function() return 40 end)
            G_reader_settings:saveSetting("cre_header_battery_percent", 1)
            rolling:onNotCharging()
            assert.are.equal(100, set_state)
            G_reader_settings:saveSetting("cre_header_battery_percent", 0)
            finally(function() G_reader_settings:delSetting("cre_header_battery_percent") end)
            rolling:onPageUpdate(rolling.current_page)
            assert.are.equal(50, set_state)
            rolling:onPosUpdate(rolling.current_pos)
            assert.are.equal(50, set_state)
        end)
    end)

    describe("settings", function()
        it("should save rolling settings", function()
            set_view_mode("page")
            rolling:onGotoPage(25)
            readerui.doc_settings:saveSetting("last_percent", 0.3)
            rolling:onSaveSettings()
            local ds = readerui.doc_settings
            assert.are.equal(rolling.xpointer, ds:readSetting("last_xpointer"))
            assert.is_nil(ds:readSetting("last_percent"))
            assert.are.equal(rolling.partial_rerendering, ds:readSetting("partial_rerendering"))
            assert.are.equal(rolling.hide_nonlinear_flows, ds:readSetting("hide_nonlinear_flows"))
        end)

        it("should save the epubcfi and cache info on close", function()
            local unscheduled = {}
            override(UIManager, "unschedule", function(_, fn) unscheduled[fn] = true end)
            local mark, unmark = function() end, function() end
            rolling.mark_func, rolling.unmark_func = mark, unmark
            local invalidated = 0
            override(readerui.document, "hasCacheFile", function() return true end)
            override(readerui.document, "isBuiltDomStale", function() return true end)
            override(readerui.document, "invalidateCacheFile", function() invalidated = invalidated + 1 end)
            rolling:onCloseDocument()
            rolling.mark_func, rolling.unmark_func = nil, nil
            assert.is_true(unscheduled[mark])
            assert.is_true(unscheduled[unmark])
            assert.is_true(unscheduled[rolling.onUpdatePos])
            local cfi = readerui.doc_settings:readSetting("last_epubcfi")
            assert.truthy(cfi and cfi:match("^epubcfi%("))
            assert.are.equal(1, invalidated)
            -- not when about to reload from a background rendered cache
            rolling.rendering_state = rolling.RENDERING_STATE.DO_RELOAD_DOCUMENT
            rolling:onCloseDocument()
            rolling.rendering_state = nil
            assert.are.equal(1, invalidated)
        end)

        it("should build menu items for partial rendering and non-linear flows", function()
            local shown = capture_show()
            override(readerui.document, "hasNonLinearFlows", function() return true end)
            local menu_items = {}
            rolling:addToMainMenu(menu_items)
            local hide = menu_items.hide_nonlinear_flows
            assert.truthy(hide)
            assert.is_true(hide.enabled_func())
            local orig = rolling.hide_nonlinear_flows
            assert.are.equal(orig, hide.checked_func())
            hide.callback()
            assert.are.equal(not orig, rolling.hide_nonlinear_flows)
            hide.hold_callback()
            shown[#shown].ok_callback()
            assert.are.equal(not orig, G_reader_settings:readSetting("hide_nonlinear_flows"))
            hide.callback()
            G_reader_settings:delSetting("hide_nonlinear_flows")

            local partial = menu_items.partial_rerendering
            local doc = readerui.document
            assert.are.equal(doc:canBePartiallyRerendered(), partial.enabled_func())
            local enabled = false
            override(doc, "isPartialRerenderingEnabled", function() return enabled end)
            override(doc, "enablePartialRerendering", function(_, v)
                local had = enabled
                enabled = v
                return had and not v
            end)
            assert.is_false(partial.checked_func())
            partial.callback()
            assert.is_true(enabled)
            assert.is_true(rolling.partial_rerendering)
            local names = record_events(readerui)
            rolling.rendering_hash = -1
            partial.callback()
            assert.is_false(enabled)
            assert.is_false(rolling.partial_rerendering)
            -- disabling after partial renderings triggers a full rerendering
            assert.are.equal(1, count(names, "DocumentRerendered"))
            -- not disabled while in a rerendering automation
            enabled = true
            rolling.rendering_state = rolling.RENDERING_STATE.PARTIALLY_RERENDERED
            partial.callback()
            rolling.rendering_state = nil
            assert.is_true(enabled)

            partial.hold_callback()
            local box = shown[#shown]
            assert.are.equal("Disable", box.choice1_text_func())
            box.choice1_callback()
            assert.is_true(G_reader_settings:isFalse("cre_partial_rerendering"))
            partial.hold_callback()
            box = shown[#shown]
            assert.are.equal("Enable", box.choice2_text_func())
            box.choice2_callback()
            assert.is_true(G_reader_settings:isTrue("cre_partial_rerendering"))
            G_reader_settings:delSetting("cre_partial_rerendering")
        end)

        it("should register key events depending on device keys", function()
            local key_events = rolling.key_events
            finally(function()
                rolling.key_events = key_events
                G_reader_settings:delSetting("left_right_keys_turn_pages")
            end)
            override(Device, "hasDPad", function() return true end)
            override(Device, "useDPadAsActionKeys", function() return true end)
            G_reader_settings:makeTrue("left_right_keys_turn_pages")
            rolling.key_events = {}
            rolling:registerKeyEvents()
            assert.are.equal(1, rolling.key_events.GotoNextView.args)
            assert.is_nil(rolling.key_events.GotoNextChapter)
            assert.truthy(rolling.key_events.MoveDown)
            G_reader_settings:delSetting("left_right_keys_turn_pages")
            override(BD, "mirroredUILayout", function() return true end)
            rolling.key_events = {}
            rolling:registerKeyEvents()
            assert.are.equal("Left", rolling.key_events.GotoNextChapter[1][1])
            override(Device, "useDPadAsActionKeys", function() return false end)
            rolling.key_events = {}
            rolling:registerKeyEvents()
            assert.are.same({ 0, -1 }, rolling.key_events.MoveUp.args)
            assert.are.equal("GotoPercent", rolling.key_events.Goto55.event)
        end)
    end)

    describe("opening books with older settings", function()
        local other_epub
        setup(function()
            other_epub = DataStorage:getDataDir() .. "/readerrolling_nav_old.epub"
            ffiutil.copyFile("spec/front/unit/data/juliet.epub", other_epub)
        end)
        local function reopen(settings)
            DocSettings:open(other_epub):purge()
            local ds = DocSettings:open(other_epub)
            for k, v in pairs(settings) do
                ds:saveSetting(k, v)
            end
            ds:flush()
            local shown = capture_show()
            local tasks = capture_schedule()
            local ui = new_readerui(other_epub)
            return ui, shown, tasks
        end

        it("should restore the position from a legacy last_percent in scroll mode", function()
            local ui = reopen({ last_percent = 0.5, copt_view_mode = 1 })
            finally(function() ui:onClose() end)
            assert.are.equal("scroll", ui.view.view_mode)
            local doc_height = ui.document.info.doc_height
            assert.are.near(doc_height / 2, ui.rolling.current_pos, 1)
            assert.are.equal(ui.document:getXPointer(), ui.rolling.xpointer)
        end)

        it("should start at the beginning of a never opened book", function()
            local ui = reopen({})
            finally(function() ui:onClose() end)
            assert.are.equal(1, ui.rolling.current_page)
            assert.are.equal(ui.document:getLatestDomVersion(), ui.doc_settings:readSetting("cre_dom_version"))
            assert.falsy(ui.rolling.using_non_normalized_xpointers)
        end)

        it("should propose a DOM version upgrade and migrate xpointers", function()
            local CreDocument = require("document/credocument")
            local cre = CreDocument:engineInit()
            local oldest = cre.getDomVersionWithNormalizedXPointers() - 1
            local ui, shown, tasks = reopen({
                cre_dom_version = oldest,
                last_xpointer = "/body/DocFragment[5]/body/div/div/div/p[3]/text().0",
                annotations = {
                    {
                        page = "/body/DocFragment[5]/body/div/div/div/p[3]/text().0",
                        pos0 = "/body/DocFragment[5]/body/div/div/div/p[3]/text().0",
                        pos1 = "/body/DocFragment[5]/body/div/div/div/p[3]/text().5",
                        text = "found",
                        datetime = "2026-01-01 00:00:00",
                    },
                    {
                        page = "/body/DocFragment[99]/body/nowhere.0",
                        datetime = "2026-01-02 00:00:00",
                    },
                },
            })
            local closed = false
            finally(function() if not closed then ui:onClose() end end)
            assert.is_true(ui.rolling.using_non_normalized_xpointers)
            local box
            for _, w in ipairs(shown) do
                if w.ok_text == "Upgrade now" then box = w end
            end
            assert.truthy(box)
            assert.truthy(box.text:find("may have been lost", 1, true))
            assert.is_false(box.dismissable)
            -- "Not for this book"
            box.cancel_callback()
            assert.is_true(ui.doc_settings:isTrue("cre_keep_old_dom_version"))
            -- "Upgrade now"
            local reloaded = 0
            ui.reloadDocument = function() reloaded = reloaded + 1 end
            local nb_tasks = #tasks
            box.ok_callback()
            assert.are.equal(nb_tasks + 1, #tasks)
            tasks[#tasks].fn()
            assert.are.equal(nb_tasks + 2, #tasks)
            assert.are.equal(2, tasks[#tasks].delay)
            ui.doc_settings.filepath = ui.doc_settings.filepath or (DocSettings:getSidecarDir(other_epub) .. "/metadata.epub.lua")
            tasks[#tasks].fn()
            assert.are.equal(1, reloaded)
            assert.are.equal(ui.document:getLatestDomVersion(), ui.doc_settings:readSetting("cre_dom_version"))
            local annotations = ui.annotation.annotations
            for _, item in ipairs(annotations) do
                if item.text ~= "found" then
                    assert.is_true(item.not_found_not_migrated)
                end
            end
            ui:onClose()
            closed = true
        end)
    end)
end)
