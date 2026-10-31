-- Real candidate generation/deinflection, with a synthetic sdcv response boundary.
describe("Japanese word selection dictionary scope", function()
    local Japanese, Deinflector, saved_path, saved_deinflector
    local plugin, dictionary, calls, dictionary_entries

    setup(function()
        require("commonrequire")
        saved_path, saved_deinflector = package.path, package.loaded.deinflector
        package.path = "plugins/japanese.koplugin/?.lua;" .. package.path
        Deinflector = require("deinflector")
        Japanese = dofile("plugins/japanese.koplugin/main.lua")
    end)

    teardown(function()
        package.path, package.loaded.deinflector = saved_path, saved_deinflector
    end)

    before_each(function()
        calls = {}
        dictionary_entries = {
            Short = { ["適当"] = true },
            Long = { ["適当に"] = true },
        }
        dictionary = { enabled_dict_names = { "Short" }, doc_disabled_dicts = {} }
        dictionary.rawSdcv = function(_, words, names, fuzzy)
            calls[#calls + 1] = { words = words, names = names, fuzzy = fuzzy }
            local results = {}
            for i, word in ipairs(words) do
                results[i] = {}
                for _, name in ipairs(names or { "Short", "Long" }) do
                    if dictionary_entries[name] and dictionary_entries[name][word] then
                        table.insert(results[i], { dict = name, word = word })
                    end
                end
            end
            return false, results
        end
        plugin = setmetatable({ dictionary = dictionary, deinflector = Deinflector:new{},
            max_scan_length = 20, ui = { doc_props = { language = "ja" } } }, { __index = Japanese })
    end)

    local function selectWord(text)
        local chars = require("util").splitToChars(text or "適当に。")
        return plugin:onWordSelection{
            text = chars[1], pos0 = 0, pos1 = 1,
            callbacks = {
                get_next_char_pos = function(pos) return pos and pos < #chars and pos + 1 or nil end,
                get_text_in_range = function(first, last)
                    return table.concat(chars, "", first + 1, last or #chars)
                end,
            },
        }
    end

    it("does not extend into a word found only in a globally disabled dictionary", function()
        assert.same({ 0, 2 }, selectWord())
        assert.same({ "Short" }, calls[1].names)
        assert.equals(1, #calls)
        assert.is_nil(calls[1].fuzzy)
    end)

    it("retains the longest match when both dictionaries are enabled", function()
        dictionary.enabled_dict_names = { "Short", "Long" }
        assert.same({ 0, 3 }, selectWord())
        assert.same({ "Short", "Long" }, calls[1].names)
    end)

    it("ignores a dictionary disabled for the current book", function()
        dictionary.enabled_dict_names = { "Long", "Short" }
        dictionary.doc_disabled_dicts.Long = true
        assert.same({ 0, 2 }, selectWord())
        assert.same({ "Short" }, calls[1].names)
        assert.same({ "Long", "Short" }, dictionary.enabled_dict_names)
        assert.same({ Long = true }, dictionary.doc_disabled_dicts)
    end)

    it("accepts an enabled preferred dictionary without changing its order", function()
        -- ReaderDictionary puts preferred dictionaries first, including globally disabled ones.
        dictionary.enabled_dict_names = { "Long", "Short" }
        assert.same({ 0, 3 }, selectWord())
        assert.same({ "Long", "Short" }, calls[1].names)
    end)

    it("works when no per-book disabling table is present", function()
        dictionary.doc_disabled_dicts = nil
        assert.same({ 0, 2 }, selectWord())
    end)

    it("does not run an unfiltered lookup when every dictionary is globally disabled", function()
        dictionary.enabled_dict_names = {}
        assert.is_nil(selectWord())
        assert.equals(0, #calls)
    end)

    it("does not run an unfiltered lookup when every dictionary is disabled for the book", function()
        dictionary.doc_disabled_dicts.Short = true
        assert.is_nil(selectWord())
        assert.equals(0, #calls)
    end)

    it("rechecks the live dictionary scope after toggles", function()
        assert.same({ 0, 2 }, selectWord())
        dictionary.enabled_dict_names = { "Short", "Long" }
        assert.same({ 0, 3 }, selectWord())
        dictionary.doc_disabled_dicts.Long = true
        assert.same({ 0, 2 }, selectWord())
        dictionary.doc_disabled_dicts.Long = nil
        assert.same({ 0, 3 }, selectWord())
    end)

    it("preserves deinflection of enabled dictionary words", function()
        dictionary_entries.Short = { ["食べる"] = true }
        assert.same({ 0, 3 }, selectWord("食べた。"))
    end)

    it("leaves the selection unchanged when enabled dictionaries have no match", function()
        dictionary_entries.Short = {}
        assert.is_nil(selectWord())
    end)

    it("ignores results from a cancelled lookup", function()
        dictionary.rawSdcv = function() return true, { { { dict = "Short" } } } end
        assert.is_nil(selectWord())
    end)

    it("leaves the selection unchanged when the dictionary backend has no results", function()
        dictionary.rawSdcv = function() return false, nil end
        assert.is_nil(selectWord())
    end)

    it("retains the non-Japanese kana guard without querying dictionaries", function()
        plugin.ui.doc_props.language = "zh"
        assert.is_nil(selectWord("學而時習之。"))
        assert.equals(0, #calls)
    end)

    it("leaves Latin text alone without querying dictionaries", function()
        assert.is_nil(selectWord("English."))
        assert.equals(0, #calls)
    end)
end)
