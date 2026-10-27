-- CJK EPUB, rendered with the bundled Noto Sans CJK SC font: text, page turns, CJK TOC.
return {
    name = "CJK EPUB: rendering, page turns and TOC",
    timeout = 120,
    settings = {
        cre_font = "Noto Sans CJK SC",
    },
    run = function(T)
        local Event = require("ui/event")
        local ui, open_ms = T:openBook(T:fixture("books/zh.epub"))
        T:budget("open_ms", open_ms, 15000, "ms")
        T:eq(ui.doc_props.language, "zh", "document language")
        T:eq(ui.doc_props.display_title, "論語選讀", "CJK document title")
        T:eq(ui.document:getFontFace(), "Noto Sans CJK SC", "document font")
        local nb_pages = ui.document:getPageCount()
        T:metric("pages", nb_pages)
        T:check(nb_pages >= 5, "the book has at least 5 pages (" .. nb_pages .. ")")

        -- The text of the first page, extracted back from the rendered page.
        local res = T:run(function()
            return ui.document:getTextFromPositions({ x = 0, y = 0 }, { x = T.screen_w - 1, y = T.screen_h - 1 }, true)
        end)
        local text = res and res.text or ""
        T:metric("page1_chars", #text)
        T:check(text:find("學而時習之", 1, true), "page 1 text has the first line of the Analects")
        -- A word can be selected (word boundaries in CJK text, used for dictionary lookups).
        local word = T:run(function()
            local d = ui.view.dimen
            return ui.document:getWordFromPosition({ x = d.x + math.floor(d.w / 2), y = d.y + math.floor(d.h / 3) }, true)
        end)
        T:check(word and word.word and #word.word > 0, "a CJK word can be selected")

        -- Page turns, forward and back.
        local t0 = T:now()
        for i = 1, 4 do
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return ui:getCurrentPage() == 1 + i end, 5, "page " .. (1 + i))
        end
        T:budget("page_turn_ms", (T:now() - t0) / 4, 1000, "ms")
        T:tap(math.floor(T.screen_w * 0.1), math.floor(T.screen_h * 0.5))
        T:waitUntil(function() return ui:getCurrentPage() == 4 end, 5, "page 4 after a backward tap")

        -- CJK TOC.
        local toc = ui.toc.toc
        T:check(toc and #toc == 5, "TOC has 5 entries")
        local titles = {}
        for _, e in ipairs(toc) do table.insert(titles, e.title) end
        T:eq(titles, { "學而第一", "為政第二", "八佾第三", "里仁第四", "公冶長第五" }, "CJK TOC titles")
        T:run(function() ui:handleEvent(Event:new("GotoPage", toc[3].page)) end)
        T:eq(ui.toc:getTocTitleByPage(ui:getCurrentPage()), "八佾第三", "chapter after jumping to the 3rd TOC entry")

        -- Font size change re-renders, keeps the text.
        local pages_before = ui.document:getPageCount()
        T:run(function() ui.font:onSetFontSize((ui.document.configurable.font_size or 22) + 6) end)
        T:repaint()
        T:check(ui.document:getPageCount() > pages_before, "bigger font gives more pages")
        T:closeBook()
    end,
}
