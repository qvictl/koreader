-- Opening a password-protected document, then cancelling the password prompt, must release
-- the document instance opened for the prompt. It stayed registered (reference count 1,
-- owned by nobody): its engine memory (MuPDF) was never freed, and the next open of the
-- same file reused it with a count of 2, so it was never freed for the rest of the session.
describe("ReaderUI password prompt cancelled", function()
    local DocumentRegistry, FileManager, ReaderUI, UIManager, ffiUtil
    local pdf, locked_doc, orig_open

    setup(function()
        require("commonrequire")
        disable_plugins()
        DocumentRegistry = require("document/documentregistry")
        FileManager = require("apps/filemanager/filemanager")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        ffiUtil = require("ffi/util")
        pdf = ffiUtil.realpath("spec/front/unit/data/2col.pdf")
        orig_open = DocumentRegistry.openDocument
        -- Make the PDF look password-protected.
        DocumentRegistry.openDocument = function(this, file, provider)
            local doc = orig_open(this, file, provider)
            if file == pdf and doc then
                locked_doc = doc
                doc.is_locked = true
                doc.unlock = function() return false end
            end
            return doc
        end
    end)

    teardown(function()
        DocumentRegistry.openDocument = orig_open
        if locked_doc then
            locked_doc.is_locked = nil
            locked_doc.unlock = nil
            while DocumentRegistry:getReferenceCount(pdf) do
                locked_doc:close()
            end
        end
        if ReaderUI.instance then ReaderUI.instance:onClose() end
        if FileManager.instance then FileManager.instance:onClose() end
        UIManager:quit()
        UIManager._exit_code = nil
    end)

    it("releases the document and goes back to the file browser", function()
        ReaderUI:showReader(pdf)
        fastforward_ui_events()
        local dialog = ReaderUI.password_dialog
        assert.truthy(dialog)
        assert.are.equal(1, DocumentRegistry:getReferenceCount(pdf))
        dialog.buttons[1][1].callback() -- Cancel
        assert.is_nil(ReaderUI.instance)
        assert.truthy(FileManager.instance)
        assert.is_nil(DocumentRegistry:getReferenceCount(pdf))
        assert.is_false(locked_doc.is_open)
    end)
end)
