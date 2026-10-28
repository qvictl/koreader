describe("DocSettings sidecar locations", function()
    local DataStorage, DocSettings, ffiutil, lfs, util
    local root, hash_dir, docsettings_dir
    local counter = 0

    local function isFile(path)
        return lfs.attributes(path, "mode") == "file"
    end

    local function isDir(path)
        return lfs.attributes(path, "mode") == "directory"
    end

    local function writeFile(path, content)
        local f = assert(io.open(path, "wb"))
        f:write(content)
        f:close()
    end

    local function readLua(path)
        local ok, t = pcall(dofile, path)
        return ok and t or nil
    end

    -- Creates a fresh book (with unique content, so that its partial MD5 is unique too).
    local function newBook(ext)
        counter = counter + 1
        local dir = root .. "/books" .. counter
        util.makePath(dir)
        local path = dir .. "/book" .. counter .. "." .. (ext or "pdf")
        writeFile(path, string.rep("book #" .. counter .. " ", 500))
        return path, dir
    end

    setup(function()
        require("commonrequire")
        DataStorage = require("datastorage")
        DocSettings = require("docsettings")
        ffiutil = require("ffi/util")
        lfs = require("libs/libkoreader-lfs")
        util = require("util")
        root = DataStorage:getDataDir() .. "/docsettings_locations"
        hash_dir = DataStorage:getDocSettingsHashDir()
        docsettings_dir = DataStorage:getDocSettingsDir()
        -- leftovers from an interrupted run would make the "new" books look already opened
        for _, dir in ipairs({ root, hash_dir, docsettings_dir .. root }) do
            if isDir(dir) then
                ffiutil.purgeDir(dir)
            end
        end
        util.makePath(root)
    end)

    teardown(function()
        ffiutil.purgeDir(root)
        ffiutil.purgeDir(hash_dir)
        -- "dir" location sidecars live under docsettings/<root>/booksN/
        if isDir(docsettings_dir .. root) then
            ffiutil.purgeDir(docsettings_dir .. root)
        end
        G_reader_settings:saveSetting("document_metadata_folder", "dir")
        DocSettings.setIsHashLocationEnabled(nil)
    end)

    after_each(function()
        -- commonrequire's default
        G_reader_settings:saveSetting("document_metadata_folder", "dir")
        G_reader_settings:delSetting("document_metadata_arc_folder")
        G_reader_settings:delSetting("document_metadata_arc_on_deletion")
        G_reader_settings:delSetting("document_metadata_arc_on_closing")
        if isDir(hash_dir) then
            ffiutil.purgeDir(hash_dir)
        end
        DocSettings.setIsHashLocationEnabled(nil)
    end)

    describe("paths", function()
        it("maps storage names to their directory", function()
            assert.are.equal(docsettings_dir, DocSettings.getSidecarStorage("dir"))
            assert.are.equal(hash_dir, DocSettings.getSidecarStorage("hash"))
            assert.is_nil(DocSettings.getSidecarStorage("doc"))
        end)

        it("builds hash locations from the partial MD5, and caches the hash", function()
            local book = newBook()
            local hsh = util.partialMD5(book)
            spy.on(util, "partialMD5")
            finally(function() util.partialMD5:revert() end)
            local expected = hash_dir .. "/" .. hsh:sub(1, 2) .. "/" .. hsh .. ".sdr"
            assert.are.equal(expected, DocSettings:getSidecarDir(book, "hash"))
            assert.are.equal(expected, DocSettings:getSidecarDir(book, "hash"))
            assert.spy(util.partialMD5).was.called(1)
        end)

        it("falls back to the book folder when the book cannot be hashed", function()
            local missing = root .. "/nope/missing.epub"
            assert.are.equal(root .. "/nope/missing.sdr", DocSettings:getSidecarDir(missing, "hash"))
            assert.are.equal("", DocSettings:getSidecarDir(nil))
            assert.are.equal("", DocSettings:getSidecarDir(""))
        end)

        it("names sidecar files after the last suffix", function()
            assert.are.equal("metadata.epub.lua", DocSettings.getSidecarFilename("/a/b.fb2.epub"))
            assert.are.equal("metadata._.lua", DocSettings.getSidecarFilename("/a/README"))
        end)

        it("parses legacy history file names", function()
            assert.are.equal("/mnt/us/documents/a b.pdf",
                DocSettings:getFileFromHistory("[#mnt#us#documents#] a b.pdf.lua"))
            -- backups and garbage are ignored
            assert.is_nil(DocSettings:getFileFromHistory("[#mnt#us#] a.pdf.lua.old"))
            assert.is_nil(DocSettings:getFileFromHistory("no_brackets.pdf.lua"))
            assert.are.equal("", DocSettings:getPathFromHistory(nil))
            assert.are.equal("", DocSettings:getNameFromHistory(""))
            assert.are.equal("", DocSettings:getNameFromHistory("no_brackets.lua"))
            assert.are.equal("", DocSettings:getHistoryPath(""))
            assert.is_nil(DocSettings:findSidecarFile(""))
        end)
    end)

    describe("location lookup", function()
        it("writes to the preferred 'dir' location only", function()
            G_reader_settings:saveSetting("document_metadata_folder", "dir")
            local book, book_dir = newBook()
            local ds = DocSettings:open(book)
            ds:saveSetting("x", 1)
            local written = ds:flush()
            assert.are.equal(docsettings_dir .. book_dir .. "/" .. book:match("([^/]+)%.pdf$") .. ".sdr", written)
            local file, location = DocSettings:findSidecarFile(book)
            assert.are.equal(written .. "/metadata.pdf.lua", file)
            assert.are.equal("dir", location)
            assert.is_false(isDir(DocSettings:getSidecarDir(book, "doc")))
            assert.is_falsy(DocSettings.isSidecarFileNotInPreferredLocation(book))
            G_reader_settings:saveSetting("document_metadata_folder", "doc")
            assert.is_true(DocSettings.isSidecarFileNotInPreferredLocation(book))
            -- NB: purge only removes the candidates found when the instance was opened, so reopen.
            DocSettings:open(book):purge()
            assert.is_false(DocSettings:hasSidecarFile(book))
            assert.is_false(isDir(written))
        end)

        it("writes to and finds the 'hash' location", function()
            G_reader_settings:saveSetting("document_metadata_folder", "hash")
            local book = newBook()
            local ds = DocSettings:open(book)
            assert.is_nil(ds.hash_sidecar_dir) -- hash dir does not exist yet
            ds:saveSetting("x", "hashed")
            local written = ds:flush()
            assert.are.equal(DocSettings:getSidecarDir(book, "hash"), written)
            assert.is_true(isFile(written .. "/metadata.pdf.lua"))
            local file, location = DocSettings:findSidecarFile(book)
            assert.are.equal("hash", location)
            assert.are.equal(written .. "/metadata.pdf.lua", file)

            -- From another preferred location, the hash dir is still searched (last) once it exists.
            G_reader_settings:saveSetting("document_metadata_folder", "doc")
            DocSettings.setIsHashLocationEnabled(nil)
            assert.is_true(DocSettings.isHashLocationEnabled())
            file, location = DocSettings:findSidecarFile(book)
            assert.are.equal(written .. "/metadata.pdf.lua", file)
            assert.are.equal("hash", location)
            assert.is_true(DocSettings.isSidecarFileNotInPreferredLocation(book))
            local reopened = DocSettings:open(book)
            assert.are.equal(written, reopened.hash_sidecar_dir)
            assert.are.equal("hashed", reopened:readSetting("x"))

            local found = DocSettings.findSidecarFilesInHashLocation()
            assert.are.equal(1, #found)
            assert.are.same({ written .. "/metadata.pdf.lua" }, found[1])
        end)

        it("pairs hash sidecars with their custom metadata", function()
            G_reader_settings:saveSetting("document_metadata_folder", "hash")
            local book = newBook("epub")
            local ds = DocSettings:open(book)
            ds:saveSetting("x", 1)
            local dir = ds:flush()
            local custom = DocSettings.openSettingsFile()
            custom:saveSetting("custom_props", { title = "T" })
            assert.is_true(custom:flushCustomMetadata(book))
            local found = DocSettings.findSidecarFilesInHashLocation()
            assert.are.same({ { dir .. "/metadata.epub.lua", dir .. "/custom_metadata.lua" } }, found)
        end)

        it("finds legacy history files unless asked not to", function()
            G_reader_settings:saveSetting("document_metadata_folder", "doc")
            local book = newBook()
            local hist = DocSettings:getHistoryPath(book)
            writeFile(hist, "return { legacy = true }")
            finally(function() os.remove(hist) end)
            local file, location = DocSettings:findSidecarFile(book)
            assert.are.equal(hist, file)
            assert.are.equal("hist", location)
            assert.is_true(DocSettings.isSidecarFileNotInPreferredLocation(book))
            assert.is_nil(DocSettings:findSidecarFile(book, true))
            assert.is_true(DocSettings:hasSidecarFile(book))
            assert.is_true(DocSettings:open(book):readSetting("legacy"))
            os.remove(hist)
            assert.is_false(DocSettings:hasSidecarFile(book))
        end)

        it("prefers the primary sidecar over a newer backup", function()
            G_reader_settings:saveSetting("document_metadata_folder", "doc")
            local book = newBook()
            local sdr = DocSettings:getSidecarDir(book, "doc")
            util.makePath(sdr)
            local primary = sdr .. "/metadata.pdf.lua"
            writeFile(primary, "return { from = 'primary' }")
            writeFile(primary .. ".old", "return { from = 'backup' }")
            local now = os.time()
            lfs.touch(primary, now - 600, now - 600)
            lfs.touch(primary .. ".old", now - 60, now - 60)
            local ds = DocSettings:open(book)
            assert.are.equal("primary", ds:readSetting("from"))
            assert.are.equal(primary, ds.source_candidate)
            -- the fudged primary mtime makes both entries tie; the primary still sorts first
            assert.are.equal(primary, ds.candidates[1].path)
            assert.are.equal(ds.candidates[1].mtime, ds.candidates[2].mtime)
        end)
    end)

    describe("openSettingsFile", function()
        it("reads a valid file and tolerates broken or missing ones", function()
            local path = root .. "/settings_file.lua"
            writeFile(path, "return { a = 'b' }")
            local s = DocSettings.openSettingsFile(path)
            assert.are.equal("b", s:readSetting("a"))
            assert.are.equal(path, s.sidecar_file)

            writeFile(path, "this is not lua")
            assert.are.same({}, DocSettings.openSettingsFile(path).data)
            writeFile(path, "return {}")
            assert.are.same({}, DocSettings.openSettingsFile(path).data)
            assert.are.same({}, DocSettings.openSettingsFile(root .. "/missing.lua").data)
            local blank = DocSettings.openSettingsFile()
            assert.are.same({}, blank.data)
            assert.is_nil(blank.sidecar_file)
        end)
    end)

    describe("custom cover and metadata", function()
        it("stores a custom cover next to the book for a new book, lowercasing the suffix", function()
            G_reader_settings:saveSetting("document_metadata_folder", "doc")
            local book = newBook()
            local image = root .. "/image.PNG"
            writeFile(image, "png")
            assert.are.same({ DocSettings:getSidecarDir(book, "doc"), DocSettings:getSidecarDir(book, "dir") },
                DocSettings:getCustomLocationCandidates(book))
            assert.is_true(DocSettings:flushCustomCover(book, image))
            local cover = DocSettings:getSidecarDir(book, "doc") .. "/cover.png"
            assert.is_true(isFile(cover))
            assert.are.equal(cover, DocSettings:findCustomCoverFile(book))
            local ds = DocSettings:open(book)
            assert.are.equal(cover, ds:getCustomCoverFile())
            os.remove(cover)
            -- cached until reset
            assert.are.equal(cover, ds:getCustomCoverFile())
            ds:getCustomCoverFile(true)
            assert.is_false(ds:getCustomCoverFile())
        end)

        it("falls back to the docsettings folder when the book folder is read-only", function()
            G_reader_settings:saveSetting("document_metadata_folder", "doc")
            local book, book_dir = newBook()
            local image = root .. "/image2.jpg"
            writeFile(image, "jpg")
            local dir_sdr = DocSettings:getSidecarDir(book, "dir")
            os.execute("chmod 0555 '" .. book_dir .. "'")
            finally(function()
                os.execute("chmod 0755 '" .. book_dir .. "'")
                if isDir(dir_sdr) then
                    ffiutil.purgeDir(dir_sdr)
                end
            end)
            if lfs.mkdir(book_dir .. "/probe") then
                lfs.rmdir(book_dir .. "/probe")
                pending("running as root: directory permissions are not enforced")
            end
            assert.is_true(DocSettings:flushCustomCover(book, image))
            local custom = DocSettings.openSettingsFile()
            custom:saveSetting("custom_props", { authors = "A" })
            assert.is_true(custom:flushCustomMetadata(book))
            assert.is_false(isDir(DocSettings:getSidecarDir(book, "doc")))
            assert.are.equal(dir_sdr .. "/cover.jpg", DocSettings:findCustomCoverFile(book))
            assert.are.equal(dir_sdr .. "/custom_metadata.lua", DocSettings:findCustomMetadataFile(book))
            assert.are.same({ authors = "A" },
                DocSettings.openSettingsFile(dir_sdr .. "/custom_metadata.lua"):readSetting("custom_props"))
        end)

        it("uses the existing sidecar dir of an opened book, or the preferred location of a new one", function()
            local book = newBook()
            G_reader_settings:saveSetting("document_metadata_folder", "dir")
            assert.are.same({ DocSettings:getSidecarDir(book, "dir") }, DocSettings:getCustomLocationCandidates(book))
            G_reader_settings:saveSetting("document_metadata_folder", "hash")
            assert.are.same({ DocSettings:getSidecarDir(book, "hash") }, DocSettings:getCustomLocationCandidates(book))

            G_reader_settings:saveSetting("document_metadata_folder", "doc")
            local ds = DocSettings:open(book)
            ds:saveSetting("opened", true)
            ds:flush()
            -- even if the preference changes later, custom data goes where the book's metadata is
            G_reader_settings:saveSetting("document_metadata_folder", "dir")
            assert.are.same({ DocSettings:getSidecarDir(book, "doc") }, DocSettings:getCustomLocationCandidates(book))
            DocSettings:open(book):purge()
        end)

        it("flush moves custom files to the new metadata location", function()
            local book = newBook()
            G_reader_settings:saveSetting("document_metadata_folder", "dir")
            local image = root .. "/image3.png"
            writeFile(image, "png")
            assert.is_true(DocSettings:flushCustomCover(book, image))
            local custom = DocSettings.openSettingsFile()
            custom:saveSetting("custom_props", { title = "Custom" })
            assert.is_true(custom:flushCustomMetadata(book))
            local dir_sdr = DocSettings:getSidecarDir(book, "dir")
            assert.is_true(isFile(dir_sdr .. "/cover.png"))

            G_reader_settings:saveSetting("document_metadata_folder", "doc")
            local ds = DocSettings:open(book)
            ds:saveSetting("moved", true)
            local doc_sdr = ds:flush()
            assert.are.equal(DocSettings:getSidecarDir(book, "doc"), doc_sdr)
            assert.is_true(isFile(doc_sdr .. "/cover.png"))
            assert.is_true(isFile(doc_sdr .. "/custom_metadata.lua"))
            assert.is_false(isFile(dir_sdr .. "/cover.png"))
            assert.is_false(isFile(dir_sdr .. "/custom_metadata.lua"))
            -- the emptied old sidecar dir is removed
            assert.is_false(isDir(dir_sdr))
            assert.are.equal(doc_sdr .. "/cover.png", ds:getCustomCoverFile())

            -- a selective purge only removes what it is asked to
            ds:purge(nil, { custom_cover_file = doc_sdr .. "/cover.png" })
            assert.is_false(isFile(doc_sdr .. "/cover.png"))
            assert.is_true(isFile(doc_sdr .. "/custom_metadata.lua"))
            assert.is_true(isFile(doc_sdr .. "/metadata.pdf.lua"))
            ds:purge(nil, { custom_metadata_file = doc_sdr .. "/custom_metadata.lua" })
            assert.is_false(isFile(doc_sdr .. "/custom_metadata.lua"))
            assert.is_true(isFile(doc_sdr .. "/metadata.pdf.lua"))
            -- a non empty book-side sidecar dir is kept
            assert.is_true(isDir(doc_sdr))
            DocSettings:open(book):purge()
            assert.is_false(isDir(doc_sdr))
        end)
    end)

    describe("updateLocation", function()
        local function prepareBook(location)
            G_reader_settings:saveSetting("document_metadata_folder", location)
            local book, book_dir = newBook()
            local ds = DocSettings:open(book)
            ds:saveSetting("last_page", 42)
            ds:saveSetting("partial_md5_checksum", util.partialMD5(book))
            ds:saveSetting("doc_props", { title = "Book" })
            ds:flush()
            local image = root .. "/cover_src.png"
            writeFile(image, "png")
            assert.is_true(DocSettings:flushCustomCover(book, image))
            local custom = DocSettings.openSettingsFile()
            custom:saveSetting("custom_props", { title = "Custom title" })
            assert.is_true(custom:flushCustomMetadata(book))
            return book, book_dir
        end

        it("does nothing for a book without any metadata", function()
            G_reader_settings:saveSetting("document_metadata_folder", "doc")
            local book, book_dir = newBook()
            DocSettings.updateLocation(book, book_dir .. "/renamed.pdf")
            assert.is_false(isDir(book_dir .. "/renamed.sdr"))
            DocSettings.updateLocation(book)
            assert.is_false(isDir(DocSettings:getSidecarDir(book, "doc")))
        end)

        it("moves sidecar, cover and custom metadata on rename", function()
            local book, book_dir = prepareBook("doc")
            local new_book = book_dir .. "/renamed.pdf"
            assert.is_true(os.rename(book, new_book))
            DocSettings.updateLocation(book, new_book)
            local old_sdr = DocSettings:getSidecarDir(book, "doc")
            local new_sdr = DocSettings:getSidecarDir(new_book, "doc")
            assert.is_false(isDir(old_sdr))
            local moved = readLua(new_sdr .. "/metadata.pdf.lua")
            assert.are.equal(42, moved.last_page)
            assert.are.equal(new_book, moved.doc_path)
            assert.is_true(isFile(new_sdr .. "/cover.png"))
            assert.are.same({ title = "Custom title" },
                DocSettings.openSettingsFile(new_sdr .. "/custom_metadata.lua"):readSetting("custom_props"))
        end)

        it("keeps the original metadata on copy", function()
            local book, book_dir = prepareBook("doc")
            local copy = book_dir .. "/copy.pdf"
            ffiutil.copyFile(book, copy)
            DocSettings.updateLocation(book, copy, true)
            local old_sdr = DocSettings:getSidecarDir(book, "doc")
            local new_sdr = DocSettings:getSidecarDir(copy, "doc")
            assert.is_true(isFile(old_sdr .. "/metadata.pdf.lua"))
            assert.is_true(isFile(old_sdr .. "/cover.png"))
            assert.is_true(isFile(new_sdr .. "/metadata.pdf.lua"))
            assert.is_true(isFile(new_sdr .. "/cover.png"))
            assert.is_true(isFile(new_sdr .. "/custom_metadata.lua"))
        end)

        it("copies custom files even when the book has no sidecar file", function()
            G_reader_settings:saveSetting("document_metadata_folder", "doc")
            local book, book_dir = newBook()
            local image = root .. "/cover_only.png"
            writeFile(image, "png")
            assert.is_true(DocSettings:flushCustomCover(book, image))
            local new_book = book_dir .. "/moved.pdf"
            assert.is_true(os.rename(book, new_book))
            DocSettings.updateLocation(book, new_book)
            assert.is_true(isFile(DocSettings:getSidecarDir(new_book, "doc") .. "/cover.png"))
            assert.is_false(isDir(DocSettings:getSidecarDir(book, "doc")))
        end)

        it("leaves hash-located metadata alone on rename", function()
            local book, book_dir = prepareBook("hash")
            local hash_sdr = DocSettings:getSidecarDir(book, "hash")
            local new_book = book_dir .. "/renamed_hash.pdf"
            assert.is_true(os.rename(book, new_book))
            DocSettings.updateLocation(book, new_book)
            assert.is_true(isFile(hash_sdr .. "/metadata.pdf.lua"))
            assert.is_true(isFile(hash_sdr .. "/cover.png"))
            assert.is_false(isDir(book_dir .. "/renamed_hash.sdr"))
        end)

        it("purges everything on delete, including the cache file", function()
            local book = prepareBook("doc")
            local cache_file = root .. "/cre_cache_file"
            writeFile(cache_file, "cache")
            local ds = DocSettings:open(book)
            ds:saveSetting("cache_file_path", cache_file)
            ds:flush()
            DocSettings.updateLocation(book)
            assert.is_false(isDir(DocSettings:getSidecarDir(book, "doc")))
            assert.is_false(isFile(cache_file))
            assert.is_false(DocSettings:hasSidecarFile(book))
        end)

        it("archives metadata on delete when asked to", function()
            local arc_dir = root .. "/arc"
            util.makePath(arc_dir)
            G_reader_settings:saveSetting("document_metadata_arc_folder", arc_dir)
            local book = prepareBook("doc")
            local md5 = util.partialMD5(book)
            assert.is_falsy(DocSettings.getSettingsArcFile(md5, true))
            G_reader_settings:makeTrue("document_metadata_arc_on_deletion")
            DocSettings.updateLocation(book)
            local arc_file = DocSettings.getSettingsArcFile(md5, true)
            assert.are.equal(arc_dir .. "/" .. md5 .. ".lua", arc_file)
            local arc = readLua(arc_file)
            assert.are.equal(42, arc.last_page)
            assert.are.same({ title = "Custom title" }, arc.metadata_arc.custom_props)
            assert.is_nil(arc.metadata_arc.on_closing)
            assert.is_string(arc.metadata_arc.datetime)
        end)

        it("drops a stale archive when archiving on delete is disabled", function()
            local arc_dir = root .. "/arc2"
            util.makePath(arc_dir)
            G_reader_settings:saveSetting("document_metadata_arc_folder", arc_dir)
            local book = prepareBook("doc")
            local arc_file = DocSettings.getSettingsArcFile(util.partialMD5(book))
            writeFile(arc_file, "return { stale = true }")
            writeFile(arc_file .. ".old", "return { stale = true }")
            DocSettings.updateLocation(book)
            assert.is_false(isFile(arc_file))
            assert.is_false(isFile(arc_file .. ".old"))
        end)
    end)

    describe("saveSettingsArcFile on closing", function()
        it("only archives when enabled, and requires an identifiable book", function()
            local arc_dir = root .. "/arc3"
            util.makePath(arc_dir)
            G_reader_settings:saveSetting("document_metadata_arc_folder", arc_dir)
            G_reader_settings:saveSetting("document_metadata_folder", "doc")
            local book = newBook()
            local md5 = util.partialMD5(book)
            local ds = DocSettings:open(book)
            ds:saveSetting("doc_props", { title = "Book" })
            ds:saveSetting("partial_md5_checksum", md5)

            DocSettings.saveSettingsArcFile(ds, nil, true)
            assert.is_falsy(DocSettings.getSettingsArcFile(md5, true))

            G_reader_settings:makeTrue("document_metadata_arc_on_closing")
            ds:delSetting("partial_md5_checksum")
            DocSettings.saveSettingsArcFile(ds, nil, true)
            assert.is_falsy(DocSettings.getSettingsArcFile(md5, true))

            ds:saveSetting("partial_md5_checksum", md5)
            DocSettings.saveSettingsArcFile(ds, nil, true)
            local arc = readLua(DocSettings.getSettingsArcFile(md5, true))
            assert.is_true(arc.metadata_arc.on_closing)
            assert.is_nil(arc.metadata_arc.custom_props)
            -- the in-memory settings are left untouched
            assert.is_nil(ds:readSetting("metadata_arc"))
        end)

        it("has no archive path without an archive folder or checksum", function()
            assert.is_nil(DocSettings.getSettingsArcFile("abc"))
            G_reader_settings:saveSetting("document_metadata_arc_folder", root)
            assert.is_nil(DocSettings.getSettingsArcFile(nil))
            assert.are.equal(root .. "/abc.lua", DocSettings.getSettingsArcFile("abc"))
        end)
    end)
end)
