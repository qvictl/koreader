return {
    name = "Rename a folder with nested shortcuts through FileManager",
    timeout = 60,
    run = function(T)
        local util = require("util")
        local lfs = require("libs/libkoreader-lfs")
        local base = os.getenv("KO_HOME") .. "/shortcut-rename"
        local source, destination = base .. "/original", base .. "/renamed"
        local fm = T:fileManager()
        local saved_shortcuts = fm.folder_shortcuts.folder_shortcuts
        local ok, err = pcall(function()
            T:run(function()
                util.makePath(source)
                fm.folder_shortcuts.folder_shortcuts = {}
                for i = 1, 80 do
                    local folder = source .. "/sub" .. i
                    util.makePath(folder)
                    fm.folder_shortcuts.folder_shortcuts[folder] = { text = "Synthetic " .. i }
                end
                fm:showRenameFileDialog(source, false)
            end)
            local dialog = T:topWidget()
            T:check(dialog and dialog.setInputText, "folder rename input is shown")
            T:run(function() dialog:setInputText("renamed") end)
            T:repaint()
            local rename_text = require("gettext")("Rename")
            local button = T:findWidget(dialog, function(widget)
                return widget.text == rename_text and widget.callback
            end)
            T:check(button and button.dimen, "folder rename button is painted")
            T:tapWidget(button, "rename folder")
            T:waitUntil(function() return lfs.attributes(destination, "mode") == "directory" end, 5, "folder is renamed")
            T:eq(lfs.attributes(source), nil, "old folder path no longer exists")
            T:run(function()
                local all_moved = true
                for i = 1, 80 do
                    local target = fm.folder_shortcuts.folder_shortcuts[destination .. "/sub" .. i]
                    if not target or target.text ~= "Synthetic " .. i
                            or fm.folder_shortcuts.folder_shortcuts[source .. "/sub" .. i]
                            or lfs.attributes(destination .. "/sub" .. i, "mode") ~= "directory" then
                        all_moved = false
                    end
                end
                T:check(all_moved, "renaming updates every nested shortcut and preserves every subfolder")
            end)
        end)
        fm.folder_shortcuts.folder_shortcuts = saved_shortcuts
        require("ffi/util").purgeDir(base)
        if not ok then error(err, 0) end
    end,
}
