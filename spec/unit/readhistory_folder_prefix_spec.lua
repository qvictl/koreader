describe("History and collections on folder rename/delete", function()
    local DocSettings, ReadCollection, ReadHistory, ffiUtil, util
    local base

    local function touch(path)
        util.makePath(ffiUtil.dirname(path))
        local f = io.open(path, "w")
        f:write("x")
        f:close()
    end

    setup(function()
        require("commonrequire")
        DocSettings = require("docsettings")
        ReadCollection = require("readcollection")
        ReadHistory = require("readhistory")
        ffiUtil = require("ffi/util")
        util = require("util")
        local data_dir = require("datastorage"):getDataDir()
        base = ffiUtil.realpath(data_dir) .. "/folder_prefix_test"
    end)

    teardown(function()
        ffiUtil.purgeDir(base)
    end)

    describe("ReadHistory", function()
        local orig_hist
        before_each(function()
            orig_hist = ReadHistory.hist
            ReadHistory.hist = {
                { file = "/x/sub/a.epub", text = "a.epub" },
                { file = "/x/sub10/b.epub", text = "b.epub" },
                { file = "/x/sub/deep/c.epub", text = "c.epub" },
            }
            stub(ReadHistory, "_flush")
            stub(ReadHistory, "fileDeleted")
            stub(ReadHistory, "ensureLastFile")
            stub(DocSettings, "updateLocation")
        end)
        after_each(function()
            ReadHistory._flush:revert()
            ReadHistory.fileDeleted:revert()
            ReadHistory.ensureLastFile:revert()
            DocSettings.updateLocation:revert()
            ReadHistory.hist = orig_hist
        end)

        it("renames only the files inside the renamed folder", function()
            ReadHistory:updateItemsByPath("/x/sub", "/x/new")
            assert.are.equal("/x/new/a.epub", ReadHistory.hist[1].file)
            assert.are.equal("/x/sub10/b.epub", ReadHistory.hist[2].file)
            assert.are.equal("/x/new/deep/c.epub", ReadHistory.hist[3].file)
        end)

        it("marks deleted only the files inside the deleted folder", function()
            ReadHistory:folderDeleted("/x/sub")
            assert.stub(ReadHistory.fileDeleted).was.called(2)
            assert.stub(ReadHistory.fileDeleted).was.called_with(ReadHistory, 1)
            assert.stub(ReadHistory.fileDeleted).was.called_with(ReadHistory, 3)
            assert.stub(DocSettings.updateLocation).was_not.called_with("/x/sub10/b.epub")
        end)
    end)

    describe("ReadCollection", function()
        local orig_coll, orig_coll_settings
        before_each(function()
            orig_coll, orig_coll_settings = ReadCollection.coll, ReadCollection.coll_settings
            ffiUtil.purgeDir(base)
            ReadCollection.coll = {
                favorites = {
                    [base .. "/sub/a.epub"] = { file = base .. "/sub/a.epub", text = "a.epub", order = 1 },
                    [base .. "/sub10/b.epub"] = { file = base .. "/sub10/b.epub", text = "b.epub", order = 2 },
                },
            }
            -- (no collection folders on this branch)
            ReadCollection.coll_settings = { favorites = {} }
            stub(ReadCollection, "write")
        end)
        after_each(function()
            ReadCollection.write:revert()
            ReadCollection.coll, ReadCollection.coll_settings = orig_coll, orig_coll_settings
        end)

        it("renames only the files inside the renamed folder", function()
            -- state after "mv sub new"
            touch(base .. "/new/a.epub")
            touch(base .. "/sub10/b.epub")
            assert.has_no.errors(function()
                ReadCollection:updateItemsByPath(base .. "/sub", base .. "/new")
            end)
            local coll = ReadCollection.coll.favorites
            assert.is_truthy(coll[base .. "/new/a.epub"])
            assert.is_truthy(coll[base .. "/sub10/b.epub"])
            assert.is_nil(coll[base .. "/sub/a.epub"])
        end)

        it("removes only the files inside the deleted folder", function()
            ReadCollection:removeItemsByPath(base .. "/sub")
            local coll = ReadCollection.coll.favorites
            assert.is_nil(coll[base .. "/sub/a.epub"])
            assert.is_truthy(coll[base .. "/sub10/b.epub"])
        end)
    end)
end)
