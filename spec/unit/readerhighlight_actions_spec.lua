describe("ReaderHighlight actions (EPUB)", function()
    local Blitbuffer, DataStorage, Device, DocSettings, DocumentRegistry, Geom, LuaSettings
    local ReaderUI, Screen, Translator, UIManager
    local sample_epub
    local readerui, hl

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
    local function find_button(rows, text)
        for _, row in ipairs(rows) do
            for _, button in ipairs(row) do
                if button.text == text then return button end
            end
        end
    end
    local shown, tasks
    local function last_shown()
        return shown[#shown]
    end
    -- touchmenu stand-in
    local function fake_touchmenu()
        local tm = { updated = 0 }
        function tm:updateItems() self.updated = self.updated + 1 end
        return tm
    end

    local WORD = { x = 400, y = 70 } -- "thy"
    local TEXT0, TEXT1 = { x = 400, y = 110 }, { x = 400, y = 170 } -- "Montagues.\nSAMPSON"
    local LATER0, LATER1 = { x = 106, y = 271 }, { x = 370, y = 314 } -- "GREGORY\nHow! turn thy back and run?"

    -- (fresh tables: ReaderHighlight keeps and may adjust the gesture positions)
    local function at(pos)
        return Geom:new({ x = pos.x, y = pos.y })
    end
    local function hold(pos)
        return hl:onHold(nil, { pos = at(pos) })
    end
    local function select_text(p0, p1)
        hold(p0)
        hl:onHoldPan(nil, { pos = at(p1) })
    end
    local function save_text(p0, p1)
        select_text(p0, p1)
        local index = hl:saveHighlight()
        hl:clear()
        return index
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        Blitbuffer = require("ffi/blitbuffer")
        DataStorage = require("datastorage")
        Device = require("device")
        DocSettings = require("docsettings")
        DocumentRegistry = require("document/documentregistry")
        Geom = require("ui/geometry")
        LuaSettings = require("luasettings")
        ReaderUI = require("apps/reader/readerui")
        Screen = Device.screen
        Translator = require("ui/translator")
        UIManager = require("ui/uimanager")
        sample_epub = DataStorage:getDataDir() .. "/readerhighlight_actions.epub"
        require("ffi/util").copyFile("spec/front/unit/data/juliet.epub", sample_epub)
        DocSettings:open(sample_epub):purge()
        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(sample_epub),
        }
        hl = readerui.highlight
    end)

    teardown(function()
        readerui:onClose()
        UIManager:quit()
    end)

    before_each(function()
        shown = {}
        override(UIManager, "show", function(_, w) table.insert(shown, w) end)
        tasks = {}
        override(UIManager, "scheduleIn", function(_, delay, fn, ...)
            table.insert(tasks, { delay = delay, fn = fn, args = { ... } })
        end)
        readerui.rolling:onGotoPage(10)
    end)

    after_each(function()
        hl:onClose()
        hl.select_mode = false
        hl.highlight_idx = nil
        hl.long_hold_reached = false
        hl.selected_link = nil
        hl.selected_text_backup = nil
        readerui.annotation.annotations = {}
        for _, k in ipairs({ "default_highlight_action", "highlight_action_on_single_word", "highlight_prompt",
                             "highlight_dialog_position", "bookmark_full_chapter", "highlight_drawing_style",
                             "highlight_color", "highlight_lighten_factor", "highlight_selection_lighten_factor",
                             "highlight_selection_invert_highlight_color", "highlight_selection_use_highlight_color",
                             "highlight_height_pct", "highlight_note_marker", "highlight_long_hold_threshold_s",
                             "highlight_corner_scroll" }) do
            G_reader_settings:delSetting(k)
        end
        hl.view.highlight.disabled = false
        hl.view.highlight.saved_drawer = "lighten"
        hl.view.highlight.note_mark = nil
        restore_all()
    end)

    describe("colors", function()
        after_each(function()
            hl.custom_colors.red = nil
            Screen.night_mode = false
        end)

        it("should name, code and invert highlight colors", function()
            assert.are.equal("Red", hl:getHighlightColorString("red"))
            assert.are.equal("Gray", hl:getHighlightColorString("gray"))
            assert.are.equal("mauve", hl:getHighlightColorString("mauve"))
            assert.are.equal(Blitbuffer.HIGHLIGHT_COLORS.red, hl:getHighlightColorCode("red"))
            hl.custom_colors.red = { name = "Crimson", code = "#a00000" }
            assert.are.equal("Crimson", hl:getHighlightColorString("red"))
            assert.are.equal("Red", hl:getHighlightColorString("red", true))
            assert.are.equal("#a00000", hl:getHighlightColorCode("red"))
            assert.are.equal(Blitbuffer.HIGHLIGHT_COLORS.red, hl:getHighlightColorCode("red", true))
            Screen.night_mode = true
            assert.are.equal("#5fffff", hl:getHighlightColorCode("red", nil, true))
            assert.are.equal("#a00000", hl:getHighlightColorCode("red", nil, false))
            local c = hl:getHighlightColor("red")
            assert.are.equal(0xa0, c.r)
            local list = hl:getHighlightColorList()
            assert.are.equal(#hl.highlight_colors, #list)
            assert.are.equal("Crimson", list[1][1])
            assert.are.equal("red", list[1][2])
            assert.are.equal("Orange", list[2][1])
        end)

        it("should use the lighten factor for gray and unknown colors", function()
            G_reader_settings:saveSetting("highlight_lighten_factor", 0.5)
            assert.are.equal(Blitbuffer.gray(0.5).a, hl:getHighlightColor("gray").a)
            assert.are.equal(Blitbuffer.gray(0.5).a, hl:getHighlightColor("mauve").a)
            G_reader_settings:delSetting("highlight_lighten_factor")
            assert.are.equal(Blitbuffer.gray(0.2).a, hl:getHighlightColor("gray").a)
        end)

        it("should push the selection color to crengine", function()
            local props = {}
            local real = hl.document._document
            hl.document._document = { setStringProperty = function(_, k, v) props[k] = v end }
            finally(function() hl.document._document = real end)
            local key = "crengine.highlight.selection.color"
            hl:setSelectionColor()
            assert.are.equal("#CCCCCC", props[key])
            G_reader_settings:saveSetting("highlight_selection_lighten_factor", 0)
            hl:setSelectionColor()
            assert.are.equal("#FFFFFF", props[key])
            G_reader_settings:saveSetting("highlight_selection_lighten_factor", 1)
            hl:setSelectionColor()
            assert.are.equal("#000000", props[key])
            G_reader_settings:makeTrue("highlight_selection_use_highlight_color")
            hl.view.highlight.saved_color = "red"
            hl:setSelectionColor()
            assert.are.equal(Blitbuffer.HIGHLIGHT_COLORS.red, props[key])
            -- not with the invert drawer
            hl.view.highlight.saved_drawer = "invert"
            hl:setSelectionColor()
            assert.are.equal("#000000", props[key])
            hl.view.highlight.saved_color = "yellow"
        end)
    end)

    describe("hold and release", function()
        it("should look up a single held word in the dictionary", function()
            local looked_up
            override(readerui.dictionary, "onLookupWord", function(_, word, is_sane, boxes, highlight)
                looked_up = { word = word, boxes = boxes, highlight = highlight }
            end)
            assert.is_true(hold(WORD))
            assert.is_true(hl.is_word_selection)
            assert.are.equal("thy", hl.selected_text.text)
            assert.truthy(hl.selected_text_start_xpointer)
            assert.is_true(hl:onHoldRelease())
            assert.are.equal("thy", looked_up.word)
            assert.are.equal(1, #looked_up.boxes)
            assert.are.equal(hl, looked_up.highlight)
            assert.is_nil(hl.highlight_dialog)
            assert.are.equal(0, #readerui.annotation.annotations)
            -- clear() reports that something was cleared, only once
            assert.is_true(hl:clear())
            assert.is_nil(hl:clear())
            assert.is_nil(hl.hold_pos)
            assert.is_nil(hl.selected_text)
        end)

        it("should show the highlight menu for a single word when asked to", function()
            G_reader_settings:makeTrue("highlight_action_on_single_word")
            hold(WORD)
            hl:onHoldRelease()
            assert.truthy(hl.highlight_dialog)
            assert.are.equal(hl.highlight_dialog, last_shown())
            local rows = hl.highlight_dialog.buttons
            for _, text in ipairs({ "Select", "Highlight", "Copy", "Add note", "Wikipedia",
                                    "Dictionary", "Translate", "View HTML", "Search" }) do
                assert.truthy(find_button(rows, text), text)
            end
            assert.is_nil(find_button(rows, "Follow Link"))
            -- two buttons per row
            for _, row in ipairs(rows) do
                assert.truthy(#row <= 2)
            end
            -- tapping outside clears the selection
            hl.highlight_dialog.tap_close_callback()
            assert.is_nil(hl.hold_pos)
        end)

        it("should do nothing on release without a selection", function()
            -- holding on blank space: no word found
            override(readerui.document, "getWordFromPosition", function() return nil end)
            assert.is_false(hold({ x = 2, y = 2 }))
            assert.is_nil(hl.hold_pos)
            assert.is_true(hl:onHoldRelease())
            assert.is_nil(hl.highlight_dialog)
            assert.are.equal(0, #shown)
            assert.are.equal(0, #readerui.annotation.annotations)
            -- pan without a previous hold is ignored
            assert.is_true(hl:onHoldPan(nil, { pos = at(TEXT1) }))
            assert.is_nil(hl.selected_text)
        end)

        it("should ignore hold and pan when long-press action is 'nothing'", function()
            hl:onSetHighlightAction(2, true)
            assert.is_true(hl.view.highlight.disabled)
            assert.are.equal("nothing", G_reader_settings:readSetting("default_highlight_action"))
            assert.is_false(hold(WORD))
            assert.is_nil(hl.hold_pos)
            assert.is_false(hl:onHoldPan(nil, { pos = at(TEXT1) }))
        end)

        it("should ignore a release while a delayed clear is pending", function()
            select_text(TEXT0, TEXT1)
            local id = hl:getClearId()
            assert.is_true(hl:onHoldRelease())
            assert.is_nil(hl.highlight_dialog)
            -- a stale id does not clear a newer selection
            hl.clear_id = id + 1
            assert.is_nil(hl:clear(id))
            assert.truthy(hl.selected_text)
            assert.is_true(hl:clear(id + 1))
            assert.is_nil(hl.selected_text)
        end)

        it("should not clear anything once the document is gone", function()
            select_text(TEXT0, TEXT1)
            local doc = readerui.document
            readerui.document = nil
            local ok = hl:clear()
            readerui.document = doc
            assert.is_nil(ok)
            assert.truthy(hl.hold_pos)
        end)

        it("should select text across words with hold and pan", function()
            select_text(TEXT0, TEXT1)
            assert.is_false(hl.is_word_selection)
            assert.are.equal("Montagues.\nSAMPSON", hl.selected_text.text)
            -- same pan again: no change, nothing to redo
            assert.is_nil(hl:onHoldPan(nil, { pos = at(TEXT1) }))
            hl:onHoldRelease()
            assert.truthy(hl.highlight_dialog)
            assert.are.equal(0, #readerui.annotation.annotations)
        end)

        it("should open an image viewer when holding on an image", function()
            local stopped = 0
            override(readerui.keyselection, "stopHighlightIndicator", function() stopped = stopped + 1 end)
            readerui.rolling:onGotoPage(1)
            assert.is_true(hold({ x = 300, y = 400 }))
            assert.is_nil(hl.hold_pos)
            assert.are.equal(1, #shown)
            assert.truthy(last_shown().image)
            assert.are.equal(1, stopped)
        end)

        it("should arm and fire the very-long-press timer", function()
            G_reader_settings:saveSetting("default_highlight_action", "highlight")
            select_text(TEXT0, TEXT1)
            local timer
            for _, t in ipairs(tasks) do
                if t.fn == hl.long_hold_reached_action then timer = t end
            end
            assert.truthy(timer)
            G_reader_settings:saveSetting("highlight_long_hold_threshold_s", 7)
            hl:onHoldPan(nil, { pos = at(TEXT0) })
            assert.are.equal(7, tasks[#tasks].delay)
            tasks[#tasks].fn()
            assert.is_true(hl.long_hold_reached)
            -- releasing after a very-long-press shows the menu instead of highlighting
            hl:onHoldRelease()
            assert.truthy(hl.highlight_dialog)
            assert.are.equal(0, #readerui.annotation.annotations)
            assert.is_false(hl.long_hold_reached)
        end)

        it("should not arm the timer when it would not change anything", function()
            -- a single word hold arms it (long-press would show the menu)
            hold(TEXT0)
            assert.are.equal(hl.long_hold_reached_action, tasks[#tasks].fn)
            -- "ask" for multi-words: nothing to arm
            tasks = {}
            hl:onHoldPan(nil, { pos = at(TEXT1) })
            for _, t in ipairs(tasks) do
                assert.are_not.equal(hl.long_hold_reached_action, t.fn)
            end
            hl:clear()
            -- single word with highlight action on single word and "ask"
            G_reader_settings:makeTrue("highlight_action_on_single_word")
            tasks = {}
            hold(WORD)
            for _, t in ipairs(tasks) do
                assert.are_not.equal(hl.long_hold_reached_action, t.fn)
            end
            hl:clear()
            -- disabled by key selection
            G_reader_settings:saveSetting("default_highlight_action", "highlight")
            hl:disableLongHoldReachedAction()
            assert.is_true(hl.long_hold_disabled)
            tasks = {}
            select_text(TEXT0, TEXT1)
            for _, t in ipairs(tasks) do
                assert.are_not.equal(hl.long_hold_reached_action, t.fn)
            end
            hl:restoreLongHoldReachedAction()
            assert.is_false(hl.long_hold_disabled)
            hl:setLongHoldReached(true)
            assert.is_true(hl.long_hold_reached)
            hl:setLongHoldReached(false)
        end)
    end)

    describe("default long-press actions", function()
        it("should highlight directly with 'highlight'", function()
            G_reader_settings:saveSetting("default_highlight_action", "highlight")
            local names = record_events(readerui)
            select_text(TEXT0, TEXT1)
            hl:onHoldRelease()
            assert.are.equal(1, #readerui.annotation.annotations)
            local item = readerui.annotation.annotations[1]
            assert.truthy(item.text:find("SAMPSON", 1, true))
            assert.are.equal("lighten", item.drawer)
            assert.truthy(item.epubcfi:match("^epubcfi%("))
            assert.truthy(item.chapter)
            assert.are.equal(1, count(names, "AnnotationsModified"))
            assert.is_nil(hl.hold_pos)
        end)

        it("should add a note with 'note'", function()
            G_reader_settings:saveSetting("default_highlight_action", "note")
            local note_args
            override(readerui.bookmark, "setBookmarkNote", function(_, index, is_new, text, cb)
                note_args = { index = index, is_new = is_new, text = text, cb = cb }
            end)
            select_text(TEXT0, TEXT1)
            hl:onHoldRelease()
            assert.are.equal(1, #readerui.annotation.annotations)
            assert.are.equal(1, note_args.index)
            assert.is_true(note_args.is_new)
            assert.is_nil(hl.selected_text)
            -- the note callback refreshes the note marker
            hl.view.highlight.note_mark = "sideline"
            note_args.cb()
        end)

        it("should save a translation into a note", function()
            override(readerui.bookmark, "setBookmarkNote", function(_, index, is_new, text)
                assert.are.equal(1, index)
                assert.is_true(is_new)
                assert.are.equal("translated", text)
            end)
            select_text(TEXT0, TEXT1)
            hl:addNote("translated")
            assert.are.equal(1, #readerui.annotation.annotations)
            assert.is_nil(hl.hold_pos)
        end)

        it("should translate with 'translate', backing up the selection", function()
            G_reader_settings:saveSetting("default_highlight_action", "translate")
            local translated
            override(Translator, "showTranslation", function(_, text, detailed, src, tgt, ui_hl)
                translated = { text = text, detailed = detailed, hl = ui_hl }
            end)
            select_text(TEXT0, TEXT1)
            hl:onHoldRelease()
            assert.truthy(translated.text:find("SAMPSON", 1, true))
            assert.is_true(translated.detailed)
            assert.are.equal(hl, translated.hl)
            assert.truthy(hl.selected_text_backup)
            assert.is_nil(hl.selected_text)
        end)

        it("should look up Wikipedia with 'wikipedia'", function()
            G_reader_settings:saveSetting("default_highlight_action", "wikipedia")
            local word
            override(readerui.wikipedia, "onLookupWikipedia", function(_, w) word = w return true end)
            select_text(TEXT0, TEXT1)
            hl:onHoldRelease()
            assert.are.equal("Montagues.\nSAMPSON", word)
            assert.is_nil(hl.selected_text)
        end)

        it("should look up the dictionary with 'dictionary'", function()
            G_reader_settings:saveSetting("default_highlight_action", "dictionary")
            local looked_up
            override(readerui.dictionary, "onLookupWord", function(_, w, _sane, boxes)
                looked_up = { w, boxes }
            end)
            select_text(TEXT0, TEXT1)
            hl:onHoldRelease()
            assert.are.equal("Montagues.\nSAMPSON", looked_up[1])
            assert.truthy(#looked_up[2] >= 1)
        end)

        it("should search with 'search', keeping the selection", function()
            G_reader_settings:saveSetting("default_highlight_action", "search")
            local searched
            override(readerui.search, "searchText", function(_, text) searched = text end)
            select_text(TEXT0, TEXT1)
            hl:onHoldRelease()
            assert.are.equal("Montagues.\nSAMPSON", searched)
            assert.truthy(hl.selected_text)
        end)

        it("should start then extend a selection with 'select'", function()
            G_reader_settings:saveSetting("default_highlight_action", "select")
            select_text(TEXT0, TEXT1)
            hl:onHoldRelease()
            assert.is_true(hl.select_mode)
            assert.are.equal(1, #readerui.annotation.annotations)
            local first = readerui.annotation.annotations[1]
            assert.is_true(first.is_tmp)
            local pos0 = first.pos0
            -- end fragment
            select_text(LATER0, LATER1)
            hl:onHoldRelease()
            assert.is_false(hl.select_mode)
            assert.are.equal(1, #readerui.annotation.annotations)
            local item = readerui.annotation.annotations[1]
            assert.is_nil(item.is_tmp)
            assert.are.equal(pos0, item.pos0)
            assert.truthy(item.text:find("Montagues", 1, true))
            assert.truthy(item.text:find("run?", 1, true))
        end)

        it("should cycle the default action and highlight style", function()
            local nums, texts = hl:getHighlightActions()
            assert.are.equal(9, #nums)
            assert.are.equal("Ask with popup dialog", texts[1])
            hl:onCycleHighlightAction()
            assert.are.equal("nothing", G_reader_settings:readSetting("default_highlight_action"))
            assert.is_true(hl.view.highlight.disabled)
            assert.truthy(last_shown().text:find("Do nothing", 1, true))
            G_reader_settings:saveSetting("default_highlight_action", "search")
            hl:onCycleHighlightAction()
            assert.are.equal("ask", G_reader_settings:readSetting("default_highlight_action"))
            assert.is_false(hl.view.highlight.disabled)
            hl.view.highlight.saved_drawer = "lighten"
            hl:onCycleHighlightStyle()
            assert.are.equal("underscore", hl.view.highlight.saved_drawer)
            hl.view.highlight.saved_drawer = "invert"
            hl:onCycleHighlightStyle()
            assert.are.equal("lighten", hl.view.highlight.saved_drawer)
            assert.are.equal("Invert", hl:getHighlightStyleString("invert"))
            assert.is_nil(hl:getHighlightStyleString("blink"))
            assert.are.equal(4, #hl.getHighlightStyles())
        end)
    end)

    describe("highlight menu buttons", function()
        local function button(id, index)
            return hl._highlight_buttons[id](hl, index)
        end

        it("should copy the selection to the clipboard", function()
            local copied
            override(Device.input, "setClipboardText", function(text) copied = text end)
            select_text(TEXT0, TEXT1)
            local b = button("03_copy")
            assert.are.equal(Device:hasClipboard(), b.enabled)
            b.callback()
            assert.are.equal("Montagues.\nSAMPSON", copied)
            assert.truthy(last_shown().text:find("copied", 1, true))
            -- the highlight is kept until the delayed clear
            assert.truthy(hl.selected_text)
            tasks[#tasks].fn()
            assert.is_nil(hl.selected_text)
        end)

        it("should highlight and add note from the menu", function()
            select_text(TEXT0, TEXT1)
            assert.is_true(button("02_highlight").enabled)
            button("02_highlight").callback()
            assert.are.equal(1, #readerui.annotation.annotations)
            local noted
            override(readerui.bookmark, "setBookmarkNote", function(_, index) noted = index end)
            select_text(LATER0, LATER1)
            assert.is_true(button("04_add_note").enabled)
            button("04_add_note").callback()
            assert.are.equal(2, #readerui.annotation.annotations)
            assert.are.equal(2, noted)
            -- without a hold position, these are disabled
            assert.is_false(button("02_highlight").enabled)
        end)

        it("should select or extend from the menu", function()
            local index = save_text(TEXT0, TEXT1)
            select_text(LATER0, LATER1)
            local b = button("01_select")
            assert.are.equal("Select", b.text)
            b.callback()
            assert.is_true(hl.select_mode)
            assert.are.equal(2, #readerui.annotation.annotations)
            hl.select_mode = false
            b = button("01_select", index)
            assert.are.equal("Extend", b.text)
            assert.is_true(b.enabled)
            readerui.annotation.annotations[index].text_edited = true
            assert.is_false(button("01_select", index).enabled)
            readerui.annotation.annotations[index].text_edited = nil
            b.callback()
            assert.is_true(hl.select_mode)
            assert.are.equal(index, hl.highlight_idx)
        end)

        it("should run lookups from the menu", function()
            select_text(TEXT0, TEXT1)
            local dict, dict_lookup, wiki, search, fulltext, translated
            override(readerui.dictionary, "onLookupWord", function(_, w) dict = w end)
            override(readerui.dictionary, "onShowDictionaryLookup", function(_, w) dict_lookup = w end)
            override(readerui.wikipedia, "onLookupWikipedia", function(_, w) wiki = w return true end)
            override(readerui.search, "searchText", function(_, w) search = w end)
            override(readerui.search, "onShowFulltextSearchInput", function(_, w) fulltext = w end)
            override(Translator, "showTranslation", function(_, w) translated = w end)
            button("05_wikipedia").callback()
            assert.is_nil(wiki)
            assert.are.equal(0.1, tasks[#tasks].delay)
            tasks[#tasks].fn()
            assert.are.equal("Montagues.\nSAMPSON", wiki)
            button("06_dictionary").callback()
            assert.are.equal("Montagues.\nSAMPSON", dict)
            assert.truthy(hl.selected_text) -- kept for dictionary lookup
            button("12_search").callback()
            assert.are.equal("Montagues.\nSAMPSON", search)
            -- translating without the menu shown clears the selection (after backing it up)
            button("07_translate").callback()
            assert.truthy(translated:find("SAMPSON", 1, true))
            assert.is_nil(hl.selected_text)
            assert.truthy(hl.selected_text_backup)
            select_text(TEXT0, TEXT1)
            button("06_dictionary").hold_callback()
            assert.are.equal("Montagues.\nSAMPSON", dict_lookup)
            select_text(TEXT0, TEXT1)
            button("12_search").hold_callback()
            assert.are.equal("Montagues.\nSAMPSON", fulltext)
            assert.is_nil(hl.selected_text)
        end)

        it("should view the selection HTML", function()
            local ViewHtml = require("ui/viewhtml")
            local viewed
            override(ViewHtml, "viewSelectionHTML", function(_, doc, sel) viewed = { doc, sel } end)
            select_text(TEXT0, TEXT1)
            button("09_view_html").callback()
            assert.are.equal(readerui.document, viewed[1])
            assert.are.equal(hl.selected_text, viewed[2])
            viewed = nil
            hl:clear()
            hl:viewSelectionHTML()
            assert.is_nil(viewed)
        end)

        it("should offer hyphenation for a single word only", function()
            override(readerui.userhyph, "isAvailable", function() return true end)
            local modified
            override(readerui.userhyph, "modifyUserEntry", function(_, w) modified = w end)
            hold(WORD)
            local b = button("10_user_dict")
            assert.is_true(b.show_in_highlight_dialog_func())
            b.callback()
            assert.are.equal("thy", modified)
            assert.is_nil(hl.selected_text)
            select_text(TEXT0, TEXT1)
            assert.is_false(button("10_user_dict").show_in_highlight_dialog_func())
        end)

        it("should follow a selected link", function()
            local followed
            override(readerui.link, "onGotoLink", function(_, link) followed = link end)
            select_text(TEXT0, TEXT1)
            assert.is_false(button("11_follow_link").show_in_highlight_dialog_func())
            hl.selected_link = { link = { xpointer = "#target" } }
            assert.is_true(button("11_follow_link").show_in_highlight_dialog_func())
            button("11_follow_link").callback()
            assert.are.same({ xpointer = "#target" }, followed)
            hl.selected_link = { xpointer = "#other" }
            button("11_follow_link").callback()
            assert.are.same({ xpointer = "#other" }, followed)
        end)

        it("should let plugins add and remove buttons", function()
            hl:addToHighlightDialog("13_test", function() return { text = "Test button" } end)
            select_text(TEXT0, TEXT1)
            hl:onShowHighlightMenu()
            assert.truthy(find_button(hl.highlight_dialog.buttons, "Test button"))
            local fn = hl:removeFromHighlightDialog("13_test")
            assert.is_function(fn)
            hl:onClose()
            select_text(TEXT0, TEXT1)
            hl:onShowHighlightMenu()
            assert.is_nil(find_button(hl.highlight_dialog.buttons, "Test button"))
            -- no menu without a selection
            hl:onClose()
            assert.is_nil(hl:onShowHighlightMenu())
        end)
    end)

    describe("highlight prompt", function()
        it("should do nothing without a selection", function()
            assert.is_nil(hl:showHighlightPrompt())
            assert.are.equal(0, #shown)
        end)

        it("should ask for the style", function()
            G_reader_settings:saveSetting("highlight_prompt", "style")
            select_text(TEXT0, TEXT1)
            hl:showHighlightPrompt()
            local selector = last_shown()
            assert.are.equal("lighten", selector.current_value)
            assert.is_nil(selector.anchor())
            selector.callback("strikeout")
            assert.are.equal(1, #readerui.annotation.annotations)
            assert.are.equal("strikeout", readerui.annotation.annotations[1].drawer)
        end)

        it("should ask for the color, and use the default when dismissed", function()
            G_reader_settings:saveSetting("highlight_prompt", "color")
            select_text(TEXT0, TEXT1)
            hl:showHighlightPrompt()
            last_shown().callback("blue")
            assert.are.equal("blue", readerui.annotation.annotations[1].color)
            select_text(LATER0, LATER1)
            hl:showHighlightPrompt()
            last_shown().tap_close_callback()
            assert.are.equal(2, #readerui.annotation.annotations)
            assert.are.equal(hl.view.highlight.saved_color, readerui.annotation.annotations[2].color)
        end)

        it("should ask for style then color with 'all'", function()
            G_reader_settings:saveSetting("highlight_prompt", "all")
            local cb_index
            select_text(TEXT0, TEXT1)
            hl:showHighlightPrompt(function(index) cb_index = index end)
            local nb = #shown
            last_shown().callback("underscore")
            assert.are.equal(nb + 1, #shown) -- color selector
            assert.are.equal(0, #readerui.annotation.annotations)
            last_shown().callback("green")
            assert.are.equal(1, cb_index)
            local item = readerui.annotation.annotations[1]
            assert.are.equal("underscore", item.drawer)
            assert.are.equal("green", item.color)
            -- no color prompt for the invert style
            select_text(LATER0, LATER1)
            hl:showHighlightPrompt()
            nb = #shown
            last_shown().tap_close_callback()
            assert.are.equal(nb + 1, #shown)
            last_shown().tap_close_callback()
            assert.are.equal(2, #readerui.annotation.annotations)
            select_text(LATER0, { x = 300, y = 271 })
            hl:showHighlightPrompt()
            nb = #shown
            last_shown().callback("invert")
            assert.are.equal(nb, #shown)
            assert.are.equal(3, #readerui.annotation.annotations)
        end)

        it("should close the menu and highlight from the hold position", function()
            select_text(TEXT0, TEXT1)
            hl:onShowHighlightMenu()
            local dialog = hl.highlight_dialog
            assert.truthy(dialog)
            hl.selected_text = nil -- only the hold position is known
            hl:showHighlightPrompt()
            assert.is_nil(hl.highlight_dialog)
            assert.are.equal(1, #readerui.annotation.annotations)
        end)
    end)

    describe("saved highlight dialog", function()
        local index, item
        before_each(function()
            index = save_text(TEXT0, TEXT1)
            item = readerui.annotation.annotations[index]
        end)

        local function open_dialog()
            hl:showHighlightDialog(index)
            local dialog = last_shown()
            assert.are.equal("edit_highlight_dialog", dialog.name)
            return dialog
        end

        it("should move highlight boundaries by word and by char", function()
            local orig_text = item.text
            local names = record_events(readerui)
            local rows = open_dialog().buttons
            local start_prev, start_next, end_prev, end_next = rows[2][1], rows[2][2], rows[2][3], rows[2][4]
            assert.is_true(start_next.enabled)
            start_next.callback()
            assert.are.equal("SAMPSON", item.text)
            assert.are.equal(1, count(names, "AnnotationsModified"))
            -- cannot move the start past the end
            start_next.callback()
            assert.are.equal("SAMPSON", item.text)
            start_prev.callback()
            assert.are.equal(orig_text, item.text)
            end_prev.callback()
            assert.are.equal("Montagues", item.text)
            -- cannot move the end before the start
            end_prev.callback()
            end_prev.callback()
            assert.truthy(#item.text > 0)
            end_next.callback()
            end_next.callback()
            local text = item.text
            assert.truthy(text:find("SAMPSON", 1, true))
            -- hold: move by char
            end_prev.hold_callback()
            assert.are.equal(text:sub(1, -2), item.text)
            end_next.hold_callback()
            assert.are.equal(text, item.text)
            start_next.hold_callback()
            assert.are.equal(text:sub(2), item.text)
            start_prev.hold_callback()
            assert.are.equal(text, item.text)
            assert.are.equal(readerui.document:getEPubCFIRangeFromXPointers(item.pos0, item.pos1), item.epubcfi)
        end)

        it("should disable boundary moves on edited text", function()
            item.text_edited = true
            local rows = open_dialog().buttons
            assert.is_false(rows[2][1].enabled)
            assert.is_false(rows[2][4].enabled)
        end)

        it("should change style and color", function()
            local names = record_events(readerui)
            local rows = open_dialog().buttons
            rows[1][2].callback()
            local selector = last_shown()
            assert.are.equal(item.drawer, selector.current_value)
            selector.callback("invert")
            assert.are.equal("invert", item.drawer)
            assert.is_nil(selector.anchor())
            -- color is not available for the invert style
            rows = open_dialog().buttons
            assert.is_false(rows[1][3].enabled)
            item.drawer = "lighten"
            rows = open_dialog().buttons
            rows[1][3].callback()
            selector = last_shown()
            selector.callback("purple")
            assert.are.equal("purple", item.color)
            assert.is_nil(selector.anchor())
            assert.are.equal(2, count(names, "AnnotationsModified"))
        end)

        it("should edit the note, show details and the full menu", function()
            local note_index, details_index
            override(readerui.bookmark, "setBookmarkNote", function(_, i) note_index = i end)
            override(readerui.bookmark, "showBookmarkDetails", function(_, i) details_index = i end)
            local rows = open_dialog().buttons
            rows[1][4].callback()
            assert.are.equal(index, note_index)
            rows[1][5].callback()
            assert.are.equal(index, details_index)
            rows[1][6].callback()
            assert.truthy(hl.highlight_dialog)
            assert.are.equal(item.text, hl.selected_text.text)
            assert.are_not.equal(item, hl.selected_text)
            assert.are.equal("Extend", find_button(hl.highlight_dialog.buttons, "Extend").text)
        end)

        it("should delete the highlight", function()
            local rows = open_dialog().buttons
            rows[1][1].callback()
            assert.are.equal(0, #readerui.annotation.annotations)
        end)

        it("should anchor dialogs as configured", function()
            local dialog = open_dialog()
            assert.is_nil(dialog.anchor())
            G_reader_settings:saveSetting("highlight_dialog_position", "top")
            assert.truthy(dialog.anchor().y < 10)
            G_reader_settings:saveSetting("highlight_dialog_position", "bottom")
            assert.truthy(dialog.anchor().y > Screen:getHeight() - 10)
            G_reader_settings:saveSetting("highlight_dialog_position", "gesture")
            -- no visible boxes: fallback to center
            hl.view.highlight.visible_boxes = {}
            hl.selected_text = {}
            assert.is_nil(dialog.anchor())
            hl.selected_text = nil
            hl.view.highlight.visible_boxes = {
                { index = index, rect = Geom:new({ x = 10, y = 300, w = 100, h = 20 }) },
                { index = index, rect = Geom:new({ x = 10, y = 100, w = 100, h = 20 }) },
            }
            local anchor, pop_down = hl:_getDialogAnchor({ getContentSize = function() return { h = 200 } end }, index)
            assert.is_true(pop_down)
            assert.truthy(anchor.y > 320)
            -- no room below: above the highlight
            hl.view.highlight.visible_boxes = {
                { index = index, rect = Geom:new({ x = 10, y = 650, w = 100, h = 20 }) },
                { index = index, rect = Geom:new({ x = 10, y = 700, w = 100, h = 20 }) },
            }
            anchor, pop_down = hl:_getDialogAnchor({ getContentSize = function() return { h = 200 } end }, index)
            assert.is_nil(pop_down)
            assert.truthy(anchor.y < 650 and anchor.y > 600)
            -- no room at all
            assert.is_nil(hl:_getDialogAnchor({ getContentSize = function() return { h = 2000 } end }, index))
            -- from the current selection
            select_text(TEXT0, TEXT1)
            assert.truthy(hl:_getDialogAnchor({ getContentSize = function() return { h = 100 } end }))
            hl.view.highlight.visible_boxes = {}
        end)
    end)

    describe("notes and overlapping highlights", function()
        it("should show a note viewer with format detection and actions", function()
            local index = save_text(TEXT0, TEXT1)
            local item = readerui.annotation.annotations[index]
            for note, fmt in pairs({ ["<p>html</p>"] = "html", ["# title"] = "md", ["* item"] = "md",
                                     ["[link](x)"] = "md", ["plain text"] = false }) do
                item.note = note
                hl:showHighlightNoteOrDialog(index)
                local viewer = last_shown()
                assert.are.equal(note, viewer.text)
                if fmt then
                    assert.are.equal(fmt, viewer.text_format)
                end
                assert.are.equal(fmt and true or false, viewer.show_menu)
                -- larger viewer for formatted notes
                assert.are.equal(math.floor(Screen:getWidth() * (fmt and 0.9 or 0.8)), viewer.width)
                assert.is_nil(viewer.anchor())
            end
            item.note_format = "md"
            item.note = "plain"
            hl:showHighlightNoteOrDialog(index)
            local viewer = last_shown()
            assert.are.equal("md", viewer.text_format)
            local buttons = viewer.buttons_table
            -- Edit note
            local edited
            override(readerui.bookmark, "setBookmarkNote", function(_, i) edited = i end)
            buttons[1][2].callback()
            assert.are.equal(index, edited)
            -- Highlight menu
            buttons[2][2].callback()
            assert.are.equal("edit_highlight_dialog", last_shown().name)
            -- Delete note
            local names, args = record_events(readerui)
            hl.view.highlight.note_mark = "underline"
            buttons[1][1].callback()
            assert.is_nil(item.note)
            assert.are.equal(1, count(names, "AnnotationsModified"))
            assert.are.equal(-1, args.AnnotationsModified[1].nb_notes_added)
            -- Delete highlight
            buttons[2][1].callback()
            assert.are.equal(0, #readerui.annotation.annotations)
        end)

        it("should go straight to the dialog when there is no note", function()
            local index = save_text(TEXT0, TEXT1)
            assert.is_true(hl:showChooseHighlightDialog({ index }))
            assert.are.equal("edit_highlight_dialog", last_shown().name)
        end)

        it("should offer to choose or merge overlapping highlights", function()
            local i1 = save_text(TEXT0, TEXT1)
            local i2 = save_text(LATER0, LATER1)
            readerui.annotation.annotations[i1].note = "first"
            readerui.annotation.annotations[i2].note = "second"
            local pos0 = readerui.annotation.annotations[i1].pos0
            local pos1 = readerui.annotation.annotations[i2].pos1
            hl:showChooseHighlightDialog({ i2, i1 })
            local dialog = last_shown()
            assert.are.equal(3, #dialog.buttons)
            assert.truthy(dialog.buttons[1][1].text:find("GREGORY", 1, true))
            dialog.buttons[2][1].callback()
            assert.are.equal("first", last_shown().text) -- note viewer
            hl:showChooseHighlightDialog({ i2, i1 })
            dialog = last_shown()
            assert.are.equal("Merge highlights", dialog.buttons[3][1].text)
            dialog.buttons[3][1].callback()
            assert.are.equal(1, #readerui.annotation.annotations)
            local merged = readerui.annotation.annotations[1]
            assert.are.equal(pos0, merged.pos0)
            assert.are.equal(pos1, merged.pos1)
            assert.are.equal("first\nsecond", merged.note)
            assert.truthy(merged.text:find("Montagues", 1, true))
            assert.truthy(merged.text:find("run?", 1, true))
        end)

        it("should react to taps on visible highlight boxes", function()
            local i1 = save_text(TEXT0, TEXT1)
            local i2 = save_text(LATER0, LATER1)
            local full = Geom:new({ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() })
            hl.view.highlight.visible_boxes = {
                { index = i1, rect = full }, { index = i1, rect = full }, { index = i2, rect = full },
            }
            finally(function() hl.view.highlight.visible_boxes = {} end)
            assert.is_true(hl:onTap(nil, { pos = Geom:new({ x = 10, y = 10 }) }))
            assert.are.equal(3, #last_shown().buttons) -- 2 highlights + merge
            assert.are.same({ full }, { hl:getHighlightVisibleBoxes(i2)[1] })
            assert.is_nil(hl:getHighlightVisibleBoxes(99))
            -- outside any box
            hl.view.highlight.visible_boxes = { { index = i1, rect = Geom:new({ x = 0, y = 0, w = 5, h = 5 }) } }
            assert.is_nil(hl:onTap(nil, { pos = Geom:new({ x = 100, y = 100 }) }))
            -- tapping while holding ends the hold
            select_text(TEXT0, TEXT1)
            assert.is_true(hl:onTap(nil, { pos = Geom:new({ x = 1, y = 1 }) }))
            assert.truthy(hl.highlight_dialog)
        end)

        it("should abort select mode by tapping on its first fragment", function()
            G_reader_settings:saveSetting("default_highlight_action", "select")
            select_text(TEXT0, TEXT1)
            hl:onHoldRelease()
            assert.is_true(hl.select_mode)
            local idx = hl.highlight_idx
            local full = Geom:new({ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() })
            hl.view.highlight.visible_boxes = { { index = 99, rect = full }, { index = idx, rect = full } }
            finally(function() hl.view.highlight.visible_boxes = {} end)
            assert.is_true(hl:onTap(nil, { pos = Geom:new({ x = 10, y = 10 }) }))
            assert.is_false(hl.select_mode)
            assert.are.equal(0, #readerui.annotation.annotations)
            -- with an existing highlight being extended, it is kept
            local index = save_text(TEXT0, TEXT1)
            hl:startSelection(index)
            hl.view.highlight.visible_boxes = { { index = index, rect = full } }
            hl:onTap(nil, { pos = Geom:new({ x = 10, y = 10 }) })
            assert.is_false(hl.select_mode)
            assert.are.equal(1, #readerui.annotation.annotations)
        end)

        it("should explain and exit select mode from its indicator", function()
            assert.is_nil(hl:onTapSelectModeIcon())
            select_text(TEXT0, TEXT1)
            hl:startSelection()
            hl:clear()
            assert.is_true(hl:onTapSelectModeIcon())
            last_shown().ok_callback()
            assert.is_false(hl.select_mode)
            assert.are.equal(0, #readerui.annotation.annotations)
            local index = save_text(TEXT0, TEXT1)
            hl:startSelection(index)
            hl:onTapSelectModeIcon()
            last_shown().ok_callback()
            assert.is_false(hl.select_mode)
            assert.are.equal(1, #readerui.annotation.annotations)
        end)

        it("should extend an existing highlight keeping its properties", function()
            local index = save_text(TEXT0, TEXT1)
            local item = readerui.annotation.annotations[index]
            item.note = "kept"
            item.color = "cyan"
            hl:startSelection(index)
            select_text(LATER0, LATER1)
            hl:onHoldRelease()
            assert.is_false(hl.select_mode)
            assert.are.equal(1, #readerui.annotation.annotations)
            local extended = readerui.annotation.annotations[1]
            assert.are.equal("kept", extended.note)
            assert.are.equal("cyan", extended.color)
            assert.truthy(extended.text:find("run?", 1, true))
            assert.is_nil(hl.selected_text)
        end)

        it("should show the menu when ending a temporary selection with 'ask'", function()
            select_text(TEXT0, TEXT1)
            hl:startSelection()
            hl:clear()
            select_text(LATER0, LATER1)
            hl:onHoldRelease()
            assert.truthy(hl.highlight_dialog)
            assert.are.equal(0, #readerui.annotation.annotations)
            assert.truthy(hl.selected_text.text:find("Montagues", 1, true))
        end)
    end)

    describe("selection helpers", function()
        it("should highlight a word at given coordinates", function()
            assert.is_nil(hl:highlightWordAtCoordinates(nil, 10))
            assert.is_true(hl:highlightWordAtCoordinates(WORD.x, WORD.y))
            assert.are.equal("thy", hl.selected_text.text)
            assert.is_true(hl.is_word_selection)
            override(readerui.document, "getWordFromPosition", function() return { word = "x" } end)
            assert.is_false(hl:highlightWordAtCoordinates(2, 2))
        end)

        it("should get the context around the selected word", function()
            assert.is_nil(hl:getSelectedWordContext(3))
            hold(WORD)
            local prev, nxt = hl:getSelectedWordContext(3)
            assert.is_string(prev)
            assert.is_string(nxt)
            assert.truthy(#prev > 0)
        end)

        it("should get the chapter title, possibly the full path", function()
            local xp = readerui.document:getXPointer()
            local short = hl:getHighlightChapter(xp)
            assert.is_string(short)
            G_reader_settings:makeTrue("bookmark_full_chapter")
            local full = hl:getHighlightChapter(xp)
            assert.truthy(full:find(short, 1, true))
        end)

        it("should translate the current page", function()
            local translated
            override(Translator, "showTranslation", function(_, text, detailed) translated = { text, detailed } end)
            hl:onTranslateCurrentPage()
            assert.truthy(#translated[1] > 100)
            assert.is_false(translated[2])
        end)

        it("should translate an extended selection with the menu open", function()
            local translated
            override(Translator, "showTranslation", function(_, text, _d, _s, _t, _h, index) translated = { text, index } end)
            select_text(TEXT0, TEXT1)
            hl:onShowHighlightMenu()
            hl:translate()
            assert.truthy(translated[1]:find("SAMPSON", 1, true))
            -- with the menu open the selection is kept
            assert.truthy(hl.selected_text)
            hl:translate(5)
            assert.are.equal(5, translated[2])
        end)

        it("should switch to scroll mode to select across pages from a corner", function()
            local rolling = readerui.rolling
            assert.is_true(hl.allow_corner_scroll)
            select_text(TEXT0, TEXT1)
            assert.is_true(hl.allow_hold_pan_corner_scroll)
            local xp = rolling.xpointer
            local w, h = Screen:getWidth(), Screen:getHeight()
            local corner = Geom:new({ x = w - 5, y = h - 5 })
            assert.is_true(hl:onHoldPan(nil, { pos = corner }))
            assert.are.equal("scroll", readerui.view.view_mode)
            assert.is_function(hl.restore_page_mode_func)
            assert.are.equal(readerui.document:getPosFromXPointer(xp) + math.floor(h / 3), rolling.current_pos)
            -- staying in the corner does nothing more
            local pos2 = rolling.current_pos
            assert.is_true(hl:onHoldPan(nil, { pos = Geom:new({ x = w - 4, y = h - 4 }) }))
            assert.are.equal(pos2, rolling.current_pos)
            -- leaving the corner selects again
            hl:onHoldPan(nil, { pos = Geom:new({ x = 300, y = 400 }) })
            assert.is_nil(hl.was_in_some_corner)
            assert.truthy(#hl.selected_text.text > 20)
            -- top left corner scrolls back
            hl:onHoldPan(nil, { pos = Geom:new({ x = 2, y = 2 }) })
            assert.are.equal(pos2 - math.floor(h / 3), rolling.current_pos)
            -- clearing restores page mode at the original page
            hl:clear()
            assert.are.equal("page", readerui.view.view_mode)
            assert.is_nil(hl.restore_page_mode_func)
            assert.are.equal(10, rolling.current_page)
        end)

        it("should not corner scroll when the selection starts in a corner", function()
            local w, h = Screen:getWidth(), Screen:getHeight()
            hold(TEXT0)
            hl.allow_hold_pan_corner_scroll = false
            hl:onHoldPan(nil, { pos = Geom:new({ x = w - 5, y = h - 5 }) })
            assert.are.equal("page", readerui.view.view_mode)
            -- panning outside the page area is ignored
            local area = hl.view:getScreenPageArea(hl.hold_pos.page)
            assert.is_true(hl:onHoldPan(nil, { pos = Geom:new({ x = area.x + area.w + 50, y = 10 }) }))
        end)

        it("should update the corner scroll setting from the menu", function()
            local menu_items = {}
            hl:addToMainMenu(menu_items)
            local corner
            for _, item in ipairs(menu_items.long_press.sub_item_table) do
                if item.text == "Auto-scroll when selection reaches a corner" then corner = item end
            end
            assert.is_true(corner.checked_func())
            assert.is_true(corner.enabled_func())
            corner.callback()
            assert.is_false(hl.allow_corner_scroll)
            assert.is_false(corner.checked_func())
            corner.callback()
            assert.is_true(hl.allow_corner_scroll)
        end)
    end)

    describe("main menu", function()
        local menu_items, tm
        before_each(function()
            menu_items = {}
            hl:addToMainMenu(menu_items)
            tm = fake_touchmenu()
        end)
        local function find_item(items, text)
            for _, item in ipairs(items) do
                local t = item.text or (item.text_func and item.text_func())
                if t and t:find(text, 1, true) then return item end
            end
        end

        it("should set the highlight style for this book and as default", function()
            local items = menu_items.highlight_options.sub_item_table
            local underline = find_item(items, "Underline")
            assert.is_false(underline.checked_func())
            underline.callback()
            assert.are.equal("underscore", hl.view.highlight.saved_drawer)
            assert.is_true(underline.checked_func())
            underline.hold_callback(tm)
            assert.are.equal("underscore", G_reader_settings:readSetting("highlight_drawing_style"))
            assert.truthy(underline.text_func():find("★", 1, true))
            assert.are.equal(1, tm.updated)
            assert.is_nil(menu_items.panel_zoom_options)
        end)

        it("should set the highlight color", function()
            local items = menu_items.highlight_options.sub_item_table
            local color = find_item(items, "Highlight color")
            assert.is_true(color.enabled_func())
            color.callback(tm)
            local selector = last_shown()
            selector.callback("olive")
            assert.are.equal("olive", hl.view.highlight.saved_color)
            assert.truthy(color.text_func():find("Olive", 1, true))
            color.hold_callback(tm)
            assert.are.equal("olive", G_reader_settings:readSetting("highlight_color"))
            assert.truthy(color.text_func():find("★", 1, true))
            hl.view.highlight.saved_color = "yellow"
            -- gray cannot be customized
            local nb = #shown
            selector.hold_callback("gray", "Gray")
            assert.are.equal(nb, #shown)
        end)

        it("should edit, validate and reset custom colors", function()
            finally(function() hl.custom_colors.red = nil end)
            hl:setHighlightColor(tm)
            local selector = last_shown()
            selector.hold_callback("red", "Red")
            local dialog = last_shown()
            assert.truthy(dialog.title:find("Red", 1, true))
            local buttons = dialog.buttons[1]
            assert.is_false(buttons[2].enabled) -- nothing to reset
            -- invalid code
            dialog.getFields = function() return { "Crimson", "#zz0000" } end
            buttons[3].callback()
            assert.are.equal("Incorrect color code", last_shown().text)
            assert.is_nil(hl.custom_colors.red)
            -- valid
            dialog.getFields = function() return { "Crimson", "#a00000" } end
            buttons[3].callback()
            assert.are.same({ name = "Crimson", code = "#a00000" }, hl.custom_colors.red)
            assert.truthy(tm.updated > 0)
            -- name only, code kept as original
            hl:editCustomColor("red", "Crimson", tm, selector)
            dialog = last_shown()
            assert.is_true(dialog.buttons[1][2].enabled)
            dialog.getFields = function() return { "Scarlet", "" } end
            dialog.buttons[1][3].callback()
            assert.are.same({ name = "Scarlet" }, hl.custom_colors.red)
            -- unchanged: nothing saved
            hl:editCustomColor("red", "Scarlet", tm, selector)
            dialog = last_shown()
            dialog.getFields = function() return { "Scarlet", "" } end
            local nb = #shown
            dialog.buttons[1][3].callback()
            assert.are.equal(nb, #shown)
            -- reset
            dialog.buttons[1][2].callback()
            assert.is_nil(hl.custom_colors.red)
            dialog.buttons[1][1].callback() -- cancel
        end)

        it("should set opacities, line height and selection colors", function()
            local items = menu_items.highlight_options.sub_item_table
            local gray = find_item(items, "Gray highlight opacity")
            assert.is_true(gray.enabled_func())
            gray.callback(tm)
            last_shown().callback({ value = 0.4 })
            assert.are.equal(0.4, G_reader_settings:readSetting("highlight_lighten_factor"))
            assert.are.equal(0.4, hl.view.highlight.lighten_factor)
            assert.truthy(gray.text_func():find("0.4", 1, true))
            local sel = find_item(items, "Gray selection opacity")
            sel.callback(tm)
            last_shown().callback({ value = 0.6 })
            assert.are.equal(0.6, G_reader_settings:readSetting("highlight_selection_lighten_factor"))
            last_shown().callback({ value = 0.2 })
            assert.is_nil(G_reader_settings:readSetting("highlight_selection_lighten_factor"))
            assert.truthy(sel.text_func():find("0.2", 1, true))
            local height = find_item(items, "Highlight line height")
            assert.is_true(height.enabled_func())
            height.callback(tm)
            last_shown().callback({ value = 50 })
            assert.are.equal(50, G_reader_settings:readSetting("highlight_height_pct"))
            last_shown().callback({ value = 100 })
            assert.is_nil(G_reader_settings:readSetting("highlight_height_pct"))
            assert.truthy(height.text_func():find("100", 1, true))
            local invert = find_item(items, "Invert highlight color in night mode")
            assert.is_true(invert.enabled_func())
            assert.is_false(invert.checked_func())
            invert.callback()
            assert.is_true(invert.checked_func())
            local use = find_item(items, "Use highlight color for selection")
            assert.is_true(use.enabled_func())
            use.callback()
            assert.is_true(use.checked_func())
            G_reader_settings:delSetting("highlight_lighten_factor")
            hl.view.highlight.lighten_factor = 0.2
        end)

        it("should set the note marker", function()
            local items = menu_items.highlight_options.sub_item_table
            local marker = find_item(items, "Note marker")
            assert.truthy(marker.text_func():find("none", 1, true))
            marker.callback()
            last_shown().callback("sideline")
            assert.are.equal("sideline", hl.view.highlight.note_mark)
            assert.are.equal("sideline", G_reader_settings:readSetting("highlight_note_marker"))
            assert.truthy(marker.text_func():find("side line", 1, true))
            last_shown().callback("none")
            assert.is_nil(hl.view.highlight.note_mark)
        end)

        it("should apply the current style and color to all highlights", function()
            local items = menu_items.highlight_options.sub_item_table
            local apply = find_item(items, "Apply current style and color to all highlights")
            save_text(TEXT0, TEXT1)
            save_text(LATER0, LATER1)
            table.insert(readerui.annotation.annotations, { page = "bookmark" }) -- not a highlight
            hl.view.highlight.saved_drawer = "strikeout"
            hl.view.highlight.saved_color = "blue"
            apply.callback()
            last_shown().ok_callback()
            assert.truthy(last_shown().text:find("2 highlights", 1, true))
            local annotations = readerui.annotation.annotations
            assert.are.equal("strikeout", annotations[1].drawer)
            assert.are.equal("blue", annotations[2].color)
            assert.is_nil(annotations[3].drawer)
            hl.view.highlight.saved_color = "yellow"
            -- nothing to update
            readerui.annotation.annotations = {}
            local nb = #shown
            apply.callback()
            last_shown().ok_callback()
            assert.are.equal(nb + 1, #shown)
        end)

        it("should set long-press options", function()
            local items = menu_items.long_press.sub_item_table
            local single = items[1]
            assert.is_true(single.enabled_func())
            assert.is_true(single.checked_func())
            single.callback()
            assert.is_true(G_reader_settings:isTrue("highlight_action_on_single_word"))
            assert.is_false(single.checked_func())
            local translate = find_item(items, "Translate")
            assert.is_false(translate.checked_func())
            translate.callback()
            assert.are.equal("translate", G_reader_settings:readSetting("default_highlight_action"))
            assert.is_true(translate.checked_func())
            local nb = #shown
            find_item(items, "Do nothing").callback()
            assert.is_true(hl.view.highlight.disabled)
            assert.are.equal(nb, #shown) -- no notification from the menu
            local position = find_item(items, "Highlight dialog position")
            assert.truthy(position.text_func():find("center", 1, true))
            position.sub_item_table[1].callback()
            assert.is_true(position.sub_item_table[1].checked_func())
            assert.are.equal("top", G_reader_settings:readSetting("highlight_dialog_position"))
            assert.truthy(position.text_func():find("top", 1, true))
            local prompt = find_item(items, "Highlight prompt")
            assert.truthy(prompt.text_func():find("none", 1, true))
            prompt.sub_item_table[4].callback()
            assert.is_true(prompt.sub_item_table[4].checked_func())
            assert.are.equal("all", G_reader_settings:readSetting("highlight_prompt"))
            assert.truthy(prompt.text_func():find("style, color", 1, true))
            local interval = find_item(items, "very-long-press interval")
            interval.callback(tm)
            last_shown().callback({ value = 5 })
            assert.are.equal(5, G_reader_settings:readSetting("highlight_long_hold_threshold_s"))
            assert.truthy(interval.text_func():find("5", 1, true))
            local GestureDetector = require("device/gesturedetector")
            last_shown().callback({ value = GestureDetector.LONG_HOLD_INTERVAL_S })
            assert.is_nil(G_reader_settings:readSetting("highlight_long_hold_threshold_s"))
            local translated
            override(Translator, "showTranslation", function(_, text) translated = text end)
            menu_items.translate_current_page.callback()
            assert.truthy(translated)
        end)
    end)

    describe("settings", function()
        it("should save and read highlight settings", function()
            hl.view.highlight.saved_drawer = "underscore"
            hl.view.highlight.saved_color = "cyan"
            hl:onSaveSettings()
            local ds = readerui.doc_settings
            assert.are.equal("underscore", ds:readSetting("highlight_drawer"))
            assert.are.equal("cyan", ds:readSetting("highlight_color"))
            hl:onReadSettings(LuaSettings:wrap({ highlight_drawer = "strikeout", highlight_color = "orange" }))
            assert.are.equal("strikeout", hl.view.highlight.saved_drawer)
            assert.are.equal("orange", hl.view.highlight.saved_color)
            -- global defaults when the book has none
            G_reader_settings:saveSetting("highlight_drawing_style", "invert")
            G_reader_settings:saveSetting("highlight_color", "gray")
            G_reader_settings:saveSetting("default_highlight_action", "nothing")
            G_reader_settings:makeFalse("highlight_corner_scroll")
            hl:onReadSettings(LuaSettings:wrap({}))
            assert.are.equal("invert", hl.view.highlight.saved_drawer)
            assert.are.equal("gray", hl.view.highlight.saved_color)
            assert.is_true(hl.view.highlight.disabled)
            assert.is_false(hl.allow_corner_scroll)
            -- panel zoom is not for reflowable documents
            assert.is_nil(hl:onTogglePanelZoomSetting())
            assert.is_nil(hl:onToggleFallbackTextSelection())
            assert.falsy(hl.panel_zoom_enabled)
            G_reader_settings:delSetting("highlight_corner_scroll")
            hl:onReadSettings(LuaSettings:wrap({}))
            hl.view.highlight.saved_color = "yellow"
        end)

        it("should keep dimensions and re-register touch zones", function()
            hl:onSetDimensions({ w = 300, h = 400 })
            assert.are.equal(300, hl.screen_w)
            assert.are.equal(400, hl.screen_h)
            hl:onSetDimensions(Screen:getSize())
            G_reader_settings:saveSetting("hold_pan_rate", 7)
            finally(function() G_reader_settings:delSetting("hold_pan_rate") end)
            hl:onUpdateHoldPanRate()
            assert.are.equal(7, readerui._zones.readerhighlight_hold_pan.gs_range.rate)
            assert.is_true(hl:onClearHighlight())
        end)

        it("should route touch zones to highlight handlers", function()
            local zones = readerui._zones
            assert.is_true(zones.readerhighlight_hold.handler({ pos = at(WORD) }))
            assert.are.equal("thy", hl.selected_text.text)
            local looked_up
            override(readerui.dictionary, "onLookupWord", function(_, w) looked_up = w end)
            assert.is_true(zones.readerhighlight_hold_release.handler())
            assert.are.equal("thy", looked_up)
            hl:clear()
            zones.readerhighlight_hold.handler({ pos = at(TEXT0) })
            zones.readerhighlight_hold_pan.handler({ pos = at(TEXT1) })
            assert.are.equal("Montagues.\nSAMPSON", hl.selected_text.text)
            assert.is_true(zones.readerhighlight_tap.handler({ pos = Geom:new({ x = 1, y = 1 }) }))
            assert.is_nil(zones.readerhighlight_tap_select_mode.handler())
        end)
    end)
end)
