describe("Dictionary download catalogue", function()
    local ReaderDictionary

    setup(function()
        require("commonrequire")
        ReaderDictionary = require("apps/reader/modules/readerdictionary")
    end)

    local function downloadLists()
        local lists = {}
        local show = stub(ReaderDictionary, "showDownload", function(_, language, dictionaries)
            lists[language] = dictionaries
        end)
        finally(function() show:revert() end)
        for _, item in ipairs(ReaderDictionary:_genDownloadDictionariesMenu()) do
            item.callback()
        end
        return lists
    end

    it("keeps every catalogue URL available under both languages", function()
        local listed = {}
        for language, dictionaries in pairs(downloadLists()) do
            listed[language] = {}
            for _, dict in ipairs(dictionaries) do
                listed[language][dict.url] = true
            end
        end
        for _, dict in ipairs(require("ui/data/dictionaries")) do
            assert.is_true(listed[dict.lang_in][dict.url], dict.url .. " missing from " .. dict.lang_in)
            assert.is_true(listed[dict.lang_out][dict.url], dict.url .. " missing from " .. dict.lang_out)
        end
    end)

    it("lists a catalogue URL at most once per language", function()
        for language, dictionaries in pairs(downloadLists()) do
            local listed = {}
            for _, dict in ipairs(dictionaries) do
                assert.is_nil(listed[dict.url], dict.url .. " repeated in " .. language)
                listed[dict.url] = true
            end
        end
    end)
end)
