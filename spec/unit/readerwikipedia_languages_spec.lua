describe("ReaderWikipedia automatic languages", function()
    local ReaderWikipedia, Translator, Wikipedia, NetworkMgr
    local saved = {}
    local saved_trap_widget
    local keys = { "language", "wikipedia_languages" }

    setup(function()
        require("commonrequire")
        ReaderWikipedia = require("apps/reader/modules/readerwikipedia")
        Translator = require("ui/translator")
        Wikipedia = require("ui/wikipedia")
        NetworkMgr = require("ui/network/manager")
    end)

    before_each(function()
        saved_trap_widget = Wikipedia.trap_widget
        for _, key in ipairs(keys) do
            saved[key] = G_reader_settings:readSetting(key)
            G_reader_settings:delSetting(key)
        end
    end)

    after_each(function()
        Wikipedia.trap_widget = saved_trap_widget
        for _, key in ipairs(keys) do G_reader_settings:saveSetting(key, saved[key]) end
    end)

    local function reader(language, has_view)
        return setmetatable({
            wiki_languages = {},
            view = has_view ~= false and {} or nil,
            ui = { doc_props = { language = language } },
            disable_history = true,
        }, { __index = ReaderWikipedia })
    end

    for _, case in ipairs({
        { "ENG", "en" }, { "eng", "en" }, { "fra", "fr" }, { "deu", "de" },
        { "jpn", "ja" }, { "zho-CN", "zh" }, { "por_BR", "pt" },
        { "en-US", "en" }, { "C", "en" }, { "ast", "ast" }, { "unknown", "unknown" },
    }) do
        it("guesses " .. case[2] .. " from metadata " .. case[1], function()
            local r = reader(case[1])
            r:initLanguages()
            assert.are.equal(case[2], r.wiki_languages[1])
            assert.are.equal(case[1], r.ui.doc_props.language)
            assert.are.equal("https://" .. case[2] .. ".wikipedia.org", Wikipedia:getWikiServer(r.wiki_languages[1]))
        end)
    end

    it("deduplicates after normalizing book and UI languages", function()
        G_reader_settings:saveSetting("language", "fr_FR")
        local r = reader("fra")
        r:initLanguages()
        assert.same({ "fr", "en" }, r.wiki_languages)
    end)

    it("uses a normalized UI language in the file manager", function()
        G_reader_settings:saveSetting("language", "jpn")
        local r = reader("fra", false)
        r:initLanguages()
        assert.same({ "ja", "en" }, r.wiki_languages)
    end)

    it("leaves explicit Wikipedia domains and their order untouched", function()
        local configured = { "zh-classical", "ast", "eng" }
        G_reader_settings:saveSetting("wikipedia_languages", configured)
        local r = reader("fra")
        r:initLanguages()
        assert.are.equal(configured, r.wiki_languages)
        assert.same({ "zh-classical", "ast", "eng" }, configured)
    end)

    it("normalizes detected language only when both metadata and UI language are absent", function()
        local detect = stub(Translator, "detect", function() return "fra" end)
        local r = reader(nil)
        local ok, err = pcall(r.initLanguages, r, "harbor")
        detect:revert()
        assert.is_true(ok, err)
        assert.same({ "fr", "en" }, r.wiki_languages)
        assert.stub(detect).was.called(1)
    end)

    it("keeps the English fallback when detection fails", function()
        local detect = stub(Translator, "detect", function() error("synthetic detection failure") end)
        local r = reader(nil)
        local ok, err = pcall(r.initLanguages, r, "harbor")
        detect:revert()
        assert.is_true(ok, err)
        assert.same({ "en" }, r.wiki_languages)
    end)

    it("keeps an initialized language list stable", function()
        local r = reader("fra")
        r:initLanguages()
        r.ui.doc_props.language = "jpn"
        r:initLanguages()
        assert.same({ "fr", "en" }, r.wiki_languages)
    end)

    for _, forced in ipairs({ true, false }) do
        it("preserves an explicit " .. (forced and "forced" or "last-selected") .. " edition", function()
            local r = reader("ENG")
            r.wiki_last_language = "ast"
            r.showLookupInfo = function() end
            r.showDict = function() end
            local requested
            local online = stub(NetworkMgr, "willRerunWhenOnline", function() return false end)
            local search = stub(Wikipedia, "searchAndGetIntros", function(_, _, lang)
                requested = lang
                return {}
            end)
            local ok, err = pcall(r.lookupWikipedia, r, "harbor", true, nil, false, forced and "zh-classical" or nil)
            search:revert()
            online:revert()
            assert.is_true(ok, err)
            assert.are.equal(forced and "zh-classical" or "ast", requested)
        end)
    end
end)
