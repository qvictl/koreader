describe("ReaderFooter items text generation", function()
    local DocumentRegistry, ReaderUI, ReaderFooter, DocSettings, UIManager, BD
    local Device, Screen, purgeDir, NetworkMgr
    local sample_epub = "spec/front/unit/data/juliet.epub"
    local sample_pdf = "spec/front/unit/data/2col.pdf"
    local readerui, footer, gen

    -- Restored in after_each
    local saved = {}
    local function override(tbl, key, value)
        table.insert(saved, { tbl = tbl, key = key, value = rawget(tbl, key) })
        tbl[key] = value
    end
    local function restoreAll()
        for i = #saved, 1, -1 do
            local s = saved[i]
            s.tbl[s.key] = s.value
        end
        saved = {}
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
        BD = require("ui/bidi")
        NetworkMgr = require("ui/network/manager")
        purgeDir = require("ffi/util").purgeDir
        Screen = Device.screen
        gen = ReaderFooter.textGeneratorMap
    end)

    teardown(function()
        G_reader_settings:delSetting("reader_footer_mode")
        G_reader_settings:delSetting("footer")
        G_reader_settings:delSetting("plugins_disabled")
        G_reader_settings:flush()
    end)

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
        footer = readerui.view.footer
        return footer
    end

    before_each(function()
        -- NOTE: Forcefully disable the statistics plugin, as lj-sqlite3 is horribly broken under Busted.
        G_reader_settings:saveSetting("plugins_disabled", { statistics = true })
        saved = {}
    end)

    after_each(function()
        restoreAll()
        if readerui then
            fastforward_ui_events()
            readerui:onClose()
            readerui = nil
            footer = nil
        end
        UIManager:quit()
        G_reader_settings:delSetting("reader_footer_mode")
        G_reader_settings:delSetting("twelve_hour_clock")
        G_reader_settings:delSetting("input_invert_page_turn_keys")
        purgeDir(DocSettings:getSidecarDir(sample_epub))
        os.remove(DocSettings:getHistoryPath(sample_epub))
        purgeDir(DocSettings:getSidecarDir(sample_pdf))
        os.remove(DocSettings:getHistoryPath(sample_pdf))
    end)

    describe("with a pdf document", function()
        before_each(function()
            openReader(sample_pdf)
        end)

        it("should show frontlight intensity, with a % on Kobo", function()
            local powerd = Device:getPowerDevice()
            override(powerd, "isFrontlightOn", function() return true end)
            override(powerd, "frontlightIntensity", function() return 42 end)
            assert.is.same("☼ 42", gen.frontlight(footer))
            footer.settings.item_prefix = "letters"
            assert.is.same("L: 42", gen.frontlight(footer))
            footer.settings.item_prefix = "compact_items"
            assert.is.same("✺ 42", gen.frontlight(footer))
            override(Device, "isKobo", function() return true end)
            assert.is.same("✺ 42%", gen.frontlight(footer))
        end)

        it("should show frontlight off unless hiding inactive items", function()
            local powerd = Device:getPowerDevice()
            override(powerd, "isFrontlightOn", function() return false end)
            assert.is.same("☼ Off", gen.frontlight(footer))
            assert.is.same("💡 Off", gen.frontlight_warmth(footer))
            -- hide_empty_generators only applies in all_at_once mode
            footer.settings.hide_empty_generators = true
            assert.is.same("☼ Off", gen.frontlight(footer))
            footer.settings.all_at_once = true
            assert.is.same("", gen.frontlight(footer))
            assert.is.same("", gen.frontlight_warmth(footer))
        end)

        it("should show frontlight warmth", function()
            local powerd = Device:getPowerDevice()
            override(powerd, "isFrontlightOn", function() return true end)
            override(powerd, "frontlightWarmth", function() return 30 end)
            assert.is.same("💡 30%", gen.frontlight_warmth(footer))
            footer.settings.item_prefix = "letters"
            assert.is.same("LW: 30%", gen.frontlight_warmth(footer))
            -- no warmth value: nothing
            powerd.frontlightWarmth = function() return nil end
            assert.is_nil(gen.frontlight_warmth(footer))
        end)

        it("should show battery level and charging state", function()
            local powerd = Device:getPowerDevice()
            override(powerd, "getCapacity", function() return 42 end)
            override(powerd, "isCharging", function() return true end)
            override(powerd, "isCharged", function() return false end)
            local charging_sym = powerd:getBatterySymbol(false, true, 42)
            assert.is.same(BD.wrap(charging_sym) .. "42%", gen.battery(footer))
            footer.settings.item_prefix = "compact_items"
            assert.is.same(BD.wrap(charging_sym), gen.battery(footer))
            footer.settings.item_prefix = "letters"
            assert.is.same("B: +42%", gen.battery(footer))
            powerd.isCharging = function() return false end
            assert.is.same("B: 42%", gen.battery(footer))
            footer.settings.item_prefix = "icons"
            assert.is.same(BD.wrap(powerd:getBatterySymbol(false, false, 42)) .. "42%", gen.battery(footer))
            assert.is_not.same(charging_sym, powerd:getBatterySymbol(false, false, 42))
        end)

        it("should hide battery above threshold in all_at_once mode only", function()
            local powerd = Device:getPowerDevice()
            override(powerd, "getCapacity", function() return 80 end)
            override(powerd, "isCharging", function() return false end)
            footer.settings.item_prefix = "letters"
            footer.settings.battery_hide_threshold = 50
            assert.is.same("B: 80%", gen.battery(footer))
            footer.settings.all_at_once = true
            assert.is.same("", gen.battery(footer))
            footer.settings.battery_hide_threshold = 80
            assert.is.same("B: 80%", gen.battery(footer))
        end)

        it("should sum main and aux battery levels", function()
            local powerd = Device:getPowerDevice()
            override(Device, "hasAuxBattery", function() return true end)
            override(powerd, "getCapacity", function() return 40 end)
            override(powerd, "isAuxBatteryConnected", function() return true end)
            override(powerd, "getAuxCapacity", function() return 30 end)
            override(powerd, "isAuxCharging", function() return true end)
            override(powerd, "isAuxCharged", function() return false end)
            -- main battery charging state is ignored when the aux battery is connected
            override(powerd, "isCharging", function() return false end)
            footer.settings.item_prefix = "letters"
            assert.is.same("B: +70%", gen.battery(footer))
            footer.settings.item_prefix = "icons"
            -- icon is computed from the average level
            assert.is.same(BD.wrap(powerd:getBatterySymbol(false, true, 35)) .. "70%", gen.battery(footer))
            -- aux disconnected
            powerd.isAuxBatteryConnected = function() return false end
            footer.settings.item_prefix = "letters"
            assert.is.same("B: 40%", gen.battery(footer))
        end)

        it("should show 0% without a battery", function()
            override(Device, "hasBattery", function() return false end)
            footer.settings.item_prefix = "letters"
            assert.is.same("B: 0%", gen.battery(footer))
        end)

        it("should show bookmark count", function()
            local n = 0
            override(readerui.annotation, "getNumberOfAnnotations", function() return n end)
            assert.is.same("\u{F097} 0", gen.bookmark_count(footer))
            footer.settings.all_at_once = true
            footer.settings.hide_empty_generators = true
            assert.is.same("", gen.bookmark_count(footer))
            n = 3
            footer.settings.item_prefix = "letters"
            assert.is.same("BM: 3", gen.bookmark_count(footer))
        end)

        it("should show time in 24h and 12h formats", function()
            local afternoon = os.time{ year = 2024, month = 1, day = 2, hour = 15, min = 7, sec = 30 }
            local morning = os.time{ year = 2024, month = 1, day = 2, hour = 9, min = 5, sec = 0 }
            local fixed = afternoon
            override(os, "time", function() return fixed end)
            assert.is.same("⌚ 15:07", gen.time(footer))
            G_reader_settings:makeTrue("twelve_hour_clock")
            assert.is.same("⌚ 3:07 PM", gen.time(footer))
            -- letters have no time prefix
            footer.settings.item_prefix = "letters"
            assert.is.same("3:07 PM", gen.time(footer))
            fixed = morning
            assert.is.same("9:05 AM", gen.time(footer))
            G_reader_settings:makeFalse("twelve_hour_clock")
            assert.is.same("09:05", gen.time(footer))
        end)

        it("should show page progress and pages left in book", function()
            footer.pageno, footer.pages = 1, 2
            assert.is.same("1 / 2", gen.page_progress(footer))
            assert.is.same("↣ 1 / 2", gen.pages_left_book(footer))
            footer.settings.pages_left_includes_current_page = true
            footer.settings.item_prefix = "letters"
            assert.is.same("-> 2 / 2", gen.pages_left_book(footer))
        end)

        it("should show page progress and pages left with page labels", function()
            override(readerui, "pagemap", {
                wantsPageLabels = function() return true end,
                getCurrentPageLabel = function() return "iv", 4, 10 end,
                getLastPageLabel = function() return "x" end,
                getPageLastLabel = function(_, page) return "L" .. page, 9 end,
            })
            footer.pageno, footer.pages = 1, 2
            assert.is.same("{iv / x} 1 / 2", gen.page_progress(footer))
            assert.is.same("↣ {6 / x}", gen.pages_left_book(footer))
            footer.settings.pages_left_includes_current_page = true
            assert.is.same("↣ {7 / x}", gen.pages_left_book(footer))
        end)

        it("should show page progress per flow with hidden flows", function()
            local doc = readerui.document
            local flow = 0
            override(doc, "hasHiddenFlows", function() return true end)
            override(doc, "getPageFlow", function() return flow end)
            override(doc, "getPageNumberInFlow", function() return 3 end)
            override(doc, "getTotalPagesInFlow", function() return 12 end)
            override(doc, "getLastLinearPage", function() return 5 end)
            override(doc, "getFirstPageInFlow", function() return 20 end)
            footer.percent_finished = 0.25
            footer.settings.item_prefix = "letters"
            -- main flow
            assert.is.same("3 // 12", gen.page_progress(footer))
            assert.is.same("-> 9 // 12", gen.pages_left_book(footer))
            assert.is.same("R: 25%", gen.percentage(footer))
            -- non-linear flow
            flow = 1
            assert.is.same("[3 / 12]1", gen.page_progress(footer))
            assert.is.same("-> [9 / 12]1", gen.pages_left_book(footer))
            assert.is.same("R: [25%]", gen.percentage(footer))
            -- with page labels
            override(readerui, "pagemap", {
                wantsPageLabels = function() return true end,
                getCurrentPageLabel = function() return "iv", 4, 10 end,
                getPageLastLabel = function(_, page) return "L" .. page, 9 end,
            })
            assert.is.same("{iv / L31} [3 / 12]1", gen.page_progress(footer))
            assert.is.same("-> {[5 / 9]1}", gen.pages_left_book(footer))
            flow = 0
            assert.is.same("{iv / L5} 3 // 12", gen.page_progress(footer))
            footer.settings.pages_left_includes_current_page = true
            assert.is.same("-> {6 / 9}", gen.pages_left_book(footer))
        end)

        it("should count pages left in chapter or book", function()
            override(readerui.toc, "getChapterPagesLeft", function() return nil end)
            override(readerui.document, "getTotalPagesLeft", function() return 7 end)
            assert.is.same("⇒ 7", gen.pages_left(footer))
            footer.settings.pages_left_includes_current_page = true
            assert.is.same("⇒ 8", gen.pages_left(footer))
            readerui.toc.getChapterPagesLeft = function() return 2 end
            footer.settings.item_prefix = "letters"
            assert.is.same("=> 3", gen.pages_left(footer))
            footer.settings.item_prefix = "compact_items"
            assert.is.same("› 3", gen.pages_left(footer))
        end)

        it("should format percentage with the configured digits", function()
            footer.percent_finished = 1 / 3
            assert.is.same("⤠ 33%", gen.percentage(footer))
            footer.settings.progress_pct_format = "1"
            assert.is.same("⤠ 33.3%", gen.percentage(footer))
            footer.settings.progress_pct_format = "2"
            footer.settings.item_prefix = "compact_items"
            -- no prefix in compact mode
            assert.is.same("33.33%", gen.percentage(footer))
        end)

        it("should estimate time to read with statistics", function()
            override(readerui, "statistics", {
                getTimeForPages = function(_, pages) return pages .. "m" end,
            })
            override(readerui.document, "getTotalPagesLeft", function() return 6 end)
            override(readerui.toc, "getChapterPagesLeft", function() return 2 end)
            assert.is.same("⏳ 6m", gen.book_time_to_read(footer))
            assert.is.same("⤻ 2m", gen.chapter_time_to_read(footer))
            footer.settings.item_prefix = "letters"
            assert.is.same("TB: 6m", gen.book_time_to_read(footer))
            assert.is.same("TC: 2m", gen.chapter_time_to_read(footer))
            footer.settings.item_prefix = "compact_items"
            assert.is.same("6m", gen.book_time_to_read(footer))
            assert.is.same("» 2m", gen.chapter_time_to_read(footer))
            -- not in a chapter: book pages left
            readerui.toc.getChapterPagesLeft = function() return nil end
            assert.is.same("» 6m", gen.chapter_time_to_read(footer))
        end)

        it("should show memory usage in MiB", function()
            footer.settings.item_prefix = "letters"
            local text = gen.mem_usage(footer)
            local mib = tonumber(text:match("^M: (%d+)$"))
            assert.truthy(mib)
            assert.is_true(mib > 0)
            -- /proc unavailable
            local orig_open = io.open
            io.open = function() return nil end -- luacheck: ignore
            local ok, res = pcall(gen.mem_usage, footer)
            io.open = orig_open -- luacheck: ignore
            assert.is_true(ok)
            assert.is.same("", res)
        end)

        it("should show wifi status", function()
            local on = true
            override(NetworkMgr, "isWifiOn", function() return on end)
            footer.settings.item_prefix = "letters"
            assert.is.same("W: On", gen.wifi_status(footer))
            on = false
            assert.is.same("W: Off", gen.wifi_status(footer))
            footer.settings.item_prefix = "icons"
            local icon_off = gen.wifi_status(footer)
            on = true
            local icon_on = gen.wifi_status(footer)
            assert.truthy(icon_on ~= "" and icon_off ~= "")
            assert.is_not.same(icon_on, icon_off)
            -- compact uses the same icons
            footer.settings.item_prefix = "compact_items"
            assert.is.same(icon_on, gen.wifi_status(footer))
            on = false
            assert.is.same(icon_off, gen.wifi_status(footer))
            footer.settings.all_at_once = true
            footer.settings.hide_empty_generators = true
            assert.is.same("", gen.wifi_status(footer))
            footer.settings.item_prefix = "letters"
            assert.is.same("", gen.wifi_status(footer))
        end)

        it("should show page turning inversion", function()
            footer.settings.item_prefix = "letters"
            assert.is.same("Pg: Off", gen.page_turning_inverted(footer))
            footer.settings.item_prefix = "icons"
            assert.is.same("⇉", gen.page_turning_inverted(footer))
            G_reader_settings:makeTrue("input_invert_page_turn_keys")
            assert.is.same("⇄", gen.page_turning_inverted(footer))
            footer.settings.item_prefix = "letters"
            assert.is.same("Pg: On", gen.page_turning_inverted(footer))
            G_reader_settings:delSetting("input_invert_page_turn_keys")
            override(readerui.view, "inverse_reading_order", true)
            assert.is.same("Pg: On", gen.page_turning_inverted(footer))
            readerui.view.inverse_reading_order = false
            footer.settings.all_at_once = true
            footer.settings.hide_empty_generators = true
            assert.is.same("", gen.page_turning_inverted(footer))
        end)

        it("should fit title, author and chapter to their max width", function()
            override(readerui.doc_props, "authors", "Jane Doe")
            override(readerui.doc_props, "display_title", string.rep("Very long title ", 20))
            override(readerui.toc, "getTocTitleByPage", function() return "Chapter One" end)
            assert.is.same(BD.auto("Jane\u{00A0}Doe"), gen.book_author(footer))
            assert.is.same(BD.auto("Chapter\u{00A0}One"), gen.book_chapter(footer))
            local title = gen.book_title(footer)
            assert.truthy(title:find("…", 1, true))
            assert.is_true(footer:getTextWidth(title) <= Screen:getWidth() * 0.3 + footer:getTextWidth("…"))
            -- a larger max width fits more text
            footer.settings.book_title_max_width_pct = 90
            assert.is_true(#gen.book_title(footer) > #title)
            readerui.doc_props.authors = nil
            assert.is.same("", gen.book_author(footer))
            readerui.toc.getTocTitleByPage = function() return "" end
            assert.is.same("", gen.book_chapter(footer))
        end)

        it("should repeat custom text and merge blank text", function()
            footer.custom_text = "ab"
            footer.custom_text_repetitions = 3
            local text, merge = gen.custom_text(footer)
            assert.is.same("ababab", text)
            assert.is_false(merge)
            footer.custom_text = "   "
            footer.custom_text_repetitions = 1
            text, merge = gen.custom_text(footer)
            assert.is.same("   ", text)
            assert.is_true(merge)
        end)

        it("should only enable dynamic fillers without an alongside progress bar", function()
            local text, merge, enabled = gen.dynamic_filler(footer)
            assert.is_nil(text)
            -- a disabled filler doesn't ask for merging (it would eat its neighbours' separators)
            assert.is_false(merge)
            assert.is_false(enabled)
            footer.settings.progress_bar_position = "below"
            assert.is_true(select(3, gen.dynamic_filler2(footer)))
            footer.settings.progress_bar_position = "alongside"
            footer.settings.disable_progress_bar = true
            assert.is_true(select(3, gen.dynamic_filler(footer)))
        end)

        it("should generate the separator for each style", function()
            assert.is.same(" | ", footer:genSeparator())
            footer.settings.items_separator = "bullet"
            assert.is.same(" • ", footer:genSeparator())
            footer.settings.items_separator = "dot"
            assert.is.same(" · ", footer:genSeparator())
            footer.settings.items_separator = "none"
            assert.is.same("  ", footer:genSeparator())
            footer.settings.item_prefix = "compact_items"
            assert.is.same(" ", footer:genSeparator())
        end)

        it("should title options according to the symbol type", function()
            assert.is.same("Current time (⌚)", footer:textOptionTitles("time"))
            footer.settings.item_prefix = "letters"
            assert.is.same("Current time", footer:textOptionTitles("time"))
            assert.is.same("Battery percentage (B:)", footer:textOptionTitles("battery"))
            assert.is.same("Time left to finish book (TB:)", footer:textOptionTitles("book_time_to_read"))
            footer.settings.item_prefix = "compact_items"
            assert.is.same("Progress percentage", footer:textOptionTitles("percentage"))
            assert.is.same("Time left to finish book", footer:textOptionTitles("book_time_to_read"))
            assert.is.same("Dynamic filler 1", footer:textOptionTitles("dynamic_filler"))
            assert.is.same("External content", footer:textOptionTitles("additional_content"))
        end)
    end)

    describe("all items at once", function()
        local function g(text) return function() return text end end
        local function merged(text) return function() return text, true end end
        local filler = function() return nil, true, true end

        before_each(function()
            openReader(sample_pdf, { all_at_once = true, disable_progress_bar = true })
            footer.settings.item_prefix = "letters"
        end)

        it("should skip empty items and merge blank custom text", function()
            footer.footerTextGenerators = { g("A"), g(""), g("B"), merged("  "), g("C"), g(nil) }
            assert.is.same("A | B  C", footer:genAllFooterText())
            footer.footerTextGenerators = { merged("<"), g("A"), merged(">") }
            assert.is.same("<A>", footer:genAllFooterText())
        end)

        it("should replace whitespace with hair spaces in compact mode", function()
            footer.settings.item_prefix = "compact_items"
            footer.footerTextGenerators = { g("a b"), g("c") }
            assert.is.same("a\u{200A}b | c", footer:genAllFooterText())
            footer.settings.items_separator = "none"
            assert.is.same("a\u{200A}b c", footer:genAllFooterText())
        end)

        it("should fill the line with a single dynamic filler", function()
            footer.footerTextGenerators = { g("A"), filler, g("B") }
            local text = footer:genAllFooterText()
            local spaces = text:match("^A( +)B$")
            assert.truthy(spaces)
            local max_width = math.floor(Screen:getWidth() - 2 * footer.horizontal_margin)
            local space_w = footer:getTextWidth(" ")
            local expected_nb = math.floor((max_width - footer:getTextWidth("AB")) / space_w)
            assert.is.same(expected_nb, #spaces)
            assert.is.same(space_w, footer.filler_space_width)
            -- a filler alone is dropped
            footer.footerTextGenerators = { filler }
            assert.is.same("", footer:genAllFooterText())
        end)

        it("should center text between two dynamic fillers", function()
            footer.footerTextGenerators = { g("L"), filler, g("Mid"), filler, g("R") }
            local text = footer:genAllFooterText()
            local s1, s2 = text:match("^L( +)Mid( +)R$")
            assert.truthy(s1)
            -- L and R have similar widths, so the middle text is roughly centered
            assert.is_true(math.abs(#s1 - #s2) <= 1)
            -- adjacent fillers are combined into one
            footer.footerTextGenerators = { g("L"), filler, filler, g("R") }
            assert.truthy(footer:genAllFooterText():match("^L +R$"))
        end)

        it("should fall back to separators when the text doesn't fit", function()
            local long = string.rep("x", 200)
            footer.footerTextGenerators = { g("A"), filler, g(long) }
            assert.is.same("A | " .. long, footer:genAllFooterText())
            -- a leading filler has no separator to fall back to
            footer.footerTextGenerators = { filler, g(long) }
            assert.is.same(long, footer:genAllFooterText())
        end)

        it("should replace the first filler when the left part is too long", function()
            local max_width = math.floor(Screen:getWidth() - 2 * footer.horizontal_margin)
            local left = "L"
            while footer:getTextWidth(left) < max_width * 0.6 do left = left .. "L" end
            footer.footerTextGenerators = { g(left), filler, g("M"), filler, g("R") }
            local text = footer:genAllFooterText()
            assert.truthy(text:match("^" .. left .. " | M +R$"))
            -- the remaining space all goes to the second filler
            local spaces = text:match("M( +)R$")
            local space_w = footer:getTextWidth(" ")
            local expected_nb = math.floor((max_width - footer:getTextWidth(left .. " | MR")) / space_w)
            assert.is.same(expected_nb, #spaces)
        end)
    end)

    describe("layout", function()
        it("should follow book margins for the progress bar at startup", function()
            openReader(sample_epub, { progress_margin = true, progress_margin_width = 1 }) -- unscaled_size_check: ignore
            local h = readerui.document.configurable.h_page_margins
            assert.is.same(math.floor((h[1] + h[2]) / 2), footer.settings.progress_margin_width)
        end)

        it("should use default margins for paged documents", function()
            openReader(sample_pdf, { progress_margin = true, progress_margin_width = 1 }) -- unscaled_size_check: ignore
            assert.is.same(ReaderFooter.default_settings.progress_margin_width, footer.settings.progress_margin_width)
        end)

        it("should use positions as markers in scroll mode", function()
            openReader(sample_epub)
            readerui.view.view_mode = "scroll"
            footer:setTocMarkers(true)
            local ticks = footer.progress_bar.ticks
            assert.is_true(#ticks > 1)
            for i = 2, #ticks do
                assert.is_true(ticks[i] >= ticks[i - 1])
            end
            assert.is.same(readerui.document.info.doc_height, footer.progress_bar.last)
            assert.is_true(ticks[#ticks] <= footer.progress_bar.last)
            readerui.view.view_mode = "page"
        end)

        it("should fall back to the default font and thin bar at init", function()
            openReader(sample_pdf, { text_font_face = "/nonexistent/font.ttf", progress_style_thin = true })
            assert.is.same(ReaderFooter.default_settings.text_font_face, footer.settings.text_font_face)
            -- thin bar: no chapter markers
            assert.is_nil(footer.progress_bar.ticks)
        end)

        it("should hide text height with no items and a bar above", function()
            local items_off = { all_at_once = true, progress_bar_position = "above" }
            for _, m in ipairs({"page_progress", "time", "pages_left", "battery", "percentage",
                                "book_time_to_read", "chapter_time_to_read"}) do
                items_off[m] = false
            end
            openReader(sample_pdf, items_off, 1)
            assert.is_true(footer.has_no_mode)
            assert.is.same(0, footer.footer_text.height)
            assert.is_true(readerui.view.footer_visible)
        end)

        it("should request a refresh of the footer area only when visible", function()
            openReader(sample_pdf)
            local dirty = {}
            override(UIManager, "setDirty", function(_, widget, fn) table.insert(dirty, { widget, fn }) end)
            override(UIManager, "widgetRepaint", function() end)
            footer.footer_content.dimen = require("ui/geometry"):new{ x = 0, y = 780, w = 600, h = 20 }
            footer:onUpdateFooter(true)
            assert.is.same(1, #dirty)
            assert.is_nil(dirty[1][1])
            local mode, region = dirty[1][2]()
            assert.is.same("ui", mode)
            assert.is.same(footer.footer_content.dimen, region)
            -- a full repaint involves the ReaderUI dialog
            dirty = {}
            footer:onUpdateFooter(true, true)
            assert.is.same(readerui.view.dialog, dirty[1][1])
            readerui.view.currently_scrolling = true
            mode = dirty[1][2]()
            assert.is.same("fast", mode)
            readerui.view.currently_scrolling = false
        end)
    end)
end)
