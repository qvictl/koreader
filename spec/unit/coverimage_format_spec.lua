-- Settings are serialized and reopened; no actual book, SDK or host command is used.
describe("Cover image format persistence", function()
    local CoverImage, LuaSettings, DataStorage, lfs
    local original_settings, settings_path, cache_path, exports, owns_fixture

    setup(function()
        require("commonrequire")
        CoverImage = dofile("plugins/coverimage.koplugin/main.lua")
        LuaSettings = require("luasettings")
        DataStorage = require("datastorage")
        lfs = require("libs/libkoreader-lfs")
    end)

    before_each(function()
        original_settings = _G.G_reader_settings
        owns_fixture = false
        settings_path = DataStorage:getDataDir() .. "/cover-format-spec.lua"
        cache_path = DataStorage:getDataDir() .. "/cover-format-spec-cache/"
        assert(not lfs.attributes(settings_path), "private settings fixture already exists")
        assert(not lfs.attributes(cache_path), "private cache fixture already exists")
        assert(not lfs.attributes(settings_path .. ".old"), "private backup fixture already exists")
        owns_fixture = true
        _G.G_reader_settings = LuaSettings:open(settings_path)
        _G.G_reader_settings:saveSetting("cover_image_cache_path", cache_path)
        _G.G_reader_settings:saveSetting("cover_image_path", cache_path .. "export.bmp")
        exports = 0
    end)

    after_each(function()
        _G.G_reader_settings = original_settings
        if owns_fixture then
            os.remove(settings_path)
            os.remove(settings_path .. ".old")
            lfs.rmdir(cache_path)
        end
    end)

    local function newPlugin()
        return CoverImage:new{
            ui = { menu = { registerToMainMenu = function() end } },
            createCoverImage = function() exports = exports + 1 end,
        }
    end
    local function reload()
        assert(_G.G_reader_settings:flush())
        _G.G_reader_settings = LuaSettings:open(settings_path)
        return newPlugin()
    end

    for _, format in ipairs({ "jpg", "png", "bmp" }) do
        it("keeps the selected " .. format .. " color entry checked after settings reload", function()
            local plugin = newPlugin()
            local entry = plugin:menuEntryFormat("synthetic color", format)
            entry.callback()
            assert.is_true(entry.checked_func())
            local reopened = reload()
            assert.equals(format, reopened.cover_image_format)
            assert.is_false(reopened.cover_image_grayscale)
            assert.is_true(reopened:menuEntryFormat("synthetic color", format).checked_func())
            assert.is_false(reopened:menuEntryFormat("synthetic grayscale", "bmp", true).checked_func())
            assert.equals(0, exports)
        end)
    end

    it("recognizes existing color settings when the grayscale key is absent", function()
        _G.G_reader_settings:saveSetting("cover_image_format", "bmp")
        local plugin = reload()
        assert.is_nil(_G.G_reader_settings:readSetting("cover_image_grayscale"))
        assert.is_true(plugin:menuEntryFormat("synthetic color", "bmp").checked_func())
    end)

    it("retains grayscale and makes the color and grayscale selections exclusive", function()
        local plugin = newPlugin()
        plugin:menuEntryFormat("synthetic grayscale", "bmp", true).callback()
        plugin = reload()
        assert.is_true(plugin:menuEntryFormat("synthetic grayscale", "bmp", true).checked_func())
        assert.is_false(plugin:menuEntryFormat("synthetic color", "bmp").checked_func())
        plugin:menuEntryFormat("synthetic color", "bmp").callback()
        plugin = reload()
        assert.is_true(plugin:menuEntryFormat("synthetic color", "bmp").checked_func())
        assert.is_false(plugin:menuEntryFormat("synthetic grayscale", "bmp", true).checked_func())
    end)

    it("does not regenerate an enabled cover when reselecting the same persisted color format", function()
        _G.G_reader_settings:saveSetting("cover_image_format", "bmp")
        _G.G_reader_settings:saveSetting("cover_image_enabled", true)
        local plugin = reload()
        assert.is_true(plugin.cover)
        assert.is_truthy(plugin:coverEnabled())
        plugin:menuEntryFormat("synthetic color", "bmp").callback()
        assert.equals(0, exports)
        plugin:menuEntryFormat("synthetic grayscale", "bmp", true).callback()
        assert.equals(1, exports)
        assert.is_true(plugin.cover_image_grayscale)
    end)
end)
