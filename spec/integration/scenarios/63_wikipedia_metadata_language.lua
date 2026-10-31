-- Native EPUB metadata and actual Wikipedia dialogs; the remote API is synthetic.
return {
    name = "Wikipedia normalizes automatically guessed ISO languages",
    timeout = 90,
    settings = {
        language = "en", wikipedia_languages = {}, wikipedia_show_image = false,
        wikipedia_disable_history = true, cover_image_enabled = false, cover_image_fallback = false,
    },
    run = function(T)
        local Archiver = require("ffi/archiver")
        local UIManager = require("ui/uimanager")
        local Wikipedia = require("ui/wikipedia")
        local NetworkMgr = require("ui/network/manager")
        local lfs = require("libs/libkoreader-lfs")
        local ui, window, dialog
        local requests = {}
        local original_page, original_online = Wikipedia.loadPage, NetworkMgr.willRerunWhenOnline
        local http = require("socket.http")
        local original_request = http.request
        http.request = function() error("Unexpected external HTTP request in metadata scenario") end
        NetworkMgr.willRerunWhenOnline = function() return false end
        Wikipedia.loadPage = function(self, word, lang)
            requests[#requests + 1] = { word = word, lang = lang, server = self:getWikiServer(lang) }
            return { query = { pages = {
                [1] = { title = "Harbor", extract = "Synthetic Wikipedia introduction in " .. lang, index = 0 },
            } } }
        end
        local function makeBook(lang)
            local path = os.getenv("KO_HOME") .. "/wikipedia-" .. lang .. ".epub"
            T:check(not lfs.attributes(path), "owned EPUB path is absent")
            local writer = Archiver.Writer:new{}
            T:check(writer:open(path, "epub"), "opens private EPUB writer")
            local ok, err = pcall(function()
                writer:setZipCompression("store")
                assert(writer:addFileFromMemory("mimetype", "application/epub+zip", 0))
                writer:setZipCompression("deflate")
                assert(writer:addFileFromMemory("META-INF/container.xml", [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
<rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
</rootfiles></container>]], 0))
                assert(writer:addFileFromMemory("content.opf", [[<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">wiki-language-]] .. lang .. [[</dc:identifier>
<dc:title>Wikipedia language fixture</dc:title><dc:language>]] .. lang .. [[</dc:language></metadata>
<manifest><item id="text" href="text.xhtml" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="text"/></spine></package>]], 0))
                assert(writer:addFileFromMemory("text.xhtml", [[<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Harbor</title></head><body><h1>The harbor</h1>]]
                    .. string.rep("<p>The keeper watched the harbor. A lantern illuminated the quiet road.</p>", 100)
                    .. "</body></html>", 0))
            end)
            writer:close()
            if not ok then error(err) end
            return path
        end
        local function closeLookup()
            T:run(function() window:onClose() end)
            T:check(not UIManager:isWidgetShown(window), "Wikipedia popup closes")
            window = nil
        end
        local function lookup(expected)
            local before = #requests
            T:run(function() ui.wikipedia:onLookupWikipedia("harbor", true) end)
            window = T:waitUntil(function()
                local w = ui.wikipedia.dict_window
                return w and UIManager:isWidgetShown(w) and w
            end, 5, "Wikipedia result window")
            T:repaint()
            T:eq(#requests, before + 1, "one synthetic API request")
            T:eq(requests[#requests].lang, expected, "API request uses the expected edition")
            T:eq(requests[#requests].server, "https://" .. expected .. ".wikipedia.org", "request server matches edition")
            T:eq(window.results[1].lang, expected, "painted result uses the expected language")
            T:check(window.results[1].definition:find("Synthetic Wikipedia introduction", 1, true), "actual intro parser populates popup")
        end
        local function tapText(root, text)
            T:repaint()
            local button = T:findWidget(root, function(w) return w.text == text and w.callback end)
            T:check(button, "button exists: " .. text)
            T:tapWidget(button, text)
        end
        local function languageDialog(value, save)
            local menu = {}
            T:run(function() ui.wikipedia:addToMainMenu(menu) end)
            T:run(function() menu.wikipedia_settings.sub_item_table[1].callback() end)
            dialog = T:topWidget()
            T:eq(dialog.title, "Wikipedia languages", "real language configuration dialog")
            T:run(function() dialog:setInputText(value) end)
            tapText(dialog, save and "Save" or "Cancel")
            T:check(not UIManager:isWidgetShown(dialog), "language dialog closes")
            dialog = nil
        end
        local ok, err = pcall(function()
            local english, french, asturian = makeBook("ENG"), makeBook("fra"), makeBook("ast")
            local open_ms
            ui, open_ms = T:openBook(english)
            T:budget("open_ms", open_ms, 15000, "ms")
            T:eq(ui.doc_props.language, "ENG", "native metadata retains original uppercase ISO code")
            lookup("en")
            T:eq(#ui.wikipedia.wiki_languages, 1, "metadata and English UI deduplicate after normalization")
            closeLookup()
            languageDialog("ast zh-classical", false)
            lookup("en")
            closeLookup()
            languageDialog("ast zh-classical", true)
            T:eq(table.concat(G_reader_settings:readSetting("wikipedia_languages"), " "), "ast zh-classical", "manual domains retain order and spelling")
            lookup("ast")
            tapText(window, "Language ≡")
            tapText(T:topWidget(), "zh-classical")
            window = T:waitUntil(function()
                local w = ui.wikipedia.dict_window
                return w and UIManager:isWidgetShown(w) and w.results[1].lang == "zh-classical" and w
            end, 5, "manual edition switch")
            T:eq(requests[#requests].lang, "zh-classical", "explicit picker selection is not ISO-normalized")
            closeLookup()
            T:closeBook()
            ui = T:openBook(english)
            lookup("zh-classical")
            closeLookup()
            T:closeBook()
            -- Start fresh books without an explicit global language selection.
            G_reader_settings:saveSetting("wikipedia_languages", {})
            G_reader_settings:delSetting("wikipedia_last_language")
            ui = T:openBook(french)
            T:eq(ui.doc_props.language, "fra", "native French metadata is unchanged")
            lookup("fr")
            T:eq(table.concat(ui.wikipedia.wiki_languages, ","), "fr,en", "automatic French precedes English fallback")
            closeLookup()
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h / 2))
            T:waitUntil(function() return ui:getCurrentPage() == 2 end, 3, "page turn after Wikipedia closes")
            T:closeBook()
            ui = T:openBook(asturian)
            T:eq(ui.doc_props.language, "ast", "native three-letter edition metadata is unchanged")
            lookup("ast")
            closeLookup()
        end)
        local errors = {}
        if not ok then errors[#errors + 1] = tostring(type(err) == "table" and err.msg or err) end
        for _, widget in ipairs({dialog or false, window or false}) do
            if widget and UIManager:isWidgetShown(widget) then
                local closed, failure = pcall(function() T:run(function() UIManager:close(widget) end) end)
                if not closed then errors[#errors + 1] = tostring(failure) end
            end
        end
        local closed, failure = pcall(function() T:closeBook() end)
        if not closed then errors[#errors + 1] = tostring(failure) end
        Wikipedia.loadPage, NetworkMgr.willRerunWhenOnline = original_page, original_online
        http.request = original_request
        if #errors > 0 then error(table.concat(errors, "\n")) end
        T:check(T:topWidget() == T:fileManager(), "returns to FileManager after Wikipedia and reading")
    end,
}
