describe("Cover list narrow cached rows", function()
    -- Deliberate native pixel fixtures: DPI scaling would hide the narrow-width regression.
    local NARROW_WIDTH, WIDE_WIDTH, ROW_HEIGHT = 228, 1000, 200
    local BD, BB, BookInfoManager, Geom, ImageWidget, ListMenuItem, FileManagerBookInfo
    local saved_path, saved_modules, saved
    local rows, buffers, owners, released, variant, settings

    setup(function()
        require("commonrequire")
        saved_path = package.path
        saved_modules = { bookinfomanager = package.loaded.bookinfomanager, listmenu = package.loaded.listmenu }
        package.path = "plugins/coverbrowser.koplugin/?.lua;" .. package.path
        BD = require("ui/bidi")
        BB = require("ffi/blitbuffer")
        BookInfoManager = require("bookinfomanager")
        Geom = require("ui/geometry")
        ImageWidget = require("ui/widget/imagewidget")
        FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
        local ListMenu = require("listmenu")
        for i = 1, 20 do
            local name, value = debug.getupvalue(ListMenu._updateItemsBuildUI, i)
            if name == "ListMenuItem" then ListMenuItem = value break end
        end
        assert.is_truthy(ListMenuItem)
    end)

    teardown(function()
        package.path = saved_path
        package.loaded.bookinfomanager, package.loaded.listmenu = saved_modules.bookinfomanager, saved_modules.listmenu
    end)

    before_each(function()
        saved = { info = BookInfoManager.getBookInfo, setting = BookInfoManager.getSetting,
            image_free = ImageWidget.free, rtl = BD.mirroredUILayout }
        rows, buffers, owners, released, settings = {}, {}, {}, {}, {}
        variant = "real"
        BookInfoManager.getSetting = function(_, key) return settings[key] end
        BookInfoManager.getBookInfo = function(_, _, with_cover)
            if variant == "uncached" then return end
            local info = { has_meta = "Y", title = "Synthetic title", authors = "Synthetic Author",
                description = "Synthetic description", cover_fetched = true, has_cover = variant == "real",
                ignore_cover = variant == "ignored", pages = 123 }
            if with_cover and info.has_cover then
                local bb = BB.new(150, 200, BB.TYPE_BB8)
                bb:fill(BB.COLOR_GRAY)
                buffers[#buffers + 1] = bb
                owners[bb] = #buffers
                info.cover_bb, info.cover_w, info.cover_h = bb, 150, 200
            end
            return info
        end
        ImageWidget.free = function(image)
            local id = owners[image.image]
            if id then released[id] = (released[id] or 0) + 1 end
            return saved.image_free(image)
        end
    end)

    after_each(function()
        for _, row in ipairs(rows) do row:free() end
        for _, bb in ipairs(buffers) do if bb:getAllocated() == 1 then bb:free() end end
        BookInfoManager.getBookInfo, BookInfoManager.getSetting = saved.info, saved.setting
        ImageWidget.free, BD.mirroredUILayout = saved.image_free, saved.rtl
    end)

    local function row(width, cover, entry, mandatory)
        local item = ListMenuItem:new{
            width = width, height = ROW_HEIGHT, dimen = Geom:new{ w = width, h = ROW_HEIGHT },
            entry = entry or { file = "synthetic.epub", mandatory = "35 kB" },
            text = "Synthetic filename.epub", mandatory = mandatory or "35 kB", do_cover_image = cover,
            do_hint_opened = true,
            menu = { no_refresh_covers = true, ui = { bookinfo = FileManagerBookInfo },
                getBookInfo = function() return { pages = 123, percent_finished = 0.2, been_opened = true } end },
        }
        rows[#rows + 1] = item
        return item
    end

    local function findWidget(widget, predicate)
        if predicate(widget) then return widget end
        for _, child in ipairs(widget) do
            if type(child) == "table" then
                local found = findWidget(child, predicate)
                if found then return found end
            end
        end
    end

    local function paint(item)
        local bb = BB.new(item.width, item.height, BB.TYPE_BB8)
        local ok, err = pcall(function()
            item:paintTo(bb, 0, 0)
            item:onFocus()
            item:repaintFocusIndicator(bb)
            item:onUnfocus()
            item:repaintFocusIndicator(bb)
        end)
        bb:free()
        assert.is_true(ok, tostring(err))
        assert.is_true(item._underline_container.line_width >= 0)
    end

    for _, kind in ipairs({ "real", "fake", "ignored" }) do
        it("shows full-width metadata instead of overflowing a narrow " .. kind .. " cover row", function()
            variant = kind
            local item = row(NARROW_WIDTH, true)
            assert.is_true(item.do_cover_image)
            assert.is_false(item._show_cover_image)
            assert.is_nil(item._has_cover_image)
            assert.is_nil(item.menu._has_cover_images)
            local title = findWidget(item, function(w) return w.text and w.text:find("Synthetic title", 1, true) end)
            assert.is_truthy(title)
            assert.is_true(title.width > item.width / 2)
            assert.is_nil(findWidget(item, function(w) return w.text and w.text:find("35 kB", 1, true) end))
            paint(item)
            if kind == "real" then assert.same({ 1 }, released) end
        end)
    end

    it("releases each image owner once and restores covers after widening", function()
        local item = row(WIDE_WIDTH, true)
        assert.is_true(item._show_cover_image)
        assert.is_true(item._has_cover_image)
        paint(item)
        item.width = NARROW_WIDTH
        item:update()
        assert.is_false(item._show_cover_image)
        assert.same({ 1, 1 }, released)
        paint(item)
        item.width = WIDE_WIDTH
        item:update()
        assert.is_true(item._show_cover_image)
        assert.is_true(item._has_cover_image)
        assert.is_true(item.do_cover_image)
        paint(item)
        item:free()
        rows = {}
        assert.same({ 1, 1, 1 }, released)
    end)

    it("retains the displayed cover flags when a cache miss keeps the old widget", function()
        local item = row(WIDE_WIDTH, true)
        local widget = item._underline_container[1]
        variant = "uncached"
        item:update()
        assert.is_true(item._underline_container[1] == widget)
        assert.is_true(item._show_cover_image)
        assert.is_true(item._has_cover_image)
        assert.same({}, released)
        paint(item)
    end)

    it("paints fallback descriptions and focus in mirrored layout", function()
        BD.mirroredUILayout = function() return true end
        local item = row(NARROW_WIDTH, true)
        assert.is_false(item._show_cover_image)
        paint(item)
    end)

    it("keeps an earlier row's image hint when a later row falls back", function()
        local item = row(NARROW_WIDTH, true)
        item.menu._has_cover_images = true
        item:update()
        assert.is_true(item.menu._has_cover_images)
        assert.is_nil(item._has_cover_image)
        paint(item)
    end)

    it("retains ordinary geometry and right-side info when space permits", function()
        local item = row(WIDE_WIDTH, true)
        assert.is_true(item._show_cover_image)
        assert.is_true(item._has_cover_image)
        assert.is_true(item._underline_container.line_x_offset >= 198)
        assert.is_truthy(findWidget(item, function(w) return w.text and w.text:find("35 kB", 1, true) end))
        paint(item)
    end)

    it("falls back without a cover when oversized optional metadata consumes the row", function()
        local item = row(NARROW_WIDTH, false, nil, string.rep("9", 100) .. " kB")
        assert.is_false(item.do_cover_image)
        assert.is_false(item._show_cover_image)
        assert.equals(0, #buffers)
        local title = findWidget(item, function(w) return w.text and w.text:find("Synthetic title", 1, true) end)
        assert.is_true(title.width > item.width / 2)
        paint(item)
    end)

    it("falls back safely when both right-hand info fields were already hidden", function()
        settings.hide_file_info, settings.hide_page_info = true, true
        local item = row(200, true)
        assert.is_false(item._show_cover_image)
        paint(item)
        assert.same({ 1 }, released)
    end)

    it("keeps the target-width uncached and directory paths usable", function()
        variant = "uncached"
        paint(row(NARROW_WIDTH, true))
        paint(row(NARROW_WIDTH, false, { path = "synthetic-directory", mandatory = "12" }))
    end)
end)
