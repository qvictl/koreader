-- Real configuration pickers and native PDF page turns; no external files or network.
return {
    name = "PDF current zoom survives partial settings and page turns",
    timeout = 90,
    settings = {
        cover_image_enabled = false, cover_image_fallback = false,
        kopt_zoom_factor = 1.5, kopt_zoom_mode_genus = 0, kopt_trim_page = 3,
    },
    run = function(T)
        local UIManager = require("ui/uimanager")
        local Event = require("ui/event")
        local lfs = require("libs/libkoreader-lfs")
        local path = os.getenv("KO_HOME") .. "/current-zoom.pdf"
        local second_path = os.getenv("KO_HOME") .. "/default-zoom.pdf"
        local ui, dialog, picker, notice
        local function pdf()
            local stream = "BT /F1 18 Tf 60 700 Td (Synthetic current zoom test) Tj ET\n"
            local objects = {
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [5 0 R 6 0 R 7 0 R] /Count 3 >>",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                "<< /Length " .. #stream .. " >>\nstream\n" .. stream .. "endstream",
            }
            for i = 5, 7 do
                objects[i] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]"
                    .. " /Resources << /Font << /F1 3 0 R >> >> /Contents 4 0 R >>"
            end
            local bytes, offsets = "%PDF-1.4\n", {}
            for i, object in ipairs(objects) do
                offsets[i] = #bytes
                bytes = bytes .. i .. " 0 obj\n" .. object .. "\nendobj\n"
            end
            local start = #bytes
            bytes = bytes .. "xref\n0 8\n0000000000 65535 f \n"
            for _, offset in ipairs(offsets) do bytes = bytes .. string.format("%010d 00000 n \n", offset) end
            return bytes .. "trailer\n<< /Size 8 /Root 1 0 R >>\nstartxref\n" .. start .. "\n%%EOF\n"
        end

        local function near(actual, expected, what)
            T:check(type(actual) == "number" and math.abs(actual - expected) < 1e-6, what)
        end
        local function tapText(widget, text)
            T:repaint()
            local button = T:findWidget(widget, function(w) return w.text == text and w.callback end)
            T:check(button ~= nil, "painted button: " .. text)
            T:tapWidget(button, text)
        end
        local function changeNumber(value)
            local count = math.floor(math.abs(value - picker.value_widget:getValue()) / picker.value_step + 0.5)
            local direction = value > picker.value_widget:getValue() and "▲" or "▼"
            for _ = 1, count do tapText(picker, direction) end
            near(picker.value_widget:getValue(), value, "picker displays requested value")
        end
        local function openPicker()
            T:run(function() ui.config:onShowConfigMenu() end)
            dialog = ui.config.config_dialog
            T:repaint()
            local option = dialog:findOptionByName("zoom_factor")
            T:run(function()
                dialog:onConfigMoreChoose(option.values, option.default_value, option.name,
                    option.event, option.args, option.name_text, option.more_options_param)
            end)
            T:waitUntil(function() return T:topWidget().title_text == "Zoom factor" end, 3, "zoom picker")
            picker = T:topWidget()
            T:repaint()
        end
        local function apply()
            tapText(picker, "Apply")
            notice = T:topWidget()
            T:check(notice ~= picker and type(notice.text) == "string" and notice.text:find("Zoom set to:", 1, true),
                "configuration applies through the normal zoom confirmation")
            T:tap(math.floor(T.screen_w / 2), math.floor(T.screen_h / 2))
            T:check(T:topWidget() == picker, "dismissing notice returns to picker")
        end
        local function closePicker()
            tapText(picker, "Close")
            T:run(function() ui.config:onCloseConfigMenu() end)
            T:check(T:topWidget() == ui, "closing picker and menu returns to reader")
            picker, dialog = nil, nil
        end
        local ok, err = pcall(function()
            for _, file_path in ipairs({path, second_path}) do
                T:check(not lfs.attributes(file_path), "private PDF path is absent")
                local file = assert(io.open(file_path, "wb"))
                assert(file:write(pdf()))
                assert(file:close())
            end
            local open_ms
            ui, open_ms = T:openBook(path)
            T:budget("open_ms", open_ms, 15000, "ms")
            T:eq(ui.document:getPageCount(), 3, "native engine opens three-page PDF")
            T:eq(ui.zooming.zoom_mode, "manual", "starts in manual mode")
            T:run(function()
                ui:handleEvent(Event:new("SetScrollMode", false))
                ui.paging:onGotoPage(2)
            end)
            openPicker()
            changeNumber(2)
            tapText(picker, "Set as default")
            tapText(T:topWidget(), "Cancel")
            near(G_reader_settings:readSetting("kopt_zoom_factor"), 1.5, "Cancel leaves the global default unchanged")
            tapText(picker, "Set as default")
            tapText(T:topWidget(), "Set as default")
            near(G_reader_settings:readSetting("kopt_zoom_factor"), 2, "confirmation sets the global factor to two")
            changeNumber(0.7)
            apply()
            local current_zoom = ui.zooming.zoom
            closePicker()
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h / 2))
            T:waitUntil(function() return ui:getCurrentPage() == 3 end, 3, "next PDF page")
            near(ui.zooming.zoom, current_zoom, "next page keeps current factor instead of the global default")
            near(ui.doc_settings:readSetting("kopt_zoom_factor"), 0.7, "current factor remains in book settings")
            near(G_reader_settings:readSetting("kopt_zoom_factor"), 2, "current change does not replace the global default")
            T:tap(math.floor(T.screen_w * 0.1), math.floor(T.screen_h / 2))
            T:waitUntil(function() return ui:getCurrentPage() == 2 end, 3, "previous PDF page")
            near(ui.zooming.zoom, current_zoom, "previous page keeps the current factor")

            openPicker()
            changeNumber(0.9)
            closePicker()
            near(ui.doc_settings:readSetting("kopt_zoom_factor"), 0.7, "Close without Apply preserves the current factor")
            openPicker()
            changeNumber(1.1)
            apply()
            closePicker()
            near(ui.doc_settings:readSetting("kopt_zoom_factor"), 1.1, "second Apply replaces the current factor")
            T:run(function() ui.zooming:_zoomPanChange("Horizontal overlap", "zoom_overlap_h") end)
            picker = T:topWidget()
            changeNumber(25)
            tapText(picker, "Set")
            T:check(T:topWidget() == ui, "overlap picker closes after Set")
            picker = nil
            near(ui.zooming.zoom_overlap_h, 25, "overlap update reaches zooming")
            near(ui.doc_settings:readSetting("kopt_zoom_factor"), 1.1, "overlap-only update retains the current factor")
            T:eq(ui.doc_settings:readSetting("zoom_mode"), "manual", "overlap-only update retains the current mode")
            T:run(function() ui.paging:onGotoPage(3) end)
            current_zoom = ui.zooming.zoom
            T:closeBook()
            ui = T:openBook(path)
            T:eq(ui:getCurrentPage(), 3, "reopen retains reading progress")
            T:eq(ui.zooming.zoom_mode, "manual", "reopen retains manual mode")
            near(ui.zooming.zoom, current_zoom, "reopen retains the current scale")
            near(ui.document.configurable.zoom_factor, 1.1, "reopen retains current factor")
            T:closeBook()
            ui = T:openBook(second_path)
            near(ui.document.configurable.zoom_factor, 2, "a new book still inherits the global default")
            T:closeBook()
            ui = T:openBook(path)
            near(ui.document.configurable.zoom_factor, 1.1, "switching books does not replace the local override")
        end)
        -- Owned PDFs remain in the private profile until process teardown for queued native work.
        local errors = {}
        if not ok then errors[#errors + 1] = tostring(type(err) == "table" and err.msg or err) end
        for _, widget in ipairs({notice or false, picker or false, dialog or false}) do
            if widget and UIManager:isWidgetShown(widget) then
                local closed, failure = pcall(function() T:run(function() UIManager:close(widget) end) end)
                if not closed then errors[#errors + 1] = tostring(failure) end
            end
        end
        local closed, failure = pcall(function() T:closeBook() end)
        if not closed then errors[#errors + 1] = tostring(failure) end
        if #errors > 0 then error(table.concat(errors, "\n")) end
        T:check(T:topWidget() == T:fileManager(), "returns to FileManager after repeated reopen")
    end,
}
