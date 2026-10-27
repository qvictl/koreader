-- Progressive dictionary lookup: the first dictionary's result is shown before the others
-- finish, the window is then updated in the background, and the final list is the same,
-- in the same order, as a classic (single sdcv run) lookup. Plus a latency budget.
return {
    name = "Dictionary lookup (progressive)",
    timeout = 180,
    settings = {
        dict_progressive_lookup = true,
    },
    run = function(T)
        local DictHelper = dofile(T.spec_dir .. "/dicthelper.lua")
        local ui = T:openBook(T:fixture("books/en.epub"))
        local max_first, max_total = 0, 0
        for _, word in ipairs({ "harbor", "lantern", "beacon", "storm", "君子", "qwxzvbnmplk" }) do
            local r = DictHelper.lookup(T, ui, word)
            local expected = DictHelper.classic(T, ui, word)
            T:eq(r.results, expected, "progressive results for '" .. word .. "' equal the classic ones")
            if #expected > 1 and expected[1]:find("^IT Alpha|") then
                -- First dictionary had a result: shown alone first, the others added later.
                T:eq(#r.initial_results, 1, "only the first dictionary's result is shown at first for '" .. word .. "'")
                T:check(r.initial_pending, "more results pending at first for '" .. word .. "'")
                T:check(r.t_painted <= (r.t_last_update or r.t_painted), "first result painted before the others are in")
                T:check(r.kept_shown ~= false, "the shown result is kept while results are added")
            end
            T:log(string.format("%s: init %d ms, first paint %d ms, complete %d ms, %d result(s), %d update(s)",
                word, r.init_ms, r.first_ms, r.total_ms, #r.results, r.nb_updates or 0))
            max_first = math.max(max_first, r.first_ms)
            max_total = math.max(max_total, r.total_ms)
            DictHelper.close(T, ui)
        end
        T:budget("first_result_ms", max_first, 3000, "ms")
        T:budget("all_results_ms", max_total, 6000, "ms")

        -- Closing the window while the background lookup runs kills it (no sdcv left behind).
        local holder = DictHelper.instrument(T)
        holder.cur = { word = "harbor" }
        T:run(function() ui.dictionary:onLookupWord("harbor", true) end)
        local w = T:waitUntil(function() return ui.dictionary.dict_window end, 20, "dictionary window")
        T:run(function() w:onClose() end)
        holder.cur = nil
        T:waitUntil(function() return #T:children() == 0 end, 5, "no sdcv process left after closing early")
        T:closeBook()
    end,
}
