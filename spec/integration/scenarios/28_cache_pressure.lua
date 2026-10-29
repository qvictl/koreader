-- Real PDF background reflow contexts survive pressure eviction and reader closure.
local function writePDF(path)
    local lines = { "BT /F1 12 Tf 35 750 Td" }
    for _ = 1, 45 do
        lines[#lines + 1] = "(Synthetic words for background reflow and cache pressure.) Tj 0 -15 Td"
    end
    lines[#lines + 1] = "ET"
    local content = table.concat(lines, "\n")
    local objects = {
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Length " .. #content .. " >>\nstream\n" .. content .. "\nendstream",
    }
    local pdf, offsets = "%PDF-1.4\n", {}
    for i, object in ipairs(objects) do
        offsets[i] = #pdf
        pdf = pdf .. i .. " 0 obj\n" .. object .. "\nendobj\n"
    end
    local xref = #pdf
    pdf = pdf .. "xref\n0 6\n0000000000 65535 f \n"
    for _, offset in ipairs(offsets) do pdf = pdf .. string.format("%010d 00000 n \n", offset) end
    pdf = pdf .. "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n" .. xref .. "\n%%EOF\n"
    local file = assert(io.open(path, "wb"))
    file:write(pdf)
    file:close()
end

-- Hold the native worker's start instead of racing its completion. The thread,
-- attributes, entry point and context stay referenced until the real create.
local function threadBarrier()
    local ffi = require("ffi")
    local original_load = ffi.load
    local held, hold_next = nil, true
    ffi.load = function(name, ...)
        local lib = original_load(name, ...)
        if name ~= "pthread" and name ~= "libpthread.so.0" then return lib end
        return setmetatable({
            pthread_create = function(thread, attr, start, arg)
                if not hold_next then return lib.pthread_create(thread, attr, start, arg) end
                hold_next = false
                held = { lib = lib, thread = thread, attr = attr, start = start, arg = arg }
                return 0
            end,
            pthread_attr_destroy = function(attr)
                if held and attr == held.attr then return 0 end
                return lib.pthread_attr_destroy(attr)
            end,
        }, { __index = lib })
    end
    return {
        holdNext = function() hold_next = true end,
        isHeld = function() return held ~= nil end,
        release = function()
            if not held then return end
            local h = held
            held = nil
            local status = h.lib.pthread_create(h.thread, h.attr, h.start, h.arg)
            h.lib.pthread_attr_destroy(h.attr)
            if status ~= 0 then
                -- Finish native work so failed thread creation cannot leave cleanup waiting.
                h.start(h.arg)
                error("pthread_create failed: " .. status)
            end
        end,
        restore = function()
            hold_next = false
            ffi.load = original_load
        end,
    }
end

return {
    name = "PDF cache pressure and reflow context lifecycle",
    timeout = 90,
    settings = { low_memory_profile = true },
    run = function(T)
        local CacheItem = require("cacheitem")
        local DocCache = require("document/doccache")
        local KoptInterface = require("document/koptinterface")
        local util = require("util")
        local original_mem, original_wait = util.calcFreeMem, KoptInterface.waitForContext
        local waits, busy_waits, wait_ms, max_wait_ms = 0, 0, 0, 0
        local barrier = threadBarrier()
        KoptInterface.waitForContext = function(self, kc)
            if barrier.isHeld() then error("pressure attempted wait on held worker") end
            local busy, start = kc:isPreCache() == 1, T:now()
            local result = original_wait(self, kc)
            local elapsed = T:now() - start
            if busy then busy_waits = busy_waits + 1 end
            wait_ms, max_wait_ms = wait_ms + elapsed, math.max(max_wait_ms, elapsed)
            T:eq(kc:isPreCache(), 0, "native context finishes before its eviction callback frees it")
            waits = waits + 1
            return result
        end
        local path = os.getenv("KO_HOME") .. "/cache-pressure.pdf"
        writePDF(path)
        local reader = T:openBook(path)
        local limit = DocCache.cache:total_size()
        local function hint()
            DocCache:clear()
            for i = 1, 16 do DocCache:insert("pressure-metadata-" .. i, CacheItem:new{}) end
            reader.document.configurable.text_wrap = 1
            KoptInterface:hintReflowedPage(reader.document, 1, 1, 0, false)
            local found = false
            for _, item in DocCache.cache:pairs() do if item.kctx then found = true end end
            T:check(found, "real background reflow context is cached")
        end
        local function pressure(ready)
            local before, previous_waits = DocCache.cache:used_size(), waits
            local previous_busy_waits, previous_slots = busy_waits, DocCache.cache:used_slots()
            -- Only the pressure trigger is synthetic; context rendering, waiting and
            -- native cleanup use the real document and KOPT implementations.
            util.calcFreeMem = function() return 48 * 1024^2, 488 * 1024^2 end
            DocCache:memoryPressureCheck()
            util.calcFreeMem = original_mem
            if ready then
                T:check(DocCache.cache:used_size() <= before / 2, "ready-context pressure releases at least half the live bytes")
                T:check(waits > previous_waits, "ready context uses its real waiting eviction callback")
            else
                T:eq(DocCache.cache:used_slots(), math.floor(previous_slots / 2), "busy context preserves the original half-slot pressure eviction")
                T:check(DocCache.cache:used_size() > before / 2, "busy context does not trigger extra byte-based eviction")
                T:eq(waits, previous_waits, "old slot scope retains this busy native context")
            end
            T:eq(busy_waits, previous_busy_waits, "byte-based pressure adds no busy native-context wait")
            T:eq(DocCache.cache:total_size(), limit, "original byte ceiling is restored")
            T:eq(DocCache.size, limit, "configured budget is unchanged")
        end
        local function cachedContext()
            for _, item in DocCache.cache:pairs() do if item.kctx then return item.kctx end end
        end
        local context
        local ok, err = pcall(function()
            T:run(function()
                hint()
                context = cachedContext()
                T:check(barrier.isHeld(), "native worker start and attribute destruction are held")
                T:eq(context:isPreCache(), 1, "native context is deterministically busy before pressure")
                pressure(false)
                T:eq(context:isPreCache(), 1, "busy context survives the original slot eviction")
                barrier.release()
            end)
            T:waitUntil(function() return context:isPreCache() == 0 end, 20, "real native reflow completion")
            T:run(function()
                pressure(true)
                barrier.holdNext()
                hint()
                context = cachedContext()
                T:check(barrier.isHeld(), "second native hint is held before reader closure")
                T:eq(context:isPreCache(), 1, "reader closes with a pending native hint")
            end)
            -- Closing abandons the pending hint while DocCache retains its context.
            -- A later pressure check must remain safe after the native document closes.
            T:closeBook()
            T:run(barrier.release)
            T:waitUntil(function() return context:isPreCache() == 0 end, 20, "native reflow after reader closure")
            T:run(function() pressure(true) end)
            T:run(function() DocCache:clear(); DocCache:clear() end)
        end)
        util.calcFreeMem = original_mem
        -- Release before draining even on an assertion failure; never change the
        -- real native busy flag to let cleanup proceed.
        local cleaned, cleanup_err = pcall(function()
            T:run(function() barrier.release(); DocCache:clear() end)
        end)
        barrier.restore()
        KoptInterface.waitForContext = original_wait
        if not ok then error(err) end
        if not cleaned then error(cleanup_err) end
        T:metric("context_wait_callbacks", waits, "count")
        T:metric("contexts_busy_before_wait", busy_waits, "count")
        T:metric("context_wait_total_ms", wait_ms, "ms")
        T:metric("context_wait_max_ms", max_wait_ms, "ms")
    end,
}
