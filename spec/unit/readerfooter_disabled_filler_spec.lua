describe("ReaderFooter with dynamic fillers disabled by the progress bar", function()
    local ReaderFooter

    -- Progress bar shown alongside the items: dynamic fillers are disabled.
    local function newFooter()
        return setmetatable({
            settings = {
                items_separator = "bar",
                all_at_once = true,
                disable_progress_bar = false,
                progress_bar_position = "alongside",
            },
            horizontal_margin = 0,
            _saved_screen_width = 1000, -- unscaled_size_check: ignore
            getTextWidth = function(_, text) return 10 * #text end,
        }, { __index = ReaderFooter })
    end

    local function realGenerator(mode)
        local footer = newFooter()
        footer.mode_index = { mode }
        footer.settings[mode] = true
        footer:updateFooterTextGenerator()
        return footer.footerTextGenerators[1]
    end

    local function text(str)
        return function() return str end
    end

    local function gen(generators)
        local footer = newFooter()
        footer.footerTextGenerators = generators
        return footer:genAllFooterText()
    end

    local filler1, filler2
    setup(function()
        require("commonrequire")
        ReaderFooter = require("apps/reader/modules/readerfooter")
        filler1 = realGenerator("dynamic_filler")
        filler2 = realGenerator("dynamic_filler2")
    end)

    it("keeps the separators around a disabled filler", function()
        assert.are.equal("AAA | BBB | CCC", gen({ text("AAA"), filler1, text("BBB"), filler2, text("CCC") }))
    end)

    it("keeps the last item when a disabled filler is last", function()
        assert.are.equal("AAA | BBB", gen({ text("AAA"), text("BBB"), filler2 }))
    end)

    it("ignores a disabled filler at the start", function()
        assert.are.equal("AAA | BBB", gen({ filler1, text("AAA"), text("BBB") }))
    end)
end)
