describe("ReaderHighlight actions (PDF)", function()
    local Blitbuffer, DataStorage, DocSettings, DocumentRegistry, Event, Geom, LuaSettings
    local ReaderUI, Screen, Translator, UIManager
    local sample_pdf
    local readerui, hl

    -- Lightweight overrides (luassert spies deep-copy their arguments, which is
    -- far too costly with ReaderUI/Document objects as self).
    local restores = {}
    local function override(obj, key, fn)
        local old = rawget(obj, key)
        obj[key] = fn
        table.insert(restores, function() obj[key] = old end)
    end
    local function restore_all()
        for i = #restores, 1, -1 do restores[i]() end
        restores = {}
    end
    local function find_item(items, text)
        for _, item in ipairs(items) do
            local t = item.text or (item.text_func and item.text_func())
            if t and t:find(text, 1, true) then return item end
        end
    end
    local shown, tasks
    local function last_shown()
        return shown[#shown]
    end
    local function fake_touchmenu()
        local tm = { updated = 0 }
        function tm:updateItems() self.updated = self.updated + 1 end
        return tm
    end
    -- Record what would be written into the PDF file
    local function record_pdf_writes()
        local writes = {}
        local doc = readerui.document
        override(doc, "saveHighlight", function(_, page, item, color)
            table.insert(writes, { "save", page, item, color })
        end)
        override(doc, "deleteHighlight", function(_, page, item)
            table.insert(writes, { "delete", page, item })
        end)
        override(doc, "updateHighlightContents", function(_, page, item, content)
            table.insert(writes, { "content", page, item, content })
        end)
        return writes
    end

    local WORD = { x = 260, y = 70 } -- "Penn"
    local TEXT0, TEXT1 = { x = 430, y = 210 }, { x = 60, y = 236 } -- "to take care of the London"
    local NEXT0, NEXT1 = { x = 260, y = 150 }, { x = 430, y = 250 } -- some text on page 11

    local function at(pos)
        return Geom:new({ x = pos.x, y = pos.y })
    end
    local function hold(pos)
        return hl:onHold(nil, { pos = at(pos) })
    end
    local function select_text(p0, p1)
        hold(p0)
        hl:onHoldPan(nil, { pos = at(p1) })
    end
    local function save_text(p0, p1)
        select_text(p0, p1)
        local index = hl:saveHighlight()
        hl:clear()
        return index
    end
    local function annotations()
        return readerui.annotation.annotations
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        Blitbuffer = require("ffi/blitbuffer")
        DataStorage = require("datastorage")
        DocSettings = require("docsettings")
        DocumentRegistry = require("document/documentregistry")
        Event = require("ui/event")
        Geom = require("ui/geometry")
        LuaSettings = require("luasettings")
        ReaderUI = require("apps/reader/readerui")
        Screen = require("device").screen
        Translator = require("ui/translator")
        UIManager = require("ui/uimanager")
        sample_pdf = DataStorage:getDataDir() .. "/readerhighlight_pdf_actions.pdf"
        require("ffi/util").copyFile("spec/front/unit/data/sample.pdf", sample_pdf)
        DocSettings:open(sample_pdf):purge()
        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(sample_pdf),
            _testsuite = true,
        }
        readerui.hinting.view.hinting = false
        readerui:handleEvent(Event:new("SetScrollMode", false))
        hl = readerui.highlight
    end)

    teardown(function()
        readerui:onClose()
        UIManager:quit()
    end)

    before_each(function()
        shown = {}
        override(UIManager, "show", function(_, w) table.insert(shown, w) end)
        tasks = {}
        override(UIManager, "scheduleIn", function(_, delay, fn, ...)
            table.insert(tasks, { delay = delay, fn = fn, args = { ... } })
        end)
        readerui.paging:onGotoPage(10)
    end)

    after_each(function()
        hl:onClose()
        hl.select_mode = false
        hl.highlight_idx = nil
        hl.highlight_write_into_pdf = nil
        hl.panel_zoom_enabled = false
        hl.panel_zoom_fallback_to_text_selection = true
        readerui.annotation.annotations = {}
        for _, k in ipairs({ "default_highlight_action", "highlight_dialog_position", "highlight_write_into_pdf",
                             "highlight_write_into_pdf_notify" }) do
            G_reader_settings:delSetting(k)
        end
        G_reader_settings:saveSetting("document_metadata_folder", "dir")
        restore_all()
    end)

    describe("boundaries", function()
        it("should move the start and end of a highlight word by word", function()
            local index = save_text(TEXT0, TEXT1)
            local item = annotations()[index]
            assert.are.equal("to take care of the London", item.text)
            local nb_boxes = #item.pboxes
            hl:updateHighlight(index, 0, 1)
            assert.are.equal("take care of the London", item.text)
            hl:updateHighlight(index, 0, -1)
            assert.are.equal("to take care of the London", item.text)
            assert.are.equal(nb_boxes, #item.pboxes)
            -- "London" is the last word of its text line: extend to the next line
            hl:updateHighlight(index, 1, 1)
            assert.are.equal("to take care of the London vineyard.", item.text)
            assert.are.equal(nb_boxes + 1, #item.pboxes)
            hl:updateHighlight(index, 1, -1)
            assert.are.equal("to take care of the London", item.text)
            assert.are.equal(nb_boxes, #item.pboxes)
            hl:updateHighlight(index, 1, -1)
            assert.are.equal("to take care of the", item.text)
            assert.are.equal(nb_boxes, #item.pboxes)
            -- moving by char is not supported with page based documents
            hl:updateHighlight(index, 1, -1, true)
            assert.are.equal("to take care of the", item.text)
        end)

        it("should not move the start past the end of a single word", function()
            hold(WORD)
            local index = hl:saveHighlight()
            hl:clear()
            local item = annotations()[index]
            assert.are.equal("Penn", item.text)
            hl:updateHighlight(index, 0, 1)
            hl:updateHighlight(index, 1, -1)
            assert.are.equal("Penn", item.text)
            -- but can grow on both sides
            hl:updateHighlight(index, 1, 1)
            hl:updateHighlight(index, 0, -1)
            assert.truthy(#item.text > #"Penn")
            assert.truthy(item.text:find("Penn", 1, true))
        end)

        it("should give up when the highlight boxes are not found on the page", function()
            local index = save_text(TEXT0, TEXT1)
            local item = annotations()[index]
            item.pboxes = { { x = 1, y = 1, w = 1, h = 1 } }
            hl:updateHighlight(index, 0, 1)
            assert.are.equal("to take care of the London", item.text)
        end)

        it("should write boundary changes into the PDF when enabled", function()
            hl.highlight_write_into_pdf = true
            local writes = record_pdf_writes()
            local index = save_text(TEXT0, TEXT1)
            assert.are.equal(1, #writes)
            assert.are.equal("save", writes[1][1])
            assert.are.equal(10, writes[1][2])
            hl:updateHighlight(index, 0, 1)
            assert.are.equal(3, #writes)
            assert.are.equal("delete", writes[2][1])
            assert.are.equal("to take care of the London", writes[2][3].text)
            assert.are.equal("save", writes[3][1])
            assert.are.equal("take care of the London", writes[3][3].text)
        end)
    end)

    describe("writing into the PDF", function()
        it("should only write when enabled and for highlights", function()
            local writes = record_pdf_writes()
            local index = save_text(TEXT0, TEXT1)
            assert.are.equal(0, #writes)
            hl.highlight_write_into_pdf = true
            hl:writePdfAnnotation("save", { pos0 = { page = 1 }, pos1 = { page = 1 } }) -- bookmark, no drawer
            assert.are.equal(0, #writes)
            local item = annotations()[index]
            item.color = "red"
            hl:writePdfAnnotation("save", item)
            assert.are.equal(0xff, writes[1][4].r)
            item.color = "gray"
            hl:writePdfAnnotation("save", item)
            assert.is_nil(writes[2][4])
            hl:writePdfAnnotation("content", item, "a note")
            assert.are.equal("a note", writes[3][4])
            hl:deleteHighlight(index)
            assert.are.equal("delete", writes[4][1])
            assert.are.equal(0, #annotations())
        end)

        it("should rewrite style, color and note changes", function()
            hl.highlight_write_into_pdf = true
            local writes = record_pdf_writes()
            local index = save_text(TEXT0, TEXT1)
            local item = annotations()[index]
            item.note = "note"
            hl:editHighlightStyle(index)
            last_shown().callback("underscore")
            assert.are.equal("underscore", item.drawer)
            -- delete, save, content
            assert.are.same({ "save", "delete", "save", "content" },
                { writes[1][1], writes[2][1], writes[3][1], writes[4][1] })
            hl:editHighlightColor(index)
            last_shown().callback("green")
            assert.are.equal("green", item.color)
            assert.are.equal(7, #writes)
            -- deleting the note empties the PDF annotation contents
            hl:showHighlightNoteOrDialog(index)
            last_shown().buttons_table[1][1].callback()
            assert.are.equal("content", writes[8][1])
            assert.are.equal("", writes[8][4])
        end)

        it("should toggle writing from the menu", function()
            local menu_items = {}
            hl:addToMainMenu(menu_items)
            local tm = fake_touchmenu()
            local write = find_item(menu_items.highlight_options.sub_item_table, "Write highlights into PDF")
            assert.truthy(write.text_func():find("off", 1, true))
            local on, off, notify, write_all, delete_all = unpack(write.sub_item_table)
            on.callback()
            assert.is_true(hl.highlight_write_into_pdf)
            assert.is_true(on.checked_func())
            assert.is_false(off.checked_func())
            on.hold_callback(tm)
            assert.is_true(G_reader_settings:isTrue("highlight_write_into_pdf"))
            assert.truthy(on.text_func():find("★", 1, true))
            assert.truthy(write.text_func():find("on", 1, true))
            off.callback()
            assert.is_false(hl.highlight_write_into_pdf)
            off.hold_callback(tm)
            assert.is_nil(G_reader_settings:readSetting("highlight_write_into_pdf"))
            assert.truthy(off.text_func():find("★", 1, true))
            assert.are.equal(2, tm.updated)
            assert.is_false(notify.checked_func())
            notify.callback()
            assert.is_true(notify.checked_func())
            -- (hash based metadata: a warning is logged)
            G_reader_settings:saveSetting("document_metadata_folder", "hash")
            local nb = #shown
            on.callback()
            assert.are.equal(nb + 1, #shown)
            assert.truthy(last_shown().text:find("hash", 1, true))
            -- read-only file
            override(readerui.document, "_checkIfWritable", function() return false end)
            hl.highlight_write_into_pdf = false
            on.callback()
            assert.is_false(hl.highlight_write_into_pdf)
            assert.truthy(last_shown().text:find("read-only", 1, true))
            -- write/delete all highlights
            hl.highlight_write_into_pdf = true
            assert.is_false(write_all.enabled_func())
            record_pdf_writes()
            save_text(TEXT0, TEXT1)
            hold(WORD)
            hl:saveHighlight()
            hl:clear()
            annotations()[1].note = "with note"
            assert.is_true(write_all.enabled_func())
            assert.is_true(delete_all.enabled_func())
            local writes = record_pdf_writes()
            write_all.callback()
            last_shown().ok_callback()
            -- 2 x (delete + save) + 1 content
            assert.are.equal(5, #writes)
            assert.truthy(last_shown().text:find("2 highlights written", 1, true))
            writes = record_pdf_writes()
            delete_all.callback()
            last_shown().ok_callback()
            assert.are.equal(2, #writes)
            assert.truthy(last_shown().text:find("2 highlights deleted", 1, true))
            G_reader_settings:delSetting("highlight_write_into_pdf_notify")
        end)

        it("should remind about writing into PDF on opening", function()
            G_reader_settings:makeTrue("highlight_write_into_pdf_notify")
            hl.highlight_write_into_pdf = true
            hl:onReaderReady()
            assert.truthy(last_shown().text:find("Write highlights into PDF: on", 1, true))
        end)
    end)

    describe("extended selections", function()
        it("should extend a selection within a page", function()
            hold(WORD)
            hl:startSelection()
            hl:clear()
            assert.is_true(hl.select_mode)
            assert.is_true(annotations()[1].is_tmp)
            select_text(TEXT0, TEXT1)
            hl:onHoldRelease()
            assert.is_false(hl.select_mode)
            assert.truthy(hl.highlight_dialog)
            local text = hl.selected_text.text
            assert.are.equal("Penn", text:sub(1, 4))
            assert.are.equal("London", text:sub(-6))
            assert.is_nil(hl.selected_text.ext)
            assert.are.equal(0, #annotations())
            assert.truthy(hl.view.highlight.temp[10])
        end)

        it("should extend a selection across pages", function()
            select_text(TEXT0, TEXT1)
            hl:startSelection()
            hl:clear()
            readerui.paging:onGotoPage(11)
            select_text(NEXT0, NEXT1)
            G_reader_settings:saveSetting("default_highlight_action", "select")
            hl:onHoldRelease()
            assert.are.equal(1, #annotations())
            local item = annotations()[1]
            assert.truthy(item.ext)
            assert.truthy(item.ext[10])
            assert.truthy(item.ext[11])
            assert.are.equal(10, item.pos0.page)
            assert.are.equal(11, item.pos1.page)
            assert.are.equal("to take care of the London", item.text:sub(1, 26))
            -- per page parts
            local parts10, offset = hl:getPageSavedHighlights(10)
            assert.are.equal(1, #parts10)
            assert.are.equal(0, offset)
            assert.are.equal(1, parts10[1].parent)
            assert.are.equal(item.ext[10].pboxes, parts10[1].pboxes)
            local parts12 = hl:getPageSavedHighlights(12)
            assert.are.equal(0, #parts12)
        end)

        it("should write multi-page highlights page by page", function()
            select_text(TEXT0, TEXT1)
            hl:startSelection()
            hl:clear()
            readerui.paging:onGotoPage(11)
            select_text(NEXT0, NEXT1)
            G_reader_settings:saveSetting("default_highlight_action", "select")
            hl.highlight_write_into_pdf = true
            local writes = record_pdf_writes()
            hl:onHoldRelease()
            -- the temporary first fragment is deleted, then each page is saved
            local saves = {}
            for _, w in ipairs(writes) do
                if w[1] == "save" then table.insert(saves, w[2]) end
            end
            assert.are.same({ 10, 11 }, saves)
            local item = annotations()[1]
            -- boundaries can only be moved on their own page
            local text = item.text
            hl:updateHighlight(1, 0, 1) -- start is on page 10, we are on page 11
            assert.are.equal(text, item.text)
            readerui.paging:onGotoPage(10)
            hl:updateHighlight(1, 1, -1) -- end is on page 11
            assert.are.equal(text, item.text)
            local x0 = item.pos0.x
            hl:updateHighlight(1, 0, 1)
            assert.are.equal(text:sub(4), item.text) -- "to " removed
            assert.are_not.equal(x0, item.pos0.x)
            assert.are.equal(item.pos0.x, item.ext[10].pos0.x)
            -- middle pages of a highlight are left untouched
            item.pos1.page = 12
            readerui.paging:onGotoPage(11)
            hl:updateHighlight(1, 1, -1)
            assert.are.equal(text:sub(4), item.text)
            item.pos1.page = 11
        end)

        it("should merge highlights on the same page and across pages", function()
            save_text(TEXT0, TEXT1)
            hold(WORD)
            hl:saveHighlight()
            hl:clear()
            -- annotations are kept sorted by position
            assert.are.equal("Penn", annotations()[1].text)
            annotations()[2].note = "n1"
            hl:mergeHighlights({ 2, 1 })
            assert.are.equal(1, #annotations())
            local merged = annotations()[1]
            assert.are.equal("Penn", merged.text:sub(1, 4))
            assert.are.equal("London", merged.text:sub(-6))
            assert.are.equal("n1", merged.note)
            assert.is_nil(merged.ext)
            readerui.paging:onGotoPage(11)
            local i3 = save_text(NEXT0, NEXT1)
            assert.are.equal(2, i3)
            hl:mergeHighlights({ 1, i3 })
            assert.are.equal(1, #annotations())
            merged = annotations()[1]
            assert.truthy(merged.ext[10] and merged.ext[11])
            assert.are.equal("Penn", merged.text:sub(1, 4))
        end)
    end)

    describe("embedded annotations", function()
        it("should import PDF markup annotations once", function()
            local index = save_text(TEXT0, TEXT1)
            local boxes = annotations()[index].pboxes
            readerui.annotation.annotations = {}
            local deleted = {}
            override(readerui.document, "deleteHighlight", function(_, page, item) table.insert(deleted, { page, item }) end)
            local embedded = {
                [10] = {
                    { boxes = boxes, type = 11, contents = "" },
                    { boxes = { { x = 50, y = 60, w = 30, h = 10 } }, type = 9, contents = "a comment" },
                },
            }
            local count, skipped = hl:importEmbeddedAnnotations(embedded)
            assert.are.equal(2, count)
            assert.are.equal(0, skipped)
            assert.are.equal(2, #deleted)
            assert.are.equal(2, #annotations())
            local struck, underlined
            for _, item in ipairs(annotations()) do
                if item.drawer == "strikeout" then struck = item end
                if item.drawer == "underscore" then underlined = item end
            end
            assert.is_nil(struck.note)
            assert.truthy(struck.text:find("London", 1, true))
            assert.are.equal("a comment", underlined.note)
            assert.is_nil(hl.selected_text)
            -- importing again finds duplicates
            count, skipped = hl:importEmbeddedAnnotations(embedded)
            assert.are.equal(0, count)
            assert.are.equal(2, skipped)
            assert.are.equal(2, #annotations())
        end)
    end)

    describe("panel zoom", function()
        it("should open the panel when found, or fall back to text selection", function()
            hl.panel_zoom_enabled = true
            local panel
            override(readerui.document, "getPanelFromPage", function() return panel end)
            -- no panel, no fallback
            hl.panel_zoom_fallback_to_text_selection = false
            assert.is_false(hold(WORD))
            assert.is_nil(hl.hold_pos)
            -- no panel, fallback to text
            hl.panel_zoom_fallback_to_text_selection = true
            assert.is_true(hold(WORD))
            assert.are.equal("Penn", hl.selected_text.text)
            hl:clear()
            -- a panel
            panel = Geom:new({ x = 0, y = 0, w = 100, h = 100 })
            local bb = Blitbuffer.new(10, 10)
            finally(function() bb:free() end)
            override(readerui.document, "drawPagePart", function() return bb, false end)
            assert.is_true(hold(WORD))
            assert.are.equal(bb, last_shown().image)
            assert.is_nil(hl.hold_pos)
            -- panel without image
            override(readerui.document, "drawPagePart", function() return nil end)
            hl.panel_zoom_fallback_to_text_selection = false
            assert.is_false(hold(WORD))
            -- outside the page
            assert.is_false(hl:onPanelZoom(nil, { pos = Geom:new({ x = 10, y = 100000 }) }))
        end)

        it("should toggle panel zoom settings from the menu", function()
            local menu_items = {}
            hl:addToMainMenu(menu_items)
            local allow, fallback = unpack(menu_items.panel_zoom_options.sub_item_table)
            assert.is_false(allow.checked_func())
            allow.callback()
            assert.is_true(hl.panel_zoom_enabled)
            assert.is_true(allow.checked_func())
            local before = G_reader_settings:getSettingForExt("panel_zoom_enabled", "pdf")
            allow.hold_callback()
            assert.are.equal(not before, G_reader_settings:getSettingForExt("panel_zoom_enabled", "pdf"))
            allow.hold_callback()
            assert.is_true(fallback.checked_func())
            fallback.callback()
            assert.is_false(hl.panel_zoom_fallback_to_text_selection)
            fallback.hold_callback()
            assert.is_false(G_reader_settings:getSettingForExt("panel_zoom_fallback_to_text_selection", "pdf"))
            fallback.callback()
            fallback.hold_callback()
            assert.is_true(G_reader_settings:getSettingForExt("panel_zoom_fallback_to_text_selection", "pdf"))
        end)

        it("should read paging highlight settings", function()
            hl:onReadSettings(LuaSettings:wrap({
                highlight_write_into_pdf = true,
                panel_zoom_enabled = true,
                panel_zoom_fallback_to_text_selection = false,
            }))
            assert.is_true(hl.highlight_write_into_pdf)
            assert.is_true(hl.panel_zoom_enabled)
            assert.is_false(hl.panel_zoom_fallback_to_text_selection)
            G_reader_settings:makeTrue("highlight_write_into_pdf")
            hl:onReadSettings(LuaSettings:wrap({}))
            assert.is_true(hl.highlight_write_into_pdf)
            assert.is_false(hl.panel_zoom_enabled)
            assert.is_true(hl.panel_zoom_fallback_to_text_selection)
            hl:onSaveSettings()
            assert.is_false(readerui.doc_settings:readSetting("panel_zoom_enabled"))
            assert.is_true(readerui.doc_settings:readSetting("highlight_write_into_pdf"))
        end)
    end)

    describe("OCR", function()
        local looked_up, translated
        before_each(function()
            looked_up, translated = nil, nil
            override(readerui.dictionary, "onLookupWord", function(_, w) looked_up = w end)
            override(Translator, "showTranslation", function(_, w) translated = w end)
            hl.hold_pos = { page = 10, x = 100, y = 100 }
            hl.selected_text = {
                text = "",
                sboxes = { { x = 10, y = 10, w = 20, h = 10 }, { x = 40, y = 10, w = 20, h = 10 } },
                pos0 = { page = 10, x = 100, y = 100 },
                pos1 = { page = 10, x = 100, y = 100 },
            }
        end)

        it("should OCR a word with no text layer for dictionary lookup", function()
            override(readerui.document, "getOCRText", function() return "recognized" end)
            hl:lookupDictWord()
            assert.are.equal("recognized", looked_up)
        end)

        it("should fall back to OCR word by word", function()
            override(readerui.document, "getOCRText", function() return nil end)
            override(readerui.document, "getOCRWord", function(_, page, box)
                assert.are.equal(10, page)
                return box.sbox.x == 10 and "ab" or "cd"
            end)
            hl:lookupDictWord()
            assert.are.equal("abcd", looked_up)
        end)

        it("should tell about missing OCR data and clear later", function()
            override(readerui.document, "getOCRText", function() return nil end)
            override(readerui.document, "getOCRWord", function() return nil end)
            hl:lookupDictWord()
            assert.is_nil(looked_up)
            assert.truthy(last_shown().text:find("No OCR results", 1, true))
            assert.truthy(hl.selected_text)
            tasks[#tasks].fn()
            assert.is_nil(hl.selected_text)
        end)

        it("should OCR for translation", function()
            override(readerui.document, "getOCRText", function() return "bonjour" end)
            hl:translate()
            assert.are.equal("bonjour", translated)
        end)

        it("should tell about missing OCR data for translation", function()
            override(readerui.document, "getOCRText", function() return "" end)
            hl:translate()
            assert.is_nil(translated)
            assert.truthy(last_shown().text:find("No OCR results", 1, true))
            tasks[#tasks].fn()
            assert.is_nil(hl.selected_text)
        end)
    end)

    describe("misc", function()
        it("should translate the current page without changing reflow", function()
            local translated
            override(Translator, "showTranslation", function(_, text) translated = text end)
            local wrap = readerui.document.configurable.text_wrap
            hl:onTranslateCurrentPage()
            assert.truthy(translated and #translated > 50)
            assert.are.equal(wrap, readerui.document.configurable.text_wrap)
        end)

        it("should anchor dialogs at the selection on screen", function()
            G_reader_settings:saveSetting("highlight_dialog_position", "gesture")
            select_text(TEXT0, TEXT1)
            local dialog = { getContentSize = function() return { h = 100 } end }
            local anchor, pop_down = hl:_getDialogAnchor(dialog)
            assert.is_true(pop_down)
            assert.truthy(anchor.y > TEXT1.y - 20)
            local index = hl:saveHighlight()
            hl:clear()
            local box = annotations()[index].pboxes[1]
            hl.view.highlight.visible_boxes = { { index = index, rect = box } }
            finally(function() hl.view.highlight.visible_boxes = {} end)
            anchor = hl:_getDialogAnchor(dialog, index)
            assert.truthy(anchor.y > 0)
        end)

        it("should clear paging temporary boxes", function()
            hold(WORD)
            assert.truthy(hl.view.highlight.temp[10])
            assert.is_true(hl:clear())
            assert.is_nil(hl.view.highlight.temp[10])
        end)
    end)
end)
