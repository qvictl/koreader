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
        T:run(function() UIManager:flushSettings() end)
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
    end,
}
