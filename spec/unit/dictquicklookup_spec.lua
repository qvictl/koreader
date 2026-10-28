-- DictQuickLookup: navigation between results ("n / N" counter, prev/next with wrap-around,
-- taps and swipes), results added while shown (progressive lookups: updateResults()),
-- closing (callbacks, highlight, all windows), the results menus, and the input dialog.
describe("DictQuickLookup", function()
    local DictQuickLookup, DocumentRegistry, Geom, ReaderUI, UIManager, Screen
    local readerui

    local function topWidget()
        local stack = UIManager._window_stack
        return stack[#stack] and stack[#stack].widget
    end

    local function closeAll()
        for i = #DictQuickLookup.window_list, 1, -1 do
            UIManager:close(DictQuickLookup.window_list[i])
        end
        for i = #UIManager._window_stack, 1, -1 do
            local w = UIManager._window_stack[i].widget
            if w ~= readerui then
                UIManager:close(w)
            end
        end
    end

    local function result(dict, word, definition, extra)
        local r = { dict = dict, word = word, definition = definition or (dict .. ": " .. word) }
        for k, v in pairs(extra or {}) do
            r[k] = v
        end
        return r
    end

    local function newWindow(results, opts)
        opts = opts or {}
        local w = DictQuickLookup:new{
            ui = readerui,
            word = opts.word or "harbor",
            results = results,
            results_pending = opts.results_pending,
            preferred_dictionaries = opts.preferred_dictionaries,
            highlight = opts.highlight,
            dict_close_callback = opts.dict_close_callback,
            word_boxes = opts.word_boxes,
        }
        UIManager:show(w)
        -- (paint it, so all its widgets get their dimen)
        w:paintTo(Screen.bb, 0, 0)
        return w
    end

    local function findButton(buttons, text)
        for _, row in ipairs(buttons) do
            for _, button in ipairs(row) do
                if button.text == text then
                    return button
                end
            end
        end
    end

    local function tapAt(x, y)
        return { pos = Geom:new({ x = x, y = y, w = 0, h = 0 }) }
    end

    local function center(dimen)
        return math.floor(dimen.x + dimen.w / 2), math.floor(dimen.y + dimen.h / 2)
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        DictQuickLookup = require("ui/widget/dictquicklookup")
        DocumentRegistry = require("document/documentregistry")
        Geom = require("ui/geometry")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        Screen = require("device").screen
        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument("spec/front/unit/data/sample.txt"),
        }
    end)

    teardown(function()
        closeAll()
        ReaderUI.instance = readerui
        readerui:closeDocument()
        readerui:onClose()
        UIManager:quit()
        UIManager._exit_code = nil
    end)

    before_each(function()
        ReaderUI.instance = readerui
        UIManager:show(readerui)
    end)

    after_each(function()
        closeAll()
    end)

    it("should report the visible area on both axes for every vertical alignment", function()
        local window = setmetatable({
            region = Geom:new{
                x = 47,
                y = 83,
                w = 600,
                h = 1000,
            },
            dict_frame = { getSize = function() return { w = 240, h = 360 } end },
        }, { __index = DictQuickLookup })
        for align, expected_y in pairs{ top = 83, bottom = 723, center = 403 } do
            window.align = align
            local area = window:getInitialVisibleArea()
            assert.are.same({ x = 227, y = expected_y, w = 240, h = 360 },
                { x = area.x, y = area.y, w = area.w, h = area.h })
        end
    end)

    describe("navigation", function()
        local results
        before_each(function()
            results = {
                result("Alpha", "harbor"),
                result("Beta", "harbor"),
                result("Gamma", "harbour"),
            }
        end)

        it("should show the first result, with the queried word and the n / N counter", function()
            local w = newWindow(results)
            assert.are.equal(1, w.dict_index)
            assert.are.equal("1 / 3", w.displaynb)
            assert.are.equal("Alpha", w.displaydictname)
            assert.matches("^Alpha: harbor\n_______\n%(query : harbor%)$", w.definition)
            assert.is_false(w:isPrevDictAvaiable())
            assert.is_true(w:isNextDictAvaiable())
        end)

        it("should go to the next and previous results, wrapping around", function()
            local w = newWindow(results)
            w:onChangeToNextDict()
            assert.are.equal(2, w.dict_index)
            assert.are.equal("2 / 3", w.displaynb)
            assert.are.equal("Beta: harbor", w.definition)
            w:onChangeToNextDict()
            assert.are.equal("Gamma", w.dictionary)
            assert.are.equal("harbour", w.lookupword)
            assert.is_false(w:isNextDictAvaiable())
            w:onChangeToNextDict() -- wraps
            assert.are.equal(1, w.dict_index)
            w:onChangeToPrevDict() -- wraps
            assert.are.equal(3, w.dict_index)
            w:onChangeToPrevDict()
            assert.are.equal(2, w.dict_index)
            w:changeToLastDict()
            assert.are.equal(3, w.dict_index)
            w:changeToLastDict() -- already there
            assert.are.equal(3, w.dict_index)
            w:changeToFirstDict()
            assert.are.equal(1, w.dict_index)
            w:changeToFirstDict()
            assert.are.equal(1, w.dict_index)
            -- No such result: nothing changes
            w:changeDictionary(42)
            assert.are.equal(1, w.dict_index)
        end)

        it("should not wrap around with a single result", function()
            local w = newWindow({ result("Alpha", "harbor") })
            w:onChangeToNextDict()
            w:onChangeToPrevDict()
            assert.are.equal(1, w.dict_index)
            assert.are.equal("1 / 1", w.displaynb)
        end)

        it("should number the preferred dictionaries in the title", function()
            local w = newWindow(results, { preferred_dictionaries = { "Beta", "Alpha" } })
            assert.are.equal("② Alpha", w.displaydictname)
            w:onChangeToNextDict()
            assert.are.equal("① Beta", w.displaydictname)
            w:onChangeToNextDict()
            assert.are.equal("Gamma", w.displaydictname)
        end)

        it("should change results with taps on the definition, and swipes", function()
            local w = newWindow(results)
            local def = w.definition_widget.dimen
            local _, y = center(def)
            -- (a tap is first given to the scroll widget, that pops it up when it can't scroll anymore)
            w:onTap(nil, tapAt(def.x + def.w - 10, y))
            assert.are.equal(2, w.dict_index)
            w:onReadNextResult()
            assert.are.equal(3, w.dict_index)
            w:onTap(nil, tapAt(def.x + 10, y))
            assert.are.equal(2, w.dict_index)
            w:onReadPrevResult() -- to the bottom of the previous one
            assert.are.equal(1, w.dict_index)

            local x
            x, y = center(w.definition_widget.dimen)
            assert.is_true(w:onSwipe(nil, { pos = Geom:new({ x = x, y = y, w = 0, h = 0 }), direction = "west" }))
            assert.are.equal(2, w.dict_index)
            assert.is_true(w:onSwipe(nil, { pos = Geom:new({ x = x, y = y, w = 0, h = 0 }), direction = "east" }))
            assert.are.equal(1, w.dict_index)
            -- Other directions: refresh, and let it propagate
            local footer = spy.on(readerui, "handleEvent")
            assert.is_false(w:onSwipe(nil, { pos = Geom:new({ x = x, y = y, w = 0, h = 0 }), direction = "north" }))
            assert.spy(footer).was_called_with(match.is_ref(readerui), match.is_table())
            readerui.handleEvent:revert()
            assert.are.equal(1, w.dict_index)
        end)

        it("should toggle the preferred dictionary with a tap on the title", function()
            local w = newWindow(results)
            local toggle = stub(readerui.dictionary, "onTogglePreferredDict")
            w:onTap(nil, tapAt(center(w.dict_title.dimen)))
            assert.stub(toggle).was_called_with(match.is_ref(readerui.dictionary), "Alpha")
            readerui.dictionary.onTogglePreferredDict:revert()
            assert.is_true(UIManager:isWidgetShown(w))
        end)

        it("should list the results in a menu, to jump to any of them", function()
            local w = newWindow(results)
            w:onShowResultsMenu()
            local menu = topWidget()
            assert.is_true(w.menu_opened[menu])
            assert.are.equal(3, #menu.buttons)
            assert.is_true(menu.buttons[1][1].font_bold)
            assert.are.equal("harbour", menu.buttons[3][1].text)
            assert.are.equal("Gamma", menu.buttons[3][2].text)
            menu.buttons[3][2].callback()
            assert.are.equal(3, w.dict_index)
            assert.is_false(UIManager:isWidgetShown(menu))
            assert.is_nil(w.menu_opened[menu])
            -- Hold on a word: look it up
            w:onShowResultsMenu()
            menu = topWidget()
            local lookup = stub(readerui, "handleEvent")
            menu.buttons[2][1].hold_callback()
            readerui.handleEvent:revert()
            assert.stub(lookup).was_called(1)
            local ev = lookup.calls[1].vals[2]
            assert.are.equal("onLookupWord", ev.handler)
            assert.are.equal("harbor", ev.args[1])
            menu.buttons[1][1].callback()
            assert.are.equal(1, w.dict_index)
        end)

        it("should list the results by dictionary in the alternative menu", function()
            local w = newWindow({ result("Alpha", "harbor"), result("Alpha", "harbors"), result("Beta", "harbor") })
            w:showResultsAltMenu()
            local menu = topWidget()
            assert.are.equal(2, #menu.buttons)
            assert.are.equal("Alpha", menu.buttons[1][1].text)
            assert.are.equal("2 results", menu.buttons[1][2].text)
            assert.are.equal("harbor", menu.buttons[2][2].text)
            menu.buttons[2][1].callback()
            assert.are.equal(3, w.dict_index)
        end)
    end)

    describe("results updated while shown", function()
        local a, b, c, d
        before_each(function()
            a = result("Alpha", "harbor")
            b = result("Beta", "harbor")
            c = result("Gamma", "harbor")
            d = result("Delta", "harbor")
        end)

        it("should show that more results are pending", function()
            local w = newWindow({ a }, { results_pending = true })
            assert.are.equal("1 / 1\u{2026}", w.displaynb)
            assert.are.equal("1 / 1\u{2026}", w.displaynb_text.text)
            -- (no next result yet)
            assert.is_false(w.button_table:getButtonById("next_dict").enabled)
        end)

        it("should add results, keeping the shown one, and updating the counter and buttons", function()
            local w = newWindow({ b }, { results_pending = true })
            local text_widget = w.text_widget
            local dirty = spy.on(UIManager, "setDirty")
            -- A result comes in before the shown one, another one after it
            w:updateResults({ a, b, c }, true)
            assert.are.equal(2, w.dict_index)
            assert.are.equal("2 / 3\u{2026}", w.displaynb_text.text)
            assert.is_true(w.button_table:getButtonById("prev_dict").enabled)
            assert.is_true(w.button_table:getButtonById("next_dict").enabled)
            -- The shown definition is not touched
            assert.are.equal(text_widget, w.text_widget)
            assert.spy(dirty).was_called()
            -- the refresh region covers the changed widgets
            local refresh_func = dirty.calls[1].vals[3]
            local mode, region = refresh_func()
            assert.are.equal("ui", mode)
            assert.truthy(region.w > 0 and region.h > 0)
            UIManager.setDirty:revert()

            -- Done
            w:updateResults({ a, b, c, d }, false)
            assert.are.equal("2 / 4", w.displaynb_text.text)
            assert.is_false(w.results_pending)
            w:onChangeToNextDict()
            w:onChangeToNextDict()
            assert.are.equal("Delta", w.dictionary)
            assert.are.equal("4 / 4", w.displaynb)
        end)

        it("should only refresh what changed", function()
            local w = newWindow({ a, b }, { results_pending = true })
            local dirty = spy.on(UIManager, "setDirty")
            -- Same results, still pending: nothing to refresh
            w:updateResults({ a, b }, true)
            assert.spy(dirty).was_not_called()
            -- No more pending: only the counter
            w:updateResults({ a, b }, false)
            assert.spy(dirty).was_called(1)
            UIManager.setDirty:revert()
            assert.are.equal("1 / 2", w.displaynb_text.text)
        end)

        it("should close an opened results menu, which is now stale", function()
            local w = newWindow({ a, b }, { results_pending = true })
            w:onShowResultsMenu()
            local menu = topWidget()
            assert.is_true(w.menu_opened[menu])
            w:updateResults({ a, b, c }, false)
            assert.is_false(UIManager:isWidgetShown(menu))
            assert.is_nil(next(w.menu_opened))
        end)

        it("should go back to the first result if the shown one is gone", function()
            local w = newWindow({ a, b }, { results_pending = true })
            w:onChangeToNextDict()
            assert.are.equal("Beta", w.dictionary)
            w:updateResults({ c, d }, false)
            assert.are.equal(1, w.dict_index)
            assert.are.equal("Gamma", w.dictionary)
            assert.are.equal("1 / 2", w.displaynb)
        end)

        it("should just update the results of a full page Wikipedia window", function()
            local w = newWindow({ result("Wikipedia", "Harbor", "A harbor is...", { is_wiki_fullpage = true }) })
            assert.is_nil(w.displaynb)
            local first = w.results[1]
            local dirty = spy.on(UIManager, "setDirty")
            w:updateResults({ first, result("Wikipedia", "Port") }, false)
            assert.spy(dirty).was_not_called()
            UIManager.setDirty:revert()
            assert.are.equal(1, w.dict_index)
            assert.are.equal(2, #w.results)
        end)
    end)

    describe("closing", function()
        it("should call close_widget_callback however it is closed", function()
            local w = newWindow({ result("Alpha", "harbor") })
            local cb = spy.new(function() end)
            w.close_widget_callback = cb
            UIManager:close(w)
            assert.spy(cb).was_called(1)
            -- (not needed)
            w = newWindow({ result("Alpha", "harbor") })
            UIManager:close(w)
            assert.are.equal(0, #DictQuickLookup.window_list)
        end)

        it("should close with a tap outside, clearing the highlight a bit later", function()
            local highlight = { getClearId = function() return 7 end, clear = spy.new(function() end) }
            local closed = spy.new(function() end)
            local w = newWindow({ result("Alpha", "harbor") }, {
                highlight = highlight,
                dict_close_callback = closed,
                word_boxes = { Geom:new({ x = 10, y = 10, w = 50, h = 20 }) },
            })
            local frame = w.dict_frame.dimen
            local y = frame.y > 5 and 1 or Screen:getHeight() - 1
            w:onTap(nil, tapAt(1, y))
            assert.is_false(UIManager:isWidgetShown(w))
            assert.spy(closed).was_called(1)
            assert.spy(highlight.clear).was_not_called()
            UIManager:shiftScheduledTasksBy(-1e9)
            UIManager:_checkTasks()
            assert.spy(highlight.clear).was_called_with(match.is_ref(highlight), 7)
        end)

        it("should save the highlight if asked to", function()
            local highlight = { saveHighlight = spy.new(function() end), clear = spy.new(function() end) }
            local w = newWindow({ result("Alpha", "harbor") }, { highlight = highlight })
            w.save_highlight = true
            w:onClose()
            assert.spy(highlight.saveHighlight).was_called()
            assert.spy(highlight.clear).was_called()
        end)

        it("should close all the windows, last opened first, on hold", function()
            local order = {}
            local w1 = newWindow({ result("Alpha", "harbor") }, { dict_close_callback = function() table.insert(order, 1) end })
            local w2 = newWindow({ result("Beta", "port") }, { dict_close_callback = function() table.insert(order, 2) end })
            local w3 = newWindow({ result("Gamma", "dock") }, { dict_close_callback = function() table.insert(order, 3) end })
            assert.are.equal(3, #DictQuickLookup.window_list)
            w3.button_table:getButtonById("close").hold_callback()
            assert.are.same({ 3, 2, 1 }, order)
            assert.are.equal(0, #DictQuickLookup.window_list)
            assert.is_false(UIManager:isWidgetShown(w1) or UIManager:isWidgetShown(w2))
        end)

        it("should close with keys, ending a search in the definition first", function()
            local w = newWindow({ result("Alpha", "harbor", "the harbor is a harbor") })
            w:searchInDefinition("harbor")
            assert.is_true(w.in_definition_search)
            w:onCloseWithKeys()
            assert.is_true(UIManager:isWidgetShown(w))
            assert.is_false(w.in_definition_search)
            w:onCloseWithKeys()
            assert.is_false(UIManager:isWidgetShown(w))
        end)
    end)

    describe("definition and input", function()
        it("should find text in the definition, and tell when not found", function()
            local w = newWindow({ result("Alpha", "harbor", "the harbor is a harbor"), result("Beta", "port") })
            w:searchInDefinition("nowhere")
            assert.is_falsy(w.in_definition_search)
            assert.matches("No matches for 'nowhere'", topWidget().text)
            UIManager:close(topWidget())
            w:searchInDefinition("harbor")
            assert.is_true(w.in_definition_search)
            -- taps go to the matches, not to the other results
            local def = w.definition_widget.dimen
            local _, y = center(def)
            w:onTap(nil, tapAt(def.x + def.w - 10, y))
            w:onTap(nil, tapAt(def.x + 10, y))
            assert.are.equal(1, w.dict_index)
            assert.is_true(w:findInDefinitionNextOrPreviousPage(1))
            -- changing result ends the search
            w:changeDictionary(2)
            assert.is_false(w.in_definition_search)
            assert.is_false(w:findInDefinitionNextOrPreviousPage(1))
            w:searchInDefinition(nil) -- (no-op)
        end)

        it("should look up a new word from its input dialog", function()
            local w = newWindow({ result("Alpha", "harbor", "the harbor") })
            w:lookupInputWord("har")
            local dialog = w.input_dialog
            assert.are.equal("har", dialog:getInputText())
            local events = spy.on(readerui, "handleEvent")
            dialog:setInputText("port")
            findButton(dialog.buttons, "Search dictionary").callback()
            assert.is_false(UIManager:isWidgetShown(dialog))
            local ev = events.calls[1].vals[2]
            assert.are.equal("onLookupWord", ev.handler)
            assert.are.same({ "port", true }, { ev.args[1], ev.args[2] })
            readerui.handleEvent:revert()
            assert.is_false(w.is_wiki)

            w:lookupInputWord()
            dialog = w.input_dialog
            dialog:setInputText("harbor")
            findButton(dialog.buttons, "Find in definition").callback()
            assert.is_true(w.in_definition_search)
            w:lookupInputWord()
            findButton(w.input_dialog.buttons, "Cancel").callback()
            assert.is_false(UIManager:isWidgetShown(w.input_dialog))
        end)

        it("should offer a preset search in its input dialog", function()
            local rd = readerui.dictionary
            rd.preset_obj.presets.OnlyBeta = { enabled_dict_names = { Beta = true } }
            local w = newWindow({ result("Alpha", "harbor") })
            w:lookupInputWord("port")
            local preset_button = findButton(w.input_dialog.buttons, "Search with preset")
            assert.truthy(preset_button)
            local load = stub(rd, "loadPreset")
            local events = stub(readerui, "handleEvent")
            preset_button.callback()
            local chooser = topWidget()
            findButton(chooser.buttons, "OnlyBeta").callback()
            assert.stub(load).was_called_with(match.is_ref(rd), rd.preset_obj.presets.OnlyBeta, true)
            local ev = events.calls[#events.calls].vals[2]
            assert.are.equal("onLookupWord", ev.handler)
            assert.are.equal("port", ev.args[1])
            ev.args[6]() -- restores the dictionaries when done
            assert.stub(load).was_called(2)
            readerui.handleEvent:revert()
            rd.loadPreset:revert()
            rd.preset_obj.presets.OnlyBeta = nil
        end)

        it("should show HTML definitions with the dictionary's CSS", function()
            local w = newWindow({
                result("Gamma", "harbor", "<b>harbor</b>", { is_html = true, css = "b { color: red; }" }),
                result("Alpha", "harbor"),
            })
            assert.truthy(w.shw_widget)
            assert.is_true(w.is_html)
            assert.matches("<br/>_______<br/>%(query : harbor%)$", w.definition)
            local css = w:getHtmlDictionaryCss()
            assert.matches("b { color: red; }$", css)
            assert.matches("text%-align: justify;", css)
            G_reader_settings:makeFalse("dict_justify")
            assert.is_nil(w:getHtmlDictionaryCss():find("text-align: justify;", 1, true))
            G_reader_settings:delSetting("dict_justify")
            w:onChangeToNextDict()
            assert.is_false(w.is_html)
            assert.is_nil(w:getHtmlDictionaryCss():find("color: red", 1, true))
        end)
    end)
end)
