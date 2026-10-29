describe("Cache memory pressure", function()
    local Cache, CacheItem, util, old_calc_free_mem
    local caches, freed, restores

    setup(function()
        require("commonrequire")
        Cache = require("cache")
        CacheItem = require("cacheitem")
        util = require("util")
    end)

    before_each(function()
        caches, freed, restores = {}, {}, {}
        old_calc_free_mem = util.calcFreeMem
        util.calcFreeMem = function() return 19, 100 end
    end)

    after_each(function()
        util.calcFreeMem = old_calc_free_mem
        for _, cache in ipairs(caches) do cache:clear() end
        for i = #restores, 1, -1 do restores[i]() end
    end)

    local function newCache(slots)
        local cache = Cache:new{
            slots = slots,
            size = not slots and 1000 or nil,
            avg_itemsize = 20,
            enable_eviction_cb = true,
        }
        caches[#caches + 1] = cache
        return cache
    end

    local function insert(cache, key, bytes)
        local item = CacheItem:new{ size = bytes }
        function item:onFree() freed[key] = (freed[key] or 0) + 1 end
        cache:insert(key, item)
    end

    local function fill(cache)
        for i = 1, 16 do insert(cache, "metadata" .. i, 1) end
        for i = 1, 4 do insert(cache, "tile" .. i, 200) end
    end

    it("leaves caches unchanged at and above the pressure threshold", function()
        local cache = newCache()
        fill(cache)
        for _, free in ipairs({ 20, 21, 100 }) do
            util.calcFreeMem = function() return free, 100 end
            cache:memoryPressureCheck()
            assert.are.equal(816, cache.cache:used_size())
            assert.are.equal(20, cache.cache:used_slots())
            assert.same({}, freed)
        end
    end)

    it("skips unavailable memory statistics", function()
        local cache = newCache()
        fill(cache)
        util.calcFreeMem = function() return nil, nil end
        cache:memoryPressureCheck()
        assert.are.equal(816, cache.cache:used_size())
        assert.same({}, freed)
    end)

    it("halves mixed live bytes and frees each evicted item exactly once", function()
        local cache = newCache()
        fill(cache)
        cache:memoryPressureCheck()
        assert.are.equal(400, cache.cache:used_size())
        assert.are.equal(2, cache.cache:used_slots())
        for i = 1, 16 do assert.are.equal(1, freed["metadata" .. i]) end
        assert.are.equal(1, freed.tile1)
        assert.are.equal(1, freed.tile2)
        assert.is_nil(freed.tile3)
        assert.is_nil(freed.tile4)
        cache:clear()
        assert.are.equal(1, freed.tile3)
        assert.are.equal(1, freed.tile4)
        for _, count in pairs(freed) do assert.are.equal(1, count) end
    end)

    it("preserves the original byte ceiling and permits refilling", function()
        local cache = newCache()
        fill(cache)
        cache:memoryPressureCheck()
        assert.are.equal(1000, cache.size)
        assert.are.equal(1000, cache.cache:total_size())
        insert(cache, "tile5", 200)
        assert.are.equal(600, cache.cache:used_size())
        assert.is_not_nil(cache:check("tile3"))
        assert.is_not_nil(cache:check("tile4"))
        assert.is_not_nil(cache:check("tile5"))
    end)

    it("evicts in LRU order after a cached tile is touched", function()
        local cache = newCache()
        fill(cache)
        cache:check("tile1")
        cache:memoryPressureCheck()
        local keys = {}
        for key in cache.cache:pairs() do keys[#keys + 1] = key end
        assert.same({ "tile1", "tile4" }, keys)
        assert.are.equal(1, freed.tile2)
        assert.are.equal(1, freed.tile3)
        assert.is_nil(freed.tile1)
    end)

    it("retains slot-only cache chopping and callbacks", function()
        local cache = newCache(4)
        for i = 1, 4 do insert(cache, "slot" .. i, 1) end
        cache:memoryPressureCheck()
        assert.are.equal(2, cache.cache:used_slots())
        assert.are.equal(4, cache.cache:total_slots())
        assert.is_nil(cache.cache:total_size())
        assert.are.equal(1, freed.slot1)
        assert.are.equal(1, freed.slot2)
        assert.is_nil(freed.slot3)
        assert.is_nil(freed.slot4)
    end)

    it("accepts empty byte-bound and slot-only caches", function()
        local bytes, slots = newCache(), newCache(4)
        bytes:memoryPressureCheck()
        slots:memoryPressureCheck()
        assert.are.equal(0, bytes.cache:used_size())
        assert.are.equal(1000, bytes.cache:total_size())
        assert.are.equal(0, slots.cache:used_slots())
        assert.same({}, freed)
    end)

    it("waits for reflow contexts before pressure eviction and later cache cleanup", function()
        local KoptInterface = require("document/koptinterface")
        local DocCache = require("document/doccache")
        local FFIUtil = require("ffi/util")
        local cache = newCache()
        local contexts, waits = {}, 0
        local old_cache, old_size = DocCache.cache, DocCache.size
        local old_bg, old_context_size = KoptInterface.bg_thread, KoptInterface.last_context_size
        DocCache.cache, DocCache.size = cache.cache, cache.size
        KoptInterface.last_context_size = 200
        restores[#restores + 1] = function()
            DocCache.cache, DocCache.size = old_cache, old_size
            KoptInterface.bg_thread, KoptInterface.last_context_size = old_bg, old_context_size
        end
        local function replace(object, key, value)
            local old = object[key]
            object[key] = value
            restores[#restores + 1] = function() object[key] = old end
        end
        replace(KoptInterface, "getContextHash", function(_, _, page, _, hash)
            hash[#hash + 1] = page
        end)
        replace(KoptInterface, "reflowPage", function(_, _, page)
            local context = { busy = true, frees = 0 }
            function context:isPreCache() return self.busy and 1 or 0 end
            function context:free()
                assert.is_false(self.busy)
                self.frees = self.frees + 1
                assert.are.equal(1, self.frees)
            end
            contexts[page] = context
            KoptInterface.bg_thread = true
            return context
        end)
        replace(FFIUtil, "usleep", function(delay)
            assert.are.equal(100000, delay)
            waits = waits + 1
            for _, context in pairs(contexts) do context.busy = false end
        end)
        for i = 1, 16 do insert(cache, "metadata" .. i, 1) end
        local doc = { getPageBBox = function() return nil end }
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, false)
        KoptInterface:hintReflowedPage(doc, 2, 1, 0, false)
        DocCache:memoryPressureCheck()
        assert.are.equal(1, waits)
        assert.are.equal(1, contexts[1].frees)
        assert.are.equal(0, contexts[2].frees)
        assert.is_nil(KoptInterface.bg_thread)
        assert.are.equal(1000, cache.cache:total_size())
        -- A later cache clear must also wait for any remaining busy context.
        contexts[2].busy = true
        KoptInterface.bg_thread = true
        DocCache:clear()
        DocCache:clear()
        assert.are.equal(2, waits)
        assert.are.equal(1, contexts[1].frees)
        assert.are.equal(1, contexts[2].frees)
        assert.is_nil(KoptInterface.bg_thread)
    end)
end)
