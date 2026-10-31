describe("ReaderStatus deferred file navigation", function()
    local ReaderStatus, UIManager, FileChooser, DocumentRegistry, filemanagerutil
    local saved, target, selections, dialogs

    setup(function()
        require("commonrequire")
        ReaderStatus = require("apps/reader/modules/readerstatus")
        UIManager = require("ui/uimanager")
        FileChooser = require("ui/widget/filechooser")
        DocumentRegistry = require("document/documentregistry")
        filemanagerutil = require("apps/filemanager/filemanagerutil")
    end)

    before_each(function()
        saved = { queue = UIManager._task_queue, dirty = UIManager._task_queue_dirty,
            chooser = FileChooser.new, provider = DocumentRegistry.getProvider, show = UIManager.show,
            collate = G_reader_settings:readSetting("collate"),
            ask = G_reader_settings:readSetting("file_ask_to_open") }
        UIManager._task_queue = {}
        G_reader_settings:saveSetting("collate", "strcoll")
        G_reader_settings:saveSetting("file_ask_to_open", false)
        target, selections, dialogs = "next.pdf", {}, {}
        UIManager.show = function(_, dialog) dialogs[#dialogs + 1] = dialog end
        FileChooser.new = function()
            return { getNextOrPreviousFileInFolder = function(_, file, prev)
                selections[#selections + 1] = { file = file, prev = prev }
                return target
            end }
        end
        DocumentRegistry.getProvider = function() return {} end
    end)

    after_each(function()
        UIManager._task_queue, UIManager._task_queue_dirty = saved.queue, saved.dirty
        FileChooser.new, DocumentRegistry.getProvider = saved.chooser, saved.provider
        UIManager.show = saved.show
        for _, dialog in ipairs(dialogs) do dialog:free() end
        G_reader_settings:saveSetting("collate", saved.collate)
        G_reader_settings:saveSetting("file_ask_to_open", saved.ask)
    end)

    local function reader()
        local document = { file = "current.pdf" }
        local ui = { document = document, opened = {} }
        function ui:switchDocument(file)
            self.opened[#self.opened + 1] = file
            self.document = nil -- ReaderUI closes the old document before showing the next reader.
        end
        return ReaderStatus:extend{ ui = ui, document = document }
    end

    local function runQueued()
        local queue = UIManager._task_queue
        UIManager._task_queue = {}
        for _, task in ipairs(queue) do task.action() end
    end

    for _, prev in ipairs({ false, true }) do
        it("opens the " .. (prev and "previous" or "next") .. " file on the next tick", function()
            local status = reader()
            assert.is_true(status:onOpenNextOrPreviousFileInFolder(prev))
            assert.equals(0, #status.ui.opened)
            assert.same({{ file = "current.pdf", prev = prev }}, selections)
            runQueued()
            assert.same({ "next.pdf" }, status.ui.opened)
        end)
    end

    it("ignores a queued request after its reader has closed", function()
        local status = reader()
        status:onOpenNextOrPreviousFileInFolder(false)
        status.ui.document = nil
        runQueued()
        assert.same({}, status.ui.opened)
    end)

    it("only the first of rapid requests can use the old reader", function()
        local status = reader()
        status:onOpenNextOrPreviousFileInFolder(false)
        status:onOpenNextOrPreviousFileInFolder(true)
        assert.equals(2, #UIManager._task_queue)
        runQueued()
        assert.same({ "next.pdf" }, status.ui.opened)
    end)

    it("does not redirect a stale request to another document", function()
        local status = reader()
        status:onOpenNextOrPreviousFileInFolder(false)
        status.ui.document = { file = "replacement.pdf" }
        runQueued()
        assert.same({}, status.ui.opened)
    end)

    it("keeps a different reader's valid request", function()
        local old, current = reader(), reader()
        old:onOpenNextOrPreviousFileInFolder(false)
        current:onOpenNextOrPreviousFileInFolder(false)
        old.ui.document = nil
        runQueued()
        assert.same({}, old.ui.opened)
        assert.same({ "next.pdf" }, current.ui.opened)
    end)

    for _, collate in ipairs({ "access", "date" }) do
        it("still skips navigation for " .. collate .. " ordering", function()
            G_reader_settings:saveSetting("collate", collate)
            assert.is_true(reader():onOpenNextOrPreviousFileInFolder(false))
            assert.equals(0, #UIManager._task_queue)
            assert.equals(0, #selections)
        end)
    end
    it("ignores the second confirmation after the first switches readers", function()
        G_reader_settings:saveSetting("file_ask_to_open", true)
        local status = reader()
        status:onOpenNextOrPreviousFileInFolder(false)
        status:onOpenNextOrPreviousFileInFolder(false)
        runQueued()
        assert.equals(2, #dialogs)
        dialogs[1].ok_callback()
        dialogs[2].ok_callback()
        assert.same({ "next.pdf" }, status.ui.opened)
    end)

    it("ignores confirmation after Home without invoking the old menu callback", function()
        G_reader_settings:saveSetting("file_ask_to_open", true)
        local status = reader()
        local closed = false
        filemanagerutil.openFile(status.ui, "next.pdf", function() closed = true end)
        status.ui.document = nil
        dialogs[1].ok_callback()
        assert.is_false(closed)
        assert.same({}, status.ui.opened)
    end)

    it("ignores confirmation if its originating document was replaced", function()
        G_reader_settings:saveSetting("file_ask_to_open", true)
        local status = reader()
        filemanagerutil.openFile(status.ui, "next.pdf")
        status.ui.document = { file = "replacement.pdf" }
        dialogs[1].ok_callback()
        assert.same({}, status.ui.opened)
    end)

    it("rechecks the reader after the caller's pre-open callback", function()
        local status = reader()
        filemanagerutil.openFile(status.ui, "next.pdf", function() status.ui.document = nil end)
        assert.same({}, status.ui.opened)
    end)

    it("keeps valid reader callbacks and provider arguments", function()
        local status = reader()
        local called, switched, after, provider = false, false, function() end, {}
        DocumentRegistry.getProvider = function() return provider, true end
        function status.ui:switchDocument(file, seamless, callback, actual_provider, forced)
            switched = true
            assert.equals("next.pdf", file)
            assert.is_nil(seamless)
            assert.equals(after, callback)
            assert.equals(provider, actual_provider)
            assert.is_true(forced)
            assert.is_true(called)
        end
        filemanagerutil.openFile(status.ui, "next.pdf", function() called = true end, nil, after)
        assert.is_true(called)
        assert.is_true(switched)
    end)

    it("preserves auxiliary providers without closing the reader", function()
        local status = reader()
        local opened
        DocumentRegistry.getProvider = function()
            return { order = 1, callback = function(file) opened = file end }
        end
        filemanagerutil.openFile(status.ui, "next.pdf")
        assert.equals("next.pdf", opened)
        assert.equals(status.document, status.ui.document)
    end)

    it("keeps FileManager confirmation and callbacks without a document", function()
        G_reader_settings:saveSetting("file_ask_to_open", true)
        local called, opened, after = false, false, function() end
        local manager = { openFile = function(_, file, provider, seamless, forced, callback)
            assert.equals("next.pdf", file)
            assert.is_nil(provider)
            assert.is_nil(seamless)
            assert.is_nil(forced)
            assert.equals(after, callback)
            assert.is_true(called)
            opened = true
        end }
        filemanagerutil.openFile(manager, "next.pdf", function() called = true end, nil, after)
        assert.is_false(opened)
        dialogs[1].ok_callback()
        assert.is_true(opened)
    end)

    it("keeps no-dialog opens immediate even when confirmation is configured", function()
        G_reader_settings:saveSetting("file_ask_to_open", true)
        local status = reader()
        filemanagerutil.openFile(status.ui, "next.pdf", nil, true)
        assert.equals(0, #dialogs)
        assert.same({ "next.pdf" }, status.ui.opened)
    end)

end)
