-- Synthetic PDF, real native rendering and keyboard event dispatch.
return {
    name = "Keyboard PDF zoom retains page navigation",
    timeout = 60,
    settings = { cover_image_enabled = false, cover_image_fallback = false },
    run = function(T)
        local UIManager = require("ui/uimanager")
        local Event = require("ui/event")
        local Key = require("device/key")
        local lfs = require("libs/libkoreader-lfs")
        local path = os.getenv("KO_HOME") .. "/keyboard-zoom.pdf"
        local ui, config_dialog, skim_dialog
        local input = require("device").input
        local saved_disable_double_tap = rawget(input, "disable_double_tap")
        local function pdf()
            local stream = "BT /F1 18 Tf 60 700 Td (Synthetic lifecycle test) Tj ET\n"
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

        local function key(name, shift)
            T:run(function() UIManager:sendEvent(Event:new("KeyPress", Key:new(name, { Shift = shift or false }))) end)
            T:run(function() UIManager:forceRePaint() end)
        end
        local function near(actual, expected, what)
            T:check(math.abs(actual - expected) < 1e-6, what)
        end
        local ok, err = pcall(function()
            T:check(not lfs.attributes(path), "private PDF path is absent")
            local file = assert(io.open(path, "wb"))
            assert(file:write(pdf()))
            assert(file:close())
            ui = T:openBook(path)
            T:eq(ui.document:getPageCount(), 3, "native PDF engine loads three pages")
            T:run(function()
                ui:handleEvent(Event:new("SetScrollMode", false))
                ui.zooming:setZoomMode("page", true)
                ui.paging:onGotoPage(2)
            end)
            T:eq(ui:getCurrentPage(), 2, "starts at the middle page")
            local start_zoom = ui.zooming.zoom
            key("RPgBack", true)
            near(ui.zooming.zoom, start_zoom * 0.75, "Shift-page-back keeps the requested zoom-out scale")
            key("RPgFwd")
            T:eq(ui:getCurrentPage(), 3, "ordinary page-forward still works after keyboard zoom-out")
            T:eq(ui.zooming.zoom_mode, "manual", "keyboard zoom uses supported manual mode")
            T:eq(ui.document.configurable.zoom_mode_genus, 0, "configuration remains a valid manual genus")
            T:check(not ui.view.page_scroll, "page view remains page view")
            key("RPgBack")
            T:eq(ui:getCurrentPage(), 2, "page-back remains usable")

            T:run(function() ui.zooming:setZoomMode("page", true) end)
            start_zoom = ui.zooming.zoom
            key("RPgFwd", true)
            near(ui.zooming.zoom, start_zoom * 1.333333, "Shift-page-forward keeps requested zoom-in scale")
            local before = ui.paging.visible_area:copy()
            key("RPgFwd")
            local after = ui.paging.visible_area
            T:check(ui:getCurrentPage() ~= 2 or before.x ~= after.x or before.y ~= after.y,
                "zoomed page can pan or turn instead of freezing")
            T:eq(ui.koptlistener.normal_zoom_mode, "manual", "Kopt listener tracks the normal zoom mode")

            T:run(function() ui.config:onShowConfigMenu() end)
            config_dialog = ui.config.config_dialog
            T:run(function() UIManager:forceRePaint() end)
            T:check(UIManager:isWidgetShown(config_dialog), "bottom configuration menu still paints after keyboard zoom")
            T:run(function() ui.config:onCloseConfigMenu() end)
            T:check(T:topWidget() == ui, "closing configuration returns to the reader")
            T:run(function() ui.paging:onGotoPage(2) end)
            local saved_zoom = ui.zooming.zoom
            T:closeBook()
            ui = T:openBook(path)
            T:eq(ui.zooming.zoom_mode, "manual", "reopen retains manual mode")
            near(ui.zooming.zoom, saved_zoom, "reopen retains the same fixture-page scale")
            T:run(function() ui.zooming:setZoomMode("page", true) end)
            key("RPgFwd")
            T:eq(ui:getCurrentPage(), 3, "normal fit-page keyboard navigation still works")

            T:run(function()
                ui.zooming:setZoomMode("pagewidth", true)
                ui.document.configurable.page_scroll = 1
                ui:handleEvent(Event:new("SetScrollMode", true))
                ui.paging:onTogglePageFlipping()
            end)
            key("RPgBack", true)
            T:run(function() ui.paging:onTogglePageFlipping() end)
            T:check(ui.view.page_scroll and ui.document.configurable.page_scroll == 1,
                "temporary page flipping does not overwrite continuous-view configuration")
            T:closeBook()
            ui = T:openBook(path)
            T:check(ui.view.page_scroll, "continuous view survives reopening after preview zoom")
            T:run(function()
                ui.document.configurable.page_scroll = 0
                ui:handleEvent(Event:new("SetScrollMode", false))
                ui.zooming:setZoomMode("page", true)
            end)
            key("RPgBack", true)
            local normal_factor, normal_zoom = ui.doc_settings:readSetting("kopt_zoom_factor"), ui.zooming.zoom
            T:run(function() ui.paging:onTogglePageFlipping() end)
            key("RPgBack", true)
            T:run(function() ui.paging:onTogglePageFlipping() end)
            near(ui.doc_settings:readSetting("kopt_zoom_factor"), normal_factor,
                "preview zoom preserves the normal manual factor")
            near(ui.zooming.zoom, normal_zoom, "leaving preview restores the normal reading scale")
            key("RPgBack", true)
            near(ui.zooming.zoom, normal_zoom * 0.75, "keyboard zoom works normally after preview ends")

            T:run(function()
                ui.zooming:setZoomMode("content", true)
                ui.gotopage:onShowSkimtoDialog()
                skim_dialog = ui.gotopage.skimto
            end)
            T:check(UIManager:isWidgetShown(skim_dialog), "real skim dialog is visible")
            -- The modal consumes page keys. Exercise the ReaderUI entry explicitly,
            -- without claiming this is the modal's physical keyboard routing.
            T:run(function() ui:handleEvent(Event:new("KeyPress", Key:new("RPgBack", { Shift = true }))) end)
            T:eq(ui.zooming.zoom_mode, "free", "temporary skim keeps its existing free-zoom path")
            T:run(function() UIManager:close(skim_dialog) end)
            T:eq(ui.koptlistener.normal_zoom_mode, "content", "skim keyboard zoom preserves the normal Kopt mode")
            T:run(function() ui.koptlistener:onRestoreZoomMode() end)
            T:eq(ui.zooming.zoom_mode, "content", "later mode restoration cannot resurrect temporary manual zoom")
            key("RPgBack", true)
            T:eq(ui.zooming.zoom_mode, "manual", "ordinary keyboard zoom resumes after skim closes")
            T:closeBook()
        end)
        local errors = {}
        local function record(label, passed, failure)
            if not passed then errors[#errors + 1] = label .. ": " .. tostring(type(failure) == "table" and failure.msg or failure) end
        end
        record("scenario", ok, err)
        record("skim cleanup", pcall(function()
            if skim_dialog and UIManager:isWidgetShown(skim_dialog) then
                T:run(function() UIManager:close(skim_dialog) end)
            end
        end))
        record("menu cleanup", pcall(function()
            if config_dialog and UIManager:isWidgetShown(config_dialog) then
                T:run(function() UIManager:close(config_dialog) end)
            end
        end))
        record("reader cleanup", pcall(function() T:closeBook() end))
        input.disable_double_tap = saved_disable_double_tap
        -- Retain private inputs until process teardown for queued native work.
        if #errors > 0 then error(table.concat(errors, "\n")) end
        T:check(not T:reader() and T:topWidget() == T:fileManager(), "returns to a usable FileManager")
    end,
}
