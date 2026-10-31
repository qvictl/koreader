-- A syntactically valid append log can survive with missing leading/interior records.
-- Load it through LuaData and exercise the real history page and lookup callback.
return {
    name = "Sparse dictionary lookup history remains accessible",
    timeout = 60,
    settings = {
        dict_progressive_lookup = false,
    },
    setup = function(T)
        local DataStorage = require("datastorage")
        T.history_path = DataStorage:getSettingsDir() .. "/lookup_history.lua"
        local file = assert(io.open(T.history_path, "w"))
        for _, record in ipairs({
            { 29, "harbor", "Book" }, { 30, "beacon", "Book" }, { 32, "harbor", "Other" },
            { 1, "harbor", "Earlier" }, { 2, "beacon", "Earlier" }, { 4, "君子", "Earlier" },
        }) do
            file:write(string.format(
                'LookupHistoryEntry{index="lookup_history",data={[%d]={word=%q,book_title=%q,time=1764562881}}}\n',
                record[1], record[2], record[3]))
        end
        file:close()
    end,
    run = function(T)
        local UIManager = require("ui/uimanager")
        local util = require("util")
        local DictHelper = dofile(T.spec_dir .. "/dicthelper.lua")
        local original = assert(util.readFromFile(T.history_path))
        local expected = {
            { "Other:", "" }, { "word", "harbor" },
            { "Book:", "" }, { "word", "beacon" }, { "word", "harbor" },
            { "Earlier:", "" }, { "word", "君子" }, { "word", "beacon" }, { "word", "harbor" },
        }
        local function showHistory(dictionary)
            T:run(function()
                local menu_items = {}
                dictionary:addToMainMenu(menu_items)
                T:check(menu_items.dictionary_lookup_history.enabled_func(), "loaded history is enabled")
                menu_items.dictionary_lookup_history.callback()
            end)
            local page = T:topWidget()
            T:eq(page.title, "Dictionary lookup history", "the actual history page is shown")
            T:repaint()
            T:eq(#page.kv_pairs, #expected, "all surviving records and title groups are displayed")
            for i, row in ipairs(expected) do
                local label = row[1] == "word" and os.date("%Y-%m-%d %H:%M:%S", 1764562881) or row[1]
                T:eq({ page.kv_pairs[i][1], page.kv_pairs[i][2] }, { label, row[2] }, "history row " .. i)
            end
            T:eq(util.readFromFile(T.history_path), original, "viewing history leaves the append log unchanged")
            return page
        end

        local fm = T:fileManager()
        for _ = 1, 2 do
            local page = showHistory(fm.dictionary)
            T:run(function() page:onClose() end)
            T:check(not UIManager:isWidgetShown(page), "closing history removes the page")
        end

        local ui = T:openBook(T:fixture("books/en.epub"))
        local page = showHistory(ui.dictionary)
        local row = T:findWidget(page, function(widget) return widget.kv_pairs_idx == 4 end)
        T:check(row ~= nil, "the surviving beacon entry has a painted row")
        T:tapWidget(row, "look up the word from sparse history")
        local window = T:waitUntil(function()
            local w = ui.dictionary.dict_window
            return w and not w.results_pending and w
        end, 10, "dictionary results from the sparse history row")
        T:eq(window.word, "beacon", "the selected surviving entry is looked up")
        T:check(not window.results[1].no_result, "the real dictionary returns a definition")
        DictHelper.close(T, ui)
        T:run(function() page:onClose() end)
        T:closeBook()
    end,
}
