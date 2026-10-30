describe("KOPT background context boundaries", function()
    local ffi, KoptInterface, KoptThread, DocCache, KOPTContext, Persist
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
    end)

    before_each(function()
        DocCache:clear()
        state = { joins = 0, frees = 0 }
        local current = state
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
                current.complete = true
                return 0
            end,
        }, function() error("unexpected synchronous fallback") end)
        doc = { getPageBBox = function() return {} end }
        hash_stub = stub(KoptInterface, "getContextHash", function() end)
        reflow_stub = stub(KoptInterface, "reflowPage", function() return kc end)
    end)

    after_each(function()
        if insert_stub then insert_stub:revert(); insert_stub = nil end
        if table_stub then table_stub:revert(); table_stub = nil end
        if persist_stub then persist_stub:revert(); persist_stub = nil end
        if reflow_stub then reflow_stub:revert(); reflow_stub = nil end
        hash_stub:revert()
        DocCache:clear()
        if kc then KoptThread.free(kc); kc = nil end
        collectgarbage("collect")
        collectgarbage("collect")
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

    it("joins and frees a context rejected by the cache", function()
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
end)
