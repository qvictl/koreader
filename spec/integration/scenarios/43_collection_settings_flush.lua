-- Exercise the same FlushSettings broadcast used before PocketBook backgrounding.
return {
    name = "Manual collection order survives settings flush without closing the file manager",
    timeout = 60,
    run = function(T)
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        local ReadCollection = require("readcollection")
        local UIManager = require("ui/uimanager")
        local ffiUtil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local util = require("util")
        local fm = T:fileManager()
        local manager = fm.collections
        local base = os.getenv("KO_HOME") .. "/collection-books"
        local first, second = base .. "/first.epub", base .. "/second.epub"
        local settings_path = DataStorage:getSettingsDir() .. "/collection.lua"
        local function diskOrder(path)
            for _, item in ipairs(LuaSettings:open(settings_path):readSetting("favorites")) do
                if item.file == path then return item.order end
            end
        end
        local function readFile(path)
            local file = io.open(path, "rb")
            if not file then return nil end
            local bytes = file:read("*a")
            file:close()
            return bytes
        end
        local saved = {
            coll = util.tableDeepCopy(ReadCollection.coll),
            coll_settings = util.tableDeepCopy(ReadCollection.coll_settings),
            last_read_time = ReadCollection.last_read_time,
            coll_default = ReadCollection.coll_default,
            updated = util.tableDeepCopy(manager.updated_collections),
            current = readFile(settings_path),
            backup = readFile(settings_path .. ".old"),
        }
        local writes
        assert(not lfs.attributes(base), "scenario fixture path must be new")
        local ok, err = pcall(function()
            T:run(function()
                util.makePath(base)
                assert(not ffiUtil.copyFile(T:fixture("books/en.epub"), first))
                assert(not ffiUtil.copyFile(T:fixture("books/en.epub"), second))
                ReadCollection:addItem(first, "favorites")
                ReadCollection:addItem(second, "favorites")
                ReadCollection:write()
                manager:onShowColl("favorites")
                manager:showArrangeBooksDialog()
            end)
            local arrange = T:topWidget()
            T:run(function() arrange.buttons[#arrange.buttons][1].callback() end)
            T:repaint()
            local sorter = T:topWidget()
            T:check(sorter.item_table and #sorter.item_table == 2, "real manual collection sorter opens")
            T:run(function()
                sorter.marked = 2
                sorter:moveItem(-1)
                sorter:onReturn()
                manager.booklist_menu.close_callback()
            end)
            T:eq(ReadCollection.coll.favorites[second].order, 1, "manual sorting updates the in-memory order")
            T:eq(diskOrder(second), 2, "sorting is pending until settings are flushed")
            T:check(T:fileManager() == fm, "closing favorites does not close the file manager")
            writes = T:spy(ReadCollection, "write")
            T:run(function()
                UIManager:flushSettings()
                UIManager:flushSettings() -- no new edits between these events
            end)
            writes.restore()
            T:eq(writes.calls, 1, "a second flush without edits does not write collections again")
            T:eq(next(manager.updated_collections), nil, "successful persistence clears pending collection edits")
            T:eq(diskOrder(second), 1, "settings flush persists the reordered favorite")
            T:eq(diskOrder(first), 2, "settings flush persists the other favorite's new order")
            T:check(T:fileManager() == fm, "file manager remains open after persistence")
            T:run(function()
                ReadCollection.last_read_time = 0
                ReadCollection:_read()
                manager:onShowColl("favorites")
            end)
            T:repaint()
            T:eq(manager.booklist_menu.item_table[1].file, second, "reopened collection displays the persisted order")
            T:check(manager.booklist_menu.dimen ~= nil, "reopened collection is painted")
            T:run(function() manager.booklist_menu.close_callback() end)

            -- A flush can occur while the connected-folder menu is still open.
            -- Its parent list must refresh even after persistence clears dirty flags.
            local connected = base .. "/connected"
            T:run(function()
                util.makePath(connected)
                assert(not ffiUtil.copyFile(T:fixture("books/en.epub"), connected .. "/third.epub"))
                manager:onShowCollList()
                manager:showCollFolderList{ name = "favorites", text = "Favorites", idx = 1 }
                manager:showAddCollFolderDialog()
            end)
            local chooser = T:topWidget()
            T:run(function()
                chooser.onConfirm(connected)
                UIManager:close(chooser)
            end)
            T:eq(util.tableSize(ReadCollection.coll.favorites), 3, "connected folder adds a third book")
            T:eq(manager.coll_list.item_table[1].mandatory, 2, "parent collection count awaits folder-menu close")
            T:run(function() UIManager:flushSettings() end)
            T:eq(next(manager.updated_collections), nil, "mid-menu flush commits folder edits")
            T:run(function() manager.coll_folder_list.close_callback() end)
            T:repaint()
            T:eq(manager.coll_list.item_table[1].mandatory,
                manager.getCollListItemMandatory("favorites"), "parent count and folder marker refresh after flush")
            T:check(manager.coll_list.dimen ~= nil, "refreshed parent collection list is painted")
            T:run(function() manager.coll_list.close_callback() end)
        end)
        local cleanup_ok, cleanup_err = pcall(function()
            if writes then writes.restore() end
            T:run(function()
                -- Close any scenario widget left behind by a failed assertion.
                while T:topWidget() and T:topWidget() ~= fm do
                    UIManager:close(T:topWidget())
                end
            end)
            -- A cover-browser launch may already be queued for the next tick.
            -- Drain it while fixtures exist, then let its normal reaper finish.
            T:wait(0.05)
            local bookinfo = package.loaded.bookinfomanager
            if bookinfo then
                T:run(function() bookinfo:terminateBackgroundJobs() end)
                T:waitUntil(function() return not bookinfo:isExtractingInBackground() end,
                    15, "cover metadata workers to finish before removing fixtures")
            end
            T:run(function()
                ReadCollection.coll = saved.coll
                ReadCollection.coll_settings = saved.coll_settings
                ReadCollection.last_read_time = saved.last_read_time
                ReadCollection.coll_default = saved.coll_default
                manager.booklist_menu, manager.coll_list, manager.coll_folder_list = nil, nil, nil
                manager.updated_collections = saved.updated
                for _, entry in ipairs({ { settings_path, saved.current }, { settings_path .. ".old", saved.backup } }) do
                    if entry[2] then
                        assert(util.writeToFile(entry[2], entry[1]))
                    else
                        os.remove(entry[1])
                    end
                end
                ffiUtil.purgeDir(base)
            end)
        end)
        if not ok then error(err, 0) end
        if not cleanup_ok then error(cleanup_err, 0) end
        T:eq(ReadCollection.last_read_time, saved.last_read_time, "collection read timestamp is restored")
        T:eq(readFile(settings_path), saved.current, "original collection settings bytes are restored")
        T:eq(lfs.attributes(base), nil, "private collection book fixtures are removed")
    end,
}
