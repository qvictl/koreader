-- Unit tests for document/credocument: crengine cache setup (disk cache size,
-- storage factor, legacy cache dir), the per-document call cache and its
-- statistics, non-linear flows handling, xpointer / position / text helpers,
-- page map and toc, and the rendering setters (checked through crengine's
-- own properties).
describe("CreDocument", function()
    local CreDocument, DataStorage, DocumentRegistry, ReaderUI, Blitbuffer, Screen, cre, lfs, logger
    local sample_epub = "spec/front/unit/data/juliet.epub"
    local other_epub = "spec/front/unit/data/leaves.epub"
    local readerui, doc

    local function anyNonWhitePixel(bb)
        for y = 0, bb:getHeight() - 1, 4 do
            for x = 0, bb:getWidth() - 1, 4 do
                if bb:getPixel(x, y):getColor8().a < 0xF0 then
                    return true
                end
            end
        end
        return false
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        -- Must be set before opening, so that the call cache keeps statistics
        G_reader_settings:makeTrue("use_cre_call_cache_log_stats")
        Blitbuffer = require("ffi/blitbuffer")
        CreDocument = require("document/credocument")
        DataStorage = require("datastorage")
        DocumentRegistry = require("document/documentregistry")
        ReaderUI = require("apps/reader/readerui")
        Screen = require("device").screen
        lfs = require("libs/libkoreader-lfs")
        logger = require("logger")
        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(sample_epub),
        }
        doc = readerui.document
        cre = CreDocument:engineInit()
    end)

    teardown(function()
        readerui:closeDocument()
        readerui:onClose()
        G_reader_settings:delSetting("use_cre_call_cache_log_stats")
        G_reader_settings:delSetting("use_cre_call_cache")
    end)

    describe("engine and disk cache", function()
        it("initializes the engine once", function()
            assert.are.equal(require("libs/libkoreader-cre"), cre)
            assert.are.equal(cre, CreDocument:engineInit())
        end)

        it("sizes the disk cache from the settings, and removes the legacy cache dir", function()
            local init_cache = stub(cre, "initCache")
            local MemoryTuning = require("memorytuning")
            assert.is_true(lfs.mkdir("./cr3cache") or lfs.attributes("./cr3cache", "mode") == "directory")
            CreDocument.cacheInit()
            assert.is_nil(lfs.attributes("./cr3cache", "mode"))
            -- defaults: 64 MB, compressed, storage factor depending on the device memory
            assert.stub(init_cache).was_called_with(DataStorage:getDataDir() .. "/cache/cr3cache",
                64 * 1024 * 1024, true, MemoryTuning:pick(40, 4))
            -- low memory users can shrink everything
            G_reader_settings:saveSetting("cre_disk_cache_max_size", 10)
            G_reader_settings:makeFalse("cre_compress_cached_data")
            G_reader_settings:saveSetting("cre_storage_size_factor", 1)
            CreDocument.cacheInit()
            assert.stub(init_cache).was_called_with(DataStorage:getDataDir() .. "/cache/cr3cache",
                10 * 1024 * 1024, false, 1)
            init_cache:revert()
            G_reader_settings:delSetting("cre_disk_cache_max_size")
            G_reader_settings:delSetting("cre_compress_cached_data")
            G_reader_settings:delSetting("cre_storage_size_factor")
        end)

        it("keeps a cache file for the open document", function()
            assert.is_true(doc:hasCacheFile())
            local path = doc:getCacheFilePath()
            assert.truthy(path:find(DataStorage:getDataDir() .. "/cache/cr3cache/juliet.epub.", 1, true))
            assert.is_false(doc:isBuiltDomStale())
            assert.is_false(doc:isRerenderingDelayed())
            doc:invalidateCacheFile()
            assert.is_true(doc:isCacheFileStale())
        end)

        it("reports DOM versions", function()
            assert.are.equal(20171225, doc:getOldestDomVersion())
            assert.is_true(doc:getDomVersionWithNormalizedXPointers() > doc:getOldestDomVersion())
            assert.is_true(doc:getLatestDomVersion() >= doc:getDomVersionWithNormalizedXPointers())
        end)

        it("fails cleanly when crengine cannot create a document view", function()
            local orig = cre.newDocView
            cre.newDocView = function() error("cannot allocate view") end
            local warn = spy.on(logger, "warn")
            local failed = DocumentRegistry:openDocument(other_epub)
            cre.newDocView = orig
            assert.is_nil(failed)
            assert.spy(warn).was_called()
            warn:revert()
            assert.is_nil(DocumentRegistry:getReferenceCount(other_epub))
        end)

        it("does not render nor load an unrecognized document", function()
            local broken = DataStorage:getDataDir() .. "/credocument_broken.epub"
            local f = assert(io.open(broken, "w"))
            f:write("PK\3\4 not really a zip")
            f:close()
            local bad = DocumentRegistry:openDocument(broken)
            assert.truthy(bad)
            assert.are.equal(0, bad:getDocumentRenderingHash())
            -- getCoverPageImage() needs a loaded document
            local load = stub(bad, "loadDocument", false)
            assert.is_nil(bad:getCoverPageImage())
            load:revert()
            bad:close()
            os.remove(broken)
        end)
    end)

    describe("call cache", function()
        it("caches global getters until something is set", function()
            doc:resetCallCache()
            assert.is_nil(next(doc._global_call_cache))
            local props = doc:getDocumentProps()
            assert.are.equal("Romeo and Juliet", props.title)
            assert.are.equal(props, doc:getDocumentProps()) -- same table: served from the cache
            assert.is_not_nil(next(doc._global_call_cache))
            -- any setter invalidates the whole cache
            doc:setFontSize(doc:getFontSize())
            assert.is_nil(next(doc._global_call_cache))
            assert.are_not.equal(props, doc:getDocumentProps())
            local hits = doc._call_cache_stats.getDocumentProps[1]
            doc:getDocumentProps()
            assert.are.equal(hits + 1, doc._call_cache_stats.getDocumentProps[1])
            -- getters returning several values are cached too
            local y, x = doc:getPosFromXPointer(doc:getPageXPointer(3))
            local y2, x2 = doc:getPosFromXPointer(doc:getPageXPointer(3))
            assert.are.equal(y, y2)
            assert.are.equal(x, x2)
        end)

        it("caches per page/position getters under the current tag", function()
            doc:gotoPage(5)
            assert.are.equal("page5", doc._callCacheGetCurrentTag())
            local links = doc:getPageLinks()
            assert.are.equal(11, #links)
            assert.are.equal(links, doc:getPageLinks()) -- cached for this page
            doc:gotoPage(6)
            assert.are.equal("page6", doc._callCacheGetCurrentTag())
            assert.are.equal(0, #doc:getPageLinks())
            -- back to page 5: the tag cache is still there (LRU of 10 tags)
            doc:gotoPage(5)
            assert.are.equal(links, doc:getPageLinks())
            doc:gotoPage(2, true)
            assert.are.equal("page2true", doc._callCacheGetCurrentTag())
            local pos = doc:getCurrentPos()
            doc:gotoPos(pos)
            assert.are.equal("pos" .. pos, doc._callCacheGetCurrentTag())
            assert.are.equal(pos, doc:getCurrentPos())
            -- a 11th tag evicts the least recently used one
            for page = 10, 20 do
                doc:gotoPage(page)
            end
            assert.are.equal(10, doc._tag_list_call_cache:used_slots())
        end)

        it("only redraws the page buffer when the page changed or was trashed", function()
            local rect = { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
            local bb = Blitbuffer.new(rect.w, rect.h, Blitbuffer.TYPE_BBRGB32)
            bb:fill(Blitbuffer.COLOR_WHITE)
            local stats = doc._call_cache_stats
            doc:drawCurrentViewByPage(bb, 0, 0, rect, 3)
            local draws = stats.drawCurrentView[3]
            local light = stats.drawCurrentView[1]
            assert.is_true(anyNonWhitePixel(bb))
            -- same page: blit the buffer again
            doc:drawCurrentViewByPage(bb, 0, 0, rect, 3)
            assert.are.equal(draws, stats.drawCurrentView[3])
            assert.are.equal(light + 1, stats.drawCurrentView[1])
            -- highlighting trashes the buffer
            doc:highlightXPointer(doc:getPageXPointer(3))
            doc:drawCurrentViewByPage(bb, 0, 0, rect, 3)
            assert.are.equal(draws + 1, stats.drawCurrentView[3])
            doc:highlightXPointer() -- clear
            -- by position
            local pos = doc:getCurrentPos()
            doc:drawCurrentViewByPos(bb, 0, 0, rect, pos)
            assert.are.equal("pos" .. pos, doc._callCacheGetCurrentTag())
            assert.are.equal(draws + 2, stats.drawCurrentView[3])
            -- a buffer of another size is reallocated
            local small = { x = 0, y = 0, w = 100, h = 120 }
            local small_bb = Blitbuffer.new(small.w, small.h, Blitbuffer.TYPE_BBRGB32)
            doc:drawCurrentViewByPos(small_bb, 0, 0, small, pos)
            assert.are.equal(100, doc.buffer:getWidth())
            -- changing color rendering drops the buffer
            doc:updateColorRendering()
            assert.is_nil(doc.buffer)
            -- no page sync while selecting across pages
            doc.no_page_sync = true
            local tag = doc._callCacheGetCurrentTag()
            doc:drawCurrentViewByPage(bb, 0, 0, rect, 42)
            assert.are.equal(tag, doc._callCacheGetCurrentTag())
            doc.no_page_sync = nil
            bb:free()
            small_bb:free()
        end)

        it("formats its statistics", function()
            doc:getDocumentProps()
            doc:getDocumentProps()
            local s = doc.getCallCacheStatistics()
            assert.truthy(s:find("^CRE call cache content:"))
            assert.truthy(s:find("\n  global: %d+ items"))
            assert.truthy(s:find("\n    tags: %d+ items"))
            assert.truthy(s:find("\n    getDocumentProps: %d+/%d+ hits"))
            assert.truthy(s:find("By call times %(hits | misses%):"))
            assert.truthy(s:find("\n  cpu time used: [%d.]+s, saved: "))
        end)

        it("dumps its statistics when the document is closed", function()
            local other = DocumentRegistry:openDocument(other_epub)
            other:loadDocument()
            other:getDocumentProps()
            other:getDocumentProps()
            local info = spy.on(logger, "info")
            other:close()
            local dumped = false
            for _, call in ipairs(info.calls) do
                if type(call.vals[1]) == "string" and call.vals[1]:find("^cre call cache statistics") then
                    dumped = true
                    assert.truthy(call.vals[1]:find("getDocumentProps: 1/2 hits", 1, true))
                end
            end
            info:revert()
            assert.is_true(dumped)
            assert.is_nil(DocumentRegistry:getReferenceCount(other_epub))
        end)

        it("can be disabled", function()
            G_reader_settings:makeFalse("use_cre_call_cache")
            local other = DocumentRegistry:openDocument(other_epub)
            G_reader_settings:delSetting("use_cre_call_cache")
            assert.is_nil(rawget(other, "getToc"))
            assert.is_nil(rawget(other, "_callCacheReset"))
            assert.is_nil(other.getCallCacheStatistics)
            other:close()
        end)
    end)

    describe("non-linear flows", function()
        -- pages 1-3: linear, 4-5: flow 1, 6-8: linear, 9-10: flow 2 (at the end)
        local page_flows = { 0, 0, 0, 1, 1, 0, 0, 0, 2, 2 }
        local fake
        before_each(function()
            fake = setmetatable({
                hide_nonlinear_flows = true,
                flows = {},
                page_in_flow = {},
            }, { __index = CreDocument })
            fake.getPageCount = function() return #page_flows end
            fake.hasNonLinearFlows = function() return true end
            fake.getPageFlow = function(_, page) return page_flows[page] or -1 end
            fake:cacheFlows()
        end)

        it("caches the flows", function()
            assert.is_true(fake:hasHiddenFlows())
            assert.are.same({ 1, 6 }, fake.flows[0])
            assert.are.same({ 4, 2 }, fake.flows[1])
            assert.are.same({ 9, 2 }, fake.flows[2])
            assert.are.equal(8, fake:getLastLinearPage())
            assert.are.equal(1, fake:getFirstPageInFlow(0))
            assert.are.equal(2, fake:getTotalPagesInFlow(2))
            assert.are.same({ 1, 2, 3, 1, 2, 4, 5, 6, 1, 2 }, fake.page_in_flow)
            assert.are.equal(5, fake:getPageNumberInFlow(7))
        end)

        it("skips non-linear flows when turning pages forward", function()
            assert.are.equal(1, fake:getNextPage(0))
            assert.are.equal(2, fake:getNextPage(1))
            assert.are.equal(6, fake:getNextPage(3)) -- skips flow 1
            assert.are.equal(5, fake:getNextPage(4)) -- stays in flow 1
            assert.are.equal(6, fake:getNextPage(5)) -- back to the linear flow
            assert.are.equal(0, fake:getNextPage(8)) -- only flow 2 left: end
            assert.are.equal(10, fake:getNextPage(9))
            assert.are.equal(0, fake:getNextPage(10))
            assert.are.equal(0, fake:getNextPage(-1))
        end)

        it("skips non-linear flows when turning pages backward", function()
            assert.are.equal(8, fake:getPrevPage(0))
            assert.are.equal(3, fake:getPrevPage(6)) -- skips flow 1
            assert.are.equal(4, fake:getPrevPage(5))
            assert.are.equal(8, fake:getPrevPage(9)) -- flow 2 goes back to the linear flow
            assert.are.equal(0, fake:getPrevPage(1)) -- went beyond the first page
            assert.are.equal(0, fake:getPrevPage(11))
            assert.are.equal(0, fake:getPrevPage(-1))
        end)

        it("counts the pages left", function()
            -- 3, 6, 7, 8
            assert.are.equal(4, fake:getTotalPagesLeft(2))
            assert.are.equal(0, fake:getTotalPagesLeft(8))
            -- in a trailing flow: only that flow counts
            assert.are.equal(1, fake:getTotalPagesLeft(9))
            assert.are.equal(0, fake:getTotalPagesLeft(10))
        end)

        it("treats every page as linear when flows are not hidden", function()
            fake.hide_nonlinear_flows = false
            fake:cacheFlows()
            assert.is_false(fake:hasHiddenFlows())
            assert.are.same({ 1, 10 }, fake.flows[0])
            assert.are.equal(10, fake:getLastLinearPage())
            assert.are.equal(7, fake:getPageNumberInFlow(7))
        end)

        it("asks crengine only in 1-page page mode with hidden flows", function()
            assert.is_false(doc:hasNonLinearFlows())
            local pages = doc:getPageCount()
            doc:setHideNonlinearFlows(true)
            assert.is_true(doc.hide_nonlinear_flows)
            -- this book has no non-linear flow: crengine reports the linear flow
            assert.are.equal(0, doc:getPageFlow(1))
            -- setViewMode() rebuilds the flows when they are hidden
            doc:setViewMode("scroll")
            assert.are.equal(doc.SCROLL_VIEW_MODE, doc._view_mode)
            assert.are.equal(0, doc:getPageFlow(1))
            assert.are.same({ 1, doc:getPageCount() }, doc.flows[0])
            doc:setViewMode("page")
            assert.are.equal(doc.PAGE_VIEW_MODE, doc._view_mode)
            doc:setViewMode(nil) -- no-op
            assert.are.equal(doc.PAGE_VIEW_MODE, doc._view_mode)
            doc:setHideNonlinearFlows(false)
            doc:setHideNonlinearFlows(false) -- unchanged: no-op
            assert.is_false(doc.hide_nonlinear_flows)
            doc:cacheFlows()
            assert.are.equal(pages, doc:getPageCount())
            assert.are.equal(pages, doc:getLastLinearPage())
        end)
    end)

    describe("xpointers and positions", function()
        local xp5, xp6
        setup(function()
            xp5 = doc:getPageXPointer(5)
            xp6 = doc:getPageXPointer(6)
        end)

        it("goes to xpointers and pages", function()
            doc:gotoXPointer(xp6)
            assert.are.equal(6, doc:getCurrentPage())
            assert.are.equal(xp6, doc:getXPointer())
            doc:gotoPage(5)
            assert.are.equal(xp5, doc:getXPointer())
            assert.are.equal(5, doc:getPageFromXPointer(xp5))
            assert.is_true(doc:isXPointerInDocument(xp5))
            assert.is_false(doc:isXPointerInDocument("/body/DocFragment[99]/body/div[42]"))
            assert.is_true(doc:isXPointerInCurrentPage(xp5))
            assert.is_false(doc:isXPointerInCurrentPage(xp6))
            assert.are.equal(xp5, doc:getNormalizedXPointer(xp5))
            assert.are.equal(1, doc:compareXPointers(xp5, xp6))
            assert.are.equal(-1, doc:compareXPointers(xp6, xp5))
            assert.are.equal(0, doc:compareXPointers(xp5, xp5))
        end)

        it("converts xpointers to EPUB CFIs", function()
            assert.are.equal("epubcfi(/6/2!/4/2/2)", doc:getPageEPubCFI(1))
            doc:gotoPage(1)
            assert.are.equal("epubcfi(/6/2!/4/2/2)", doc:getEPubCFI())
            assert.are.equal(doc:getPageEPubCFI(5), doc:getEPubCFIFromXPointer(xp5))
            local range = doc:getEPubCFIRangeFromXPointers(xp5, xp6)
            assert.truthy(range:find("^epubcfi%("))
        end)

        it("goes to document positions", function()
            doc:gotoPage(6)
            local y6 = doc:getCurrentPos()
            assert.is_true(doc:getPosFromXPointer(xp6) >= y6)
            doc:gotoPage(1)
            doc:gotoPos(y6)
            assert.are.equal(y6, doc:getCurrentPos())
            assert.are.equal(6, doc:getCurrentPage())
            -- crengine internal history is disabled: back/forward do not move
            doc:goBack()
            doc:goForward()
            assert.are.equal(6, doc:getCurrentPage())
        end)

        it("computes the screen position of an xpointer", function()
            doc:gotoPage(5)
            local margins = doc:getPageMargins()
            local doc_y, doc_x = doc:getPosFromXPointer(xp5)
            local screen_y, screen_x = doc:getScreenPositionFromXPointer(xp5)
            assert.are.equal(doc_y - doc:getCurrentPos() + margins.top + doc:getHeaderHeight(), screen_y)
            assert.are.equal(doc_x + margins.left, screen_x)
            -- an xpointer on a later page is below the screen
            assert.is_true(doc:getScreenPositionFromXPointer(xp6) > screen_y)
            assert.is_number(doc:getPageOffsetX(5))
        end)

        it("accounts for the second page in 2-page mode", function()
            doc:setVisiblePageCount(2)
            assert.are.equal(2, doc:getVisiblePageCount())
            assert.are.equal(1, doc:getVisiblePageNumberCount())
            doc:gotoPage(3)
            local internal = doc:getCurrentPage(true)
            doc:gotoPage(internal + 1, true)
            local right_xp = doc:getXPointer()
            doc:gotoPage(internal, true)
            local screen_y, screen_x = doc:getScreenPositionFromXPointer(right_xp)
            assert.is_true(screen_x > Screen:getWidth() / 2)
            assert.is_true(screen_y >= 0 and screen_y < Screen:getHeight())
            doc:setVisiblePageCount(1)
            assert.are.equal(1, doc:getVisiblePageCount())
        end)
    end)

    describe("text, words and links", function()
        local pos = { x = 200, y = 300 }

        it("finds the word at a position, its box and xpointers", function()
            doc:gotoPage(5)
            local wordbox = doc:getWordFromPosition(pos, true)
            assert.truthy(wordbox)
            assert.is_number(wordbox.page)
            assert.truthy(wordbox.word:find("%S"))
            assert.is_true(wordbox.sbox.w > 0 and wordbox.sbox.h > 0)
            assert.is_true(wordbox.sbox:contains({ x = pos.x, y = pos.y, w = 1, h = 1 }) or
                           math.abs(wordbox.sbox.y - pos.y) < 50)
            assert.are.equal(1, doc:compareXPointers(wordbox.pos0, wordbox.pos1))
            assert.are.equal(wordbox.word, doc:getTextFromXPointers(wordbox.pos0, wordbox.pos1))
        end)

        it("gets the text and boxes between two positions", function()
            doc:gotoPage(5)
            local range = doc:getTextFromPositions({ x = 20, y = 200 }, { x = 400, y = 260 }, true)
            assert.truthy(range.text:find("%S"))
            assert.is_true(#range.sboxes >= 1)
            assert.is_true(range.sboxes[1].w > 0)
            assert.are.equal(1, doc:compareXPointers(range.pos0, range.pos1))
            local boxes = doc:getScreenBoxesFromPositions(range.pos0, range.pos1, true)
            assert.are.equal(#range.sboxes, #boxes)
            assert.are.same({}, doc:getScreenBoxesFromPositions(nil, range.pos1))
            -- extending to the sentence keeps the range inside
            local sentence = doc:extendXPointersToSentenceSegment(range.pos0, range.pos1)
            assert.is_true(doc:compareXPointers(sentence.pos0, range.pos0) >= 0)
            assert.is_true(doc:compareXPointers(range.pos1, sentence.pos1) >= 0)
            assert.truthy(sentence.text:find(range.text, 1, true))
            doc:clearSelection()
        end)

        it("finds the nearest word", function()
            doc:gotoPage(5)
            local nearest = doc:getNearestWordAndBoxFromPosition({ x = 1, y = 300 }, 1)
            assert.truthy(nearest)
            assert.truthy(nearest.word:find("%S"))
            assert.is_true(nearest.sbox.w > 0)
            assert.are.equal(nearest.word, doc:getNearestWordFromPosition({ x = 1, y = 300 }, 1).text)
            -- no word found, or no box for it: nil
            local fake = setmetatable({ _document = {
                getNearestWordFromPosition = function() return nil end,
                getCurrentPage = function() return 1 end,
                getWordBoxesFromPositions = function() return {} end,
            } }, { __index = CreDocument })
            assert.is_nil(fake:getNearestWordAndBoxFromPosition({ x = 1, y = 300 }, 1))
            fake._document.getNearestWordFromPosition = function() return { text = "word", pos0 = "a", pos1 = "b" } end
            assert.is_nil(fake:getNearestWordAndBoxFromPosition({ x = 1, y = 300 }, 1))
        end)

        it("walks visible words and characters, and gets a word's context", function()
            doc:gotoPage(5)
            local wordbox = doc:getWordFromPosition(pos, true)
            local next_start = doc:getNextVisibleWordStart(wordbox.pos1)
            assert.are.equal(1, doc:compareXPointers(wordbox.pos1, next_start))
            local next_end = doc:getNextVisibleWordEnd(next_start)
            assert.are.equal(1, doc:compareXPointers(next_start, next_end))
            local prev_start = doc:getPrevVisibleWordStart(wordbox.pos0)
            assert.are.equal(-1, doc:compareXPointers(wordbox.pos0, prev_start))
            local prev_end = doc:getPrevVisibleWordEnd(wordbox.pos0)
            assert.are.equal(-1, doc:compareXPointers(wordbox.pos0, prev_end))
            assert.are.equal(1, doc:compareXPointers(wordbox.pos0, doc:getNextVisibleChar(wordbox.pos0)))
            assert.are.equal(-1, doc:compareXPointers(wordbox.pos1, doc:getPrevVisibleChar(wordbox.pos1)))
            local prev, nxt = doc:getSelectedWordContext(wordbox.word, 3, wordbox.pos0, wordbox.pos1, true)
            assert.truthy(prev:find("%S"))
            assert.truthy(nxt:find("%S"))
            doc:clearSelection()
        end)

        it("gets text and HTML from xpointers", function()
            local xp = doc:getPageXPointer(5)
            assert.truthy(doc:getTextFromXPointer(xp):find("%S"))
            assert.is_nil(doc:getTextFromXPointer(nil))
            local html = doc:getHTMLFromXPointer(xp, 0x0)
            assert.truthy(html:find("Shakespeare", 1, true) or html:find("%S"))
            assert.is_nil(doc:getHTMLFromXPointer(nil))
            local html2 = doc:getHTMLFromXPointers(xp, doc:getNextVisibleWordEnd(xp), 0x0)
            assert.truthy(html2:find("%S"))
            assert.is_nil(doc:getHTMLFromXPointers(xp, nil))
            assert.truthy(doc:getDocumentFileContent("OPS/fb.opf"):find("<package", 1, true))
            assert.is_nil(doc:getDocumentFileContent(nil))
        end)

        it("finds links and footnotes", function()
            doc:gotoPage(5)
            local links = doc:getPageLinks()
            local link = links[1]
            assert.are.equal("http://generation.feedbooks.com/book/2846.epub", link.uri)
            local found = doc:getLinkFromPosition({ x = link.start_x + 2, y = link.start_y + 2 })
            assert.are.equal(link.uri, found)
            assert.are.same({}, doc:getPageLinks(true)) -- internal links only: none here
        end)

        it("searches text and checks regexes", function()
            local results = doc:findAllText("Romeo", true, 2, 5, false)
            assert.are.equal(5, #results)
            assert.are.equal("Romeo", results[1].matched_text)
            assert.are.equal(" and Juliet", results[1].next_text)
            assert.are.equal(0, doc:checkRegex("Rom.o"))
            assert.are_not.equal(0, doc:checkRegex("a(b"))
            assert.are.equal(0, doc:getAndClearRegexSearchError())
            doc:gotoPage(1)
            local hits = doc:findText("Juliet", 0, 0, true, 1, false, 3)
            assert.truthy(hits)
            doc:clearSelection()
        end)

        it("extracts images, including scalable ones", function()
            doc:gotoPage(1)
            local image = doc:getImageFromPosition({ x = 300, y = 300 })
            assert.truthy(image)
            assert.is_true(image:getWidth() > 0)
            image:free()
            assert.is_nil(doc:getImageFromPosition({ x = 1, y = 1 }))
            local cover = doc:getCoverPageImage()
            assert.truthy(cover)
            cover:free()

            -- crengine hands back a scalable image object for SVG: we get a renderer function
            local freed = false
            local cre_img = {
                renderScaled = function(_, scale, w, h)
                    local data = Blitbuffer.new(w or 10, h or 10, Blitbuffer.TYPE_BBRGB32)
                    return data.data, w or 10, h or 10, scale or 1, data
                end,
                free = function() freed = true end,
            }
            local fake = setmetatable({ _document = {
                getImageDataFromPosition = function(_, x, y, accept_scalable)
                    assert.is_true(accept_scalable)
                    return nil, nil, cre_img
                end,
            } }, { __index = CreDocument })
            local render = fake:getImageFromPosition({ x = 10, y = 10 }, false, true)
            assert.is_function(render)
            local bb, scale = render(2, 20, 30)
            assert.are.equal(20, bb:getWidth())
            assert.are.equal(30, bb:getHeight())
            assert.are.equal(2, scale)
            assert.is_nil(render(false)) -- done with it
            assert.is_true(freed)
            assert.is_nil(render(1, 5, 5)) -- already freed
        end)
    end)

    describe("page map and toc", function()
        it("builds a synthetic page map", function()
            -- (legacy user patches entry point; called before any page map getter)
            doc:buildSyntheticPageMapIfNoneDocumentProvided()
            assert.is_false(doc:hasPageMapDocumentProvided())
            assert.is_false(doc:isPageMapDocumentProvided())
            assert.is_true(doc:hasPageMap())
            assert.is_true(doc:isPageMapSynthetic())
            assert.are.equal(1024, doc:getSyntheticPageMapCharsPerPage())
            doc:buildSyntheticPageMap(2048)
            assert.are.equal(2048, doc:getSyntheticPageMapCharsPerPage())
            local map = doc:getPageMap()
            assert.is_true(#map > 10)
            assert.are.equal("1", doc:getPageMapFirstPageLabel())
            assert.are.equal(map[#map].label, doc:getPageMapLastPageLabel())
            assert.are.equal(map[3].label, doc:getPageMapXPointerPageLabel(map[3].xpointer))
            assert.truthy(doc:getPageMapSource() == nil or type(doc:getPageMapSource()) == "string")
            doc:gotoXPointer(map[3].xpointer)
            assert.truthy(doc:getPageMapCurrentPageLabel())
            local labels = doc:getPageMapVisiblePageLabels()
            assert.is_table(labels)
            assert.is_true(#labels >= 1)
        end)

        it("builds an alternative toc from headings", function()
            assert.is_true(doc:canHaveAlternativeToc())
            assert.is_false(doc:isTocAlternativeToc())
            doc:buildAlternativeToc()
            assert.is_true(doc:isTocAlternativeToc())
            assert.is_true(#doc:getToc() > 0)
        end)
    end)

    describe("rendering settings", function()
        local function intProp(name) return doc._document:getIntProperty(name) end
        local function strProp(name) return doc._document:getStringProperty(name) end

        it("sets the fallback fonts, the user one first", function()
            G_reader_settings:saveSetting("fallback_font", "FreeSans")
            doc:setupFallbackFontFaces()
            local faces = strProp("crengine.font.fallback.faces")
            assert.truthy(faces:find("^FreeSans|"))
            -- not repeated
            local _, count = faces:gsub("FreeSans|", "")
            assert.are.equal(1, count)
            -- additional fallback fonts disabled: keep only the first one
            G_reader_settings:makeFalse("additional_fallback_fonts")
            doc:setupFallbackFontFaces()
            assert.are.equal("FreeSans", strProp("crengine.font.fallback.faces"))
            G_reader_settings:delSetting("fallback_font")
            G_reader_settings:delSetting("additional_fallback_fonts")
            doc:setupFallbackFontFaces()
            assert.are.equal(doc.fallback_fonts[1], strProp("crengine.font.fallback.faces"):match("^[^|]+"))
        end)

        it("sets the font-family fonts", function()
            doc:setFontFamilyFontFaces(nil, true)
            assert.are.equal("not-empty||||||||", strProp("crengine.font.family.faces"))
            doc:setFontFamilyFontFaces({ serif = "Noto Serif", monospace = "Droid Sans Mono" })
            assert.are.equal("|Noto Serif||||Droid Sans Mono|||", strProp("crengine.font.family.faces"))
            doc:setFontFamilyFontFaces({})
        end)

        it("sets hyphenation", function()
            assert.are.equal("English_US.pattern", doc:getTextMainLangDefaultHyphDictionary())
            doc:setHyphDictionary(nil) -- no-op
            doc:setHyphDictionary("@none")
            assert.are.equal("@none", strProp("crengine.hyphenation.directory"))
            doc:setHyphDictionary("English_US.pattern")
            doc:setHyphLeftHyphenMin(3)
            assert.are.equal(3, intProp("crengine.hyphenation.left.hyphen.min"))
            doc:setHyphLeftHyphenMin()
            assert.are.equal(2, intProp("crengine.hyphenation.left.hyphen.min"))
            doc:setHyphRightHyphenMin(4)
            assert.are.equal(4, intProp("crengine.hyphenation.right.hyphen.min"))
            doc:setHyphRightHyphenMin()
            doc:setTrustSoftHyphens(true)
            assert.are.equal(1, intProp("crengine.hyphenation.trust.soft.hyphens"))
            doc:setTrustSoftHyphens(false)
            assert.are.equal(0, intProp("crengine.hyphenation.trust.soft.hyphens"))
        end)

        it("sets font size, weight, rendering DPI and spacing", function()
            local size = doc:getFontSize()
            doc:setFontSize(nil) -- no-op
            assert.are.equal(size, doc:getFontSize())
            doc:setFontSize(size + 4)
            assert.are.equal(size + 4, doc:getFontSize())
            doc:zoomFont(-4)
            assert.is_true(doc:getFontSize() < size + 4)
            doc:setFontSize(size)
            doc:setFontBaseWeight(-0.5)
            assert.are.equal(350, intProp("font.face.base.weight"))
            doc:setFontBaseWeight(0)
            assert.are.equal(400, intProp("font.face.base.weight"))
            doc:setRenderDPI(120)
            assert.are.equal(120, intProp("crengine.render.dpi"))
            doc:setRenderDPI()
            assert.are.equal(96, intProp("crengine.render.dpi"))
            doc:setRenderScaleFontWithDPI(1)
            assert.are.equal(1, intProp("crengine.render.scale.font.with.dpi"))
            doc:setWordSpacing({ 90, 75 })
            assert.are.equal(90, intProp("crengine.style.space.width.scale.percent"))
            assert.are.equal(75, intProp("crengine.style.space.condensing.percent"))
            doc:setWordExpansion()
            assert.are.equal(0, intProp("crengine.style.max.added.letter.spacing.percent"))
            doc:setCJKWidthScaling()
            assert.are.equal(100, intProp("crengine.style.cjk.width.scale.percent"))
            doc:setMonospaceFontScaling(90)
            assert.are.equal(90, intProp("font.monospace.size.scale.percent"))
            doc:setMonospaceFontScaling()
            assert.are.equal(100, intProp("font.monospace.size.scale.percent"))
        end)

        it("sets the gamma, the header and the status line", function()
            doc:setGammaIndex(20)
            assert.is_true(doc:getGammaLevel() > 1)
            doc:setGammaIndex(15)
            assert.are.equal(1, doc:getGammaLevel())
            doc:setHeaderFont(nil) -- no-op
            doc:setHeaderFont("Noto Sans")
            doc:setHeaderProgressMarks(doc:getPageCount(), { 10, 20 })
            doc:setBatteryState(42)
            doc:setPageInfoOverride("12 / 34")
            doc:setPageInfoOverride("")
            doc:setStatusLineProp("1")
            assert.are.equal("1", strProp("window.status.line"))
            doc:setStatusLineProp("0")
        end)

        it("sets the background color and image", function()
            doc:setBackgroundColor(0xEEEEEE)
            local rect = { x = 0, y = 0, w = 200, h = 200 }
            local bb = Blitbuffer.new(rect.w, rect.h, Blitbuffer.TYPE_BBRGB32)
            doc:resetBufferCache()
            doc:drawCurrentView(bb, 0, 0, rect)
            assert.are.equal(0xEE, bb:getPixel(1, 1):getColorRGB32().r)
            doc:setBackgroundColor(nil)
            doc:setBackgroundImage(nil)
            doc:resetBufferCache()
            doc:drawCurrentView(bb, 0, 0, rect)
            assert.are.equal(0xFF, bb:getPixel(1, 1):getColorRGB32().r)
            bb:free()
        end)

        it("applies the header/background defaults before loading only", function()
            G_reader_settings:saveSetting("cre_header_status_font_size", 18)
            G_reader_settings:saveSetting("cre_background_color", 0xDDDDDD)
            G_reader_settings:saveSetting("cre_background_image", "resources/koreader.png")
            local other = DocumentRegistry:openDocument(other_epub)
            local set_color = spy.on(other, "setBackgroundColor")
            local set_image = spy.on(other, "setBackgroundImage")
            other:setupDefaultView()
            assert.spy(set_color).was_called_with(match.is_ref(other), 0xDDDDDD)
            assert.spy(set_image).was_called_with(match.is_ref(other), "resources/koreader.png")
            assert.are.equal(18, other._document:getIntProperty("crengine.page.header.font.size"))
            assert.is_true(other:loadDocument())
            -- already loaded: defaults are not applied again
            other:setupDefaultView()
            assert.spy(set_color).was_called(1)
            other:close()
            G_reader_settings:delSetting("cre_header_status_font_size")
            G_reader_settings:delSetting("cre_background_color")
            G_reader_settings:delSetting("cre_background_image")
        end)

        it("sets alternative document properties", function()
            doc:setAltDocumentProp("series_index", 3)
            doc:setAltDocumentProp("title", "Alternative title")
            assert.are.equal("Romeo and Juliet", doc:getDocumentProps().title)
        end)

        it("reports statistics, embedded fonts and partial rerendering", function()
            assert.truthy(doc:getStatistics():find("^Elements: %d+"))
            assert.is_table(doc:getEmbeddedFontList())
            assert.are.equal("Noto Serif", doc:getFontFace())
            local unknown = doc:getUnknownEntities()
            assert.truthy(unknown == nil or type(unknown) == "table" or type(unknown) == "string")
            assert.is_true(doc:canBePartiallyRerendered())
            local enabled = doc:isPartialRerenderingEnabled()
            assert.is_boolean(enabled)
            assert.are.equal(0, doc:getPartialRerenderingsCount())
            assert.is_function(doc.setCallback)
        end)
    end)
end)
