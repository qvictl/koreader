--[[--
Helpers to keep memory usage in check.

@{releaseMemory} runs a full Lua GC and then asks the C allocator to give its free
pages back to the system. It's meant to be called at points where a lot of memory
was just freed (document closed, document opened and rendered, suspend).

@module memorytuning
--]]

local ffi = require("ffi")
local logger = require("logger")

local MemoryTuning = {}

-- glibc's malloc_trim(): returns free memory at the top of the heap *and* free pages in the
-- middle of the heap (via MADV_DONTNEED) to the system. Without it, memory freed by crengine
-- when closing a document mostly stays in the process (RSS doesn't go down) because the
-- main heap can only shrink from its top.
local malloc_trim
if jit.os == "Linux" then
    -- (cdef only fails if it was already declared elsewhere, which is fine)
    pcall(ffi.cdef, "int malloc_trim(size_t pad);")
    -- Resolving the symbol fails on libcs without malloc_trim (e.g., older Android bionic)
    local ok, fn = pcall(function() return ffi.C.malloc_trim end)
    if ok then
        malloc_trim = fn
    end
end

local function getRssKb()
    local f = io.open("/proc/self/statm", "r")
    if not f then return end
    local _, resident = f:read("*l"):match("^(%d+)%s+(%d+)")
    f:close()
    -- statm is in pages
    return resident and tonumber(resident) * 4
end

--- Runs a full Lua GC, then gives free C heap memory back to the system.
-- @string reason only used for logging
function MemoryTuning:releaseMemory(reason)
    if G_reader_settings and G_reader_settings:isFalse("release_memory_on_close") then
        return
    end
    local rss_before = getRssKb()
    -- Twice, so that objects with finalizers (e.g., cdata with ffi.gc'ed C buffers) are really freed.
    collectgarbage()
    collectgarbage()
    if malloc_trim then
        malloc_trim(0)
    end
    if rss_before then
        logger.dbg("MemoryTuning: released memory on", reason, "RSS (kB):", rss_before, "->", getRssKb())
    end
end

return MemoryTuning
