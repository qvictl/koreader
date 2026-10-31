describe("Wallabag nullable article metadata", function()
    local Wallabag, JSON, UIManager, lfs, root, owns_root
    local plugin, calls, written, articles, failure_id
    local restores = {}
    local function override(obj, key, value)
        local old = rawget(obj, key)
        obj[key] = value
        restores[#restores + 1] = function() obj[key] = old end
    end

    setup(function()
        require("commonrequire")
        JSON = require("json")
        UIManager = require("ui/uimanager")
        lfs = require("libs/libkoreader-lfs")
        Wallabag = dofile("plugins/wallabag.koplugin/main.lua")
        root = require("datastorage"):getDataDir() .. "/wallabag-null-metadata-spec"
        assert.is_nil(lfs.attributes(root))
        assert.is_true(require("util").makePath(root))
        owns_root = true
    end)

    before_each(function()
        calls, written, articles, failure_id = {}, {}, {}, nil
        for _, key in ipairs({ "show", "close", "forceRePaint" }) do override(UIManager, key, function() end) end
        plugin = Wallabag:extend{
            directory = root, access_token = "synthetic", download_original_document = false,
            auto_archive = false, sync_remote_archive = false, is_dateparser_available = false,
            getBearerToken = function() return true end,
            uploadQueue = function() return 0 end,
            getArticleList = function() return articles end,
            callAPI = function(_, method, url, headers, body, path)
                assert.are.equal("GET", method)
                assert.is_string(url)
                assert.is_nil(headers)
                assert.is_nil(body)
                assert.are.equal(root .. "/", path:sub(1, #root + 1))
                calls[#calls + 1] = { url = url, path = path }
                if failure_id and url:find("/" .. failure_id .. "/", 1, true) then return nil end
                local file = assert(io.open(path, "wb"))
                written[path] = true
                assert(file:write("Synthetic exported entry: " .. url))
                assert(file:close())
                return path
            end,
        }
    end)

    after_each(function()
        for i = #restores, 1, -1 do restores[i]() end
        restores = {}
        for path in pairs(written) do assert(os.remove(path)) end
    end)

    teardown(function()
        if owns_root then assert(lfs.rmdir(root)) end
    end)

    it("exports a real JSON-null title without invoking its sentinel", function()
        local article = JSON.decode([[{"id":42,"title":null,"url":"https://example.invalid/a","mimetype":"text/html"}]])
        assert.are.equal("function", type(article.title))
        local title = article.title
        local path = plugin:downloadArticle(article)
        assert.are.equal(root .. "/[w-id_42] .epub", path)
        assert.are.equal("/api/entries/42/export.epub", calls[1].url)
        assert.are.equal(title, article.title)
    end)

    it("exports an absent title with its unique entry ID", function()
        local path = plugin:downloadArticle(JSON.decode([[{"id":43,"url":"https://example.invalid/b"}]]))
        assert.are.equal(root .. "/[w-id_43] .epub", path)
    end)

    it("leaves an ordinary title and EPUB endpoint unchanged", function()
        local path = plugin:downloadArticle(JSON.decode([[{"id":44,"title":"Report.pdf","url":"https://example.invalid/report.pdf"}]]))
        assert.are.equal(root .. "/[w-id_44] Report.pdf.epub", path)
        assert.are.equal("/api/entries/44/export.epub", calls[1].url)
    end)

    for _, mime in ipairs({ "null", '"application/pdf"' }) do
        it("uses EPUB for a missing original URL, mimetype=" .. mime, function()
            plugin.download_original_document = true
            local article = JSON.decode('{"id":45,"title":"Report","url":null,"mimetype":' .. mime .. '}')
            assert.are.equal(root .. "/[w-id_45] Report.epub", plugin:downloadArticle(article))
            assert.are.equal("/api/entries/45/export.epub", calls[1].url)
        end)
    end

    it("keeps original-document preference for a valid URL", function()
        plugin.download_original_document = true
        local article = JSON.decode([[{"id":46,"title":"Report.pdf","url":"https://example.invalid/report.pdf","mimetype":null}]])
        assert.are.equal(root .. "/[w-id_46] Report.pdf", plugin:downloadArticle(article))
        assert.are.equal(article.url, calls[1].url)
    end)

    it("uses the ID filename for a null title with a valid original URL", function()
        plugin.download_original_document = true
        local article = JSON.decode([[{"id":47,"title":null,"url":"https://example.invalid/report.pdf","mimetype":null}]])
        assert.are.equal(root .. "/[w-id_47] .pdf", plugin:downloadArticle(article))
        assert.are.equal(article.url, calls[1].url)
    end)

    for _, mime in ipairs({ "null", '"application/pdf"' }) do
        it("uses EPUB for an absent original URL, mimetype=" .. mime, function()
            plugin.download_original_document = true
            local article = JSON.decode('{"id":48,"title":"Report","mimetype":' .. mime .. '}')
            assert.are.equal(root .. "/[w-id_48] Report.epub", plugin:downloadArticle(article))
            assert.are.equal("/api/entries/48/export.epub", calls[1].url)
        end)
    end

    it("keeps MIME-based original selection for a valid URL", function()
        plugin.download_original_document = true
        local article = JSON.decode([[{"id":49,"title":"Report","url":"https://example.invalid/document","mimetype":"application/pdf; charset=utf-8"}]])
        assert.are.equal(root .. "/[w-id_49] Report.pdf", plugin:downloadArticle(article))
        assert.are.equal(article.url, calls[1].url)
    end)

    it("keeps EPUB selection for ordinary HTML even with original preference", function()
        plugin.download_original_document = true
        local article = JSON.decode([[{"id":50,"title":"Page","url":"https://example.invalid/page.html","mimetype":"text/html"}]])
        assert.are.equal(root .. "/[w-id_50] Page.epub", plugin:downloadArticle(article))
        assert.are.equal("/api/entries/50/export.epub", calls[1].url)
    end)

    it("finishes the batch and skips already saved files on the next sync", function()
        articles = JSON.decode([[ [
            {"id":101,"title":"First"}, {"id":102,"title":null}, {"id":103,"title":"Last"}
        ] ]])
        local local_articles = {}
        assert.is_true(plugin:downloadArticles(local_articles))
        assert.are.equal(3, #calls)
        for _, id in ipairs({ "101", "102", "103" }) do assert.truthy(lfs.attributes(local_articles[id])) end
        local file = assert(io.open(local_articles["101"], "rb"))
        local first = file:read("*a")
        assert(file:close())
        assert.is_true(plugin:downloadArticles(local_articles))
        assert.are.equal(3, #calls)
        file = assert(io.open(local_articles["101"], "rb"))
        assert.are.equal(first, file:read("*a"))
        assert(file:close())
    end)

    it("continues after a failed export and retries only that entry", function()
        articles = JSON.decode([[ [
            {"id":101,"title":"First"}, {"id":102,"title":null}, {"id":103,"title":"Last"}
        ] ]])
        failure_id = "102"
        local local_articles = {}
        assert.is_true(plugin:downloadArticles(local_articles))
        assert.are.equal(3, #calls)
        assert.truthy(lfs.attributes(local_articles["101"]))
        assert.is_nil(local_articles["102"])
        assert.truthy(lfs.attributes(local_articles["103"]))
        failure_id = nil
        assert.is_true(plugin:downloadArticles(local_articles))
        assert.are.equal(4, #calls)
        assert.are.equal("/api/entries/102/export.epub", calls[4].url)
        assert.truthy(lfs.attributes(local_articles["102"]))
    end)
end)
