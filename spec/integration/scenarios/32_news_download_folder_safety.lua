-- Exercise the real confirmation widgets, but never point deletion at user data.
return {
    name = "News download folder warnings preserve data until explicit confirmation",
    timeout = 60,
    settings = { language = "en" },
    run = function(T)
        local BD = require("ui/bidi")
        local DataStorage = require("datastorage")
        local DownloadMgr = require("ui/downloadmgr")
        local UIManager = require("ui/uimanager")
        local ffiUtil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local _ = require("gettext")
        local fm = T:fileManager()
        local plugin = fm.newsdownloader
        T:check(plugin, "the news downloader plugin is attached")
        T:run(function() plugin:lazyInitialization() end)
        local old_dir = plugin.download_dir
        local old_custom = plugin.settings:readSetting(plugin.config_key_custom_dl_dir)
        local old_choose = DownloadMgr.chooseDir
        -- KO_HOME is fresh for each scenario; refuse to reuse any existing folder.
        local root = DataStorage:getSettingsDir() .. "/news-folder-safety"
        assert(lfs.mkdir(root))
        local selected = root .. "/selected"
        local function write(path, text)
            local f = assert(io.open(path, "w")); assert(f:write(text)); assert(f:close())
        end
        local function read(path)
            local f = assert(io.open(path, "r")); local text = f:read("*all"); f:close(); return text
        end
        local function choose(path)
            -- Only the path chooser is bypassed. Warning and delete dialogs are real.
            DownloadMgr.chooseDir = function(self) self.onConfirm(path) end
            T:run(function() plugin:setCustomDownloadDirectory() end)
            DownloadMgr.chooseDir = old_choose
        end
        local function confirmation(label, path)
            local dialog = T:waitUntil(function()
                local widget = T:topWidget()
                return widget and widget.ok_text == _(label) and widget
            end, 5, label .. " confirmation")
            T:repaint()
            T:check(dialog.dimen and dialog.dimen.w > 0, label .. " confirmation paints")
            T:check(dialog.text:find(BD.dirpath(path or selected), 1, true),
                "confirmation identifies the selected folder")
            return dialog
        end
        local function press(dialog, label)
            local button = T:findWidget(dialog, function(w)
                return w.text == _(label) and type(w.callback) == "function"
            end)
            T:tapWidget(button, label)
        end
        local function deleteEntry()
            local delete_label = _("Delete all items in download folder")
            for _, menu in ipairs(plugin:getSubMenuItems()) do
                for _, item in ipairs(menu.sub_item_table or {}) do
                    if item.text == delete_label then return item end
                end
            end
            error("truthfully named delete entry not found")
        end
        local ok, err = xpcall(function()
            assert(lfs.mkdir(selected))
            assert(lfs.mkdir(selected .. "/nested"))
            write(root .. "/outside.txt", "outside sentinel")
            write(selected .. "/unrelated.txt", "unrelated sentinel")
            write(selected .. "/nested/keep.txt", "nested sentinel")
            write(selected .. "/feed_config.lua", "-- destination sentinel\nreturn {}\n")
            local source_config = read(plugin.feed_config_path)

            choose(selected)
            local warning = confirmation("Use folder")
            T:check(warning.text:find("If it already contains feed_config.lua", 1, true)
                and warning.text:find("will be overwritten with the current feed configuration", 1, true),
                "selection warns that an existing feed configuration will be replaced")
            T:eq(plugin.download_dir, old_dir, "nonempty selection is not applied before confirmation")
            T:eq(plugin.settings:readSetting(plugin.config_key_custom_dl_dir), old_custom,
                "pending warning does not persist the selection")
            press(warning, "Cancel")
            T:eq(plugin.download_dir, old_dir, "cancel keeps the original download folder")
            T:eq(read(selected .. "/feed_config.lua"), "-- destination sentinel\nreturn {}\n",
                "cancel does not overwrite the destination configuration")
            T:eq(read(selected .. "/unrelated.txt"), "unrelated sentinel", "cancel preserves unrelated files")

            choose(selected)
            warning = confirmation("Use folder")
            press(warning, "Use folder")
            T:eq(plugin.download_dir, selected .. "/", "accept applies the selected folder")
            T:eq(plugin.settings:readSetting(plugin.config_key_custom_dl_dir), selected .. "/",
                "accept persists the selected folder")
            T:eq(read(selected .. "/feed_config.lua"), source_config, "accept preserves the feed-copy contract")
            T:eq(read(selected .. "/nested/keep.txt"), "nested sentinel", "choosing a folder never deletes its content")

            choose(selected)
            warning = confirmation("Use folder")
            press(warning, "Use folder")
            T:eq(read(selected .. "/feed_config.lua"), source_config,
                "selecting the current folder cannot truncate its feed configuration")

            T:run(function() deleteEntry().callback() end)
            local deletion = confirmation("Delete", plugin.download_dir)
            T:check(deletion.text:find("feed_config.lua", 1, true), "deletion names the configuration exception")
            T:check(deletion.text:find("ALL", 1, true), "deletion explicitly warns about all contents")
            press(deletion, "Cancel")
            T:eq(read(selected .. "/unrelated.txt"), "unrelated sentinel", "delete cancellation preserves files")
            T:eq(read(selected .. "/nested/keep.txt"), "nested sentinel", "delete cancellation preserves subfolders")

            T:run(function() deleteEntry().callback() end)
            deletion = confirmation("Delete", plugin.download_dir)
            press(deletion, "Delete")
            T:check(not lfs.attributes(selected .. "/unrelated.txt"), "confirmed deletion removes unrelated fixture file")
            T:check(not lfs.attributes(selected .. "/nested"), "confirmed deletion removes fixture subfolders")
            T:eq(read(selected .. "/feed_config.lua"), source_config, "confirmed deletion retains feed configuration")
            T:eq(read(root .. "/outside.txt"), "outside sentinel", "confirmed deletion cannot touch the outside sentinel")
            T:run(function() UIManager:close(T:topWidget()) end)

            choose(root .. "/missing")
            T:repaint()
            local top = T:topWidget()
            T:check(top and top ~= fm and top.ok_text == nil
                and type(top.text) == "string"
                and top.text:find(BD.dirpath(root .. "/missing"), 1, true)
                and top.text:find("Cannot read folder", 1, true),
                "unreadable selection shows the folder-read error for the selected path")
            T:eq(plugin.download_dir, selected .. "/", "unreadable selection fails closed")
            T:eq(plugin.settings:readSetting(plugin.config_key_custom_dl_dir), selected .. "/",
                "unreadable selection does not persist settings")
        end, debug.traceback)
        DownloadMgr.chooseDir = old_choose
        local cleanup_ok, cleanup_err = pcall(function()
            T:run(function()
                while T:topWidget() and T:topWidget() ~= fm do
                    local widget = T:topWidget()
                    -- Resume any pending Trapper confirmation with cancellation,
                    -- so failed assertions do not leave standby inhibited.
                    if widget.cancel_callback then widget.cancel_callback() end
                    if T:topWidget() == widget then UIManager:close(widget) end
                end
                if old_custom == nil then
                    plugin.settings:delSetting(plugin.config_key_custom_dl_dir)
                else
                    plugin.settings:saveSetting(plugin.config_key_custom_dl_dir, old_custom)
                end
                plugin.settings:flush()
                plugin.initialized = false
                plugin:lazyInitialization()
            end)
            ffiUtil.purgeDir(root)
        end)
        if not ok then error(err, 0) end
        if not cleanup_ok then error(cleanup_err, 0) end
    end,
}
