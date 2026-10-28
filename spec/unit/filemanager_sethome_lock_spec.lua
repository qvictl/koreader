describe("FileManager setHome with a locked home folder", function()
    local FileManager, FileManagerShortcuts, UIManager, util
    local orig_home, orig_lock, orig_shortcuts

    setup(function()
        require("commonrequire")
        disable_plugins()
        FileManager = require("apps/filemanager/filemanager")
        FileManagerShortcuts = require("apps/filemanager/filemanagershortcuts")
        UIManager = require("ui/uimanager")
        util = require("util")
        orig_home = G_reader_settings:readSetting("home_dir")
        orig_lock = G_reader_settings:readSetting("lock_home_folder")
        -- (shared table, updated by setHome())
        orig_shortcuts = util.tableDeepCopy(FileManagerShortcuts.folder_shortcuts)
    end)

    teardown(function()
        G_reader_settings:saveSetting("home_dir", orig_home)
        G_reader_settings:saveSetting("lock_home_folder", orig_lock)
        local shortcuts = FileManagerShortcuts.folder_shortcuts
        for folder in pairs(shortcuts) do shortcuts[folder] = nil end
        for folder, shortcut in pairs(orig_shortcuts) do shortcuts[folder] = shortcut end
    end)

    it("refreshes the list after the new home is saved", function()
        G_reader_settings:saveSetting("home_dir", "/old/home")
        G_reader_settings:makeTrue("lock_home_folder")

        -- home_dir as seen by each list refresh ("../" is hidden only when it is the current path)
        local refreshed_with = {}
        local fm = setmetatable({
            file_chooser = {
                path = "/new/home",
                refreshPath = function()
                    table.insert(refreshed_with, G_reader_settings:readSetting("home_dir"))
                end,
            },
            updateTitleBarPath = function() end,
        }, { __index = FileManager })
        fm.folder_shortcuts = FileManagerShortcuts:new{ ui = fm }

        local shown = {}
        stub(UIManager, "show", function(_, w) table.insert(shown, w) end)
        fm:setHome()
        UIManager.show:revert()
        assert.are.equal(1, #shown)
        shown[1].ok_callback() -- "Set as HOME"

        assert.are.equal("/new/home", G_reader_settings:readSetting("home_dir"))
        assert.is_true(#refreshed_with > 0)
        assert.are.equal("/new/home", refreshed_with[#refreshed_with])
    end)
end)
