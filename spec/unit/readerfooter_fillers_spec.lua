describe("ReaderFooter dynamic fillers", function()
    local ReaderFooter
    local filler1, filler2

    -- Fake footer: every character is 10px wide, " | " separators, no margin.
    local function newFooter(screen_width, settings)
        local footer = setmetatable({
            settings = settings or { items_separator = "bar", disable_progress_bar = true, all_at_once = true },
            horizontal_margin = 0,
            _saved_screen_width = screen_width,
            getTextWidth = function(_, text) return 10 * #text end,
        }, { __index = ReaderFooter })
        return footer
    end

    local function realGenerator(mode)
        local footer = newFooter(0)
        footer.mode_index = { mode }
        footer.settings[mode] = true
        footer:updateFooterTextGenerator()
        return footer.footerTextGenerators[1]
    end

    local function text(str)
        return function() return str end
    end

    local function gen(footer, generators)
        footer.footerTextGenerators = generators
        return footer:genAllFooterText()
    end

    setup(function()
        require("commonrequire")
        ReaderFooter = require("apps/reader/modules/readerfooter")
        filler1 = realGenerator("dynamic_filler")
        filler2 = realGenerator("dynamic_filler2")
    end)

    describe("with a long text", function()
        it("replaces two inner fillers with separators", function()
            assert.are.equal("AAA | BBB | CCC",
                gen(newFooter(50), { text("AAA"), filler1, text("BBB"), filler2, text("CCC") }))
        end)

        it("handles the first filler at the start", function()
            assert.are.equal("AAA | BBB",
                gen(newFooter(50), { filler1, text("AAA"), filler2, text("BBB") }))
        end)

        it("handles the second filler at the end", function()
            assert.are.equal("AAA | BBB",
                gen(newFooter(50), { text("AAA"), filler1, text("BBB"), filler2 }))
        end)
    end)

    it("puts the separator before the right text when it doesn't fit", function()
        local right = ("C"):rep(20)
        -- left 10px, center 10px, right 200px in 300px: the 2nd filler becomes a separator
        local result = gen(newFooter(300), { text("A"), filler1, text("B"), filler2, text(right) })
        assert.are.equal("A" .. (" "):rep(5) .. "B | " .. right, result)
    end)

    it("centers the middle text with two fillers when everything fits", function()
        local result = gen(newFooter(300), { text("A"), filler1, text("B"), filler2, text("C") })
        assert.are.equal("A" .. (" "):rep(13) .. "B" .. (" "):rep(13) .. "C", result)
    end)
end)
