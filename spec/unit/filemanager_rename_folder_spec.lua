describe("FileManager renaming a folder", function()
    local FileManager, ReadHistory, ReadCollection, UIManager, ffiUtil, lfs, util
    local base, calls

    local function record(name)
        return function(_, from, to) table.insert(calls, { name, from, to }) end
    end

    local function newFM()
        return setmetatable({
            folder_shortcuts = { updateItemsByPath = record("shortcuts") },
            onRefresh = function() end,
        }, { __index = FileManager })
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        FileManager = require("apps/filemanager/filemanager")
        ReadHistory = require("readhistory")
        ReadCollection = require("readcollection")
        UIManager = require("ui/uimanager")
        ffiUtil = require("ffi/util")
        lfs = require("libs/libkoreader-lfs")
        util = require("util")
        base = require("datastorage"):getDataDir() .. "/rename_folder_test"
    end)

    before_each(function()
        ffiUtil.purgeDir(base)
        util.makePath(base .. "/a")
        util.makePath(base .. "/b")
        calls = {}
        stub(ReadHistory, "updateItemsByPath", record("history"))
        stub(ReadCollection, "updateItemsByPath", record("collection"))
    end)

    after_each(function()
        ReadHistory.updateItemsByPath:revert()
        ReadCollection.updateItemsByPath:revert()
        ffiUtil.purgeDir(base)
    end)

    it("updates history/collections/shortcuts with the plain new path", function()
        local fm = newFM()
        fm:renameFile(base .. "/a", "c", false)
        assert.are.equal("directory", lfs.attributes(base .. "/c", "mode"))
        assert.are.same({
            { "history", base .. "/a", base .. "/c" },
            { "collection", base .. "/a", base .. "/c" },
            { "shortcuts", base .. "/a", base .. "/c" },
        }, calls)
    end)

    it("uses the real location when moved inside an existing folder", function()
        local fm = newFM()
        local shown = {}
        stub(UIManager, "show", function(_, w) table.insert(shown, w) end)
        fm:renameFile(base .. "/a", "b", false)
        UIManager.show:revert()
        assert.are.equal(1, #shown)
        shown[1].ok_callback() -- "Move the folder inside it?"

        assert.are.equal("directory", lfs.attributes(base .. "/b/a", "mode"))
        assert.are.same({
            { "history", base .. "/a", base .. "/b/a" },
            { "collection", base .. "/a", base .. "/b/a" },
            { "shortcuts", base .. "/a", base .. "/b/a" },
        }, calls)
    end)
end)
