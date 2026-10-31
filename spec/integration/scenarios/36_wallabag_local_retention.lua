-- Real local files/sidecars and plugin paths, with only the remote API simulated.
return {
    name = "Wallabag status uploads preserve local articles and annotations unless removal is enabled",
    timeout = 60,
    run = function(T)
        local DocSettings = require("docsettings")
        local ffiUtil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local UIManager = require("ui/uimanager")
        local util = require("util")
        local plugin = T:fileManager().wallabag
        T:check(plugin ~= nil, "Wallabag is attached to the real file manager")
        local base = os.getenv("KO_HOME") .. "/wallabag-retention"
        local path = base .. "/[w-id_42] article.epub"
        local saved = {}
        local fields = {
            "archive_finished", "archive_read", "archive_abandoned", "send_review_as_tags",
            "sync_remote_archive", "use_local_archive", "archive_directory", "auto_archive",
            "delete_instead", "getBearerToken", "callAPI", "access_token", "uploadQueue", "getArticleList",
        }
        for _, field in ipairs(fields) do saved[field] = rawget(plugin, field) end
        local function read(file)
            local f = assert(io.open(file, "rb"))
            local data = f:read("*a")
            f:close()
            return data
        end
        local article_bytes, sidecar, sidecar_bytes, remote_count = nil, nil, nil, 0
        local function dismissSummary()
            T:run(function()
                local widget = T:topWidget()
                if widget and widget.text then UIManager:close(widget) end
            end)
        end
        local ok, err = pcall(function()
            T:run(function()
                util.makePath(base)
                assert(not ffiUtil.copyFile(T:fixture("books/en.epub"), path))
                local settings = DocSettings:open(path)
                settings:saveSetting("summary", { status = "complete" })
                settings:saveSetting("annotations", {{ text = "Synthetic highlight", note = "Keep this note" }})
                settings:flush()
                sidecar = assert(DocSettings:findSidecarFile(path))
                article_bytes, sidecar_bytes = read(path), read(sidecar)
                plugin.archive_finished = true
                plugin.archive_read, plugin.archive_abandoned, plugin.send_review_as_tags = false, false, false
                plugin.sync_remote_archive, plugin.use_local_archive = false, false
                plugin.auto_archive, plugin.delete_instead = true, false
                plugin.archive_directory = base .. "/archive"
                plugin.getBearerToken = function() return true end
                plugin.access_token = "synthetic-not-sent"
                plugin.callAPI = function(_, method, endpoint)
                    T:eq(method, "PATCH", "finished status is uploaded through the real archive path")
                    T:eq(endpoint, "/api/entries/42.json", "only the synthetic article is updated remotely")
                    remote_count = remote_count + 1
                    return true
                end
                plugin.uploadQueue = function() return 0 end
                plugin.getArticleList = function() return {} end
            end)
            local articles = { ["42"] = path }
            T:run(function()
                local count_remote, count_local = plugin:uploadStatuses(articles)
                T:eq(count_remote, 1, "manual status upload succeeds remotely")
                T:eq(count_local, 0, "manual upload does not remove the local article")
            end)
            T:eq(articles["42"], path, "retained file remains in the local inventory")
            T:check(read(path) == article_bytes, "manual upload preserves every EPUB byte")
            T:check(read(sidecar) == sidecar_bytes, "manual upload preserves notes and highlights byte-for-byte")
            T:run(function() plugin:downloadArticles(articles) end)
            dismissSummary()
            T:eq(remote_count, 2, "automatic upload runs during a subsequent download")
            T:check(read(path) == article_bytes, "automatic upload preserves the EPUB")
            T:check(read(sidecar) == sidecar_bytes, "automatic upload preserves the sidecar")
            T:run(function()
                plugin.use_local_archive = true
                plugin:uploadStatuses(articles)
            end)
            T:eq(lfs.attributes(plugin.archive_directory), nil, "archive preference alone does not move files")
            T:check(read(sidecar) == sidecar_bytes, "archive preference alone preserves annotations")
            T:run(function()
                plugin.sync_remote_archive = true
                local count_remote, count_local = plugin:uploadStatuses(articles)
                T:eq(count_remote, 1, "explicit archival uploads the status")
                T:eq(count_local, 1, "explicit local removal moves the article to the archive")
            end)
            local archive_path = plugin.archive_directory .. "/[w-id_42] article.epub"
            T:eq(lfs.attributes(path), nil, "explicit archival removes only the original path")
            T:eq(articles["42"], nil, "successful archival removes the old inventory entry")
            T:check(read(archive_path) == article_bytes, "archive contains the original EPUB bytes")
            local archived_settings = DocSettings:open(archive_path)
            T:eq(archived_settings:readSetting("annotations")[1].note, "Keep this note", "explicit archival carries the annotation sidecar")
        end)
        for _, field in ipairs(fields) do plugin[field] = saved[field] end
        ffiUtil.purgeDir(base)
        if not ok then error(err, 0) end
    end,
}
