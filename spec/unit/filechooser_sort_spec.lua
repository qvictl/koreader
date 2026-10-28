describe("FileChooser sorting and filtering", function()
    local BookList, DataStorage, Device, DocSettings, DocumentRegistry, FileChooser, ReadCollection, UIManager
    local ffiUtil, lfs, util

    local base
    local starred_folder
    local saved_settings, saved_fc
    local settings_keys = {
        "collate", "collate_mixed", "reverse_collate", "lock_home_folder", "home_dir", "show_parent_folder",
        "show_file_in_bold", "show_hidden", "show_unsupported", "show_flat_view", "collection_show_mark",
    }
    local fc_keys = { "show_flat_view", "show_hidden", "show_unsupported", "show_filter" }

    local fake_ui = {
        folder_shortcuts = {
            hasFolderShortcut = function(_, folder) return folder == starred_folder end,
            getShortcutFullName = function() end,
        },
    }

    local function writeFile(path, size)
        local f = assert(io.open(path, "w"))
        f:write(string.rep("x", size or 1))
        f:close()
    end

    -- access, modification
    local function stampTimes()
        lfs.touch(base .. "/a0.pdf", 1000, 3000)
        lfs.touch(base .. "/a10.epub", 3000, 1000)
        lfs.touch(base .. "/a2.txt", 2000, 2000)
        lfs.touch(base .. "/adir", 500, 500)
        lfs.touch(base .. "/zdir", 4000, 4000)
    end

    local function setOpened(file, percent, status)
        local doc_settings = DocSettings:open(file)
        doc_settings:saveSetting("percent_finished", percent)
        if status then
            doc_settings:saveSetting("summary", { status = status })
        end
        doc_settings:flush()
        BookList.resetBookInfoCache(file)
    end

    local function newChooser(o)
        o = o or {}
        o.path = o.path or base
        o.ui = o.ui or fake_ui
        return FileChooser:new(o)
    end

    local function texts(item_table)
        local t = {}
        for _, item in ipairs(item_table) do
            if not item.is_go_up then
                table.insert(t, item.text)
            end
        end
        return t
    end

    local function listWith(collate, reverse, mixed, chooser)
        G_reader_settings:saveSetting("collate", collate)
        G_reader_settings:saveSetting("reverse_collate", reverse or nil)
        G_reader_settings:saveSetting("collate_mixed", mixed or nil)
        chooser = chooser or newChooser()
        chooser:clearSortingCache()
        -- listing a folder (to count its content) may update its access time (relatime)
        stampTimes()
        return texts(chooser:genItemTableFromPath(base)), chooser
    end

    local function findItem(item_table, text)
        for _, item in ipairs(item_table) do
            if item.text == text then return item end
        end
    end

    setup(function()
        require("commonrequire")
        BookList = require("ui/widget/booklist")
        DataStorage = require("datastorage")
        Device = require("device")
        DocSettings = require("docsettings")
        DocumentRegistry = require("document/documentregistry")
        FileChooser = require("ui/widget/filechooser")
        ReadCollection = require("readcollection")
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
        G_reader_settings:delSetting("lock_home_folder")
        G_reader_settings:delSetting("show_file_in_bold")

        local dir = DataStorage:getDataDir() .. "/fcsort"
        if lfs.attributes(dir, "mode") then
            os.execute(string.format("chmod -R u+rwx '%s'", dir))
            ffiUtil.purgeDir(dir)
        end
        util.makePath(dir .. "/zdir/inner")
        util.makePath(dir .. "/adir")
        base = ffiUtil.realpath(dir)
        writeFile(base .. "/zdir/one.pdf")
        writeFile(base .. "/zdir/two.pdf")
        -- name, size, modification/access time
        writeFile(base .. "/a0.pdf", 30)
        writeFile(base .. "/a10.epub", 10)
        writeFile(base .. "/a2.txt", 20)
        stampTimes()
        starred_folder = nil
        BookList.book_info_cache = {}
    end)

    after_each(function()
        for _, file in ipairs({ "a0.pdf", "a10.epub", "a2.txt" }) do
            DocSettings.updateLocation(base .. "/" .. file) -- drop sidecars
        end
        for _, coll in pairs(ReadCollection.coll) do
            for file in pairs(coll) do
                if file:sub(1, #base) == base then coll[file] = nil end
            end
        end
        os.execute(string.format("chmod -R u+rwx '%s'", base))
        ffiUtil.purgeDir(base)
        for _, key in ipairs(settings_keys) do
            G_reader_settings:saveSetting(key, saved_settings[key])
        end
        for _, key in ipairs(fc_keys) do
            FileChooser[key] = saved_fc[key]
        end
        BookList.book_info_cache = {}
    end)

    describe("collates", function()
        it("sorts by name, folders first", function()
            assert.are.same({ "adir/", "zdir/", "a0.pdf", "a10.epub", "a2.txt" }, listWith("strcoll"))
        end)

        it("sorts by natural name", function()
            assert.are.same({ "adir/", "zdir/", "a0.pdf", "a2.txt", "a10.epub" }, listWith("natural"))
        end)

        it("keeps a sort cache only for instances", function()
            local chooser = newChooser()
            local collate = FileChooser.collates.natural
            chooser:getSortingFunction(collate)
            assert.is_not_nil(chooser.sort_cache)
            chooser:clearSortingCache()
            assert.is_nil(chooser.sort_cache)
            local class_sort = FileChooser:getSortingFunction(collate)
            assert.is_true(class_sort({ text = "a2" }, { text = "a10" }))
            assert.is_nil(rawget(FileChooser, "sort_cache"))
        end)

        it("sorts by modification date, newest first, folders mixed in when asked", function()
            assert.are.same({ "zdir/", "adir/", "a0.pdf", "a2.txt", "a10.epub" }, listWith("date"))
            assert.are.same({ "zdir/", "a0.pdf", "a2.txt", "a10.epub", "adir/" }, listWith("date", false, true))
        end)

        it("sorts by last access date", function()
            assert.are.same({ "zdir/", "adir/", "a10.epub", "a2.txt", "a0.pdf" }, listWith("access"))
            assert.are.same({ "adir/", "a0.pdf", "a2.txt", "a10.epub", "zdir/" }, listWith("access", true, true))
        end)

        it("shows dates as mandatory text for date collates", function()
            G_reader_settings:saveSetting("collate", "date")
            local items = newChooser():genItemTableFromPath(base)
            local datetime = require("datetime")
            assert.are.equal(datetime.secondsToDateTime(3000, nil, true), findItem(items, "a0.pdf").mandatory)
        end)

        it("sorts by size and never mixes or reverses folders", function()
            assert.are.same({ "adir/", "zdir/", "a10.epub", "a2.txt", "a0.pdf" }, listWith("size"))
            -- size collate cannot be mixed: folders stay first, sorted by name even when reversed
            assert.are.same({ "adir/", "zdir/", "a0.pdf", "a2.txt", "a10.epub" }, listWith("size", true, true))
            local items = newChooser():genItemTableFromPath(base)
            assert.are.equal(util.getFriendlySize(30), findItem(items, "a0.pdf").mandatory)
        end)

        it("sorts by type then name", function()
            assert.are.same({ "adir/", "zdir/", "a10.epub", "a0.pdf", "a2.txt" }, listWith("type"))
            assert.are.same({ "adir/", "zdir/", "a2.txt", "a0.pdf", "a10.epub" }, listWith("type", true))
        end)

        it("reverses names and folders with a mixable collate", function()
            assert.are.same({ "zdir/", "adir/", "a2.txt", "a10.epub", "a0.pdf" }, listWith("strcoll", true))
            assert.are.same({ "zdir/", "adir/", "a2.txt", "a10.epub", "a0.pdf" }, listWith("strcoll", true, true))
            assert.are.same({ "a0.pdf", "a10.epub", "a2.txt", "adir/", "zdir/" }, listWith("strcoll", false, true))
        end)

        it("sorts by percent with unopened books first or last", function()
            setOpened(base .. "/a0.pdf", 0.8)
            setOpened(base .. "/a2.txt", 0.25)
            assert.are.same({ "adir/", "zdir/", "a10.epub", "a2.txt", "a0.pdf" }, listWith("percent_unopened_first"))
            assert.are.same({ "adir/", "zdir/", "a2.txt", "a0.pdf", "a10.epub" }, listWith("percent_unopened_last"))
            local items = newChooser():genItemTableFromPath(base)
            assert.are.equal("80\u{202F}%", findItem(items, "a0.pdf").mandatory)
            assert.are.equal("–", findItem(items, "a10.epub").mandatory)
        end)

        it("sorts by percent with finished books last and on hold below unopened", function()
            setOpened(base .. "/a0.pdf", 0.5, "complete")
            setOpened(base .. "/a2.txt", 0.3, "abandoned")
            writeFile(base .. "/b.pdf")
            setOpened(base .. "/b.pdf", 0.9, "reading")
            assert.are.same({ "adir/", "zdir/", "b.pdf", "a2.txt", "a10.epub", "a0.pdf" }, listWith("percent_natural"))
            DocSettings.updateLocation(base .. "/b.pdf")
        end)

        it("falls back to name sorting for an unknown collate", function()
            G_reader_settings:saveSetting("collate", "no_such_collate")
            local collate, collate_id = newChooser():getCollate()
            assert.are.equal("strcoll", collate_id)
            assert.are.equal(FileChooser.collates.strcoll, collate)
            assert.are.equal("strcoll", G_reader_settings:readSetting("collate"))
        end)
    end)

    describe("items", function()
        it("describes folders by their content", function()
            G_reader_settings:saveSetting("collate", "strcoll")
            local items = newChooser():genItemTableFromPath(base)
            assert.are.equal("1 \u{F114} 2 \u{F016}", findItem(items, "zdir/").mandatory)
            assert.are.equal("0 \u{F016}", findItem(items, "adir/").mandatory)
            starred_folder = base .. "/zdir"
            items = newChooser():genItemTableFromPath(base)
            assert.are.equal("☆ 1 \u{F114} 2 \u{F016}", findItem(items, "zdir/").mandatory)
        end)

        it("stars files in collections", function()
            ReadCollection:addItem(base .. "/a0.pdf", ReadCollection.default_collection_name)
            G_reader_settings:saveSetting("collate", "size")
            local items = newChooser():genItemTableFromPath(base)
            assert.are.equal("☆ " .. util.getFriendlySize(30), findItem(items, "a0.pdf").mandatory)
            assert.are.equal(util.getFriendlySize(10), findItem(items, "a10.epub").mandatory)
        end)

        it("shows new or opened files in bold depending on settings", function()
            setOpened(base .. "/a0.pdf", 0.5)
            G_reader_settings:saveSetting("collate", "strcoll")
            local items = newChooser():genItemTableFromPath(base)
            assert.is_false(findItem(items, "a0.pdf").bold)
            assert.is_true(findItem(items, "a2.txt").bold)
            G_reader_settings:saveSetting("show_file_in_bold", "opened")
            items = newChooser():genItemTableFromPath(base)
            assert.is_true(findItem(items, "a0.pdf").bold)
            assert.is_false(findItem(items, "a2.txt").bold)
            G_reader_settings:saveSetting("show_file_in_bold", false)
            items = newChooser():genItemTableFromPath(base)
            assert.is_nil(findItem(items, "a0.pdf").bold)
            assert.is_nil(findItem(items, "a2.txt").bold)
        end)

        it("calls item_func for folders only with mixable collates", function()
            local seen = {}
            local orig = FileChooser.collates.strcoll.item_func
            FileChooser.collates.strcoll.item_func = function(item, ui)
                seen[item.text] = ui
                return orig(item)
            end
            G_reader_settings:saveSetting("collate", "strcoll")
            local chooser = newChooser()
            chooser:genItemTableFromPath(base)
            FileChooser.collates.strcoll.item_func = orig
            assert.are.equal(fake_ui, seen["adir/"])
            assert.are.equal(fake_ui, seen["a0.pdf"])
        end)

        it("adds the go-up and current folder entries", function()
            G_reader_settings:saveSetting("collate", "strcoll")
            local chooser = newChooser{ show_current_dir_for_hold = true }
            local items = chooser:genItemTableFromPath(base)
            assert.are.equal("Long-press here to choose current folder", items[1].text)
            assert.are.equal(base .. "/.", items[1].path)
            assert.is_true(items[2].is_go_up)
            assert.are.equal(base .. "/..", items[2].path)
            -- no go-up entry at root
            local root_items = chooser:genItemTable({}, {}, "/")
            assert.is_nil(root_items[2])
            -- nor at a locked home
            G_reader_settings:makeTrue("lock_home_folder")
            G_reader_settings:saveSetting("home_dir", base)
            items = newChooser():genItemTableFromPath(base)
            assert.is_nil(items[1].is_go_up)
            -- nor in the file manager when disabled
            G_reader_settings:delSetting("lock_home_folder")
            G_reader_settings:makeFalse("show_parent_folder")
            local fm_chooser = newChooser()
            fm_chooser.is_fm = true
            items = fm_chooser:genItemTableFromPath(base)
            assert.is_nil(items[1].is_go_up)
            G_reader_settings:delSetting("show_parent_folder")
        end)
    end)

    describe("filters", function()
        before_each(function()
            G_reader_settings:saveSetting("collate", "strcoll")
            util.makePath(base .. "/book.sdr")
            util.makePath(base .. "/kepub")
            util.makePath(base .. "/.hiddendir")
            writeFile(base .. "/.hidden.pdf")
            writeFile(base .. "/._fork.pdf")
            writeFile(base .. "/Thumbs.db")
            writeFile(base .. "/data.xyz")
        end)

        it("hides system folders and files", function()
            local chooser = newChooser{ file_filter = function(f) return DocumentRegistry:hasProvider(f) end }
            assert.are.same({ "adir/", "zdir/", "a0.pdf", "a10.epub", "a2.txt" },
                texts(chooser:genItemTableFromPath(base)))
            assert.is_false(chooser:show_dir("book.sdr"))
            assert.is_false(chooser:show_dir(".Trash-1000"))
            assert.is_true(chooser:show_dir("books"))
            assert.is_false(chooser:show_file("KoboReader.sqlite"))
            assert.is_false(chooser:show_file(".DS_Store"))
            assert.is_false(chooser:show_file("data.xyz"))
        end)

        it("shows hidden entries and unsupported files when asked", function()
            local chooser = newChooser{ file_filter = function(f) return DocumentRegistry:hasProvider(f) end }
            FileChooser.show_hidden = true
            FileChooser.show_unsupported = true
            local t = texts(chooser:genItemTableFromPath(base))
            table.sort(t)
            assert.are.same({ ".hidden.pdf", ".hiddendir/", "a0.pdf", "a10.epub", "a2.txt", "adir/", "data.xyz", "zdir/" }, t)
            -- excluded system entries and resource forks stay hidden
            for _, text in ipairs(t) do
                assert.is_nil(text:find("sdr", 1, true))
                assert.are_not.equal("Thumbs.db", text)
                assert.are_not.equal("._fork.pdf", text)
            end
        end)

        it("toggles show modes and persists them", function()
            local chooser = newChooser{ file_filter = function(f) return DocumentRegistry:hasProvider(f) end }
            assert.is_nil(findItem(chooser.item_table, "data.xyz"))
            chooser:toggleShowFilesMode("show_unsupported")
            assert.is_true(G_reader_settings:isTrue("show_unsupported"))
            assert.is_not_nil(findItem(chooser.item_table, "data.xyz"))
            chooser:toggleShowFilesMode("show_unsupported")
            assert.is_nil(findItem(chooser.item_table, "data.xyz"))
        end)

        it("filters files by reading status", function()
            setOpened(base .. "/a0.pdf", 0.5, "reading")
            setOpened(base .. "/a2.txt", 1, "complete")
            local chooser = newChooser{ file_filter = function(f) return DocumentRegistry:hasProvider(f) end }
            FileChooser.show_filter = { status = { reading = true, complete = true } }
            assert.are.same({ "adir/", "zdir/", "a0.pdf", "a2.txt" }, texts(chooser:genItemTableFromPath(base)))
            FileChooser.show_filter = { status = { new = true } }
            assert.are.same({ "adir/", "zdir/", "a10.epub" }, texts(chooser:genItemTableFromPath(base)))
            -- next/previous file ignores the status filter
            assert.are.equal(base .. "/a10.epub", chooser:getNextOrPreviousFileInFolder(base .. "/a0.pdf"))
            assert.are.same({ status = { new = true } }, FileChooser.show_filter)
        end)

        it("lists files of subfolders in flat view in the file manager only", function()
            FileChooser.show_flat_view = true
            local chooser = newChooser{ file_filter = function(f) return DocumentRegistry:hasProvider(f) end }
            local t = texts(chooser:genItemTableFromPath(base))
            assert.are.same({ "adir/", "zdir/" }, { t[1], t[2] })
            chooser.is_fm = true
            t = texts(chooser:genItemTableFromPath(base))
            assert.are.same({ "a0.pdf", "a10.epub", "a2.txt", "one.pdf", "two.pdf" }, t)
        end)
    end)

    describe("navigation", function()
        before_each(function()
            G_reader_settings:saveSetting("collate", "strcoll")
        end)

        it("falls back to the home folder for an invalid initial path", function()
            G_reader_settings:saveSetting("home_dir", base .. "/zdir")
            local chooser = newChooser{ path = base .. "/does/not/exist" }
            assert.are.equal(base .. "/zdir", chooser.path)
        end)

        it("goes up to the nearest existing folder and focuses an item", function()
            local chooser = newChooser()
            chooser:changeToPath(base .. "/zdir/missing/deeper")
            assert.are.equal(base .. "/zdir", chooser.path)
            chooser:changeToPath(base, base .. "/zdir")
            assert.are.equal(base, chooser.path)
            assert.is_nil(chooser.focused_path)
            assert.are.equal(base .. "/zdir", chooser.item_table[chooser.prev_itemnumber].path)
        end)

        it("shows the known child of an unreadable folder", function()
            util.makePath(base .. "/locked")
            writeFile(base .. "/locked/known.pdf")
            os.execute(string.format("chmod 0 '%s'", base .. "/locked"))
            if pcall(lfs.dir, base .. "/locked") then return end -- running as root
            local messages = {}
            stub(UIManager, "show", function(_, w) table.insert(messages, w) end)
            local chooser = newChooser()
            chooser:changeToPath(base .. "/locked", base .. "/locked/known.pdf")
            UIManager.show:revert()
            local items = chooser.item_table
            assert.are.equal(2, #items)
            assert.is_true(items[1].is_go_up)
            assert.are.equal(base .. "/locked/known.pdf", items[2].path)
            assert.are.equal(1, #messages)
            assert.are.equal("Current folder not readable. Some content may not be shown.", messages[1].text)
        end)

        it("returns no list for an unreadable folder in flat view", function()
            util.makePath(base .. "/locked")
            os.execute(string.format("chmod 0 '%s'", base .. "/locked"))
            if pcall(lfs.dir, base .. "/locked") then return end -- running as root
            FileChooser.show_flat_view = true
            local chooser = newChooser()
            chooser.is_fm = true
            local dirs, files, readable = chooser:getList(base .. "/locked", chooser:getCollate())
            assert.is_false(readable)
            assert.are.same({}, dirs)
            assert.are.same({}, files)
        end)

        it("selects folders and files", function()
            local chooser = newChooser()
            local zdir = findItem(chooser.item_table, "zdir/")
            assert.is_true(chooser:onMenuSelect(zdir))
            assert.are.equal(base .. "/zdir", chooser.path)
            -- going up focuses the folder we came from
            assert.is_true(chooser:onMenuSelect(chooser.item_table[1]))
            assert.are.equal(base, chooser.path)
            assert.are.equal(base .. "/zdir", chooser.item_table[chooser.prev_itemnumber].path)

            stub(UIManager, "close")
            assert.is_true(chooser:onMenuSelect(findItem(chooser.item_table, "a0.pdf")))
            assert.stub(UIManager.close).was.called(1)
            UIManager.close:revert()
            assert.is_true(chooser:onMenuHold(findItem(chooser.item_table, "a0.pdf")))
        end)

        it("goes home, or refreshes when already there", function()
            G_reader_settings:saveSetting("home_dir", base)
            local chooser = newChooser{ path = base .. "/zdir" }
            assert.is_true(chooser:goHome())
            assert.are.equal(base, chooser.path)
            writeFile(base .. "/late.pdf")
            assert.is_true(chooser:goHome())
            assert.is_not_nil(findItem(chooser.item_table, "late.pdf"))
            -- invalid home: device default, or nothing
            G_reader_settings:saveSetting("home_dir", base .. "/gone")
            local old_home = rawget(Device, "home_dir")
            Device.home_dir = base .. "/adir"
            assert.is_true(chooser:goHome())
            assert.are.equal(base .. "/adir", chooser.path)
            Device.home_dir = false
            assert.is_nil(chooser:goHome())
            Device.home_dir = old_home
        end)

        it("closes itself and sends Home when there is no file manager", function()
            local FileManager = require("apps/filemanager/filemanager")
            assert.is_nil(FileManager.instance)
            local chooser = newChooser()
            local closed = false
            chooser.onClose = function() closed = true end
            local tasks = {}
            stub(UIManager, "setSuspendRepaints")
            stub(UIManager, "nextTick", function(_, task) table.insert(tasks, task) end)
            local sent
            stub(UIManager, "sendEvent", function(_, event) sent = event end)
            assert.is_true(chooser:onHome())
            assert.is_true(closed)
            assert.are.equal(1, #tasks)
            assert.is_nil(sent)
            tasks[1]()
            assert.are.equal("onHome", sent.handler)
            UIManager.setSuspendRepaints:revert()
            UIManager.nextTick:revert()
            UIManager.sendEvent:revert()
        end)

        it("finds next and previous readable files, skipping finished and unsupported ones", function()
            writeFile(base .. "/a3.xyz")
            writeFile(base .. "/a4.pdf")
            setOpened(base .. "/a2.txt", 1, "complete")
            G_reader_settings:saveSetting("collate", "natural")
            local chooser = newChooser{ show_unsupported = true }
            -- natural order: a0, a2 (finished), a3.xyz (no provider), a4, a10
            assert.are.equal(base .. "/a4.pdf", chooser:getNextOrPreviousFileInFolder(base .. "/a0.pdf"))
            assert.are.equal(base .. "/a10.epub", chooser:getNextOrPreviousFileInFolder(base .. "/a4.pdf"))
            assert.is_nil(chooser:getNextOrPreviousFileInFolder(base .. "/a10.epub"))
            assert.are.equal(base .. "/a0.pdf", chooser:getNextOrPreviousFileInFolder(base .. "/a2.txt", true))
            assert.are.equal(base .. "/a4.pdf", chooser:getNextOrPreviousFileInFolder(base .. "/a3.xyz"))
            assert.is_nil(chooser:getNextOrPreviousFileInFolder(base .. "/a0.pdf", true))
        end)
    end)
end)
