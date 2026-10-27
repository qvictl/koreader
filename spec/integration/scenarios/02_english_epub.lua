-- English EPUB: open, page turns (tap & swipe gestures), TOC navigation, close.
return {
    name = "English EPUB: page turns and TOC",
    timeout = 120,
    run = function(T)
        local ui, open_ms = T:openBook(T:fixture("books/en.epub"))
        T:budget("open_ms", open_ms, 15000, "ms")
        T:eq(ui.doc_props.language, "en", "document language")
        T:eq(ui.doc_props.display_title, "Integration Test Book", "document title")
        local nb_pages = ui.document:getPageCount()
        T:metric("pages", nb_pages)
        T:check(nb_pages >= 20, "the book has at least 20 pages (" .. nb_pages .. ")")
        T:eq(ui:getCurrentPage(), 1, "opens on the first page")

        -- Page turns with taps on the right side of the screen (forward) and the left side (back).
        local t0 = T:now()
        for i = 1, 10 do
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return ui:getCurrentPage() == 1 + i end, 5, "page " .. (1 + i))
        end
        T:budget("page_turn_ms", (T:now() - t0) / 10, 1000, "ms")
        T:tap(math.floor(T.screen_w * 0.1), math.floor(T.screen_h * 0.5))
        T:waitUntil(function() return ui:getCurrentPage() == 10 end, 5, "page 10 after a backward tap")
        -- Swipe to the west: next page.
        T:swipe(math.floor(T.screen_w * 0.7), math.floor(T.screen_h * 0.5), "west")
        T:waitUntil(function() return ui:getCurrentPage() == 11 end, 5, "page 11 after a swipe")

        -- TOC: the 6 chapters, in order.
        local toc = ui.toc.toc
        T:check(toc and #toc == 6, "TOC has 6 entries")
        local titles = {}
        for _, e in ipairs(toc) do table.insert(titles, e.title) end
        T:eq(titles[1], "Chapter One: The Harbor", "first TOC entry")
        T:eq(titles[6], "Chapter Six: The Return", "last TOC entry")
        -- Show the TOC and tap its 4th entry.
        T:run(function() ui.toc:onShowToc() end)
        local UIManager = require("ui/uimanager")
        local menu = T:waitUntil(function()
            return ui.toc.toc_menu and UIManager:isWidgetShown(ui.toc.toc_menu.show_parent) and ui.toc.toc_menu
        end, 5, "the TOC menu")
        T:repaint()
        local item = T:findWidget(menu, function(w)
            return w.entry and w.entry.text and w.entry.text:find("The Orchard", 1, true) and w.dimen and w.dimen.w > 0
        end)
        T:check(item, "the 4th chapter is shown in the TOC menu")
        T:tapWidget(item, "TOC entry")
        T:waitUntil(function() return not UIManager:isWidgetShown(menu.show_parent) end, 5, "the TOC menu to close")
        T:eq(ui:getCurrentPage(), toc[4].page, "jumped to the 4th chapter")
        T:eq(ui.toc:getTocTitleByPage(ui:getCurrentPage()), "Chapter Four: The Orchard", "current chapter")

        -- Last page, then back to the start with GotoPage.
        T:run(function() ui:handleEvent(require("ui/event"):new("GotoPage", nb_pages)) end)
        T:eq(ui:getCurrentPage(), nb_pages, "last page")
        T:run(function() ui:handleEvent(require("ui/event"):new("GotoPage", 1)) end)
        T:eq(ui:getCurrentPage(), 1, "back to the first page")
        local close_ms = T:closeBook()
        T:budget("close_ms", close_ms, 10000, "ms")
    end,
}
