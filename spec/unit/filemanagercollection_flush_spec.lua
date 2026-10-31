describe("Collection persistence on settings flush", function()
    local Collection, Event, Menu, ReadCollection, UIManager
    local saved_write, saved_new, saved_show, saved_close, writes

    setup(function()
        require("commonrequire")
        Collection = require("apps/filemanager/filemanagercollection")
        Event = require("ui/event")
        ReadCollection = require("readcollection")
        Menu = require("ui/widget/menu")
        UIManager = require("ui/uimanager")
    end)

    before_each(function()
        saved_write, writes = ReadCollection.write, {}
        saved_new, saved_show, saved_close = Menu.new, UIManager.show, UIManager.close
        ReadCollection.write = function(_, updated)
            writes[#writes + 1] = updated
            return true
        end
    end)

    after_each(function()
        ReadCollection.write = saved_write
        Menu.new, UIManager.show, UIManager.close = saved_new, saved_show, saved_close
    end)

    it("flushes changed collections through the normal event path", function()
        local changed = { favorites = true }
        local manager = Collection:extend{ updated_collections = changed }
        manager:handleEvent(Event:new("FlushSettings"))
        assert.are.equal(1, #writes)
        assert.are.equal(changed, writes[1])
    end)

    it("preserves the all-collections marker for deferred removals", function()
        local changed = { [1] = true }
        Collection:extend{ updated_collections = changed }:handleEvent(Event:new("FlushSettings"))
        assert.are.equal(changed, writes[1])
    end)

    it("does not write unchanged collections during a flush", function()
        Collection:extend{ updated_collections = {} }:handleEvent(Event:new("FlushSettings"))
        assert.are.equal(0, #writes)
    end)

    it("still persists subsequent changes after an earlier flush", function()
        local manager = Collection:extend{ updated_collections = { favorites = true } }
        manager:handleEvent(Event:new("FlushSettings"))
        manager.updated_collections.work = true
        manager:handleEvent(Event:new("FlushSettings"))
        assert.are.equal(2, #writes)
        assert.is_true(writes[2].work)
    end)

    it("preserves persistence when the owner widget closes", function()
        local changed = { favorites = true }
        Collection:extend{ updated_collections = changed }:handleEvent(Event:new("CloseWidget"))
        assert.are.equal(changed, writes[1])
    end)

    it("does not repeat a successful write when flushing or closing without new edits", function()
        local manager = Collection:extend{ updated_collections = { favorites = true } }
        manager:handleEvent(Event:new("FlushSettings"))
        manager:handleEvent(Event:new("FlushSettings"))
        manager:handleEvent(Event:new("CloseWidget"))
        assert.are.equal(1, #writes)
        assert.is_nil(next(manager.updated_collections))
    end)

    it("retains dirty collections after a failed write and retries on the next flush", function()
        local manager = Collection:extend{ updated_collections = { favorites = true } }
        ReadCollection.write = function(_, updated)
            writes[#writes + 1] = updated
            return #writes > 1
        end
        manager:handleEvent(Event:new("FlushSettings"))
        assert.is_true(manager.updated_collections.favorites)
        assert.is_true(manager.updated_collections[1])
        manager:handleEvent(Event:new("FlushSettings"))
        assert.are.equal(2, #writes)
        assert.is_nil(next(manager.updated_collections))
    end)

    for _, count in ipairs({ 2, 3 }) do
        it("refreshes connected-folder metadata only when its displayed count changes to " .. count, function()
            Menu.new = function(_, options) return options end
            UIManager.show, UIManager.close = function() end, function() end
            local refreshed = 0
            local manager = Collection:extend{
                updated_collections = {}, -- a successful flush already cleared this
                coll_list = { item_table = {{ mandatory = 2 }} },
                getCollListItemMandatory = function() return count end,
                updateCollListItemTable = function() refreshed = refreshed + 1 end,
                updateCollFolderListItemTable = function() end,
            }
            manager:showCollFolderList{ name = "favorites", text = "Favorites", idx = 1 }
            manager.coll_folder_list.close_callback()
            assert.equals(count, manager.coll_list.item_table[1].mandatory)
            assert.equals(count == 3 and 1 or 0, refreshed)
        end)
    end
end)
