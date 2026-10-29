--[[--
Helpers shared by the dictionary scenarios: run a lookup through the real UI entry
point (ReaderDictionary:onLookupWord, as a word selection does), and record when the
dictionary window was created, first painted and last updated.
]]

local DictHelper = {}

local function describe(results)
    local t = {}
    for _, r in ipairs(results or {}) do
        table.insert(t, string.format("%s|%s|%s", r.dict, r.word, (r.definition or ""):gsub("%s+", " "):gsub("^ ", "")))
    end
    return t
end
DictHelper.describe = describe

local function dictNames(results)
    local t = {}
    for _, r in ipairs(results or {}) do table.insert(t, r.dict) end
    return t
end
DictHelper.dictNames = dictNames

--- Instruments DictQuickLookup (once per process).
function DictHelper.instrument(T)
    if DictHelper.cur_holder then return DictHelper.cur_holder end
    local DictQuickLookup = require("ui/widget/dictquicklookup")
    local holder = {}
    local orig_init = DictQuickLookup.init
    DictQuickLookup.init = function(self, ...)
        local r = orig_init(self, ...)
        local cur = holder.cur
        if cur and not cur.t_init then
            cur.t_init = T:now()
            cur.initial_results = describe(self.results)
            cur.initial_pending = self.results_pending and true or false
        end
        return r
    end
    local orig_paint = DictQuickLookup.paintTo
    DictQuickLookup.paintTo = function(self, ...)
        orig_paint(self, ...)
        local cur = holder.cur
        if cur and not cur.t_painted then
            cur.t_painted = T:now()
            cur.painted_results = describe(self.results)
        end
    end
    if DictQuickLookup.updateResults then
        local orig_update = DictQuickLookup.updateResults
        DictQuickLookup.updateResults = function(self, results, pending)
            local cur = holder.cur
            local shown = self.results[self.dict_index]
            orig_update(self, results, pending)
            if cur then
                cur.nb_updates = (cur.nb_updates or 0) + 1
                cur.t_last_update = T:now()
                cur.kept_shown = (cur.kept_shown ~= false) and self.results[self.dict_index] == shown
            end
        end
    end
    DictHelper.cur_holder = holder
    return holder
end

--- Looks up `word` like a word selection does, waits for the window to be complete.
-- Returns a record: t_init/t_painted/t_last_update (relative ms), results, window.
function DictHelper.lookup(T, ui, word, timeout)
    local holder = DictHelper.instrument(T)
    local cur = { word = word }
    holder.cur = cur
    ui.dictionary.dict_window = nil
    cur.t0 = T:now()
    T:run(function() ui.dictionary:onLookupWord(word, true) end)
    local w = T:waitUntil(function()
        local w = ui.dictionary.dict_window
        return w and cur.t_painted and not w.results_pending and w
    end, timeout or 30, "dictionary window for " .. word)
    T:wait(0.1)
    cur.window = w
    cur.results = describe(w.results)
    cur.dicts = dictNames(w.results)
    cur.first_ms = cur.t_painted - cur.t0
    cur.init_ms = cur.t_init - cur.t0
    cur.total_ms = (cur.t_last_update or cur.t_painted) - cur.t0
    holder.cur = nil
    return cur
end

--- Closes the dictionary window(s).
function DictHelper.close(T, ui)
    local UIManager = require("ui/uimanager")
    local w = ui.dictionary.dict_window
    if w then
        T:run(function() w:onClose() end)
        T:waitUntil(function() return not UIManager:isWidgetShown(w) end, 5, "dictionary window to close")
    end
end

--- Classic (single sdcv run) results for `word`, for comparison.
function DictHelper.classic(T, ui, word)
    local results = T:run(function()
        local saved = G_reader_settings:readSetting("dict_progressive_lookup")
        G_reader_settings:saveSetting("dict_progressive_lookup", false)
        local fuzzy = not ui.dictionary.disable_fuzzy_search
        local ok, res = pcall(ui.dictionary.startSdcv, ui.dictionary, word, ui.dictionary.enabled_dict_names, fuzzy)
        G_reader_settings:saveSetting("dict_progressive_lookup", saved)
        if not ok then error(res) end
        return res
    end)
    return describe(results)
end

return DictHelper
