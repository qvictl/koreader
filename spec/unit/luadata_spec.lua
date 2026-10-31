describe("luadata module", function()
    local DataStorage, Settings, lfs
    setup(function()
        require("commonrequire")
        DataStorage = require("datastorage")
        lfs = require("libs/libkoreader-lfs")
        Settings = require("luadata"):open(DataStorage:getDataDir() .. "/this-is-not-a-valid-file")
    end)

    it("should handle undefined keys", function()
        Settings:delSetting("abc")

        assert.True(Settings:hasNot("abc"))
        assert.True(Settings:nilOrTrue("abc"))
        assert.False(Settings:isTrue("abc"))
        Settings:saveSetting("abc", true)
        assert.True(Settings:has("abc"))
        assert.True(Settings:nilOrTrue("abc"))
        assert.True(Settings:isTrue("abc"))
    end)

    it("should flip bool values", function()
        Settings:delSetting("abc")

        assert.True(Settings:hasNot("abc"))
        Settings:flipNilOrTrue("abc")
        assert.False(Settings:nilOrTrue("abc"))
        assert.True(Settings:has("abc"))
        assert.False(Settings:isTrue("abc"))
        Settings:flipNilOrTrue("abc")
        assert.True(Settings:nilOrTrue("abc"))
        assert.True(Settings:hasNot("abc"))
        assert.False(Settings:isTrue("abc"))

        Settings:flipTrue("abc")
        assert.True(Settings:has("abc"))
        assert.True(Settings:isTrue("abc"))
        assert.True(Settings:nilOrTrue("abc"))
        Settings:flipTrue("abc")
        assert.False(Settings:has("abc"))
        assert.False(Settings:isTrue("abc"))
        assert.True(Settings:nilOrTrue("abc"))
    end)

    it("should create child settings", function()
        Settings:delSetting("key")

        Settings:saveSetting("key", {
            a = "b",
            c = "True",
            d = false,
        })

        local child = Settings:child("key")

        assert.is_not_nil(child)
        assert.True(child:has("a"))
        assert.are.equal(child:readSetting("a"), "b")
        assert.True(child:has("c"))
        assert.False(child:isTrue("c")) -- It's a string, not a bool!
        assert.True(child:has("d"))
        assert.True(child:isFalse("d"))
        assert.False(child:isTrue("e"))
        child:flipTrue("e")
        child:close()

        child = Settings:child("key")
        assert.True(child:isTrue("e"))
    end)

    describe("table wrapper", function()

        setup(function()
            Settings:delSetting("key")
        end)

        it("should add item to table", function()
            Settings:addTableItem("key", 1)
            Settings:addTableItem("key", 2)
            Settings:addTableItem("key", 3)

            assert.are.equal(1, Settings:readSetting("key")[1])
            assert.are.equal(2, Settings:readSetting("key")[2])
            assert.are.equal(3, Settings:readSetting("key")[3])
        end)

        it("should remove item from table", function()
            Settings:removeTableItem("key", 1)

            assert.are.equal(2, Settings:readSetting("key")[1])
            assert.are.equal(3, Settings:readSetting("key")[2])
        end)
    end)

    describe("backup data file", function()
        local file, d
        setup(function()
            file = DataStorage:getDataDir() .. "/dummy-test-file"
            d = Settings:open(file)
        end)
        it("should generate data file", function()
            d:saveSetting("a", "a")
            assert.Equals("file", lfs.attributes(d.file, "mode"))
        end)
        it("should generate backup data file on flush", function()
            d:flush()
            -- file and file.old.1 should be generated.
            assert.Equals("file", lfs.attributes(d.file, "mode"))
            assert.Equals("file", lfs.attributes(d.file .. ".old.1", "mode"))
            d:close()
        end)
        it("should remove garbage data file", function()
            -- write some garbage to sidecar-file.
            local f_out = io.open(d.file, "w")
            f_out:write("bla bla bla")
            f_out:close()

            d = Settings:open(file)
            -- file should be removed.
            assert.are.not_equal("file", lfs.attributes(d.file, "mode"))
            assert.Equals("file", lfs.attributes(d.file .. ".old.2", "mode"))
            assert.Equals("a", d:readSetting("a"))
            d:saveSetting("a", "b")
            d:close()
            -- backup should be generated.
            assert.Equals("file", lfs.attributes(d.file, "mode"))
            assert.Equals("file", lfs.attributes(d.file .. ".old.1", "mode"))
            -- The contents in file and file.old.1 are different.
            -- a:b v.s. a:a
        end)
        it("should open backup data file after garbage removal", function()
            d = Settings:open(file)
            -- We should get the right result.
            assert.Equals("b", d:readSetting("a"))
            -- write some garbage to file.
            local f_out = io.open(d.file, "w")
            f_out:write("bla bla bla")
            f_out:close()

            -- do not flush the result, open docsettings again.
            d = Settings:open(file)
            -- data file should be removed.
            assert.are.not_equal("file", lfs.attributes(d.file, "mode"))
            assert.Equals("file", lfs.attributes(d.file .. ".old.2", "mode"))
            -- The newest backup is file.old.1, not the original stale snapshot.
            assert.Equals("b", d:readSetting("a"))
            d:close()
            -- data file should be generated and last good backup should not change name.
            assert.Equals("file", lfs.attributes(d.file, "mode"))
            assert.Equals("file", lfs.attributes(d.file .. ".old.2", "mode"))
        end)
    end)

    describe("backup generation ordering", function()
        local file, data
        before_each(function()
            file = DataStorage:getDataDir() .. "/luadata-generation-test"
            data = Settings:open(file, "Generation")
        end)
        after_each(function()
            os.remove(file)
            for i = 1, 10 do os.remove(file .. ".old." .. i) end
        end)

        local function snapshots(count)
            for i = 1, count do data:reset{ generation = i } end
        end

        local function generation(suffix)
            return Settings:open(file .. suffix, "Generation"):readSetting("generation")
        end

        it("keeps the newest backup first and preserves every older generation", function()
            snapshots(4)
            assert.equals(4, generation(""))
            assert.equals(3, generation(".old.1"))
            assert.equals(2, generation(".old.2"))
            assert.equals(1, generation(".old.3"))
        end)

        it("recovers the newest valid snapshot after the current file is corrupted", function()
            snapshots(4)
            local f = assert(io.open(file, "w"))
            f:write("not valid Lua !!!")
            f:close()
            assert.equals(3, generation(""))
        end)

        it("falls back in recency order when the first backup is also corrupted", function()
            snapshots(4)
            for _, suffix in ipairs({ "", ".old.1" }) do
                local f = assert(io.open(file .. suffix, "w"))
                f:write("not valid Lua !!!")
                f:close()
            end
            assert.equals(2, generation(""))
            assert.equals(1, generation(".old.3"))
        end)

        it("keeps only the configured number of rotated generations", function()
            data.max_backups = 3
            snapshots(6)
            assert.equals(6, generation(""))
            assert.equals(5, generation(".old.1"))
            assert.equals(4, generation(".old.2"))
            assert.equals(3, generation(".old.3"))
            assert.is_nil(lfs.attributes(file .. ".old.4"))
        end)

        it("rotates surviving older backups even if an intermediate file is missing", function()
            snapshots(4)
            assert(os.remove(file .. ".old.2"))
            data:reset{ generation = 5 }
            assert.equals(4, generation(".old.1"))
            assert.equals(3, generation(".old.2"))
            assert.is_nil(lfs.attributes(file .. ".old.3"))
            assert.equals(1, generation(".old.4"))
        end)
    end)
end)
