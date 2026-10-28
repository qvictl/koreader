describe("ReaderFooter modes, menu and refresh scheduling", function()
    local DocumentRegistry, ReaderUI, ReaderFooter, DocSettings, UIManager, Geom
    local CenterContainer, LeftContainer, RightContainer
    local Device, Screen, purgeDir, MockTime
    local sample_epub = "spec/front/unit/data/juliet.epub"
    local sample_pdf = "spec/front/unit/data/2col.pdf"
    local readerui

    -- Restored in after_each
    local saved = {}
    local function save(tbl, key)
        table.insert(saved, { tbl = tbl, key = key, value = rawget(tbl, key) })
    end
    local function override(tbl, key, value)
        save(tbl, key)
        tbl[key] = value
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        Device = require("device")
        -- Override powerd for running tests on devices with batteries.
        Device.powerd.isChargingHW = function() return false end
        Device.powerd.getCapacityHW = function() return 0 end
        require("document/canvascontext"):init(Device)
        DocumentRegistry = require("document/documentregistry")
        DocSettings = require("docsettings")
        ReaderUI = require("apps/reader/readerui")
        ReaderFooter = require("apps/reader/modules/readerfooter")
        UIManager = require("ui/uimanager")
        Geom = require("ui/geometry")
        CenterContainer = require("ui/widget/container/centercontainer")
        LeftContainer = require("ui/widget/container/leftcontainer")
        RightContainer = require("ui/widget/container/rightcontainer")
        purgeDir = require("ffi/util").purgeDir
        Screen = Device.screen
        MockTime = require("mock_time")
    end)

    teardown(function()
        G_reader_settings:delSetting("reader_footer_mode")
        G_reader_settings:delSetting("footer")
        G_reader_settings:delSetting("footer_presets")
        G_reader_settings:delSetting("reader_footer_custom_text")
        G_reader_settings:delSetting("reader_footer_custom_text_repetitions")
        G_reader_settings:delSetting("plugins_disabled")
        G_reader_settings:flush()
    end)

    -- Open a ReaderUI with the default footer settings, patched with `overrides`.
    local function openReader(file, overrides, footer_mode)
        local settings = {}
        for k, v in pairs(ReaderFooter.default_settings) do
            settings[k] = v
        end
        settings.battery = true
        for k, v in pairs(overrides or {}) do
            settings[k] = v
        end
        G_reader_settings:saveSetting("footer", settings)
        if footer_mode then
            G_reader_settings:saveSetting("reader_footer_mode", footer_mode)
        else
            G_reader_settings:delSetting("reader_footer_mode")
        end
        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(file),
        }
        return readerui.view.footer
    end

    before_each(function()
        -- NOTE: Forcefully disable the statistics plugin, as lj-sqlite3 is horribly broken under Busted.
        G_reader_settings:saveSetting("plugins_disabled", { statistics = true })
        saved = {}
    end)

    after_each(function()
        for i = #saved, 1, -1 do
            local s = saved[i]
            s.tbl[s.key] = s.value
        end
        saved = {}
        if readerui then
            fastforward_ui_events()
            readerui:onClose()
            readerui = nil
        end
        UIManager:quit()
        G_reader_settings:delSetting("reader_footer_mode")
        G_reader_settings:delSetting("screensaver_delay")
        G_reader_settings:delSetting("footer_presets")
        G_reader_settings:delSetting("reader_footer_custom_text")
        G_reader_settings:delSetting("reader_footer_custom_text_repetitions")
        purgeDir(DocSettings:getSidecarDir(sample_epub))
        os.remove(DocSettings:getHistoryPath(sample_epub))
        purgeDir(DocSettings:getSidecarDir(sample_pdf))
        os.remove(DocSettings:getHistoryPath(sample_pdf))
    end)

    local function countRefreshTasks(footer)
        local found = 0
        for _, task in ipairs(UIManager._task_queue) do
            if footer.autoRefreshFooter and task.action == footer.autoRefreshFooter then
                found = found + 1
            end
        end
        return found
    end

    -- Record events sent to ReaderUI; events listed in `swallow` are not propagated.
    local function recordEvents(swallow)
        local events = {}
        local orig = readerui.handleEvent
        override(readerui, "handleEvent", function(self, ev)
            table.insert(events, ev)
            if swallow and swallow[ev.handler] then return true end
            return orig(self, ev)
        end)
        return events
    end
    local function hasEvent(events, handler)
        for _, ev in ipairs(events) do
            if ev.handler == handler then return ev end
        end
    end

    local function getMenu(footer)
        local fake_menu = { setting = {} }
        footer:addToMainMenu(fake_menu)
        return fake_menu.status_bar.sub_item_table
    end
    local function itemTitle(item)
        return item.text or (item.text_func and item.text_func())
    end
    -- Find a menu item by a path of title prefixes
    local function findItem(items, path)
        local list, found = items, nil
        for _, prefix in ipairs(path) do
            found = nil
            for _, it in ipairs(list) do
                local title = itemTitle(it)
                if title and title:sub(1, #prefix) == prefix then
                    found = it
                    break
                end
            end
            assert(found, "menu item not found: " .. prefix)
            list = found.sub_item_table
        end
        return found
    end
    -- Run fn while capturing widgets passed to UIManager:show (they are not actually shown)
    local function captureShown(fn)
        local shown = {}
        local orig = UIManager.show
        UIManager.show = function(_, w) table.insert(shown, w) end
        local ok, err = pcall(fn)
        UIManager.show = orig
        assert(ok, err)
        return shown
    end
    local fake_touchmenu = { updateItems = function() end }

    describe("mode cycling", function()
        it("should skip disabled items and dynamic fillers when cycling", function()
            local footer = openReader(sample_pdf, {
                time = false, pages_left = false, battery = false,
                custom_text = true, dynamic_filler = true,
            })
            assert.is.same("page_progress", footer.mode_index[footer.mode])
            footer:onToggleFooterMode()
            assert.is.same("percentage", footer.mode_index[footer.mode])
            assert.is.same(footer.mode, G_reader_settings:readSetting("reader_footer_mode"))
            footer:onToggleFooterMode()
            assert.is.same("book_time_to_read", footer.mode_index[footer.mode])
            footer:onToggleFooterMode()
            assert.is.same("chapter_time_to_read", footer.mode_index[footer.mode])
            footer:onToggleFooterMode()
            assert.is.same("custom_text", footer.mode_index[footer.mode])
            assert.is.same("KOReader", footer.footer_text.text)
            -- dynamic_filler is enabled but never selectable as a single mode: we wrap to off
            footer:onToggleFooterMode()
            assert.is.same(footer.mode_list.off, footer.mode)
            assert.is_false(readerui.view.footer_visible)
            footer:onToggleFooterMode()
            assert.is.same("page_progress", footer.mode_index[footer.mode])
            assert.is_true(readerui.view.footer_visible)
        end)

        it("should only toggle the progress bar when no item is enabled", function()
            local items_off = {}
            for _, m in ipairs({"page_progress", "time", "pages_left", "battery", "percentage",
                                "book_time_to_read", "chapter_time_to_read"}) do
                items_off[m] = false
            end
            local footer = openReader(sample_pdf, items_off, 1)
            assert.is_true(footer.has_no_mode)
            assert.is.same(1, footer.mode)
            footer:onToggleFooterMode()
            assert.is.same(footer.mode_list.off, footer.mode)
            assert.is_false(readerui.view.footer_visible)
            footer:onToggleFooterMode()
            assert.is.same(footer.mode_list.page_progress, footer.mode)
            assert.is_true(readerui.view.footer_visible)
            assert.is.same("", footer.footer_text.text)

            -- Nothing at all to show: toggling is a no-op
            footer.settings.disable_progress_bar = true
            assert.is_nil(footer:onToggleFooterMode())
            assert.is.same(footer.mode_list.page_progress, footer.mode)
        end)

        it("should offer a toggle menu item when the tap zone is disabled", function()
            local zone = require("util").tableDeepCopy(G_defaults:readSetting("DTAP_ZONE_MINIBAR"))
            zone.w = 0
            G_defaults:saveSetting("DTAP_ZONE_MINIBAR", zone)
            local ok, err = pcall(function()
                local footer = openReader(sample_pdf)
                local item = findItem(getMenu(footer), {"Toggle mode"})
                assert.is_true(item.enabled_func())
                readerui.view.flipping_visible = true
                assert.is_false(item.enabled_func())
                readerui.view.flipping_visible = false
                item.callback()
                assert.is.same("time", footer.mode_index[footer.mode])
            end)
            G_defaults:delSetting("DTAP_ZONE_MINIBAR")
            assert(ok, err)
        end)

        it("should ignore taps when the status bar is locked", function()
            local footer = openReader(sample_pdf, { lock_tap = true })
            local mode = footer.mode
            assert.is_nil(footer:TapFooter())
            assert.is.same(mode, footer.mode)
            footer.settings.lock_tap = false
            assert.is_true(footer:TapFooter())
            assert.is_not.same(mode, footer.mode)
        end)

        it("should jump to the tapped percentage while in flipping mode", function()
            local footer = openReader(sample_pdf)
            local events = recordEvents({ onGotoPercentage = true })
            readerui.view.flipping_visible = true
            -- not yet painted: no dimen, nothing to jump to but tap is still consumed
            footer.progress_bar.dimen = nil
            assert.is_true(footer:TapFooter({ pos = Geom:new{ x = 50, y = 790 } }))
            assert.is_nil(hasEvent(events, "onGotoPercentage"))

            footer.progress_bar.dimen = Geom:new{ x = 10, y = 780, w = 200, h = 10 }
            local mode = footer.mode
            assert.is_true(footer:TapFooter({ pos = Geom:new{ x = 60, y = 785 } }))
            local ev = hasEvent(events, "onGotoPercentage")
            assert.truthy(ev)
            assert.is.same(0.25, ev.args[1])
            -- mode didn't change
            assert.is.same(mode, footer.mode)
            readerui.view.flipping_visible = false
        end)

        it("should show page progress while flipping and restore the mode on exit", function()
            local footer = openReader(sample_pdf, { auto_refresh_time = true })
            footer:applyFooterMode(footer.mode_list.time)
            footer:rescheduleFooterAutoRefreshIfNeeded()
            assert.is.same(1, countRefreshTasks(footer))
            footer:onEnterFlippingMode()
            assert.is.same(footer.mode_list.page_progress, footer.mode)
            assert.is.same(footer.mode_list.time, footer.orig_mode)
            -- page progress doesn't need auto refresh
            assert.is.same(0, countRefreshTasks(footer))
            footer:onExitFlippingMode()
            assert.is.same(footer.mode_list.time, footer.mode)
            assert.is.same(1, countRefreshTasks(footer))
        end)

        it("should notify ReaderView of a visibility change on next repaint", function()
            local footer = openReader(sample_pdf)
            local events = recordEvents()
            footer:applyFooterMode(footer.mode_list.off)
            assert.is_false(readerui.view.footer_visible)
            assert.is_true(footer.visibility_change)
            assert.is.same(footer.textGeneratorMap.empty, footer.genFooterText)
            footer:onUpdateFooter(true)
            assert.truthy(hasEvent(events, "onReaderFooterVisibilityChange"))
            assert.is_nil(footer.visibility_change)
            -- no visibility change: no flag
            footer:applyFooterMode(footer.mode_list.off)
            assert.is_nil(footer.visibility_change)
        end)

        it("should use the all-at-once generator when visible in all_at_once mode", function()
            local footer = openReader(sample_pdf, { all_at_once = true }, 1)
            footer:applyFooterMode(footer.mode_list.off)
            assert.is.same(footer.textGeneratorMap.empty, footer.genFooterText)
            footer:applyFooterMode(footer.mode_list.page_progress)
            assert.is.same(footer.genAllFooterText, footer.genFooterText)
        end)

        it("should only open skim dialog on hold inside a visible footer", function()
            local footer = openReader(sample_pdf)
            local events = recordEvents({ onShowSkimtoDialog = true })
            local ges = { pos = Geom:new{ x = 100, y = 790, w = 0, h = 0 } }
            assert.is_nil(footer:onHoldFooter(ges))
            footer.settings.skim_widget_on_hold = true
            footer.footer_content.dimen = Geom:new{ x = 0, y = 780, w = 600, h = 20 }
            assert.is_true(footer:onHoldFooter(ges))
            assert.truthy(hasEvent(events, "onShowSkimtoDialog"))
            -- outside
            assert.is_nil(footer:onHoldFooter({ pos = Geom:new{ x = 100, y = 100, w = 0, h = 0 } }))
            -- footer hidden
            readerui.view.footer_visible = false
            assert.is_nil(footer:onHoldFooter(ges))
            readerui.view.footer_visible = true
        end)
    end)

    describe("progress computation", function()
        it("should compute chapter progress from the toc", function()
            local footer = openReader(sample_pdf)
            local toc = readerui.toc
            override(toc, "getChapterPagesDone", function() return 4 end)
            override(toc, "getChapterPageCount", function() return 10 end)
            assert.is.same("5 ⁄⁄ 10", footer:getChapterProgress())
            assert.is.same(0.5, footer:getChapterProgress(true))
            -- not in any chapter: fall back to page number / book pages
            toc.getChapterPagesDone = function() return nil end
            toc.getChapterPageCount = function() return nil end
            assert.is.same("2 ⁄⁄ 2", footer:getChapterProgress(false, 2))
            assert.is.same("1 ⁄⁄ 2", footer.textGeneratorMap.chapter_progress(footer))
        end)

        it("should use the page number in flow with hidden flows", function()
            local footer = openReader(sample_pdf)
            local doc = readerui.document
            override(doc, "hasHiddenFlows", function() return true end)
            override(doc, "getPageFlow", function(_, page) return page > 1 and 1 or 0 end)
            override(doc, "getPageNumberInFlow", function() return 3 end)
            override(doc, "getTotalPagesInFlow", function() return 12 end)
            override(readerui.toc, "getChapterPagesDone", function() return nil end)
            override(readerui.toc, "getChapterPageCount", function() return 12 end)
            assert.is.same("3 ⁄⁄ 12", footer:getChapterProgress())
            footer.pageno = 1
            assert.is.same(0.25, footer:getBookProgress())
        end)

        it("should switch the progress bar to chapter progress", function()
            local footer = openReader(sample_pdf, { initial_marker = true })
            override(readerui.toc, "getChapterPagesDone", function() return 0 end)
            override(readerui.toc, "getChapterPageCount", function() return 4 end)
            override(readerui.toc, "getNextChapter", function() return 3 end)
            footer:onPageUpdate(2)
            assert.is.same(1, footer.initial_pageno)
            assert.is.same(1, footer.progress_bar.percentage)
            footer:onToggleChapterProgressBar()
            assert.is_true(footer.settings.chapter_progress_bar)
            -- ticks are removed with the chapter progress bar
            assert.is_nil(footer.progress_bar.ticks)
            assert.is.same(0.25, footer.progress_bar.percentage)
            -- same chapter as initial page: marker at the chapter progress of the initial page
            assert.is.same(0.25, footer.progress_bar.initial_percentage)
            -- different chapter: marker hidden
            readerui.toc.getNextChapter = function(_, page) return page + 1 end
            footer:onUpdateFooter()
            assert.is.same(-1, footer.progress_bar.initial_percentage)
            -- back to book progress bar: initial marker at initial page / pages
            footer:onToggleChapterProgressBar()
            assert.is.same(0.5, footer.progress_bar.initial_percentage)
            assert.is.same(1, footer.progress_bar.percentage)
        end)

        it("should place the initial marker relative to the current flow", function()
            local footer = openReader(sample_pdf, { initial_marker = true })
            local doc = readerui.document
            local flows = { 0, 0 }
            override(doc, "hasHiddenFlows", function() return true end)
            override(doc, "getPageFlow", function(_, page) return flows[page] end)
            override(doc, "getPageNumberInFlow", function(_, page) return page end)
            override(doc, "getTotalPagesInFlow", function() return 4 end)
            override(readerui.toc, "getChapterPagesDone", function() return 0 end)
            override(readerui.toc, "getChapterPageCount", function() return 2 end)
            override(readerui.toc, "getNextChapter", function() return 5 end)
            footer.initial_pageno = 1
            footer.pageno = 2
            footer:updateProgressBarInitialPercentage()
            assert.is.same(0.25, footer.progress_bar.initial_percentage)
            footer.settings.chapter_progress_bar = true
            footer:updateProgressBarInitialPercentage()
            assert.is.same(0.5, footer.progress_bar.initial_percentage)
            -- different chapters
            readerui.toc.getNextChapter = function(_, page) return page + 1 end
            footer:updateProgressBarInitialPercentage()
            assert.is.same(-1, footer.progress_bar.initial_percentage)
            -- chapter progress bar in a non-linear flow: no marker
            flows = { 1, 1 }
            footer:updateProgressBarInitialPercentage()
            assert.is.same(-1, footer.progress_bar.initial_percentage)
            -- initial page in another flow: no marker
            flows = { 0, 1 }
            footer.settings.chapter_progress_bar = false
            footer:updateProgressBarInitialPercentage()
            assert.is.same(-1, footer.progress_bar.initial_percentage)
        end)

        it("should recompute toc markers on flow change", function()
            local footer = openReader(sample_pdf)
            local doc = readerui.document
            override(doc, "hasHiddenFlows", function() return true end)
            override(doc, "getPageFlow", function(_, page) return page > 1 and 1 or 0 end)
            override(doc, "getPageNumberInFlow", function() return 1 end)
            override(doc, "getTotalPagesInFlow", function(_, flow) return flow == 0 and 5 or 3 end)
            override(readerui.toc, "getTocTicksFlattened", function() return { 1, 2 } end)
            footer.pageno = nil
            footer:onPageUpdate(1)
            assert.are.same({ 1 }, footer.progress_bar.ticks)
            assert.is.same(5, footer.progress_bar.last)
            footer:onPageUpdate(2)
            assert.are.same({ 1 }, footer.progress_bar.ticks)
            assert.is.same(3, footer.progress_bar.last)
        end)

        it("should update progress on PosUpdate and TocReset", function()
            local footer = openReader(sample_pdf)
            footer:onPosUpdate(nil, 2)
            assert.is.same(2, footer.pageno)
            assert.is.same(1, footer.percent_finished)
            footer.progress_bar.ticks = { 42 }
            override(readerui.toc, "getTocTicksFlattened", function() return { 2 } end)
            footer:onTocReset()
            assert.are.same({ 2 }, footer.progress_bar.ticks)
            assert.is.same(2, footer.pages)
        end)
    end)

    describe("menu", function()
        it("should toggle the progress bar position", function()
            local footer = openReader(sample_pdf)
            local menu = getMenu(footer)
            assert.is.same("Position: alongside items", itemTitle(findItem(menu, {"Progress bar", "Position:"})))
            findItem(menu, {"Progress bar", "Position:", "Above items"}).callback()
            assert.is.same("above", footer.settings.progress_bar_position)
            assert.is.same(footer.progress_bar, footer.vertical_frame[1])
            assert.is.same(footer.footer_container, footer.vertical_frame[3])
            -- the bar takes the whole width minus margins
            assert.is.same(Screen:getWidth() - 2 * Screen:scaleBySize(footer.settings.progress_margin_width),
                           footer.progress_bar.width)
            findItem(menu, {"Progress bar", "Position:", "Below items"}).callback()
            assert.is.same(footer.footer_container, footer.vertical_frame[1])
            assert.is.same(footer.progress_bar, footer.vertical_frame[3])
            footer.settings.align = "left"
            findItem(menu, {"Progress bar", "Position:", "Alongside items"}).callback()
            -- alongside forces centered text
            assert.is.same("center", footer.settings.align)
            assert.is.same(footer.footer_container, footer.vertical_frame[1])
            assert.is_nil(footer.vertical_frame[2])
        end)

        it("should align text left, right or center", function()
            local footer = openReader(sample_pdf, { progress_bar_position = "below" })
            local menu = getMenu(footer)
            local align = findItem(menu, {"Configure items", "Alignment:"})
            assert.is_true(align.enabled_func())
            findItem(menu, {"Configure items", "Alignment:", "Left"}).callback()
            assert.is.same("left", footer.settings.align)
            assert.is.same(LeftContainer, getmetatable(footer.footer_container))
            assert.is.same("Alignment: left", itemTitle(align))
            -- not centered: text is constrained to the container
            local text_max = footer.footer_text.max_width
            assert.is.same(math.floor(Screen:getWidth() - 2 * footer.horizontal_margin), text_max)
            findItem(menu, {"Configure items", "Alignment:", "Right"}).callback()
            assert.is.same(RightContainer, getmetatable(footer.footer_container))
            -- a dynamic filler forces centering
            footer.settings.dynamic_filler = true
            footer:updateFooterContainer()
            assert.is.same(CenterContainer, getmetatable(footer.footer_container))
            footer.settings.dynamic_filler = false
            findItem(menu, {"Configure items", "Alignment:", "Center"}).callback()
            assert.is.same(CenterContainer, getmetatable(footer.footer_container))
            assert.is.same(math.floor(Screen:getWidth() - 2 * Screen:scaleBySize(footer.settings.progress_margin_width)),
                           footer.footer_text.max_width)
            -- alongside: alignment is disabled
            footer.settings.progress_bar_position = "alongside"
            assert.is_false(align.enabled_func())
        end)

        it("should reflect current settings in checkable menu items", function()
            local footer = openReader(sample_pdf, { auto_refresh_time = true })
            local menu = getMenu(footer)
            local function checkedIn(path)
                local checked = {}
                for _, it in ipairs(findItem(menu, path).sub_item_table) do
                    if it.checked_func and it.checked_func() then
                        table.insert(checked, itemTitle(it))
                    end
                end
                return checked
            end
            assert.are.same({ "Alongside items" }, checkedIn({"Progress bar", "Position:"}))
            assert.are.same({ "Thick" }, checkedIn({"Progress bar", "Thickness and height:"}))
            assert.are.same({ "Medium" }, checkedIn({"Progress bar", "Chapter marker width:"}))
            assert.are.same({ "No decimal places (⤠ 50%)" }, checkedIn({"Configure items", "Progress percentage format:"}))
            assert.is.same(1, #checkedIn({"Configure items", "Item symbols:"}))
            assert.is.same("Icons", checkedIn({"Configure items", "Item symbols:"})[1]:match("^%a+"))
            assert.are.same({ "Vertical bar (|)" }, checkedIn({"Configure items", "Item separator:"}))
            assert.are.same({ "Center" }, checkedIn({"Configure items", "Alignment:"}))
            assert.is_true(findItem(menu, {"Status bar items", "Current page"}).checked_func())
            assert.is_false(findItem(menu, {"Status bar items", "Book title"}).checked_func())
            assert.is_true(findItem(menu, {"Configure items", "Auto refresh items"}).checked_func())
            assert.is_false(findItem(menu, {"Configure items", "Item font:", "Items in bold"}).checked_func())
            assert.falsy(findItem(menu, {"Progress bar", "Lock width at minimum"}).checked_func())
            assert.is_false(findItem(menu, {"Show status bar separator"}).checked_func())
            for _, path in ipairs({ {"Progress bar", "Position:"}, {"Progress bar", "Thickness and height:"},
                                    {"Progress bar", "Margins:"}, {"Progress bar", "Show initial-position marker"},
                                    {"Progress bar", "Chapter marker width:"} }) do
                assert.is_true(findItem(menu, path).enabled_func())
            end
            -- not in all_at_once: minimum width is meaningless
            assert.is_false(findItem(menu, {"Progress bar", "Lock width at minimum"}).enabled_func())
            assert.is.same("table", type(findItem(menu, {"Status bar presets"}).sub_item_table_func()))

            local chapter_bar = findItem(menu, {"Progress bar", "Show chapter-progress bar instead"})
            assert.is_true(chapter_bar.enabled_func())
            assert.falsy(chapter_bar.checked_func())
            chapter_bar.callback()
            assert.is_true(chapter_bar.checked_func())
            -- chapter markers make no sense on a chapter progress bar
            assert.is_false(findItem(menu, {"Progress bar", "Show chapter markers"}).checked_func())
            assert.is_false(findItem(menu, {"Progress bar", "Show chapter markers"}).enabled_func())
            assert.is_false(findItem(menu, {"Progress bar", "Chapter marker width:"}).enabled_func())
        end)

        it("should toggle the progress bar and show a hidden footer", function()
            local footer = openReader(sample_pdf)
            local menu = getMenu(footer)
            local item = findItem(menu, {"Progress bar", "Show progress bar"})
            assert.is_true(item.checked_func())
            item.callback()
            assert.is_true(footer.settings.disable_progress_bar)
            assert.is.same(0, footer.progress_bar.width)
            assert.is.same(0, footer.progress_bar.height)
            -- text only constrained by container
            assert.is.same(footer.footer_text:getSize().w, footer.text_width)
            assert.is_false(findItem(menu, {"Progress bar", "Show chapter-progress bar instead"}).enabled_func())
            -- hide footer, then re-enable the progress bar: footer comes back in page progress mode
            footer:applyFooterMode(footer.mode_list.off)
            item.callback()
            assert.is_false(footer.settings.disable_progress_bar)
            assert.is.same(footer.mode_list.page_progress, footer.mode)
            assert.is_true(readerui.view.footer_visible)
            assert.is.same(footer.mode_list.page_progress, G_reader_settings:readSetting("reader_footer_mode"))
        end)

        it("should report no text when the progress bar is disabled and items are empty", function()
            local footer = openReader(sample_pdf, { disable_progress_bar = true })
            footer.genFooterText = footer.textGeneratorMap.empty
            footer:onUpdateFooter()
            assert.is.same(0, footer.text_width)
            assert.is.same(0, footer.footer_text.height)
            footer.settings.progress_bar_position = "above"
            footer.settings.disable_progress_bar = false
            footer:onUpdateFooter()
            assert.is.same(0, footer.text_width)
        end)

        it("should switch progress bar thickness and height", function()
            local footer = openReader(sample_pdf)
            local menu = getMenu(footer)
            local thickness = findItem(menu, {"Progress bar", "Thickness and height:"})
            assert.is.same("Thickness and height: thick", itemTitle(thickness))
            findItem(menu, {"Progress bar", "Thickness and height:", "Thin"}).callback()
            assert.is_true(footer.settings.progress_style_thin)
            assert.is.same("Thickness and height: thin", itemTitle(thickness))
            -- chapter markers can't be shown with a thin bar
            assert.is_false(findItem(menu, {"Progress bar", "Show chapter markers"}).enabled_func())
            local height = findItem(menu, {"Progress bar", "Thickness and height:", "Height:"})
            assert.is.same("Height: 3", itemTitle(height))
            local shown = captureShown(function() height.callback(fake_touchmenu) end)
            assert.is.same(1, shown[1].value_min)
            assert.is.same(12, shown[1].value_max)
            shown[1].callback({ value = 5 })
            assert.is.same(5, footer.settings.progress_style_thin_height)
            assert.is.same(5, footer.progress_bar.height)

            findItem(menu, {"Progress bar", "Thickness and height:", "Thick"}).callback()
            assert.is_nil(footer.settings.progress_style_thin)
            shown = captureShown(function() height.callback(fake_touchmenu) end)
            assert.is.same(5, shown[1].value_min)
            assert.is.same(28, shown[1].value_max)
            shown[1].callback({ value = 9 })
            assert.is.same(9, footer.settings.progress_style_thick_height)
            assert.is.same(9, footer.progress_bar.height)
        end)

        it("should set progress bar margins", function()
            local footer = openReader(sample_epub)
            local menu = getMenu(footer)
            local item = findItem(menu, {"Progress bar", "Margins:"})
            assert.is.same("Margins: 10", itemTitle(item))
            local shown = captureShown(function() item.callback(fake_touchmenu) end)
            shown[1].callback({ value = 20 })
            assert.is.same(20, footer.settings.progress_margin_width)
            assert.is_false(footer.settings.progress_margin)
            assert.is.same("Margins: 20", itemTitle(item))
            -- reflowable doc: margins can follow the book margins
            local h = readerui.document.configurable.h_page_margins
            shown[1].extra_callback()
            assert.is_true(footer.settings.progress_margin)
            assert.is.same(math.floor((h[1] + h[2]) / 2), footer.settings.progress_margin_width)
            assert.is.same("Margins: same as book margins", itemTitle(item))
            -- and follow book margins changes
            footer:onSetPageHorizMargins({ 30, 50 })
            assert.is.same(40, footer.settings.progress_margin_width)
            footer.settings.progress_margin = false
            footer:onSetPageHorizMargins({ 0, 0 })
            assert.is.same(40, footer.settings.progress_margin_width)
        end)

        it("should lock the progress bar width at its minimum", function()
            local footer = openReader(sample_pdf, { all_at_once = true })
            local menu = getMenu(footer)
            local min_item = findItem(menu, {"Progress bar", "Minimum progress bar width:"})
            assert.is_true(min_item.enabled_func())
            local shown = captureShown(function() min_item.callback(fake_touchmenu) end)
            shown[1].callback({ value = 40 })
            assert.is.same(40, footer.settings.progress_bar_min_width_pct)
            local lock = findItem(menu, {"Progress bar", "Lock width at minimum"})
            assert.is_true(lock.enabled_func())
            lock.callback()
            assert.is_true(footer.settings.progress_bar_lock_width)
            local w = Screen:getWidth()
            local bar_width = 0.4 * w
            assert.is.same(w - bar_width + footer.horizontal_margin, footer.text_width)
            lock.callback()
            assert.is_nil(footer.settings.progress_bar_lock_width)
        end)

        it("should toggle initial marker, chapter markers and their width", function()
            local footer = openReader(sample_pdf)
            local menu = getMenu(footer)
            local initial = findItem(menu, {"Progress bar", "Show initial-position marker"})
            assert.is_false(initial.checked_func())
            initial.callback()
            assert.is_true(footer.progress_bar.initial_pos_marker)
            assert.is_true(initial.checked_func())

            override(readerui.toc, "getTocTicksFlattened", function() return { 1 } end)
            footer:setTocMarkers(true)
            local markers = findItem(menu, {"Progress bar", "Show chapter markers"})
            assert.is_true(markers.checked_func())
            markers.callback()
            assert.is_nil(footer.progress_bar.ticks)
            markers.callback()
            assert.are.same({ 1 }, footer.progress_bar.ticks)

            local width = findItem(menu, {"Progress bar", "Chapter marker width:"})
            assert.is.same("Chapter marker width: medium", itemTitle(width))
            findItem(menu, {"Progress bar", "Chapter marker width:", "Thick"}).callback()
            assert.is.same(3, footer.settings.toc_markers_width)
            assert.is.same(Screen:scaleBySize(3), footer.progress_bar.tick_width)
        end)

        it("should change percentage format, symbols and separators", function()
            local footer = openReader(sample_pdf, { all_at_once = true, time = false, battery = false,
                                                    book_time_to_read = false, chapter_time_to_read = false })
            local menu = getMenu(footer)
            assert.is.same("1 / 2 | ⇒ 1 | ⤠ 50%", footer.footer_text.text)
            local fmt = findItem(menu, {"Configure items", "Progress percentage format:"})
            assert.is.same("Progress percentage format: ⤠ 50%", itemTitle(fmt))
            local two = findItem(menu, {"Configure items", "Progress percentage format:", "2 decimal"})
            assert.is.same("2 decimal places (⤠ 50.00%)", itemTitle(two))
            two.callback()
            assert.is_true(two.checked_func())
            assert.is.same("1 / 2 | ⇒ 1 | ⤠ 50.00%", footer.footer_text.text)

            findItem(menu, {"Configure items", "Item symbols:", "Letters"}).callback()
            assert.is.same("Item symbols: letters", itemTitle(findItem(menu, {"Configure items", "Item symbols:"})))
            assert.is.same("1 / 2 | => 1 | R: 50.00%", footer.footer_text.text)

            findItem(menu, {"Configure items", "Item separator:", "Bullet"}).callback()
            assert.is.same("1 / 2 • => 1 • R: 50.00%", footer.footer_text.text)
            findItem(menu, {"Configure items", "Item separator:", "Dot"}).callback()
            assert.is.same("1 / 2 · => 1 · R: 50.00%", footer.footer_text.text)
            findItem(menu, {"Configure items", "Item separator:", "No separator"}).callback()
            assert.is.same("Item separator: no separator", itemTitle(findItem(menu, {"Configure items", "Item separator:"})))
            assert.is.same("1 / 2  => 1  R: 50.00%", footer.footer_text.text)

            -- compact symbols: whitespace inside items is replaced by hair spaces
            local compact = findItem(menu, {"Configure items", "Item symbols:", "Compact"})
            assert.truthy(itemTitle(compact):find("^Compact %("))
            compact.callback()
            assert.is.same("1\u{200A}/\u{200A}2 ›\u{200A}1 50.00%", footer.footer_text.text)
        end)

        it("should toggle misc configure options", function()
            local footer = openReader(sample_pdf, { all_at_once = true })
            local menu = getMenu(footer)
            local hide = findItem(menu, {"Configure items", "Hide inactive items"})
            assert.is_true(hide.enabled_func())
            hide.callback()
            assert.is_true(footer.settings.hide_empty_generators)
            assert.is_true(hide.checked_func())

            local incl = findItem(menu, {"Configure items", "Include current page in pages left"})
            assert.is_true(incl.enabled_func())
            assert.is.same("⇒ 1", footer.textGeneratorMap.pages_left(footer))
            incl.callback()
            assert.is_true(incl.checked_func())
            assert.is.same("⇒ 2", footer.textGeneratorMap.pages_left(footer))

            local bold = findItem(menu, {"Configure items", "Item font:", "Items in bold"})
            bold.callback()
            assert.is_true(footer.settings.text_font_bold)
            assert.is_true(footer.footer_text.bold)
            assert.is.same(footer.footer_text, footer.text_container[1])
            assert.is.same("Item font: default, 14, bold", itemTitle(findItem(menu, {"Configure items", "Item font:"})))

            local size = findItem(menu, {"Configure items", "Item font:", "Item font size:"})
            local shown = captureShown(function() size.callback(fake_touchmenu) end)
            shown[1].callback({ value = 20 })
            assert.is.same(20, footer.settings.text_font_size)
            assert.is.same(20, footer.footer_text_face.orig_size)

            -- unknown font falls back to the default one
            local font = findItem(menu, {"Configure items", "Item font:", "Item font: default"})
            shown = captureShown(function() font.callback(fake_touchmenu) end)
            shown[1].callback("/nonexistent/font.ttf")
            assert.is.same(ReaderFooter.default_settings.text_font_face, footer.settings.text_font_face)
            footer.settings.text_font_face = "/other.ttf"
            font.hold_callback(fake_touchmenu)
            assert.is.same(ReaderFooter.default_settings.text_font_face, footer.settings.text_font_face)

            local sep = findItem(menu, {"Show status bar separator"})
            sep.callback()
            assert.is_true(sep.checked_func())
            assert.truthy(footer.separator_line)
            assert.is.same(footer.separator_line, footer.vertical_frame[1])
            assert.is.same(Screen:getWidth() - 2 * footer.horizontal_margin, footer.separator_line.dimen.w)

            local lock = findItem(menu, {"Lock status bar"})
            lock.callback()
            assert.is_true(lock.checked_func())
            local skim = findItem(menu, {"Long-press on status bar to skim"})
            skim.callback()
            assert.is_true(skim.checked_func())
        end)

        it("should resize the items container", function()
            local footer = openReader(sample_pdf)
            local menu = getMenu(footer)
            local height = findItem(menu, {"Configure items", "Height:"})
            local shown = captureShown(function() height.callback(fake_touchmenu) end)
            shown[1].callback({ value = 30 })
            assert.is.same(Screen:scaleBySize(30), footer.height)
            assert.is.same("Height: 30", itemTitle(height))
            local margin = findItem(menu, {"Configure items", "Bottom margin:"})
            shown = captureShown(function() margin.callback(fake_touchmenu) end)
            shown[1].callback({ value = 5 })
            assert.is.same(Screen:scaleBySize(5), footer.bottom_padding)
            assert.is.same(footer.height + footer.bottom_padding, footer:getHeight())

            local maxw = findItem(menu, {"Configure items", "Item max width", "Book-title item"})
            shown = captureShown(function() maxw.callback(fake_touchmenu) end)
            shown[1].callback({ value = 55 })
            assert.is.same(55, footer.settings.book_title_max_width_pct)
            assert.truthy(itemTitle(maxw):find("55"))
        end)

        it("should hide the battery item above a threshold", function()
            override(Device.powerd, "getCapacity", function() return 80 end)
            local footer = openReader(sample_pdf, { all_at_once = true })
            local menu = getMenu(footer)
            local item = findItem(menu, {"Configure items", "Hide battery item"})
            assert.is_true(item.enabled_func())
            assert.is_true(item.checked_func())
            local shown = captureShown(function() item.callback(fake_touchmenu) end)
            shown[1].callback({ value = 50 })
            assert.is.same(50, footer.settings.battery_hide_threshold)
            assert.is.same("", footer.textGeneratorMap.battery(footer))
            assert.falsy(footer.footer_text.text:find("80%", 1, true))
            shown[1].extra_callback()
            assert.is.same(ReaderFooter.default_settings.battery_hide_threshold + 1, footer.settings.battery_hide_threshold)
            assert.is_false(item.checked_func())
            assert.is.same("Hide battery item at custom threshold", itemTitle(item))
            assert.truthy(footer.footer_text.text:find("80%", 1, true))
        end)

        it("should reorder items with the arrange dialog", function()
            local footer = openReader(sample_pdf, { all_at_once = true, battery = false, pages_left = false,
                                                    book_time_to_read = false, chapter_time_to_read = false,
                                                    percentage = false })
            local timeinfo = footer.textGeneratorMap.time(footer)
            local menu = getMenu(footer)
            local arrange = findItem(menu, {"Configure items", "Arrange items in status bar"})
            assert.is_true(arrange.enabled_func())
            local shown = captureShown(function() arrange.callback() end)
            local sort = shown[1]
            local items = sort.item_table
            assert.is.same("page_progress", items[1].label)
            assert.is_false(items[1].dim)
            -- move "time" before "page_progress"
            local t_idx
            for i, it in ipairs(items) do
                if it.label == "time" then t_idx = i end
            end
            items[1], items[t_idx] = items[t_idx], items[1]
            sort.callback()
            assert.is.same("time", footer.settings.order[1])
            assert.is.same(timeinfo .. " | 1 / 2", footer.footer_text.text)
            -- the saved order is honored by set_mode_index
            footer:set_mode_index()
            assert.is.same("time", footer.mode_index[1])
            assert.is.same("page_progress", footer.mode_index[t_idx])
            -- a single enabled item can't be arranged
            footer.settings.time = false
            assert.is_false(arrange.enabled_func())
        end)

        it("should drop unknown modes from a saved order", function()
            local order = { [0] = "off", "time", "no_such_mode", "page_progress" }
            local footer = openReader(sample_pdf, { order = order })
            assert.is.same("off", footer.mode_index[0])
            assert.is.same("time", footer.mode_index[1])
            assert.is.same("page_progress", footer.mode_index[2])
            assert.is.same(footer.mode_nb, #footer.mode_index + 1)
            for i = 0, #footer.mode_index do
                assert.is_not.same("no_such_mode", footer.mode_index[i])
            end
        end)

        it("should restore a mode when enabling an item while none was enabled", function()
            local items_off = {}
            for _, m in ipairs({"page_progress", "time", "pages_left", "battery", "percentage",
                                "book_time_to_read", "chapter_time_to_read"}) do
                items_off[m] = false
            end
            items_off.all_at_once = true
            local footer = openReader(sample_pdf, items_off, 1)
            local menu = getMenu(footer)
            assert.is_true(footer.has_no_mode)
            footer:applyFooterMode(footer.mode_list.off)
            findItem(menu, {"Status bar items", "Current time"}).callback()
            assert.is_false(footer.has_no_mode)
            assert.is.same(footer.mode_list.page_progress, footer.mode)
            assert.is.same(footer.mode_list.page_progress, G_reader_settings:readSetting("reader_footer_mode"))
            assert.is.same(footer.textGeneratorMap.time(footer), footer.footer_text.text)
        end)

        it("should save the first enabled mode when enabling an item while none was enabled", function()
            local items_off = {}
            for _, m in ipairs({"page_progress", "time", "pages_left", "battery", "percentage",
                                "book_time_to_read", "chapter_time_to_read"}) do
                items_off[m] = false
            end
            local footer = openReader(sample_pdf, items_off, 1)
            local menu = getMenu(footer)
            findItem(menu, {"Status bar items", "Pages left in chapter"}).callback()
            assert.is.same(footer.mode_list.pages_left, footer.mode)
            assert.is.same(footer.mode_list.pages_left, G_reader_settings:readSetting("reader_footer_mode"))
            assert.is.same("⇒ 1", footer.footer_text.text)
        end)

        it("should signal a margin change when toggling overlap", function()
            local footer = openReader(sample_pdf)
            local menu = getMenu(footer)
            local spy_refresh = spy.on(footer, "refreshFooter")
            local item = findItem(menu, {"Overlap status bar"})
            assert.truthy(item.help_text)
            item.callback()
            assert.is_true(footer.reclaim_height)
            assert.spy(spy_refresh).was.called_with(match.is_ref(footer), true, true)
            footer.refreshFooter:revert()
        end)

        it("should edit custom text through its dialog", function()
            local footer = openReader(sample_pdf, { custom_text = true, all_at_once = true, time = false })
            local menu = getMenu(footer)
            local item = findItem(menu, {"Status bar items", "Custom text"})
            assert.is.same("Custom text (long-press to edit): 'KOReader'", itemTitle(item))
            local shown = captureShown(function() item.help_text_func(fake_touchmenu) end)
            local dialog = shown[1]
            assert.truthy(dialog.getFields)
            local buttons = {}
            for _, b in ipairs(dialog.buttons[1]) do
                buttons[b.text] = b.callback
            end
            -- cancel keeps the current text
            local closed
            override(UIManager, "close", function(_, w) closed = w end)
            buttons["Cancel"]()
            assert.is.same(dialog, closed)
            assert.is.same("KOReader", footer.custom_text)
            -- patterns are delegated to bookinfo
            local pattern_args
            override(readerui.bookinfo, "chooseExpandStringPattern", function(d, ui) pattern_args = { d, ui } end)
            buttons["Patterns"]()
            assert.is.same(dialog, pattern_args[1])
            assert.is.same(readerui, pattern_args[2])
            dialog.getFields = function() return { "Hi", "3" } end
            local set_cb = buttons["Set"]
            captureShown(set_cb)
            assert.is.same("Hi", footer.custom_text)
            assert.is.same(3, footer.custom_text_repetitions)
            assert.is.same("Hi", G_reader_settings:readSetting("reader_footer_custom_text"))
            assert.is.same(3, G_reader_settings:readSetting("reader_footer_custom_text_repetitions"))
            assert.is.same("Custom text (long-press to edit): 'Hi' × 3", itemTitle(item))
            assert.truthy(footer.footer_text.text:find("HiHiHi", 1, true))
            -- empty text and invalid repetitions are sanitized
            dialog.getFields = function() return { "", "-2" } end
            captureShown(set_cb)
            assert.is.same(" ", footer.custom_text)
            assert.is.same(1, footer.custom_text_repetitions)
        end)
    end)

    describe("presets", function()
        it("should build and load a preset", function()
            local footer = openReader(sample_pdf, { all_at_once = true })
            footer:applyFooterMode(footer.mode_list.off)
            local preset = footer:buildPreset()
            -- a hidden footer with a progress bar is saved as visible
            assert.is.same(footer.mode_list.page_progress, preset.reader_footer_mode)
            assert.is.same("KOReader", preset.reader_footer_custom_text)
            preset.footer.item_prefix = "letters"
            preset.footer.text_font_size = 18
            preset.footer.progress_style_thin = true
            preset.reader_footer_custom_text = "Preset"
            G_reader_settings:saveSetting("footer_presets", { mine = preset })
            footer.preset_obj.presets = G_reader_settings:readSetting("footer_presets")
            assert.are.same({ "mine" }, ReaderFooter.getPresets())

            footer:onLoadFooterPreset("mine")
            assert.is.same("letters", footer.settings.item_prefix)
            assert.is.same(18, footer.footer_text_face.orig_size)
            assert.is.same("Preset", footer.custom_text)
            assert.is.same(footer.mode_list.page_progress, footer.mode)
            assert.is_true(readerui.view.footer_visible)
            assert.is.same(Screen:scaleBySize(3), footer.progress_bar.height)
            assert.truthy(footer.footer_text.text:find("R: 50%", 1, true))
            -- the preset settings are deep-copied, not shared
            footer.settings.item_prefix = "icons"
            assert.is.same("letters", preset.footer.item_prefix)

            -- loading a preset keeping the same font only resets the filler cache
            footer.filler_space_width = 42
            footer:loadPreset(footer:buildPreset())
            assert.is_nil(footer.filler_space_width)
        end)
    end)

    describe("additional content", function()
        it("should add and remove external content", function()
            local footer = openReader(sample_pdf, { all_at_once = true, time = false, battery = false,
                                                    book_time_to_read = false, chapter_time_to_read = false,
                                                    pages_left = false, percentage = false })
            local a = function() return "A" end
            local b = function() return "" end
            local c = function() return "C" end
            assert.is_nil(footer.textGeneratorMap.additional_content(footer))
            footer:addAdditionalFooterContent(a)
            assert.is_true(footer.settings.additional_content)
            assert.is.same("A", footer.textGeneratorMap.additional_content(footer))
            footer:onRefreshAdditionalContent()
            assert.is.same("1 / 2 | A", footer.footer_text.text)
            footer:addAdditionalFooterContent(b)
            footer:addAdditionalFooterContent(c)
            assert.is.same("A | C", footer.textGeneratorMap.additional_content(footer))
            footer:removeAdditionalFooterContent(a)
            footer:removeAdditionalFooterContent(c)
            assert.is_true(footer.settings.additional_content)
            -- only an empty provider left
            assert.is_nil(footer.textGeneratorMap.additional_content(footer))
            footer:removeAdditionalFooterContent(function() end) -- unknown, ignored
            assert.is.same(1, #footer.additional_footer_content)
            footer:removeAdditionalFooterContent(b)
            assert.is_nil(footer.settings.additional_content)
            -- no content: refresh request ignored
            local s = spy.on(footer, "maybeUpdateFooter")
            footer:onRefreshAdditionalContent()
            assert.spy(s).was_not.called()
            footer.maybeUpdateFooter:revert()
        end)
    end)

    describe("auto refresh", function()
        after_each(function()
            MockTime:uninstall()
        end)

        it("should only schedule in single mode for items that change over time", function()
            local footer = openReader(sample_pdf, { auto_refresh_time = true })
            assert.is.same(footer.mode_list.page_progress, footer.mode)
            assert.is.same(0, countRefreshTasks(footer))
            for _, m in ipairs({ "time", "battery", "mem_usage" }) do
                footer.mode = footer.mode_list[m]
                footer:rescheduleFooterAutoRefreshIfNeeded()
                assert.is.same(1, countRefreshTasks(footer))
            end
            -- rescheduling doesn't duplicate the task
            footer:rescheduleFooterAutoRefreshIfNeeded()
            assert.is.same(1, countRefreshTasks(footer))
            footer.mode = footer.mode_list.percentage
            footer:rescheduleFooterAutoRefreshIfNeeded()
            assert.is.same(0, countRefreshTasks(footer))
        end)

        it("should not schedule in all_at_once mode without time-dependent items", function()
            local footer = openReader(sample_pdf, { auto_refresh_time = true, all_at_once = true,
                                                    time = false, battery = false })
            assert.is.same(0, countRefreshTasks(footer))
            footer.settings.mem_usage = true
            footer:rescheduleFooterAutoRefreshIfNeeded()
            assert.is.same(1, countRefreshTasks(footer))
        end)

        it("should refresh every minute and reschedule itself", function()
            MockTime:install()
            local footer = openReader(sample_pdf, { auto_refresh_time = true, all_at_once = true })
            assert.is.same(1, countRefreshTasks(footer))
            local task
            for _, t in ipairs(UIManager._task_queue) do
                if t.action == footer.autoRefreshFooter then task = t end
            end
            local delay = require("ui/time").to_s(task.time - require("ui/time").now())
            assert.is_true(delay >= 1 and delay <= 61)
            local s = spy.on(footer, "onUpdateFooter")
            override(UIManager, "getTopmostVisibleWidget", function() return { name = "ReaderUI" } end)
            MockTime:increase(62)
            UIManager:_checkTasks()
            assert.spy(s).was.called_with(match.is_ref(footer), true)
            -- rescheduled for next minute
            assert.is.same(1, countRefreshTasks(footer))
            footer.onUpdateFooter:revert()
        end)

        it("should decide whether repainting is safe", function()
            local footer = openReader(sample_pdf)
            local top = { name = "ReaderUI" }
            override(UIManager, "getTopmostVisibleWidget", function() return top end)
            assert.is_true(footer:shouldBeRepainted())
            top = { covers_fullscreen = true }
            assert.is_false(footer:shouldBeRepainted())
            top = { covers_footer = true }
            assert.is_false(footer:shouldBeRepainted())
            top = { name = "SomeDialog" }
            local repaint, full = footer:shouldBeRepainted()
            assert.is_true(repaint)
            assert.is_true(full)
            top = nil
            repaint, full = footer:shouldBeRepainted()
            assert.is_true(repaint and full)
            readerui.view.footer_visible = false
            assert.is_false(footer:shouldBeRepainted())
            readerui.view.footer_visible = true
        end)

        it("should not regenerate the text of a hidden footer", function()
            local footer = openReader(sample_pdf)
            local calls = 0
            footer.genFooterText = function() calls = calls + 1 return "x" end
            readerui.view.footer_visible = false
            footer:onUpdateFooter()
            assert.is.same(0, calls)
            footer:onUpdateFooter(true)
            assert.is.same(1, calls)
            readerui.view.footer_visible = true
            footer:onUpdateFooter()
            assert.is.same(2, calls)
            -- no page yet: nothing at all
            footer.pageno = nil
            footer:onUpdateFooter(true)
            assert.is.same(2, calls)
        end)

        it("should unschedule on suspend and reschedule on resume", function()
            local footer = openReader(sample_pdf, { auto_refresh_time = true, all_at_once = true })
            assert.is.same(1, countRefreshTasks(footer))
            footer:onSuspend()
            assert.is.same(0, countRefreshTasks(footer))
            local s = spy.on(footer, "onUpdateFooter")
            override(UIManager, "getTopmostVisibleWidget", function() return { name = "ReaderUI" } end)
            footer:onResume()
            assert.spy(s).was.called_with(match.is_ref(footer), true)
            assert.is.same(1, countRefreshTasks(footer))
            -- spurious OutOfScreenSaver: nothing to do
            footer:onSuspend()
            footer:onOutOfScreenSaver()
            assert.is.same(0, countRefreshTasks(footer))
            footer.onUpdateFooter:revert()
        end)

        it("should wait for the screensaver to go away when delayed", function()
            local footer = openReader(sample_pdf, { auto_refresh_time = true, all_at_once = true, initial_marker = true })
            G_reader_settings:saveSetting("screensaver_delay", "tap")
            footer:onPageUpdate(2)
            footer:onSuspend()
            footer:onResume()
            -- initial marker reset to current position
            assert.is.same(2, footer.initial_pageno)
            assert.is.same(footer.progress_bar.percentage, footer.progress_bar.initial_percentage)
            assert.is_true(footer._delayed_screensaver)
            assert.is.same(0, countRefreshTasks(footer))
            footer:onOutOfScreenSaver()
            assert.is_nil(footer._delayed_screensaver)
            assert.is.same(1, countRefreshTasks(footer))
        end)

        it("should be safe to unschedule before any scheduling", function()
            local footer = openReader(sample_pdf)
            footer.autoRefreshFooter = nil
            assert.has_no.errors(function() footer:onSuspend() end)
        end)
    end)

    describe("events", function()
        it("should only repaint on network changes when showing wifi status", function()
            local footer = openReader(sample_pdf)
            local s = spy.on(footer, "maybeUpdateFooter")
            footer:onNetworkConnected()
            footer:onNetworkDisconnected()
            assert.spy(s).was_not.called()
            footer.settings.wifi_status = true
            footer:onNetworkConnected()
            footer:onNetworkDisconnected()
            assert.spy(s).was.called(2)
            footer.maybeUpdateFooter:revert()
        end)

        it("should delay repaint on page turn inversion only when showing it", function()
            local footer = openReader(sample_pdf)
            local n = #UIManager._task_queue
            footer:onSwapPageTurnButtons()
            assert.is.same(n, #UIManager._task_queue)
            footer.settings.page_turning_inverted = true
            footer:onToggleReadingOrder()
            assert.is.same(n + 1, #UIManager._task_queue)
            local found = false
            for _, t in ipairs(UIManager._task_queue) do
                if t.action == footer.maybeUpdateFooter then found = true end
            end
            assert.is_true(found)
        end)

        it("should repaint on metadata changes of title or authors only", function()
            local footer = openReader(sample_pdf)
            local s = spy.on(footer, "maybeUpdateFooter")
            footer:onBookMetadataChanged()
            footer:onBookMetadataChanged({ metadata_key_updated = "series" })
            assert.spy(s).was_not.called()
            footer:onBookMetadataChanged({ metadata_key_updated = "title" })
            footer:onBookMetadataChanged({ metadata_key_updated = "authors" })
            assert.spy(s).was.called(2)
            footer.maybeUpdateFooter:revert()
        end)

        it("should rebuild layout on time format change and resize", function()
            local footer = openReader(sample_pdf)
            local s = spy.on(footer, "refreshFooter")
            footer:onTimeFormatChanged()
            assert.spy(s).was.called_with(match.is_ref(footer), true, true)
            footer.refreshFooter:revert()
            local old = Screen.getWidth
            Screen.getWidth = function() return 900 end
            footer:onScreenResize()
            Screen.getWidth = old
            assert.is.same(900, footer.footer_container.dimen.w)
            footer:onSetDimensions()
            assert.is.same(Screen:getWidth(), footer.footer_container.dimen.w)
        end)

        it("should invert the progress bar direction", function()
            local footer = openReader(sample_pdf)
            footer:invertProgressBar(true)
            assert.is_true(footer.progress_bar.invert_direction)
            footer:invertProgressBar(false)
            assert.is_false(footer.progress_bar.invert_direction)
        end)
    end)
end)
