-- Real cover menu, saved settings and native RGB PNG/BMP decode/export.
-- No hardware capability, SDK, image writer or filesystem mocks.
return {
    name = "Color cover format stays selected after settings save and reader reopen",
    timeout = 60,
    settings = { language = "en", cover_image_enabled = false, cover_image_fallback = false },
    run = function(T)
        local BB = require("ffi/blitbuffer")
        local CanvasContext = require("document/canvascontext")
        local DocSettings = require("docsettings")
        local LuaSettings = require("luasettings")
        local RenderImage = require("ui/renderimage")
        local TouchMenu = require("ui/widget/touchmenu")
        local CheckMark = require("ui/widget/checkmark")
        local UIManager = require("ui/uimanager")
        local ffiUtil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local util = require("util")
        local _ = require("gettext")
        local base = os.getenv("KO_HOME") .. "/cover-format"
        local book, output = base .. "/synthetic.epub", base .. "/export.bmp"
        local keys = { "cover_image_path", "cover_image_cache_path", "cover_image_format",
            "cover_image_grayscale", "cover_image_enabled", "cover_image_fallback",
            "cover_image_background", "document_metadata_folder" }
        local saved, original_color = {}, CanvasContext.is_color_rendering_enabled
        for _, key in ipairs(keys) do saved[key] = G_reader_settings:readSetting(key) end
        local menu, plugin
        local color_title, gray_title = _("BMP file format (color)"), _("BMP file format (grayscale)")
        local function showMenu()
            T:run(function()
                menu = TouchMenu:new{
                    width = T.screen_w,
                    tab_item_table = { { icon = "appbar.settings",
                        plugin:menuEntryFormat(color_title, "bmp"),
                        plugin:menuEntryFormat(gray_title, "bmp", true),
                    } },
                }
                UIManager:show(menu)
            end)
            T:repaint()
        end
        local function item(title)
            return T:findWidget(menu, function(w) return w.item and w.item.text == title end)
        end
        local function checked(title)
            local mark = T:findWidget(item(title), function(w) return getmetatable(w) == CheckMark end)
            return mark.checked
        end
        local function closeMenu()
            if menu then
                T:run(function() UIManager:close(menu) end)
                menu = nil
            end
        end
        local function checkBMP(grayscale)
            local bytes = assert(util.readFromFile(output))
            T:eq(bytes:sub(1, 2), "BM", "actual export is a BMP file")
            local bpp = bytes:byte(29) + bytes:byte(30) * 256
            T:eq(bpp, grayscale and 8 or 24, "BMP pixel format matches the selected color mode")
            local image = assert(RenderImage:renderImageFile(output))
            local pixel = image:getPixel(0, 0)
            local r, g, b = pixel:getR(), pixel:getG(), pixel:getB()
            image:free()
            if grayscale then
                T:check(r == g and g == b, "native grayscale export contains grayscale pixels")
            else
                T:check(r > g and r > b, "native color export retains the synthetic red pixel")
            end
        end
        local function saveAndInspect(grayscale)
            T:run(function() assert(G_reader_settings:flush()) end)
            local persisted = LuaSettings:open(G_reader_settings.file)
            T:eq(persisted:readSetting("cover_image_format"), "bmp", "disk settings retain the BMP format")
            T:eq(persisted:readSetting("cover_image_grayscale"), grayscale,
                "disk settings retain the normalized boolean color mode")
        end
        local ok, err = pcall(function()
            assert(not lfs.attributes(base), "private fixture directory must be new")
            T:run(function()
                util.makePath(base .. "/cache")
                assert(not ffiUtil.copyFile(T:fixture("books/en.epub"), book))
                local sidecar = DocSettings:getSidecarDir(book, "doc")
                util.makePath(sidecar)
                local FIXTURE_WIDTH, FIXTURE_HEIGHT = 24, 36
                local image = BB.new(FIXTURE_WIDTH, FIXTURE_HEIGHT, BB.TYPE_BBRGB32)
                image:paintRectRGB32(0, 0, FIXTURE_WIDTH, FIXTURE_HEIGHT, BB.ColorRGB32(240, 20, 40, 255))
                local call_ok, write_ok, write_err = pcall(image.writePNG, image, sidecar .. "/cover.png")
                image:free()
                assert(call_ok, write_ok)
                assert(write_ok, write_err)
                G_reader_settings:saveSetting("document_metadata_folder", "doc")
                G_reader_settings:saveSetting("cover_image_path", output)
                G_reader_settings:saveSetting("cover_image_cache_path", base .. "/cache/")
                G_reader_settings:saveSetting("cover_image_background", "none")
                G_reader_settings:saveSetting("cover_image_format", "bmp")
                G_reader_settings:saveSetting("cover_image_grayscale", true)
                G_reader_settings:makeTrue("cover_image_enabled")
                CanvasContext:setColorRenderingEnabled(true)
            end)
            local ui = T:openBook(book)
            plugin = assert(ui.coverimage)
            checkBMP(true)
            showMenu()
            T:check(checked(gray_title) and not checked(color_title), "initial menu marks only grayscale")
            T:tapWidget(item(color_title), "select BMP color through the real menu")
            T:check(checked(color_title) and not checked(gray_title), "selection refreshes the rendered color checkmark")
            checkBMP(false)
            T:run(function() assert(G_reader_settings:flush()) end)
            closeMenu()
            T:closeBook()

            ui = T:openBook(book)
            plugin = assert(ui.coverimage)
            showMenu()
            T:check(checked(color_title) and not checked(gray_title), "color remains checked on the new reader instance")
            saveAndInspect(false)
            checkBMP(false)
            T:tapWidget(item(gray_title), "select grayscale after reopening")
            T:check(checked(gray_title) and not checked(color_title), "grayscale and color remain exclusive")
            checkBMP(true)
            saveAndInspect(true)
            closeMenu()
            T:closeBook()

            ui = T:openBook(book)
            plugin = assert(ui.coverimage)
            showMenu()
            T:check(checked(gray_title) and not checked(color_title), "grayscale also survives reopening")
            closeMenu()
            local page = ui:getCurrentPage()
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return ui:getCurrentPage() == page + 1 end, 5, "normal reading after cover changes")
            T:closeBook()
            ui = T:openBook(book)
            plugin = assert(ui.coverimage)
            T:eq(ui:getCurrentPage(), page + 1, "normal close/reopen retains reading progress")
        end)
        -- Restore settings/rendering even if closing the menu or reader fails.
        for _, key in ipairs(keys) do G_reader_settings:saveSetting(key, saved[key]) end
        CanvasContext:setColorRenderingEnabled(original_color)
        if plugin then plugin.cover, plugin.fallback = false, false end
        local menu_ok, menu_err = pcall(closeMenu)
        local close_ok, close_err = pcall(function() T:closeBook() end)
        local errors = {}
        local function describe(e) return tostring(type(e) == "table" and e.msg or e) end
        if not ok then errors[#errors + 1] = "scenario: " .. describe(err) end
        if not menu_ok then errors[#errors + 1] = "menu cleanup: " .. describe(menu_err) end
        if not close_ok then errors[#errors + 1] = "reader cleanup: " .. describe(close_err) end
        if #errors > 0 then error(table.concat(errors, "\n")) end
        -- Keep private inputs alive through any background-worker teardown.
        T:check(not T:reader() and T:topWidget() == T:fileManager(), "cleanup returns to the file manager")
    end,
}
