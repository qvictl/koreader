return {
    name = "News feeds follow HTTP 308 redirects without parsing redirect bodies",
    timeout = 45,
    run = function(T)
        local ffi = require("ffi")
        local ffiutil = require("ffi/util")
        local http = require("socket.http")
        local https = require("ssl.https")
        local json = require("rapidjson")
        local lfs = require("libs/libkoreader-lfs")
        local socketutil = require("socketutil")
        local util = require("util")
        local plugin = T:fileManager().newsdownloader
        T:check(plugin, "the real news downloader is attached")
        T:run(function() plugin:lazyInitialization() end)
        local root = os.getenv("KO_HOME") .. "/http-308-fixture"
        assert(lfs.mkdir(root))
        assert(lfs.mkdir(root .. "/downloads"))
        local function read(name)
            local content = util.readFromFile(root .. "/" .. name .. ".json")
            return content and json.decode(content)
        end
        local saved_dir, saved_proxy = plugin.download_dir, http.PROXY
        local saved_block, saved_total = socketutil.block_timeout, socketutil.total_timeout
        local saved_http, saved_https = http.TIMEOUT, https.TIMEOUT
        local pid
        local ok, err = xpcall(function()
            pid = assert(ffiutil.runInSubProcess(function()
                ffi.C.execlp("python3", "python3", T.spec_dir .. "/mock_http_308.py", root,
                    ffi.cast("char *", nil))
                ffi.C._exit(127)
            end))
            local ready = T:waitUntil(function() return read("ready") end, 5, "local redirect fixture")
            local origin = "http://127.0.0.1:" .. ready.port
            http.PROXY = nil
            plugin.download_dir = root .. "/downloads/"
            local unsupported = {}
            T:run(function()
                plugin:processFeedSource(origin .. "/start", nil, nil, 1, unsupported,
                    false, false, "Synthetic redirect feed")
            end)
            T:eq(#unsupported, 0, "308 response body is not mistaken for feed XML")
            local requests = read("requests")
            T:eq(#requests, 3, "the feed follows exactly two redirects")
            T:eq(requests[1], "/start", "initial URL is used")
            T:eq(requests[2], "/permanent", "308 relative location is followed")
            T:eq(requests[3], "/feed", "301 after 308 reaches the real RSS feed")
            local target = plugin.download_dir .. "Permanent redirect fixture/Redirect article.epub"
            T:eq(lfs.attributes(target, "mode"), "file", "real news pipeline creates the article EPUB")
            T:openBook(target)
            T:check(T:reader().document:getPageCount() > 1, "redirected article is readable and paginated")
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return T:reader():getCurrentPage() == 2 end, 5, "reading downloaded news")
            T:closeBook()

            local result, code
            T:run(function() result, code = http.request{ url = origin .. "/start", redirect = false } end)
            T:eq(result, 1, "disabled redirect returns normally")
            T:eq(code, 308, "caller can still opt out of redirects")
            T:eq(#read("requests"), 4, "disabled redirect does not contact its location")
            T:run(function() result, code = http.request{ url = origin .. "/loop", maxredirects = 2 } end)
            T:eq(result, 1, "bounded redirect loop returns normally")
            T:eq(code, 308, "redirect limit is retained")
            T:eq(#read("requests"), 7, "loop stops at the configured redirect count")
        end, debug.traceback)
        plugin.download_dir, http.PROXY = saved_dir, saved_proxy
        socketutil.block_timeout, socketutil.total_timeout = saved_block, saved_total
        http.TIMEOUT, https.TIMEOUT = saved_http, saved_https
        local cleanup_errors = {}
        local function cleanup(fn)
            local clean, message = pcall(fn)
            if not clean then
                cleanup_errors[#cleanup_errors + 1] = tostring(type(message) == "table" and message.msg or message)
            end
        end
        cleanup(function() if T:reader() then T:closeBook() end end)
        cleanup(function()
            if pid and not ffiutil.isSubProcessDone(pid) then
                ffiutil.terminateSubProcess(pid)
                T:waitUntil(function() return ffiutil.isSubProcessDone(pid) end, 5, "redirect fixture reaped")
            end
        end)
        if not ok then table.insert(cleanup_errors, 1, tostring(type(err) == "table" and err.msg or err)) end
        if #cleanup_errors > 0 then error(table.concat(cleanup_errors, "\n"), 0) end
    end,
}
