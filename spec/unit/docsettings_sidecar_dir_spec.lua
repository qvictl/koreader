describe("DocSettings.removeSidecarDir with special characters in the data dir", function()
    local DataStorage, DocSettings, lfs, util
    local orig_docsettings, data_dir

    setup(function()
        require("commonrequire")
        DataStorage = require("datastorage")
        lfs = require("libs/libkoreader-lfs")
        util = require("util")
        -- "-" and "[" are magic in Lua patterns
        data_dir = DataStorage:getDataDir() .. "/ko-data [1]"
        -- Reload docsettings so that it picks up a data dir with special characters
        orig_docsettings = package.loaded["docsettings"]
        package.loaded["docsettings"] = nil
        stub(DataStorage, "getDataDir", function() return data_dir end)
        DocSettings = require("docsettings")
        DataStorage.getDataDir:revert()
    end)

    teardown(function()
        package.loaded["docsettings"] = orig_docsettings
        require("ffi/util").purgeDir(data_dir)
    end)

    it("removes the empty parent folders in the docsettings dir", function()
        local parent = data_dir .. "/docsettings/mnt/books"
        local sdr = parent .. "/foo.sdr"
        assert.is_true(util.makePath(sdr))
        assert.has_no.errors(function() DocSettings.removeSidecarDir(sdr) end)
        assert.is_nil(lfs.attributes(sdr, "mode"))
        assert.is_nil(lfs.attributes(parent, "mode"))
        assert.is_nil(lfs.attributes(data_dir .. "/docsettings", "mode"))
    end)

    it("keeps the parent folders of a doc sidecar dir", function()
        local parent = data_dir .. "/books"
        local sdr = parent .. "/foo.sdr"
        assert.is_true(util.makePath(sdr))
        DocSettings.removeSidecarDir(sdr)
        assert.is_nil(lfs.attributes(sdr, "mode"))
        assert.are.equal("directory", lfs.attributes(parent, "mode"))
    end)
end)
