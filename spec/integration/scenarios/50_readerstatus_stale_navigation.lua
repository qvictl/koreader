-- Real PDF readers and task queue: repeated navigation must not reuse a closed reader.
return {
    name = "ReaderStatus ignores stale deferred file navigation",
    timeout = 90,
    settings = { collate = "strcoll", file_ask_to_open = false,
        cover_image_enabled = false, cover_image_fallback = false },
    run = function(T)
        local UIManager = require("ui/uimanager")
        local util = require("util")
        local lfs = require("libs/libkoreader-lfs")
        local gettext = require("gettext")
        local prompts = {}
        local saved_ask = G_reader_settings:readSetting("file_ask_to_open")
        local base = os.getenv("KO_HOME") .. "/readerstatus-navigation"
        local a, b, c = base .. "/a.pdf", base .. "/b.pdf", base .. "/c.pdf"
        -- Small deterministic three-page PDF, generated without external tools or inputs.
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
        local function current(path, modal)
            local ui = T:waitUntil(function()
                local reader = T:reader()
                return reader and reader.document and reader.document.file == path and reader.view.dimen and reader
            end, 20, "navigation to " .. path)
            T:run(function() UIManager:forceRePaint() end)
            if not modal then T:check(T:topWidget() == ui, "navigation leaves the real reader visible") end
            T:eq(ui.document:getPageCount(), 3, "native PDF engine loads all three fixture pages")
            return ui
        end
        local function tapPrompt(prompt, text)
            T:run(function() UIManager:forceRePaint() end)
            T:check(T:topWidget() == prompt, "confirmation is the active modal")
            local button = T:findWidget(prompt, function(w) return w.text == text and w.callback and w.dimen end)
            T:tapWidget(button, "confirmation " .. text)
        end
        local ok, err = pcall(function()
            assert(not lfs.attributes(base), "private PDF fixture directory must be new")
            assert(util.makePath(base))
            for _, path in ipairs({ a, b, c }) do
                local file = assert(io.open(path, "wb"))
                assert(file:write(pdf()))
                assert(file:close())
            end
            local ui = T:openBook(b)
            T:run(function()
                ui.status:onOpenNextOrPreviousFileInFolder(false)
                ui.status:onOpenNextOrPreviousFileInFolder(false)
            end)
            local next_ui = current(c)
            T:check(next_ui ~= ui and ui.document == nil, "repeated next requests close the old reader exactly once")

            ui = T:openBook(b)
            T:run(function()
                ui.status:onOpenNextOrPreviousFileInFolder(true)
                ui.status:onOpenNextOrPreviousFileInFolder(true)
            end)
            local prev_ui = current(a)
            T:check(prev_ui ~= ui and ui.document == nil, "repeated previous requests leave a fresh reader")
            T:run(function()
                prev_ui.view:onSetScrollMode(false)
                prev_ui.zooming:setZoomMode("page", true)
            end)
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return prev_ui:getCurrentPage() == 2 end, 5, "page turn after repeated navigation")
            T:eq(prev_ui:getCurrentPage(), 2, "real input still turns PDF pages")

            ui = T:openBook(b)
            T:run(function()
                ui.status:onOpenNextOrPreviousFileInFolder(false)
                ui:onHome() -- close before the queued callback gets its turn
            end)
            T:run(function() end) -- drain the stale task, without sleeping to race it
            T:check(not T:reader() and T:topWidget() == T:fileManager(), "Home wins over queued navigation")

            ui = T:openBook(b)
            T:run(function()
                ui.status:onOpenNextOrPreviousFileInFolder(false)
                ui:switchDocument(a) -- a different explicit selection wins
            end)
            local replacement = current(a)
            T:check(replacement ~= ui and ui.document == nil, "stale callback does not redirect the replacement reader")
            T:eq(replacement:getCurrentPage(), 2, "normal reopen preserves PDF reading position")
            T:run(function() replacement.status:onOpenNextOrPreviousFileInFolder(false) end)
            current(b)
            T:closeBook()

            G_reader_settings:saveSetting("file_ask_to_open", true)
            ui = T:openBook(b)
            T:run(function()
                ui.status:onOpenNextOrPreviousFileInFolder(false)
                ui.status:onOpenNextOrPreviousFileInFolder(false)
            end)
            T:run(function() end)
            for _, entry in ipairs(UIManager._window_stack) do
                local widget = entry.widget
                if widget.modal and widget.ok_text == gettext("Open") then prompts[#prompts + 1] = widget end
            end
            T:eq(#prompts, 2, "rapid requests can create two real confirmation dialogs")
            tapPrompt(prompts[2], gettext("Open"))
            local confirmed = current(c, true)
            T:check(UIManager:isWidgetShown(prompts[1]), "the first modal survives closing its originating reader")
            tapPrompt(prompts[1], gettext("Open"))
            T:check(T:reader() == confirmed, "stale confirmation does not switch or reopen a document")
            current(c)

            ui = T:openBook(b)
            T:run(function() ui.status:onOpenNextOrPreviousFileInFolder(false) end)
            T:run(function() end)
            local cancelled = T:topWidget()
            prompts[#prompts + 1] = cancelled
            tapPrompt(cancelled, gettext("Cancel"))
            T:check(T:reader() == ui and ui.document.file == b, "Cancel retains the current PDF")

            T:run(function() ui.status:onOpenNextOrPreviousFileInFolder(false) end)
            T:run(function() end)
            local abandoned = T:topWidget()
            prompts[#prompts + 1] = abandoned
            T:run(function() ui:onHome() end)
            T:check(UIManager:isWidgetShown(abandoned), "Home leaves the modal available to dismiss")
            tapPrompt(abandoned, gettext("Open"))
            T:check(not T:reader() and T:topWidget() == T:fileManager(), "confirmation after Home safely dismisses")

            T:run(function() require("apps/filemanager/filemanagerutil").openFile(T:fileManager(), b) end)
            local fm_prompt = T:topWidget()
            prompts[#prompts + 1] = fm_prompt
            tapPrompt(fm_prompt, gettext("Open"))
            current(b)
            T:closeBook()
        end)
        -- Keep private inputs until process teardown, so background workers cannot
        -- lose files. Always close a surviving reader even if an assertion failed.
        G_reader_settings:saveSetting("file_ask_to_open", saved_ask)
        local cleanup_ok, cleanup_err = pcall(function()
            for _, prompt in ipairs(prompts) do
                if UIManager:isWidgetShown(prompt) then T:run(function() UIManager:close(prompt) end) end
            end
            T:closeBook()
        end)
        local errors = {}
        local function describe(e) return tostring(type(e) == "table" and e.msg or e) end
        if not ok then errors[#errors + 1] = "scenario: " .. describe(err) end
        if not cleanup_ok then errors[#errors + 1] = "cleanup: " .. describe(cleanup_err) end
        if #errors > 0 then error(table.concat(errors, "\n")) end
        T:check(not T:reader() and T:topWidget() == T:fileManager(), "returns to the file manager after navigation")
    end,
}
