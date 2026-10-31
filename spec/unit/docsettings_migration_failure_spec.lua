describe("DocSettings migration failures", function()
    local DocSettings, util, ffiutil, lfs
    local root, book, original, source, destination, old_setting
    local cover = "original cover bytes"
    local metadata = 'return { custom_props = { title = "Original title" } }'

    local function write(path, content)
        local file = assert(io.open(path, "wb"))
        assert(file:write(content))
        assert(file:close())
    end

    setup(function()
        require("commonrequire")
        DocSettings = require("docsettings")
        util = require("util")
        ffiutil = require("ffi/util")
        lfs = require("libs/libkoreader-lfs")
    end)

    before_each(function()
        old_setting = G_reader_settings:readSetting("document_metadata_folder")
        root = os.tmpname()
        assert(os.remove(root))
        assert(lfs.mkdir(root))
        book = root .. "/original.epub"
        write(book, "synthetic book")
        G_reader_settings:saveSetting("document_metadata_folder", "doc")
        local doc = DocSettings:open(book)
        doc:saveSetting("last_page", 42)
        doc:saveSetting("annotations", { { text = "Important note", note = "Preserve me" } })
        source = assert(doc:flush())
        write(source .. "/cover.png", cover)
        write(source .. "/custom_metadata.lua", metadata)
        original = assert(util.readFromFile(source .. "/metadata.epub.lua"))
    end)

    after_each(function()
        if destination and lfs.attributes(destination, "mode") == "directory" then
            os.execute("chmod 0755 '" .. destination .. "'")
        end
        G_reader_settings:saveSetting("document_metadata_folder", old_setting)
        if destination and lfs.attributes(destination) then ffiutil.purgeDir(destination) end
        ffiutil.purgeDir(root)
        destination = nil
    end)

    it("keeps original custom files when flush cannot copy to its new location", function()
        G_reader_settings:saveSetting("document_metadata_folder", "dir")
        destination = DocSettings:getSidecarDir(book, "dir")
        util.makePath(destination)
        -- The settings file is writable, but new custom files cannot be created.
        write(destination .. "/metadata.epub.lua", original)
        os.execute("chmod 0555 '" .. destination .. "'")
        if lfs.mkdir(destination .. "/probe") then
            lfs.rmdir(destination .. "/probe")
            pending("directory permissions are not enforced")
        end
        local doc = DocSettings:open(book)
        doc:saveSetting("last_page", 43)
        assert.are.equal(destination, doc:flush())
        assert.are.equal(cover, util.readFromFile(source .. "/cover.png"))
        assert.are.equal(metadata, util.readFromFile(source .. "/custom_metadata.lua"))
        assert.are.equal(source .. "/cover.png", doc:getCustomCoverFile())
        assert.are.equal(source .. "/custom_metadata.lua", doc:getCustomMetadataFile())
        -- Once the destination is writable, the same instance can finish the move.
        os.execute("chmod 0755 '" .. destination .. "'")
        assert.are.equal(destination, doc:flush())
        assert.are.equal(cover, util.readFromFile(destination .. "/cover.png"))
        assert.are.equal(metadata, util.readFromFile(destination .. "/custom_metadata.lua"))
        assert.is_nil(lfs.attributes(source))
    end)

    for _, blocked in ipairs({ "cover.png", "custom_metadata.lua" }) do
        it("keeps a custom file when flush finds a destination directory named " .. blocked, function()
            local doc = DocSettings:open(book)
            -- Cache the actual source before introducing the cover-name collision.
            assert.are.equal(source .. "/cover.png", doc:getCustomCoverFile())
            assert.are.equal(source .. "/custom_metadata.lua", doc:getCustomMetadataFile())
            G_reader_settings:saveSetting("document_metadata_folder", "dir")
            destination = DocSettings:getSidecarDir(book, "dir")
            util.makePath(destination .. "/" .. blocked)
            local bytes = assert(util.readFromFile(source .. "/" .. blocked))
            assert.are.equal(destination, doc:flush())
            assert.are.equal(bytes, util.readFromFile(source .. "/" .. blocked))
            assert(lfs.rmdir(destination .. "/" .. blocked))
            assert.are.equal(destination, doc:flush())
            assert.are.equal(cover, util.readFromFile(destination .. "/cover.png"))
            assert.are.equal(metadata, util.readFromFile(destination .. "/custom_metadata.lua"))
            assert.is_nil(lfs.attributes(source))
        end)
    end

    for _, blocked in ipairs({ "cover.png", "custom_metadata.lua" }) do
        it("keeps all source metadata if rename cannot copy " .. blocked, function()
            local renamed = root .. "/renamed.epub"
            assert(os.rename(book, renamed))
            destination = DocSettings:getSidecarDir(renamed, "doc")
            util.makePath(destination .. "/" .. blocked)
            DocSettings.updateLocation(book, renamed)
            assert.are.equal(original, util.readFromFile(source .. "/metadata.epub.lua"))
            assert.are.equal(cover, util.readFromFile(source .. "/cover.png"))
            assert.are.equal(metadata, util.readFromFile(source .. "/custom_metadata.lua"))
            assert(lfs.rmdir(destination .. "/" .. blocked))
            DocSettings.updateLocation(book, renamed)
            assert.is_nil(lfs.attributes(source))
            local reopened = DocSettings:open(renamed)
            assert.are.equal(42, reopened:readSetting("last_page"))
            assert.are.equal("Preserve me", reopened:readSetting("annotations")[1].note)
            assert.are.equal(cover, util.readFromFile(destination .. "/cover.png"))
            assert.are.equal(metadata, util.readFromFile(destination .. "/custom_metadata.lua"))
        end)
    end

    it("keeps the only annotations when the destination settings file cannot be saved", function()
        local renamed = root .. "/renamed.epub"
        assert(os.rename(book, renamed))
        G_reader_settings:saveSetting("document_metadata_folder", "dir")
        destination = DocSettings:getSidecarDir(renamed, "dir")
        util.makePath(destination .. "/metadata.epub.lua")
        DocSettings.updateLocation(book, renamed)
        assert.are.equal(original, util.readFromFile(source .. "/metadata.epub.lua"))
        assert.are.equal(cover, util.readFromFile(source .. "/cover.png"))
        assert.are.equal(metadata, util.readFromFile(source .. "/custom_metadata.lua"))
        assert(lfs.rmdir(destination .. "/metadata.epub.lua"))
        DocSettings.updateLocation(book, renamed)
        local reopened = DocSettings:open(renamed)
        assert.are.equal(42, reopened:readSetting("last_page"))
        assert.are.equal("Preserve me", reopened:readSetting("annotations")[1].note)
        assert.is_nil(lfs.attributes(source))
    end)

    for _, operation in ipairs({ "rename", "copy", "same path" }) do
        it("preserves shared sidecar files during " .. operation, function()
            local target = operation == "same path" and book or root .. "/original.pdf"
            if operation == "rename" then
                assert(os.rename(book, target))
            elseif operation == "copy" then
                write(target, "synthetic book copy")
            end
            DocSettings.updateLocation(book, target, operation == "copy")
            assert.are.equal(cover, util.readFromFile(source .. "/cover.png"))
            assert.are.equal(metadata, util.readFromFile(source .. "/custom_metadata.lua"))
            local reopened = DocSettings:open(target)
            assert.are.equal(42, reopened:readSetting("last_page"))
            assert.are.equal("Preserve me", reopened:readSetting("annotations")[1].note)
            if operation == "copy" then
                assert.are.equal(original, util.readFromFile(source .. "/metadata.epub.lua"))
            end
        end)
    end

    it("copies metadata without removing the source", function()
        local target = root .. "/copied.epub"
        write(target, "synthetic book copy")
        destination = DocSettings:getSidecarDir(target, "doc")
        DocSettings.updateLocation(book, target, true)
        assert.are.equal(original, util.readFromFile(source .. "/metadata.epub.lua"))
        assert.are.equal(cover, util.readFromFile(source .. "/cover.png"))
        assert.are.equal(metadata, util.readFromFile(source .. "/custom_metadata.lua"))
        assert.are.equal(cover, util.readFromFile(destination .. "/cover.png"))
        assert.are.equal(metadata, util.readFromFile(destination .. "/custom_metadata.lua"))
        assert.are.equal(42, DocSettings:open(target):readSetting("last_page"))
    end)

    it("migrates custom-only sidecars without inventing document settings", function()
        assert(os.remove(source .. "/metadata.epub.lua"))
        local target = root .. "/renamed.epub"
        assert(os.rename(book, target))
        destination = DocSettings:getSidecarDir(target, "doc")
        util.makePath(destination .. "/custom_metadata.lua")
        DocSettings.updateLocation(book, target)
        assert.are.equal(cover, util.readFromFile(source .. "/cover.png"))
        assert.are.equal(metadata, util.readFromFile(source .. "/custom_metadata.lua"))
        assert(lfs.rmdir(destination .. "/custom_metadata.lua"))
        DocSettings.updateLocation(book, target)
        assert.are.equal(cover, util.readFromFile(destination .. "/cover.png"))
        assert.are.equal(metadata, util.readFromFile(destination .. "/custom_metadata.lua"))
        assert.is_false(DocSettings:hasSidecarFile(target))
        assert.is_nil(lfs.attributes(source))
    end)

end)
