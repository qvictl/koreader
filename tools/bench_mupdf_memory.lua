-- Launched from a built KOReader runtime by bench_mupdf_memory.py.
require("setupkoenv")
local ffi = require("ffi")
local mupdf = require("ffi/mupdf")
local DrawContext = require("ffi/drawcontext")
local sha = require("ffi/sha2")
local time = require("ui/time")

mupdf.cache_size = assert(tonumber(arg[1])) * 1024 * 1024
local function memory()
    local file = assert(io.open("/proc/self/smaps_rollup"), "Linux smaps_rollup is required")
    local text = file:read("*a")
    file:close()
    return tonumber(text:match("\nRss:%s*(%d+)")), tonumber(text:match("\nPss:%s*(%d+)"))
end

local start_rss, start_pss = memory()
local document = mupdf.openDocument(assert(arg[2]))
local peak_rss, peak_pss, render_ms = 0, 0, 0
local hashes = {}
for pass = 1, 2 do
    for index = 1, document:getPages() do
        local page = document:openPage(pass == 1 and index or document:getPages() - index + 1)
        local context = DrawContext.new()
        local width, height = page:getSize(context)
        local start = time.now()
        local buffer = page:draw_new(context, width, height, 0, 0)
        render_ms = render_ms + time.to_ms(time.since(start))
        hashes[#hashes + 1] = sha.sha256(ffi.string(buffer.data, buffer.stride * buffer.h))
        buffer:free()
        page:close()
        collectgarbage()
        local rss, pss = memory()
        peak_rss, peak_pss = math.max(peak_rss, rss), math.max(peak_pss, pss)
    end
end
document:close()
document = nil -- luacheck: ignore 311 (release the context before measuring close RSS)
collectgarbage()
collectgarbage()
local close_rss, close_pss = memory()
print(require("rapidjson").encode{
    store_mib = tonumber(arg[1]),
    peak_rss_kib = peak_rss, peak_pss_kib = peak_pss,
    start_rss_kib = start_rss, start_pss_kib = start_pss,
    close_rss_kib = close_rss, close_pss_kib = close_pss,
    render_ms = render_ms, hashes = hashes,
})
