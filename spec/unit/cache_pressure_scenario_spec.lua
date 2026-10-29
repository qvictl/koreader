describe("Cache pressure scenario failure cleanup", function()
    local DocCache, DocumentRegistry, KoptInterface, ffi, ffiutil, time, util, scenario
    local active, mode, closes, creates, destroys
    local original_load, original_wait, original_mem, original_open
    local open_stub

    setup(function()
        require("commonrequire")
        DocCache = require("document/doccache")
        DocumentRegistry = require("document/documentregistry")
        KoptInterface = require("document/koptinterface")
        ffi, ffiutil, time, util = require("ffi"), require("ffi/util"), require("ui/time"), require("util")
        local spec_dir = debug.getinfo(1, "S").source:sub(2):match("^(.*)/unit/[^/]+$")
        scenario = dofile(spec_dir .. "/integration/scenarios/28_cache_pressure.lua")
    end)

    before_each(function()
        active, closes, creates, destroys = nil, 0, 0, 0
        open_stub = nil
        original_load, original_wait = ffi.load, KoptInterface.waitForContext
        original_mem, original_open = util.calcFreeMem, io.open
    end)

    after_each(function()
        ffi.load, KoptInterface.waitForContext = original_load, original_wait
        util.calcFreeMem = original_mem
        if open_stub then open_stub:revert() end
        if active then active.document:close(); active = nil end
        DocCache:clear()
        os.remove(os.getenv("KO_HOME") .. "/cache-pressure.pdf")
    end)

    local function runFailure()
        local T = {
            now = function() return time.to_ms(time.now()) end,
            run = function(_, fn) return fn() end,
            reader = function() return active end,
            openBook = function(_, path)
                active = { document = assert(DocumentRegistry:openDocument(path)) }
                if mode == "open" then error("injected open failure") end
                return active
            end,
            closeBook = function()
                closes = closes + 1
                if mode == "close" and closes == 1 then error("injected close failure") end
                if active then active.document:close(); active = nil end
            end,
            eq = function(_, actual, expected, message) assert.are.equal(expected, actual, message) end,
            check = function(_, condition, message) assert.is_true(condition, message) end,
            metric = function() end,
            waitUntil = function(_, predicate, timeout)
                local deadline = time.to_ms(time.now()) + timeout * 1000
                while not predicate() do
                    assert.is_true(time.to_ms(time.now()) < deadline, "native reflow must complete")
                    ffiutil.usleep(10000)
                end
            end,
        }
        local ok, err = pcall(scenario.run, T)
        assert.is_false(ok)
        assert.is_not_nil(tostring(err):find("injected " .. mode .. " failure", 1, true))
        assert.are.equal(original_wait, KoptInterface.waitForContext)
        assert.are.equal(original_mem, util.calcFreeMem)
        assert.is_nil(active)
        assert.are.equal(0, DocCache.cache:used_slots())
    end

    it("restores hooks when writing the PDF fails during setup", function()
        mode = "write"
        open_stub = stub(io, "open", function(path, flags, ...)
            if path:match("/cache%-pressure%.pdf$") and flags == "wb" then
                return nil, "injected write failure"
            end
            return original_open(path, flags, ...)
        end)
        runFailure()
        assert.are.equal(original_load, ffi.load)
        assert.are.equal(0, closes)
    end)

    it("closes a real document after a partially failed open", function()
        mode = "open"
        runFailure()
        assert.are.equal(original_load, ffi.load)
        assert.are.equal(1, closes)
    end)

    it("releases real held reflow workers and drains after a close error", function()
        mode = "close"
        local observed_load = function(name, ...)
            local lib = original_load(name, ...)
            if name ~= "pthread" and name ~= "libpthread.so.0" then return lib end
            return setmetatable({
                pthread_create = function(...)
                    creates = creates + 1
                    return lib.pthread_create(...)
                end,
                pthread_attr_destroy = function(...)
                    destroys = destroys + 1
                    return lib.pthread_attr_destroy(...)
                end,
            }, { __index = lib })
        end
        ffi.load = observed_load
        runFailure()
        assert.are.equal(observed_load, ffi.load)
        assert.are.equal(2, closes)
        assert.are.equal(2, creates)
        assert.are.equal(2, destroys)
        assert.is_nil(KoptInterface.bg_thread)
    end)
end)
