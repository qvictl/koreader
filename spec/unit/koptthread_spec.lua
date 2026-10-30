describe("Background KOPT context ownership", function()
    local ffi, KoptThread, state, pthread, context_type
    local context_types = 0

    setup(function()
        ffi = require("ffi")
        require("ffi/posix_h")
    end)

    before_each(function()
        state = { joins = 0, frees = 0, creates = 0, destroys = 0, fallbacks = 0, pid = 1 }
        local current = state
        local process_ffi = setmetatable({ C = { getpid = function() return current.pid end } }, { __index = ffi })
        local loader = assert(loadfile(assert(package.searchpath("document/koptthread", package.path))))
        setfenv(loader, setmetatable({ require = function(name)
            if name == "ffi" then return process_ffi end
            return require(name)
        end }, { __index = _G }))
        KoptThread = loader()
        context_types = context_types + 1
        context_type = ffi.metatype(ffi.typeof("struct { int precache; char case_id[" .. context_types .. "]; }"), {
            __index = {
                free = function()
                    -- This Lua guard is the negative oracle. No native worker
                    -- or native buffer participates in these tests.
                    if not current.complete then error("context freed before worker returned", 0) end
                    current.frees = current.frees + 1
                end,
            },
        })
        pthread = {
            pthread_attr_init = function() return current.init_error or 0 end,
            pthread_attr_destroy = function()
                current.destroys = current.destroys + 1
                return 0
            end,
            pthread_create = function(thread)
                current.creates = current.creates + 1
                if not current.held then thread[0] = 17 end
                current.thread = thread
                return current.create_error or 0
            end,
            pthread_join = function(thread)
                assert.are.equal(17, tonumber(thread), "join uses the handle written by real creation")
                current.joins = current.joins + 1
                if current.join_error then return current.join_error end
                current.complete = true
                return 0
            end,
        }
    end)

    local function start()
        local kc = context_type()
        local current = state
        local asynchronous = KoptThread.start(kc, pthread, function()
            current.fallbacks = current.fallbacks + 1
            current.complete = true
        end)
        return kc, asynchronous
    end

    it("requires a join even after the native progress flag becomes zero", function()
        local kc, asynchronous = start()
        assert.is_true(asynchronous)
        assert.are.equal(0, kc.precache)
        assert.has_error(function() kc:free() end, "context freed before worker returned")
        KoptThread.wait(kc)
        assert.is_true(state.complete)
        KoptThread.wait(kc)
        KoptThread.free(kc)
        assert.are.equal(1, state.joins)
        assert.are.equal(1, state.frees)
    end)

    it("keeps the thread array until deferred creation writes the handle", function()
        state.held = true
        local kc = start()
        assert.are.equal(0, tonumber(state.thread[0]))
        state.thread[0] = 17
        KoptThread.free(kc)
        assert.are.equal(1, state.joins)
    end)

    it("frees once across repeated eviction and subsequent garbage collection", function()
        local kc = start()
        KoptThread.free(kc)
        KoptThread.free(kc)
        assert.has_error(function() KoptThread.wait(kc) end, "KOPT context has already been freed")
        kc = nil
        collectgarbage("collect")
        collectgarbage("collect")
        assert.are.equal(1, state.joins)
        assert.are.equal(1, state.frees)
    end)

    it("joins abandoned contexts without retaining them through their finalizer", function()
        local function abandon()
            local kc = start()
            assert.is_not_nil(kc)
        end
        abandon()
        collectgarbage("collect")
        collectgarbage("collect")
        assert.are.equal(1, state.joins)
        assert.are.equal(1, state.frees)
    end)

    it("joins and frees when cache insertion raises and drops its local owner", function()
        local ok = pcall(function()
            local kc = start()
            assert.is_not_nil(kc)
            error("cache insertion failed")
        end)
        assert.is_false(ok)
        collectgarbage("collect")
        collectgarbage("collect")
        assert.are.equal(1, state.joins)
        assert.are.equal(1, state.frees)
    end)

    it("falls back synchronously when thread creation fails", function()
        state.create_error = 11
        local kc, asynchronous = start()
        assert.is_falsy(asynchronous)
        KoptThread.free(kc)
        assert.are.equal(1, state.destroys)
        assert.are.equal(1, state.fallbacks)
        assert.are.equal(0, state.joins)
        assert.are.equal(1, state.frees)
    end)

    it("does not destroy uninitialized attributes when initialization fails", function()
        state.init_error = 12
        local kc, asynchronous = start()
        assert.is_falsy(asynchronous)
        KoptThread.free(kc)
        assert.are.equal(0, state.creates)
        assert.are.equal(0, state.destroys)
        assert.are.equal(1, state.fallbacks)
        assert.are.equal(0, state.joins)
    end)

    it("falls back synchronously when pthread is unavailable", function()
        pthread = nil
        local kc, asynchronous = start()
        assert.is_falsy(asynchronous)
        KoptThread.free(kc)
        assert.are.equal(1, state.fallbacks)
        assert.are.equal(0, state.joins)
    end)

    it("refuses consumption and freeing on join failure and permits retry", function()
        local kc = start()
        state.join_error = 3
        assert.has_error(function() KoptThread.wait(kc) end, "pthread_join failed: 3")
        assert.has_error(function() KoptThread.free(kc) end, "pthread_join failed: 3")
        assert.are.equal(0, state.frees)
        state.join_error = nil
        KoptThread.free(kc)
        assert.are.equal(1, state.frees)
    end)

    it("retains failed GC owners until a later reap can safely join and free", function()
        local function abandon()
            local kc = start()
            assert.is_not_nil(kc)
        end
        state.join_error = 3
        abandon()
        collectgarbage("collect")
        collectgarbage("collect")
        assert.are.equal(0, state.frees)
        assert.is_false(KoptThread.reap())
        local next_kc, asynchronous = start()
        assert.is_true(asynchronous)
        state.join_error = nil
        KoptThread.free(next_kc)
        KoptThread.reap()
        KoptThread.reap()
        assert.are.equal(2, state.frees)
    end)

    it("rejects consumption of an inherited context and skips child destruction", function()
        local kc = start()
        state.pid = 2
        assert.has_error(function() KoptThread.wait(kc) end, "KOPT context belongs to another process")
        KoptThread.free(kc)
        kc = nil
        collectgarbage("collect")
        collectgarbage("collect")
        assert.are.equal(0, state.joins)
        assert.are.equal(0, state.frees)
    end)

    it("does not join or destroy the parent's context from a child GC finalizer", function()
        local function abandon()
            local kc = start()
            assert.is_not_nil(kc)
        end
        abandon()
        state.pid = 2
        collectgarbage("collect")
        collectgarbage("collect")
        assert.are.equal(0, state.joins)
        assert.are.equal(0, state.frees)
    end)

    it("allows reading an inherited context already joined by its parent", function()
        local kc = start()
        KoptThread.wait(kc)
        state.pid = 2
        KoptThread.wait(kc)
        KoptThread.free(kc)
        assert.are.equal(1, state.joins)
        assert.are.equal(0, state.frees)
    end)

    it("allows reading an inherited synchronous fallback without joining", function()
        state.create_error = 11
        local kc = start()
        state.pid = 2
        KoptThread.wait(kc)
        KoptThread.free(kc)
        assert.are.equal(0, state.joins)
        assert.are.equal(0, state.frees)
    end)

    it("discards inherited failed-GC records without retrying the parent's join", function()
        local function abandon()
            local kc = start()
            assert.is_not_nil(kc)
        end
        state.join_error = 3
        abandon()
        collectgarbage("collect")
        collectgarbage("collect")
        assert.are.equal(1, state.joins)
        state.pid = 2
        KoptThread.reap()
        assert.are.equal(1, state.joins)
        assert.are.equal(0, state.frees)
    end)
end)
