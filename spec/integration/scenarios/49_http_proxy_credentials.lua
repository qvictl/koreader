return {
    name = "OPDS Basic authentication keeps credentials out of proxy request targets",
    timeout = 45,
    run = function(T)
        local ffi = require("ffi")
        local ffiutil = require("ffi/util")
        local http = require("socket.http")
        local json = require("rapidjson")
        local mime = require("mime")
        local util = require("util")
        local root = os.getenv("KO_HOME") .. "/proxy-fixture"
        util.makePath(root)
        local function read(name)
            local content = util.readFromFile(root .. "/" .. name .. ".json")
            return content and json.decode(content)
        end
        local pid = assert(ffiutil.runInSubProcess(function()
            ffi.C.execlp("python3", "python3", T.spec_dir .. "/mock_http_proxy.py", root,
                ffi.cast("char *", nil))
            ffi.C._exit(127)
        end))
        local saved_proxy = http.PROXY
        local ok, err = xpcall(function()
            local ready = T:waitUntil(function() return read("ready") end, 5, "local proxy fixture")
            local proxy = "http://127.0.0.1:" .. ready.port
            local username, password = "reader@example.invalid", "synthetic@:/?#password"
            local authorization = "Basic " .. mime.b64(username .. ":" .. password)
            local target = "http://catalog.invalid:25600/opds/catalog;v=2?q=book%20one"
            http.PROXY = proxy
            local Browser = require("opdsbrowser")
            -- Use the actual catalog browser and client, not a replacement HTTP function.
            local browser = setmetatable({
                root_catalog_username = username,
                root_catalog_password = password,
            }, { __index = Browser })
            local head, catalog
            T:run(function() head = browser:fetchFeed(target, true) end)
            T:eq(head["x-proxy-fixture"], "synthetic", "OPDS HEAD reaches the local proxy")
            T:run(function() catalog = browser:parseFeed(target) end)
            T:check(catalog and catalog.is_opds2, "OPDS GET parses the catalog through the proxy")
            T:eq(catalog.metadata.title, "Synthetic proxy catalog", "catalog payload survives authentication")
            for index, method in ipairs{ "HEAD", "GET" } do
                local request = read(index)
                T:eq(request.method, method, "real OPDS method is preserved")
                T:eq(request.target, target, "absolute proxy target contains no credentials")
                T:eq(request.host, "catalog.invalid:25600", "origin Host is preserved")
                T:eq(request.authorization, authorization, "reserved credentials remain in Basic header")
                T:eq(request.proxy_authorization, nil, "origin credentials are not proxy credentials")
            end

            local function request(options, expected_target, expected_host, expected_auth, expected_proxy_auth, index)
                local success, status
                T:run(function() success, status = http.request(options) end)
                T:eq(success, 1, "request completes over a real loopback socket")
                T:eq(status, 200, "proxy accepts the request target")
                local observed = read(index)
                T:eq(observed.target, expected_target, "request-target form is correct")
                T:eq(observed.host, expected_host, "Host header retains the destination")
                T:eq(observed.authorization, expected_auth, "origin authentication is retained")
                T:eq(observed.proxy_authorization, expected_proxy_auth, "proxy authentication remains separate")
            end
            http.PROXY = nil
            request({ url = target, proxy = proxy, user = username, password = password },
                target, "catalog.invalid:25600", authorization, nil, 3)
            request({ url = target, proxy = proxy:gsub("//", "//proxy-user:proxy-pass@"),
                user = username, password = password }, target, "catalog.invalid:25600", authorization,
                "Basic " .. mime.b64("proxy-user:proxy-pass"), 4)
            local direct = proxy .. "/opds/catalog;v=2?q=book%20one"
            request({ url = direct, user = username, password = password },
                "/opds/catalog;v=2?q=book%20one", "127.0.0.1:" .. ready.port, authorization, nil, 5)
            request({ url = "http://url-user:url-pass@catalog.invalid:25600/opds", proxy = proxy },
                "http://catalog.invalid:25600/opds", "catalog.invalid:25600",
                "Basic " .. mime.b64("url-user:url-pass"), nil, 6)
            request({ url = target, proxy = proxy }, target, "catalog.invalid:25600", nil, nil, 7)
            T:openBook(T:fixture("books/en.epub"))
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return T:reader():getCurrentPage() == 2 end, 5, "reading after proxy requests")
            T:closeBook()
        end, debug.traceback)
        http.PROXY = saved_proxy
        if not ffiutil.isSubProcessDone(pid) then
            ffiutil.terminateSubProcess(pid)
            T:waitUntil(function() return ffiutil.isSubProcessDone(pid) end, 5, "proxy fixture reaped")
        end
        if not ok then error(err, 0) end
    end,
}
