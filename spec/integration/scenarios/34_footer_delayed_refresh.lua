-- Real reader, event propagation and task queue; no synthetic document lifetime.
return {
    name = "Closing a reader cancels delayed page-turn footer feedback",
    timeout = 60,
    run = function(T)
        local ReaderFooter = require("apps/reader/modules/readerfooter")
        local UIManager = require("ui/uimanager")
        local Event = require("ui/event")
        local settings = {}
        for key, value in pairs(ReaderFooter.default_settings) do settings[key] = value end
        settings.page_turning_inverted = true
        settings.auto_refresh_time = false
        G_reader_settings:saveSetting("footer", settings)
        G_reader_settings:saveSetting("reader_footer_mode", 1)

        local function countTasks(action)
            local count = 0
            for _, task in ipairs(UIManager._task_queue) do
                if task.action == action then count = count + 1 end
            end
            return count
        end

        for _ = 1, 2 do
            local old = T:openBook(T:fixture("books/en.epub"))
            local footer = old.view.footer
            T:run(function()
                old:handleEvent(Event:new("ToggleReadingOrder", true))
                local pending = footer._delayed_footer_refresh or footer.maybeUpdateFooter
                T:eq(countTasks(pending), 1, "reading-order event queues a delayed footer refresh")
                -- Close in the same UI action: no timing assumption about loading the next book.
                old:onHome()
                T:eq(old.document, nil, "the real reader releases its document")
                T:eq(countTasks(pending), 0, "closing removes every delayed callback for the old footer")
            end)

            local current = T:openBook(T:fixture("books/en.epub"))
            local active_footer = current.view.footer
            local updates = 0
            local original_update = active_footer.onUpdateFooter
            T:run(function()
                active_footer.onUpdateFooter = function(self, ...)
                    updates = updates + 1
                    return original_update(self, ...)
                end
                current:handleEvent(Event:new("ToggleReadingOrder", false))
                T:eq(countTasks(active_footer._delayed_footer_refresh), 1,
                    "the new reader still queues its own feedback")
            end)
            T:waitUntil(function()
                return updates > 0 and countTasks(active_footer._delayed_footer_refresh) == 0
            end, 5, "the live reader's delayed footer refresh")
            T:run(function() active_footer.onUpdateFooter = original_update end)
            local page = current:getCurrentPage()
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return current:getCurrentPage() == page + 1 end, 5,
                "page turning after the previous reader's delayed feedback was canceled")
            T:closeBook()
        end
    end,
}
