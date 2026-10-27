-- Dictionary lookups (classic, single sdcv run): exact match in several dictionaries,
-- CJK word, no result (fuzzy and non-fuzzy), and the res/ directory of an HTML dictionary
-- that must be skipped by KOReader's .ifo scan (see 06_sdcv_res_dirs for sdcv itself).
return {
    name = "Dictionary lookup (classic)",
    timeout = 180,
    settings = {
        dict_progressive_lookup = false,
    },
    run = function(T)
        local DictHelper = dofile(T.spec_dir .. "/dicthelper.lua")
        local ui = T:openBook(T:fixture("books/en.epub"))

        -- Dictionaries found by KOReader: the 4 fixtures, not the decoy one inside it-gamma/res/.
        T:eq(ui.dictionary:getNumberOfDictionaries(), 4, "number of dictionaries found (res/ skipped)")

        -- Exact match in 3 dictionaries, in dictionary order.
        local r = DictHelper.lookup(T, ui, "harbor")
        T:eq(r.dicts, { "IT Alpha", "IT Beta", "IT Gamma" }, "dictionaries with results for 'harbor'")
        T:check(r.results[1]:find("alpha: definition of harbor", 1, true), "IT Alpha definition")
        T:check(r.window.results[3].is_html, "IT Gamma result is HTML")
        T:check(not r.window.results_pending, "classic lookup is complete at once")
        T:budget("lookup_ms", r.total_ms, 5000, "ms")
        DictHelper.close(T, ui)

        -- A word only in one dictionary.
        r = DictHelper.lookup(T, ui, "beacon")
        T:eq(r.dicts, { "IT Beta", "IT Gamma" }, "dictionaries with results for 'beacon'")
        DictHelper.close(T, ui)

        -- CJK word.
        r = DictHelper.lookup(T, ui, "君子")
        T:eq(r.dicts, { "IT Hanzi" }, "dictionaries with results for 君子")
        T:check(r.results[1]:find("才德出眾的人", 1, true), "CJK definition")
        DictHelper.close(T, ui)

        -- No result, fuzzy search enabled: a window saying so.
        r = DictHelper.lookup(T, ui, "qwxzvbnmplk")
        T:check(r.window.results[1].no_result, "no result for a nonsense word")
        DictHelper.close(T, ui)

        -- No result, fuzzy search disabled: the "No results found" dialog, offering fuzzy search.
        ui.dictionary.disable_fuzzy_search = true
        local UIManager = require("ui/uimanager")
        T:run(function() ui.dictionary:onLookupWord("qwxzvbnmplk", true) end)
        local dialog = T:waitUntil(function()
            local top = T:topWidget()
            return top and top.title == "No results found" and top
        end, 20, "the 'No results found' dialog")
        T:run(function() UIManager:close(dialog) end)
        ui.dictionary.disable_fuzzy_search = false

        -- No sdcv process left behind.
        T:waitUntil(function() return #T:children() == 0 end, 5, "no child process left")
        T:closeBook()
    end,
}
