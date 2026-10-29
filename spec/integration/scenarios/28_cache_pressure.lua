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
        KoptInterface.waitForContext = function(self, kc)
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
        local function pressure()
            local before, previous_waits = DocCache.cache:used_size(), waits
            -- Only the pressure trigger is synthetic; context rendering, waiting and
            -- native cleanup use the real document and KOPT implementations.
            util.calcFreeMem = function() return 48 * 1024^2, 488 * 1024^2 end
            DocCache:memoryPressureCheck()
            util.calcFreeMem = original_mem
            T:check(DocCache.cache:used_size() <= before / 2, "pressure releases at least half the live bytes")
            T:check(waits > previous_waits, "pressure evicts the real reflow context through its waiting callback")
            T:eq(DocCache.cache:total_size(), limit, "original byte ceiling is restored")
            T:eq(DocCache.size, limit, "configured budget is unchanged")
        end
        local ok, err = pcall(function()
            T:run(function() hint(); pressure(); hint() end)
            -- Closing abandons the pending hint while DocCache retains its context.
            -- A later pressure check must remain safe after the native document closes.
            T:closeBook()
            T:run(pressure)
            T:run(function() DocCache:clear(); DocCache:clear() end)
        end)
        util.calcFreeMem = original_mem
        -- Also drain native threads on a failed assertion, before process teardown.
        T:run(function() DocCache:clear() end)
        KoptInterface.waitForContext = original_wait
        if not ok then error(err) end
        T:metric("context_wait_callbacks", waits, "count")
        T:metric("contexts_busy_before_wait", busy_waits, "count")
        T:metric("context_wait_total_ms", wait_ms, "ms")
        T:metric("context_wait_max_ms", max_wait_ms, "ms")
    end,
}
