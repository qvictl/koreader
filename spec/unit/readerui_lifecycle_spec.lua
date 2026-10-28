-- Unit tests for the ReaderUI open/close lifecycle: showReader() and its
-- coroutine, ReaderUI.instance bookkeeping, password-protected / unsupported /
-- missing / unloadable documents, archived metadata restore, close/reload/
-- switch/home, and the helpers around them.
describe("ReaderUI lifecycle", function()
    local DataStorage, DocSettings, DocumentRegistry, Event, FileManager, ReaderUI, UIManager
    local Device, Screen, ffiUtil, lfs, logger, util
    -- Absolute paths, as used by the file browser and the reading history
    local data_dir, sample_epub, other_epub, sample_pdf, text_pdf
    local tmp_dir

    -- Captures every widget shown, while still showing it for real.
    local shown
    local orig_show
    local function captureShow()
        shown = {}
        orig_show = UIManager.show
        UIManager.show = function(this, widget, ...)
            table.insert(shown, widget)
            return orig_show(this, widget, ...)
        end
    end
    local function releaseShow()
        UIManager.show = orig_show
    end
    local function shownWithText(pattern)
        for i = #shown, 1, -1 do
            local text = shown[i].text
            if type(text) == "string" and text:find(pattern) then
                return shown[i]
            end
        end
    end

    -- Wrap DocumentRegistry:openDocument, to tweak the opened document.
    local orig_open
    local function hookOpen(tweak)
        orig_open = DocumentRegistry.openDocument
        DocumentRegistry.openDocument = function(this, file, provider)
            local doc = orig_open(this, file, provider)
            return tweak(doc, file)
        end
    end
    local function unhookOpen()
        if orig_open then
            DocumentRegistry.openDocument = orig_open
            orig_open = nil
        end
    end

    local function closeEverything()
        if ReaderUI.instance then
            ReaderUI.instance:onClose()
        end
        if FileManager.instance then
            FileManager.instance:onClose()
        end
        for i = #UIManager._window_stack, 1, -1 do
            UIManager:close(UIManager._window_stack[i].widget)
        end
    end

    local function openReader(file, ...)
        ReaderUI:showReader(file, ...)
        fastforward_ui_events()
        return ReaderUI.instance
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        DataStorage = require("datastorage")
        DocSettings = require("docsettings")
        DocumentRegistry = require("document/documentregistry")
        Event = require("ui/event")
        FileManager = require("apps/filemanager/filemanager")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        Device = require("device")
        Screen = Device.screen
        ffiUtil = require("ffi/util")
        lfs = require("libs/libkoreader-lfs")
        logger = require("logger")
        util = require("util")
        data_dir = ffiUtil.realpath("spec/front/unit/data")
        sample_epub = data_dir .. "/juliet.epub"
        other_epub = data_dir .. "/leaves.epub"
        sample_pdf = data_dir .. "/2col.pdf"
        text_pdf = data_dir .. "/paper.pdf"
        tmp_dir = DataStorage:getDataDir() .. "/readerui_lifecycle"
        ffiUtil.purgeDir(tmp_dir)
        util.makePath(tmp_dir)
    end)

    teardown(function()
        closeEverything()
        ffiUtil.purgeDir(tmp_dir)
        UIManager:quit()
        UIManager._exit_code = nil
    end)

    before_each(function()
        captureShow()
    end)

    after_each(function()
        releaseShow()
        unhookOpen()
        closeEverything()
        assert.is_nil(ReaderUI.instance)
        assert.is_nil(FileManager.instance)
    end)

    describe("showReader()", function()
        it("opens a document through the coroutine and registers the instance", function()
            local after_open = spy.new(function() end)
            local reader = openReader(sample_epub, nil, false, nil, after_open)
            assert.truthy(reader)
            assert.are.equal(sample_epub, reader.document.file)
            assert.is_true(UIManager:isWidgetShown(reader))
            assert.spy(after_open).was_called(1)
            assert.spy(after_open).was_called_with(match.is_ref(reader))
            assert.is_nil(reader.after_open_callback)
            assert.is_nil(reader.reloading)
            assert.truthy(shownWithText("^Opening file"))
            -- the class itself does not keep per-open state around
            assert.is_nil(ReaderUI.after_open_callback)
            assert.is_nil(ReaderUI.md5_checksum)
            -- lastfile now points to it
            assert.are.equal(sample_epub, G_reader_settings:readSetting("lastfile"))
            reader:onClose()
            assert.is_nil(ReaderUI.instance)
            assert.is_nil(reader.document)
            assert.is_false(UIManager:isWidgetShown(reader))
            assert.is_nil(DocumentRegistry:getReferenceCount(sample_epub))
        end)

        it("tells about a missing file and does nothing else", function()
            ReaderUI:showReader(tmp_dir .. "/missing.epub")
            assert.truthy(shownWithText("does not exist"))
            assert.is_nil(ReaderUI.instance)
            assert.is_nil(FileManager.instance)
            -- no coroutine scheduled
            assert.is_nil(shownWithText("^Opening file"))
        end)

        it("tells about an unsupported file and goes back to the file browser on it", function()
            local file = tmp_dir .. "/notes.unknownext"
            local f = assert(io.open(file, "w"))
            f:write("hello")
            f:close()
            ReaderUI:showReader(file)
            assert.truthy(shownWithText("is not supported"))
            assert.is_nil(ReaderUI.instance)
            assert.truthy(FileManager.instance)
            assert.are.equal(ffiUtil.realpath(tmp_dir), FileManager.instance.file_chooser.path)
        end)

        it("closes the file browser and the previous reader before opening", function()
            FileManager:showFiles(data_dir)
            local fm = FileManager.instance
            assert.truthy(fm)
            local first = openReader(sample_epub)
            assert.is_nil(FileManager.instance)
            assert.is_false(UIManager:isWidgetShown(fm))
            assert.truthy(first)
            -- the old instance gets ShowingReader: it closes itself without a full refresh
            local close = spy.on(UIManager, "close")
            local second = openReader(other_epub)
            assert.spy(close).was_called_with(match.is_ref(UIManager), match.is_ref(first), false)
            close:revert()
            assert.is_true(first.tearing_down)
            assert.is_nil(first.document)
            assert.are_not.equal(first, second)
            assert.are.equal(second, ReaderUI.instance)
            assert.are.equal(other_epub, second.document.file)
        end)

        it("asks to restore archived metadata for a book opened before on this device", function()
            local arc_dir = tmp_dir .. "/arc"
            util.makePath(arc_dir)
            G_reader_settings:saveSetting("document_metadata_arc_folder", arc_dir)
            local copy = tmp_dir .. "/restored.epub"
            ffiUtil.copyFile(sample_epub, copy)
            local md5 = util.partialMD5(copy)
            local arc_file = arc_dir .. "/" .. md5 .. ".lua"
            local function writeArc()
                local f = assert(io.open(arc_file, "w"))
                f:write(string.format([[return {
                    partial_md5_checksum = %q,
                    doc_path = "/old/location/restored.epub",
                    archived_marker = "kept",
                    summary = { status = "reading" },
                    metadata_arc = { datetime = "2020-01-01 00:00:00", custom_props = { title = "Archived title" } },
                    doc_props = { title = "Original title" },
                }]], md5))
                f:close()
                local f2 = assert(io.open(arc_file .. ".old", "w"))
                f2:write("return {}")
                f2:close()
            end
            writeArc()

            ReaderUI:showReader(copy)
            local confirm = shown[#shown]
            assert.truthy(confirm.text:find("previously opened on this device", 1, true))
            assert.is_nil(ReaderUI.instance) -- waiting for the answer
            confirm.ok_callback()
            fastforward_ui_events()
            local reader = ReaderUI.instance
            assert.truthy(reader)
            -- the archived settings were applied, re-pointed at the new location
            assert.are.equal("kept", reader.doc_settings:readSetting("archived_marker"))
            assert.are.equal(copy, reader.doc_settings:readSetting("doc_path"))
            assert.is_nil(reader.doc_settings:readSetting("metadata_arc"))
            assert.is_nil(ReaderUI.arc_settings_data)
            -- custom metadata restored into its own file
            local custom_file = DocSettings:findCustomMetadataFile(copy)
            assert.truthy(custom_file)
            local custom = DocSettings.openSettingsFile(custom_file)
            assert.are.equal("Archived title", custom:readSetting("custom_props").title)
            assert.are.equal("Archived title", reader.doc_props.title)
            -- the archive entries are consumed
            assert.is_nil(lfs.attributes(arc_file))
            assert.is_nil(lfs.attributes(arc_file .. ".old"))
            reader:onClose()

            -- Discard: start over with a fresh copy (not opened before)
            DocSettings:open(copy):purge()
            require("ui/widget/booklist").book_info_cache[copy] = nil
            writeArc()
            ReaderUI:showReader(copy)
            confirm = shown[#shown]
            confirm.cancel_callback()
            fastforward_ui_events()
            reader = ReaderUI.instance
            assert.truthy(reader)
            assert.is_nil(reader.doc_settings:readSetting("archived_marker"))
            assert.is_nil(lfs.attributes(arc_file))
            reader:onClose()
            G_reader_settings:delSetting("document_metadata_arc_folder")
        end)

        it("shows the file browser when the document cannot be opened", function()
            hookOpen(function(doc) if doc then doc:close() end end)
            local reader = openReader(sample_epub)
            assert.is_nil(reader)
            assert.truthy(shownWithText("No reader engine for this file or invalid file"))
            assert.truthy(FileManager.instance)
            assert.is_nil(DocumentRegistry:getReferenceCount(sample_epub))
        end)

        it("recovers from a crash while opening the document", function()
            hookOpen(function(doc)
                if doc then doc:close() end
                error("simulated engine crash")
            end)
            local set_ignore = spy.on(Device, "setIgnoreInput")
            local stderr = io.stderr
            local stderr_lines = {}
            io.stderr = { write = function(_, s) table.insert(stderr_lines, s) end } -- luacheck: ignore
            local reader = openReader(sample_epub)
            io.stderr = stderr -- luacheck: ignore
            assert.is_nil(reader)
            assert.truthy(table.concat(stderr_lines):find("doShowReader coroutine crashed", 1, true))
            assert.truthy(table.concat(stderr_lines):find("simulated engine crash", 1, true))
            assert.spy(set_ignore).was_called_with(match.is_ref(Device), false)
            set_ignore:revert()
            assert.truthy(shownWithText("No reader engine for this file or invalid file"))
            assert.truthy(FileManager.instance)
        end)

        it("bails out when crengine cannot load the document (KOReader exits)", function()
            local opened
            hookOpen(function(doc)
                opened = doc
                doc.loadDocument = function() return false end
                return doc
            end)
            ReaderUI:showReader(other_epub)
            fastforward_ui_events()
            local msg = shownWithText("^Failed recognizing or parsing this file")
            assert.truthy(msg)
            assert.is_nil(ReaderUI.instance)
            -- dismissing the message resumes the coroutine, which then errors out on purpose
            msg.dismiss_callback()
            UIManager:close(msg)
            assert.is_nil(ReaderUI.instance)
            assert.is_nil(FileManager.instance)
            -- nothing left to show: the UI loop will quit
            local readers = 0
            for _, w in ipairs(UIManager._window_stack) do
                if w.widget.name == "ReaderUI" then readers = readers + 1 end
            end
            assert.are.equal(0, readers)
            opened:close()
        end)
    end)

    describe("password protected documents", function()
        local locked_doc
        before_each(function()
            hookOpen(function(doc, file)
                if file == sample_pdf and doc then
                    locked_doc = doc
                    doc.is_locked = true
                    doc.unlock = function(this, password)
                        if password == "secret" then
                            this.is_locked = false
                            return true
                        end
                        return false
                    end
                end
                return doc
            end)
        end)
        after_each(function()
            if locked_doc then
                locked_doc.unlock = nil
                locked_doc.is_locked = nil
                locked_doc = nil
            end
        end)

        it("asks again on a wrong password, then opens the document", function()
            ReaderUI:showReader(sample_pdf)
            fastforward_ui_events()
            assert.is_nil(ReaderUI.instance)
            local dialog = ReaderUI.password_dialog
            assert.truthy(dialog)
            assert.are.equal("Input document password", dialog.title)
            assert.are.equal("password", dialog.text_type)
            assert.is_true(UIManager:isWidgetShown(dialog))
            -- wrong password
            dialog:setInputText("guess")
            dialog.buttons[1][2].callback()
            assert.is_false(UIManager:isWidgetShown(dialog))
            local retry = ReaderUI.password_dialog
            assert.are_not.equal(dialog, retry)
            assert.are.equal("Password is incorrect, try again?", retry.title)
            assert.is_nil(ReaderUI.instance)
            -- right password: the coroutine resumes and the reader opens
            retry:setInputText("secret")
            retry.buttons[1][2].callback()
            assert.is_false(UIManager:isWidgetShown(retry))
            local reader = ReaderUI.instance
            assert.truthy(reader)
            assert.are.equal(locked_doc, reader.document)
            assert.is_false(locked_doc.is_locked)
            reader:onClose()
            assert.is_nil(DocumentRegistry:getReferenceCount(sample_pdf))
        end)

        it("goes back to the file browser when the password prompt is cancelled", function()
            ReaderUI:showReader(sample_pdf)
            fastforward_ui_events()
            local dialog = ReaderUI.password_dialog
            dialog.buttons[1][1].callback()
            assert.is_false(UIManager:isWidgetShown(dialog))
            assert.is_nil(ReaderUI.instance)
            assert.truthy(FileManager.instance)
            assert.are.equal(data_dir, FileManager.instance.file_chooser.path)
            -- release the document instance opened for the prompt, if still registered
            while DocumentRegistry:getReferenceCount(sample_pdf) do
                locked_doc:close()
            end
        end)
    end)

    describe("instance bookkeeping", function()
        it("complains when a second instance is created behind its back", function()
            local first = openReader(sample_epub)
            local err = spy.on(logger, "err")
            local warn = spy.on(logger, "warn")
            -- doShowReader() closes the existing instance first
            ReaderUI:doShowReader(other_epub)
            assert.spy(warn).was_called()
            assert.is_nil(first.document)
            local second = ReaderUI.instance
            assert.are.equal(other_epub, second.document.file)
            assert.spy(err).was_not_called()
            -- creating one by hand trips the mismatch error, and takes over the instance
            local third = ReaderUI:new{
                dimen = Screen:getSize(),
                document = DocumentRegistry:openDocument(sample_epub),
            }
            assert.spy(err).was_called()
            assert.are.equal(third, ReaderUI.instance)
            err:revert()
            warn:revert()
            third:onClose()
            assert.is_nil(ReaderUI.instance)
            second:onClose()
        end)

        it("doShowReader() closes the file browser and avoids flashing when seamless", function()
            FileManager:showFiles(data_dir)
            assert.truthy(FileManager.instance)
            local avoid = spy.on(UIManager, "avoidFlashOnNextRepaint")
            ReaderUI:doShowReader(sample_epub, nil, true)
            assert.spy(avoid).was_called(1)
            avoid:revert()
            assert.is_nil(FileManager.instance)
            assert.truthy(ReaderUI.instance)
        end)
    end)

    describe("closing, reloading and switching", function()
        it("onClose() saves the book state and releases the document", function()
            local reader = openReader(sample_epub)
            reader.doc_settings:saveSetting("lifecycle_marker", 42)
            local discard = spy.on(reader.document, "discardChange")
            local is_edited = stub(reader.document, "isEdited", true)
            reader:onClose()
            assert.spy(discard).was_called(1)
            is_edited:revert()
            assert.is_nil(reader.document)
            assert.is_nil(ReaderUI.instance)
            assert.are.equal(42, DocSettings:open(sample_epub):readSetting("lifecycle_marker"))
            assert.is_nil(DocumentRegistry:getReferenceCount(sample_epub))
        end)

        it("onFlushSettings() saves, and notifies when asked to", function()
            local reader = openReader(sample_epub)
            local Notification = require("ui/widget/notification")
            local notify = stub(Notification, "notify")
            reader.doc_settings:saveSetting("lifecycle_marker", 7)
            reader:onFlushSettings()
            assert.stub(notify).was_not_called()
            assert.are.equal(7, DocSettings:open(sample_epub):readSetting("lifecycle_marker"))
            reader:onFlushSettings(true)
            assert.stub(notify).was_called_with(match.is_ref(Notification), "Book metadata saved.")
            notify:revert()
        end)

        it("onSetupShowReader() only prepares the teardown", function()
            local reader = openReader(sample_epub)
            reader.dithered = true
            reader:onSetupShowReader()
            assert.is_true(reader.tearing_down)
            assert.is_nil(reader.dithered)
            assert.truthy(reader.document)
            assert.are.equal(reader, ReaderUI.instance)
        end)

        it("onHome() closes the book and shows the file browser on it", function()
            local reader = openReader(sample_epub)
            assert.is_true(reader:onHome())
            assert.is_nil(ReaderUI.instance)
            assert.is_nil(reader.document)
            assert.truthy(FileManager.instance)
            assert.are.equal(data_dir, FileManager.instance.file_chooser.path)
        end)

        it("reloadDocument() reopens the same document with the same provider", function()
            local reader = openReader(sample_epub)
            local provider = getmetatable(reader.document).__index
            local after_close = spy.new(function() end)
            local after_open = spy.new(function() end)
            local highlight_close = spy.on(reader.highlight, "onClose")
            reader:reloadDocument(after_close, true, after_open)
            assert.spy(highlight_close).was_called(1)
            assert.spy(after_close).was_called_with(sample_epub, match.is_ref(provider))
            assert.is_nil(ReaderUI.instance)
            fastforward_ui_events()
            local reloaded = ReaderUI.instance
            assert.truthy(reloaded)
            assert.are_not.equal(reader, reloaded)
            assert.are.equal(sample_epub, reloaded.document.file)
            assert.spy(after_open).was_called_with(match.is_ref(reloaded))
            -- the reloading flag was handed over to the new instance, then cleared once ready
            assert.is_nil(reloaded.reloading)
        end)

        it("onReload() reloads", function()
            local reader = openReader(sample_epub)
            reader:onReload()
            fastforward_ui_events()
            assert.truthy(ReaderUI.instance)
            assert.are_not.equal(reader, ReaderUI.instance)
            assert.are.equal(sample_epub, ReaderUI.instance.document.file)
        end)

        it("switchDocument() closes the current book and opens the new one", function()
            local reader = openReader(sample_epub)
            reader:switchDocument(nil) -- no-op
            assert.are.equal(reader, ReaderUI.instance)
            local after_open = spy.new(function() end)
            reader:switchDocument(other_epub, false, after_open)
            assert.is_true(reader.tearing_down)
            assert.is_nil(reader.document)
            fastforward_ui_events()
            assert.are.equal(other_epub, ReaderUI.instance.document.file)
            assert.spy(after_open).was_called(1)
        end)

        it("onOpenLastDoc() opens the previous book", function()
            local first = openReader(other_epub)
            first:onClose()
            local reader = openReader(sample_epub)
            assert.are.equal(other_epub, reader.menu:getPreviousFile())
            reader:onOpenLastDoc()
            fastforward_ui_events()
            assert.are.equal(other_epub, ReaderUI.instance.document.file)
        end)
    end)

    describe("helpers", function()
        it("remembers the folder to show in the file browser, once", function()
            local reader = openReader(sample_epub)
            reader:setLastDirForFileBrowser("/mnt/us/documents/")
            assert.are.equal("/mnt/us/documents", reader.last_dir_for_file_browser)
            assert.are.equal("/mnt/us/documents", reader:getLastDirFile(true))
            -- consumed: back to the last file's folder
            local dir, file = reader:getLastDirFile(true)
            assert.are.equal(data_dir, dir)
            assert.are.equal(sample_epub, file)
            -- "/" stays "/"
            reader:setLastDirForFileBrowser("/")
            assert.are.equal("/", reader.last_dir_for_file_browser)
            reader:setLastDirForFileBrowser(nil)
            -- the quickstart guide is not a folder to go back to
            local QuickStart = require("ui/quickstart")
            G_reader_settings:saveSetting("lastfile", QuickStart.quickstart_filename)
            dir, file = reader:getLastDirFile()
            assert.is_nil(dir)
            assert.are.equal(QuickStart.quickstart_filename, file)
        end)

        it("showFileManager() reuses an existing file browser", function()
            FileManager:showFiles(tmp_dir)
            local fm = FileManager.instance
            local change = spy.on(fm.file_chooser, "changeToPath")
            local selected = { [sample_epub] = true }
            ReaderUI:showFileManager(sample_epub, selected)
            assert.are.equal(fm, FileManager.instance)
            assert.spy(change).was_called_with(match.is_ref(fm.file_chooser), data_dir .. "/", sample_epub)
            assert.are.equal(selected, fm.selected_files)
            change:revert()
        end)

        it("showFileManager() without a file goes to the last folder", function()
            local reader = openReader(sample_epub)
            reader:onClose()
            reader:setLastDirForFileBrowser(tmp_dir)
            reader:showFileManager()
            assert.are.equal(ffiUtil.realpath(tmp_dir), FileManager.instance.file_chooser.path)
        end)

        it("onScreenResize() updates the dimensions and touch zones", function()
            local reader = openReader(sample_epub)
            local update = spy.on(reader, "updateTouchZonesOnScreenResize")
            local dimen = { x = 0, y = 0, w = 300, h = 400 }
            reader:onScreenResize(dimen)
            assert.are.equal(dimen, reader.dimen)
            assert.spy(update).was_called_with(match.is_ref(reader), match.is_ref(dimen))
            update:revert()
            reader:onScreenResize(Screen:getSize())
        end)

        it("keeps the book info cache up to date", function()
            local BookList = require("ui/widget/booklist")
            local reader = openReader(sample_epub)
            local pages = reader.document:getPageCount()
            reader:onDocumentRerendered()
            assert.are.equal(pages, reader.doc_settings:readSetting("doc_pages"))
            assert.are.equal(pages, BookList.book_info_cache[sample_epub].pages)
            -- page labels from the publisher's page map
            reader.doc_settings:saveSetting("pagemap_doc_pages", 321)
            reader.doc_settings:makeTrue("pagemap_use_page_labels")
            reader:onUsePageLabelsUpdated()
            assert.are.equal(321, BookList.book_info_cache[sample_epub].pages)
            -- a re-render keeps the page map count
            reader:onDocumentRerendered()
            assert.are.equal(321, BookList.book_info_cache[sample_epub].pages)
            reader.doc_settings:makeFalse("pagemap_use_page_labels")
            reader:onUsePageLabelsUpdated()
            assert.are.equal(pages, BookList.book_info_cache[sample_epub].pages)
            -- annotations
            reader:onAnnotationsModified({ index_modified = true })
            assert.is_false(BookList.book_info_cache[sample_epub].has_annotations)
            reader.doc_settings:delSetting("pagemap_doc_pages")
            reader.doc_settings:delSetting("pagemap_use_page_labels")
        end)

        it("getCurrentPage() works for both engines", function()
            local reader = openReader(sample_epub)
            assert.are.equal(reader.document:getCurrentPage(), reader:getCurrentPage())
            reader:onClose()
            reader = openReader(sample_pdf)
            assert.are.equal(reader.paging.current_page, reader:getCurrentPage())
        end)
    end)

    describe("extendProvider()", function()
        local cre_provider, pdf_provider
        setup(function()
            cre_provider = DocumentRegistry:getProvider(sample_epub)
            pdf_provider = DocumentRegistry:getProvider(sample_pdf)
        end)
        local function makeZip(path, entry, content)
            local Archiver = require("ffi/archiver")
            local writer = Archiver.Writer:new()
            assert.is_true(writer:open(path, "zip"))
            if entry then
                writer:addFileFromMemory(entry, content)
            end
            writer:close()
        end

        it("flags fb2 and txt documents from their extension", function()
            local p = ReaderUI:extendProvider("book.fb2", { provider = "crengine" })
            assert.is_true(p.is_fb2)
            assert.is_false(p.is_txt)
            p = ReaderUI:extendProvider("book.txt", { provider = "crengine" })
            assert.is_false(p.is_fb2)
            assert.is_true(p.is_txt)
            p = ReaderUI:extendProvider("book.fb2.zip", { provider = "crengine" })
            assert.is_true(p.is_fb2)
        end)

        it("looks inside a zip archive to choose the provider", function()
            local zip = tmp_dir .. "/inside_txt.zip"
            makeZip(zip, "folder/Story.TXT", "Once upon a time")
            local p = ReaderUI:extendProvider(zip, pdf_provider)
            assert.are.equal(cre_provider, p)
            assert.is_true(p.is_txt)
            assert.is_false(p.is_fb2)
            p.is_txt = nil
            p.is_fb2 = nil
        end)

        it("keeps a forced provider for a zip archive", function()
            local zip = tmp_dir .. "/inside_fb2.zip"
            makeZip(zip, "book.fb2", "<FictionBook/>")
            local p = ReaderUI:extendProvider(zip, pdf_provider, true)
            assert.are.equal(pdf_provider, p)
            assert.is_true(p.is_fb2)
            p.is_txt = nil
            p.is_fb2 = nil
        end)

        it("handles an unreadable or empty zip archive", function()
            local zip = tmp_dir .. "/garbage.zip"
            local f = assert(io.open(zip, "w"))
            f:write("not a zip")
            f:close()
            local p = ReaderUI:extendProvider(zip, { provider = "dummy" })
            assert.is_false(p.is_fb2)
            assert.is_false(p.is_txt)
            local empty = tmp_dir .. "/empty.zip"
            makeZip(empty)
            p = ReaderUI:extendProvider(empty, { provider = "dummy" })
            assert.is_false(p.is_txt)
        end)
    end)

    describe("findTextInBookContent()", function()
        it("finds text in a document without touching the reader's crengine cache", function()
            local cre = require("libs/libkoreader-cre")
            local init_cache = stub(cre, "initCache")
            local caller = {}
            local found = ReaderUI:findTextInBookContent(caller, other_epub, "LEAVES")
            assert.stub(init_cache).was_called_with("", 0, true, 40)
            assert.is_true(caller.is_cre_cache_disabled)
            assert.is_string(found)
            assert.truthy(found:find("^/body"))
            -- case sensitive: not found
            caller.case_sensitive = true
            assert.is_false(ReaderUI:findTextInBookContent(caller, other_epub, "lEaVeS"))
            assert.stub(init_cache).was_called(1)
            init_cache:revert()
            assert.is_nil(DocumentRegistry:getReferenceCount(other_epub))
        end)

        it("returns a page number for paged documents", function()
            local page = ReaderUI:findTextInBookContent({ is_cre_cache_disabled = true }, text_pdf, "the")
            assert.is_number(page)
            assert.is_nil(DocumentRegistry:getReferenceCount(text_pdf))
        end)

        it("returns false for a document that cannot be opened", function()
            local broken = tmp_dir .. "/broken.pdf"
            local f = assert(io.open(broken, "w"))
            f:write("%PDF-garbage")
            f:close()
            assert.is_false(ReaderUI:findTextInBookContent({ is_cre_cache_disabled = true }, broken, "x"))
        end)
    end)

    -- Keep Event referenced for the ShowingReader broadcast tests above
    it("broadcasts ShowingReader to the current reader", function()
        local reader = openReader(sample_epub)
        UIManager:broadcastEvent(Event:new("ShowingReader"))
        assert.is_true(reader.tearing_down)
        assert.is_nil(ReaderUI.instance)
    end)
end)
