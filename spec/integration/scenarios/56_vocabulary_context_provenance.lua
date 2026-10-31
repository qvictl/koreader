-- Native book selection, sdcv, dictionary widgets and SQLite; no network or dictionary installation.
return {
    name = "Vocabulary retains book context only for the originating lookup",
    timeout = 90,
    settings = { language = "en", dict_progressive_lookup = false,
        vocabulary_builder = { enabled = false, with_context = true } },
    run = function(T)
        local UIManager = require("ui/uimanager")
        local DictQuickLookup = require("ui/widget/dictquicklookup")
        local DataStorage = require("datastorage")
        local SQ3 = require("lua-ljsqlite3/init")
        local Event = require("ui/event")
        local Geom = require("ui/geometry")
        local time = require("ui/time")
        local ffiUtil = require("ffi/util")
        local util = require("util")
        local lfs = require("libs/libkoreader-lfs")
        local _ = require("gettext")
        local base = DataStorage:getDataDir() .. "/vocabulary-context-it"
        local book = base .. "/private.epub"
        local settings = assert(G_reader_settings:readSetting("vocabulary_builder"))
        local saved_enabled, saved_context = settings.enabled, settings.with_context
        local saved_external = G_reader_settings:readSetting("external_dict_lookup")
        local ui, root, selected, previous, following
        local function row(word)
            local conn = SQ3.open(DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3", "ro")
            local ok, result = pcall(function()
                local stmt = conn:prepare("SELECT prev_context, next_context, highlight FROM vocabulary WHERE word = ?")
                stmt:bind(word)
                return stmt:step()
            end)
            conn:close()
            if not ok then error(result, 0) end
            return result
        end
        local function tapButton(window, text)
            T:repaint()
            local target
            if window.button_table then
                for _, button in pairs(window.button_table.button_by_id) do
                    if button.text == text then target = button; break end
                end
            end
            target = target or T:findWidget(window, function(w) return w.text == text and w.onTapSelectButton end)
            T:tapWidget(target, text)
        end
        local function waitWindow(old)
            local window = T:waitUntil(function()
                local w = ui.dictionary.dict_window
                return w and w ~= old and UIManager:isWidgetShown(w) and not w.results_pending and w
            end, 10, "new completed dictionary popup")
            T:repaint()
            return window
        end
        local function closeWindow(window)
            T:run(function() window:onClose() end)
        end
        local function edit(window, word)
            T:run(function() window:lookupInputWord(word) end)
            tapButton(window.input_dialog, _("Search dictionary"))
            return waitWindow(window)
        end
        local ok, err = pcall(function()
            assert(not lfs.attributes(base), "private fixture must be new")
            T:run(function()
                util.makePath(base)
                assert(not ffiUtil.copyFile(T:fixture("books/en.epub"), book))
                settings.enabled, settings.with_context = false, true
                G_reader_settings:makeFalse("external_dict_lookup")
            end)
            ui = T:openBook(book)
            T:check(ui.vocabbuilder, "real vocabulary plugin is loaded")
            T:run(function()
                ui.dictionary.enabled_dict_names = { "IT Alpha" }
                ui.dictionary.disable_fuzzy_search = false
                local words = { harbor = true, lantern = true, quiet = true, orchard = true,
                    storm = true, ["return"] = true, keeper = true, evening = true, window = true,
                    river = true, bridge = true, garden = true, letter = true, morning = true }
                local d = ui.view.dimen
                for y = d.y + 80, d.y + d.h - 80, 18 do
                    for x = d.x + 30, d.x + d.w - 30, 20 do
                        local word = ui.document:getWordFromPosition({ x = x, y = y }, true)
                        if word and words[word.word] and word.pos0 and word.sbox then
                            selected = word
                            break
                        end
                    end
                    if selected then break end
                end
                assert(selected, "native EPUB must contain a fixture dictionary word")
                ui.highlight.selected_text = { text = selected.word, pos0 = selected.pos0,
                    pos1 = selected.pos1, sboxes = { selected.sbox } }
                previous, following = ui.highlight:getSelectedWordContext(15)
                assert(previous and following, "native selected-word context must be available")
                assert(not row(selected.word), "private vocabulary entry must be new")
                ui.dictionary:onLookupWord(selected.word, true, { selected.sbox }, ui.highlight)
            end)
            root = waitWindow()
            T:check(root.from_definition ~= true, "book lookup is not a definition lookup")
            tapButton(root, _("Add to vocabulary builder"))
            local book_row = row(selected.word)
            T:check(book_row, "manual button persists the book word")
            T:eq({ book_row[1], book_row[2] }, { previous, following }, "saved context comes from native EPUB selection")

            -- Long-press real rendered definition text through the ordinary gesture route.
            local text = root.stw_widget.text_widget
            local d = text.dimen
            local x, y = d.x + 8, d.y + math.floor(text.line_height / 2)
            T:run(function()
                UIManager:sendEvent(Event:new("Gesture", { ges = "hold", pos = Geom:new{ x = x, y = y, w = 0, h = 0 }, time = time.now() }))
                UIManager:sendEvent(Event:new("Gesture", { ges = "hold_release", pos = Geom:new{ x = x, y = y, w = 0, h = 0 }, time = time.now() }))
            end)
            local nested = waitWindow(root)
            T:check(nested.word ~= selected.word, "definition selection differs from the book word")
            tapButton(nested, _("Add to vocabulary builder"))
            local nested_row = row(nested.lookupword)
            T:check(nested_row, "manual nested lookup is persisted")
            T:eq({ nested_row[1], nested_row[2], nested_row[3] }, {}, "nested word does not inherit the book context or highlight")
            T:check(nested.from_definition == true, "nested popup records definition origin")
            local edited_nested = edit(nested, "synthetic-nested-stem")
            tapButton(edited_nested, _("Add to vocabulary builder"))
            T:eq({ unpack(row(edited_nested.lookupword)) }, {}, "editing a nested lookup keeps its context-free provenance")
            closeWindow(edited_nested)
            closeWindow(nested)
            T:check(ui.highlight.selected_text ~= nil, "closing child lookups preserves the root book selection")

            local edited_root = edit(root, "synthetic-book-stem")
            tapButton(edited_root, _("Add to vocabulary builder"))
            local edited_row = row(edited_root.lookupword)
            T:eq({ edited_row[1], edited_row[2], edited_row[3] }, { previous, following, selected.word },
                "editing the root retains its original word form and native context")
            closeWindow(edited_root)
            T:run(function()
                settings.enabled = true
                root:lookupDictionaryOrWikipedia("of")
            end)
            local automatic = waitWindow(root)
            T:check(row("of"), "automatic nested lookup is persisted without a manual button")
            local auto_row = row("of")
            T:eq({ auto_row[1], auto_row[2], auto_row[3] }, {}, "automatic nested lookup also omits unrelated book context")
            closeWindow(automatic)
            closeWindow(root)
            root = nil
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h / 2))
            T:check(ui:getCurrentPage() > 1, "reader still turns pages after nested lookup closure")
            local page = ui:getCurrentPage()
            T:closeBook()
            ui = T:openBook(book)
            T:eq(ui:getCurrentPage(), page, "private book reopens at the saved page")
            T:eq({ row(selected.word)[1], row(selected.word)[2] }, { previous, following }, "SQLite retains the original context after reader recreation")
            T:eq({ unpack(row("synthetic-nested-stem")) }, {}, "SQLite retains context-free nested entry after reader recreation")
            T:closeBook()
        end)
        settings.enabled, settings.with_context = saved_enabled, saved_context
        G_reader_settings:saveSetting("external_dict_lookup", saved_external)
        local errors = {}
        local function message(e) return tostring(type(e) == "table" and e.msg or e) end
        if not ok then errors[#errors + 1] = "scenario: " .. message(err) end
        local popups_ok, popups_err = pcall(function()
            T:run(function()
                for i = #DictQuickLookup.window_list, 1, -1 do
                    local closed, close_err = pcall(DictQuickLookup.window_list[i].onClose, DictQuickLookup.window_list[i])
                    if not closed then errors[#errors + 1] = "popup: " .. message(close_err) end
                end
            end)
        end)
        if not popups_ok then errors[#errors + 1] = "popups: " .. message(popups_err) end
        local reader_ok, reader_err = pcall(function() if T:reader() then T:closeBook() end end)
        if not reader_ok then errors[#errors + 1] = "reader: " .. message(reader_err) end
        -- Keep the private EPUB/profile for diagnostics and any queued cover worker.
        if #errors > 0 then error(table.concat(errors, "\n"), 0) end
        T:eq(#DictQuickLookup.window_list, 0, "cleanup closes all nested dictionary popups")
        T:check(T:topWidget() == T:fileManager(), "cleanup leaves the file manager usable")
    end,
}
