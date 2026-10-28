describe("FileManagerShortcuts:updateItemsByPath with special paths", function()
    local FileManagerShortcuts
    local saved = {}
    local keys = { "home_dir", "download_dir", "screenshot_dir", "wikipedia_save_dir" }

    setup(function()
        require("commonrequire")
        FileManagerShortcuts = require("apps/filemanager/filemanagershortcuts")
        for _, k in ipairs(keys) do
            saved[k] = G_reader_settings:readSetting(k)
        end
    end)

    teardown(function()
        for _, k in ipairs(keys) do
            G_reader_settings:saveSetting(k, saved[k])
        end
    end)

    local shortcuts
    before_each(function()
        for _, k in ipairs(keys) do
            G_reader_settings:saveSetting(k, "/elsewhere/" .. k)
        end
        shortcuts = FileManagerShortcuts:new{ ui = {} }
        shortcuts.folder_shortcuts = {
            ["/mnt/my-books"] = { text = "books", time = 1 },
            ["/mnt/my-books/sci-fi"] = { text = "scifi", time = 2 },
            ["/mnt/my-books10"] = { text = "other", time = 3 },
            ["/mnt/[new]"] = { text = "brackets", time = 4 },
        }
    end)

    local function names()
        local t = {}
        for folder, shortcut in pairs(shortcuts.folder_shortcuts) do
            t[folder] = shortcut.text
        end
        return t
    end

    it("renames a folder whose path contains '-'", function()
        G_reader_settings:saveSetting("home_dir", "/mnt/my-books/sci-fi")
        shortcuts:updateItemsByPath("/mnt/my-books", "/mnt/ebooks")
        assert.are.same({
            ["/mnt/ebooks"] = "books",
            ["/mnt/ebooks/sci-fi"] = "scifi",
            ["/mnt/my-books10"] = "other", -- not inside the renamed folder
            ["/mnt/[new]"] = "brackets",
        }, names())
        assert.are.equal("/mnt/ebooks/sci-fi", G_reader_settings:readSetting("home_dir"))
        assert.are.equal("/elsewhere/download_dir", G_reader_settings:readSetting("download_dir"))
    end)

    it("handles '[' and '%' in paths", function()
        assert.has_no.errors(function()
            shortcuts:updateItemsByPath("/mnt/[new]", "/mnt/100% new")
        end)
        assert.are.equal("brackets", names()["/mnt/100% new"])
        assert.is_nil(names()["/mnt/[new]"])
    end)

    it("removes the shortcuts of a deleted folder and its subfolders only", function()
        G_reader_settings:saveSetting("download_dir", "/mnt/my-books")
        shortcuts:updateItemsByPath(nil, "/mnt/my-books")
        assert.are.same({
            ["/mnt/my-books10"] = "other",
            ["/mnt/[new]"] = "brackets",
        }, names())
        assert.is_nil(G_reader_settings:readSetting("download_dir"))
        assert.are.equal("/elsewhere/home_dir", G_reader_settings:readSetting("home_dir"))
    end)
end)
