describe("OPDS literal catalog credentials", function()
    local Client, CookieJar, http, mime, socketutil
    local request_impl, saved_proxy, responses, observed, requests

    setup(function()
        require("commonrequire")
        Client = dofile("plugins/opds.koplugin/opdsclient.lua")
        CookieJar = dofile("plugins/opds.koplugin/cookiejar.lua")
        http = require("socket.http")
        mime = require("mime")
        socketutil = require("socketutil")
    end)
    before_each(function()
        request_impl, saved_proxy = http.request, http.PROXY
        http.PROXY = nil
        responses, observed, requests = {}, {}, {}
        -- Keep the real HTTP parser/header writer, replacing only its transport.
        -- Every connection is synthetic: no DNS, socket, TLS or live credentials.
        http.request = function(request)
            requests[#requests + 1] = request
            local response = table.remove(responses, 1) or { 200, {} }
            if response.error then return nil, response.error end
            local raw = "HTTP/1.1 " .. response[1] .. " Synthetic\r\nContent-Length: 0\r\n"
            for key, value in pairs(response[2]) do raw = raw .. key .. ": " .. value .. "\r\n" end
            raw = raw .. "\r\n"
            local entry = { chunks = {}, closes = 0 }
            observed[#observed + 1] = entry
            request.create = function()
                return {
                    settimeout = function() return 1 end,
                    connect = function(_, host, port)
                        entry.destination = { host, tonumber(port) }
                        return 1
                    end,
                    send = function(_, chunk)
                        entry.chunks[#entry.chunks + 1] = chunk
                        return #chunk
                    end,
                    receive = function(_, pattern, prefix)
                        local chunk
                        if type(pattern) == "number" then
                            chunk, raw = raw:sub(1, pattern), raw:sub(pattern + 1)
                        else
                            local last = assert(raw:find("\r\n", 1, true))
                            chunk, raw = raw:sub(1, last - 1), raw:sub(last + 2)
                        end
                        return (prefix or "") .. chunk
                    end,
                    close = function() entry.closes = entry.closes + 1; return 1 end,
                }
            end
            local result, code, headers, status = request_impl(request)
            entry.message = table.concat(entry.chunks)
            entry.target = entry.message:match("^(.-)\r\n")
            entry.headers = {}
            for key, value in entry.message:gmatch("\r\n([^:\r\n]+): ([^\r\n]*)") do
                entry.headers[key:lower()] = value
            end
            assert.are.equal(1, entry.closes)
            return result, code, headers, status
        end
    end)
    after_each(function()
        http.request, http.PROXY = request_impl, saved_proxy
    end)

    local function basic(user, password)
        return "Basic " .. mime.b64(user .. ":" .. password)
    end
    local function request(options)
        local client = Client:new{ cookie_jar = CookieJar:new() }
        options = options or {}
        options.url = options.url or "http://catalog.example.invalid/opds"
        local code = client:request(options)
        assert.are.equal(200, code)
        return observed[#observed], client
    end

    for _, password in ipairs{ "fake%F5", "%40%3A", "%25%00%0d%0a", "%2520", "fake:@/?#[] &+", "中文:é+%F5", "100%", "%xY", "" } do
        for _, method in ipairs{ "GET", "HEAD" } do
            it("preserves literal password " .. password .. " for " .. method, function()
                local input = { username = "reader%40example", password = password, method = method }
                local result = request(input)
                assert.are.equal(basic(input.username, password), result.headers.authorization)
                assert.are.equal(method .. " /opds HTTP/1.1", result.target)
                assert.are.equal(password, input.password)
                assert.is_nil(input.headers)
            end)
        end
    end
    it("preserves an empty username and password", function()
        local result = request{ username = "", password = "" }
        assert.are.equal(basic("", ""), result.headers.authorization)
    end)
    it("retains partial explicit fields combined with URL credentials", function()
        local result = request{
            url = "http://url-user:fake%40pass@catalog.example.invalid/opds", username = "reader",
        }
        assert.are.equal(basic("reader", "fake@pass"), result.headers.authorization)
    end)
    it("keeps raw credentials out of proxy targets and proxy authentication", function()
        http.PROXY = "http://proxy-user:proxy-pass@proxy.example.invalid:8080"
        local result = request{ username = "reader", password = "fake%F5" }
        assert.are.equal(basic("reader", "fake%F5"), result.headers.authorization)
        assert.are.equal(basic("proxy-user", "proxy-pass"), result.headers["proxy-authorization"])
        assert.are.equal("GET http://catalog.example.invalid:80/opds HTTP/1.1", result.target)
        assert.are.same({ "proxy.example.invalid", 8080 }, result.destination)
    end)
    for _, name in ipairs{ "Authorization", "authorization", "aUtHoRiZaTiOn" } do
        it("preserves explicit " .. name .. " priority", function()
            local headers = { [name] = "Bearer synthetic-token", ["X-Fixture"] = "unchanged" }
            local result = request{ username = "reader", password = "fake%F5", headers = headers }
            assert.are.equal("Bearer synthetic-token", result.headers.authorization)
            assert.are.same({ [name] = "Bearer synthetic-token", ["X-Fixture"] = "unchanged" }, headers)
        end)
    end
    it("preserves existing URL-embedded percent decoding", function()
        local result = request{ url = "http://url-user:fake%40%3Apass@catalog.example.invalid/opds" }
        assert.are.equal(basic("url-user", "fake@:pass"), result.headers.authorization)
    end)
    it("does not invent credentials when either or both explicit fields are absent", function()
        for _, options in ipairs{ {}, { username = "reader" }, { password = "fake%F5" } } do
            assert.is_nil(request(options).headers.authorization)
        end
    end)
    it("retains literal credentials on a relative same-origin redirect", function()
        responses = { { 302, { Location = "/next" } } }
        request{ username = "reader", password = "fake%F5" }
        assert.are.equal(2, #observed)
        for _, item in ipairs(observed) do
            assert.are.equal(basic("reader", "fake%F5"), item.headers.authorization)
        end
        assert.are.equal("GET /next HTTP/1.1", observed[2].target)
    end)
    for _, target in ipairs{ "http://other.example.invalid/book", "http://catalog.example.invalid:8080/book", "https://catalog.example.invalid/book" } do
        it("does not forward generated credentials to " .. target, function()
            responses = { { 302, { Location = target } } }
            request{ username = "reader", password = "fake%F5" }
            assert.are.equal(2, #observed)
            assert.are.equal(basic("reader", "fake%F5"), observed[1].headers.authorization)
            assert.is_nil(observed[2].headers.authorization)
            assert.is_nil(requests[2].user)
            assert.is_nil(requests[2].password)
        end)
    end
    it("does not follow an HTTPS downgrade", function()
        responses = { { 302, { Location = "http://catalog.example.invalid/book" } } }
        local client = Client:new{ cookie_jar = CookieJar:new() }
        assert.are.equal(302, client:request{
            url = "https://catalog.example.invalid/opds", username = "reader", password = "fake%F5",
        })
        assert.are.equal(1, #observed)
        assert.are.equal(basic("reader", "fake%F5"), observed[1].headers.authorization)
    end)
    it("rebuilds origin credentials after a cross-origin redirect returns", function()
        responses = { { 302, { Location = "http://other.example.invalid/book" } },
            { 302, { Location = "http://catalog.example.invalid/return" } } }
        request{ username = "reader", password = "fake%F5" }
        assert.are.equal(3, #observed)
        assert.is_nil(observed[2].headers.authorization)
        assert.are.equal(basic("reader", "fake%F5"), observed[3].headers.authorization)
    end)
    it("retains the same header when retrying an interrupted TLS handshake", function()
        responses = { { error = socketutil.SSL_HANDSHAKE_CODE } }
        request{ url = "https://catalog.example.invalid/opds", username = "reader", password = "fake%F5" }
        assert.are.equal(2, #requests)
        assert.are.equal(basic("reader", "fake%F5"), observed[1].headers.authorization)
    end)
end)
