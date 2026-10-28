-- Books whose saved progress predates xpointers (only `last_percent` in their settings)
-- must reopen at that position, in page mode as in scroll mode. In page mode, the
-- restore went to the right page, then jumped back to the top of the book
-- (gotoPos(self.current_pos), which isn't maintained in page mode).
describe("ReaderRolling legacy last_percent", function()
    local DataStorage, DocSettings, DocumentRegistry, ReaderUI, UIManager, Screen, ffiutil
    local epub

    local function reopen(settings)
        DocSettings:open(epub):purge()
        local ds = DocSettings:open(epub)
        for k, v in pairs(settings) do
            ds:saveSetting(k, v)
        end
        ds:flush()
        return ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(epub),
        }
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        DataStorage = require("datastorage")
        DocSettings = require("docsettings")
        DocumentRegistry = require("document/documentregistry")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        Screen = require("device").screen
        ffiutil = require("ffi/util")
        epub = DataStorage:getDataDir() .. "/readerrolling_legacy_percent.epub"
        ffiutil.copyFile("spec/front/unit/data/juliet.epub", epub)
    end)

    teardown(function()
        DocSettings:open(epub):purge()
        os.remove(epub)
        UIManager:quit()
        UIManager._exit_code = nil
    end)

    it("restores it in page mode", function()
        local ui = reopen({ last_percent = 0.5 })
        assert.are.equal("page", ui.view.view_mode)
        local half = ui.document:getPageCount() / 2
        assert.are.near(half, ui.rolling.current_page, 2)
        assert.are.near(half, ui.document:getCurrentPage(), 2)
        assert.are.equal(ui.document:getXPointer(), ui.rolling.xpointer)
        ui:closeDocument()
        ui:onClose()
    end)

    it("restores it in scroll mode", function()
        local ui = reopen({ last_percent = 0.5, copt_view_mode = 1 })
        assert.are.equal("scroll", ui.view.view_mode)
        assert.are.near(ui.document.info.doc_height / 2, ui.rolling.current_pos, 1)
        assert.are.equal(ui.document:getXPointer(), ui.rolling.xpointer)
        ui:closeDocument()
        ui:onClose()
    end)
end)
