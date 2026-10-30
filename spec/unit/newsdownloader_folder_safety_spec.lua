describe("NewsDownloader download folder safety", function()
    local NewsDownloader, UIManager, DownloadMgr, Trapper, ConfirmBox, InfoMessage, LuaSettings
    local lfs, ffiutil, util, original_path
    local root, plugin, shown, picker, flushes, resets, undo

    local function replace(object, key, value)
        undo[#undo + 1] = { object, key, object[key] }
        object[key] = value
    end

    local function write(path, contents)
        local file = assert(io.open(path, "w"))
        file:write(contents or "inert fixture")
        file:close()
    end

    local function read(path)
        local file = assert(io.open(path, "r"))
        local contents = file:read("*a")
        file:close()
        return contents
    end

    local function choose(path)
        plugin:setCustomDownloadDirectory()
        picker.onConfirm(path)
    end

    local function deletion()
        return plugin:getSubMenuItems()[4].sub_item_table[3]
    end

    setup(function()
        require("commonrequire")
        original_path = package.path
        package.path = "plugins/newsdownloader.koplugin/?.lua;" .. package.path
        NewsDownloader = dofile("plugins/newsdownloader.koplugin/main.lua")
        UIManager = require("ui/uimanager")
        DownloadMgr = require("ui/downloadmgr")
        Trapper = require("ui/trapper")
        ConfirmBox = require("ui/widget/confirmbox")
        InfoMessage = require("ui/widget/infomessage")
        LuaSettings = require("luasettings")
        lfs = require("libs/libkoreader-lfs")
        ffiutil = require("ffi/util")
        util = require("util")
    end)

    teardown(function()
        package.path = original_path
    end)

    before_each(function()
        -- Only fresh, inert fixtures are ever passed to the real deletion method.
        root = os.tmpname()
        assert(os.remove(root))
        assert(lfs.mkdir(root))
        assert(lfs.mkdir(root .. "/old"))
        assert(lfs.mkdir(root .. "/candidate"))
        write(root .. "/old/feed_config.lua", "return {}")
        write(root .. "/outside.txt", "outside sentinel")
        shown, undo, flushes, resets = {}, {}, 0, 0
        plugin = setmetatable({
            initialized = true,
            download_dir = root .. "/old/",
            feed_config_path = root .. "/old/feed_config.lua",
            settings = LuaSettings:wrap{ custom_dl_dir = root .. "/old/" },
        }, { __index = NewsDownloader })
        replace(UIManager, "show", function(_, widget) shown[#shown + 1] = widget end)
        replace(ConfirmBox, "new", function(_, options)
            options.is_confirmation = true
            options.cancel_callback = function() end
            return options
        end)
        replace(InfoMessage, "new", function(_, options) return options end)
        replace(DownloadMgr, "chooseDir", function(self) picker = self end)
        replace(Trapper, "wrap", function(_, callback) callback() end)
        replace(Trapper, "reset", function() resets = resets + 1 end)
        replace(plugin.settings, "flush", function() flushes = flushes + 1 end)
        replace(plugin, "lazyInitialization", function(self)
            if not self.initialized then
                self.download_dir = self.settings:readSetting(self.config_key_custom_dl_dir)
                self.feed_config_path = self.download_dir .. self.feed_config_file
                self.initialized = true
            end
        end)
    end)

    after_each(function()
        for i = #undo, 1, -1 do
            local item = undo[i]
            item[1][item[2]] = item[3]
        end
        ffiutil.purgeDir(root)
    end)

    it("names the full deletion scope and leaves every fixture intact on cancel", function()
        write(root .. "/old/unrelated.txt")
        local item = deletion()
        assert.equals("Delete all items in download folder", item.text)
        replace(Trapper, "confirm", function(_, text, cancel, accept)
            assert.truthy(text:find(plugin.download_dir, 1, true))
            assert.truthy(text:find("ALL files and subfolders", 1, true))
            assert.truthy(text:find("not downloaded by this plugin", 1, true))
            assert.truthy(text:find("Only feed_config.lua will be kept", 1, true))
            assert.equals("Cancel", cancel)
            assert.equals("Delete", accept)
            return false
        end)
        item.callback()
        assert.equals("inert fixture", read(root .. "/old/unrelated.txt"))
        assert.equals("return {}", read(plugin.feed_config_path))
        assert.equals("outside sentinel", read(root .. "/outside.txt"))
        assert.equals(1, resets)
        assert.equals(0, #shown)
    end)

    it("retains the existing recursive deletion contract only after acceptance", function()
        write(root .. "/old/downloaded.epub")
        write(root .. "/old/unrelated.txt")
        assert(lfs.mkdir(root .. "/old/subfolder"))
        write(root .. "/old/subfolder/unrelated.txt")
        replace(Trapper, "confirm", function() return true end)
        deletion().callback()
        assert.is_nil(lfs.attributes(root .. "/old/downloaded.epub"))
        assert.is_nil(lfs.attributes(root .. "/old/unrelated.txt"))
        assert.is_nil(lfs.attributes(root .. "/old/subfolder"))
        assert.equals("return {}", read(plugin.feed_config_path))
        assert.equals("outside sentinel", read(root .. "/outside.txt"))
        assert.equals(1, resets)
        assert.equals("Download folder cleanup finished.", shown[1].text)
    end)

    it("reports an unreadable deletion folder without attempting removal", function()
        replace(lfs, "dir", function() error("injected unreadable directory") end)
        replace(os, "remove", function() error("must not remove anything") end)
        replace(ffiutil, "purgeDir", function() error("must not purge anything") end)
        plugin:removeNewsButKeepFeedConfig()
        assert.truthy(shown[1].text:find("No items were deleted", 1, true))
    end)

    it("applies an empty folder immediately and copies the feed configuration", function()
        choose(root .. "/candidate")
        assert.equals(root .. "/candidate/", plugin.download_dir)
        assert.equals(root .. "/candidate/", plugin.settings:readSetting("custom_dl_dir"))
        assert.equals("return {}", read(plugin.feed_config_path))
        assert.equals(1, flushes)
        assert.equals(0, #shown)
    end)

    it("does not change settings or copy configuration when a nonempty folder is cancelled", function()
        write(root .. "/candidate/unrelated.txt")
        choose(root .. "/candidate")
        local dialog = shown[1]
        assert.is_true(dialog.is_confirmation)
        assert.equals("Use folder", dialog.ok_text)
        assert.truthy(dialog.text:find(root .. "/candidate", 1, true))
        assert.truthy(dialog.text:find("ALL files and subfolders", 1, true))
        assert.truthy(dialog.text:find("Only feed_config.lua will be kept", 1, true))
        dialog.cancel_callback()
        assert.equals(root .. "/old/", plugin.settings:readSetting("custom_dl_dir"))
        assert.equals(root .. "/old/", plugin.download_dir)
        assert.is_nil(lfs.attributes(root .. "/candidate/feed_config.lua"))
        assert.equals("inert fixture", read(root .. "/candidate/unrelated.txt"))
        assert.equals(0, flushes)
    end)

    it("accepts a nonempty folder without deleting any of its existing items", function()
        assert(lfs.mkdir(root .. "/candidate/subfolder"))
        write(root .. "/candidate/subfolder/unrelated.txt")
        choose(root .. "/candidate")
        assert.equals(root .. "/old/", plugin.download_dir)
        shown[1].ok_callback()
        assert.equals(root .. "/candidate/", plugin.download_dir)
        assert.equals("return {}", read(plugin.feed_config_path))
        assert.equals("inert fixture", read(root .. "/candidate/subfolder/unrelated.txt"))
        assert.equals(1, flushes)
    end)

    it("conservatively warns even for a folder containing only feed configuration", function()
        write(root .. "/candidate/feed_config.lua", "return {'existing'}")
        choose(root .. "/candidate")
        assert.is_true(shown[1].is_confirmation)
        assert.equals("return {'existing'}", read(root .. "/candidate/feed_config.lua"))
        assert.equals(0, flushes)
    end)

    it("rejects a missing folder rather than treating it as empty", function()
        choose(root .. "/missing")
        assert.is_nil(shown[1].is_confirmation)
        assert.truthy(shown[1].text:find("Cannot read folder", 1, true))
        assert.equals(root .. "/old/", plugin.download_dir)
        assert.equals(0, flushes)
    end)

    it("rejects a regular file rather than treating it as a folder", function()
        choose(root .. "/outside.txt")
        assert.truthy(shown[1].text:find("Cannot read folder", 1, true))
        assert.equals(root .. "/old/", plugin.download_dir)
        assert.equals("outside sentinel", read(root .. "/outside.txt"))
        assert.equals(0, flushes)
    end)

    it("fails closed when directory iteration raises an error", function()
        replace(util, "isEmptyDir", function() error("injected iterator failure") end)
        choose(root .. "/candidate")
        assert.truthy(shown[1].text:find("Cannot read folder", 1, true))
        assert.equals(root .. "/old/", plugin.settings:readSetting("custom_dl_dir"))
        assert.is_nil(lfs.attributes(root .. "/candidate/feed_config.lua"))
        assert.equals(0, flushes)
    end)
end)
