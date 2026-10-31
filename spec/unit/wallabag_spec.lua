describe("Wallabag status upload local retention", function()
    local Wallabag, DocSettings, UIManager
    local plugin, articles, remote, deleted, archived
    local path = "/synthetic/[w-id_42] article.epub"

    setup(function()
        require("commonrequire")
        DocSettings = require("docsettings")
        UIManager = require("ui/uimanager")
        Wallabag = dofile("plugins/wallabag.koplugin/main.lua")
    end)

    before_each(function()
        remote, deleted, archived = 0, 0, 0
        articles = { ["42"] = path }
        plugin = Wallabag:extend{
            archive_finished = true,
            sync_remote_archive = false,
            use_local_archive = false,
            getBearerToken = function() return true end,
            shouldUploadStatus = function() return true end,
            archiveArticle = function(_, entry)
                assert.equals(path, entry)
                remote = remote + 1
                return true
            end,
            deleteLocalArticle = function(_, entry)
                assert.equals(path, entry)
                deleted = deleted + 1
                return true
            end,
            archiveLocalArticle = function(_, entry)
                assert.equals(path, entry)
                archived = archived + 1
                return true
            end,
        }
        stub(DocSettings, "hasSidecarFile", function() return true end)
        stub(UIManager, "show")
        stub(UIManager, "close")
        stub(UIManager, "forceRePaint")
    end)

    after_each(function()
        DocSettings.hasSidecarFile:revert()
        UIManager.show:revert()
        UIManager.close:revert()
        UIManager.forceRePaint:revert()
    end)

    for _, archive in ipairs({ false, true }) do
        it("keeps the article and inventory with local removal disabled, archive=" .. tostring(archive), function()
            plugin.use_local_archive = archive
            local count_remote, count_local = plugin:uploadStatuses(articles)
            assert.equals(1, remote)
            assert.equals(1, count_remote)
            assert.equals(0, count_local)
            assert.equals(0, deleted)
            assert.equals(0, archived)
            assert.equals(path, articles["42"])
        end)

        it("honors explicitly enabled local removal, archive=" .. tostring(archive), function()
            plugin.sync_remote_archive = true
            plugin.use_local_archive = archive
            local count_remote, count_local = plugin:uploadStatuses(articles)
            assert.equals(1, count_remote)
            assert.equals(1, count_local)
            assert.equals(archive and 0 or 1, deleted)
            assert.equals(archive and 1 or 0, archived)
            assert.is_nil(articles["42"])
        end)

        it("retains the inventory if local removal fails, archive=" .. tostring(archive), function()
            plugin.sync_remote_archive = true
            plugin.use_local_archive = archive
            plugin.deleteLocalArticle = function() return false end
            plugin.archiveLocalArticle = function() return false end
            local count_remote, count_local = plugin:uploadStatuses(articles)
            assert.equals(1, count_remote)
            assert.equals(0, count_local)
            assert.equals(path, articles["42"])
        end)
    end

    it("keeps local articles when an older configuration has no removal setting", function()
        plugin.sync_remote_archive = nil
        local count_remote, count_local = plugin:uploadStatuses(articles, false)
        assert.equals(1, count_remote)
        assert.equals(0, count_local)
        assert.equals(0, deleted)
        assert.equals(path, articles["42"])
    end)

    it("does not remove local articles when the remote update fails", function()
        plugin.sync_remote_archive = true
        plugin.archiveArticle = function() return false end
        local count_remote, count_local = plugin:uploadStatuses(articles)
        assert.equals(0, count_remote)
        assert.equals(0, count_local)
        assert.equals(0, deleted)
        assert.equals(0, archived)
        assert.equals(path, articles["42"])
    end)

    it("keeps unfinished articles without uploading them", function()
        plugin.sync_remote_archive = true
        plugin.shouldUploadStatus = function() return false end
        local count_remote, count_local = plugin:uploadStatuses(articles)
        assert.equals(0, remote)
        assert.equals(0, count_remote)
        assert.equals(0, count_local)
        assert.equals(0, deleted)
        assert.equals(path, articles["42"])
    end)
end)
