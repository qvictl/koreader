describe("FileManager operations", function()
    local BookList, ButtonDialog, ConfirmBox, DataStorage, Device, DocSettings, DocumentRegistry
    local FileChooser, FileManager, InfoMessage, InputDialog, MultiConfirmBox, ReadCollection, ReadHistory
    local Screen, UIManager, ffiUtil, lfs, util

    local base -- realpath of a per-test scratch folder
    local fm
    local shown -- widgets passed to UIManager:show
    local saved_settings, saved_fc, saved_device_home
    -- cleanups registered by a test, run by after_each even when the test fails
    local cleanups = {}
    local function defer(fn)
        table.insert(cleanups, fn)
    end

    local settings_keys = {
        "home_dir", "lock_home_folder", "collate", "collate_mixed", "reverse_collate", "show_flat_view",
        "show_hidden", "show_unsupported", "show_parent_folder", "back_to_exit", "back_in_filemanager",
        "lastfile", "lastdir", "lock_rotation", "fm_rotation_mode", "document_metadata_arc_folder",
        "document_metadata_arc_on_deletion", "shorten_home_dir", "show_file_in_bold",
    }
    local fc_keys = { "show_flat_view", "show_hidden", "show_unsupported", "show_filter" }

    local function writeFile(path, content)
        local f = assert(io.open(path, "w"))
        f:write(content or "x")
        f:close()
    end

    local function readFile(path)
        local f = io.open(path, "r")
        if not f then return end
        local content = f:read("*a")
        f:close()
        return content
    end

    local function mode(path)
        return lfs.attributes(path, "mode")
    end

    local function lastShown(class)
        for i = #shown, 1, -1 do
            if getmetatable(shown[i]) == class then
                return shown[i]
            end
        end
    end

    local function countShown(class)
        local n = 0
        for _, w in ipairs(shown) do
            if getmetatable(w) == class then n = n + 1 end
        end
        return n
    end

    local function findButton(rows, text)
        for _, row in ipairs(rows) do
            for _, button in ipairs(row) do
                local button_text = button.text or (button.text_func and button.text_func())
                if button_text == text then
                    return button
                end
            end
        end
    end

    local function itemTexts(item_table)
        local t = {}
        for _, item in ipairs(item_table) do
            if not item.is_go_up then
                table.insert(t, item.text)
            end
        end
        return t
    end

    local function findItem(path)
        for _, item in ipairs(fm.file_chooser.item_table) do
            if item.path == path then
                return item
            end
        end
    end

    local function historyIndex(file)
        return ReadHistory:getIndexByFile(file)
    end

    local function dropHistoryUnder(dir)
        for i = #ReadHistory.hist, 1, -1 do
            if ReadHistory.hist[i].file:sub(1, #dir) == dir then
                table.remove(ReadHistory.hist, i)
            end
        end
    end

    local function chmodTree(path, perm)
        os.execute(string.format("chmod -R %s '%s' 2>/dev/null", perm, path))
    end

    -- Returns true if the current user really cannot write in a 0555 folder (i.e., not root)
    local function readOnlyDirIsEnforced(dir)
        local probe = dir .. "/.probe"
        local f = io.open(probe, "w")
        if f then
            f:close()
            os.remove(probe)
            return false
        end
        return true
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        BookList = require("ui/widget/booklist")
        ButtonDialog = require("ui/widget/buttondialog")
        ConfirmBox = require("ui/widget/confirmbox")
        DataStorage = require("datastorage")
        Device = require("device")
        DocSettings = require("docsettings")
        DocumentRegistry = require("document/documentregistry")
        FileChooser = require("ui/widget/filechooser")
        FileManager = require("apps/filemanager/filemanager")
        InfoMessage = require("ui/widget/infomessage")
        InputDialog = require("ui/widget/inputdialog")
        MultiConfirmBox = require("ui/widget/multiconfirmbox")
        ReadCollection = require("readcollection")
        ReadHistory = require("readhistory")
        Screen = Device.screen
        UIManager = require("ui/uimanager")
        ffiUtil = require("ffi/util")
        lfs = require("libs/libkoreader-lfs")
        util = require("util")
        ReadCollection:_read()
    end)

    before_each(function()
        saved_settings = {}
        for _, key in ipairs(settings_keys) do
            saved_settings[key] = G_reader_settings:readSetting(key)
        end
        saved_fc = {}
        for _, key in ipairs(fc_keys) do
            saved_fc[key] = FileChooser[key]
        end
        FileChooser.show_flat_view = false
        FileChooser.show_hidden = false
        FileChooser.show_unsupported = false
        FileChooser.show_filter = {}
        saved_device_home = rawget(Device, "home_dir")
        G_reader_settings:saveSetting("collate", "strcoll")
        G_reader_settings:delSetting("collate_mixed")
        G_reader_settings:delSetting("reverse_collate")
        G_reader_settings:delSetting("lock_home_folder")

        local dir = DataStorage:getDataDir() .. "/fmops"
        if mode(dir) then
            chmodTree(dir, "u+rwx")
            ffiUtil.purgeDir(dir)
        end
        util.makePath(dir .. "/sub")
        base = ffiUtil.realpath(dir)
        writeFile(base .. "/a.pdf", "aaaa")
        writeFile(base .. "/b.pdf", "bb")
        writeFile(base .. "/notes.xyz", "notes")
        writeFile(base .. "/sub/c.pdf", "c")
        G_reader_settings:saveSetting("home_dir", base)

        shown = {}
        stub(UIManager, "show", function(_, widget)
            table.insert(shown, widget)
        end)
        fm = FileManager:new{
            dimen = Screen:getSize(),
            root_path = base,
        }
    end)

    after_each(function()
        for i = #cleanups, 1, -1 do
            cleanups[i]()
        end
        cleanups = {}
        rawset(Device, "home_dir", saved_device_home)
        if FileManager.instance then
            FileManager.instance:onClose()
        end
        FileManager.instance = nil
        UIManager.show:revert()
        dropHistoryUnder(base)
        ReadHistory:_flush()
        for _, coll in pairs(ReadCollection.coll) do
            for file in pairs(coll) do
                if file:sub(1, #base) == base then
                    coll[file] = nil
                end
            end
        end
        chmodTree(base, "u+rwx")
        ffiUtil.purgeDir(base)
        -- sidecars of the scratch books in the default "dir" location
        local sidecars = DataStorage:getDocSettingsDir() .. base
        if mode(sidecars) then
            ffiUtil.purgeDir(sidecars)
        end
        for _, key in ipairs(settings_keys) do
            G_reader_settings:saveSetting(key, saved_settings[key])
        end
        for _, key in ipairs(fc_keys) do
            FileChooser[key] = saved_fc[key]
        end
        BookList.book_info_cache = {}
    end)

    describe("copy, cut and paste", function()
        it("copies a file into a folder and keeps the clipboard semantics", function()
            fm:copyFile(base .. "/a.pdf")
            assert.is_false(fm.cutfile)
            assert.are.equal(base .. "/a.pdf", fm.clipboard)
            fm:pasteFileFromClipboard(base .. "/sub")
            assert.are.equal("aaaa", readFile(base .. "/sub/a.pdf"))
            assert.are.equal("file", mode(base .. "/a.pdf"))
            assert.is_nil(fm.clipboard)
            assert.is_nil(lastShown(InfoMessage))
        end)

        it("pastes into the folder of a file used as target", function()
            fm:copyFile(base .. "/sub/c.pdf")
            fm:pasteFileFromClipboard(base .. "/a.pdf")
            assert.are.equal("c", readFile(base .. "/c.pdf"))
            assert.are.equal("file", mode(base .. "/sub/c.pdf"))
            -- refreshed listing shows the new file
            assert.is_not_nil(findItem(base .. "/c.pdf"))
        end)

        it("pastes into the current folder when no target is given", function()
            fm.file_chooser:changeToPath(base .. "/sub")
            fm:copyFile(base .. "/b.pdf")
            fm:pasteFileFromClipboard()
            assert.are.equal("bb", readFile(base .. "/sub/b.pdf"))
        end)

        it("moves a file and updates history and collections", function()
            ReadHistory:addItem(base .. "/a.pdf")
            ReadCollection:addItem(base .. "/a.pdf", ReadCollection.default_collection_name)
            fm:cutFile(base .. "/a.pdf")
            assert.is_true(fm.cutfile)
            fm:pasteFileFromClipboard(base .. "/sub")
            assert.is_nil(mode(base .. "/a.pdf"))
            assert.are.equal("aaaa", readFile(base .. "/sub/a.pdf"))
            assert.is_nil(historyIndex(base .. "/a.pdf"))
            assert.is_not_nil(historyIndex(base .. "/sub/a.pdf"))
            assert.is_true(ReadCollection:isFileInCollection(base .. "/sub/a.pdf", ReadCollection.default_collection_name))
            assert.is_nil(fm.clipboard)
        end)

        it("moves a folder and updates history entries below it", function()
            util.makePath(base .. "/dest")
            ReadHistory:addItem(base .. "/sub/c.pdf")
            fm:cutFile(base .. "/sub")
            fm:pasteFileFromClipboard(base .. "/dest")
            assert.is_nil(mode(base .. "/sub"))
            assert.are.equal("c", readFile(base .. "/dest/sub/c.pdf"))
            assert.is_nil(historyIndex(base .. "/sub/c.pdf"))
            assert.is_not_nil(historyIndex(base .. "/dest/sub/c.pdf"))
        end)

        it("copies a folder recursively", function()
            util.makePath(base .. "/dest")
            fm:copyFile(base .. "/sub")
            fm:pasteFileFromClipboard(base .. "/dest")
            assert.are.equal("c", readFile(base .. "/dest/sub/c.pdf"))
            assert.are.equal("c", readFile(base .. "/sub/c.pdf"))
        end)

        it("does nothing when pasting a file into its own folder", function()
            fm:cutFile(base .. "/a.pdf")
            fm:pasteFileFromClipboard(base .. "/b.pdf")
            assert.are.equal("aaaa", readFile(base .. "/a.pdf"))
            assert.is_nil(fm.clipboard)
            assert.are.equal(0, #shown)
        end)

        it("does nothing when pasting a folder onto itself", function()
            fm:copyFile(base .. "/sub")
            fm:pasteFileFromClipboard(base .. "/sub")
            assert.is_nil(fm.clipboard)
            assert.are.equal(0, #shown)
            assert.is_nil(mode(base .. "/sub/sub"))
        end)

        it("refuses to copy a folder into its own subfolder", function()
            util.makePath(base .. "/sub/inner")
            fm:copyFile(base .. "/sub")
            fm:pasteFileFromClipboard(base .. "/sub/inner")
            local msg = lastShown(InfoMessage)
            assert.is_not_nil(msg)
            assert.is_truthy(msg.text:find("Failed to copy:", 1, true))
            -- clipboard is kept on failure
            assert.are.equal(base .. "/sub", fm.clipboard)
            assert.are.equal("c", readFile(base .. "/sub/c.pdf")) -- source untouched
        end)

        it("refuses to move a folder into its own subfolder", function()
            util.makePath(base .. "/sub/inner")
            fm:cutFile(base .. "/sub")
            fm:pasteFileFromClipboard(base .. "/sub/inner")
            local msg = lastShown(InfoMessage)
            assert.is_truthy(msg.text:find("Failed to move:", 1, true))
            assert.are.equal("c", readFile(base .. "/sub/c.pdf"))
        end)

        it("asks before overwriting an existing file of the same name", function()
            writeFile(base .. "/sub/a.pdf", "old")
            fm:copyFile(base .. "/a.pdf")
            fm:pasteFileFromClipboard(base .. "/sub")
            local box = lastShown(ConfirmBox)
            assert.is_not_nil(box)
            assert.is_truthy(box.text:find("File already exists:", 1, true))
            assert.are.equal("Overwrite", box.ok_text)
            assert.are.equal("old", readFile(base .. "/sub/a.pdf"))
            box.ok_callback()
            assert.are.equal("aaaa", readFile(base .. "/sub/a.pdf"))
            assert.is_nil(fm.clipboard)
        end)

        it("asks before merging into an existing folder of the same name", function()
            util.makePath(base .. "/dest/sub")
            fm:copyFile(base .. "/sub")
            fm:pasteFileFromClipboard(base .. "/dest")
            local box = lastShown(ConfirmBox)
            assert.is_truthy(box.text:find("Folder already exists:", 1, true))
            box.ok_callback()
            assert.are.equal("c", readFile(base .. "/dest/sub/c.pdf"))
        end)

        it("refuses to paste a file over a folder of the same name", function()
            util.makePath(base .. "/sub/a.pdf")
            fm:copyFile(base .. "/a.pdf")
            fm:pasteFileFromClipboard(base .. "/sub")
            assert.is_nil(lastShown(ConfirmBox))
            local msg = lastShown(InfoMessage)
            assert.is_truthy(msg.text:find("Folder already exists:", 1, true))
            assert.are.equal("directory", mode(base .. "/sub/a.pdf"))
        end)

        it("refuses to paste a folder over a file of the same name", function()
            util.makePath(base .. "/dest")
            writeFile(base .. "/dest/sub", "file")
            fm:copyFile(base .. "/sub")
            fm:pasteFileFromClipboard(base .. "/dest")
            assert.is_nil(lastShown(ConfirmBox))
            local msg = lastShown(InfoMessage)
            assert.is_truthy(msg.text:find("File already exists:", 1, true))
            assert.are.equal("file", readFile(base .. "/dest/sub"))
        end)

        it("reports a failure when the destination is read-only", function()
            util.makePath(base .. "/ro")
            chmodTree(base .. "/ro", "0555")
            if not readOnlyDirIsEnforced(base .. "/ro") then
                -- running as root: permissions are not enforced, inject the failure instead
                stub(fm, "copyRecursive", function() return false end)
            end
            fm:copyFile(base .. "/a.pdf")
            fm:pasteFileFromClipboard(base .. "/ro")
            local msg = lastShown(InfoMessage)
            assert.is_truthy(msg.text:find("Failed to copy:", 1, true))
            assert.is_nil(mode(base .. "/ro/a.pdf"))
        end)

        it("exposes cp/mv shortcuts", function()
            assert.is_true(fm:copyFileFromTo(base .. "/a.pdf", base .. "/copy.pdf"))
            assert.are.equal("aaaa", readFile(base .. "/copy.pdf"))
            assert.is_false(fm:copyFileFromTo(base .. "/missing.pdf", base .. "/copy2.pdf"))
            assert.is_true(fm:moveFile(base .. "/copy.pdf", base .. "/moved.pdf"))
            assert.is_nil(mode(base .. "/copy.pdf"))
            assert.is_false(fm:moveFile(base .. "/missing.pdf", base .. "/moved2.pdf"))
            assert.is_false(fm:copyRecursive(base .. "/missing", base .. "/sub"))
        end)
    end)

    describe("delete", function()
        it("shows not found for a missing path", function()
            fm:showDeleteFileDialog(base .. "/nope.pdf")
            local msg = lastShown(InfoMessage)
            assert.are.equal("File not found:\n" .. base .. "/nope.pdf", msg.text)
        end)

        it("deletes a file after confirmation and runs the callbacks in order", function()
            ReadHistory:addItem(base .. "/a.pdf")
            local calls = {}
            fm:showDeleteFileDialog(base .. "/a.pdf",
                function() table.insert(calls, "post") end,
                function() table.insert(calls, "pre") end)
            local box = lastShown(ConfirmBox)
            assert.is_truthy(box.text:find("Delete file permanently?", 1, true))
            assert.are.equal("file", mode(base .. "/a.pdf"))
            box.ok_callback()
            assert.is_nil(mode(base .. "/a.pdf"))
            assert.are.same({ "pre", "post" }, calls)
            -- kept in history as a deleted (dimmed) entry
            assert.is_true(ReadHistory.hist[historyIndex(base .. "/a.pdf")].dim)
        end)

        it("deletes a folder recursively", function()
            util.makePath(base .. "/sub/deeper")
            writeFile(base .. "/sub/deeper/d.pdf")
            fm:showDeleteFileDialog(base .. "/sub")
            local box = lastShown(ConfirmBox)
            assert.is_truthy(box.text:find("Delete folder permanently?", 1, true))
            box.ok_callback()
            assert.is_nil(mode(base .. "/sub"))
        end)

        it("adds the metadata archive check box for opened books", function()
            local doc_settings = DocSettings:open(base .. "/a.pdf")
            doc_settings:saveSetting("doc_props", { title = "A" })
            doc_settings:saveSetting("partial_md5_checksum", "0123")
            doc_settings:flush()
            BookList.resetBookInfoCache(base .. "/a.pdf")
            spy.on(FileManager, "addMetadataArcCheckButton")
            defer(function() FileManager.addMetadataArcCheckButton:revert() end)
            fm:showDeleteFileDialog(base .. "/a.pdf")
            assert.spy(FileManager.addMetadataArcCheckButton).was.called(1)
            lastShown(ConfirmBox).ok_callback()
            assert.is_nil(mode(base .. "/a.pdf"))
            assert.is_false(DocSettings:hasSidecarFile(base .. "/a.pdf"))
        end)

        it("enables the metadata archive check box only with a valid folder", function()
            local added = {}
            local fake_box = {
                addWidget = function(_, w) table.insert(added, w) end,
                getAddedWidgetAvailableWidth = function() return Screen:getWidth() end,
            }
            G_reader_settings:delSetting("document_metadata_arc_folder")
            FileManager.addMetadataArcCheckButton(fake_box)
            assert.is_false(added[1].enabled)
            assert.is_false(added[1].checked)

            G_reader_settings:saveSetting("document_metadata_arc_folder", base .. "/sub")
            G_reader_settings:makeTrue("document_metadata_arc_on_deletion")
            FileManager.addMetadataArcCheckButton(fake_box)
            assert.is_true(added[2].enabled)
            assert.is_true(added[2].checked)
            added[2].callback()
            assert.is_false(G_reader_settings:isTrue("document_metadata_arc_on_deletion"))
        end)

        it("reports failure to delete", function()
            assert.is_nil(fm:deleteFile(base .. "/missing.pdf", true))
            local msg = lastShown(InfoMessage)
            assert.is_truthy(msg.text:find("Failed to delete:", 1, true))
            assert.is_nil(fm:deleteFile(base .. "/missing_dir", false))
            assert.are.equal(2, countShown(InfoMessage))
        end)

        it("deletes selected files and leaves select mode", function()
            fm:onToggleSelectMode()
            fm.selected_files[base .. "/a.pdf"] = true
            fm.selected_files[base .. "/b.pdf"] = true
            ReadHistory:addItem(base .. "/a.pdf")
            fm:deleteSelectedFiles()
            assert.is_nil(mode(base .. "/a.pdf"))
            assert.is_nil(mode(base .. "/b.pdf"))
            assert.is_nil(fm.selected_files)
            -- history entry is kept, dimmed as deleted
            assert.is_true(ReadHistory.hist[historyIndex(base .. "/a.pdf")].dim)
            assert.is_nil(lastShown(InfoMessage))
        end)

        it("keeps select mode and reports files that failed to delete", function()
            fm:onToggleSelectMode()
            fm.selected_files[base .. "/a.pdf"] = true
            fm.selected_files[base .. "/gone.pdf"] = true
            fm:deleteSelectedFiles()
            assert.is_nil(mode(base .. "/a.pdf"))
            assert.are.same({ [base .. "/gone.pdf"] = true }, fm.selected_files)
            assert.are.equal("Failed to delete 1 file.", lastShown(InfoMessage).text)
        end)
    end)

    describe("rename", function()
        it("renames a file and updates history and collections", function()
            ReadHistory:addItem(base .. "/a.pdf")
            ReadCollection:addItem(base .. "/a.pdf", ReadCollection.default_collection_name)
            fm:renameFile(base .. "/a.pdf", "renamed.pdf", true)
            assert.is_nil(mode(base .. "/a.pdf"))
            assert.are.equal("aaaa", readFile(base .. "/renamed.pdf"))
            assert.is_not_nil(historyIndex(base .. "/renamed.pdf"))
            assert.is_nil(historyIndex(base .. "/a.pdf"))
            assert.is_true(ReadCollection:isFileInCollection(base .. "/renamed.pdf", ReadCollection.default_collection_name))
            assert.is_not_nil(findItem(base .. "/renamed.pdf"))
        end)

        it("is a no-op when the name does not change", function()
            spy.on(fm, "moveFile")
            fm:renameFile(base .. "/a.pdf", "a.pdf", true)
            assert.spy(fm.moveFile).was_not.called()
            assert.are.equal(0, #shown)
        end)

        it("renames a folder and updates history below it", function()
            ReadHistory:addItem(base .. "/sub/c.pdf")
            fm:renameFile(base .. "/sub", "other", false)
            assert.is_nil(mode(base .. "/sub"))
            assert.are.equal("c", readFile(base .. "/other/c.pdf"))
            assert.is_not_nil(historyIndex(base .. "/other/c.pdf"))
        end)

        it("asks before overwriting an existing file", function()
            fm:renameFile(base .. "/a.pdf", "b.pdf", true)
            local box = lastShown(ConfirmBox)
            assert.is_truthy(box.text:find("File already exists:\nb.pdf\nOverwrite file?", 1, true))
            assert.are.equal("bb", readFile(base .. "/b.pdf"))
            box.ok_callback()
            assert.are.equal("aaaa", readFile(base .. "/b.pdf"))
            assert.is_nil(mode(base .. "/a.pdf"))
        end)

        it("offers to move a folder into an existing folder of the same name", function()
            util.makePath(base .. "/other")
            fm:renameFile(base .. "/sub", "other", false)
            local box = lastShown(ConfirmBox)
            assert.is_truthy(box.text:find("Move the folder inside it?", 1, true))
            assert.are.equal("Move", box.ok_text)
            box.ok_callback()
            assert.are.equal("c", readFile(base .. "/other/sub/c.pdf"))
        end)

        it("refuses to rename a file onto a folder and vice versa", function()
            fm:renameFile(base .. "/a.pdf", "sub", true)
            assert.is_truthy(lastShown(InfoMessage).text:find("File cannot be renamed.", 1, true))
            fm:renameFile(base .. "/sub", "a.pdf", false)
            assert.is_truthy(lastShown(InfoMessage).text:find("Folder cannot be renamed.", 1, true))
            assert.is_nil(lastShown(ConfirmBox))
            assert.are.equal("file", mode(base .. "/a.pdf"))
            assert.are.equal("directory", mode(base .. "/sub"))
        end)

        it("reports a failure for a nonexistent source", function()
            fm:renameFile(base .. "/ghost.pdf", "new.pdf", true)
            assert.is_truthy(lastShown(InfoMessage).text:find("Failed to rename:", 1, true))
            assert.is_nil(mode(base .. "/new.pdf"))
        end)

        it("reports a failure in a read-only folder", function()
            util.makePath(base .. "/ro")
            writeFile(base .. "/ro/f.pdf", "f")
            chmodTree(base .. "/ro", "0555")
            if not readOnlyDirIsEnforced(base .. "/ro") then
                -- running as root: permissions are not enforced, inject the failure instead
                stub(fm, "moveFile", function() return false end)
            end
            fm:renameFile(base .. "/ro/f.pdf", "g.pdf", true)
            assert.is_truthy(lastShown(InfoMessage).text:find("Failed to rename:", 1, true))
            assert.are.equal("f", readFile(base .. "/ro/f.pdf"))
            assert.is_nil(mode(base .. "/ro/g.pdf"))
        end)

        it("renames through the input dialog", function()
            fm:showRenameFileDialog(base .. "/a.pdf", true)
            local dialog = lastShown(InputDialog)
            assert.are.equal("Rename file", dialog.title)
            assert.are.equal("a.pdf", dialog:getInputText())
            -- empty input keeps the dialog
            dialog:setInputText("")
            findButton(dialog.buttons, "Rename").callback()
            assert.are.equal("file", mode(base .. "/a.pdf"))
            dialog:setInputText("z.pdf")
            findButton(dialog.buttons, "Rename").callback()
            assert.are.equal("aaaa", readFile(base .. "/z.pdf"))
            findButton(dialog.buttons, "Cancel").callback()

            fm:showRenameFileDialog(base .. "/sub", false)
            assert.are.equal("Rename folder", lastShown(InputDialog).title)
        end)
    end)

    describe("create folder", function()
        local function newFolderDialog(name)
            fm:createFolder()
            local dialog = lastShown(InputDialog)
            assert.are.equal("New folder", dialog.title)
            dialog:setInputText(name)
            return dialog
        end

        it("creates a folder and stays in the current folder", function()
            local dialog = newFolderDialog("newdir")
            findButton(dialog.buttons, "Create").callback()
            assert.are.equal("directory", mode(base .. "/newdir"))
            assert.are.equal(base, fm.file_chooser.path)
            assert.is_not_nil(findItem(base .. "/newdir"))
        end)

        it("ignores an empty name", function()
            local dialog = newFolderDialog("")
            findButton(dialog.buttons, "Create").callback()
            assert.is_nil(lastShown(InfoMessage))
            findButton(dialog.buttons, "Cancel").callback()
        end)

        it("enters the new folder when requested", function()
            local CheckButton = require("ui/widget/checkbutton")
            local check_buttons = {}
            local orig_new = CheckButton.new
            stub(CheckButton, "new", function(class, o)
                local w = orig_new(class, o)
                table.insert(check_buttons, w)
                return w
            end)
            defer(function() CheckButton.new:revert() end)
            local dialog = newFolderDialog("entered")
            assert.are.equal(1, #check_buttons)
            check_buttons[1].checked = true
            findButton(dialog.buttons, "Create").callback()
            assert.are.equal(base .. "/entered", fm.file_chooser.path)
        end)

        it("reports a failure in a read-only folder", function()
            util.makePath(base .. "/ro")
            chmodTree(base .. "/ro", "0555")
            local enforced = readOnlyDirIsEnforced(base .. "/ro")
            fm.file_chooser:changeToPath(base .. "/ro")
            local dialog = newFolderDialog("nope")
            if not enforced then
                -- running as root: permissions are not enforced, inject the failure instead
                stub(util, "makePath", function() return false end)
                defer(function() util.makePath:revert() end)
            end
            findButton(dialog.buttons, "Create").callback()
            assert.is_truthy(lastShown(InfoMessage).text:find("Failed to create folder:", 1, true))
            assert.is_nil(mode(base .. "/ro/nope"))
        end)
    end)

    describe("select mode", function()
        it("toggles select mode and the title bar icon", function()
            assert.is_nil(fm.selected_files)
            assert.are.equal("plus", fm.title_bar.right_button.icon)
            fm:onToggleSelectMode()
            assert.are.same({}, fm.selected_files)
            assert.are.equal("check", fm.title_bar.right_button.icon)
            fm:onToggleSelectMode(true)
            assert.is_nil(fm.selected_files)
            assert.are.equal("plus", fm.title_bar.right_button.icon)
        end)

        it("toggles single files on tap and selects all files in folder", function()
            fm:onToggleSelectMode()
            local item = findItem(base .. "/a.pdf")
            fm.file_chooser:onFileSelect(item)
            assert.is_true(fm.selected_files[base .. "/a.pdf"])
            assert.is_true(item.dim)
            fm.file_chooser:onFileSelect(item)
            assert.is_nil(fm.selected_files[base .. "/a.pdf"])
            assert.is_nil(item.dim)

            fm.file_chooser:selectAllFilesInFolder(true)
            -- show_unsupported is off: notes.xyz is not listed, sub/ is a folder
            assert.are.same({ [base .. "/a.pdf"] = true, [base .. "/b.pdf"] = true }, fm.selected_files)
            assert.is_true(findItem(base .. "/b.pdf").dim)
            assert.is_nil(findItem(base .. "/sub").dim)

            -- leaving select mode without refresh undims items
            fm:onToggleSelectMode()
            assert.is_nil(fm.selected_files)
            assert.is_nil(findItem(base .. "/a.pdf").dim)
        end)

        it("shows the plus menu on hold while selecting", function()
            fm:onToggleSelectMode()
            fm.file_chooser:onFileHold(findItem(base .. "/a.pdf"))
            local dialog = lastShown(ButtonDialog)
            assert.are.equal("No files selected", dialog.title)
        end)

        it("builds the selection plus menu and runs its actions", function()
            fm:onToggleSelectMode()
            local title, buttons = fm:getPlusDialogButtons()
            assert.are.equal("No files selected", title)
            assert.is_false(findButton(buttons, "Delete").enabled)
            assert.is_false(findButton(buttons, "Move here").enabled)

            findButton(buttons, "Select all files in folder").callback()
            title, buttons = fm:getPlusDialogButtons()
            assert.are.equal("2 files selected", title)
            assert.is_true(findButton(buttons, "Copy here").enabled)

            findButton(buttons, "Deselect all").callback()
            assert.are.same({}, fm.selected_files)
            assert.is_nil(findItem(base .. "/a.pdf").dim)

            findButton(buttons, "Exit select mode").callback()
            assert.is_nil(fm.selected_files)
        end)

        it("deletes selected files from the plus menu", function()
            fm:onToggleSelectMode()
            fm.selected_files[base .. "/a.pdf"] = true
            local _, buttons = fm:getPlusDialogButtons()
            findButton(buttons, "Delete").callback()
            local box = lastShown(ConfirmBox)
            assert.is_truthy(box.text:find("Delete selected files?", 1, true))
            box.ok_callback()
            assert.is_nil(mode(base .. "/a.pdf"))
            assert.is_nil(fm.selected_files)
        end)

        it("creates a folder from the selection plus menu", function()
            fm:onToggleSelectMode()
            local _, buttons = fm:getPlusDialogButtons()
            findButton(buttons, "New folder").callback()
            assert.is_not_nil(lastShown(InputDialog))
        end)

        it("lists selected files sorted by folder then name", function()
            fm:onToggleSelectMode()
            fm.selected_files[base .. "/sub/c.pdf"] = true
            fm.selected_files[base .. "/b.pdf"] = true
            fm.selected_files[base .. "/a.pdf"] = true
            local _, buttons = fm:getPlusDialogButtons()
            findButton(buttons, "Show selected files list").callback()
            local menu = lastShown(BookList)
            assert.are.equal("Selected files (3)", menu.title)
            local paths = {}
            for _, item in ipairs(menu.item_table) do
                table.insert(paths, item.filepath)
            end
            assert.are.same({ base .. "/a.pdf", base .. "/b.pdf", base .. "/sub/c.pdf" }, paths)
            menu:onMenuSelect(menu.item_table[3])
            assert.are.equal(base .. "/sub", fm.file_chooser.path)
        end)

        local function prepareCopyMove(cut)
            util.makePath(base .. "/dest")
            writeFile(base .. "/dest/b.pdf", "old")
            fm:onToggleSelectMode()
            fm.selected_files[base .. "/a.pdf"] = true
            fm.selected_files[base .. "/b.pdf"] = true
            fm.file_chooser:changeToPath(base .. "/dest")
            local _, buttons = fm:getPlusDialogButtons()
            findButton(buttons, cut and "Move here" or "Copy here").callback()
            return lastShown(ConfirmBox)
        end

        it("copies selected files here, overwriting existing ones", function()
            local box = prepareCopyMove(false)
            assert.are.equal("Copy selected files to the current folder?", box.text)
            assert.are.equal("Copy", box.ok_text)
            box.ok_callback()
            assert.are.equal("aaaa", readFile(base .. "/dest/a.pdf"))
            assert.are.equal("bb", readFile(base .. "/dest/b.pdf"))
            assert.are.equal("file", mode(base .. "/a.pdf"))
            assert.is_nil(fm.selected_files)
        end)

        it("moves selected files here and updates history", function()
            ReadHistory:addItem(base .. "/a.pdf")
            local box = prepareCopyMove(true)
            assert.are.equal("Move selected files to the current folder?", box.text)
            assert.are.equal("Move", box.ok_text)
            box.ok_callback()
            assert.is_nil(mode(base .. "/a.pdf"))
            assert.is_nil(mode(base .. "/b.pdf"))
            assert.are.equal("aaaa", readFile(base .. "/dest/a.pdf"))
            assert.is_not_nil(historyIndex(base .. "/dest/a.pdf"))
        end)

        it("skips existing files without overwrite and keeps select mode", function()
            util.makePath(base .. "/dest")
            writeFile(base .. "/dest/b.pdf", "old")
            fm:onToggleSelectMode()
            fm.selected_files[base .. "/a.pdf"] = true
            fm.selected_files[base .. "/b.pdf"] = true
            fm.cutfile = false
            fm:pasteSelectedFiles(false, base .. "/dest")
            assert.are.equal("aaaa", readFile(base .. "/dest/a.pdf"))
            assert.are.equal("old", readFile(base .. "/dest/b.pdf"))
            assert.are.same({ [base .. "/b.pdf"] = true }, fm.selected_files)
            assert.are.equal("1 file was not copied", lastShown(InfoMessage).text)

            fm.cutfile = true
            fm:pasteSelectedFiles(false, base .. "/dest")
            assert.are.equal("1 file was not moved", lastShown(InfoMessage).text)
        end)

        it("drops files already in the destination folder from the selection", function()
            fm:onToggleSelectMode()
            fm.selected_files[base .. "/a.pdf"] = true
            fm.cutfile = true
            fm:pasteSelectedFiles(true, base)
            assert.are.equal("aaaa", readFile(base .. "/a.pdf"))
            assert.is_nil(fm.selected_files)
        end)

        it("words the confirmation for an explicit target folder", function()
            fm:onToggleSelectMode()
            fm.selected_files[base .. "/a.pdf"] = true
            fm.cutfile = false
            local closed = false
            fm:showCopyMoveSelectedFilesDialog(function() closed = true end, base .. "/sub")
            local box = lastShown(ConfirmBox)
            assert.are.equal("Copy selected files?", box.text)
            box.ok_callback()
            assert.is_true(closed)
            assert.are.equal("aaaa", readFile(base .. "/sub/a.pdf"))
            fm.cutfile = true
            fm:showCopyMoveSelectedFilesDialog(function() end, base .. "/sub")
            assert.are.equal("Move selected files?", lastShown(ConfirmBox).text)
        end)
    end)

    describe("plus menu", function()
        it("offers folder actions when not selecting", function()
            local title, buttons = fm:getPlusDialogButtons()
            assert.are.equal("Home", title)
            assert.is_false(findButton(buttons, "Paste").enabled)
            fm:copyFile(base .. "/sub/c.pdf")
            title, buttons = fm:getPlusDialogButtons()
            assert.are.equal("Home", title)
            local paste = findButton(buttons, "Paste")
            assert.is_true(paste.enabled)
            paste.callback()
            assert.are.equal("c", readFile(base .. "/c.pdf"))

            findButton(buttons, "New folder").callback()
            assert.is_not_nil(lastShown(InputDialog))

            findButton(buttons, "Set as HOME folder").callback()
            assert.is_truthy(lastShown(ConfirmBox).text:find("as HOME folder?", 1, true))

            findButton(buttons, "Select files").callback()
            assert.are.same({}, fm.selected_files)
        end)

        it("goes home from the plus menu", function()
            fm.file_chooser:changeToPath(base .. "/sub")
            local _, buttons = fm:getPlusDialogButtons()
            findButton(buttons, "Go to HOME folder").callback()
            assert.are.equal(base, fm.file_chooser.path)
        end)

        it("opens a random document", function()
            local _, buttons = fm:getPlusDialogButtons()
            local random = findButton(buttons, "Open random document")
            random.callback()
            local box = lastShown(MultiConfirmBox)
            assert.is_truthy(box.text:find("Do you want to open", 1, true))
            assert.is_truthy(box.text:find("%.pdf%?$"))
            -- "Another" asks again
            box.choice2_callback()
            assert.are.equal(2, countShown(MultiConfirmBox))
            local ReaderUI = require("apps/reader/readerui")
            stub(ReaderUI, "showReader")
            defer(function() ReaderUI.showReader:revert() end)
            box.choice1_callback()
            assert.stub(ReaderUI.showReader).was.called(1)

            -- only unopened: all files opened -> nothing found
            stub(BookList, "hasBookBeenOpened", function() return true end)
            defer(function() BookList.hasBookBeenOpened:revert() end)
            random.hold_callback()
            assert.are.equal("File not found", lastShown(InfoMessage).text)
        end)

        it("adds external storage and import buttons when the device supports them", function()
            stub(Device, "hasExternalSD", function() return true, base .. "/sub" end)
            stub(Device, "canImportFiles", function() return true end)
            local valid = true
            stub(Device, "isValidPath", function() return valid end)
            stub(Device, "importFile")
            defer(function()
                Device.importFile:revert()
                Device.hasExternalSD:revert()
                Device.canImportFiles:revert()
                Device.isValidPath:revert()
            end)
            local _, buttons = fm:getPlusDialogButtons()
            local import = findButton(buttons, "Import files here")
            assert.is_true(import.enabled)
            local switch = findButton(buttons, "Switch to SDCard")
            assert.is_not_nil(switch)
            switch.callback()
            assert.are.equal(base .. "/sub", fm.file_chooser.path)
            valid = false
            Device.home_dir = base -- restored by after_each
            switch.callback()
            assert.are.equal(base, fm.file_chooser.path)
            assert.are.equal("Switch to internal storage", switch.text_func())
            import.callback()
            assert.stub(Device.importFile).was.called_with(base)
        end)

        it("integrates cover browser buttons", function()
            local refresh_args, extract_args
            fm.coverbrowser = {
                genMultipleRefreshBookInfoButton = function(_, cb, disabled)
                    refresh_args = { cb, disabled }
                    return { { text = "Refresh cached book information" } }
                end,
                genExtractBookInfoButton = function(_, cb)
                    extract_args = { cb }
                    return { { text = "Extract and cache book information" } }
                end,
            }
            local _, buttons = fm:getPlusDialogButtons()
            assert.are.equal("Extract and cache book information", buttons[#buttons][1].text)
            assert.are.same({}, buttons[#buttons - 1]) -- separator
            assert.are.equal("function", type(extract_args[1]))

            fm:onToggleSelectMode()
            _, buttons = fm:getPlusDialogButtons()
            assert.are.equal("Refresh cached book information", buttons[7][1].text)
            assert.is_true(refresh_args[2]) -- nothing selected yet: disabled
            refresh_args[1]() -- closes the dialog and leaves select mode
            assert.is_nil(fm.selected_files)
            fm.coverbrowser = nil
        end)

        it("shows the plus menu dialog", function()
            assert.is_true(fm:onShowPlusMenu())
            local dialog = lastShown(ButtonDialog)
            assert.are.equal(fm.plus_dialog, dialog)
            assert.are.equal("Home", dialog.title)
        end)
    end)

    describe("file dialog", function()
        it("shows file actions and runs them", function()
            local item = findItem(base .. "/a.pdf")
            fm.file_chooser:onFileHold(item)
            local dialog = lastShown(ButtonDialog)
            assert.are.equal("a.pdf", dialog.title)
            local buttons = dialog.buttons
            assert.is_false(findButton(buttons, "Paste").enabled)
            assert.is_true(findButton(buttons, "Rename").enabled)
            assert.is_not_nil(findButton(buttons, "Open with…"))

            findButton(buttons, "Copy").callback()
            assert.are.equal(base .. "/a.pdf", fm.clipboard)
            assert.is_false(fm.cutfile)
            findButton(buttons, "Cut").callback()
            assert.is_true(fm.cutfile)

            findButton(buttons, "Rename").callback()
            assert.are.equal("Rename file", lastShown(InputDialog).title)

            findButton(buttons, "Delete").callback()
            local box = lastShown(ConfirmBox)
            assert.is_truthy(box.text:find("Delete file permanently?", 1, true))
            box.ok_callback()
            assert.is_nil(mode(base .. "/a.pdf"))
            assert.is_nil(findItem(base .. "/a.pdf")) -- refreshed
        end)

        it("selects the held file", function()
            local item = findItem(base .. "/b.pdf")
            fm.file_chooser:showFileDialog(item)
            findButton(lastShown(ButtonDialog).buttons, "Select").callback()
            assert.are.same({ [base .. "/b.pdf"] = true }, fm.selected_files)
            assert.is_true(item.dim)
        end)

        it("pastes on a folder from its dialog", function()
            fm:copyFile(base .. "/a.pdf")
            fm.file_chooser:showFileDialog(findItem(base .. "/sub"))
            local dialog = lastShown(ButtonDialog)
            assert.are.equal("sub", dialog.title)
            local paste = findButton(dialog.buttons, "Paste")
            assert.is_true(paste.enabled)
            paste.callback()
            assert.are.equal("aaaa", readFile(base .. "/sub/a.pdf"))

            findButton(dialog.buttons, "Set as HOME folder").callback()
            local box = lastShown(ConfirmBox)
            assert.is_truthy(box.text:find(base .. "/sub", 1, true))
            box.ok_callback()
            assert.are.equal(base .. "/sub", G_reader_settings:readSetting("home_dir"))
        end)

        it("disables rename and delete on the parent folder entry", function()
            local up = fm.file_chooser.item_table[1]
            assert.is_true(up.is_go_up)
            fm.file_chooser:showFileDialog(up)
            local buttons = lastShown(ButtonDialog).buttons
            assert.is_false(findButton(buttons, "Rename").enabled)
            assert.is_false(findButton(buttons, "Delete").enabled)
            assert.is_false(findButton(buttons, "Cut").enabled)
        end)

        it("adds status rows for opened books and extra registered rows", function()
            local doc_settings = DocSettings:open(base .. "/a.pdf")
            doc_settings:saveSetting("doc_props", { title = "A" })
            doc_settings:saveSetting("annotations", { { page = 1, text = "hl" } })
            doc_settings:flush()
            BookList.resetBookInfoCache(base .. "/a.pdf")
            local row_args
            fm:addFileDialogButtons("test_row", function(file, is_file, book_props)
                row_args = { file, is_file, book_props }
                return { { text = "Extra row" } }
            end)
            fm:addFileDialogButtons("nil_row", function() return nil end)
            fm.file_chooser:showFileDialog(findItem(base .. "/a.pdf"))
            local buttons = lastShown(ButtonDialog).buttons
            assert.is_not_nil(findButton(buttons, "Extra row"))
            assert.are.equal(base .. "/a.pdf", row_args[1])
            assert.is_true(row_args[2])
            assert.are.equal("A", row_args[3].title)
            assert.is_not_nil(findButton(buttons, "Book cover"))
            DocSettings.updateLocation(base .. "/a.pdf")
        end)

        it("opens the Open with dialog", function()
            fm.file_chooser:showFileDialog(findItem(base .. "/a.pdf"))
            findButton(lastShown(ButtonDialog).buttons, "Open with…").callback()
            local OpenWithDialog = require("ui/widget/openwithdialog")
            local dialog = lastShown(OpenWithDialog)
            assert.are.equal("Open a.pdf with:", dialog.title)
            local checked
            for _, row in ipairs(dialog.radio_buttons) do
                if row[1].checked then checked = row[1].provider end
            end
            assert.are.equal(DocumentRegistry:getProvider(base .. "/a.pdf").provider, checked.provider)

            local opened = {}
            stub(FileManager, "openFile", function(_, file, provider) table.insert(opened, { file, provider }) end)
            stub(DocumentRegistry, "setProvider")
            defer(function()
                DocumentRegistry.setProvider:revert()
                FileManager.openFile:revert()
            end)
            findButton(dialog.buttons, "Open").callback()
            assert.are.same({ { base .. "/a.pdf", checked } }, opened)
            assert.stub(DocumentRegistry.setProvider).was_not.called()

            dialog._check_file_button.checked = true
            findButton(dialog.buttons, "Open").callback()
            local box = lastShown(ConfirmBox)
            assert.is_truthy(box.text:find("Always open 'a.pdf'", 1, true))
            box.ok_callback()
            assert.stub(DocumentRegistry.setProvider).was.called_with(DocumentRegistry, base .. "/a.pdf", checked, false)
            assert.are.equal(2, #opened)

            dialog._check_file_button.checked = false
            dialog._check_global_button.checked = true
            findButton(dialog.buttons, "Open").callback()
            box = lastShown(ConfirmBox)
            assert.is_truthy(box.text:find("Always open pdf files", 1, true))
            box.ok_callback()
            assert.stub(DocumentRegistry.setProvider).was.called_with(DocumentRegistry, base .. "/a.pdf", checked, true)
            assert.are.equal(3, #opened)
            findButton(dialog.buttons, "Cancel").callback()
        end)

        it("offers reset buttons when a provider is associated", function()
            local provider = DocumentRegistry:getProvider(base .. "/a.pdf")
            stub(DocumentRegistry, "getAssociatedProviderKey", function(_, file, all)
                if file == nil then return { pdf = provider.provider } end
                return provider.provider
            end)
            stub(DocumentRegistry, "setProvider")
            defer(function()
                DocumentRegistry.getAssociatedProviderKey:revert()
                DocumentRegistry.setProvider:revert()
            end)
            fm:showOpenWithDialog(base .. "/a.pdf")
            local OpenWithDialog = require("ui/widget/openwithdialog")
            local dialog = lastShown(OpenWithDialog)
            findButton(dialog.buttons, "Reset default for this file").callback()
            assert.stub(DocumentRegistry.setProvider).was.called_with(DocumentRegistry, base .. "/a.pdf", nil, false)
            findButton(dialog.buttons, "Reset default for pdf files").callback()
            assert.stub(DocumentRegistry.setProvider).was.called_with(DocumentRegistry, base .. "/a.pdf", nil, true)
            findButton(dialog.buttons, "View defaults for file types").callback()
            assert.are.equal("pdf: " .. provider.provider_name, lastShown(InfoMessage).text)
        end)

        it("lists unsupported providers for unknown files", function()
            writeFile(base .. "/x.unknownext", "?")
            fm:showOpenWithDialog(base .. "/x.unknownext")
            local OpenWithDialog = require("ui/widget/openwithdialog")
            local dialog = lastShown(OpenWithDialog)
            assert.is_truthy(dialog.radio_buttons[1][1].text:find("~Unsupported", 1, true))
        end)

        it("adds and removes extra file dialog rows", function()
            local f1, f2, f3 = function() end, function() end, function() end
            fm:addFileDialogButtons("one", f1)
            fm:addFileDialogButtons("two", f2)
            fm:addFileDialogButtons("three", f3)
            fm:addFileDialogButtons("two", f3) -- already registered: ignored
            assert.are.equal(3, #fm.file_dialog_added_buttons)
            fm:removeFileDialogButtons("two")
            assert.are.equal(2, #fm.file_dialog_added_buttons)
            assert.are.equal(f3, fm.file_dialog_added_buttons[fm.file_dialog_added_buttons.index.three])
            assert.is_nil(fm.file_dialog_added_buttons.index.two)
            fm:removeFileDialogButtons("unknown")
            fm:removeFileDialogButtons("one")
            fm:removeFileDialogButtons("three")
            assert.is_nil(fm.file_dialog_added_buttons)
        end)
    end)

    describe("home and navigation", function()
        it("goes home and refreshes when already there", function()
            fm.file_chooser:changeToPath(base .. "/sub")
            assert.is_true(fm:onHome())
            assert.are.equal(base, fm.file_chooser.path)
            writeFile(base .. "/new.pdf")
            fm:onHome()
            assert.is_not_nil(findItem(base .. "/new.pdf"))
        end)

        it("asks to set home when no home folder is available", function()
            G_reader_settings:delSetting("home_dir")
            Device.home_dir = false -- restored by after_each
            fm:onHome()
            local box = lastShown(ConfirmBox)
            assert.is_truthy(box.text:find(base, 1, true))
            box.ok_callback()
            assert.are.equal(base, G_reader_settings:readSetting("home_dir"))
        end)

        it("refreshes the listing after setting a locked home folder (shortcut markers hidden)", function()
            local shortcut_settings = fm.folder_shortcuts.settings
            local old_show_marker = shortcut_settings.show_marker
            defer(function() shortcut_settings.show_marker = old_show_marker end)
            shortcut_settings.show_marker = false -- shortcuts do not refresh the list by themselves
            G_reader_settings:makeTrue("lock_home_folder")
            fm.file_chooser:changeToPath(base .. "/sub")
            assert.is_true(fm.file_chooser.item_table[1].is_go_up)
            fm:setHome()
            lastShown(ConfirmBox).ok_callback()
            assert.are.equal(base .. "/sub", G_reader_settings:readSetting("home_dir"))
            -- the folder is now the locked home: no go-up entry anymore
            assert.is_nil(fm.file_chooser.item_table[1].is_go_up)
            assert.is_truthy(fm.title_bar.subtitle_widget.text:find("Home", 1, true))
        end)

        it("does not go above a locked home folder", function()
            G_reader_settings:makeTrue("lock_home_folder")
            fm.file_chooser:onFolderUp()
            assert.are.equal(base, fm.file_chooser.path)
            G_reader_settings:makeFalse("lock_home_folder")
            fm.file_chooser:changeToPath(base .. "/sub")
            fm.file_chooser:onFolderUp()
            assert.are.equal(base, fm.file_chooser.path)
        end)

        it("redirects FileChooser Home to the file manager instance", function()
            fm.file_chooser:changeToPath(base .. "/sub")
            assert.are.equal(fm, FileManager.instance)
            fm.file_chooser:onHome()
            assert.are.equal(base, fm.file_chooser.path)
        end)

        it("builds the folder menu from the path components", function()
            fm.file_chooser:changeToPath(base .. "/sub")
            fm:onShowFolderMenu()
            local dialog = lastShown(ButtonDialog)
            local texts = {}
            for _, row in ipairs(dialog.buttons) do
                if row[1] then table.insert(texts, row[1].text) end
            end
            assert.are.equal("/", texts[1])
            assert.is_truthy(texts[#texts - 1]:find("\u{f015}", 1, true)) -- home marker
            assert.is_truthy(texts[#texts]:find("└.*sub$"))
            dialog.buttons[1][1].callback()
            assert.are.equal("/", fm.file_chooser.path)
            assert.is_true(dialog.buttons[1][1].hold_callback())
        end)

        it("starts the folder menu at a locked home and lists subfolders in flat view", function()
            G_reader_settings:makeTrue("lock_home_folder")
            util.makePath(base .. "/sub2")
            util.makePath(base .. "/zzz.sdr")
            FileChooser.show_flat_view = true
            fm:onShowFolderMenu()
            local dialog = lastShown(ButtonDialog)
            local texts = {}
            for _, row in ipairs(dialog.buttons) do
                if row[1] then table.insert(texts, row[1].text) end
            end
            -- home first (root and parents hidden), then sorted subfolders, no .sdr
            assert.is_truthy(texts[1]:find("\u{f015}", 1, true))
            assert.is_truthy(texts[#texts - 1]:find("└.*sub$"))
            assert.is_truthy(texts[#texts]:find("└.*sub2$"))
            assert.are.equal(#texts, 3)
        end)

        it("handles back according to settings", function()
            local chooser = fm.file_chooser
            G_reader_settings:saveSetting("back_in_filemanager", "default")
            G_reader_settings:saveSetting("back_to_exit", "disable")
            assert.is_true(chooser:onBack())
            assert.are.equal(0, #shown)
            G_reader_settings:saveSetting("back_to_exit", "prompt")
            assert.is_true(chooser:onBack())
            local box = lastShown(ConfirmBox)
            assert.are.equal("Exit KOReader?", box.text)
            stub(chooser, "onClose", function() return "closed" end)
            defer(function() chooser.onClose:revert() end)
            box.ok_callback()
            assert.stub(chooser.onClose).was.called(1)
            G_reader_settings:saveSetting("back_to_exit", "always")
            assert.are.equal("closed", chooser:onBack())

            chooser:changeToPath(base .. "/sub")
            G_reader_settings:saveSetting("back_in_filemanager", "parent_folder")
            assert.is_true(chooser:onBack())
            assert.are.equal(base, chooser.path)
        end)

        it("pages on horizontal swipes", function()
            stub(fm.file_chooser, "onNextPage")
            stub(fm.file_chooser, "onPrevPage")
            assert.is_true(fm:onSwipeFM({ direction = "west" }))
            assert.stub(fm.file_chooser.onNextPage).was.called(1)
            fm:onSwipeFM({ direction = "east" })
            assert.stub(fm.file_chooser.onPrevPage).was.called(1)
            fm:onSwipeFM({ direction = "north" })
            assert.stub(fm.file_chooser.onNextPage).was.called(1)
            assert.stub(fm.file_chooser.onPrevPage).was.called(1)
        end)

        it("reinitializes at a new path keeping browsed positions", function()
            fm.file_chooser.path_items["/some/where"] = 7
            local old_chooser = fm.file_chooser
            fm:reinit(base .. "/sub", base .. "/sub/c.pdf")
            assert.are_not.equal(old_chooser, fm.file_chooser)
            assert.are.equal(base .. "/sub", fm.file_chooser.path)
            assert.are.equal(7, fm.file_chooser.path_items["/some/where"])
        end)

        it("only rotates when rotation is not locked", function()
            stub(Screen, "getRotationMode", function() return 0 end)
            stub(Screen, "setRotationMode")
            stub(fm, "rotate")
            defer(function()
                Screen.getRotationMode:revert()
                Screen.setRotationMode:revert()
                fm.rotate:revert()
            end)
            G_reader_settings:makeTrue("lock_rotation")
            fm:setRotationMode()
            assert.stub(Screen.setRotationMode).was_not.called()
            G_reader_settings:makeFalse("lock_rotation")
            G_reader_settings:saveSetting("fm_rotation_mode", 1)
            fm:setRotationMode()
            assert.stub(Screen.setRotationMode).was.called_with(Screen, 1)
            assert.stub(fm.rotate).was.called(1)
            fm:onSetRotationMode(0) -- same mode: no-op
            assert.stub(Screen.setRotationMode).was.called(1)
        end)
    end)

    describe("lifecycle and dispatcher actions", function()
        it("replaces an existing instance in showFiles and remembers the folder", function()
            local old = fm
            spy.on(old, "onClose")
            FileManager:showFiles(base .. "/sub")
            assert.spy(old.onClose).was.called(1)
            assert.are_not.equal(old, FileManager.instance)
            assert.are.equal(base .. "/sub", FileManager.instance.file_chooser.path)
            assert.are.equal(base .. "/sub", G_reader_settings:readSetting("lastdir"))
            assert.are.equal(FileManager.instance, lastShown(FileManager))
            assert.are.equal(FileManager.instance.file_chooser, FileManager.getMenuInstance())
            fm = FileManager.instance
        end)

        it("flags teardown when the reader is shown", function()
            fm:onSetupShowReader()
            assert.is_true(fm.tearing_down)
            fm.tearing_down = nil
            fm:onShowingReader()
            assert.is_true(fm.tearing_down)
            assert.is_nil(FileManager.instance)
        end)

        it("flushes settings", function()
            spy.on(G_reader_settings, "flush")
            defer(function() G_reader_settings.flush:revert() end)
            fm:onFlushSettings()
            assert.spy(G_reader_settings.flush).was.called()
        end)

        it("lists display modes and sort actions", function()
            local names, texts = FileManager.getDisplayModeActions()
            assert.are.same({ "classic" }, names)
            assert.are.equal(1, #texts)
            assert.is_true(fm:onSetDisplayMode("classic"))

            names, texts = FileManager.getSortByActions()
            assert.are.equal("strcoll", names[1])
            assert.are.equal("natural", names[2])
            assert.are.equal(#names, #texts)
            for i = 2, #names do
                assert.is_true(FileChooser.collates[names[i - 1]].menu_order < FileChooser.collates[names[i]].menu_order)
            end
        end)

        it("forwards display mode to the cover browser", function()
            fm.coverbrowser = { setDisplayMode = spy.new(function() end), modes = {
                { "Classic" }, { "Mosaic", "mosaic_image" },
            } }
            fm:onSetDisplayMode("classic")
            fm:onSetDisplayMode("mosaic_image")
            assert.spy(fm.coverbrowser.setDisplayMode).was.called_with(fm.coverbrowser, nil)
            assert.spy(fm.coverbrowser.setDisplayMode).was.called_with(fm.coverbrowser, "mosaic_image")
            local names = FileManager.getDisplayModeActions()
            assert.are.same({ "classic", "mosaic_image" }, names)
            fm.coverbrowser = nil
        end)

        it("re-sorts on sort setting changes", function()
            writeFile(base .. "/big.pdf", string.rep("x", 100))
            fm:onSetSortBy("size")
            assert.are.equal("size", G_reader_settings:readSetting("collate"))
            assert.are.same({ "sub/", "b.pdf", "a.pdf", "big.pdf" }, itemTexts(fm.file_chooser.item_table))
            fm:onSetReverseSorting(true)
            assert.is_true(G_reader_settings:isTrue("reverse_collate"))
            assert.are.same({ "sub/", "big.pdf", "a.pdf", "b.pdf" }, itemTexts(fm.file_chooser.item_table))
            fm:onSetReverseSorting(false)
            assert.is_nil(G_reader_settings:readSetting("reverse_collate"))
            fm:onSetSortBy("strcoll")
            fm:onSetMixedSorting(true)
            assert.are.same({ "a.pdf", "b.pdf", "big.pdf", "sub/" }, itemTexts(fm.file_chooser.item_table))
            fm:onSetMixedSorting(false)
            assert.are.same({ "sub/", "a.pdf", "b.pdf", "big.pdf" }, itemTexts(fm.file_chooser.item_table))
        end)

        it("shows files from subfolders in flat view", function()
            fm:onSetFlatView(true)
            assert.is_true(FileChooser.show_flat_view)
            assert.is_not_nil(findItem(base .. "/sub/c.pdf"))
            assert.is_nil(findItem(base .. "/sub"))
            fm:onSetFlatView(false)
            assert.is_nil(findItem(base .. "/sub/c.pdf"))
            assert.is_not_nil(findItem(base .. "/sub"))
        end)

        it("toggles hidden and unsupported files", function()
            writeFile(base .. "/.hidden.pdf")
            assert.is_nil(findItem(base .. "/.hidden.pdf"))
            assert.is_nil(findItem(base .. "/notes.xyz"))
            fm.file_chooser:toggleShowFilesMode("show_hidden")
            assert.is_true(G_reader_settings:isTrue("show_hidden"))
            assert.is_not_nil(findItem(base .. "/.hidden.pdf"))
            fm.file_chooser:toggleShowFilesMode("show_unsupported")
            assert.is_not_nil(findItem(base .. "/notes.xyz"))
            fm.file_chooser:toggleShowFilesMode("show_hidden")
            fm.file_chooser:toggleShowFilesMode("show_unsupported")
            assert.is_nil(findItem(base .. "/.hidden.pdf"))
            assert.is_nil(findItem(base .. "/notes.xyz"))
        end)

        it("refreshes on refresh events", function()
            writeFile(base .. "/late.pdf")
            assert.is_nil(findItem(base .. "/late.pdf"))
            assert.is_true(fm:onRefresh())
            assert.is_not_nil(findItem(base .. "/late.pdf"))
        end)

        it("opens the last document when it exists", function()
            local opened = {}
            fm.openFile = function(_, file) table.insert(opened, file) end
            G_reader_settings:delSetting("lastfile")
            assert.is_true(fm:onOpenLastDoc())
            assert.are.equal("Cannot open previous document", lastShown(InfoMessage).text)
            G_reader_settings:saveSetting("lastfile", base .. "/missing.pdf")
            fm:onOpenLastDoc()
            assert.are.equal(2, countShown(InfoMessage))
            G_reader_settings:saveSetting("lastfile", base .. "/a.pdf")
            fm:onOpenLastDoc()
            fm.openFile = nil
            assert.are.same({ base .. "/a.pdf" }, opened)
        end)

        it("opens the next or previous file in the folder", function()
            local opened = {}
            fm.openFile = function(_, file) table.insert(opened, file) end
            G_reader_settings:delSetting("lastfile")
            assert.is_true(fm:onOpenNextOrPreviousFileInFolder())
            assert.are.equal(0, #opened)
            assert.are.equal(0, #shown)
            G_reader_settings:saveSetting("lastfile", base .. "/a.pdf")
            fm:onOpenNextOrPreviousFileInFolder()
            assert.are.same({ base .. "/b.pdf" }, opened)
            fm:onOpenNextOrPreviousFileInFolder(true)
            assert.is_truthy(lastShown(InfoMessage).text:find("No previous file", 1, true))
            G_reader_settings:saveSetting("lastfile", base .. "/b.pdf")
            fm:onOpenNextOrPreviousFileInFolder(true)
            assert.are.same({ base .. "/b.pdf", base .. "/a.pdf" }, opened)
            fm:onOpenNextOrPreviousFileInFolder()
            assert.is_truthy(lastShown(InfoMessage).text:find("No next file", 1, true))
            fm.openFile = nil
        end)

        it("skips finished books when looking for the next file", function()
            local doc_settings = DocSettings:open(base .. "/b.pdf")
            doc_settings:saveSetting("summary", { status = "complete" })
            doc_settings:flush()
            BookList.resetBookInfoCache(base .. "/b.pdf")
            assert.is_nil(fm.file_chooser:getNextOrPreviousFileInFolder(base .. "/a.pdf"))
        end)

        it("opens documents and auxiliary providers", function()
            local ReaderUI = require("apps/reader/readerui")
            stub(ReaderUI, "showReader")
            defer(function() ReaderUI.showReader:revert() end)
            local doc_cb = spy.new(function() end)
            fm:openFile(base .. "/a.pdf", nil, doc_cb)
            assert.spy(doc_cb).was.called(1)
            assert.stub(ReaderUI.showReader).was.called(1)
            local forced = DocumentRegistry:getProvider(base .. "/a.pdf")
            fm:openFile(base .. "/a.pdf", forced)
            assert.stub(ReaderUI.showReader).was.called_with(ReaderUI, base .. "/a.pdf", forced, nil, true, nil)

            local aux_cb = spy.new(function() end)
            local module_cb = spy.new(function() end)
            fm:openFile(base .. "/a.pdf", { order = 1, callback = module_cb }, nil, aux_cb)
            assert.spy(aux_cb).was.called(1)
            assert.spy(module_cb).was.called_with(base .. "/a.pdf")
            fm.fakeplugin = { openFile = spy.new(function() end) }
            fm:openFile(base .. "/a.pdf", { order = 2, provider = "fakeplugin" })
            assert.spy(fm.fakeplugin.openFile).was.called_with(fm.fakeplugin, base .. "/a.pdf")
            fm.fakeplugin = nil
        end)

        it("opens a tapped file when not selecting", function()
            local filemanagerutil = require("apps/filemanager/filemanagerutil")
            local ui, opened
            stub(filemanagerutil, "openFile", function(caller, file) ui, opened = caller, file end)
            defer(function() filemanagerutil.openFile:revert() end)
            assert.is_true(fm.file_chooser:onFileSelect(findItem(base .. "/a.pdf")))
            assert.are.equal(fm, ui)
            assert.are.equal(base .. "/a.pdf", opened)
        end)
    end)
end)
