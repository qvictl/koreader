-- Actual EPUB selection, dictionary controls and native sdcv, with owned synthetic
-- StarDict files. No dictionary downloads, network calls or user dictionaries.
local short_name, long_name = "IT Japanese Short", "IT Japanese Long"
local original_dict_dir, private_dir

return {
    name = "Japanese selections use enabled dictionaries",
    timeout = 90,
    settings = { language = "en", cre_font = "Noto Sans CJK SC", dict_progressive_lookup = false },
    setup = function(T)
        local DataStorage = require("datastorage")
        local lfs = require("libs/libkoreader-lfs")
        private_dir = DataStorage:getDataDir() .. "/japanese-selection-dicts"
        assert(not lfs.attributes(private_dir), "private dictionaries must be new")
        local StarDict = dofile(T.spec_dir .. "/../unit/stardict_fixture.lua")
        StarDict.write(private_dir .. "/short", "short", short_name, { ["吾輩"] = "short: I, myself" }, { lang = "ja-en" })
        StarDict.write(private_dir .. "/long", "long", long_name, { ["吾輩は"] = "long: I, with topic particle" }, { lang = "ja-en" })
        original_dict_dir = G_defaults:readSetting("STARDICT_DATA_DIR")
        G_defaults:saveSetting("STARDICT_DATA_DIR", private_dir)
    end,
    run = function(T)
        local UIManager = require("ui/uimanager")
        local DataStorage = require("datastorage")
        local Event = require("ui/event")
        local Geom = require("ui/geometry")
        local time = require("ui/time")
        local ffiUtil = require("ffi/util")
        local DictHelper = dofile(T.spec_dir .. "/dicthelper.lua")
        local book = DataStorage:getDataDir() .. "/japanese-selection.epub"
        local ui, pos, raw

        local function toggleGlobal(name, accept)
            T:run(function() ui.dictionary:showDictionariesMenu(function() end) end)
            local menu = T:topWidget()
            T:eq(menu.title, "Manage installed dictionaries", "real dictionary management dialog")
            T:repaint()
            local row = T:findWidget(menu, function(w)
                return w.item and w.item.text == name and w.checkmark_widget
            end)
            T:check(row, "dictionary row is present")
            T:tapWidget(row.checkmark_widget, "dictionary enabled checkbox")
            T:tapWidget(accept == false and menu.footer_cancel or menu.footer_ok, "dictionary dialog close")
            T:check(not UIManager:isWidgetShown(menu), "dictionary dialog closed")
        end

        local function select(expected, lookup)
            local before = raw.calls
            local started = T:now()
            T:run(function()
                UIManager:sendEvent(Event:new("Gesture", {
                    ges = "hold", pos = Geom:new{ x = pos.x, y = pos.y, w = 0, h = 0 }, time = time.now(),
                }))
            end)
            T:eq(ui.highlight.selected_text and ui.highlight.selected_text.text, expected, "native hold selects the enabled dictionary word")
            T:budget("selection_ms", T:now() - started, 5000, "ms")
            if lookup then
                T:run(function() ui.highlight:onHoldRelease() end)
                local window = T:waitUntil(function()
                    local w = ui.dictionary.dict_window
                    return w and UIManager:isWidgetShown(w) and not w.results_pending and w
                end, 10, "dictionary popup from held word")
                T:repaint()
                T:eq(window.word, expected, "lookup uses the selected word")
                T:check(not window.results[1].no_result, "selection has a usable dictionary entry")
                DictHelper.close(T, ui)
            else
                T:run(function() ui.highlight:clear() end)
            end
            return raw.calls - before
        end

        local function findWord()
            local d = ui.view.dimen
            T:run(function()
                for y = d.y + 70, d.y + d.h - 70, 12 do
                    for x = d.x + 20, d.x + d.w - 20, 12 do
                        local word = ui.document:getWordFromPosition({ x = x, y = y }, true)
                        if word and word.word == "吾" and word.pos0 then
                            pos = { x = x, y = y }
                            return
                        end
                    end
                end
            end)
            T:check(pos, "native Japanese EPUB exposes the starting character")
        end

        local ok, err = pcall(function()
            assert(not ffiUtil.copyFile(T:fixture("books/ja.epub"), book))
            ui = T:openBook(book)
            T:eq(ui.dictionary.data_dir, private_dir, "only owned dictionaries are used")
            T:eq(ui.dictionary:getNumberOfDictionaries(), 2, "both synthetic dictionaries discovered")
            T:check(ui.languagesupport.plugins.japanese, "Japanese language support loaded")
            findWord()
            raw = T:spy(ui.dictionary, "rawSdcv")
            select("吾輩は", true)

            -- Cancelling a checkbox change must not change either selection or lookup.
            toggleGlobal(long_name, false)
            select("吾輩は", true)
            toggleGlobal(long_name)
            T:eq(ui.dictionary.enabled_dict_names, { short_name }, "global disable updates the actual sdcv list")
            select("吾輩", true)

            -- Preferred dictionaries remain eligible even when globally disabled.
            T:run(function()
                ui.dictionary:onTogglePreferredDict(long_name)
                UIManager:close(T:topWidget()) -- Dismiss the preference notice before sending another hold.
            end)
            T:eq(ui.dictionary.enabled_dict_names, { long_name, short_name }, "preferred dictionary precedes globally enabled dictionary")
            select("吾輩は", true)

            -- Long-hold the real preferred-dictionary button to disable it for this book.
            T:run(function() ui.dictionary:showPreferredDictsDialog({ updateItems = function() end }) end)
            local dialog = T:topWidget()
            T:repaint()
            local button = T:findWidget(dialog, function(w)
                return type(w.text) == "string" and w.text:find(long_name, 1, true) and w.hold_callback
            end)
            T:check(button, "preferred dictionary button is painted")
            T:run(function()
                local d = button.dimen
                UIManager:sendEvent(Event:new("Gesture", { ges = "hold", time = time.now(),
                    pos = Geom:new{ x = d.x + math.floor(d.w / 2), y = d.y + math.floor(d.h / 2), w = 0, h = 0 },
                }))
            end)
            T:run(function() UIManager:close(T:topWidget()) end)
            T:check(ui.dictionary.doc_disabled_dicts[long_name], "dictionary is disabled for this book")
            select("吾輩", true)

            raw.restore()
            T:closeBook()
            T:check(T:fileManager(), "reader closes to file manager")
            ui = T:openBook(book)
            pos = nil
            findWord()
            raw = T:spy(ui.dictionary, "rawSdcv")
            T:check(ui.dictionary.doc_disabled_dicts[long_name], "per-book disable survives reopen")
            select("吾輩", true)

            -- With all eligible dictionaries disabled, selection must not fall back to all installed ones.
            toggleGlobal(short_name)
            T:eq(select("吾", false), 0, "no unfiltered sdcv call when no dictionary is eligible")
            toggleGlobal(short_name)
            select("吾輩", true)
            raw.restore()
            raw = nil
            T:closeBook()
            T:check(T:fileManager(), "final reader close returns to file manager")
        end)
        if raw then raw.restore() end
        G_defaults:saveSetting("STARDICT_DATA_DIR", original_dict_dir)
        if not ok then error(err, 0) end
    end,
}
