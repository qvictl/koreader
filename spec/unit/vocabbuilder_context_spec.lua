-- Real vocabulary SQLite writes with synthetic book/definition lookups; no dictionary process.
describe("Vocabulary lookup context provenance", function()
    local DataStorage, LuaSettings, SQ3, DB, VocabBuilder, ReaderDictionary, DictQuickLookup, Trapper
    local saved_settings, saved_path, saved_db, saved_wiki, saved_dir, root, owns_root
    local settings, plugin, dictionary, ui, context_calls, UIManager, restores, stack_size
    local function override(object, key, value)
        local original = rawget(object, key)
        restores[#restores + 1] = function() object[key] = original end
        object[key] = value
    end
    local function button(widget, text)
        for _, row in ipairs(widget.buttons) do
            for _, entry in ipairs(row) do if entry.text == text then return entry end end
        end
        error("missing button " .. text)
    end
    local function topWidget()
        return UIManager._window_stack[#UIManager._window_stack].widget
    end

    setup(function()
        require("commonrequire")
        DataStorage = require("datastorage")
        LuaSettings = require("luasettings")
        SQ3 = require("lua-ljsqlite3/init")
        ReaderDictionary = require("apps/reader/modules/readerdictionary")
        DictQuickLookup = require("ui/widget/dictquicklookup")
        Trapper = require("ui/trapper")
        UIManager = require("ui/uimanager")
        saved_settings, saved_path, saved_db = _G.G_reader_settings, package.path, package.loaded.db
        saved_wiki = package.loaded["apps/reader/modules/readerwikipedia"]
        saved_dir = DataStorage.getSettingsDir
        root = DataStorage:getDataDir() .. "/vocab-context-spec"
        local lfs = require("libs/libkoreader-lfs")
        assert.is_nil(lfs.attributes(root), "private fixture already exists")
        assert(lfs.mkdir(root))
        owns_root = true
        _G.G_reader_settings = LuaSettings:open(root .. "/settings.lua")
        settings = { enabled = true, with_context = true }
        _G.G_reader_settings:saveSetting("vocabulary_builder", settings)
        DataStorage.getSettingsDir = function() return root end
        package.path = "plugins/vocabbuilder.koplugin/?.lua;" .. package.path
        package.loaded.db = nil
        local ok, err = pcall(function()
            DB = require("db")
            VocabBuilder = dofile("plugins/vocabbuilder.koplugin/main.lua")
        end)
        DataStorage.getSettingsDir = saved_dir
        assert(ok, err)
    end)

    teardown(function()
        DataStorage.getSettingsDir = saved_dir
        _G.G_reader_settings, package.path, package.loaded.db = saved_settings, saved_path, saved_db
        package.loaded["apps/reader/modules/readerwikipedia"] = saved_wiki
        if owns_root then
            for _, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do
                os.remove(root .. "/vocabulary_builder.sqlite3" .. suffix)
            end
            assert(require("libs/libkoreader-lfs").rmdir(root))
        end
    end)

    before_each(function()
        restores, stack_size = {}, #UIManager._window_stack
        local conn = SQ3.open(root .. "/vocabulary_builder.sqlite3")
        conn:exec("DELETE FROM vocabulary; DELETE FROM title;")
        conn:close()
        settings.enabled, settings.with_context = true, true
        context_calls = 0
        ui = { doc_props = { display_title = "Synthetic book" }, highlight = {
            selected_text = { text = "migrated" },
            getSelectedWordContext = function()
                context_calls = context_calls + 1
                return "He ", " to America."
            end,
        } }
        plugin = setmetatable({ ui = ui }, { __index = VocabBuilder })
        dictionary = setmetatable({ ui = ui, enabled_dict_names = {}, disable_lookup_history = true,
            showDict = function() end, preset_obj = { presets = {} },
            default_layout = { { "close" } }, _dict_buttons = {},
            addToDictButtons = function(_, entry) if entry.id == "vocabulary" then ui.vocab_button = entry end end }, { __index = ReaderDictionary })
        ui.dictionary = dictionary
        ui.handleEvent = function(_, event)
            if event.handler == "onLookupWord" then
                return dictionary:onLookupWord(unpack(event.args, 1, event.args.n))
            elseif event.handler == "onWordLookedUp" then
                return plugin:onWordLookedUp(unpack(event.args, 1, event.args.n))
            end
        end
        override(Trapper, "wrap", function(_, callback) return callback() end)
        override(require("device"), "canExternalDictLookup", function() return false end)
        override(DictQuickLookup, "temp_large_window_request", nil)
    end)

    after_each(function()
        local ok, err = pcall(function()
            while #UIManager._window_stack > stack_size do UIManager:close(topWidget()) end
        end)
        for i = #restores, 1, -1 do restores[i]() end
        assert(ok, err)
    end)

    local function popup(from_definition)
        return setmetatable({ ui = ui, from_definition = from_definition, word = "migrated",
            lookupword = "migrated", width = require("device").screen:scaleBySize(500), menu_scrolled_offsets = {}, menu_opened = {} }, { __index = DictQuickLookup })
    end

    it("does not attach the book selection to a nested definition word", function()
        popup():lookupDictionaryOrWikipedia("geological")
        local item = assert(DB:hasWord("geological"))
        assert.is_nil(item.prev_context)
        assert.is_nil(item.next_context)
        assert.is_nil(item.highlight)
        assert.equals(0, context_calls)
    end)

    it("preserves original book context when the lookup stem differs", function()
        dictionary:onLookupWord("migrate", true)
        local item = assert(DB:hasWord("migrate"))
        assert.equals("He ", item.prev_context)
        assert.equals(" to America.", item.next_context)
        assert.equals("migrated", item.highlight)
        assert.equals(1, context_calls)
    end)
    it("does not confuse an identical word in the definition with a book selection", function()
        popup():lookupDictionaryOrWikipedia("migrated")
        local item = assert(DB:hasWord("migrated"))
        assert.is_nil(item.prev_context)
        assert.equals(0, context_calls)
        assert.equals("Synthetic book", item.book_title)
    end)

    for _, origin in ipairs({ false, true }) do
        it("preserves provenance through editing a popup: " .. tostring(origin), function()
            local window = popup(origin)
            window:lookupInputWord("migrate")
            button(window.input_dialog, "Search dictionary").callback()
            local item = assert(DB:hasWord("migrate"))
            assert.equals(origin and 0 or 1, context_calls)
            if origin then assert.is_nil(item.highlight) else assert.equals("migrated", item.highlight) end
        end)

        it("passes the popup origin through a manual add: " .. tostring(origin), function()
            settings.enabled = false
            plugin:registerDictButtons()
            local window = popup(origin)
            window.lookupword = "manual"
            window.button_table = { button_by_id = { vocabulary = { setText = function() end } } }
            override(UIManager, "setDirty", function() end)
            ui.vocab_button.callback(window)
            local item = assert(DB:hasWord("manual"))
            assert.equals(origin and 0 or 1, context_calls)
            if origin then assert.is_nil(item.highlight) else assert.equals("migrated", item.highlight) end
            assert.equals("Synthetic book", item.book_title)
        end)

        it("preserves provenance through dictionary resizing: " .. tostring(origin), function()
            popup(origin):setTemporaryLargeWindowMode()
            assert.equals(origin and 0 or 1, context_calls)
        end)

        it("preserves provenance through a fuzzy retry: " .. tostring(origin), function()
            dictionary:showNoResultsDialog("fuzzy", {}, false, nil, nil, nil, function() end, origin)
            local dialog = topWidget()
            button(dialog, "Fuzzy search").callback(dialog)
            assert.is_not_nil(DB:hasWord("fuzzy"))
            assert.equals(origin and 0 or 1, context_calls)
        end)

        it("preserves provenance through a preset retry: " .. tostring(origin), function()
            dictionary.preset_obj.presets.One = {}
            dictionary.buildPreset = function() return {} end
            dictionary.loadPreset = function() end
            dictionary:showSearchWithPresetDialog({ "One" }, nil, "preset", nil, nil, nil, origin)
            button(topWidget(), "One").callback()
            assert.is_not_nil(DB:hasWord("preset"))
            assert.equals(origin and 0 or 1, context_calls)
        end)

        it("attaches provenance to the actual dictionary popup: " .. tostring(origin), function()
            dictionary.getDictButtons = function() return {} end
            dictionary.showDict = ReaderDictionary.showDict
            dictionary:stardictLookup("popup", {}, false, nil, nil, nil, origin)
            assert.equals(origin, dictionary.dict_window.from_definition)
            assert.equals(origin and 0 or 1, context_calls)
        end)
    end

    it("marks HTML dictionary cross-links as definition words", function()
        dictionary.stardictLookup = function(_, word, _, _, _, _, _, from_definition)
            assert.is_true(from_definition)
            plugin:onWordLookedUp(word, "Synthetic book", nil, from_definition)
        end
        dictionary:onHtmlDictionaryLinkTapped("fixture", { uri = "bword://linked", x0 = 0, y0 = 0, x1 = 10, y1 = 10 })
        assert.is_not_nil(DB:hasWord("linked"))
        assert.equals(0, context_calls)
    end)

    it("does not let an interleaved nested lookup change a book lookup's origin", function()
        local pending = {}
        override(Trapper, "wrap", function(_, callback) pending[#pending + 1] = callback end)
        dictionary:onLookupWord("book", true)
        popup():lookupDictionaryOrWikipedia("nested")
        pending[2]()
        pending[1]()
        assert.is_nil(DB:hasWord("nested").prev_context)
        assert.equals("He ", DB:hasWord("book").prev_context)
        assert.equals(1, context_calls)
    end)

    it("retains an existing legitimate context instead of deleting it on nested update", function()
        DB:insertOrUpdate{ word = "existing", book_title = "Synthetic book", time = os.time(),
            prev_context = "Original ", next_context = " example.", highlight = "original" }
        popup():lookupDictionaryOrWikipedia("existing")
        local dialog = topWidget()
        dialog.update_callback()
        local item = DB:hasWord("existing")
        assert.equals("Original ", item.prev_context)
        assert.equals(" example.", item.next_context)
        assert.equals("original", item.highlight)
        assert.equals(0, context_calls)
    end)

    it("keeps legacy optional argument values compatible", function()
        plugin:onWordLookedUp("legacy", "Synthetic book", nil, "extension-data")
        assert.equals("He ", DB:hasWord("legacy").prev_context)
    end)

    it("respects disabled automatic capture and context preferences", function()
        settings.enabled = false
        popup():lookupDictionaryOrWikipedia("disabled")
        assert.is_nil(DB:hasWord("disabled"))
        settings.enabled, settings.with_context = true, false
        dictionary:onLookupWord("no-context", true)
        assert.is_nil(DB:hasWord("no-context").prev_context)
        assert.equals(0, context_calls)
    end)

    for _, origin in ipairs({ false, true }) do
        it("preserves origin through the popup preset button: " .. tostring(origin), function()
            dictionary.preset_obj.presets.One = {}
            dictionary.buildPreset = function() return {} end
            dictionary.loadPreset = function() end
            local window = popup(origin)
            window:lookupInputWord("popup-preset")
            button(window.input_dialog, "Search with preset").callback()
            button(topWidget(), "One").callback()
            assert.is_not_nil(DB:hasWord("popup-preset"))
            assert.equals(origin and 0 or 1, context_calls)
        end)

        it("preserves origin through a result-headword lookup: " .. tostring(origin), function()
            local window = popup(origin)
            window.results = { { dict = "synthetic", word = "headword" } }
            window.dict_index = 1
            window:onShowResultsMenu()
            button(topWidget(), "headword").hold_callback()
            assert.is_not_nil(DB:hasWord("headword"))
            assert.equals(origin and 0 or 1, context_calls)
        end)

        it("preserves origin across the Wikipedia bridge and deferred connection: " .. tostring(origin), function()
            local Wikipedia = require("ui/wikipedia")
            local NetworkMgr = require("ui/network/manager")
            local ReaderWikipedia = require("apps/reader/modules/readerwikipedia")
            local retry, deferred, requests = nil, false, 0
            override(NetworkMgr, "willRerunWhenOnline", function(_, callback)
                if not deferred then retry, deferred = callback, true; return true end
                return false
            end)
            local function syntheticPage()
                requests = requests + 1
                return { { title = "wiki-bridge", extract = "A synthetic definition." } }
            end
            override(Wikipedia, "searchAndGetIntros", syntheticPage)
            override(Wikipedia, "getFullPage", syntheticPage)
            override(Wikipedia, "setTrapWidget", function() end)
            override(Wikipedia, "resetTrapWidget", function() end)
            local wiki = setmetatable({ ui = ui, disable_history = true, wiki_languages = { "en" },
                initLanguages = function() end, showLookupInfo = function() end }, { __index = ReaderWikipedia })
            ui.wikipedia = wiki
            local dispatch = ui.handleEvent
            ui.handleEvent = function(_, event)
                if event.handler == "onLookupWikipedia" then
                    return wiki:onLookupWikipedia(unpack(event.args, 1, event.args.n))
                end
                return dispatch(ui, event)
            end
            popup(origin):lookupWikipedia(false, "wiki-bridge", true)
            assert.equals(0, requests)
            assert.is_function(retry)
            retry()
            assert.equals(1, requests)
            assert.equals(origin, wiki.dict_window.from_definition)
            wiki.dict_window:lookupInputWord("bridge-edit")
            button(wiki.dict_window.input_dialog, "Search dictionary").callback()
            assert.is_not_nil(DB:hasWord("bridge-edit"))
            assert.equals(origin and 0 or 1, context_calls)
        end)
    end

    it("marks selected definition text when switching from dictionary to Wikipedia", function()
        local captured
        ui.handleEvent = function(_, event) captured = event end
        popup(false):lookupDictionaryOrWikipedia("definition", true)
        assert.equals("onLookupWikipedia", captured.handler)
        assert.is_true(captured.args[7])
        assert.is_function(captured.args[6])
    end)

    it("preserves origin through Wikipedia resizing", function()
        local window = popup(true)
        window.is_wiki = true
        local captured
        ui.handleEvent = function(_, event) captured = event end
        window:setTemporaryLargeWindowMode()
        assert.equals("onLookupWikipedia", captured.handler)
        assert.is_true(captured.args[7])
        assert.is_function(captured.args[6])
    end)

    it("preserves origin through the alternate single-result headword menu", function()
        local window = popup(true)
        window.results = { { dict = "synthetic", word = "alt-single" } }
        window.dict_index = 1
        window:showResultsAltMenu()
        button(topWidget(), "alt-single").hold_callback()
        assert.is_not_nil(DB:hasWord("alt-single"))
        assert.equals(0, context_calls)
    end)

    it("preserves origin through the alternate multiple-result headword menu", function()
        local window = popup(true)
        window.results = { { dict = "synthetic", word = "alt-first" }, { dict = "synthetic", word = "alt-second" } }
        window.dict_index = 1
        window:showResultsAltMenu()
        button(topWidget(), "2 results").callback()
        button(topWidget(), "alt-second").hold_callback()
        assert.is_not_nil(DB:hasWord("alt-second"))
        assert.equals(0, context_calls)
    end)

    it("passes origin from the search result into the no-results retry dialog", function()
        dictionary.startProgressiveSdcv = function()
            return { { dict = "synthetic", word = "missing", definition = "No results", no_result = true } }
        end
        dictionary.showLookupInfo = function() end
        dictionary.quick_dismiss_before_delay = 0
        local source
        dictionary.showNoResultsDialog = function(_, _, _, _, _, _, _, _, from_definition)
            source = from_definition
            return true
        end
        dictionary:stardictLookup("missing", { "synthetic" }, false, nil, nil, nil, true)
        assert.is_true(source)
        assert.equals(0, context_calls)
    end)

    it("passes origin from the no-results dialog into its preset action", function()
        dictionary.preset_obj.presets.One = {}
        local source
        dictionary.showSearchWithPresetDialog = function(_, _, _, word, _, _, _, from_definition)
            assert.equals("preset-missing", word)
            source = from_definition
        end
        dictionary:showNoResultsDialog("preset-missing", {}, true, nil, nil, nil, function() end, true)
        local dialog = topWidget()
        button(dialog, "Search with preset").callback(dialog)
        assert.is_true(source)
    end)

end)
