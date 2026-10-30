-- Reflow must not access an uncreated progress widget when the footer is disabled.
return {
    name = "Disabled footer survives EPUB reflow and TOC reset",
    timeout = 60,
    run = function(T)
        local settings = {}
        for key, value in pairs(require("apps/reader/modules/readerfooter").default_settings) do
            settings[key] = value
        end
        settings.disabled = true
        settings.disable_progress_bar = false
        G_reader_settings:saveSetting("footer", settings)
        local reader = T:openBook(T:fixture("books/en.epub"))
        local footer = reader.view.footer
        T:eq(footer.progress_bar, nil, "disabled footer does not create a progress widget")
        T:eq(reader.view.footer_visible, false, "footer starts hidden")
        T:run(function()
            reader:handleEvent(require("ui/event"):new("TocReset"))
        end)
        T:eq(footer.pages, reader.document:getPageCount(), "TOC reset retains the current page count")
        local font_size = reader.font.configurable.font_size
        T:run(function() reader.font:onChangeSize(2) end)
        T:repaint()
        T:eq(reader.font.configurable.font_size, font_size + 2, "real font-size action reflows the EPUB")
        T:eq(footer.pages, reader.document:getPageCount(), "reflow updates the footer's page count")
        T:eq(footer.progress_bar, nil, "reflow leaves the disabled progress widget absent")
        T:eq(reader.view.footer_visible, false, "reflow keeps the footer hidden")
        T:closeBook()
    end,
}
