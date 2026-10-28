describe("Readerui module", function()
    local DocumentRegistry, ReaderUI, DocSettings, UIManager, Screen
    local sample_epub = "spec/front/unit/data/juliet.epub"
    local readerui
    setup(function()
        require("commonrequire")
        disable_plugins()
        DocumentRegistry = require("document/documentregistry")
        ReaderUI = require("apps/reader/readerui")
        DocSettings = require("docsettings")
        UIManager = require("ui/uimanager")
        Screen = require("device").screen

        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(sample_epub),
        }
    end)
    it("should save settings", function()
        -- remove history settings and sidecar settings
        DocSettings:open(sample_epub):purge()
        local doc_settings = DocSettings:open(sample_epub)
        assert.are.same(doc_settings.data, {doc_path = sample_epub})
        readerui:saveSettings()
        assert.are_not.same(readerui.doc_settings.data, {doc_path = sample_epub})
        doc_settings = DocSettings:open(sample_epub)
        assert.truthy(doc_settings.data.last_xpointer)
        assert.are.same(doc_settings.data.last_xpointer,
                readerui.doc_settings.data.last_xpointer)
    end)
    it("should show reader", function()
        UIManager:quit()
        UIManager:show(readerui)
        UIManager:scheduleIn(1, function()
            UIManager:close(readerui)
            -- We haven't torn it down yet
            ReaderUI.instance = readerui
        end)
        UIManager:run()
    end)
    it("should close document", function()
        readerui:closeDocument()
        assert(readerui.document == nil)
        readerui:onClose()
    end)
    it("should not reset ReaderUI.instance by mistake", function()
        ReaderUI:doShowReader(sample_epub) -- spins up a new, sane instance
        local new_readerui = ReaderUI.instance
        assert.is.truthy(new_readerui.document)
        -- This *will* trip:
        -- * A pair of ReaderUI instance mimsatch warnings (on open/close) because it bypasses the safety of doShowReader!
        -- * A refcount warning from DocumentRegistry, because bypassinf the safeties means that two different instances opened the same Document.
        ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(sample_epub)
        }:onClose()
        assert.is.truthy(new_readerui.document)
        new_readerui:closeDocument()
        new_readerui:onClose()
    end)
    it("should close the end of book dialog when closing the book", function()
        -- Closing the book (e.g. Home) while ReaderStatus' end of book dialog is shown used to
        -- leave the dialog on the window stack, hidden under the next fullscreen widget forever
        -- (and flagged in UIManager._dirty), keeping this ReaderUI alive through its callbacks.
        UIManager:quit()
        ReaderUI:doShowReader(sample_epub)
        local ui = ReaderUI.instance
        ui.status:onEndOfBook()
        local dialog = UIManager:getTopmostVisibleWidget()
        assert.are.same("end_document", dialog.name)
        -- Modal widgets and toasts shown above the reader are left alone (they stay on top of
        -- whatever comes next, as before).
        local InfoMessage = require("ui/widget/infomessage")
        local Notification = require("ui/widget/notification")
        local info = InfoMessage:new{ text = "modal" }
        local toast = Notification:new{ text = "toast" }
        UIManager:show(info)
        UIManager:show(toast)
        ui:onClose()
        assert.is_nil(ReaderUI.instance)
        assert.is_false(UIManager:isWidgetShown(ui))
        assert.is_false(UIManager:isWidgetShown(dialog))
        assert.is_nil(UIManager._dirty[dialog])
        assert.is_true(UIManager:isWidgetShown(info))
        assert.is_true(UIManager:isWidgetShown(toast))
        UIManager:close(toast)
        UIManager:close(info)
    end)
end)
