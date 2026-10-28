describe("Cache eviction and memory pressure", function()
    local Cache, CacheItem, DataStorage, ffiutil, lfs, logger, md5, util
    local tmp_root

    local function writeFile(path, content)
        local f = assert(io.open(path, "wb"))
        f:write(content)
        f:close()
    end

    local function readFile(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local content = f:read("*a")
        f:close()
        return content
    end

    local function exists(path)
        return lfs.attributes(path, "mode") ~= nil
    end

    -- A CacheItem that records its eviction.
    local freed
    local function newItem(name, size)
        return CacheItem:new{
            name = name,
            size = size,
            onFree = function(self) table.insert(freed, self.name) end,
        }
    end

    local function keys(cache)
        local t = {}
        for k in cache.cache:pairs() do
            table.insert(t, k)
        end
        return t
    end

    setup(function()
        require("commonrequire")
        Cache = require("cache")
        CacheItem = require("cacheitem")
        DataStorage = require("datastorage")
        ffiutil = require("ffi/util")
        lfs = require("libs/libkoreader-lfs")
        logger = require("logger")
        md5 = require("ffi/sha2").md5
        util = require("util")
        tmp_root = DataStorage:getDataDir() .. "/cache_eviction_spec"
        util.makePath(tmp_root)
    end)

    teardown(function()
        ffiutil.purgeDir(tmp_root)
    end)

    before_each(function()
        freed = {}
    end)

    describe("slot-bound cache", function()
        it("evicts the least recently used slot, get() refreshes recency", function()
            local c = Cache:new{ slots = 2 }
            assert.is_nil(c.cached)
            -- Without a disk cache, check is the raw lru getter.
            assert.are.equal(c.cache.get, c.check)
            c:insert("a", "A")
            c:insert("b", "B")
            assert.are.equal("A", c:check("a")) -- "a" is now the MRU
            c:insert("c", "C")
            assert.is_nil(c:check("b"))
            assert.are.equal("A", c:check("a"))
            assert.are.equal("C", c:check("c"))
            assert.are.same({ "c", "a" }, keys(c))
        end)

        it("re-inserting an existing key replaces the value without growing", function()
            local c = Cache:new{ slots = 2 }
            c:insert("a", 1)
            c:insert("a", 2)
            assert.are.equal(1, c.cache:used_slots())
            assert.are.equal(2, c:check("a"))
        end)

        it("clear() drops everything", function()
            local c = Cache:new{ slots = 3 }
            c:insert("a", 1)
            c:insert("b", 2)
            c:clear()
            assert.are.equal(0, c.cache:used_slots())
            assert.is_nil(c:check("a"))
        end)
    end)

    describe("size-bound cache", function()
        it("derives the slot count from size / avg_itemsize (rounded up)", function()
            local c = Cache:new{ size = 1000, avg_itemsize = 300 }
            assert.are.equal(4, c.slots)
            assert.are.equal(4, c.cache:total_slots())
            assert.are.equal(1000, c.cache:total_size())
        end)

        it("plain caches take an explicit size argument and evict by bytes", function()
            local c = Cache:new{ size = 1000, avg_itemsize = 100 }
            -- insert is lru.set(key, value, size) here
            assert.are.equal(c.cache.set, c.insert)
            c:insert("k1", {}, 600)
            c:insert("k2", {}, 300)
            assert.are.equal(900, c.cache:used_size())
            c:insert("k3", {}, 200) -- 1100 > 1000: k1 (oldest) must go
            assert.is_nil(c:check("k1"))
            assert.is_not_nil(c:check("k2"))
            assert.is_not_nil(c:check("k3"))
            assert.are.equal(500, c.cache:used_size())
        end)

        it("evicts by size in LRU order and calls onFree on evicted items", function()
            local c = Cache:new{ size = 1000, avg_itemsize = 250, enable_eviction_cb = true }
            c:insert("a", newItem("a", 300))
            c:insert("b", newItem("b", 300))
            c:insert("c", newItem("c", 300))
            assert.are.equal(900, c.cache:used_size())
            -- touch "a" so that "b" becomes the LRU
            assert.are.equal("a", c:check("a").name)
            c:insert("d", newItem("d", 300))
            assert.are.same({ "b" }, freed)
            assert.is_nil(c:check("b"))
            assert.are.equal(900, c.cache:used_size())
            -- a large (but acceptable) item can push out several older ones at once
            c:insert("e", newItem("e", 450))
            assert.are.same({ "b", "c", "a" }, freed)
            assert.are.same({ "e", "d" }, keys(c))
            assert.are.equal(750, c.cache:used_size())
        end)

        it("refuses items that would take half of the cache or more", function()
            local c = Cache:new{ size = 1000, avg_itemsize = 250, enable_eviction_cb = true }
            assert.is_true(c:willAccept(499))
            assert.is_false(c:willAccept(500))
            c:insert("small", newItem("small", 100))
            spy.on(logger, "warn")
            finally(function() logger.warn:revert() end)
            c:insert("huge", newItem("huge", 500))
            assert.spy(logger.warn).was.called_with("Too much memory would be claimed by caching", "huge")
            assert.is_nil(c:check("huge"))
            -- and it did not evict anything to make room
            assert.are.same({}, freed)
            assert.are.equal("small", c:check("small").name)
            assert.are.equal(100, c.cache:used_size())
        end)

        it("clear() frees every item", function()
            local c = Cache:new{ size = 1000, avg_itemsize = 250, enable_eviction_cb = true }
            c:insert("a", newItem("a", 100))
            c:insert("b", newItem("b", 100))
            c:clear()
            table.sort(freed)
            assert.are.same({ "a", "b" }, freed)
            assert.are.equal(0, c.cache:used_size())
        end)
    end)

    describe("memoryPressureCheck", function()
        local orig_calcFreeMem
        local c

        before_each(function()
            orig_calcFreeMem = util.calcFreeMem
            c = Cache:new{ size = 10000, avg_itemsize = 1000, enable_eviction_cb = true }
            for _, k in ipairs({ "a", "b", "c", "d" }) do
                c:insert(k, newItem(k, 100))
            end
        end)

        after_each(function()
            util.calcFreeMem = orig_calcFreeMem
        end)

        it("does nothing when memory stats are unavailable", function()
            util.calcFreeMem = function() return nil, nil end
            c:memoryPressureCheck()
            assert.are.equal(4, c.cache:used_slots())
            assert.are.same({}, freed)
        end)

        it("does nothing with at least 20% of free RAM", function()
            util.calcFreeMem = function() return 20, 100 end
            c:memoryPressureCheck()
            assert.are.equal(4, c.cache:used_slots())
            util.calcFreeMem = function() return 90, 100 end
            c:memoryPressureCheck()
            assert.are.equal(4, c.cache:used_slots())
            assert.are.same({}, freed)
        end)

        it("evicts the older half of the cache when redlining", function()
            util.calcFreeMem = function() return 19 * 1024 * 1024, 100 * 1024 * 1024 end
            spy.on(logger, "warn")
            finally(function() logger.warn:revert() end)
            c:memoryPressureCheck()
            assert.spy(logger.warn).was.called(1)
            assert.are.same({ "a", "b" }, freed)
            assert.are.same({ "d", "c" }, keys(c))
            assert.are.equal(200, c.cache:used_size())
            -- Repeated pressure keeps halving, down to nothing.
            c:memoryPressureCheck()
            assert.are.same({ "d" }, keys(c))
            c:memoryPressureCheck()
            assert.are.same({}, keys(c))
            -- An empty cache under pressure is not an error.
            c:memoryPressureCheck()
            assert.are.equal(0, c.cache:used_slots())
        end)
    end)

    describe("disk cache", function()
        local dir
        local LoadableItem -- set in before_each (CacheItem is loaded in setup)

        before_each(function()
            dir = tmp_root .. "/disk_" .. tostring(os.clock()):gsub("%.", "_") .. "/"
            util.makePath(dir)
            writeFile(dir .. md5("good"), "good payload")
            writeFile(dir .. md5("bad"), "corrupted")
            lfs.mkdir(dir .. "subdir")
            LoadableItem = CacheItem:extend{
                size = 10,
                load = function(self, path)
                    local content = readFile(path)
                    if content == "corrupted" then
                        error("unusable cache file")
                    end
                    self.payload = content
                end,
            }
        end)

        it("snapshots regular files only", function()
            local c = Cache:new{ slots = 4, disk_cache = true, cache_path = dir }
            assert.are.equal(dir .. md5("good"), c.cached[md5("good")])
            assert.are.equal(dir .. md5("bad"), c.cached[md5("bad")])
            assert.is_nil(c.cached["subdir"])
            assert.is_nil(c.cached["."])
            assert.is_nil(c.cached[".."])
        end)

        it("loads hits from disk into memory, purges unusable files", function()
            local c = Cache:new{ slots = 4, disk_cache = true, cache_path = dir }
            -- Not in memory, no ItemClass: disk is not checked
            assert.is_nil(c:check("good"))
            assert.is_nil(c:get("good"))

            local item = c:check("good", LoadableItem)
            assert.are.equal("good payload", item.payload)
            -- now served from memory
            assert.are.equal(item, c:get("good"))
            assert.are.equal(item, c:check("good"))

            spy.on(logger, "warn")
            finally(function() logger.warn:revert() end)
            assert.is_nil(c:check("bad", LoadableItem))
            assert.spy(logger.warn).was.called(1)
            assert.is_false(exists(dir .. md5("bad")))
            -- snapshot was refreshed
            assert.is_nil(c.cached[md5("bad")])
            assert.is_not_nil(c.cached[md5("good")])
            assert.is_nil(c:get("bad"))

            -- unknown key: miss
            assert.is_nil(c:check("missing", LoadableItem))
        end)

        it("disk hits go through the size-checking insert on size-bound caches", function()
            local c = Cache:new{ size = 100, avg_itemsize = 10, enable_eviction_cb = true,
                                 disk_cache = true, cache_path = dir }
            local item = c:check("good", LoadableItem)
            assert.are.equal("good payload", item.payload)
            assert.are.equal(10, c.cache:used_size())
        end)

        it("clearDiskCache removes the cached files and refreshes the snapshot", function()
            local c = Cache:new{ slots = 4, disk_cache = true, cache_path = dir }
            c:clearDiskCache()
            assert.is_false(exists(dir .. md5("good")))
            assert.is_false(exists(dir .. md5("bad")))
            assert.are.equal("directory", lfs.attributes(dir .. "subdir", "mode"))
            assert.are.same({}, c.cached)
            -- a file appearing later is picked up by refreshSnapshot
            writeFile(dir .. md5("new"), "x")
            c:refreshSnapshot()
            assert.are.equal(dir .. md5("new"), c.cached[md5("new")])
        end)

        it("snapshot helpers are no-ops without a disk cache", function()
            local c = Cache:new{ slots = 4 }
            c:refreshSnapshot()
            c:clearDiskCache()
            assert.is_nil(c.cached)
            assert.is_true(exists(dir .. md5("good")))
        end)
    end)
end)

describe("DocCache", function()
    local CacheItem, DataStorage, DocCache, MemoryTuning, ffiutil, lfs, logger, md5, util
    local tmp_dir
    local saved = {}

    local function writeFile(path, size)
        local f = assert(io.open(path, "wb"))
        f:write(string.rep("x", size))
        f:close()
    end

    local function exists(path)
        return lfs.attributes(path, "mode") ~= nil
    end

    setup(function()
        require("commonrequire")
        CacheItem = require("cacheitem")
        DataStorage = require("datastorage")
        ffiutil = require("ffi/util")
        DocCache = require("document/doccache")
        MemoryTuning = require("memorytuning")
        lfs = require("libs/libkoreader-lfs")
        logger = require("logger")
        md5 = require("ffi/sha2").md5
        util = require("util")
    end)

    describe("sizing", function()
        local orig_calcFreeMem

        -- Re-evaluates the doccache module (its size is computed once, at load time) with a fake memory state.
        local function loadDocCache(memfree, low_memory)
            local singleton = package.loaded["document/doccache"]
            package.loaded["document/doccache"] = nil
            util.calcFreeMem = function() return memfree, memfree and memfree * 2 end
            MemoryTuning._is_low_memory = low_memory
            local ok, dc = pcall(require, "document/doccache")
            package.loaded["document/doccache"] = singleton
            util.calcFreeMem = orig_calcFreeMem
            MemoryTuning._is_low_memory = nil
            assert(ok, dc)
            return dc
        end

        local MiB = 1024 * 1024

        before_each(function()
            orig_calcFreeMem = util.calcFreeMem
        end)

        after_each(function()
            util.calcFreeMem = orig_calcFreeMem
            MemoryTuning._is_low_memory = nil
            G_defaults:delSetting("DGLOBAL_CACHE_SIZE_MAXIMUM")
            G_defaults:delSetting("DGLOBAL_CACHE_SIZE_MINIMUM")
        end)

        it("uses a proportion of free memory, capped by the maximum", function()
            local dc = loadDocCache(100 * MiB, false)
            assert.are.equal(40 * MiB, dc.size)
            assert.are.equal(40 * MiB, dc.cache:total_size())
            assert.is_true(dc.enable_eviction_cb)
            assert.is_true(dc.disk_cache)
            assert.are.equal(DataStorage:getDataDir() .. "/cache/", dc.cache_path)

            dc = loadDocCache(4096 * MiB, false)
            assert.are.equal(512 * MiB, dc.size)
        end)

        it("never goes below the minimum, even without meminfo", function()
            assert.are.equal(16 * MiB, loadDocCache(10 * MiB, false).size)
            assert.are.equal(16 * MiB, loadDocCache(nil, false).size)
        end)

        it("caps the budget at 32 MiB on low memory devices", function()
            assert.are.equal(32 * MiB, loadDocCache(4096 * MiB, true).size)
            -- below the cap, the proportion still applies
            assert.are.equal(20 * MiB, loadDocCache(50 * MiB, true).size)
        end)

        it("honors a customized maximum on low memory devices", function()
            G_defaults:saveSetting("DGLOBAL_CACHE_SIZE_MAXIMUM", 64 * MiB)
            assert.are.equal(64 * MiB, loadDocCache(4096 * MiB, true).size)
        end)

        it("degrades to a single slot cache below 8 MiB", function()
            G_defaults:saveSetting("DGLOBAL_CACHE_SIZE_MAXIMUM", 4 * MiB)
            local dc = loadDocCache(4096 * MiB, false)
            assert.is_nil(dc.size)
            assert.are.equal(1, dc.slots)
            assert.are.equal(1, dc.cache:total_slots())
            assert.is_nil(dc.cache:total_size())
            -- Inserts go straight to the lru, so the single slot just keeps the latest item.
            dc:insert("a", CacheItem:new{ size = 10 * MiB })
            dc:insert("b", CacheItem:new{ size = 10 * MiB })
            assert.is_nil(dc:check("a"))
            assert.is_not_nil(dc:check("b"))
            dc:clear()
        end)
    end)

    describe("serialize", function()
        local dumped
        local function newDumpable(key, doc_path, opts)
            opts = opts or {}
            local item = CacheItem:new{
                key = key,
                size = 1,
                persistent = opts.persistent ~= false,
                doc_path = doc_path,
                dump = function(self, path)
                    table.insert(dumped, { key = self.key, path = path })
                    local size = opts.dump_size or 100
                    if opts.write ~= false then
                        writeFile(path, size)
                    end
                    return size
                end,
            }
            if opts.no_dump then
                item.dump = nil
            end
            return item
        end

        before_each(function()
            dumped = {}
            tmp_dir = DataStorage:getDataDir() .. "/doccache_spec_" .. tostring(os.clock()):gsub("%.", "_") .. "/"
            util.makePath(tmp_dir)
            saved.cache_path = DocCache.cache_path
            saved.size = DocCache.size
            saved.cached = DocCache.cached
            saved.disk_cache = DocCache.disk_cache
            DocCache:clear()
            DocCache.cache_path = tmp_dir
            DocCache:refreshSnapshot()
        end)

        after_each(function()
            DocCache:clear()
            DocCache.cache_path = saved.cache_path
            DocCache.size = saved.size
            DocCache.disk_cache = saved.disk_cache
            DocCache.cached = saved.cached
            DocCache:refreshSnapshot()
            ffiutil.purgeDir(tmp_dir)
        end)

        it("is a no-op without a disk cache", function()
            DocCache.disk_cache = false
            DocCache.cache:set("k", newDumpable("k", "/book.pdf"), 1)
            spy.on(DocCache, "refreshSnapshot")
            finally(function() DocCache.refreshSnapshot:revert() end)
            DocCache:serialize("/book.pdf")
            assert.spy(DocCache.refreshSnapshot).was_not.called()
            assert.are.same({}, dumped)
        end)

        it("dumps the displayed page (skipping hinted pages, other books and non persistent items)", function()
            local doc = "/books/a.pdf"
            -- oldest -> newest
            DocCache.cache:set("a1", newDumpable("a1", doc), 1)
            DocCache.cache:set("a2", newDumpable("a2", doc), 1)
            DocCache.cache:set("other", newDumpable("other", "/books/b.pdf"), 1)
            DocCache.cache:set("volatile", newDumpable("volatile", doc, { persistent = false }), 1)
            DocCache.cache:set("nodump", newDumpable("nodump", doc, { no_dump = true }), 1)
            DocCache.cache:set("a3", newDumpable("a3", doc), 1) -- most recently *hinted* page
            assert.are.equal(1, G_defaults:readSetting("DHINTCOUNT"))
            DocCache:serialize(doc)
            assert.are.equal(1, #dumped)
            assert.are.equal("a2", dumped[1].key)
            assert.are.equal(tmp_dir .. md5("a2"), dumped[1].path)
            -- the snapshot now knows about the new file
            assert.are.equal(tmp_dir .. md5("a2"), DocCache.cached[md5("a2")])
        end)

        it("falls back to the only matching item, and never re-dumps an existing file", function()
            local doc = "/books/a.pdf"
            DocCache.cache:set("only", newDumpable("only", doc), 1)
            DocCache.cache:set("other", newDumpable("other", "/books/b.pdf"), 1)
            DocCache:serialize(doc)
            assert.are.equal(1, #dumped)
            assert.are.equal("only", dumped[1].key)
            DocCache:serialize(doc)
            assert.are.equal(1, #dumped)
        end)

        it("does not dump anything without a document, or without a match", function()
            DocCache.cache:set("a1", newDumpable("a1", "/books/a.pdf"), 1)
            DocCache:serialize()
            DocCache:serialize("/books/unknown.pdf")
            assert.are.same({}, dumped)
        end)

        it("trims the disk cache to the memory budget, least recently accessed first", function()
            local now = os.time()
            for _, name in ipairs({ "old", "older", "newest", "oldest" }) do
                writeFile(tmp_dir .. name, 1000)
            end
            lfs.touch(tmp_dir .. "oldest", now - 400, now - 400)
            lfs.touch(tmp_dir .. "older", now - 300, now - 300)
            lfs.touch(tmp_dir .. "old", now - 200, now - 200)
            lfs.touch(tmp_dir .. "newest", now - 100, now - 100)
            DocCache:refreshSnapshot()
            DocCache.size = 2500
            DocCache:serialize()
            assert.is_false(exists(tmp_dir .. "oldest"))
            assert.is_false(exists(tmp_dir .. "older"))
            assert.is_true(exists(tmp_dir .. "old"))
            assert.is_true(exists(tmp_dir .. "newest"))
            assert.is_nil(DocCache.cached["oldest"])
            assert.are.equal(tmp_dir .. "newest", DocCache.cached["newest"])

            -- Within budget: nothing else goes away.
            DocCache:serialize()
            assert.is_true(exists(tmp_dir .. "old"))
            assert.is_true(exists(tmp_dir .. "newest"))
        end)

        it("counts the freshly dumped page against the budget", function()
            local now = os.time()
            writeFile(tmp_dir .. "stale", 1000)
            lfs.touch(tmp_dir .. "stale", now - 100, now - 100)
            DocCache:refreshSnapshot()
            DocCache.size = 1500
            DocCache.cache:set("p", newDumpable("p", "/books/a.pdf", { dump_size = 1000 }), 1)
            DocCache:serialize("/books/a.pdf")
            assert.is_false(exists(tmp_dir .. "stale"))
            assert.is_true(exists(tmp_dir .. md5("p")))
        end)

        it("bails out instead of looping when accounting is off", function()
            DocCache.size = 10
            -- The dumped page alone exceeds the budget, and it is not a candidate for eviction.
            DocCache.cache:set("p", newDumpable("p", "/books/a.pdf", { dump_size = 1000, write = false }), 1)
            spy.on(logger, "warn")
            finally(function() logger.warn:revert() end)
            DocCache:serialize("/books/a.pdf")
            assert.spy(logger.warn).was.called_with("Cache accounting is broken")
            assert.are.equal(1, #dumped)
        end)
    end)
end)
