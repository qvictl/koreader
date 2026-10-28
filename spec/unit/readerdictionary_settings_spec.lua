-- ReaderDictionary settings and dialogs: the dictionary settings menu (managing, ordering
-- and disabling dictionaries, per-book priority, fuzzy search and progressive lookup
-- toggles, lookup history, buttons customization), presets, the lookup input dialog,
-- HTML dictionary links, external dictionaries, and dictionary downloads (with a fake
-- HTTP server: no network).
describe("ReaderDictionary settings", function()
    local DataStorage, DictQuickLookup, DocumentRegistry, ReaderUI, UIManager, Screen, Device
    local StarDict, ffiUtil, util, logger, lfs
    local RD_MOD = "apps/reader/modules/readerdictionary"
    local readerui, rd, ReaderDictionary
    local tmp, dict_dir

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

    local function findItem(items, text)
        for _, item in ipairs(items) do
            local t = item.text or (item.text_func and item.text_func())
            if t and t:find(text, 1, true) then
                return item
            end
        end
    end

    local function findButton(buttons, text)
        for _, row in ipairs(buttons) do
            for _, button in ipairs(row) do
                if button.text and button.text:find(text, 1, true) then
                    return button
                end
            end
        end
    end

    local function buttonTexts(buttons)
        local t = {}
        for _, row in ipairs(buttons) do
            for _, button in ipairs(row) do
                table.insert(t, button.text)
            end
        end
        return t
    end

    local function settingsMenu(instance)
        local menu_items = {}
        instance:addToMainMenu(menu_items)
        return menu_items, menu_items.dictionary_settings.sub_item_table
    end

    local function ifoFile(name)
        local Mod = ReaderDictionary
        local i = 1
        while true do
            local n, v = debug.getupvalue(Mod.sortAvailableIfos, i)
            assert(n, "no available_ifos")
            if n == "available_ifos" then
                for _, ifo in ipairs(v) do
                    if ifo.name == name then return ifo.file end
                end
                return
            end
            i = i + 1
        end
    end

    local function fakeTouchMenu()
        return { updateItems = spy.new(function() end) }
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        DataStorage = require("datastorage")
        DictQuickLookup = require("ui/widget/dictquicklookup")
        DocumentRegistry = require("document/documentregistry")
        UIManager = require("ui/uimanager")
        Device = require("device")
        Screen = Device.screen
        StarDict = require("stardict_fixture")
        ffiUtil = require("ffi/util")
        util = require("util")
        logger = require("logger")
        lfs = require("libs/libkoreader-lfs")

        tmp = DataStorage:getDataDir() .. "/readerdictionary_settings"
        StarDict.purge(tmp)
        util.makePath(tmp)
        dict_dir = tmp .. "/dict"
        StarDict.write(dict_dir .. "/alpha", "alpha", "Alpha", { harbor = "alpha harbor" })
        StarDict.write(dict_dir .. "/beta", "beta", "Beta", { harbor = "beta harbor", beacon = "beta beacon" })
        StarDict.write(dict_dir .. "/gamma", "gamma", "Gamma", { harbor = "gamma harbor" })

        G_defaults:saveSetting("STARDICT_DATA_DIR", dict_dir)
        G_reader_settings:saveSetting("dicts_order", {})
        G_reader_settings:saveSetting("dicts_disabled", {})
        ReaderUI = require("apps/reader/readerui")
        ReaderDictionary = require(RD_MOD)
        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument("spec/front/unit/data/sample.txt"),
        }
        rd = readerui.dictionary
    end)

    teardown(function()
        closeAll()
        ReaderUI.instance = readerui
        readerui:closeDocument()
        readerui:onClose()
        G_defaults:delSetting("STARDICT_DATA_DIR")
        UIManager:quit()
        UIManager._exit_code = nil
        StarDict.purge(tmp)
    end)

    before_each(function()
        ReaderUI.instance = readerui
        UIManager:show(readerui)
    end)

    after_each(function()
        closeAll()
    end)

    describe("dictionary management", function()
        it("should let the user disable and reorder dictionaries", function()
            local _, items = settingsMenu(rd)
            local manage = findItem(items, "Manage dictionaries")
            assert.are.equal("Manage dictionaries: 3", manage.text_func())
            assert.is_true(manage.enabled_func())
            local touchmenu = fakeTouchMenu()
            manage.callback(touchmenu)
            local sort_widget = topWidget()
            assert.are.equal("Manage installed dictionaries", sort_widget.title)
            local sort_items = sort_widget.item_table
            assert.are.same({ "Alpha", "Beta", "Gamma" }, { sort_items[1].text, sort_items[2].text, sort_items[3].text })
            -- Disable Beta, move Gamma first
            sort_items[2].callback()
            assert.is_false(sort_items[2].checked_func())
            assert.is_true(sort_items[1].checked_func())
            table.insert(sort_items, 1, table.remove(sort_items, 3))
            -- (not saved until accepted)
            assert.are.equal("Manage dictionaries: 3", manage.text_func())
            sort_widget.callback()
            assert.spy(touchmenu.updateItems).was_called()
            assert.are.same({ "Gamma", "Alpha" }, rd.enabled_dict_names)
            assert.are.equal("Manage dictionaries: 2/3", manage.text_func())
            assert.are.same({ [ifoFile("Beta")] = true }, G_reader_settings:readSetting("dicts_disabled"))
            assert.are.same({ [ifoFile("Gamma")] = 1, [ifoFile("Alpha")] = 2, [ifoFile("Beta")] = 3 },
                G_reader_settings:readSetting("dicts_order"))

            -- Back to the initial state
            UIManager:close(sort_widget)
            manage.callback()
            sort_widget = topWidget()
            sort_items = sort_widget.item_table
            assert.are.same({ "Gamma", "Alpha", "Beta" }, { sort_items[1].text, sort_items[2].text, sort_items[3].text })
            sort_items[3].callback() -- re-enable Beta
            table.sort(sort_items, function(a, b) return a.text < b.text end)
            sort_widget.callback()
            assert.are.same({ "Alpha", "Beta", "Gamma" }, rd.enabled_dict_names)
        end)

        it("should let the user prefer or disable dictionaries for this book", function()
            local _, items = settingsMenu(rd)
            local priority = findItem(items, "Set dictionary priority for this book")
            assert.is_true(priority.enabled_func())
            local touchmenu = fakeTouchMenu()
            priority.callback(touchmenu)
            local dialog = topWidget()
            assert.are.same({ "Alpha", "Beta", "Gamma", "Reset" }, buttonTexts(dialog.buttons))

            -- Prefer Gamma, then Beta: they come first, numbered
            findButton(dialog.buttons, "Gamma").callback()
            dialog = topWidget()
            findButton(dialog.buttons, "Beta").callback()
            dialog = topWidget()
            assert.are.same({ "① Gamma", "② Beta", "Alpha", "Reset" }, buttonTexts(dialog.buttons))
            assert.are.same({ "Gamma", "Beta" }, rd.preferred_dictionaries)
            assert.are.same({ "Gamma", "Beta", "Alpha" }, rd.enabled_dict_names)
            assert.are.same({ "Gamma", "Beta" }, readerui.doc_settings:readSetting("preferred_dictionaries"))

            -- Disable Alpha for this book (hold): shown last, crossed
            findButton(dialog.buttons, "Alpha").hold_callback()
            dialog = topWidget()
            assert.are.same({ "① Gamma", "② Beta", "⊗ Alpha", "Reset" }, buttonTexts(dialog.buttons))
            assert.are.same({ Alpha = true }, readerui.doc_settings:readSetting("disabled_dicts"))
            -- (a disabled one can't be preferred)
            findButton(dialog.buttons, "Alpha").callback()
            assert.are.same({ "Gamma", "Beta" }, rd.preferred_dictionaries)
            -- un-prefer Gamma
            findButton(dialog.buttons, "Gamma").callback()
            dialog = topWidget()
            assert.are.same({ "Beta" }, rd.preferred_dictionaries)
            -- Re-enable Alpha
            findButton(dialog.buttons, "Alpha").hold_callback()
            dialog = topWidget()
            assert.are.same({}, rd.doc_disabled_dicts)

            findButton(dialog.buttons, "Reset").callback()
            dialog = topWidget()
            assert.are.same({}, rd.preferred_dictionaries)
            assert.are.same({ "Alpha", "Beta", "Gamma" }, rd.enabled_dict_names)
            assert.is_nil(readerui.doc_settings:readSetting("preferred_dictionaries"))
            UIManager:close(dialog)
        end)

        it("should close the priority dialog when un-preferring the only usable dictionary", function()
            local all_disabled = { [ifoFile("Alpha")] = true, [ifoFile("Beta")] = true, [ifoFile("Gamma")] = true }
            G_reader_settings:saveSetting("dicts_disabled", all_disabled)
            rd.preferred_dictionaries = { "Beta" }
            rd:updateSdcvDictNamesOptions()
            assert.are.same({ "Beta" }, rd.enabled_dict_names)
            local touchmenu = fakeTouchMenu()
            rd:showPreferredDictsDialog(touchmenu)
            local dialog = topWidget()
            findButton(dialog.buttons, "Beta").callback()
            assert.spy(touchmenu.updateItems).was_called()
            assert.is_false(UIManager:isWidgetShown(dialog))
            assert.is_not.equal(dialog, topWidget())
            G_reader_settings:saveSetting("dicts_disabled", {})
            rd:updateSdcvDictNamesOptions()
        end)

        it("should toggle a preferred dictionary from the dictionary window title", function()
            rd:onTogglePreferredDict("Gamma")
            assert.are.same({ "Gamma" }, rd.preferred_dictionaries)
            assert.matches("now the preferred dictionary", topWidget().text)
            rd:onTogglePreferredDict("Beta")
            assert.are.same({ "Beta", "Gamma" }, rd.preferred_dictionaries)
            assert.are.same({ "Beta", "Gamma", "Alpha" }, rd.enabled_dict_names)
            rd:onTogglePreferredDict("Gamma")
            assert.matches("no longer a preferred dictionary", topWidget().text)
            rd:onTogglePreferredDict("Beta")
            assert.are.same({}, rd.preferred_dictionaries)
            -- From the file manager: nothing to do
            local fm_rd = { preferred_dictionaries = nil }
            assert.is_true(ReaderDictionary.onTogglePreferredDict(fm_rd, "Beta"))
        end)

        it("should read the book settings, migrating the legacy default dictionary", function()
            local LuaSettings = require("luasettings")
            local config = LuaSettings:open(tmp .. "/book_settings.lua")
            config:saveSetting("default_dictionary", "Gamma")
            config:saveSetting("disable_fuzzy_search", true)
            config:saveSetting("disabled_dicts", { Alpha = true })
            local saved = { rd.preferred_dictionaries, rd.disable_fuzzy_search, rd.doc_disabled_dicts }
            rd:onReadSettings(config)
            assert.are.same({ "Gamma" }, rd.preferred_dictionaries)
            assert.is_nil(config:readSetting("default_dictionary"))
            assert.are.equal("Gamma", rd.enabled_dict_names[1])
            assert.is_true(rd.disable_fuzzy_search)
            assert.are.same({ Alpha = true }, rd.doc_disabled_dicts)
            -- Without a book setting, the global default is used
            G_reader_settings:makeTrue("disable_fuzzy_search")
            rd:onReadSettings(LuaSettings:open(tmp .. "/other_book_settings.lua"))
            assert.is_true(rd.disable_fuzzy_search)
            assert.are.same({}, rd.preferred_dictionaries)
            G_reader_settings:delSetting("disable_fuzzy_search")
            rd.preferred_dictionaries, rd.disable_fuzzy_search, rd.doc_disabled_dicts = saved[1], saved[2], saved[3]
            rd.preferred_dictionaries = {}
            rd:updateSdcvDictNamesOptions()
        end)
    end)

    describe("lookup settings", function()
        it("should toggle fuzzy search for this book, and set its default", function()
            local _, items = settingsMenu(rd)
            local fuzzy = findItem(items, "Enable fuzzy search")
            rd.disable_fuzzy_search = false
            assert.are.equal("Enable fuzzy search   ★", fuzzy.text_func())
            assert.is_true(fuzzy.checked_func())
            fuzzy.callback()
            assert.is_false(fuzzy.checked_func())
            assert.is_true(readerui.doc_settings:isTrue("disable_fuzzy_search"))
            fuzzy.callback()
            assert.is_true(fuzzy.checked_func())

            local touchmenu = fakeTouchMenu()
            fuzzy.hold_callback(touchmenu)
            local box = topWidget()
            assert.matches("The current default %(★%) is enabled", box.text)
            box.choice1_callback() -- Disable
            assert.is_true(G_reader_settings:isTrue("disable_fuzzy_search"))
            assert.spy(touchmenu.updateItems).was_called()
            assert.are.equal("Enable fuzzy search", fuzzy.text_func())
            UIManager:close(box)
            fuzzy.hold_callback(touchmenu)
            box = topWidget()
            assert.matches("The current default %(★%) is disabled", box.text)
            assert.are.equal("Disable (★)", box.choice1_text_func())
            assert.are.equal("Enable", box.choice2_text_func())
            box.choice2_callback() -- Enable
            assert.is_false(G_reader_settings:isTrue("disable_fuzzy_search"))
            UIManager:close(box)
        end)

        it("should toggle fuzzy search globally in the file manager", function()
            local fm_rd = ReaderDictionary:new{ ui = { menu = { registerToMainMenu = function() end } } }
            local menu_items, items = settingsMenu(fm_rd)
            assert.is_nil(findItem(items, "Set dictionary priority for this book"))
            assert.truthy(menu_items.dictionary_lookup)
            local fuzzy = findItem(items, "Enable fuzzy search")
            assert.is_true(fuzzy.checked_func())
            fuzzy.callback()
            assert.is_false(fuzzy.checked_func())
            assert.is_true(fm_rd.disable_fuzzy_search_fm)
            -- (the lookup uses it)
            local lookup = stub(fm_rd, "stardictLookup")
            fm_rd:onLookupWord("Harbor,")
            -- wait for the Trapper coroutine to run
            assert.stub(lookup).was_called_with(match.is_ref(fm_rd), "Harbor", fm_rd.enabled_dict_names, false,
                nil, nil, nil)
            fm_rd.stardictLookup:revert()
        end)

        it("should toggle the progressive lookup", function()
            local _, items = settingsMenu(rd)
            local progressive = findItem(items, "Progressive lookup")
            G_reader_settings:delSetting("dict_progressive_lookup")
            assert.matches("first dictionary alone", progressive.help_text)
            assert.is_true(progressive.checked_func())
            progressive.callback()
            assert.is_false(progressive.checked_func())
            assert.is_false(G_reader_settings:nilOrTrue("dict_progressive_lookup"))
            progressive.callback()
            assert.is_true(progressive.checked_func())
        end)

        it("should toggle and clean the lookup history", function()
            local menu_items, items = settingsMenu(rd)
            local history = findItem(items, "Dictionary lookup history")
            local enable = findItem(history.sub_item_table, "Enable dictionary lookup history")
            local clean = findItem(history.sub_item_table, "Clean dictionary lookup history")
            rd.disable_lookup_history = false
            assert.is_true(history.checked_func())
            enable.callback()
            assert.is_false(enable.checked_func())
            assert.is_true(G_reader_settings:isTrue("disable_lookup_history"))
            enable.callback()
            assert.is_true(enable.checked_func())

            -- Add an entry (as a lookup does)
            stub(rd, "showLookupInfo")
            stub(rd, "startProgressiveSdcv", function() return { { dict = "Alpha", word = "harbor", definition = "x" } } end)
            rd:stardictLookup("harbor", rd.enabled_dict_names, true)
            rd.showLookupInfo:revert()
            rd.startProgressiveSdcv:revert()
            UIManager:shiftScheduledTasksBy(-1e9)
            UIManager:_checkTasks()
            assert.is_true(clean.enabled_func())
            assert.is_true(menu_items.dictionary_lookup_history.enabled_func())
            local touchmenu = fakeTouchMenu()
            clean.callback(touchmenu)
            local box = topWidget()
            assert.are.equal("Clean dictionary lookup history?", box.text)
            box.ok_callback()
            assert.spy(touchmenu.updateItems).was_called()
            assert.is_false(clean.enabled_func())
            assert.is_false(menu_items.dictionary_lookup_history.enabled_func())
        end)

        it("should toggle the dictionary window settings", function()
            local _, items = settingsMenu(rd)
            local large = findItem(items, "Large window")
            local justify = findItem(items, "Justify text")
            assert.is_false(large.checked_func())
            large.callback()
            assert.is_true(large.checked_func())
            large.callback()
            assert.is_true(justify.checked_func())
            justify.callback()
            assert.is_false(justify.checked_func())
            justify.callback()

            local font = findItem(items, "Font size")
            assert.are.equal("Font size: 20", font.text_func())
            local touchmenu = fakeTouchMenu()
            font.callback(touchmenu)
            local spin = topWidget()
            assert.are.equal(20, spin.value)
            spin.callback({ value = 24 })
            assert.are.equal(24, G_reader_settings:readSetting("dict_font_size"))
            assert.are.equal("Font size: 24", font.text_func())
            assert.spy(touchmenu.updateItems).was_called()
            G_reader_settings:delSetting("dict_font_size")
        end)

        it("should use an external dictionary when the device has some and it is enabled", function()
            local list = { { "app1", "Dict App", true }, { "app2", "Other App", false } }
            stub(Device, "canExternalDictLookup", function() return true end)
            stub(Device, "getExternalDictLookupList", function() return list end)
            local ext_lookup = stub(Device, "doExternalDictLookup")
            local _, items = settingsMenu(rd)
            local use = items[1]
            local which = items[2]
            assert.are.equal("Use external dictionary", use.text)
            assert.is_false(use.checked_func())
            assert.is_false(which.enabled_func())
            use.callback()
            assert.is_true(use.checked_func())
            assert.is_true(which.enabled_func())
            assert.are.equal("Dictionary: none", which.text_func())
            local app1, app2 = which.sub_item_table[1], which.sub_item_table[2]
            assert.are.equal("Dict App", app1.text)
            assert.is_true(app1.enabled_func())
            assert.is_false(app2.enabled_func())
            app1.callback()
            assert.is_true(app1.checked_func())
            assert.is_false(app2.checked_func())
            assert.are.equal("Dictionary: Dict App", which.text_func())

            -- A lookup now goes to the external app, sdcv is not used
            local run = spy.on(rd, "runSdcv")
            local highlight = { getClearId = function() return 42 end, clear = spy.new(function() end) }
            local closed = spy.new(function() end)
            rd.highlight = highlight
            rd:stardictLookup("harbor", rd.enabled_dict_names, true, nil, nil, closed)
            assert.spy(run).was_not_called()
            rd.runSdcv:revert()
            assert.stub(ext_lookup).was_called_with(match.is_ref(Device), "harbor", "app1", match.is_function())
            -- When the external lookup is done
            ext_lookup.calls[1].vals[4]()
            assert.spy(closed).was_called()
            UIManager:shiftScheduledTasksBy(-1e9)
            UIManager:_checkTasks()
            assert.spy(highlight.clear).was_called_with(match.is_ref(highlight), 42)
            rd.highlight = nil

            use.callback()
            G_reader_settings:delSetting("external_dict_lookup_method")
            Device.canExternalDictLookup:revert()
            Device.getExternalDictLookupList:revert()
            Device.doExternalDictLookup:revert()
        end)
    end)

    describe("buttons customization", function()
        after_each(function()
            G_reader_settings:delSetting("dict_button_config")
        end)

        it("should let the user toggle, sort and lay out the buttons", function()
            local menu = rd:_genCustomizeButtonsMenu()
            local sort_item = findItem(menu, "Sort and toggle buttons")
            assert.truthy(findItem(menu, "Max buttons in row 1: 3"))
            assert.truthy(findItem(menu, "Max buttons in row 2: 3"))
            local touchmenu = fakeTouchMenu()
            sort_item.callback(touchmenu)
            local sort_widget = topWidget()
            local by_id = {}
            for _, item in ipairs(sort_widget.item_table) do
                by_id[item.id] = item
            end
            assert.is_true(by_id.prev_dict.checked_func())
            assert.is_falsy(by_id.translate.checked_func())
            by_id.translate.callback() -- enable Translate
            by_id.wikipedia.callback() -- disable Wikipedia
            sort_widget.callback()
            assert.spy(touchmenu.updateItems).was_called()
            local config = G_reader_settings:readSetting("dict_button_config")
            assert.are.same({ { "prev_dict", "highlight", "next_dict" }, { "search", "close", "translate" } }, config.layout)

            -- Only 2 buttons in row 1
            local row1 = findItem(menu, "Max buttons in row 1: 3")
            row1.callback(touchmenu)
            local spin = topWidget()
            spin.callback({ value = 2 })
            config = G_reader_settings:readSetting("dict_button_config")
            assert.are.same({ { "prev_dict", "highlight" }, { "next_dict", "search", "close" }, { "translate" } }, config.layout)
            assert.truthy(findItem(menu, "Max buttons in row 3: 3"))
            UIManager:close(spin)

            -- Preview
            findItem(menu, "Test button layout").callback()
            local preview = rd.dict_window
            assert.are.equal("Layout preview", preview.results[1].dict)
            assert.is_true(UIManager:isWidgetShown(preview))
            UIManager:close(preview)

            -- Reset (hold)
            sort_item.hold_callback(touchmenu)
            local box = topWidget()
            box.ok_callback()
            assert.is_nil(G_reader_settings:readSetting("dict_button_config"))
            assert.truthy(findItem(menu, "Max buttons in row 2: 3"))
            assert.is_nil(findItem(menu, "Max buttons in row 3"))
        end)

        it("should offer plugins buttons", function()
            local warn = spy.on(logger, "warn")
            rd:addToDictButtons("not a table")
            rd:addToDictButtons({ id = 42 })
            assert.spy(warn).was_called(2)
            logger.warn:revert()
            rd:addToDictButtons({ id = "zz_plugin", menu_text = "My plugin", insert_first = true })
            rd:addToDictButtons({ id = "zz_cond", conditional = true })
            local menu = rd:_genCustomizeButtonsMenu()
            assert.are.same({ "zz_plugin" }, rd.default_layout[1])
            findItem(menu, "Sort and toggle buttons").callback()
            local sort_widget = topWidget()
            local ids = {}
            for _, item in ipairs(sort_widget.item_table) do
                ids[item.id] = item.text
            end
            assert.are.equal("My plugin", ids.zz_plugin)
            assert.is_nil(ids.zz_cond)
            rd._dict_buttons = {}
            table.remove(rd.default_layout, 1)
        end)
    end)

    describe("presets", function()
        after_each(function()
            for k in pairs(rd.preset_obj.presets) do
                rd.preset_obj.presets[k] = nil
            end
            G_reader_settings:saveSetting("dicts_disabled", {})
            rd.dicts_disabled = G_reader_settings:readSetting("dicts_disabled")
            rd:updateSdcvDictNamesOptions()
        end)

        it("should build and load presets, telling about missing dictionaries", function()
            local preset = rd:buildPreset()
            assert.are.same({ enabled_dict_names = { Alpha = true, Beta = true, Gamma = true } }, preset)
            rd:loadPreset({ enabled_dict_names = { Beta = true } })
            assert.are.same({ "Beta" }, rd.enabled_dict_names)
            assert.are.same({ [ifoFile("Alpha")] = true, [ifoFile("Gamma")] = true },
                G_reader_settings:readSetting("dicts_disabled"))
            assert.are.equal(1, select(2, rd:getNumberOfDictionaries()))
            rd:loadPreset({ enabled_dict_names = { Gamma = true, Deleted = true } })
            assert.are.same({ "Gamma" }, rd.enabled_dict_names)
            assert.matches("no longer available:\n\n• Deleted", topWidget().text)
            -- (an invalid preset is ignored)
            rd:loadPreset({})
            assert.are.same({ "Gamma" }, rd.enabled_dict_names)
        end)

        it("should cycle through presets", function()
            rd.preset_obj.presets.First = { enabled_dict_names = { Alpha = true } }
            rd.preset_obj.presets.Second = { enabled_dict_names = { Beta = true, Gamma = true } }
            assert.are.same({ "First", "Second" }, ReaderDictionary.getPresets())
            rd.preset_obj.cycle_index = nil
            rd:onCycleDictionaryPresets()
            assert.are.same({ "Alpha" }, rd.enabled_dict_names)
            rd:onCycleDictionaryPresets()
            assert.are.same({ "Beta", "Gamma" }, rd.enabled_dict_names)
            assert.are.equal(2, G_reader_settings:readSetting("dict_presets_cycle_index"))
            rd:onCycleDictionaryPresets()
            assert.are.same({ "Alpha" }, rd.enabled_dict_names)
            rd:onLoadDictionaryPreset("Second")
            assert.are.same({ "Beta", "Gamma" }, rd.enabled_dict_names)
            G_reader_settings:delSetting("dict_presets_cycle_index")
        end)

        it("should offer the presets in the presets menu", function()
            local _, items = settingsMenu(rd)
            local presets_item = findItem(items, "Dictionary presets")
            local sub_items = presets_item.sub_item_table_func()
            assert.truthy(findItem(sub_items, "Create new preset from enabled dictionaries"))
        end)

        it("should look up with a preset, and restore the dictionaries afterwards", function()
            rd.preset_obj.presets.OnlyBeta = { enabled_dict_names = { Beta = true } }
            local lookup = stub(rd, "onLookupWord")
            rd:onShowDictionaryLookup("harbor")
            local input = rd.dictionary_lookup_dialog
            assert.are.equal("harbor", input:getInputText())
            findButton(input.buttons, "Search with preset").callback()
            local chooser = topWidget()
            assert.are.same({ "OnlyBeta" }, buttonTexts(chooser.buttons))
            findButton(chooser.buttons, "OnlyBeta").callback()
            assert.is_false(UIManager:isWidgetShown(chooser))
            assert.is_false(UIManager:isWidgetShown(input))
            assert.are.same({ "Beta" }, rd.enabled_dict_names)
            assert.stub(lookup).was_called(1)
            local args = lookup.calls[1].vals
            assert.are.equal("harbor", args[2])
            -- closing the dictionary window restores the previous dictionaries
            args[7]()
            assert.are.same({ "Alpha", "Beta", "Gamma" }, rd.enabled_dict_names)
            rd.onLookupWord:revert()
        end)

        it("should offer a preset search when nothing is found", function()
            rd.preset_obj.presets.OnlyBeta = { enabled_dict_names = { Beta = true } }
            -- fuzzy search already done: the preset search is the main action
            assert.is_true(rd:showNoResultsDialog("harbr", rd.enabled_dict_names, true, nil, nil, nil, function() end))
            local dialog = topWidget()
            assert.are.equal("Would you like to search with a preset?", dialog.description)
            assert.are.same({ "Cancel", "Search with preset" }, buttonTexts(dialog.buttons))
            local show_presets = stub(rd, "showSearchWithPresetDialog")
            findButton(dialog.buttons, "Search with preset").callback()
            assert.stub(show_presets).was_called()
            rd.showSearchWithPresetDialog:revert()
            UIManager:close(dialog)
            -- exact search: fuzzy search first, preset search too
            assert.is_true(rd:showNoResultsDialog("harbr", rd.enabled_dict_names, false, nil, nil, nil, function() end))
            dialog = topWidget()
            assert.are.same({ "Search with preset", "Cancel", "Fuzzy search" }, buttonTexts(dialog.buttons))
            UIManager:close(dialog)
        end)
    end)

    describe("lookup dialog and links", function()
        it("should look up the entered text as is", function()
            local lookup = stub(rd, "onLookupWord")
            rd:onShowDictionaryLookup()
            local input = rd.dictionary_lookup_dialog
            local search = findButton(input.buttons, "Search dictionary")
            search.callback() -- empty: nothing
            assert.stub(lookup).was_not_called()
            input:setInputText("-suffix")
            search.callback()
            assert.stub(lookup).was_called_with(match.is_ref(rd), "-suffix", true)
            assert.is_false(UIManager:isWidgetShown(input))
            rd.onLookupWord:revert()
            rd:onShowDictionaryLookup("x")
            findButton(rd.dictionary_lookup_dialog.buttons, "Cancel").callback()
            assert.is_false(UIManager:isWidgetShown(rd.dictionary_lookup_dialog))
        end)

        it("should look up words from HTML dictionary links", function()
            local lookup = stub(rd, "stardictLookup")
            local link = { x0 = 10, y0 = 20, x1 = 50, y1 = 30 }
            link.uri = "bword://harbor"
            rd:onHtmlDictionaryLinkTapped("Gamma", link)
            assert.stub(lookup).was_called(1)
            local args = lookup.calls[1].vals
            assert.are.equal("harbor", args[2])
            assert.are.same({ "Gamma" }, args[3])
            assert.is_false(args[4])
            assert.are.same({ x = 10, y = 20, w = 40, h = 10 }, { x = args[5][1].x, y = args[5][1].y, w = args[5][1].w, h = args[5][1].h })
            link.uri = "beacon"
            rd:onHtmlDictionaryLinkTapped("Gamma", link)
            assert.are.equal("beacon", lookup.calls[2].vals[2])
            -- ignored: other protocols, empty words, no uri
            link.uri = "https://example.com/harbor"
            rd:onHtmlDictionaryLinkTapped("Gamma", link)
            link.uri = "bword://"
            rd:onHtmlDictionaryLinkTapped("Gamma", link)
            link.uri = nil
            rd:onHtmlDictionaryLinkTapped("Gamma", link)
            assert.stub(lookup).was_called(2)
            rd.stardictLookup:revert()
        end)

        it("should not refresh the 'Searching...' message when hidden by the dictionary window", function()
            local Geom = require("ui/geometry")
            local results = { { dict = "Alpha", word = "harbor", definition = "alpha harbor" } }
            stub(DictQuickLookup, "getInitialVisibleArea", function() return Geom:new({ x = 0, y = 100, w = 600, h = 400 }) end)
            -- Still invisible (lookup quicker than its show_delay): nothing to care about
            rd:showLookupInfo("harbor", 10)
            local msg = rd.lookup_progress_msg
            rd:showDict("harbor", results)
            assert.is_nil(msg.no_refresh_on_close)
            assert.is_false(UIManager:isWidgetShown(msg))
            -- Shown, and hidden by the dictionary window
            rd:showLookupInfo("harbor", 0)
            msg = rd.lookup_progress_msg
            stub(msg, "getVisibleArea", function() return Geom:new({ x = 100, y = 200, w = 300, h = 100 }) end)
            rd:showDict("harbor", results)
            assert.is_true(msg.no_refresh_on_close)
            assert.is_nil(rd.lookup_progress_msg)
            assert.is_false(UIManager:isWidgetShown(msg))
            -- Shown, and not entirely hidden
            rd:showLookupInfo("harbor", 0)
            msg = rd.lookup_progress_msg
            stub(msg, "getVisibleArea", function() return Geom:new({ x = 100, y = 50, w = 300, h = 100 }) end)
            rd:showDict("harbor", results)
            assert.is_nil(msg.no_refresh_on_close)
            DictQuickLookup.getInitialVisibleArea:revert()
        end)
    end)

    describe("downloads", function()
        local socket, orig_http
        local http_responses
        local archive

        local function fakeRequest(reqt)
            local resp = table.remove(http_responses, 1)
            assert(resp, "unexpected request")
            assert.are.equal(resp.method, reqt.method)
            if resp.body and reqt.sink then
                reqt.sink(resp.body)
                reqt.sink(nil)
            end
            return 1, resp.code, resp.headers, resp.status
        end

        setup(function()
            socket = require("socket")
            require("socket.http")
            orig_http = socket.http
            -- A dictionary archive to "download"
            local src = tmp .. "/archive_src"
            StarDict.write(src .. "/delta", "delta", "Delta", { harbor = "delta harbor" })
            archive = tmp .. "/delta.tar.gz"
            os.execute("cd '" .. src .. "' && tar czf '" .. archive .. "' delta")
        end)

        before_each(function()
            socket.http = { request = fakeRequest }
            http_responses = {}
        end)

        after_each(function()
            socket.http = orig_http
        end)

        local function readFile(path)
            local f = assert(io.open(path, "rb"))
            local content = f:read("*a")
            f:close()
            return content
        end

        local dict = { name = "Delta: l'édition", url = "https://example.com/dl/delta.tar.gz", ifo_lang = "en-de",
                       lang_in = "English", lang_out = "German", entries = 1, license = "MIT" }

        it("should download, extract and add a dictionary", function()
            http_responses = {
                { method = "HEAD", code = 200, headers = { ["content-length"] = "2048" } },
                { method = "GET", code = 200, headers = {}, body = readFile(archive) },
            }
            rd:downloadDictionary(dict)
            local box = topWidget()
            assert.matches("Dictionary filesize is 2%.0 kB", box.text)
            box.ok_callback()
            assert.are.equal(0, #http_responses)
            assert.are.equal("Dictionary downloaded", topWidget().text)
            local dict_ifo = dict_dir .. "/" .. util.getSafeFilename(dict.name, ffiUtil.realpath(dict_dir)) .. "/delta.ifo"
            assert.are.equal("file", lfs.attributes(dict_ifo, "mode"))
            assert.matches("\nlang=en%-de$", readFile(dict_ifo))
            -- (the archive is removed)
            assert.is_nil(lfs.attributes(dict_dir .. "/delta.tar.gz"))
            -- Now available (and enabled): last, as the user has ordered the others (in the first test)
            assert.are.same({ "Alpha", "Beta", "Gamma", "Delta" }, rd.enabled_dict_names)
            assert.are.equal(4, rd:getNumberOfDictionaries())

            -- Downloading it again replaces it
            http_responses = {
                { method = "HEAD", code = 200, headers = { ["content-length"] = "2048" } },
                { method = "GET", code = 200, headers = {}, body = readFile(archive) },
            }
            rd:downloadDictionary(dict)
            topWidget().ok_callback()
            assert.are.equal("Dictionary downloaded", topWidget().text)
            assert.are.equal(4, rd:getNumberOfDictionaries())
        end)

        it("should tell about failed requests", function()
            http_responses = { { method = "HEAD", code = 404, headers = {}, status = "HTTP/1.1 404 Not Found" } }
            rd:downloadDictionary(dict)
            assert.matches("Download failed:\n\n.*404 Not Found", topWidget().text)
            UIManager:close(topWidget())
            -- no size: nothing done
            http_responses = { { method = "HEAD", code = 200, headers = {} } }
            rd:downloadDictionary(dict)
            assert.are.equal(0, #http_responses)
            -- GET failure
            http_responses = {
                { method = "HEAD", code = 200, headers = { ["content-length"] = "10" } },
                { method = "GET", code = "timeout" },
            }
            rd:downloadDictionary(dict)
            topWidget().ok_callback()
            assert.matches("Download failed:\n\n.*timeout", topWidget().text)
        end)

        it("should do nothing more when the user cancels", function()
            http_responses = { { method = "HEAD", code = 200, headers = { ["content-length"] = "10" } } }
            rd:downloadDictionary(dict)
            topWidget().cancel_callback()
            assert.are.equal(0, #http_responses)
        end)

        it("should tell about extraction failures", function()
            http_responses = {
                { method = "HEAD", code = 200, headers = { ["content-length"] = "10" } },
                { method = "GET", code = 200, headers = {}, body = "this is not an archive" },
            }
            local bad = { name = "Broken", url = "https://example.com/dl/broken.tar.gz" }
            rd:downloadDictionary(bad)
            topWidget().ok_callback()
            assert.matches("Extraction failed", topWidget().text)
            assert.is_nil(lfs.attributes(dict_dir .. "/Broken"))
        end)

        it("should list the downloadable dictionaries by language", function()
            local menu = rd:_genDownloadDictionariesMenu()
            assert.is_true(#menu > 10)
            local english = findItem(menu, "English")
            assert.truthy(english)
            -- sorted, no duplicates
            for i = 2, #menu do
                assert.is_true(menu[i - 1].text < menu[i].text)
            end
            english.callback()
            local list = rd.dl_dict_list
            local all = #list.item_table
            local names = {}
            for _, item in ipairs(list.item_table) do
                assert.is_nil(names[item.text])
                names[item.text] = true
            end
            -- Filter: monolingual, then bilingual
            list.onLeftButtonTap()
            local selector = topWidget()
            selector.callback(true)
            local mono = #list.item_table
            selector.callback(false)
            local bi = #list.item_table
            assert.are.equal(all, mono + bi)
            assert.is_true(mono > 0 and bi > 0)
            assert.matches("\u{F0B0}$", list.title_bar.subtitle_widget.text)
            UIManager:close(selector)

            -- Tap: details, and download when online
            local item = list.item_table[1]
            local when_online = stub(require("ui/network/manager"), "runWhenOnline", function(_, cb) cb() end)
            local download = stub(rd, "downloadDictionary")
            list:onMenuSelect(item)
            local box = topWidget()
            assert.matches("License:", box.text)
            box.ok_callback()
            assert.stub(download).was_called_with(match.is_ref(rd), item.dict)
            rd.downloadDictionary:revert()
            when_online:revert()
        end)
    end)
end)
