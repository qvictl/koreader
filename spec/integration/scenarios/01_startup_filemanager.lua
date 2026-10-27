-- Startup to the file manager: it is shown, lists the fixture books, and tapping a book opens it.
return {
    name = "Startup to file manager",
    timeout = 90,
    run = function(T)
        local fm = T:fileManager()
        T:check(fm, "file manager is shown")
        T:check(T:topWidget() == fm, "file manager is the top widget (stack: " .. T:windowStack() .. ")")
        T:budget("startup_ms", T.startup_ms, 20000, "ms")

        -- The fixture books are listed.
        local books = {}
        for _, item in ipairs(fm.file_chooser.item_table) do
            if item.path and item.path:match("%.epub$") then
                books[item.path:match("[^/]+$")] = true
            end
        end
        T:check(books["en.epub"] and books["zh.epub"] and books["ja.epub"], "the 3 fixture books are listed")

        -- Tap the English book's entry, as a user would.
        T:run(function() require("ui/uimanager"):forceRePaint() end)
        local target = T:fixture("books/en.epub")
        local item = T:findWidget(fm, function(w)
            return w.entry and w.entry.path == target and w.dimen and w.dimen.w > 0
        end)
        T:check(item, "en.epub has a painted entry in the file chooser")
        local t0 = T:now()
        T:tapWidget(item, "en.epub entry")
        local ReaderUI = require("apps/reader/readerui")
        local ui = T:waitUntil(function()
            local ui = ReaderUI.instance
            return ui and ui.document and ui.view and ui.view.dimen and ui
        end, 60, "the book to open from the file chooser")
        T:budget("open_from_tap_ms", T:now() - t0, 15000, "ms")
        T:eq(ui.document.file, target, "the tapped book is opened")
        T:closeBook()
        T:check(T:fileManager() and T:topWidget() == T:fileManager(), "back to the file manager after closing")
    end,
}
