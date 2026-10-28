-- With a document cache budget under 8 MiB (e.g. DGLOBAL_CACHE_SIZE_MAXIMUM lowered to save
-- RAM), DocCache degrades to a single-slot cache without a size. DocCache:serialize(), which
-- ReaderUI runs on every book close, compared the disk cache size with that nil size:
-- "attempt to compare nil with number", i.e. an error on every close.
describe("DocCache with a small budget", function()
    local DocCache, lfs, util
    local orig_calcFreeMem
    local MiB = 1024 * 1024

    setup(function()
        require("commonrequire")
        lfs = require("libs/libkoreader-lfs")
        util = require("util")
        orig_calcFreeMem = util.calcFreeMem
        G_defaults:saveSetting("DGLOBAL_CACHE_SIZE_MAXIMUM", 4 * MiB)
        util.calcFreeMem = function() return 4096 * MiB, 8192 * MiB end
        package.loaded["document/doccache"] = nil
        DocCache = require("document/doccache")
        util.calcFreeMem = orig_calcFreeMem
        G_defaults:delSetting("DGLOBAL_CACHE_SIZE_MAXIMUM")
    end)

    teardown(function()
        DocCache:clearDiskCache()
        package.loaded["document/doccache"] = nil
    end)

    it("is a single slot cache", function()
        assert.is_nil(DocCache.size)
        assert.are.equal(1, DocCache.slots)
    end)

    it("serializes without error, keeping the disk cache within the (small) budget", function()
        util.makePath(DocCache.cache_path)
        -- 3 MiB of older disk cache files, then a 2 MiB one: over the 4 MiB budget.
        local function write(name, size)
            local path = DocCache.cache_path .. name
            local f = assert(io.open(path, "wb"))
            f:write(string.rep("x", size))
            f:close()
            return path
        end
        local old = write("doccache_small_budget_old", 3 * MiB)
        lfs.touch(old, os.time() - 3600, os.time() - 3600)
        local new = write("doccache_small_budget_new", 2 * MiB)
        DocCache:refreshSnapshot()
        assert.has_no.errors(function() DocCache:serialize("/books/a.pdf") end)
        assert.is_nil(lfs.attributes(old)) -- least recently used, evicted
        assert.are.equal("file", lfs.attributes(new, "mode"))
        assert.has_no.errors(function() DocCache:serialize() end)
    end)
end)
