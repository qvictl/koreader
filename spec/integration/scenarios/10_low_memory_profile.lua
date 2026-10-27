-- Low memory profile (forced on): smaller crengine storage factor and DocCache, memory
-- released (Lua GC + malloc_trim) after a book is opened and closed, and open/close cycles
-- of both books keep working.
local cre_init_args
return {
    name = "Low memory profile",
    timeout = 180,
    settings = {
        low_memory_profile = true,
    },
    setup = function()
        -- crengine's cache is initialized when the first book is opened: record its parameters.
        local cre = require("libs/libkoreader-cre")
        local orig = cre.initCache
        cre.initCache = function(...)
            cre_init_args = { ... }
            return orig(...)
        end
    end,
    run = function(T)
        local MemoryTuning = require("memorytuning")
        T:check(MemoryTuning:isLowMemory(), "low memory profile is active")
        T:eq(MemoryTuning:pick(40, 4), 4, "MemoryTuning:pick gives the low memory value")
        local DocCache = require("document/doccache")
        T:metric("doccache_size_mb", (DocCache.size or 0) / 1024 / 1024, "MiB")
        T:check(DocCache.size == nil or DocCache.size <= 32 * 1024 * 1024, "DocCache is capped to 32 MiB")

        local release = T:spy(MemoryTuning, "releaseMemory")
        local function reasons()
            local t = {}
            for _, args in ipairs(release.args) do t[args[2]] = (t[args[2]] or 0) + 1 end
            return t
        end
        for cycle = 1, 3 do
            for _, book in ipairs({ "books/zh.epub", "books/en.epub" }) do
                local ui = T:openBook(T:fixture(book))
                T:run(function() ui:handleEvent(require("ui/event"):new("GotoPage", 1)) end)
                for _ = 1, 5 do
                    T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
                end
                T:waitUntil(function() return ui:getCurrentPage() == 6 end, 10, "5 page turns (" .. book .. ")")
                -- "document ready" release is scheduled 2 s after the reader is ready.
                T:wait(2.2)
                T:closeBook()
                T:wait(0.3)
            end
            T:log("cycle", cycle, "RSS", T:rssKb(), "kB")
        end
        T:check(cre_init_args, "crengine cache was initialized")
        T:eq(cre_init_args and cre_init_args[4], 4, "crengine storage size factor")
        local r = reasons()
        T:log("releaseMemory calls:", require("dump")(r))
        T:eq(r["document close"], 6, "memory released after each close")
        T:eq(r["document ready"], 6, "memory released after each open")
        release.restore()
    end,
}
