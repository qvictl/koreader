-- Japanese plugin: in a book whose language is not Japanese (here Chinese), word selections
-- and lookups of kana-less text are left alone (no dictionary lookups, no deinflection),
-- while text with kana, and any text in a Japanese book, is still handled.
return {
    name = "Japanese plugin kana guard",
    timeout = 120,
    settings = {
        cre_font = "Noto Sans CJK SC",
    },
    run = function(T)
        local ui = T:openBook(T:fixture("books/zh.epub"))
        local ls = ui.languagesupport
        local japanese = ls and ls.plugins and ls.plugins.japanese
        T:check(japanese, "the Japanese language plugin is loaded")
        T:check(japanese.shouldHandleText, "the plugin has the kana guard")
        T:check(not japanese:shouldHandleText("學而時習之"), "kana-less text in a Chinese book is not handled")
        T:check(japanese:shouldHandleText("ねこ"), "text with hiragana is handled")
        T:check(japanese:shouldHandleText("ネコ"), "text with katakana is handled")

        local raw = T:spy(ui.dictionary, "rawSdcv")
        -- Hold on Chinese text: the selection is not "improved" (expanded) by the Japanese plugin,
        -- and that costs no dictionary lookup.
        local selections = 0
        for _, y in ipairs({ 0.3, 0.45, 0.6 }) do
            local d = ui.view.dimen
            local word = T:run(function()
                return ui.document:getWordFromPosition({ x = d.x + math.floor(d.w / 2), y = d.y + math.floor(d.h * y) }, true)
            end)
            if word and word.pos0 then
                selections = selections + 1
                local new = T:run(function()
                    return ls:improveWordSelection({ text = word.word, pos0 = word.pos0, pos1 = word.pos1 })
                end)
                T:check(new == nil, "Chinese selection '" .. word.word .. "' left alone")
            end
        end
        T:check(selections > 0, "got some word selections")
        T:check(ls:extraDictionaryFormCandidates("學而") == nil, "no deinflection candidates for Chinese text")
        T:eq(raw.calls, 0, "no dictionary lookup spent on Chinese text")

        -- The option restores the old behaviour.
        japanese.handle_other_languages = true
        T:check(japanese:shouldHandleText("學而時習之"), "kana-less text handled when the option is enabled")
        japanese.handle_other_languages = false
        raw.restore()

        -- In a Japanese book, kana-less (kanji only) text is handled.
        ui = T:openBook(T:fixture("books/ja.epub"))
        japanese = ui.languagesupport.plugins.japanese
        T:eq(ui.doc_props.language, "ja", "document language")
        T:check(japanese:shouldHandleText("記憶"), "kanji-only text is handled in a Japanese book")
        T:closeBook()
    end,
}
