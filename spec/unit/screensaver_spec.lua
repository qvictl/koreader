-- Unit tests for ui/screensaver: the sleep screen shown on the suspend path
-- (setup() mode selection and fallbacks, show() for every mode, the delayed /
-- immediate / gesture / tap close paths Kindle relies on, the anti-ghosting
-- flashes and cleanup() resetting every Device flag).
describe("Screensaver", function()
    local Blitbuffer, BookList, DataStorage, Device, DocumentRegistry, FileManager, ReaderUI
    local Screen, Screensaver, UIManager, ffiUtil, filemanagerutil
    local sample_epub = "spec/front/unit/data/juliet.epub"
    local readerui, orig_summary
    local img_dir, empty_dir, alt_dir, image_file

    -- Every setting the module reads, so each test starts from the module defaults.
    local ss_settings = {
        "screensaver_type", "screensaver_show_message", "screensaver_img_background", "screensaver_msg_background",
        "screensaver_message_container", "screensaver_message_vertical_position", "screensaver_message_alpha",
        "screensaver_stretch_images", "screensaver_rotate_auto_for_best_fit", "screensaver_delay",
        "screensaver_hide_fallback_msg", "screensaver_dir", "screensaver_max_files", "screensaver_cycle_images_alphabetically",
        "screensaver_cycle_index", "screensaver_document_cover", "screensaver_message", "screensaver_exit_message",
        "screensaver_exclude_finished_books", "screensaver_exclude_on_hold_books", "screensaver_hide_cover_in_filemanager",
        "screensaver_stretch_limit_percentage", "screensaver_extra_flash_count", "screensaver_extra_flash_delay",
        "imageviewer_rotation_landscape_invert",
        "poweroff_screensaver_type", "poweroff_screensaver_dir", "poweroff_screensaver_message",
        "poweroff_screensaver_message_container",
        "reboot_screensaver_type", "reboot_screensaver_message_vertical_position", "reboot_screensaver_message_alpha",
        "reboot_screensaver_message_container",
    }
    local function resetSettings()
        for _, key in ipairs(ss_settings) do
            G_reader_settings:delSetting(key)
        end
        G_reader_settings:saveSetting("screensaver_type", "disable")
        G_reader_settings:makeTrue("screensaver_show_message")
        G_reader_settings:saveSetting("screensaver_img_background", "black")
        G_reader_settings:saveSetting("screensaver_msg_background", "none")
        G_reader_settings:saveSetting("screensaver_message_container", "box")
        G_reader_settings:saveSetting("screensaver_message_vertical_position", 50)
        G_reader_settings:saveSetting("screensaver_message_alpha", 100)
        G_reader_settings:makeFalse("screensaver_stretch_images")
        G_reader_settings:makeFalse("screensaver_rotate_auto_for_best_fit")
        G_reader_settings:saveSetting("screensaver_delay", "disable")
        G_reader_settings:makeFalse("screensaver_hide_fallback_msg")
        G_reader_settings:saveSetting("lastfile", sample_epub)
    end

    local function isScheduled(action)
        for _, task in ipairs(UIManager._task_queue) do
            if task.action == action then return true end
        end
        return false
    end

    local function countScheduled(action)
        local n = 0
        for _, task in ipairs(UIManager._task_queue) do
            if task.action == action then n = n + 1 end
        end
        return n
    end

    -- Tear down whatever a test left on screen, through the regular widget close path.
    local function dismiss()
        if Screensaver.screensaver_lock_widget and UIManager:isWidgetShown(Screensaver.screensaver_lock_widget) then
            UIManager:close(Screensaver.screensaver_lock_widget)
        end
        if Screensaver.screensaver_widget then
            UIManager:close(Screensaver.screensaver_widget)
        end
        Screensaver:cleanup()
    end

    local function assertCleanState()
        assert.is_false(Device.screen_saver_mode)
        assert.is_false(Device.screen_saver_lock)
        assert.is_nil(Device.screensaver_suspend_wait_timeout)
        assert.is_nil(Screensaver.screensaver_widget)
        assert.is_nil(Screensaver.screensaver_lock_widget)
        assert.is_nil(Screensaver.screensaver_type)
        assert.is_nil(Screensaver.image)
        assert.is_nil(Screensaver.image_file)
        assert.is_nil(Screensaver.overlay_message)
        assert.is_nil(Screensaver.delayed_close)
        assert.is_nil(Screensaver.bb_copy)
        assert.is_false(isScheduled(Screensaver.flashBlack))
        assert.is_false(isScheduled(Screensaver.restoreCover))
        assert.is_false(isScheduled(Screensaver.close_widget))
    end

    local function makeFile(path, content)
        local f = assert(io.open(path, "w"))
        f:write(content or "x")
        f:close()
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        Blitbuffer = require("ffi/blitbuffer")
        BookList = require("ui/widget/booklist")
        DataStorage = require("datastorage")
        Device = require("device")
        DocumentRegistry = require("document/documentregistry")
        FileManager = require("apps/filemanager/filemanager")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        ffiUtil = require("ffi/util")
        filemanagerutil = require("apps/filemanager/filemanagerutil")
        Screen = Device.screen
        Screensaver = require("ui/screensaver")

        local base = DataStorage:getDataDir() .. "/screensaver_spec"
        ffiUtil.purgeDir(base)
        img_dir = base .. "/images"
        empty_dir = base .. "/empty"
        alt_dir = base .. "/poweroff"
        require("util").makePath(img_dir)
        require("util").makePath(empty_dir)
        require("util").makePath(alt_dir)
        -- Natural order: img1 < img2 < img11 (plain string order would put img11 first)
        for _, name in ipairs{ "img11.png", "img2.png", "img1.png" } do
            ffiUtil.copyFile("resources/koreader.png", img_dir .. "/" .. name)
        end
        makeFile(img_dir .. "/._img0.png") -- macOS resource fork: must be ignored
        makeFile(img_dir .. "/notes.txt") -- not an image: must be ignored
        ffiUtil.copyFile("resources/koreader.png", alt_dir .. "/poweroff.png")
        makeFile(empty_dir .. "/readme.txt")
        image_file = img_dir .. "/img2.png"

        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(sample_epub),
        }
        orig_summary = readerui.doc_settings:readSetting("summary")
        readerui:saveSettings() -- so that the book has a sidecar file (hasBookBeenOpened)
        BookList.book_info_cache[sample_epub] = nil
    end)

    teardown(function()
        dismiss()
        resetSettings()
        readerui:closeDocument()
        readerui:onClose()
        ReaderUI.instance = nil
        ffiUtil.purgeDir(DataStorage:getDataDir() .. "/screensaver_spec")
    end)

    before_each(function()
        resetSettings()
        ReaderUI.instance = readerui
        readerui.doc_settings:delSetting("exclude_screensaver")
        readerui.doc_settings:saveSetting("summary", orig_summary)
        Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
    end)

    after_each(function()
        dismiss()
        assertCleanState()
    end)

    describe("module defaults", function()
        it("leaves the screen as-is with a message by default, and reminds emulator users of F2", function()
            assert.are.equal("disable", G_reader_settings:readSetting("screensaver_type"))
            assert.is_true(G_reader_settings:isTrue("screensaver_show_message"))
            assert.are.equal("disable", G_reader_settings:readSetting("screensaver_delay"))
            assert.truthy(Screensaver.default_screensaver_message:find("F2", 1, true))
        end)
    end)

    describe("setup()", function()
        it("skips when there is neither a ReaderUI nor a FileManager instance", function()
            ReaderUI.instance = nil
            local fm_instance = FileManager.instance
            FileManager.instance = nil
            Screensaver.ui = nil
            assert.is_nil(Screensaver:setup())
            assert.is_nil(Screensaver.ui)
            -- show() is a no-op as well: Device must not be flagged as in screensaver mode
            Screensaver:show()
            assert.is_false(Device.screen_saver_mode)
            FileManager.instance = fm_instance
        end)

        it("keeps 'disable' with the message background when the book is not excluded", function()
            G_reader_settings:saveSetting("screensaver_msg_background", "white")
            Screensaver:setup()
            assert.are.equal(readerui, Screensaver.ui)
            assert.are.equal("disable", Screensaver:getMode())
            assert.are.equal("white", Screensaver.screensaver_background)
            assert.is_true(Screensaver:withBackground())
            assert.is_false(Screensaver:modeIsImage())
            assert.is_false(Screensaver:modeExpectsPortrait())
            assert.is_true(Screensaver.show_message)
            assert.are.equal("", Screensaver.prefix)
            assert.is_nil(Screensaver.overlay_message)
        end)

        it("turns 'disable' into a random image for an excluded book", function()
            readerui.doc_settings:makeTrue("exclude_screensaver")
            assert.is_true(Screensaver.isExcluded(readerui))
            Screensaver:setup()
            assert.are.equal("random_image", Screensaver:getMode())
            -- no folder configured: the bundled fallback image
            assert.are.equal("resources/koreader.png", Screensaver.image_file)
            assert.are.equal("black", Screensaver.screensaver_background)
            assert.is_true(Screensaver:modeIsImage())
            assert.is_true(Screensaver:modeExpectsPortrait())
        end)

        it("uses the cover of the book being read", function()
            G_reader_settings:saveSetting("screensaver_type", "cover")
            Screensaver:setup()
            assert.are.equal("cover", Screensaver:getMode())
            assert.truthy(Screensaver.image)
            assert.is_true(Screensaver.image:getWidth() > 0)
            assert.is_nil(Screensaver.image_file)
            assert.are.equal("black", Screensaver.screensaver_background)
            assert.is_true(Screensaver.show_message)
            Screensaver.image:free()
        end)

        it("falls back to a random image when the current book is excluded", function()
            G_reader_settings:saveSetting("screensaver_type", "cover")
            G_reader_settings:saveSetting("screensaver_dir", img_dir)
            readerui.doc_settings:makeTrue("exclude_screensaver")
            Screensaver:setup()
            assert.are.equal("random_image", Screensaver:getMode())
            assert.is_nil(Screensaver.image)
            assert.truthy(Screensaver.image_file:find(img_dir, 1, true))
            -- the message is still shown for an explicit exclusion
            assert.is_true(Screensaver.show_message)
        end)

        it("excludes finished books and hides the message when asked to", function()
            G_reader_settings:saveSetting("screensaver_type", "cover")
            readerui.doc_settings:saveSetting("summary", { status = "complete" })
            -- not enabled: the finished book's cover is used
            Screensaver:setup()
            assert.are.equal("cover", Screensaver:getMode())
            Screensaver.image:free()
            Screensaver:cleanup()

            G_reader_settings:makeTrue("screensaver_exclude_finished_books")
            Screensaver:setup()
            assert.are.equal("random_image", Screensaver:getMode())
            assert.is_false(Screensaver.show_message)
            assert.is_nil(Screensaver.image)
        end)

        it("excludes on-hold books when asked to", function()
            G_reader_settings:saveSetting("screensaver_type", "cover")
            G_reader_settings:makeTrue("screensaver_exclude_on_hold_books")
            readerui.doc_settings:saveSetting("summary", { status = "reading" })
            Screensaver:setup()
            assert.are.equal("cover", Screensaver:getMode())
            Screensaver.image:free()
            Screensaver:cleanup()

            readerui.doc_settings:saveSetting("summary", { status = "abandoned" })
            Screensaver:setup()
            assert.are.equal("random_image", Screensaver:getMode())
            assert.is_false(Screensaver.show_message)
        end)

        it("falls back to a random image when the last file is gone", function()
            G_reader_settings:saveSetting("screensaver_type", "cover")
            G_reader_settings:saveSetting("lastfile", img_dir .. "/missing.epub")
            Screensaver:setup()
            assert.are.equal("random_image", Screensaver:getMode())
            assert.are.equal("resources/koreader.png", Screensaver.image_file)
        end)

        it("falls back to a random image when there is no last file", function()
            G_reader_settings:saveSetting("screensaver_type", "cover")
            G_reader_settings:delSetting("lastfile")
            Screensaver:setup()
            assert.are.equal("random_image", Screensaver:getMode())
        end)

        it("shows an image last file as-is", function()
            G_reader_settings:saveSetting("screensaver_type", "cover")
            G_reader_settings:saveSetting("lastfile", image_file)
            Screensaver:setup()
            assert.are.equal("cover", Screensaver:getMode())
            assert.are.equal(image_file, Screensaver.image_file)
            assert.is_nil(Screensaver.image)
        end)

        it("falls back to a random image when the book has no cover", function()
            G_reader_settings:saveSetting("screensaver_type", "cover")
            local get_cover = stub(readerui.bookinfo, "getCoverImage")
            Screensaver:setup()
            assert.stub(get_cover).was_called(1)
            assert.are.equal("random_image", Screensaver:getMode())
            get_cover:revert()
        end)

        it("shows the chosen document cover even if that book is excluded", function()
            G_reader_settings:saveSetting("screensaver_type", "document_cover")
            G_reader_settings:saveSetting("screensaver_document_cover", sample_epub)
            G_reader_settings:saveSetting("lastfile", image_file)
            readerui.doc_settings:makeTrue("exclude_screensaver")
            Screensaver:setup()
            assert.are.equal("cover", Screensaver:getMode())
            assert.truthy(Screensaver.image)
            Screensaver.image:free()
        end)

        it("shows a chosen image file as document cover", function()
            G_reader_settings:saveSetting("screensaver_type", "document_cover")
            G_reader_settings:saveSetting("screensaver_document_cover", image_file)
            Screensaver:setup()
            assert.are.equal("cover", Screensaver:getMode())
            assert.are.equal(image_file, Screensaver.image_file)
        end)

        it("falls back to a random image when the chosen document cover is unset", function()
            G_reader_settings:saveSetting("screensaver_type", "document_cover")
            Screensaver:setup()
            assert.are.equal("random_image", Screensaver:getMode())
        end)

        it("keeps bookstatus for a non excluded open book, with the message background", function()
            G_reader_settings:saveSetting("screensaver_type", "bookstatus")
            Screensaver:setup()
            assert.are.equal("bookstatus", Screensaver:getMode())
            assert.are.equal("none", Screensaver.screensaver_background)
            assert.is_false(Screensaver:withBackground())
            assert.is_false(Screensaver:modeExpectsPortrait())
        end)

        it("turns bookstatus into a random image for an excluded book", function()
            G_reader_settings:saveSetting("screensaver_type", "bookstatus")
            readerui.doc_settings:makeTrue("exclude_screensaver")
            Screensaver:setup()
            assert.are.equal("random_image", Screensaver:getMode())
        end)

        it("turns readingprogress into a random image without the statistics plugin", function()
            G_reader_settings:saveSetting("screensaver_type", "readingprogress")
            assert.is_nil(readerui.statistics)
            Screensaver:setup()
            assert.are.equal("random_image", Screensaver:getMode())
        end)

        it("keeps readingprogress when statistics are available", function()
            G_reader_settings:saveSetting("screensaver_type", "readingprogress")
            readerui.statistics = {}
            Screensaver:setup()
            readerui.statistics = nil
            assert.are.equal("readingprogress", Screensaver:getMode())
            assert.is_false(Screensaver:modeExpectsPortrait())
        end)

        it("overlays the event message on poweroff/reboot when no specific mode is set", function()
            Screensaver:setup("poweroff", "Powered off")
            assert.are.equal("poweroff_", Screensaver.prefix)
            assert.are.equal("Powered off", Screensaver.event_message)
            assert.are.equal("Powered off", Screensaver.overlay_message)
            assert.are.equal("disable", Screensaver:getMode())
        end)

        it("does not overlay the event message when the fallback message is hidden", function()
            G_reader_settings:makeTrue("screensaver_hide_fallback_msg")
            Screensaver:setup("reboot", "Rebooting…")
            assert.are.equal("reboot_", Screensaver.prefix)
            assert.is_nil(Screensaver.overlay_message)
        end)

        it("uses the poweroff_ prefixed mode and folder when set", function()
            G_reader_settings:saveSetting("poweroff_screensaver_type", "random_image")
            G_reader_settings:saveSetting("poweroff_screensaver_dir", alt_dir)
            G_reader_settings:saveSetting("screensaver_dir", img_dir)
            Screensaver:setup("poweroff", "Powered off")
            assert.are.equal("random_image", Screensaver:getMode())
            assert.is_nil(Screensaver.overlay_message)
            assert.are.equal(alt_dir .. "/poweroff.png", Screensaver.image_file)
            Screensaver:cleanup()
            -- a regular suspend ignores the poweroff_ settings
            Screensaver:setup()
            assert.are.equal("disable", Screensaver:getMode())
        end)

        it("falls back to the generic folder when the prefixed one is unset", function()
            G_reader_settings:saveSetting("reboot_screensaver_type", "random_image")
            G_reader_settings:saveSetting("screensaver_dir", alt_dir)
            Screensaver:setup("reboot", "Rebooting")
            assert.are.equal(alt_dir .. "/poweroff.png", Screensaver.image_file)
        end)

        describe("with the FileManager", function()
            local filemanager
            before_each(function()
                ReaderUI.instance = nil
                filemanager = FileManager:new{
                    dimen = Screen:getSize(),
                    root_path = "spec/front/unit/data",
                }
                BookList.book_info_cache[sample_epub] = nil
            end)
            after_each(function()
                filemanager:onClose()
                ReaderUI.instance = readerui
                local ds = BookList.getDocSettings(sample_epub)
                ds:delSetting("exclude_screensaver")
                ds:delSetting("summary")
                ds:flush()
                BookList.book_info_cache[sample_epub] = nil
            end)

            it("shows the last book's cover", function()
                G_reader_settings:saveSetting("screensaver_type", "cover")
                Screensaver:setup()
                assert.are.equal(filemanager, Screensaver.ui)
                assert.is_false(Screensaver.isExcluded(filemanager))
                assert.are.equal("cover", Screensaver:getMode())
                assert.truthy(Screensaver.image)
                Screensaver.image:free()
            end)

            it("hides the cover in the file browser when asked to", function()
                G_reader_settings:saveSetting("screensaver_type", "cover")
                G_reader_settings:makeTrue("screensaver_hide_cover_in_filemanager")
                Screensaver:setup()
                assert.are.equal("random_image", Screensaver:getMode())
                assert.is_false(Screensaver.show_message)
            end)

            it("honours the last book's exclusion from its sidecar settings", function()
                local ds = BookList.getDocSettings(sample_epub)
                ds:makeTrue("exclude_screensaver")
                ds:flush()
                BookList.book_info_cache[sample_epub] = nil
                assert.is_true(Screensaver.isExcluded(filemanager))
                G_reader_settings:saveSetting("screensaver_type", "cover")
                Screensaver:setup()
                assert.are.equal("random_image", Screensaver:getMode())
            end)

            it("does not consider anything excluded without a last file", function()
                G_reader_settings:delSetting("lastfile")
                assert.is_false(Screensaver.isExcluded(filemanager))
            end)

            it("turns bookstatus into a random image (no document)", function()
                G_reader_settings:saveSetting("screensaver_type", "bookstatus")
                Screensaver:setup()
                assert.are.equal("random_image", Screensaver:getMode())
            end)

            it("keeps 'disable' (no document to exclude)", function()
                Screensaver:setup()
                assert.are.equal("disable", Screensaver:getMode())
            end)
        end)
    end)

    describe("random image selection", function()
        before_each(function()
            G_reader_settings:saveSetting("screensaver_type", "random_image")
            G_reader_settings:saveSetting("screensaver_dir", img_dir)
        end)

        local function pick()
            Screensaver:setup()
            local file = Screensaver.image_file
            Screensaver:cleanup()
            return file
        end

        it("cycles alphabetically in natural order and wraps around", function()
            G_reader_settings:makeTrue("screensaver_cycle_images_alphabetically")
            assert.are.equal(img_dir .. "/img1.png", pick())
            assert.are.equal(1, G_reader_settings:readSetting("screensaver_cycle_index"))
            assert.are.equal(img_dir .. "/img2.png", pick())
            assert.are.equal(img_dir .. "/img11.png", pick())
            assert.are.equal(3, G_reader_settings:readSetting("screensaver_cycle_index"))
            -- wrap around
            assert.are.equal(img_dir .. "/img1.png", pick())
            assert.are.equal(1, G_reader_settings:readSetting("screensaver_cycle_index"))
        end)

        it("wraps a stale cycle index (folder shrank since last time)", function()
            G_reader_settings:makeTrue("screensaver_cycle_images_alphabetically")
            G_reader_settings:saveSetting("screensaver_cycle_index", 42)
            assert.are.equal(img_dir .. "/img1.png", pick())
            assert.are.equal(1, G_reader_settings:readSetting("screensaver_cycle_index"))
        end)

        it("caps the number of files considered", function()
            -- (The cap counts every file scanned, images or not, in directory order: use a
            -- folder with images only, so that the outcome doesn't depend on that order.)
            local only_images = img_dir .. "_only"
            require("util").makePath(only_images)
            for _, name in ipairs{ "a.png", "b.png" } do
                ffiUtil.copyFile("resources/koreader.png", only_images .. "/" .. name)
            end
            finally(function() ffiUtil.purgeDir(only_images) end)
            G_reader_settings:saveSetting("screensaver_dir", only_images)
            G_reader_settings:makeTrue("screensaver_cycle_images_alphabetically")
            G_reader_settings:saveSetting("screensaver_max_files", 1)
            local first = pick()
            assert.truthy(first:find(only_images, 1, true))
            -- a single candidate: the cycle keeps returning it
            assert.are.equal(first, pick())
            assert.are.equal(1, G_reader_settings:readSetting("screensaver_cycle_index"))
        end)

        it("falls back to the bundled image when the folder has no image", function()
            G_reader_settings:saveSetting("screensaver_dir", empty_dir)
            G_reader_settings:makeTrue("screensaver_cycle_images_alphabetically")
            assert.are.equal("resources/koreader.png", pick())
            assert.is_nil(G_reader_settings:readSetting("screensaver_cycle_index"))
            G_reader_settings:makeFalse("screensaver_cycle_images_alphabetically")
            assert.are.equal("resources/koreader.png", pick())
        end)

        it("falls back to the bundled image when the folder does not exist", function()
            G_reader_settings:saveSetting("screensaver_dir", img_dir .. "/nope")
            assert.are.equal("resources/koreader.png", pick())
        end)

        it("picks random images, never macOS resource forks nor non-images", function()
            local valid = {
                [img_dir .. "/img1.png"] = true,
                [img_dir .. "/img2.png"] = true,
                [img_dir .. "/img11.png"] = true,
            }
            local get_random = spy.on(filemanagerutil, "getRandomFile")
            for _ = 1, 12 do
                local file = pick()
                assert.is_true(valid[file] or false, file)
            end
            assert.spy(get_random).was_called(12)
            get_random:revert()
            assert.is_nil(G_reader_settings:readSetting("screensaver_cycle_index"))
        end)
    end)

    describe("show()", function()
        it("shows nothing as-is without message, overlay nor lock", function()
            G_reader_settings:makeFalse("screensaver_show_message")
            Screensaver:setup()
            Screensaver:show()
            assert.is_true(Device.screen_saver_mode)
            assert.is_nil(Screensaver.screensaver_widget)
            assert.is_nil(Screensaver.screensaver_lock_widget)
            -- close() has no widget to wait for: it cleans up right away
            assert.is_nil(Screensaver:close())
            assertCleanState()
        end)

        it("shows the message in a box, without covering the screen", function()
            G_reader_settings:saveSetting("screensaver_message", "Good night")
            Screensaver:setup()
            Screensaver:show()
            local widget = Screensaver.screensaver_widget
            assert.truthy(widget)
            assert.is_true(UIManager:isWidgetShown(widget))
            assert.is_true(widget.modal)
            assert.is_false(widget.covers_fullscreen)
            assert.is_nil(widget.background)
            assert.is_nil(Device.orig_rotation_mode)
            -- the CustomPositionContainer holds the InfoMessage's movable
            local container = widget.widget
            assert.are.equal(0.5, container.vertical_position)
            assert.are.equal(1, container.alpha)
            assert.truthy(container.widget)
        end)

        it("shows the message in a banner at the requested position and opacity", function()
            G_reader_settings:saveSetting("screensaver_message_container", "banner")
            G_reader_settings:saveSetting("screensaver_message_vertical_position", 100)
            G_reader_settings:saveSetting("screensaver_message_alpha", 40)
            G_reader_settings:saveSetting("screensaver_msg_background", "white")
            G_reader_settings:saveSetting("screensaver_message", "Banner %T")
            Screensaver:setup()
            Screensaver:show()
            local widget = Screensaver.screensaver_widget
            assert.is_true(widget.covers_fullscreen)
            assert.are.equal(Blitbuffer.COLOR_WHITE, widget.background)
            local container = widget.widget
            assert.are.equal(0, container.vertical_position)
            assert.are.equal(0.4, container.alpha)
            -- expandString() substituted the title pattern
            local text = container.widget.text
            assert.truthy(text:find("^Banner "))
            assert.is_nil(text:find("%T", 1, true))
        end)

        it("prefers the event message over the default message, and shows it only once", function()
            G_reader_settings:saveSetting("screensaver_message_container", "banner")
            Screensaver:setup("poweroff", "Powered off")
            assert.are.equal("Powered off", Screensaver.overlay_message)
            Screensaver:show()
            assert.is_nil(Screensaver.overlay_message)
            assert.are.equal("Powered off", Screensaver.screensaver_widget.widget.widget.text)
        end)

        it("keeps a custom message and overlays the event message on top", function()
            G_reader_settings:saveSetting("screensaver_message", "Custom")
            G_reader_settings:saveSetting("screensaver_message_vertical_position", 90)
            G_reader_settings:saveSetting("screensaver_message_container", "banner")
            Screensaver:setup("reboot", "Rebooting")
            Screensaver:show()
            assert.are.equal("Rebooting", Screensaver.overlay_message)
            local group = Screensaver.screensaver_widget.widget
            -- OverlapGroup{ message widget, overlay }
            assert.are.equal("Custom", group[1].widget.text)
            assert.truthy(group[2])
        end)

        it("wraps an overlay message wider than the screen", function()
            G_reader_settings:saveSetting("screensaver_type", "random_image")
            G_reader_settings:makeFalse("screensaver_show_message")
            local long_message = string.rep("Shutting down now ", 20)
            Screensaver:setup("reboot", long_message)
            Screensaver:show()
            local group = Screensaver.screensaver_widget.widget
            -- OverlapGroup{ image, RightContainer{ FrameContainer{ TextBoxWidget } } }
            assert.are.equal("resources/koreader.png", group[1].file)
            local textw = group[2][1][1]
            assert.are.equal(long_message, textw.text)
            assert.are.equal(math.floor(Screen:getWidth() * 0.9), textw.width)
            assert.is_true(textw:getSize().h > 0)
        end)

        it("uses the poweroff_ prefixed message settings", function()
            G_reader_settings:saveSetting("poweroff_screensaver_type", "message")
            G_reader_settings:saveSetting("poweroff_screensaver_message", "Bye")
            G_reader_settings:saveSetting("screensaver_message", "Not this one")
            G_reader_settings:saveSetting("poweroff_screensaver_message_container", "banner")
            Screensaver:setup("poweroff", "Powered off")
            Screensaver:show()
            assert.are.equal("Bye", Screensaver.screensaver_widget.widget.widget.text)
        end)

        it("shows the book cover over a black background", function()
            G_reader_settings:saveSetting("screensaver_type", "cover")
            G_reader_settings:makeFalse("screensaver_show_message")
            Screensaver:setup()
            local image = Screensaver.image
            Screensaver:show()
            local widget = Screensaver.screensaver_widget
            assert.is_true(widget.covers_fullscreen)
            assert.are.equal(Blitbuffer.COLOR_BLACK, widget.background)
            local imagewidget = widget.widget
            assert.are.equal(image, imagewidget.image)
            assert.is_true(imagewidget.image_disposable)
            assert.are.equal(0, imagewidget.scale_factor) -- no stretching
            assert.are.equal(Screen:getWidth(), imagewidget.width)
            assert.are.equal(Screen:getHeight(), imagewidget.height)
        end)

        it("stretches images up to the configured limit", function()
            G_reader_settings:saveSetting("screensaver_type", "random_image")
            G_reader_settings:makeTrue("screensaver_stretch_images")
            G_reader_settings:saveSetting("screensaver_stretch_limit_percentage", 10)
            G_reader_settings:saveSetting("screensaver_dir", alt_dir)
            G_reader_settings:makeFalse("screensaver_show_message")
            Screensaver:setup()
            Screensaver:show()
            local imagewidget = Screensaver.screensaver_widget.widget
            assert.is_nil(imagewidget.scale_factor)
            assert.are.equal(10, imagewidget.stretch_limit_percentage)
            assert.are.equal(alt_dir .. "/poweroff.png", imagewidget.file)
            assert.is_false(imagewidget.file_do_cache)
            assert.is_true(imagewidget.alpha)
        end)

        it("overlays the message on top of an image", function()
            G_reader_settings:saveSetting("screensaver_type", "random_image")
            G_reader_settings:saveSetting("screensaver_img_background", "none")
            Screensaver:setup()
            Screensaver:show()
            local widget = Screensaver.screensaver_widget
            assert.is_true(widget.covers_fullscreen)
            assert.is_nil(widget.background)
            local group = widget.widget
            assert.are.equal("resources/koreader.png", group[1].file)
            assert.truthy(group[2].vertical_position)
        end)

        it("rotates a landscape screen to portrait for images, and restores it on close", function()
            G_reader_settings:saveSetting("screensaver_type", "random_image")
            local w, h = Screen:getWidth(), Screen:getHeight()
            Screen:setRotationMode(Screen.DEVICE_ROTATED_CLOCKWISE)
            Screensaver:setup()
            Screensaver:show()
            assert.are.equal(Screen.DEVICE_ROTATED_CLOCKWISE, Device.orig_rotation_mode)
            assert.are.equal(Screen.DEVICE_ROTATED_UPRIGHT, Screen:getRotationMode())
            assert.are.equal(w, Screen:getWidth())
            assert.are.equal(h, Screen:getHeight())
            assert.is_true(Screensaver:close())
            assert.are.equal(Screen.DEVICE_ROTATED_CLOCKWISE, Screen:getRotationMode())
            assert.is_nil(Device.orig_rotation_mode)
            Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
        end)

        it("keeps a landscape screen for message only modes", function()
            Screen:setRotationMode(Screen.DEVICE_ROTATED_CLOCKWISE)
            Device.orig_rotation_mode = 3 -- stale value from an earlier image screensaver
            Screensaver:setup()
            Screensaver:show()
            assert.is_nil(Device.orig_rotation_mode)
            assert.are.equal(Screen.DEVICE_ROTATED_CLOCKWISE, Screen:getRotationMode())
            Screensaver:close()
            Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
        end)

        it("flashes the screen first on eInk to avoid ghosting", function()
            G_reader_settings:saveSetting("screensaver_type", "random_image")
            local has_eink = stub(Device, "hasEinkScreen", true)
            local is_kobo = stub(Device, "isKobo", true)
            local is_sunxi = stub(Device, "isSunxi", true)
            local usleep = stub(ffiUtil, "usleep")
            local clear = spy.on(Screen, "clear")
            local refresh_full = spy.on(Screen, "refreshFull")
            Screensaver:setup()
            Screensaver:show()
            assert.spy(clear).was_called(1)
            assert.spy(refresh_full).was_called_with(Screen, 0, 0, Screen:getWidth(), Screen:getHeight())
            assert.stub(usleep).was_called_with(150 * 1000)
            Screensaver:close()
            -- without a background, no clear(), but still the flash
            G_reader_settings:saveSetting("screensaver_img_background", "none")
            is_kobo:revert()
            Screensaver:setup()
            Screensaver:show()
            assert.spy(clear).was_called(1)
            assert.spy(refresh_full).was_called(2)
            assert.stub(usleep).was_called(1)
            Screensaver:close()
            has_eink:revert()
            is_sunxi:revert()
            usleep:revert()
            clear:revert()
            refresh_full:revert()
        end)

        it("rotates the image for best fit, renders SVGs and replaces broken images with a checkerboard", function()
            G_reader_settings:saveSetting("screensaver_type", "cover")
            G_reader_settings:makeTrue("screensaver_rotate_auto_for_best_fit")
            G_reader_settings:makeFalse("screensaver_show_message")
            local function writePNG(path, w, h)
                local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
                bb:fill(Blitbuffer.COLOR_GRAY)
                bb:writePNG(path)
                bb:free()
            end
            local landscape = img_dir .. "/landscape.png"
            local portrait = img_dir .. "/portrait.png"
            writePNG(landscape, 40, 20)
            writePNG(portrait, 20, 40)
            local function showFor(file)
                G_reader_settings:saveSetting("lastfile", file)
                Screensaver:setup()
                assert.are.equal(file, Screensaver.image_file)
                Screensaver:show()
                local imagewidget = Screensaver.screensaver_widget.widget
                assert.truthy(imagewidget.image)
                assert.is_true(imagewidget.image_disposable)
                assert.is_nil(imagewidget.file)
                return imagewidget
            end
            -- a landscape image on a portrait screen is rotated by 90°
            assert.are.equal(90, showFor(landscape).rotation_angle)
            Screensaver:close()
            -- a portrait image is left alone
            assert.are.equal(0, showFor(portrait).rotation_angle)
            Screensaver:close()
            -- inverted landscape rotation
            G_reader_settings:makeTrue("imageviewer_rotation_landscape_invert")
            assert.are.equal(-90, showFor(landscape).rotation_angle)
            Screensaver:close()

            -- SVG files go through the SVG renderer
            local svg_file = img_dir .. "/drawing.svg"
            makeFile(svg_file, [[<svg xmlns="http://www.w3.org/2000/svg" width="20" height="40"><rect width="20" height="40"/></svg>]])
            local svg_widget = showFor(svg_file)
            assert.is_true(svg_widget.image:getHeight() > svg_widget.image:getWidth())
            assert.are.equal(0, svg_widget.rotation_angle)
            Screensaver:close()

            -- an unreadable image is replaced by a screen-sized checkerboard (portrait: no rotation)
            local broken = img_dir .. "/broken.jpg"
            makeFile(broken, "this is not a jpeg")
            local checker = showFor(broken)
            assert.are.equal(Screen:getWidth(), checker.image:getWidth())
            assert.are.equal(Screen:getHeight(), checker.image:getHeight())
            assert.are.equal(0, checker.rotation_angle)
            Screensaver:close()
            for _, f in ipairs{ landscape, portrait, svg_file, broken } do
                os.remove(f)
            end
        end)

        it("shows the book status widget", function()
            G_reader_settings:saveSetting("screensaver_type", "bookstatus")
            G_reader_settings:makeFalse("screensaver_show_message")
            Screensaver:setup()
            Screensaver:show()
            local widget = Screensaver.screensaver_widget
            assert.are.equal(require("ui/widget/bookstatuswidget"), getmetatable(widget.widget).__index)
            assert.is_true(widget.widget.readonly)
            assert.are.equal(readerui, widget.widget.ui)
            assert.is_true(Screensaver:close())
        end)

        it("asks the statistics plugin for the reading progress widget", function()
            G_reader_settings:saveSetting("screensaver_type", "readingprogress")
            G_reader_settings:makeFalse("screensaver_show_message")
            local progress_widget = require("ui/widget/verticalspan"):new{ width = 10 } -- unscaled_size_check: ignore
            local asked_with
            readerui.statistics = {
                onShowReaderProgress = function(_, return_widget)
                    asked_with = return_widget
                    return progress_widget
                end,
            }
            Screensaver:setup()
            Screensaver:show()
            readerui.statistics = nil
            assert.is_true(asked_with)
            assert.are.equal(progress_widget, Screensaver.screensaver_widget.widget)
        end)

        it("adds a gesture lock widget, shown on top of the screensaver", function()
            G_reader_settings:saveSetting("screensaver_delay", "gesture")
            G_reader_settings:saveSetting("screensaver_type", "random_image")
            Screensaver:setup()
            Screensaver:show()
            local lock = Screensaver.screensaver_lock_widget
            assert.truthy(lock)
            assert.is_true(UIManager:isWidgetShown(lock))
            assert.is_true(UIManager:isWidgetShown(Screensaver.screensaver_widget))
            -- "gesture": close() keeps everything up, waiting for the unlock gesture
            assert.is_nil(Screensaver:close())
            assert.is_true(UIManager:isWidgetShown(lock))
            -- the unlock closes both widgets and cleans up
            lock:onClose()
            assert.is_false(UIManager:isWidgetShown(lock))
            assertCleanState()
        end)

        it("shows the gesture lock alone in as-is mode without message", function()
            G_reader_settings:saveSetting("screensaver_delay", "gesture")
            G_reader_settings:makeFalse("screensaver_show_message")
            Screensaver:setup()
            Screensaver:show()
            assert.is_nil(Screensaver.screensaver_widget)
            local lock = Screensaver.screensaver_lock_widget
            assert.is_true(UIManager:isWidgetShown(lock))
            -- on resume, the lock takes over the Device lock flag
            lock:onResume()
            assert.is_true(Device.screen_saver_lock)
            lock:onSuspend()
            assert.is_false(Device.screen_saver_lock)
            -- closing the lock widget cleans up in place of the (absent) ScreenSaverWidget
            UIManager:close(lock)
            assertCleanState()
        end)

        it("passes the original dimensions to the gesture lock when rotating a landscape screen", function()
            G_reader_settings:saveSetting("screensaver_delay", "gesture")
            G_reader_settings:saveSetting("screensaver_type", "random_image")
            local resize = stub(readerui, "updateTouchZonesOnScreenResize")
            Screen:setRotationMode(Screen.DEVICE_ROTATED_CLOCKWISE)
            local landscape_w, landscape_h = Screen:getWidth(), Screen:getHeight()
            Screensaver:setup()
            Screensaver:show()
            local lock = Screensaver.screensaver_lock_widget
            assert.are.same({ w = landscape_w, h = landscape_h }, lock.orig_dimen)
            assert.stub(resize).was_called(1)
            lock:onClose()
            -- back to the original touch zones
            assert.stub(resize).was_called(2)
            assert.are.equal(Screen.DEVICE_ROTATED_CLOCKWISE, Screen:getRotationMode())
            resize:revert()
            Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
        end)
    end)

    describe("close()", function()
        before_each(function()
            G_reader_settings:saveSetting("screensaver_type", "random_image")
        end)

        it("closes the widget right away and returns true with 'disable' (Kindle relies on it)", function()
            Screensaver:setup()
            Screensaver:show()
            local widget = Screensaver.screensaver_widget
            assert.is_true(UIManager:isWidgetShown(widget))
            assert.is_true(Screensaver:close())
            assert.is_false(UIManager:isWidgetShown(widget))
            -- ScreenSaverWidget:onCloseWidget() ran Screensaver:cleanup()
            assertCleanState()
        end)

        it("delays the close by the configured number of seconds", function()
            G_reader_settings:saveSetting("screensaver_delay", "3")
            Screensaver:setup()
            Screensaver:show()
            local widget = Screensaver.screensaver_widget
            assert.is_nil(Screensaver:close())
            assert.is_true(Screensaver.delayed_close)
            assert.is_true(isScheduled(Screensaver.close_widget))
            assert.is_true(UIManager:isWidgetShown(widget))
            -- the widget catches Resume while shown: further power presses go back to suspend
            widget:onResume()
            assert.is_true(Device.screen_saver_lock)
            widget:onSuspend()
            assert.is_false(Device.screen_saver_lock)
            fastforward_ui_events()
            assert.is_false(UIManager:isWidgetShown(widget))
            assertCleanState()
        end)

        it("unschedules the delayed close when the user dismisses the screensaver early", function()
            G_reader_settings:saveSetting("screensaver_delay", "10")
            Screensaver:setup()
            Screensaver:show()
            local widget = Screensaver.screensaver_widget
            Screensaver:close()
            assert.is_true(isScheduled(Screensaver.close_widget))
            widget:onTap()
            assert.is_false(UIManager:isWidgetShown(widget))
            assertCleanState()
        end)

        it("keeps a poweroff/reboot screensaver up when asked to", function()
            G_reader_settings:saveSetting("screensaver_delay", "tap")
            Screensaver:setup("poweroff", "Powered off")
            Screensaver:show()
            local widget = Screensaver.screensaver_widget
            assert.is_true(widget:onClose({ keep_screensaver = true }))
            assert.is_true(UIManager:isWidgetShown(widget))
        end)

        it("waits for a tap with 'tap'", function()
            G_reader_settings:saveSetting("screensaver_delay", "tap")
            Screensaver:setup()
            Screensaver:show()
            local widget = Screensaver.screensaver_widget
            assert.is_nil(Screensaver:close())
            assert.is_nil(Screensaver.delayed_close)
            assert.is_false(isScheduled(Screensaver.close_widget))
            assert.is_true(UIManager:isWidgetShown(widget))
            assert.is_true(Device.screen_saver_mode)
            widget:onTap()
            assert.is_false(UIManager:isWidgetShown(widget))
            assertCleanState()
        end)

        it("close_widget() is a no-op without a widget", function()
            Screensaver.screensaver_widget = nil
            local close = spy.on(UIManager, "close")
            Screensaver:close_widget()
            assert.spy(close).was_not_called()
            close:revert()
        end)
    end)

    describe("extra anti-ghosting flashes", function()
        before_each(function()
            G_reader_settings:saveSetting("screensaver_type", "random_image")
            G_reader_settings:saveSetting("screensaver_extra_flash_count", 2)
            G_reader_settings:saveSetting("screensaver_extra_flash_delay", 1000)
        end)

        it("schedules the flashes and extends the suspend wait timeout", function()
            G_reader_settings:saveSetting("screensaver_delay", "gesture")
            Screensaver:setup()
            Screensaver:show()
            assert.are.equal(Device:getScreensaverSuspendWaitTimeout(2, 1000), Device.screensaver_suspend_wait_timeout)
            assert.are.equal(Device.suspend_wait_timeout + 0.5 + 1 + 0.5 + 2, Device.screensaver_suspend_wait_timeout)
            assert.truthy(Screensaver.bb_copy)
            assert.are.equal(2, countScheduled(Screensaver.flashBlack))
            -- the lock widget waits for the last redraw
            local lock = Screensaver.screensaver_lock_widget
            assert.truthy(lock)
            assert.is_false(UIManager:isWidgetShown(lock))

            -- flash: fill black, full refresh, then schedule the restore
            local refresh_full = spy.on(Screen, "refreshFull")
            Screensaver:flashBlack(false)
            assert.spy(refresh_full).was_called(1)
            refresh_full:revert()
            assert.are.equal(1, countScheduled(Screensaver.restoreCover))
            local copy = Screensaver.bb_copy
            -- intermediate restore: keep the copy for the next flash
            Screensaver:restoreCover(false)
            assert.are.equal(copy, Screensaver.bb_copy)
            assert.is_false(UIManager:isWidgetShown(lock))
            -- last restore: free the copy and show the lock widget
            Screensaver:restoreCover(true)
            assert.is_nil(Screensaver.bb_copy)
            assert.is_true(UIManager:isWidgetShown(lock))
            -- a stray restore without a copy only repaints
            Screensaver:restoreCover(false)
            assert.is_nil(Screensaver.bb_copy)
        end)

        it("runs the whole flash sequence through the UI loop", function()
            Screensaver:setup()
            Screensaver:show()
            local widget = Screensaver.screensaver_widget
            -- run the two flashes and their restores
            for _ = 1, 4 do
                fastforward_ui_events()
            end
            assert.are.equal(0, countScheduled(Screensaver.flashBlack))
            assert.are.equal(0, countScheduled(Screensaver.restoreCover))
            assert.is_nil(Screensaver.bb_copy)
            assert.is_true(UIManager:isWidgetShown(widget))
            -- the extended timeout is only for this suspend
            assert.truthy(Device.screensaver_suspend_wait_timeout)
            assert.is_true(Screensaver:close())
            assertCleanState()
        end)

        it("cancels pending flashes when dismissed before they ran (no leak)", function()
            Screensaver:setup()
            Screensaver:show()
            Screensaver:flashBlack(false)
            assert.are.equal(2, countScheduled(Screensaver.flashBlack))
            assert.are.equal(1, countScheduled(Screensaver.restoreCover))
            assert.is_true(Screensaver:close())
            assertCleanState()
        end)

        it("cleanup() frees the framebuffer copy and resets every flag", function()
            Screensaver:setup("poweroff", "Powered off")
            Screensaver:show()
            Device.screen_saver_lock = true
            Screensaver.delayed_close = true
            Screensaver:cleanup()
            -- the widget itself is still up (cleanup only forgets about it)
            assert.is_nil(Screensaver.screensaver_widget)
            assert.is_nil(Screensaver.prefix)
            assert.is_nil(Screensaver.event_message)
            assert.is_nil(Screensaver.show_message)
            assert.is_nil(Screensaver.screensaver_background)
            assertCleanState()
            -- close it for real (onCloseWidget runs cleanup again: must be idempotent)
            for i = #UIManager._window_stack, 1, -1 do
                local w = UIManager._window_stack[i].widget
                if w.name == "ScreenSaver" then
                    UIManager:close(w)
                end
            end
            assertCleanState()
        end)
    end)

    describe("settings dialogs", function()
        local shown
        local show_stub, close_stub
        before_each(function()
            shown = {}
            show_stub = stub(UIManager, "show", function(_, widget) table.insert(shown, widget) end)
            close_stub = stub(UIManager, "close")
        end)
        after_each(function()
            show_stub:revert()
            close_stub:revert()
        end)

        it("sets the sleep screen message", function()
            Screensaver:setMessage(readerui)
            local dialog = shown[1]
            assert.are.equal(Screensaver.default_screensaver_message, dialog:getInputText())
            local buttons = dialog.buttons[1]
            -- Patterns
            local choose = stub(readerui.bookinfo, "chooseExpandStringPattern")
            buttons[2].callback()
            assert.stub(choose).was_called_with(match.is_ref(dialog), match.is_ref(readerui))
            choose:revert()
            -- Set message
            dialog:setInputText("Sleeping %T")
            buttons[3].callback()
            assert.are.equal("Sleeping %T", G_reader_settings:readSetting("screensaver_message"))
            assert.stub(close_stub).was_called_with(match.is_ref(UIManager), match.is_ref(dialog))
            -- An empty message resets to the default
            Screensaver:setMessage(readerui)
            dialog = shown[#shown]
            assert.are.equal("Sleeping %T", dialog:getInputText())
            dialog:setInputText("")
            dialog.buttons[1][3].callback()
            assert.is_nil(G_reader_settings:readSetting("screensaver_message"))
            -- Cancel
            Screensaver:setMessage(readerui)
            dialog = shown[#shown]
            dialog:setInputText("discarded")
            dialog.buttons[1][1].callback()
            assert.is_nil(G_reader_settings:readSetting("screensaver_message"))
        end)

        it("sets the exit sleep screen message", function()
            G_reader_settings:saveSetting("screensaver_exit_message", "Welcome back")
            Screensaver:setMessage(readerui, true)
            local dialog = shown[1]
            assert.are.equal("Welcome back", dialog:getInputText())
            dialog:setInputText("Hi")
            dialog.buttons[1][3].callback()
            assert.are.equal("Hi", G_reader_settings:readSetting("screensaver_exit_message"))
            assert.is_nil(G_reader_settings:readSetting("screensaver_message"))
        end)

        it("sets the stretch limit, disables or fully enables stretching", function()
            local menu = { updateItems = spy.new(function() end) }
            Screensaver:setStretchLimit(menu)
            local spin = shown[1]
            assert.are.equal(8, spin.value)
            spin.callback({ value = 15 })
            assert.are.equal(15, G_reader_settings:readSetting("screensaver_stretch_limit_percentage"))
            assert.is_true(G_reader_settings:isTrue("screensaver_stretch_images"))
            spin.extra_callback()
            assert.is_true(G_reader_settings:isFalse("screensaver_stretch_images"))
            assert.are.equal(15, G_reader_settings:readSetting("screensaver_stretch_limit_percentage"))
            spin.option_callback()
            assert.is_true(G_reader_settings:isTrue("screensaver_stretch_images"))
            assert.is_nil(G_reader_settings:readSetting("screensaver_stretch_limit_percentage"))
            assert.spy(menu.updateItems).was_called(3)
            -- without a menu to refresh
            Screensaver:setStretchLimit()
            shown[2].callback({ value = 3 })
            shown[2].extra_callback()
            shown[2].option_callback()
            assert.spy(menu.updateItems).was_called(3)
        end)

        it("sets the message position", function()
            local menu = { updateItems = spy.new(function() end) }
            Screensaver:setCustomPosition(menu)
            local spin = shown[1]
            assert.are.equal(50, spin.value)
            spin.callback({ value = 85 })
            assert.are.equal(85, G_reader_settings:readSetting("screensaver_message_vertical_position"))
            assert.spy(menu.updateItems).was_called(1)
            Screensaver:setCustomPosition()
            assert.are.equal(85, shown[2].value)
            shown[2].callback({ value = 10 })
            assert.are.equal(10, G_reader_settings:readSetting("screensaver_message_vertical_position"))
        end)

        it("sets the message opacity", function()
            local menu = { updateItems = spy.new(function() end) }
            Screensaver:setMessageOpacity(menu)
            local spin = shown[1]
            assert.are.equal(100, spin.value)
            spin.callback({ value = 35 })
            assert.are.equal(35, G_reader_settings:readSetting("screensaver_message_alpha"))
            assert.spy(menu.updateItems).was_called(1)
            Screensaver:setMessageOpacity()
            shown[2].callback({ value = 60 })
            assert.are.equal(60, G_reader_settings:readSetting("screensaver_message_alpha"))
        end)

        it("chooses the random image folder and the document cover", function()
            local choose = stub(filemanagerutil, "showChooseDialog")
            G_reader_settings:saveSetting("screensaver_dir", img_dir)
            Screensaver.chooseFolder()
            local args = choose.calls[1].vals
            assert.are.equal(img_dir, args[3])
            args[2](alt_dir)
            assert.are.equal(alt_dir, G_reader_settings:readSetting("screensaver_dir"))

            Screensaver.chooseFile()
            args = choose.calls[2].vals
            assert.is_nil(args[3])
            local file_filter = args[5]
            assert.is_true(file_filter(sample_epub))
            assert.is_true(file_filter(image_file))
            assert.is_false(file_filter(img_dir .. "/notes.unknownext"))
            args[2](sample_epub)
            assert.are.equal(sample_epub, G_reader_settings:readSetting("screensaver_document_cover"))
            choose:revert()
        end)
    end)
end)
