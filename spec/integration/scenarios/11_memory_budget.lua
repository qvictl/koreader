-- Memory budget: after the first cycles have warmed up the caches, more open / page turns /
-- close cycles must not make the process grow (RSS, Lua heap), i.e. no leak.
--
-- Every cycle ends at the end of the book: paging past the last page shows ReaderStatus' end of
-- book dialog, and the book is closed (Home) with that dialog still shown. That dialog used to be
-- left on the window stack (hidden under the file manager, flagged in UIManager._dirty), keeping
-- the whole ReaderUI alive: ~1 MB of Lua heap per book and cycle.
return {
    name = "Memory budget (open/close cycles)",
    timeout = 300,
    settings = {
        cre_font = "Noto Sans CJK SC",
    },
    run = function(T)
        local Event = require("ui/event")
        local UIManager = require("ui/uimanager")
        -- (Not keeping any reference to the dialog here, that would keep it alive.)
        local function isEndOfBookDialog(w)
            return w ~= nil and w.name == "end_document"
        end
        local function endOfBookDialogLeft()
            for w in UIManager:topdown_widgets_iter() do
                if isEndOfBookDialog(w) then return true end
            end
            for w in pairs(UIManager._dirty) do
                if type(w) == "table" and isEndOfBookDialog(w) then return true end
            end
            return false
        end
        local samples = {}
        local CYCLES = 10
        for cycle = 1, CYCLES do
            for _, book in ipairs({ "books/zh.epub", "books/en.epub" }) do
                local ui = T:openBook(T:fixture(book))
                local pages = ui.document:getPageCount()
                -- Books reopen at their last position, i.e. the last page after the first cycle.
                if cycle > 1 then
                    T:expect(ui:getCurrentPage() == pages, book .. " reopened at its last page")
                end
                T:run(function() ui:handleEvent(Event:new("GotoPage", 1)) end)
                for _ = 1, 8 do
                    T:run(function() ui:handleEvent(Event:new("GotoViewRel", 1)) end)
                end
                T:repaint()
                T:run(function() ui.toc:onShowToc() end)
                T:repaint()
                T:run(function() ui.toc.toc_menu.close_callback() end)
                -- Page past the end of the book: the end of book dialog shows up…
                T:run(function() ui:handleEvent(Event:new("GotoPage", pages)) end)
                T:run(function() ui:handleEvent(Event:new("GotoViewRel", 1)) end)
                T:repaint()
                T:check(isEndOfBookDialog(T:topWidget()), book .. ": end of book dialog shown")
                -- …and close the book with it shown: it must go away with the book.
                T:closeBook()
                -- (Soft check: go on, so that the budgets below show what the leak costs.)
                T:expect(not endOfBookDialogLeft(), book .. ": end of book dialog closed with the book")
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
