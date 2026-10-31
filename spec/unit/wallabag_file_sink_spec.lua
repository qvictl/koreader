describe("Wallabag file sink lifecycle", function()
    local Wallabag, http, socketutil, UIManager, util, lfs
    local root, owns_root, target, plugin, response, restores, handles, counts, fault
    local function override(obj, key, value)
        local old = rawget(obj, key)
        obj[key] = value
        restores[#restores + 1] = function() obj[key] = old end
    end
    setup(function()
        require("commonrequire")
        Wallabag = dofile("plugins/wallabag.koplugin/main.lua")
        http = require("socket.http")
        socketutil = require("socketutil")
        UIManager = require("ui/uimanager")
        util = require("util")
        lfs = require("libs/libkoreader-lfs")
        root = require("datastorage"):getDataDir() .. "/wallabag-file-sink-spec"
        assert.is_nil(lfs.attributes(root))
        assert(util.makePath(root))
        owns_root = true
        target = root .. "/entry.epub"
    end)
    before_each(function()
        restores, handles, counts, fault = {}, {}, { close = 0, reset = 0, requests = 0 }, {}
        response = { status = 200, chunks = { "FIRST", "SECOND" } }
        local saved_block, saved_total = socketutil.block_timeout, socketutil.total_timeout
        local https = require("ssl.https")
        local saved_http, saved_https = http.TIMEOUT, https.TIMEOUT
        restores[#restores + 1] = function()
            socketutil.block_timeout, socketutil.total_timeout = saved_block, saved_total
            http.TIMEOUT, https.TIMEOUT = saved_http, saved_https
        end
        local reset = socketutil.reset_timeout
        override(socketutil, "reset_timeout", function(self)
            counts.reset = counts.reset + 1
            return reset(self)
        end)
        override(UIManager, "show", function() end)
        local open = io.open
        override(io, "open", function(path, mode)
            if path ~= target or mode ~= "w" then return open(path, mode) end
            if fault.open then return nil, "synthetic open error" end
            local handle = assert(open(path, mode))
            local state = { handle = handle }
            handles[#handles + 1] = state
            return {
                write = function(_, chunk)
                    if fault.write_throw then error(fault.write_throw) end
                    if fault.write then
                        assert(handle:write(chunk:sub(1, 2)))
                        assert(handle:flush())
                        return nil, "synthetic write ENOSPC"
                    end
                    return handle:write(chunk)
                end,
                close = function()
                    counts.close = counts.close + 1
                    assert(handle:close())
                    state.closed = true
                    if fault.close_throw then error(fault.close_throw) end
                    if fault.close then return nil, "synthetic close EIO" end
                    return true
                end,
            }
        end)
        override(http, "request", function(request)
            counts.requests = counts.requests + 1
            assert.equals("https://wallabag.example.invalid/api/entries/401/export.epub", request.url)
            assert.equals("Bearer synthetic", request.headers.Authorization)
            if response.before_body then return nil, "synthetic connection failure" end
            if response.no_body then return 1, response.status, {}, "no response body" end
            for _, chunk in ipairs(response.chunks) do
                local ok, err = request.sink(chunk)
                if not ok then return nil, err end
            end
            if response.throw then error(response.throw) end
            if response.partial then return nil, "synthetic interrupted transfer" end
            local ok, err = request.sink(nil)
            if not ok then return nil, err end
            return 1, response.status, {}, "synthetic response"
        end)
        plugin = Wallabag:extend{ server_url = "https://wallabag.example.invalid", access_token = "synthetic" }
    end)
    after_each(function()
        for i = #restores, 1, -1 do restores[i]() end
        -- These are only handles and files created by this fixture.
        for _, state in ipairs(handles) do if not state.closed then state.handle:close() end end
        if lfs.attributes(target) then assert(os.remove(target)) end
    end)
    teardown(function() if owns_root then assert(lfs.rmdir(root)) end end)

    local function download()
        return plugin:callAPI("GET", "/api/entries/401/export.epub", nil, nil, target)
    end
    local function closedOnce()
        assert.equals(1, counts.close)
        assert.is_true(handles[1].closed)
        assert.equals(1, counts.reset)
    end
    it("preserves successful bytes, return path and one close", function()
        local ok, path = download()
        assert.is_true(ok)
        assert.equals(target, path)
        closedOnce()
        assert.equals("FIRSTSECOND", util.readFromFile(target))
    end)
    it("accepts an empty successful export", function()
        response.chunks = {}
        assert.is_true(download())
        closedOnce()
        assert.equals("", util.readFromFile(target))
    end)
    for _, status in ipairs({204, 503}) do
        it("keeps HTTP " .. status .. " failure and partial-file removal", function()
            response.status = status
            response.no_body = status == 204
            local ok, err, code = download()
            assert.is_false(ok)
            assert.equals("http_error", err)
            assert.equals(status, code)
            closedOnce()
            assert.is_nil(lfs.attributes(target))
        end)
    end
    for _, stage in ipairs({"before_body", "partial"}) do
        it("closes an interrupted transfer " .. stage .. " before removal", function()
            response[stage] = true
            local ok, err = download()
            assert.is_false(ok)
            assert.equals("network_error", err)
            closedOnce()
            assert.is_nil(lfs.attributes(target))
        end)
    end
    it("closes and removes a partially written failed sink", function()
        fault.write = true
        assert.is_false(download())
        closedOnce()
        assert.is_nil(lfs.attributes(target))
    end)
    for _, kind in ipairs({"close", "close_throw"}) do
        it("does not report success after " .. kind .. " failure", function()
            fault[kind] = "synthetic close exception"
            local ok, err = download()
            assert.is_false(ok)
            assert.equals("file_error", err)
            closedOnce()
            assert.is_nil(lfs.attributes(target))
        end)
    end
    it("preserves an HTTP error when closing also fails", function()
        fault.close, response.status = true, 503
        local ok, err, code = download()
        assert.is_false(ok)
        assert.equals("http_error", err)
        assert.equals(503, code)
        closedOnce()
        assert.is_nil(lfs.attributes(target))
    end)
    it("returns the existing failure shape when opening fails", function()
        fault.open = true
        local ok, err = download()
        assert.is_false(ok)
        assert.equals("network_error", err)
        assert.equals(0, counts.close)
        assert.equals(0, counts.reset)
        assert.equals(0, counts.requests)
        assert.is_nil(lfs.attributes(target))
    end)
    it("does not delete a file it failed to open", function()
        local file = assert(io.open(target, "wb"))
        assert(file:write("PREEXISTING BYTES"))
        assert(file:close())
        fault.open = true
        assert.is_false(download())
        assert.equals(0, counts.requests)
        assert.equals(0, counts.close)
        assert.equals("PREEXISTING BYTES", util.readFromFile(target))
    end)
    it("preserves the request exception when close also throws", function()
        local sentinel = {}
        response.throw, fault.close_throw = sentinel, "synthetic close exception"
        local ok, err = pcall(download)
        assert.is_false(ok)
        assert.equals(sentinel, err)
        closedOnce()
    end)
    for _, kind in ipairs({"request", "write"}) do
        it("closes and resets timeouts before rethrowing a " .. kind .. " exception", function()
            local sentinel = {}
            if kind == "request" then response.throw = sentinel else fault.write_throw = sentinel end
            local ok, err = pcall(download)
            assert.is_false(ok)
            assert.equals(sentinel, err)
            closedOnce()
            -- Unexpected exceptions previously left partial files; do not change that contract here.
            assert.is_not_nil(lfs.attributes(target))
        end)
    end
    it("can retry after a failed write with a fresh closed handle", function()
        fault.write = true
        assert.is_false(download())
        assert.equals(1, counts.close)
        fault.write = false
        assert.is_true(download())
        assert.equals(2, counts.close)
        assert.is_true(handles[1].closed)
        assert.is_true(handles[2].closed)
        assert.equals("FIRSTSECOND", util.readFromFile(target))
    end)
    it("leaves JSON requests and their result unchanged", function()
        response.chunks = { '{"id":401}' }
        local ok, value = plugin:callAPI("GET", "/api/entries/401/export.epub")
        assert.is_true(ok)
        assert.same({id = 401}, value)
        assert.equals(0, counts.close)
        assert.equals(1, counts.reset)
    end)
end)
