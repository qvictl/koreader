describe("Collection persistence on settings flush", function()
    local Collection, Event, ReadCollection
    local saved_write, writes

    setup(function()
        require("commonrequire")
        Collection = require("apps/filemanager/filemanagercollection")
        Event = require("ui/event")
        ReadCollection = require("readcollection")
    end)

    before_each(function()
        saved_write, writes = ReadCollection.write, {}
        ReadCollection.write = function(_, updated)
            writes[#writes + 1] = updated
        end
    end)

    after_each(function()
        ReadCollection.write = saved_write
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
end)
