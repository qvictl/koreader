describe("KOPT background context boundaries", function()
    local ffi, KoptInterface, KoptThread, DocCache, KOPTContext, Persist
    local CanvasContext, thread_methods, cpu_stub, old_bg, old_cache
    local create_stub, start_stub, free_stub
    local admission_stub, accept_stub, old_size, old_context_size
    local state, kc, doc, reflow_stub, hash_stub, insert_stub, table_stub, persist_stub
    local context_types = 0

    setup(function()
        require("commonrequire")
        ffi = require("ffi")
        KoptInterface = require("document/koptinterface")
        KoptThread = require("document/koptthread")
        DocCache = require("document/doccache")
        KOPTContext = require("ffi/koptcontext")
        Persist = require("persist")
        CanvasContext = require("document/canvascontext")
    end)

    before_each(function()
        DocCache:clear()
        state = { joins = 0, frees = 0, pid = 1 }
        local current = state
        old_bg, old_cache = KoptInterface.bg_thread, DocCache.cache
        old_size, old_context_size = DocCache.size, KoptInterface.last_context_size
        local process_ffi = setmetatable({ C = { getpid = function() return current.pid end } }, { __index = ffi })
        local loader = assert(loadfile(assert(package.searchpath("document/koptthread", package.path))))
        setfenv(loader, setmetatable({ require = function(name)
            if name == "ffi" then return process_ffi end
            return require(name)
        end }, { __index = _G }))
        thread_methods = {}
        for name, method in pairs(loader()) do
            thread_methods[name], KoptThread[name] = KoptThread[name], method
        end
        context_types = context_types + 1
        local ctype = ffi.metatype(ffi.typeof("struct { int precache; char boundary_id[" .. context_types .. "]; }"), {
            __index = {
                isPreCache = function(context) return context.precache end,
                free = function()
                    if not current.complete then error("free requires completed join", 0) end
                    current.frees = current.frees + 1
                end,
                getPageDim = function()
                    if not current.complete then error("consume requires completed join", 0) end
                    return 100, 100
                end,
            },
        })
        kc = ctype()
        KoptThread.start(kc, {
            pthread_attr_init = function() return 0 end,
            pthread_attr_destroy = function() return 0 end,
            pthread_create = function(thread) thread[0] = 19; return 0 end,
            pthread_join = function(thread)
                assert.are.equal(19, tonumber(thread))
                current.joins = current.joins + 1
                if current.join_error then return current.join_error end
                current.complete = true
                return 0
            end,
        }, function() error("unexpected synchronous fallback") end)
        doc = { getPageBBox = function() return {} end }
        hash_stub = stub(KoptInterface, "getContextHash", function() end)
        reflow_stub = stub(KoptInterface, "reflowPage", function() return kc end)
    end)

    after_each(function()
        state.join_error = nil
        if create_stub then create_stub:revert(); create_stub = nil end
        if start_stub then start_stub:revert(); start_stub = nil end
        if free_stub then free_stub:revert(); free_stub = nil end
        if admission_stub then admission_stub:revert(); admission_stub = nil end
        if accept_stub then accept_stub:revert(); accept_stub = nil end
        if insert_stub then insert_stub:revert(); insert_stub = nil end
        if table_stub then table_stub:revert(); table_stub = nil end
        if persist_stub then persist_stub:revert(); persist_stub = nil end
        if reflow_stub then reflow_stub:revert(); reflow_stub = nil end
        hash_stub:revert()
        DocCache:clear()
        if kc then KoptThread.free(kc); kc = nil end
        collectgarbage("collect")
        collectgarbage("collect")
        KoptThread.reap()
        if cpu_stub then cpu_stub:revert(); cpu_stub = nil end
        KoptInterface.bg_thread, DocCache.cache = old_bg, old_cache
        DocCache.size, KoptInterface.last_context_size = old_size, old_context_size
        for name, method in pairs(thread_methods) do KoptThread[name] = method end
    end)

    it("joins before consuming a cached context whose progress flag is zero", function()
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, false)
        assert.are.equal(0, kc:isPreCache())
        assert.has_error(function() kc:getPageDim() end, "consume requires completed join")
        assert.are.equal(kc, KoptInterface:getCachedContext(doc, 1))
        assert.are.equal(1, state.joins)
    end)

    it("joins before serializing context fields that native code still owns", function()
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, false)
        table_stub = stub(KOPTContext, "totable", function()
            if not state.complete then error("serialize requires completed join", 0) end
            return {}
        end)
        persist_stub = stub(Persist, "new", function()
            return { save = function() return true, 123 end }
        end)
        assert.are.equal(123, DocCache:check("kctx"):dump("unused"))
        assert.are.equal(1, state.joins)
    end)

    it("skips serialization while the context still reports busy", function()
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, false)
        kc.precache = 1
        assert.is_nil(DocCache:check("kctx"):dump("unused"))
        assert.are.equal(0, state.joins)
    end)

    it("joins before an eviction callback frees the context", function()
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, false)
        DocCache:clear()
        assert.are.equal(1, state.joins)
        assert.are.equal(1, state.frees)
        KoptThread.free(kc)
        assert.are.equal(1, state.frees)
    end)

    it("joins and frees if insertion unexpectedly drops an admitted context", function()
        insert_stub = stub(DocCache, "insert", function() end)
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, false)
        assert.is_nil(DocCache:check("kctx"))
        -- Spies retain their argument and return history, including the item.
        insert_stub:clear(); insert_stub:revert(); insert_stub = nil
        reflow_stub:clear(); reflow_stub:revert(); reflow_stub = nil
        kc = nil
        collectgarbage("collect")
        collectgarbage("collect")
        assert.are.equal(1, state.joins)
        assert.are.equal(1, state.frees)
    end)

    it("joins and frees after cache insertion raises", function()
        insert_stub = stub(DocCache, "insert", function() error("cache insertion failure", 0) end)
        assert.has_error(function() KoptInterface:hintReflowedPage(doc, 1, 1, 0, false) end,
            "cache insertion failure")
        insert_stub:clear(); insert_stub:revert(); insert_stub = nil
        reflow_stub:clear(); reflow_stub:revert(); reflow_stub = nil
        kc = nil
        collectgarbage("collect")
        collectgarbage("collect")
        assert.are.equal(1, state.joins)
        assert.are.equal(1, state.frees)
    end)

    it("restores parent CPU configuration after a consumption join fails", function()
        cpu_stub = stub(CanvasContext, "enableCPUCores", function() end)
        state.join_error = 3
        KoptInterface.bg_thread = true
        assert.has_error(function() KoptInterface:waitForContext(kc) end, "pthread_join failed: 3")
        assert.stub(cpu_stub).was.called_with(CanvasContext, 1)
        assert.is_nil(KoptInterface.bg_thread)
        assert.are.equal(0, state.frees)
    end)

    it("restores parent CPU configuration without freeing after an eviction join fails", function()
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, false)
        cpu_stub = stub(CanvasContext, "enableCPUCores", function() end)
        state.join_error = 3
        KoptInterface.bg_thread = true
        assert.has_error(function() DocCache:clear() end, "pthread_join failed: 3")
        assert.stub(cpu_stub).was.called_with(CanvasContext, 1)
        assert.is_nil(KoptInterface.bg_thread)
        assert.are.equal(0, state.frees)
    end)

    it("lets child cache insertion evict an inherited worker without joining or touching CPU settings", function()
        local cache = require("cache"):new{ slots = 1, enable_eviction_cb = true }
        DocCache.cache = cache.cache
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, false)
        state.pid = 2
        KoptInterface.bg_thread = true
        cpu_stub = stub(CanvasContext, "enableCPUCores", function() end)
        local tile = require("cacheitem"):new{ size = 1 }
        DocCache:insert("child-tile", tile)
        assert.are.equal(tile, DocCache:check("child-tile"))
        assert.is_nil(DocCache:check("kctx"))
        assert.are.equal(0, state.joins)
        assert.are.equal(0, state.frees)
        assert.stub(cpu_stub).was_not.called()
        assert.is_true(KoptInterface.bg_thread)
    end)

    it("rejects child consumption of an inherited worker without touching CPU settings", function()
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, false)
        state.pid = 2
        KoptInterface.bg_thread = true
        cpu_stub = stub(CanvasContext, "enableCPUCores", function() end)
        assert.has_error(function() KoptInterface:getCachedContext(doc, 1) end,
            "KOPT context belongs to another process")
        assert.stub(cpu_stub).was_not.called()
        assert.is_true(KoptInterface.bg_thread)
        assert.are.equal(0, state.joins)
        assert.are.equal(0, state.frees)
    end)

    it("discards an unstarted hint and restores CPU configuration without caching it", function()
        reflow_stub:revert(); reflow_stub = nil
        local discarded = 0
        local context = { zoom = 1, quality = 1, dev_width = 600, setPreCache = function() end } -- unscaled_size_check: ignore (native pixel fixture)
        create_stub = stub(KoptInterface, "createContext", function() return context end)
        start_stub = stub(KoptThread, "start", function() return false end)
        free_stub = stub(KoptThread, "free", function(value)
            assert.are.equal(context, value)
            discarded = discarded + 1
        end)
        cpu_stub = stub(CanvasContext, "enableCPUCores", function() end)
        doc.getPageBBox = function() return { x1 = 600 } end
        doc.configurable = {}
        doc._document = { openPage = function()
            return { getPagePix = function() end, close = function() end }
        end }
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, true)
        assert.are.equal(1, discarded)
        assert.is_nil(DocCache:check("kctx"))
        assert.is_nil(KoptInterface.bg_thread)
        assert.stub(cpu_stub).was.called_with(CanvasContext, 2)
        assert.stub(cpu_stub).was.called_with(CanvasContext, 1)
    end)

    local function checkSkippedHint()
        assert.stub(reflow_stub).was_not.called()
        assert.stub(cpu_stub).was_not.called()
        assert.is_nil(DocCache:check("kctx"))
        local joined = state.joins
        collectgarbage("collect")
        collectgarbage("collect")
        assert.are.equal(joined, state.joins, "rejected hints add no context waiting in GC")
    end

    it("rejects oversized hints before rendering, starting or boosting CPUs", function()
        KoptInterface.last_context_size = DocCache.size
        cpu_stub = stub(CanvasContext, "enableCPUCores", function() end)
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, true)
        checkSkippedHint()
        assert.are.equal(0, state.joins)
    end)

    it("skips unavailable workers before rendering or boosting CPUs", function()
        admission_stub = stub(KoptThread, "canStart", function() return false end)
        cpu_stub = stub(CanvasContext, "enableCPUCores", function() end)
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, true)
        checkSkippedHint()
        assert.are.equal(0, state.joins)
    end)

    it("skips quarantined workers without creating another orphan context", function()
        state.join_error = 3
        kc = nil
        collectgarbage("collect")
        collectgarbage("collect")
        assert.are.equal(0, state.frees)
        cpu_stub = stub(CanvasContext, "enableCPUCores", function() end)
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, true)
        checkSkippedHint()
        assert.are.equal(0, state.frees)
    end)

    it("uses the admitted byte estimate unchanged when inserting the context", function()
        KoptInterface.last_context_size = 17000
        admission_stub = stub(KoptThread, "canStart", function()
            KoptInterface.last_context_size = 99000
            return true
        end)
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, false)
        assert.are.equal(17000, DocCache:check("kctx").size)
    end)

    it("admits a slot-only cache without calling its byte-budget predicate", function()
        DocCache.size = nil
        accept_stub = stub(DocCache, "willAccept", function() error("slot-only cache has no byte budget") end)
        -- Cache:init uses a direct slot insertion method in this configuration.
        insert_stub = stub(DocCache, "insert", function() end)
        KoptInterface:hintReflowedPage(doc, 1, 1, 0, false)
        assert.stub(accept_stub).was_not.called()
        assert.stub(reflow_stub).was.called(1)
        assert.stub(insert_stub).was.called(1)
    end)
end)
