return {
    name = "OPDS catalog and downloads preserve literal percent credentials",
    timeout = 60,
    settings = { language = "en", cover_image_enabled = false, cover_image_fallback = false },
    run = function(T)
        local ffi = require("ffi")
        local ffiutil = require("ffi/util")
        local http = require("socket.http")
        local https = require("ssl.https")
        local json = require("rapidjson")
        local mime = require("mime")
        local NetworkMgr = require("ui/network/manager")
        local socketutil = require("socketutil")
        local UIManager = require("ui/uimanager")
        local util = require("util")
        local lfs = require("libs/libkoreader-lfs")
        local Browser = require("opdsbrowser")
        local root = os.getenv("KO_HOME") .. "/opds-literal-credentials"
        local username, password = "reader%40example", "fake%F5:%2520+é"
        local authorization = "Basic " .. mime.b64(username .. ":" .. password)
        local saved_proxy, saved_connected = http.PROXY, rawget(NetworkMgr, "runWhenConnected")
        local saved_block, saved_total = socketutil.block_timeout, socketutil.total_timeout
        local saved_http, saved_https = http.TIMEOUT, https.TIMEOUT
        local browser, pid
        local function read(name)
            local bytes = util.readFromFile(root .. "/" .. name .. ".json")
            return bytes and json.decode(bytes)
        end
        local function closeBrowser()
            if browser and UIManager:isWidgetShown(browser) then
                T:run(function() UIManager:close(browser) end)
            end
        end
        local ok, err = pcall(function()
            T:check(not lfs.attributes(root), "private loopback fixture directory is new")
            assert(util.makePath(root))
            pid = assert(ffiutil.runInSubProcess(function()
                ffi.C.execlp("python3", "python3", T.spec_dir .. "/mock_opds_credentials.py", root,
                    T:fixture("books/en.epub"), ffi.cast("char *", nil))
                ffi.C._exit(127)
            end))
            local ready = T:waitUntil(function() return read("ready") end, 5, "loopback credential origins")
            local origin = "http://127.0.0.1:" .. ready.port
            http.PROXY = nil
            -- Only the device connectivity prerequisite is synthetic. HTTP uses
            -- real loopback sockets against the private non-forwarding fixture.
            NetworkMgr.runWhenConnected = function(_, callback) callback() end
            T:run(function()
                browser = Browser:new{
                    title = "Synthetic OPDS", paths = {}, downloads = {}, pending_syncs = {}, settings = {},
                    servers = { { title = "Literal credential fixture", url = origin .. "/catalog",
                        username = username, password = password } },
                    _manager = {},
                }
                UIManager:show(browser)
            end)
            T:repaint()
            local catalog_item = T:findWidget(browser, function(w)
                return w.entry and w.entry.text == "Literal credential fixture"
            end)
            T:tapWidget(catalog_item, "select the catalog through its real menu")
            T:eq(browser.catalog_title, "Literal password catalog", "literal password authenticates the catalog")
            T:eq(browser.item_table[1].text, "Synthetic authenticated book - Unknown Author", "authenticated catalog entries render")
            T:eq(browser.root_catalog_password, password, "menu selection retains the literal saved field")
            T:eq(read(1).authorization, authorization, "GET wire Basic contains original percent bytes")
            T:eq(read(1).status, 200, "fixture accepts the unmodified credential")
            local headers
            T:run(function() headers = browser:fetchFeed(origin .. "/catalog", true) end)
            T:eq(headers["x-credentials-fixture"], "synthetic", "real OPDS HEAD authenticates")
            T:eq(read(2).method, "HEAD", "metadata request remains HEAD")
            T:eq(read(2).authorization, authorization, "HEAD wire Basic retains percent bytes")
            local target = root .. "/authenticated.epub"
            local downloaded, callback_path
            T:run(function()
                downloaded = browser:downloadFile(target, origin .. "/book.epub", username, password,
                    function(path) callback_path = path end)
            end)
            T:check(downloaded, "normal OPDS download uses the corrected client")
            T:eq(callback_path, target, "successful download callback receives the private path")
            T:check(util.readFromFile(target) == util.readFromFile(T:fixture("books/en.epub")), "downloaded EPUB bytes are intact")
            T:eq(read(3).authorization, authorization, "download wire Basic is literal")
            local same, foreign
            T:run(function() same = browser:parseFeed(origin .. "/same") end)
            T:eq(same.metadata.title, "Literal password catalog", "same-origin redirect remains authenticated")
            T:eq(read(4).authorization, authorization, "initial same-origin redirect request is authenticated")
            T:eq(read(5).authorization, authorization, "relative redirect carries origin credentials")
            T:run(function() foreign = browser:parseFeed(origin .. "/cross") end)
            T:eq(foreign.metadata.title, "Foreign catalog", "cross-origin redirect succeeds without origin credentials")
            T:eq(read(6).authorization, authorization, "initial cross-origin redirect request is authenticated")
            T:check(read(7).foreign, "redirect reaches the separately bound origin")
            T:eq(read(7).authorization, nil, "no generated authorization reaches the other port")
            T:eq(read(7).status, 200, "foreign fixture confirms no credentials leaked")
            closeBrowser()
            T:openBook(target)
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return T:reader():getCurrentPage() == 2 end, 5, "reading authenticated download")
            T:eq(T:reader():getCurrentPage(), 2, "downloaded book remains usable")
            T:closeBook()
        end)
        -- Restore network prerequisites/timeouts regardless of independent UI or
        -- worker cleanup failures. Private inputs remain available to readers.
        http.PROXY, NetworkMgr.runWhenConnected = saved_proxy, saved_connected
        socketutil.block_timeout, socketutil.total_timeout = saved_block, saved_total
        http.TIMEOUT, https.TIMEOUT = saved_http, saved_https
        local cleanup_errors = {}
        local function cleanup(callback)
            local clean, cleanup_err = pcall(callback)
            if not clean then cleanup_errors[#cleanup_errors + 1] = tostring(type(cleanup_err) == "table" and cleanup_err.msg or cleanup_err) end
        end
        cleanup(closeBrowser)
        cleanup(function() if T:reader() then T:closeBook() end end)
        cleanup(function()
            if pid and not ffiutil.isSubProcessDone(pid) then
                ffiutil.terminateSubProcess(pid)
                T:waitUntil(function() return ffiutil.isSubProcessDone(pid) end, 5, "credential fixture reaped")
            end
        end)
        if not ok then table.insert(cleanup_errors, 1, tostring(type(err) == "table" and err.msg or err)) end
        if #cleanup_errors > 0 then error(table.concat(cleanup_errors, "\n"), 0) end
    end,
}
