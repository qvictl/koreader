describe("MemoryTuning", function()
    local MemoryTuning

    setup(function()
        require("commonrequire")
        MemoryTuning = require("memorytuning")
    end)

    before_each(function()
        MemoryTuning._is_low_memory = nil
        G_reader_settings:delSetting("low_memory_profile")
        G_reader_settings:delSetting("release_memory_on_close")
    end)

    after_each(function()
        MemoryTuning._is_low_memory = nil
        G_reader_settings:delSetting("low_memory_profile")
        G_reader_settings:delSetting("release_memory_on_close")
    end)

    it("should read MemTotal on Linux", function()
        local total = MemoryTuning:getMemTotal()
        if jit.os == "Linux" then
            assert.is.number(total)
            assert.is_true(total > 0)
        end
    end)

    it("should honor the low_memory_profile setting", function()
        G_reader_settings:saveSetting("low_memory_profile", true)
        assert.is_true(MemoryTuning:isLowMemory())
        assert.are.equal(4, MemoryTuning:pick(40, 4))
        MemoryTuning._is_low_memory = nil
        G_reader_settings:saveSetting("low_memory_profile", false)
        assert.is_false(MemoryTuning:isLowMemory())
        assert.are.equal(40, MemoryTuning:pick(40, 4))
    end)

    it("should enable the profile at or below the RAM threshold", function()
        local orig = MemoryTuning.getMemTotal
        MemoryTuning.getMemTotal = function() return 512 * 1024 end
        assert.is_true(MemoryTuning:isLowMemory())
        MemoryTuning._is_low_memory = nil
        MemoryTuning.getMemTotal = function() return 2 * 1024 * 1024 end
        assert.is_false(MemoryTuning:isLowMemory())
        MemoryTuning._is_low_memory = nil
        MemoryTuning.getMemTotal = function() return nil end
        assert.is_false(MemoryTuning:isLowMemory())
        MemoryTuning.getMemTotal = orig
    end)

    it("should cache its decision", function()
        G_reader_settings:saveSetting("low_memory_profile", true)
        assert.is_true(MemoryTuning:isLowMemory())
        G_reader_settings:saveSetting("low_memory_profile", false)
        assert.is_true(MemoryTuning:isLowMemory())
    end)

    it("should release memory, unless disabled", function()
        local function makeGarbage()
            local t = {}
            for i = 1, 10000 do t[i] = { i } end
            return #t
        end
        assert.are.equal(10000, makeGarbage())
        local before = collectgarbage("count")
        MemoryTuning:releaseMemory("unit test")
        assert.is_true(collectgarbage("count") < before)
        G_reader_settings:saveSetting("release_memory_on_close", false)
        local spy_gc = spy.on(_G, "collectgarbage")
        MemoryTuning:releaseMemory("unit test (disabled)")
        assert.spy(spy_gc).was_not_called()
        spy_gc:revert()
    end)
end)
