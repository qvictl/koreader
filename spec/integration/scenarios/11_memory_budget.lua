-- Memory budget: after the first cycles have warmed up the caches, more open / page turns /
-- close cycles must not make the process grow (RSS, Lua heap), i.e. no leak.
return {
    name = "Memory budget (open/close cycles)",
    timeout = 300,
    settings = {
        cre_font = "Noto Sans CJK SC",
    },
    run = function(T)
        local samples = {}
        local CYCLES = 10
        for cycle = 1, CYCLES do
            for _, book in ipairs({ "books/zh.epub", "books/en.epub" }) do
                local ui = T:openBook(T:fixture(book))
                -- (Books reopen at their last position: start from the beginning, so that
                -- we never reach the end of the book and its end-of-document dialog.)
                T:run(function() ui:handleEvent(require("ui/event"):new("GotoPage", 1)) end)
                for _ = 1, 8 do
                    T:run(function() ui:handleEvent(require("ui/event"):new("GotoViewRel", 1)) end)
                end
                T:repaint()
                T:run(function() ui.toc:onShowToc() end)
                T:repaint()
                T:run(function() ui.toc.toc_menu.close_callback() end)
                T:closeBook()
            end
            T:wait(0.5) -- let the deferred memory release run
            -- The global document cache is bounded, but fills up over the first cycles:
            -- empty it so that it doesn't hide (or look like) a leak.
            T:run(function() require("document/doccache"):clear() end)
            local lua_kb = T:luaKb()
            local rss_kb = T:rssKb()
            samples[cycle] = { rss = rss_kb, lua = lua_kb }
            T:log(string.format("cycle %d: RSS %d kB, Lua heap %.0f kB", cycle, rss_kb, lua_kb))
        end
        -- The Lua heap and RSS oscillate by a MB or two from cycle to cycle (GC timing): compare
        -- the lowest values of the last 3 cycles to those of cycles 2-4 (a leak raises the floor).
        local function floor(from, to, key)
            local m = math.huge
            for i = from, to do m = math.min(m, samples[i][key]) end
            return m
        end
        local peak = 0
        for _, s in ipairs(samples) do peak = math.max(peak, s.rss) end
        T:metric("rss_after_warmup_kb", floor(2, 4, "rss"), "kB")
        T:metric("rss_final_kb", floor(CYCLES - 2, CYCLES, "rss"), "kB")
        T:metric("lua_heap_final_kb", floor(CYCLES - 2, CYCLES, "lua"), "kB")
        T:budget("rss_growth_kb", floor(CYCLES - 2, CYCLES, "rss") - floor(2, 4, "rss"), 12 * 1024, "kB")
        T:budget("lua_heap_growth_kb", floor(CYCLES - 2, CYCLES, "lua") - floor(2, 4, "lua"), 2048, "kB")
        T:budget("rss_peak_after_close_kb", peak, 400 * 1024, "kB")
    end,
}
