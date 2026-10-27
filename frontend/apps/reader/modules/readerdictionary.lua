local Archiver = require("ffi/archiver")
local BD = require("ui/bidi")
local BookList = require("ui/widget/booklist")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonSelector = require("ui/widget/buttonselector")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local DictQuickLookup = require("ui/widget/dictquicklookup")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local KeyValuePage = require("ui/widget/keyvaluepage")
local LuaData = require("luadata")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local NetworkMgr = require("ui/network/manager")
local Presets = require("ui/presets")
local SortWidget = require("ui/widget/sortwidget")
local TrapWidget = require("ui/widget/trapwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Utf8Proc = require("ffi/utf8proc")
local bit = require("bit")
local ffi = require("ffi")
local C = ffi.C
local ffiUtil  = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local posix = require("ffi/posix")
local rapidjson = require("rapidjson")
local time = require("ui/time")
local util  = require("util")
local _ = require("gettext")
local Input = Device.input
local T = ffiUtil.template
local android = Device:isAndroid() and require("android")

-- We'll store the list of available dictionaries as a module local
-- so we only have to look for them on the first :init()
local available_ifos = nil
local lookup_history = nil

local function getIfosInDir(path)
    -- Get all the .ifo under directory path.
    -- Don't walk into "res/" subdirectories, as per Stardict specs, they
    -- may contain possibly many resource files (image, audio files...)
    -- that could slow down our walk here.
    local ifos = {}
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if ok then
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." and name ~= "res" then
                local fullpath = path.."/"..name
                local attributes = lfs.attributes(fullpath)
                if attributes ~= nil then
                    if attributes.mode == "directory" then
                        local dirifos = getIfosInDir(fullpath) -- recurse
                        for _, ifo in pairs(dirifos) do
                            table.insert(ifos, ifo)
                        end
                    elseif fullpath:match("%.ifo$") then
                        table.insert(ifos, fullpath)
                    end
                end
            end
        end
    end
    return ifos
end

local ReaderDictionary = InputContainer:extend{
    data_dir = nil,
    lookup_msg = _("Searching dictionary for:\n%1"),
}

-- For a HTML dict, one can specify a specific stylesheet
-- in a file named as the .ifo with a .css extension
local function readDictionaryCss(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end

    local content = f:read("*all")
    f:close()
    return content
end

-- For a HTML dict, one can specify a function called on
-- the raw returned definition to "fix" the HTML if needed
-- (as MuPDF, used for rendering, is quite sensitive to the
-- HTML quality) in a file named as the .ifo with a .lua
-- extension, containing for example:
--    return function(html)
--        html = html:gsub("<hr>", "<hr/>")
--        return html
--    end
local function getDictionaryFixHtmlFunc(path)
    if lfs.attributes(path, "mode") == "file" then
        local ok, func = pcall(dofile, path)
        if ok and func then
            return func
        else
            logger.warn("Dict's user provided file failed:", func)
        end
    end
end

function ReaderDictionary:init()
    self._dict_buttons = {}
    self.disable_lookup_history = G_reader_settings:isTrue("disable_lookup_history")
    self.dicts_order = G_reader_settings:readSetting("dicts_order", {})
    self.dicts_disabled = G_reader_settings:readSetting("dicts_disabled", {})
    self.disable_fuzzy_search_fm = G_reader_settings:isTrue("disable_fuzzy_search")

    self.default_layout = {
        { "prev_dict", "highlight", "next_dict" },
        { "wikipedia",    "search",     "close" },
    }
    if Device:hasDPad() and Device:hasFewKeys() then
        table.insert(self.default_layout, 1, {"text_selection"})
    end

    if self.ui then
        self.ui.menu:registerToMainMenu(self)
    end
    self.data_dir = G_defaults:readSetting("STARDICT_DATA_DIR") or
        os.getenv("STARDICT_DATA_DIR") or
        DataStorage:getDataDir() .. "/data/dict"

    -- Show the "Searching..." InfoMessage after this delay
    self.lookup_msg_delay = 0.5
    -- Allow quick interruption or dismiss of search result window
    -- with tap if done before this delay. After this delay, the
    -- result window is shown and dismiss prevented for a few 100ms
    self.quick_dismiss_before_delay = time.s(3)

    -- Gather info about available dictionaries
    if not available_ifos then
        available_ifos = {}
        logger.dbg("Getting list of dictionaries")
        local ifo_files = getIfosInDir(self.data_dir)
        local dict_ext = self.data_dir.."_ext"
        if lfs.attributes(dict_ext, "mode") == "directory" then
            local extifos = getIfosInDir(dict_ext)
            for _, ifo in pairs(extifos) do
                table.insert(ifo_files, ifo)
            end
        end
        for _, ifo_file in pairs(ifo_files) do
            local f = io.open(ifo_file, "r")
            if f then
                local content = f:read("*all")
                f:close()
                local dictname = content:match("\nbookname=(.-)\r?\n")
                local is_html = content:find("sametypesequence=h", 1, true) ~= nil
                local lang_in, lang_out = content:match("lang=(%a+)-?(%a*)\r?\n?")
                -- sdcv won't use dict that don't have a bookname=
                if dictname then
                    table.insert(available_ifos, {
                        file = ifo_file,
                        name = dictname,
                        is_html = is_html,
                        css = readDictionaryCss(ifo_file:gsub("%.ifo$", ".css")),
                        fix_html_func = getDictionaryFixHtmlFunc(ifo_file:gsub("%.ifo$", ".lua")),
                        lang = lang_in and { lang_in = lang_in, lang_out = lang_out },
                    })
                end
            end
        end
        logger.dbg("found", #available_ifos, "dictionaries")
        self:sortAvailableIfos()
    end
    -- Prepare the -u options to give to sdcv the dictionary order and if some are disabled
    self:updateSdcvDictNamesOptions()

    if not lookup_history then
        lookup_history = LuaData:open(DataStorage:getSettingsDir() .. "/lookup_history.lua", "LookupHistory")
    end

    self.preset_obj = {
        presets = G_reader_settings:readSetting("dict_presets", {}),
        cycle_index = G_reader_settings:readSetting("dict_presets_cycle_index"),
        dispatcher_name = "load_dictionary_preset",
        saveCycleIndex = function(this)
            G_reader_settings:saveSetting("dict_presets_cycle_index", this.cycle_index)
        end,
        buildPreset = function() return self:buildPreset() end,
        loadPreset = function(preset) self:loadPreset(preset) end,
    }
end

function ReaderDictionary:addToDictButtons(spec)
    if type(spec) ~= "table" or type(spec.id) ~= "string" then
        logger.warn("ReaderDictionary: addToDictButtons expects a table with a string 'id'")
        return
    end
    self._dict_buttons[spec.id] = spec
end

-- function ReaderDictionary:registerKeyEvents()
--     Now handled by hotkeys.koplugin:
--     onShowDictionaryLookup = { { "Alt", "D" }, { "Ctrl", "D" } }
-- end

function ReaderDictionary:sortAvailableIfos()
    table.sort(available_ifos, function(lifo, rifo)
        local lord = self.dicts_order[lifo.file]
        local rord = self.dicts_order[rifo.file]

        -- Both ifos without an explicit position -> lexical comparison
        if lord == rord then
            return ffiUtil.strcoll(lifo.name, rifo.name)
        end

        -- Ifos without an explicit position come last.
        return lord ~= nil and (rord == nil or lord < rord)
    end)
end


function ReaderDictionary:updateSdcvDictNamesOptions()
    -- We cannot tell sdcv which dictionaries to ignore, but we
    -- can tell it which dictionaries to use, by using multiple
    -- -u <dictname> options.
    -- The order of the -u options controls the dictionary order
    -- that sdcv uses to order its results.

    self.enabled_dict_names = {}

    -- First, insert any preferred dicts, even if globally disabled
    -- (this might allow enabling a dict only for a specific book,
    -- while keeping it disabled for all others)
    local preferred_names_already_in = {}
    if self.preferred_dictionaries then
        for _, name in ipairs(self.preferred_dictionaries) do
            table.insert(self.enabled_dict_names, name)
            preferred_names_already_in[name] = true
        end
    end

    local dicts_disabled = G_reader_settings:readSetting("dicts_disabled")
    for _, ifo in pairs(available_ifos) do
        if not dicts_disabled[ifo.file] and not preferred_names_already_in[ifo.name] then
            table.insert(self.enabled_dict_names, ifo.name)
        end
    end
end

function ReaderDictionary:addToMainMenu(menu_items)
    local is_docless = self.ui == nil or self.ui.document == nil
    menu_items.search_settings = { -- submenu with Dict, Wiki, Translation settings
        text = _("Settings"),
    }
    menu_items.dictionary_lookup = {
        text = _("Dictionary lookup"),
        callback = function()
            self:onShowDictionaryLookup()
        end,
    }
    menu_items.dictionary_lookup_history = {
        text = _("Dictionary lookup history"),
        enabled_func = function()
            return lookup_history:has("lookup_history")
        end,
        callback = function()
            local lookup_history_table = lookup_history:readSetting("lookup_history")
            local kv_pairs = {}
            local previous_title
            for i = #lookup_history_table, 1, -1 do
                local value = lookup_history_table[i]
                if value.book_title ~= previous_title then
                    table.insert(kv_pairs, { value.book_title..":", "" })
                end
                previous_title = value.book_title
                table.insert(kv_pairs, {
                    os.date("%Y-%m-%d %H:%M:%S", value.time),
                    value.word,
                    callback = function()
                        -- Word had been cleaned before being added to history
                        self:onLookupWord(value.word, true)
                    end
                })
            end
            UIManager:show(KeyValuePage:new{
                title = _("Dictionary lookup history"),
                value_overflow_align = "right",
                kv_pairs = kv_pairs,
            })
        end,
    }
    menu_items.dictionary_settings = {
        text = _("Dictionary settings"),
        sub_item_table = {
            {
                keep_menu_open = true,
                text_func = function()
                    local nb_available, nb_enabled, nb_disabled = self:getNumberOfDictionaries()
                    local nb_str = nb_available
                    if nb_disabled > 0 then
                        nb_str = nb_enabled .. "/" .. nb_available
                    end
                    return T(_("Manage dictionaries: %1"), nb_str)
                end,
                enabled_func = function()
                    return self:getNumberOfDictionaries() > 0
                end,
                callback = function(touchmenu_instance)
                    self:showDictionariesMenu(function()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end)
                end,
            },
            {
                text = _("Dictionary presets"),
                help_text = _("This feature allows you to organize dictionaries into presets (for example, by language). You can quickly switch between these presets to change which dictionaries are used for lookups.\n\nNote: presets only store dictionaries, no other settings."),
                sub_item_table_func = function()
                    return Presets.genPresetMenuItemTable(self.preset_obj, _("Create new preset from enabled dictionaries"),
                        function() return self.enabled_dict_names and #self.enabled_dict_names > 0 end)
                end,
            },
            {
                text = _("Download dictionaries"),
                sub_item_table_func = function() return self:_genDownloadDictionariesMenu() end,
                separator = true,
            },
            {
                text_func = function()
                    local text = _("Enable fuzzy search")
                    if G_reader_settings:nilOrFalse("disable_fuzzy_search") then
                        text = text .. "   ★"
                    end
                    return text
                end,
                checked_func = function()
                    if self.ui.doc_settings then
                        return not self.disable_fuzzy_search
                    end
                    return not self.disable_fuzzy_search_fm
                end,
                callback = function()
                    if self.ui.doc_settings then
                        self.disable_fuzzy_search = not self.disable_fuzzy_search
                        self.ui.doc_settings:saveSetting("disable_fuzzy_search", self.disable_fuzzy_search)
                    else
                        self.disable_fuzzy_search_fm = not self.disable_fuzzy_search_fm
                    end
                end,
                hold_callback = function(touchmenu_instance)
                    self:toggleFuzzyDefault(touchmenu_instance)
                end,
                separator = true,
            },
            {
                text = _("Dictionary lookup history"),
                checked_func = function()
                    return not self.disable_lookup_history
                end,
                sub_item_table = {
                    {
                        text = _("Enable dictionary lookup history"),
                        checked_func = function()
                            return not self.disable_lookup_history
                        end,
                        callback = function()
                            self.disable_lookup_history = not self.disable_lookup_history
                            G_reader_settings:saveSetting("disable_lookup_history", self.disable_lookup_history)
                        end,
                    },
                    {
                        text = _("Clean dictionary lookup history"),
                        enabled_func = function()
                            return lookup_history:has("lookup_history")
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            UIManager:show(ConfirmBox:new{
                                text = _("Clean dictionary lookup history?"),
                                ok_text = _("Clean"),
                                ok_callback = function()
                                    -- empty data table to replace current one
                                    lookup_history:reset{}
                                    touchmenu_instance:updateItems()
                                end,
                            })
                        end,
                    },
                },
                separator = true,
            },
            { -- setting used by dictquicklookup
                text = _("Large window"),
                checked_func = function()
                    return G_reader_settings:isTrue("dict_largewindow")
                end,
                callback = function()
                    G_reader_settings:flipNilOrFalse("dict_largewindow")
                end,
            },
            { -- setting used by dictquicklookup
                text = _("Justify text"),
                checked_func = function()
                    return G_reader_settings:nilOrTrue("dict_justify")
                end,
                callback = function()
                    G_reader_settings:flipNilOrTrue("dict_justify")
                end,
            },
            { -- setting used by dictquicklookup
                text_func = function()
                    local font_size = G_reader_settings:readSetting("dict_font_size") or 20
                    return T(_("Font size: %1"), font_size)
                end,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local font_size = G_reader_settings:readSetting("dict_font_size") or 20
                    local items_font = SpinWidget:new{
                        value = font_size,
                        value_min = 8,
                        value_max = 32,
                        default_value = 20,
                        title_text = _("Dictionary font size"),
                        callback = function(spin)
                            G_reader_settings:saveSetting("dict_font_size", spin.value)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    }
                    UIManager:show(items_font)
                end,
                keep_menu_open = true,
            }
        }
    }
    table.insert(menu_items.dictionary_settings.sub_item_table, {
        text = _("Customize buttons"),
        sub_item_table_func = function()
            return self:_genCustomizeButtonsMenu()
        end,
    })
    if not is_docless then
        table.insert(menu_items.dictionary_settings.sub_item_table, 2, {
            keep_menu_open = true,
            text = _("Set dictionary priority for this book"),
            help_text = _("This feature enables you to specify dictionary priorities on a per-book basis. Results from higher-priority dictionaries will be displayed first when looking up words. Only dictionaries that are currently active can be selected and prioritized."),
            enabled_func = function()
                -- we allow to use preferred dictionaries even if no dictionaries are enabled globally (see self:updateSdcvDictNamesOptions)
                return #self.enabled_dict_names > 1 or #self.preferred_dictionaries > 0
            end,
            callback = function(touchmenu_instance)
                self:showPreferredDictsDialog(touchmenu_instance)
            end,
        })
    end
    if Device:canExternalDictLookup() then
        local function genExternalDictItems()
            local items_table = {}
            for i, v in ipairs(Device:getExternalDictLookupList()) do
                local setting = v[1]
                local dict_name = v[2]
                local is_enabled = v[3]
                table.insert(items_table, {
                    text = dict_name,
                    checked_func = function()
                        return setting == G_reader_settings:readSetting("external_dict_lookup_method")
                    end,
                    enabled_func = function()
                        return is_enabled == true
                    end,
                    callback = function()
                        G_reader_settings:saveSetting("external_dict_lookup_method", v[1])
                    end,
                })
            end
            return items_table
        end
        table.insert(menu_items.dictionary_settings.sub_item_table, 1, {
            text = _("Use external dictionary"),
            checked_func = function()
                return G_reader_settings:isTrue("external_dict_lookup")
            end,
            callback = function()
                G_reader_settings:flipNilOrFalse("external_dict_lookup")
            end,
        })
        table.insert(menu_items.dictionary_settings.sub_item_table, 2, {
            text_func = function()
                local display_name = _("none")
                local ext_id = G_reader_settings:readSetting("external_dict_lookup_method")
                for i, v in ipairs(Device:getExternalDictLookupList()) do
                    if v[1] == ext_id then
                        display_name = v[2]
                        break
                    end
                end
                return T(_("Dictionary: %1"), display_name)
            end,
            enabled_func = function()
                return G_reader_settings:isTrue("external_dict_lookup")
            end,
            sub_item_table = genExternalDictItems(),
            separator = true,
        })
    end
end

function ReaderDictionary:_genCustomizeButtonsMenu()
    local customize_buttons_menu = {}
    local available_options = {
        { text = _("Previous result"), id = "prev_dict" },
        { text = _("Highlight"),       id = "highlight" },
        { text = _("Next result"),     id = "next_dict" },
        { text = _("Wikipedia"),       id = "wikipedia" },
        { text = _("Search"),          id = "search" },
        { text = _("Close"),           id = "close" },
        { text = _("Translate"),       id = "translate" },
    }
    if Device:hasDPad() then
        table.insert(available_options, { text = _("Text selection"), id = "text_selection" })
    end

    for _, spec in ffiUtil.orderedPairs(self._dict_buttons) do
        if not spec.conditional and spec.menu_text then
            table.insert(available_options, { text = spec.menu_text, id = spec.id })
        end
        if not spec.conditional and not DictQuickLookup.layoutContainsButtonId(self.default_layout, spec.id) then
            local i = spec.insert_first and 1 or (#self.default_layout + 1)
            table.insert(self.default_layout, i, { spec.id })
        end
    end

    -- This function return the config from settings.
    local function getDictConfig()
        local config = util.tableDeepCopy(G_reader_settings:readSetting("dict_button_config"))
        if not config then
            config = {
                layout = self.default_layout,
                order = {},
                row_count = {}
            }
            for i = 1, #self.default_layout do
                config.row_count[i] = #self.default_layout[i]
            end
        end

        if #config.order == 0 then
            for _, row in ipairs(self.default_layout) do
                for _, id in ipairs(row) do
                    table.insert(config.order, id)
                end
            end
        end

        local in_order = {}
        for _, id in ipairs(config.order) do
            in_order[id] = true
        end
        for _, opt in ipairs(available_options) do
            if not in_order[opt.id] then
                table.insert(config.order, opt.id)
            end
        end

        return config
    end

    -- This helper regenerates the layout based on the given config, and saves it in settings.
    local function regenLayout(override_config, override_selected)
        local config = override_config or getDictConfig()

        local selected_ids = override_selected
        if not selected_ids then
            selected_ids = {}
            for _, row in ipairs(config.layout) do
                for _, id in ipairs(row) do
                    selected_ids[id] = true
                end
            end
        end

        local new_layout = {}
        local current_row = {}
        local row_idx = 1
        local max_in_row = config.row_count[row_idx] or 3

        for _, id in ipairs(config.order) do
            if selected_ids[id] then
                if #current_row >= max_in_row then
                    table.insert(new_layout, current_row)
                    current_row = {}
                    row_idx = row_idx + 1
                    max_in_row = config.row_count[row_idx] or 3
                end
                table.insert(current_row, id)
            end
        end
        if #current_row > 0 then
            table.insert(new_layout, current_row)
        end

        local new_row_count = {}
        for i = 1, #new_layout do
            new_row_count[i] = config.row_count[i] or 3
        end
        config.row_count = new_row_count

        config.layout = new_layout
        G_reader_settings:saveSetting("dict_button_config", config)
    end

    local rebuildRowMenu -- forward declaration for recursive use in genRowMenu
    -- This function generates dynamically the row submenu, according to the current config.
    local function genRowMenu()
        local config = getDictConfig()
        local layout_rows = config.layout
        for i = 1, #layout_rows do
            table.insert(customize_buttons_menu, {
                text_func = function()
                    return T(_("Max buttons in row %1: %2"), i, config.row_count[i] or 3)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        value = config.row_count[i] or 3,
                        value_min = 1,
                        value_max = 4,
                        default_value = self.default_layout[i] and #self.default_layout[i] or 3,
                        title_text = T(_("Max buttons in row %1"), i),
                        callback = function(spin)
                            config.row_count[i] = spin.value
                            regenLayout(config)
                            rebuildRowMenu()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
                separator = i == #layout_rows,
            })
        end

        table.insert(customize_buttons_menu, {
            text = _("Test button layout"),
            keep_menu_open = true,
            callback = function()
                local preview_word = "lorem"
                local preview_definition = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. " ..
                _("This is a mock definition used to preview dictionary button positions.") .. "\n\n" ..
                _("Tip: Place the Previous/Next buttons in the same row with two other buttons (4 total) to make them shrink and save space.")
                self:showDict(preview_word, {
                    {
                        dict = _("Layout preview"),
                        word = preview_word,
                        definition = preview_definition,
                    },
                })
            end,
        })
    end

    -- This rebuillds the row menu based on changes in the layout.
    local row_menu_start_idx = #customize_buttons_menu + 1
    function rebuildRowMenu()
        while #customize_buttons_menu >= row_menu_start_idx do
            table.remove(customize_buttons_menu)
        end
        genRowMenu()
    end

    table.insert(customize_buttons_menu, {
        text = _("Sort and toggle buttons"),
        keep_menu_open = true,
        separator = true,
        callback = function(touchmenu_instance)
            local config = getDictConfig()
            local selected_ids = {}
            for _, row in ipairs(config.layout) do
                for _, id in ipairs(row) do
                    selected_ids[id] = true
                end
            end

            local sort_items = {}
            local local_selected = util.tableDeepCopy(selected_ids)

            for _, id in ipairs(config.order) do
                for _, opt in ipairs(available_options) do
                    if opt.id == id then
                        table.insert(sort_items, {
                            text = opt.text,
                            id = opt.id,
                            checked_func = function() return local_selected[opt.id] end,
                            callback = function() local_selected[opt.id] = not local_selected[opt.id] end,
                        })
                        break
                    end
                end
            end

            UIManager:show(SortWidget:new{
                title = _("Sort and toggle buttons"),
                item_table = sort_items,
                callback = function()
                    local new_order = {}

                    for _, item in ipairs(sort_items) do
                        table.insert(new_order, item.id)
                    end

                    config.order = new_order
                    regenLayout(config, local_selected)
                    rebuildRowMenu()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end
            })
        end,
        hold_callback = function(touchmenu_instance)
             UIManager:show(ConfirmBox:new{
                text = _("Would you like to reset the button layout?"),
                ok_text = _("Reset"),
                ok_callback = function()
                    G_reader_settings:delSetting("dict_button_config")
                    rebuildRowMenu()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
             })
        end,
    })
    row_menu_start_idx = #customize_buttons_menu + 1
    genRowMenu()
    return customize_buttons_menu
end

function ReaderDictionary:showPreferredDictsDialog(touchmenu_instance)
    local dialog
    local buttons = {}
    local disabled_buttons = {}  -- store disabled dict buttons separately
    local update_sdcv = true

    local function saveAndRefresh()
        self:onSaveSettings()
        if update_sdcv then self:updateSdcvDictNamesOptions() end
        UIManager:close(dialog)
        if #self.enabled_dict_names == 0 then
            -- This is an edge case where we have a preferred dictionary but no globally enabled ones.
            -- If we un-prefer said dict, we would end up with an empty dialog, so close up shop and go home.
            touchmenu_instance:updateItems()
            return
        end
        self:showPreferredDictsDialog(touchmenu_instance)
    end

    local function makeButtonEntry(dict, is_enabled)
        local is_preferred = false
        local pref_num = 0
        for i, pref_dict in ipairs(self.preferred_dictionaries) do
            if pref_dict == dict then
                is_preferred = true
                pref_num = i
                break
            end
        end

        local button_text = dict
        if is_preferred and is_enabled then
            -- Add circled number (U+2460...2473) at start
            local symbol = util.unicodeCodepointToUtf8(0x245F + (pref_num < 20 and pref_num or 20))
            button_text = symbol .. " " .. button_text
        elseif not is_enabled then
            -- Add circled x (U+2297) at start for disabled dictionaries
            button_text = "⊗ " .. button_text
        end

        return {
            {
                align = "left",
                text = button_text,
                callback = function()
                    if not is_enabled then return end -- No toggle for disabled dicts
                    if is_preferred then
                        for i, pref_dict in ipairs(self.preferred_dictionaries) do
                            if pref_dict == dict then
                                table.remove(self.preferred_dictionaries, i)
                                break
                            end
                        end
                    else
                        table.insert(self.preferred_dictionaries, dict)
                    end
                    saveAndRefresh()
                end,
                hold_callback = function()
                    if not is_enabled then -- re-enable dictionary
                        self.doc_disabled_dicts[dict] = nil
                    else -- disable dictionary for this book
                        self.doc_disabled_dicts[dict] = true
                    end
                    update_sdcv = false
                    saveAndRefresh()
                end,
            }
        }
    end

    -- Process enabled dictionaries first.
    for _, dict in ipairs(self.enabled_dict_names) do
        if not self.doc_disabled_dicts[dict] then
            table.insert(buttons, makeButtonEntry(dict, true))
        else
            table.insert(disabled_buttons, makeButtonEntry(dict, false))
        end
    end

    -- Append disabled dictionaries at the bottom of the list.
    for _, btn in ipairs(disabled_buttons) do
        table.insert(buttons, btn)
    end

    table.insert(buttons, {
        {
            text = _("Reset"),
            callback = function()
                self.doc_disabled_dicts = {}
                self.preferred_dictionaries = {}
                saveAndRefresh()
            end,
        }
    })

    dialog = ButtonDialog:new{
        title = _("Select preferred dictionaries"),
        title_align = "center",
        shrink_unneeded_width = true,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function ReaderDictionary:onLookupWord(word, is_sane, boxes, highlight, link, dict_close_callback)
    logger.dbg("dict lookup word:", word, boxes)
    -- escape quotes and other funny characters in word
    word = self:cleanSelection(word, is_sane)
    logger.dbg("dict stripped word:", word)
    -- (If word ends up empty, we still do the lookup, which will give us
    -- a window with no result. This will ensure the normal cleanup of the
    -- highlight when closing this "no result" window, which is easier than
    -- trying to do it here if we were skipping the lookup.)

    self.highlight = highlight
    local disable_fuzzy_search
    if self.ui.doc_settings then
        disable_fuzzy_search = self.disable_fuzzy_search
    else
        disable_fuzzy_search = self.disable_fuzzy_search_fm
    end

    -- Wrapped through Trapper, as we may be using Trapper:dismissablePopen() in it
    Trapper:wrap(function()
        self:stardictLookup(word, self.enabled_dict_names, not disable_fuzzy_search, boxes, link, dict_close_callback)
    end)
    return true
end

function ReaderDictionary:onHtmlDictionaryLinkTapped(dictionary, link)
    if not link.uri then
        return
    end

    -- The protocol is either "bword" or there is no protocol, only the word.
    -- https://github.com/koreader/koreader/issues/3588#issuecomment-357088125
    local url_prefix = "bword://"
    local word
    if link.uri:sub(1,url_prefix:len()) == url_prefix then
        word = link.uri:sub(url_prefix:len() + 1)
    elseif link.uri:find("://") then
        return
    else
        word = link.uri
    end

    if word == "" then
        return
    end

    local link_box = Geom:new{
        x = link.x0,
        y = link.y0,
        w = math.abs(link.x1 - link.x0),
        h = math.abs(link.y1 - link.y0),
    }

    -- Only the first dictionary window stores the highlight, this way the highlight
    -- is only removed when there are no more dictionary windows open.
    self.highlight = nil

    -- Wrapped through Trapper, as we may be using Trapper:dismissablePopen() in it
    Trapper:wrap(function()
        self:stardictLookup(word, {dictionary}, false, {link_box}, nil)
    end)
end

--- Gets number of available, enabled, and disabled dictionaries
-- @treturn int nb_available
-- @treturn int nb_enabled
-- @treturn int nb_disabled
function ReaderDictionary:getNumberOfDictionaries()
    local nb_available = #available_ifos
    local nb_enabled = 0
    local nb_disabled = 0
    for _, ifo in pairs(available_ifos) do
        if self.dicts_disabled[ifo.file] then
            nb_disabled = nb_disabled + 1
        else
            nb_enabled = nb_enabled + 1
        end
    end
    return nb_available, nb_enabled, nb_disabled
end

function ReaderDictionary:_genDownloadDictionariesMenu()
    local downloadable_dicts = require("ui/data/dictionaries")
    local IsoLanguage = require("ui/data/isolanguage")
    local languages = {}

    for i = 1, #downloadable_dicts do
        local dict = downloadable_dicts[i]
        if not dict.ifo_lang then
            -- this only needs to happen the first time this function is called
            local ifo_in = IsoLanguage:getBCPLanguageTag(dict.lang_in)
            local ifo_out = IsoLanguage:getBCPLanguageTag(dict.lang_out)
            dict.ifo_lang = ("%s-%s"):format(ifo_in, ifo_out)
            dict.lang_in = IsoLanguage:getLocalizedLanguage(dict.lang_in)
            dict.lang_out = IsoLanguage:getLocalizedLanguage(dict.lang_out)
        end
        local dict_lang_in = dict.lang_in
        local dict_lang_out = dict.lang_out
        if not languages[dict_lang_in] then
            languages[dict_lang_in] = {}
        end
        table.insert(languages[dict_lang_in], dict)
        if not languages[dict_lang_out] then
            languages[dict_lang_out] = {}
        end
        table.insert(languages[dict_lang_out], dict)
    end

    -- remove duplicates
    for lang_key,lang in pairs(languages) do
        local hash = {}
        local res = {}
        for k,v in ipairs(lang) do
           if not hash[v.name] then
               res[#res+1] = v
               hash[v.name] = true
           end
        end
        languages[lang_key] = res
    end

    local menu_items = {}
    for lang_key, available_langs in ffiUtil.orderedPairs(languages) do
        table.insert(menu_items, {
            keep_menu_open = true,
            text = lang_key,
            callback = function()
                self:showDownload(lang_key, available_langs)
            end
        })
    end

    return menu_items
end

function ReaderDictionary:showDictionariesMenu(changed_callback)
    -- Work on local copy, save to settings only when SortWidget is closed with the accept button
    local dicts_disabled = util.tableDeepCopy(self.dicts_disabled)

    local sort_items = {}
    for _, ifo in pairs(available_ifos) do
        table.insert(sort_items, {
            text = ifo.name,
            callback = function()
                if dicts_disabled[ifo.file] then
                    dicts_disabled[ifo.file] = nil
                else
                    dicts_disabled[ifo.file] = true
                end
            end,
            checked_func = function()
                return not dicts_disabled[ifo.file]
            end,
            ifo = ifo,
        })
    end

    local sort_widget = SortWidget:new{
        title = _("Manage installed dictionaries"),
        item_table = sort_items,
        callback = function()
            -- Update both references to point to that new object
            self.dicts_disabled = dicts_disabled
            G_reader_settings:saveSetting("dicts_disabled", self.dicts_disabled)

            -- Write back the sorted items array to dicts_order
            local dicts_order = {}
            for i, sort_item in ipairs(sort_items) do
                dicts_order[sort_item.ifo.file] = i
            end
            self.dicts_order = dicts_order
            G_reader_settings:saveSetting("dicts_order", self.dicts_order)

            self:sortAvailableIfos()

            self:updateSdcvDictNamesOptions()

            UIManager:setDirty(nil, "ui")
            changed_callback()
        end
    }
    UIManager:show(sort_widget)
end

local function dictDirsEmpty(dict_dirs)
    for _, dict_dir in ipairs(dict_dirs) do
        if not util.isEmptyDir(dict_dir) then
            return false
        end
    end
    return true
end

local function getAvailableIfoByName(dictionary_name)
    for _, ifo in ipairs(available_ifos) do
        if ifo.name == dictionary_name then
            return ifo
        end
    end

    return nil
end

local function tidyMarkup(results)
    local cdata_tag = "<!%[CDATA%[(.-)%]%]>"
    local format_escape = "&[29Ib%+]{(.-)}"
    for _, result in ipairs(results) do
        local ifo = getAvailableIfoByName(result.dict)
        if ifo and ifo.lang then
            result.ifo_lang = ifo.lang
        end
        if ifo and ifo.is_html then
            local dict_path = util.splitFilePathName(ifo.file)
            result.is_html = ifo.is_html
            result.css = ifo.css
            if ifo.fix_html_func then
                local ok, fixed_definition = pcall(ifo.fix_html_func, result.definition, dict_path)
                if ok then
                    result.definition = fixed_definition
                else
                    logger.warn("Dict's user provided function failed:", fixed_definition)
                end
            end

            local res_dir = dict_path .. "res"
            if lfs.attributes(res_dir, "mode") == "directory" then
                result.dictionary_resource_directory = res_dir
            end
        else
            local def = result.definition
            -- preserve the <br> tag for line break
            def = def:gsub("<[bB][rR] ?/?>", "\n")
            -- parse CDATA text in XML
            if def:find(cdata_tag) then
                def = def:gsub(cdata_tag, "%1")
                -- ignore format strings
                while def:find(format_escape) do
                    def = def:gsub(format_escape, "%1")
                end
            end
            -- convert any htmlentities (&gt;, &quot;...)
            def = util.htmlEntitiesToUtf8(def)
            -- ignore all markup tags
            def = def:gsub("%b<>", "")
            -- strip all leading empty lines/spaces
            def = def:gsub("^%s+", "")
            result.definition = def
        end
    end
    return results
end

function ReaderDictionary:cleanSelection(text, is_sane)
    -- Will be used by ReaderWikipedia too
    if not text then
        return ""
    end
    -- crengine does now a much better job at finding word boundaries, but
    -- some cleanup is still needed for selection we get from other engines
    -- (example: pdf selection "qu’autrefois," will be cleaned to "autrefois")
    --
    -- Replace no-break space with regular space
    text = text:gsub("\u{00A0}", ' ')
    -- Trim any space at start or end
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    if not is_sane then
        -- Replace extended quote (included in the general puncturation range)
        -- with plain ascii quote (for french words like "aujourd’hui")
        text = text:gsub("\u{2019}", "'") -- Right single quotation mark
        -- Strip punctuation characters around selection
        text = util.stripPunctuation(text)
        -- Note: although it seems innocuous to use a character class [·|↑] to perform a single gsub,
        --       doing so will cause byte corruption in some languages (e.g. Greek).
        -- In some dictionaries, both interpuncts and pipes are used to delimiter syllables.
        text = text:gsub("·", "") -- interpunct
        text = text:gsub("|", "") -- pipe
        text = text:gsub("↑", "") -- and up arrow, used in some dictionaries to indicate related words
        text = text:gsub("ˈ", "") -- primary stress mark, used in phonetic transcriptions to indicate a stressed syllable
        text = text:gsub("ˌ", "") -- secondary stress mark, used in phonetic transcriptions to indicate a weaker stressed syllable
        -- Strip some common english grammatical construct
        text = text:gsub("'s$", '') -- english possessive
        -- Strip some common french grammatical constructs
        text = text:gsub("^[LSDMNTlsdmnt]'", '') -- french l' s' t'...
        text = text:gsub("^[Qq][Uu]'", '') -- french qu'
        -- There may be a need to remove some (all?) diacritical marks
        -- https://en.wikipedia.org/wiki/Combining_character#Unicode_ranges
        -- see discussion at https://github.com/koreader/koreader/issues/1649
        -- Commented for now, will have to be checked by people who read
        -- languages and texts that use them.
        -- text = text:gsub("\204[\128-\191]", '') -- U+0300 to U+033F
        -- text = text:gsub("\205[\128-\175]", '') -- U+0340 to U+036F
        -- Trim any space now at start or end after above changes
        text = text:gsub("^%s+", "")
        text = text:gsub("%s+$", "")
    end
    return text
end

function ReaderDictionary:showLookupInfo(word, show_delay)
    local text = T(self.lookup_msg, word)
    self.lookup_progress_msg = InfoMessage:new{
        text = text,
        show_delay = show_delay,
    }
    UIManager:show(self.lookup_progress_msg)
end

function ReaderDictionary:dismissLookupInfo()
    if self.lookup_progress_msg then
        UIManager:close(self.lookup_progress_msg)
    end
    self.lookup_progress_msg = nil
end

function ReaderDictionary:onShowDictionaryLookup()
    local buttons = {}
    local preset_names = Presets.getPresets(self.preset_obj)
    if preset_names and #preset_names > 0 then
        table.insert(buttons, {
            {
                text = _("Search with preset"),
                callback = function()
                    local text = self.dictionary_lookup_dialog:getInputText()
                    if text == "" or text:match("^%s*$") then return end
                    self:showSearchWithPresetDialog(preset_names, self.dictionary_lookup_dialog, text)
                end,
            }
        })
    end

    table.insert(buttons, {
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                UIManager:close(self.dictionary_lookup_dialog)
            end,
        },
        {
            text = _("Search dictionary"),
            is_enter_default = true,
            callback = function()
                if self.dictionary_lookup_dialog:getInputText() == "" then return end
                UIManager:close(self.dictionary_lookup_dialog)
                -- Trust that input text does not need any cleaning (allows querying for "-suffix")
                self:onLookupWord(self.dictionary_lookup_dialog:getInputText(), true)
            end,
        },
    })

    self.dictionary_lookup_dialog = InputDialog:new{
        title = _("Enter a word or phrase to look up"),
        input = "",
        input_type = "text",
        buttons = buttons,
    }
    UIManager:show(self.dictionary_lookup_dialog)
    self.dictionary_lookup_dialog:onShowKeyboard()
    return true
end

function ReaderDictionary:showSearchWithPresetDialog(preset_names, input_dialog, word, boxes, link, dict_close_callback)
    if not preset_names then
        preset_names = Presets.getPresets(self.preset_obj)
    end
    local current_dict_state = self:buildPreset()
    local button_dialog, buttons = nil, {}
    for _, preset_name in ipairs(preset_names) do
        table.insert(buttons, {
            {
                align = "left",
                text = preset_name,
                callback = function()
                    self:loadPreset(self.preset_obj.presets[preset_name], true)
                    UIManager:close(button_dialog)
                    UIManager:close(input_dialog)
                    self:onLookupWord(word, true, boxes, self.highlight, link,
                        function()
                            self:loadPreset(current_dict_state, true)
                            if dict_close_callback then dict_close_callback() end
                        end
                    )
                end,
            }
        })
    end
    button_dialog = ButtonDialog:new{
        buttons = buttons,
        shrink_unneeded_width = true,
    }
    if input_dialog then input_dialog:onCloseKeyboard() end
    UIManager:show(button_dialog)
end

-- sdcv is run directly (no shell in between), with its stdout connected to a
-- non-blocking pipe, so we can collect its output from the UI loop without ever
-- blocking it: this allows for a lookup that can be interrupted with a tap (see
-- ReaderDictionary:waitForSdcv()), and that doesn't add much latency.
local SdcvProcess = {}
SdcvProcess.__index = SdcvProcess

local SDCV_READ_SIZE = 16384
local sdcv_read_buffer = nil

-- We'd rather use posix_spawn() than fork(): it doesn't have to copy our (big) page
-- tables, and doesn't trigger the fork hooks some platforms need (i.e., SDL ones, that
-- can take a few 100 ms). It's not in our posix_h: declare what we need, using opaque
-- buffers for its types (whose size and layout depend on the libc).
pcall(ffi.cdef, [[
int posix_spawnp(int *, const char *, const void *, const void *, char *const *, char *const *);
int posix_spawn_file_actions_init(void *);
int posix_spawn_file_actions_adddup2(void *, int, int);
int posix_spawn_file_actions_addclose(void *, int);
int posix_spawn_file_actions_destroy(void *);
int posix_spawnattr_init(void *);
int posix_spawnattr_setflags(void *, short);
int posix_spawnattr_destroy(void *);
extern char **environ;
]])
local has_posix_spawn = pcall(function()
    return C.posix_spawnp, C.posix_spawn_file_actions_init, C.posix_spawn_file_actions_adddup2,
           C.posix_spawn_file_actions_addclose, C.posix_spawn_file_actions_destroy,
           C.posix_spawnattr_init, C.posix_spawnattr_setflags, C.posix_spawnattr_destroy, C.environ
end)

-- Runs args (no shell involved) with its stdout redirected to write_fd, closing read_fd in the child.
local function spawn(args, write_fd, read_fd)
    local argv = ffi.new("char *[?]", #args + 1) -- zero-filled, so NULL terminated
    for i, arg in ipairs(args) do
        argv[i-1] = ffi.cast("char *", arg)
    end
    if has_posix_spawn then
        local file_actions = ffi.new("uint8_t[1024]") -- (bigger than any libc's posix_spawn_file_actions_t)
        local attr = ffi.new("uint8_t[1024]") -- (same for posix_spawnattr_t)
        C.posix_spawn_file_actions_init(file_actions)
        C.posix_spawn_file_actions_addclose(file_actions, read_fd)
        if write_fd ~= 1 then
            C.posix_spawn_file_actions_adddup2(file_actions, write_fd, 1)
            C.posix_spawn_file_actions_addclose(file_actions, write_fd)
        end
        C.posix_spawnattr_init(attr)
        if ffi.os == "Linux" then
            -- POSIX_SPAWN_USEVFORK: older glibc would fork() otherwise (newer ones ignore it)
            C.posix_spawnattr_setflags(attr, 0x40)
        end
        local pid = ffi.new("int[1]")
        local err = C.posix_spawnp(pid, args[1], file_actions, attr, argv, C.environ)
        C.posix_spawn_file_actions_destroy(file_actions)
        C.posix_spawnattr_destroy(attr)
        if err ~= 0 then
            return nil, posix.strerror(err)
        end
        return pid[0]
    end
    local pid, err = ffiUtil.runInSubProcess(function()
        -- In the child: have it write to our pipe, and replace ourselves with it
        if write_fd ~= 1 then
            C.dup2(write_fd, 1)
            C.close(write_fd)
        end
        C.execvp(args[1], argv)
        C._exit(127) -- only reached if exec failed
    end)
    return pid, err
end

--- Starts sdcv.
-- @tparam table args sdcv path and arguments
-- @treturn SdcvProcess|nil nil if it could not be started
function SdcvProcess:new(args)
    local pipe = ffi.new("int[2]", -1, -1)
    if C.pipe(pipe) ~= 0 then
        logger.warn("ReaderDictionary: could not create pipe for sdcv:", posix.strerror())
        return
    end
    local read_fd, write_fd = pipe[0], pipe[1]
    -- Don't leak our side of the pipe into any other process we may start
    C.fcntl(read_fd, C.F_SETFD, ffi.cast("int", C.FD_CLOEXEC))
    if android then
        -- NOTE: Bionic doesn't support rpath, but does honor LD_LIBRARY_PATH...
        --       Give it a shove so it can actually find the STL.
        C.setenv("LD_LIBRARY_PATH", android.nativeLibraryDir, 1)
    end
    local pid, err = spawn(args, write_fd, read_fd)
    if android then
        -- NOTE: It's unset by default, so this is perfectly fine.
        C.unsetenv("LD_LIBRARY_PATH")
    end
    C.close(write_fd)
    if not pid then
        C.close(read_fd)
        logger.warn("ReaderDictionary: could not start sdcv:", err)
        return
    end
    -- So that reading never blocks (fcntl() is variadic: make sure we pass it an int)
    C.fcntl(read_fd, C.F_SETFL, ffi.cast("int", bit.bor(C.fcntl(read_fd, C.F_GETFL), C.O_NONBLOCK)))
    return setmetatable({ pid = pid, fd = read_fd, chunks = {} }, SdcvProcess)
end

--- Reads whatever output is available, without blocking.
-- @treturn bool true when sdcv is done, false if it is still running
function SdcvProcess:poll()
    if not self.fd then
        return true
    end
    if not sdcv_read_buffer then
        sdcv_read_buffer = ffi.new("char[?]", SDCV_READ_SIZE)
    end
    while true do
        local nb_read = tonumber(C.read(self.fd, sdcv_read_buffer, SDCV_READ_SIZE))
        if nb_read > 0 then
            table.insert(self.chunks, ffi.string(sdcv_read_buffer, nb_read))
        elseif nb_read == 0 then -- EOF: sdcv is exiting
            self:stop()
            return true
        else
            local errno = ffi.errno()
            if errno == C.EAGAIN then -- nothing more for now
                return false
            elseif errno ~= C.EINTR then
                logger.warn("ReaderDictionary: could not read sdcv output:", posix.strerror(errno))
                self:stop(true)
                return true
            end
        end
    end
end

--- Waits (blocking) for sdcv to be done, collecting its output.
function SdcvProcess:wait()
    if not self.fd then
        return
    end
    local pfd = ffi.new("struct pollfd[1]")
    pfd[0].fd = self.fd
    pfd[0].events = C.POLLIN
    while not self:poll() do
        C.poll(pfd, 1, -1)
    end
end

--- Closes our side of the pipe, and collects the process (killing it first, if kill is true).
function SdcvProcess:stop(kill)
    if self.fd then
        C.close(self.fd)
        self.fd = nil
    end
    local pid = self.pid
    if not pid then
        return
    end
    self.pid = nil
    if ffiUtil.isSubProcessDone(pid) then
        return
    end
    if kill then
        C.kill(pid, 9) -- SIGKILL (sdcv doesn't start any child process of its own)
    end
    -- It's about to exit (or has been killed): collect it a bit later, so it doesn't linger as a zombie.
    local collect
    collect = function()
        if not ffiUtil.isSubProcessDone(pid) then
            UIManager:scheduleIn(0.1, collect)
        end
    end
    UIManager:scheduleIn(0.01, collect)
end

function SdcvProcess:getOutput()
    return table.concat(self.chunks)
end

-- How long to wait before checking again for sdcv output: quite often at first,
-- so we don't add much latency to quick lookups, and less and less often as
-- time passes, so we don't wake up for nothing too often during long ones.
local function getSdcvPollInterval(start_time)
    return math.min(math.max(time.to_s(time.since(start_time)) / 8, 0.01), 0.25)
end

--- Waits for sdcv to be done, and returns its output.
-- When run in a coroutine (i.e., wrapped through Trapper), the UI loop keeps running while
-- we wait, and a tap on trap_widget_or_false interrupts the wait and kills sdcv (as with
-- Trapper:dismissablePopen(): if false, an invisible TrapWidget not resending the tap is used).
-- When not run in a coroutine, we just block until sdcv is done.
-- @tparam SdcvProcess proc
-- @param trap_widget_or_false already shown widget (i.e., an InfoMessage), false or nil
-- @treturn bool completed (false if interrupted)
-- @treturn string output
function ReaderDictionary:waitForSdcv(proc, trap_widget_or_false)
    local _coroutine = coroutine.running()
    if not _coroutine then
        proc:wait()
        return true, proc:getOutput()
    end

    local trap_widget
    local own_trap_widget = type(trap_widget_or_false) ~= "table"
    if own_trap_widget then
        trap_widget = TrapWidget:new{
            text = nil,
            resend_event = trap_widget_or_false ~= false,
        }
        UIManager:show(trap_widget)
    else
        trap_widget = trap_widget_or_false
    end
    -- Restored when done, so a later tap doesn't resume our coroutine at some other yield
    local orig_dismiss_callback = trap_widget.dismiss_callback
    trap_widget.dismiss_callback = function()
        -- this resumes us at coroutine.yield() below, with go_on = false
        coroutine.resume(_coroutine, false)
    end

    local completed = false
    local start_time = time.now()
    local go_on_func = function() coroutine.resume(_coroutine, true) end
    while true do
        UIManager:scheduleIn(getSdcvPollInterval(start_time), go_on_func)
        local go_on = coroutine.yield() -- gives control back to UIManager
        if not go_on then -- dismissed
            UIManager:unschedule(go_on_func)
            proc:stop(true)
            break
        end
        if proc:poll() then
            completed = true
            break
        end
    end

    if own_trap_widget then
        UIManager:close(trap_widget)
    else
        trap_widget.dismiss_callback = orig_dismiss_callback
    end
    return completed, proc:getOutput()
end

function ReaderDictionary:getDictDirs()
    -- Allow for two sdcv calls : one in the classic data/dict, and
    -- another one in data/dict_ext if it exists
    -- We could put in data/dict_ext dictionaries with a great number of words
    -- but poor definitions as a fall back. If these were in data/dict,
    -- they would prevent fuzzy searches in other dictories with better
    -- definitions, and masks such results. This way, we can get both.
    local dict_dirs = {self.data_dir}
    local dict_ext = self.data_dir.."_ext"
    if lfs.attributes(dict_ext, "mode") == "directory" then
        table.insert(dict_dirs, dict_ext)
    end
    return dict_dirs
end

function ReaderDictionary:getSdcvArgs(dict_dir, words, dict_names, fuzzy_search)
    local args = {
        android and (android.nativeLibraryDir .. "/libsdcv.so") or "./sdcv",
        "--utf8-input",
        "--utf8-output",
        "--json-output",
        "--non-interactive",
        "--data-dir", dict_dir,
    }
    if not fuzzy_search then
        table.insert(args, "--exact-search")
    end
    if dict_names then
        for _, opt in pairs(dict_names) do
            table.insert(args, "-u")
            table.insert(args, opt)
        end
    end
    table.insert(args, "--") -- prevent words starting with a "-" to be interpreted as a sdcv option
    util.arrayAppend(args, words)
    return args
end

--- Runs sdcv, and returns its output (see waitForSdcv()).
function ReaderDictionary:runSdcv(args, trap_widget_or_false)
    -- Some sdcv lookups, when using fuzzy search with many dictionaries
    -- and a really bad selected text, can take up to 10 seconds.
    -- It is nice to be able to cancel it when noticing wrong text was
    -- selected.
    -- When fuzzy search is enabled, we have a lookup_progress_msg that can
    -- be used to catch a tap and trigger cancellation.
    -- When fuzzy search is disabled, we provide false instead so an
    -- invisible non-event-forwarding TrapWidget is used to catch a tap
    -- and trigger cancellation (invisible so there's no need for repaint
    -- and refresh with the usually fast non-fuzzy search lookups).
    local proc = SdcvProcess:new(args)
    if not proc then
        return false
    end
    return self:waitForSdcv(proc, trap_widget_or_false)
end

-- sdcv can return multiple results if we passed multiple words to
-- the cmdline. In this case, the lookup results for each word are
-- newline separated. The JSON output doesn't contain raw newlines
-- so it's safe to split.
-- (We use rapidjson, as definitions can be quite large, i.e. a few 100 KB
-- for HTML dictionaries, and it is more than 10 times faster than luajson.)
local function parseSdcvOutput(results_str, nb_words)
    local results_by_word = {}
    for _, entry_str in ipairs(util.splitToArray(results_str, "\n")) do
        local ok, results = pcall(rapidjson.decode, entry_str)
        if not ok or type(results) ~= "table" then
            logger.warn("JSON data cannot be decoded", results)
            -- Need to insert an empty table so that the word entries
            -- match up to the result entries (so that callers can
            -- batch lookups to reduce the cost of bulk lookups while
            -- still being able to figure out which lookup came from
            -- which word).
            results = {}
        end
        table.insert(results_by_word, results)
    end
    if #results_by_word ~= nb_words then
        logger.warn("sdcv returned a different number of results than the number of words")
    end
    return results_by_word
end

function ReaderDictionary:rawSdcv(words, dict_names, fuzzy_search, lookup_progress_msg)
    local dict_dirs = self:getDictDirs()
    -- early exit if no dictionaries
    if dictDirsEmpty(dict_dirs) then
        return false, nil
    end
    local all_results = {}
    local lookup_cancelled = false
    for _, dict_dir in ipairs(dict_dirs) do
        if lookup_cancelled then
            break -- don't do any more lookup on additional dict_dirs
        end
        local args = self:getSdcvArgs(dict_dir, words, dict_names, fuzzy_search)
        local completed, results_str = self:runSdcv(args, lookup_progress_msg)
        lookup_cancelled = not completed
        if results_str and results_str ~= "" then
            for idx, results in ipairs(parseSdcvOutput(results_str, #words)) do
                if all_results[idx] then
                    util.arrayAppend(all_results[idx], results)
                else
                    table.insert(all_results, results)
                end
            end
        end
    end
    return lookup_cancelled, all_results
end

--- Returns the words to look up for the selected word, and whether fuzzy search should be used.
function ReaderDictionary:getSdcvWords(word, fuzzy_search)
    local words = {word}
    -- If a word starts with a capital letter, add lowercase version to words array.
    if not fuzzy_search then
        local lowercased = Utf8Proc.lowercase(word, false)
        if word ~= lowercased then
            table.insert(words, lowercased)
        end
    end

    if self.ui.languagesupport and self.ui.languagesupport:hasActiveLanguagePlugins() then
        -- Get any other candidates from any language-specific plugins we have.
        -- We prefer the originally selected word first (in case there is a
        -- dictionary entry for whatever text the user selected).
        local candidates = self.ui.languagesupport:extraDictionaryFormCandidates(word)
        if candidates then
            -- (Skip the ones we already have, i.e. the word itself: sdcv would
            -- look them up and output their results again, for nothing.)
            for _, candidate in ipairs(candidates) do
                if not util.arrayContains(words, candidate) then
                    table.insert(words, candidate)
                end
            end
        end
    end

    -- If every word contains a CJK character, every word candidate is
    -- (probably) a CJK word. We don't want fuzzy searching in this case
    -- because sdcv cannot handle CJK text properly when fuzzy searching (with
    -- Japanese, it returns hundreds of useless results).
    local shouldnt_fuzzy_search = true
    for _, w in ipairs(words) do
        if not util.hasCJKChar(w) then
            shouldnt_fuzzy_search = false
            break
        end
    end
    if shouldnt_fuzzy_search then
        logger.dbg("disabling fuzzy searching for all-CJK word search:", words)
        fuzzy_search = false
    end
    return words, fuzzy_search
end

-- Returns the final results list, from the flat list of results (or dummy ones if none)
local function finalizeSdcvResults(word, results, lookup_cancelled)
    if #results == 0 then -- no results found
        -- dummy results
        results = {
            {
                dict = _("Not available"),
                word = word,
                definition = lookup_cancelled and _("Dictionary lookup interrupted.") or _("No results."),
                no_result = true,
                lookup_cancelled = lookup_cancelled,
            }
        }
    end
    if lookup_cancelled then
        -- Also put this as a k/v into the results array: when using dict_ext,
        -- we may get results from the 1st lookup, and have interrupted the 2nd.
        results.lookup_cancelled = true
    end
    return results
end

function ReaderDictionary:startSdcv(word, dict_names, fuzzy_search)
    local words
    words, fuzzy_search = self:getSdcvWords(word, fuzzy_search)
    local lookup_cancelled, results = self:rawSdcv(words, dict_names, fuzzy_search, self.lookup_progress_msg or false)
    if results == nil then -- no dictionaries found
        return {
            {
                dict = "",
                word = word,
                definition = _([[No dictionaries installed. Please search for "Dictionary support" in the KOReader Wiki to get more information about installing new dictionaries.]]),
            }
        }
    end
    -- flatten any possible results
    local flat_results = {}
    local seen_results = {}
    -- Flatten the array, removing any duplicates we may have gotten (sdcv
    -- may do multiple queries, in fixed mode then in fuzzy mode, and the
    -- language-specific plugin may have also returned multiple equivalent
    -- results).
    local h
    for _, term_results in ipairs(results) do
        for _, r in ipairs(term_results) do
            h = r.dict .. r.word .. r.definition
            if seen_results[h] == nil then
                table.insert(flat_results, r)
                seen_results[h] = true
            end
        end
    end
    return finalizeSdcvResults(word, flat_results, lookup_cancelled)
end

function ReaderDictionary:stardictLookup(word, dict_names, fuzzy_search, boxes, link, dict_close_callback)
    local book_title = self.ui.doc_props and self.ui.doc_props.display_title or _("Dictionary lookup")

    -- Event for plugin to catch lookup with book title
    self.ui:handleEvent(Event:new("WordLookedUp", word, book_title))
    if not self.disable_lookup_history then
        local history_item = {
            book_title = book_title,
            time = os.time(),
            word = word,
        }
        -- Not urgent: done while sdcv is running
        UIManager:nextTick(function()
            lookup_history:addTableItem("lookup_history", history_item)
        end)
    end

    if Device:canExternalDictLookup() and G_reader_settings:isTrue("external_dict_lookup") then
        Device:doExternalDictLookup(word, G_reader_settings:readSetting("external_dict_lookup_method"), function()
            if self.highlight then
                local clear_id = self.highlight:getClearId()
                UIManager:scheduleIn(G_defaults:readSetting("DELAY_CLEAR_HIGHLIGHT_S"), function()
                    self.highlight:clear(clear_id)
                end)
            end

            if dict_close_callback then
                dict_close_callback()
            end
        end)
        return
    end

    -- Before starting the search, remove any dictionaries that were disabled for *this* book.
    if dict_names and self.doc_disabled_dicts then
        local filtered_names = {}
        for _, name in ipairs(dict_names) do
            if not self.doc_disabled_dicts[name] then
                table.insert(filtered_names, name)
            end
        end
        dict_names = filtered_names
    end

    -- If the user disabled all the dictionaries, go away.
    if dict_names and #dict_names == 0 then
        -- Dummy result
        local nope = {
            {
                dict = _("Not available"),
                word = word,
                definition = _("There are no enabled dictionaries.\nPlease check the 'Dictionary settings' menu."),
                no_result = true,
                lookup_cancelled = false,
            }
        }
        self:showDict(word, nope, boxes, link, dict_close_callback)
        return
    end

    self:showLookupInfo(word, self.lookup_msg_delay)

    self._lookup_start_time = UIManager:getTime()
    local results = self:startSdcv(word, dict_names, fuzzy_search)
    local function lookupCancelled()
        if self.highlight then
            self.highlight:clear()
        end
        if dict_close_callback then
            dict_close_callback()
        end
    end
    if results and results.lookup_cancelled
        and (time.now() - self._lookup_start_time) <= self.quick_dismiss_before_delay then
        -- If interrupted quickly just after launch, don't display anything
        -- (this might help avoiding refreshes and the need to dismiss
        -- after accidental long-press when holding a device).
        lookupCancelled()
        return
    end
    -- Intercept "No results" to offer alternative search methods (e.g., fuzzy search to non-fussy people)
    if results and results[1].no_result then
        local handled = self:showNoResultsDialog(word, dict_names, fuzzy_search, boxes, link, dict_close_callback, lookupCancelled)
        if handled then return end
    end

    self:showDict(word, tidyMarkup(results), boxes, link, dict_close_callback)
end

function ReaderDictionary:showDict(word, results, boxes, link, dict_close_callback)
    if results and results[1] then
        logger.dbg("showing quick lookup window", #DictQuickLookup.window_list+1, ":", word, results)
        self.dict_window = DictQuickLookup:new{
            ui = self.ui,
            highlight = self.highlight,
            dialog = self.dialog,
            -- original lookup word
            word = word,
            -- selected link, if any
            selected_link = link,
            results = results,
            word_boxes = boxes,
            preferred_dictionaries = self.preferred_dictionaries,
            -- differentiate between dict and wiki
            is_wiki = self.is_wiki,
            refresh_callback = function()
                if self.view then
                    -- update info in footer (time, battery, etc)
                    self.view.footer:onUpdateFooter()
                end
            end,
            html_dictionary_link_tapped_callback = function(dictionary, html_link)
                self:onHtmlDictionaryLinkTapped(dictionary, html_link)
            end,
            dict_close_callback = dict_close_callback,
        }
        if self.lookup_progress_msg then
            -- If we have a lookup InfoMessage that ended up being displayed, make
            -- it *not* refresh on close if it is hidden by our DictQuickLookup
            -- to avoid refreshes competition and possible glitches
            local msg_dimen = self.lookup_progress_msg:getVisibleArea()
            if msg_dimen then -- not invisible
                local dict_dimen = self.dict_window:getInitialVisibleArea()
                if dict_dimen and dict_dimen:contains(msg_dimen) then
                    self.lookup_progress_msg.no_refresh_on_close = true
                end
            end
        end
    end

    self:dismissLookupInfo()
    if results and results[1] then
        UIManager:show(self.dict_window)
        if not results.lookup_cancelled and self._lookup_start_time
            and (time.now() - self._lookup_start_time) > self.quick_dismiss_before_delay then
            -- If the search took more than a few seconds to be done, discard
            -- queued and upcoming input events to avoid a voluntary dismissal
            -- (because the user felt the result would not come) to kill the
            -- result that finally came and is about to be displayed
            Input:inhibitInputUntil(true)
        end
    end
end

function ReaderDictionary:showNoResultsDialog(word, dict_names, fuzzy_search, boxes, link, dict_close_callback, lookupCancelled)
    self:dismissLookupInfo() -- Close the "Searching..." message
    local preset_names = Presets.getPresets(self.preset_obj)
    local has_presets = preset_names and #preset_names > 0
    if fuzzy_search and not has_presets then return false end -- fall through to showing empty results

    local preset_button = has_presets and {
        text = _("Search with preset"),
        callback = function(dialog)
            local new_word = dialog:getInputText()
            if new_word == "" or new_word:match("^%s*$") then return end
            self:showSearchWithPresetDialog(preset_names, dialog, new_word, boxes, link, dict_close_callback)
        end,
    } or nil

    -- Determine the primary action based on what's available
    local description, primary_action
    if not fuzzy_search then
        description = _("Would you like to use fuzzy search?")
        primary_action = {
            text = _("Fuzzy search"),
            is_enter_default = true,
            callback = function(dialog)
                local new_word = dialog:getInputText()
                if new_word == "" then return end
                UIManager:close(dialog)
                -- Re-run the lookup with the (possibly edited) word and fuzzy enabled.
                -- Wrapped through Trapper, as we may be using Trapper:dismissablePopen() in it
                Trapper:wrap(function()
                    self:stardictLookup(new_word, dict_names, true, boxes, link, dict_close_callback)
                end)
            end,
        }
    elseif has_presets then
        description = _("Would you like to search with a preset?")
        primary_action = preset_button
        primary_action.is_enter_default = true
    end

    local buttons = {}
    -- Add preset button as an additional option (when fuzzy is the primary action)
    if not fuzzy_search and has_presets then
        table.insert(buttons, { preset_button })
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            id = "close",
            callback = function(dialog)
                UIManager:close(dialog)
                UIManager:scheduleIn(G_defaults:readSetting("DELAY_CLEAR_HIGHLIGHT_S"), function() lookupCancelled() end)
            end,
        },
        primary_action,
    })
    local dialog
    dialog = InputDialog:new{
        title = _("No results found"),
        input = word, -- Pre-fills the dialog with the selected word
        input_type = "text",
        description = description,
        buttons = buttons,
    }

    -- Wire up callbacks with the dialog instance
    for _, row in ipairs(buttons) do
        for _, button in ipairs(row) do
            if button.callback then
                local original_callback = button.callback
                button.callback = function()
                    original_callback(dialog)
                end
            end
        end
    end
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return true
end

function ReaderDictionary:showDownload(lang, downloadable_dicts)
    self.dl_dict_list = BookList:new{
        lang = lang,
        dicts = downloadable_dicts,
        filter = nil,
        _manager = self,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            self:filterDownloadDict()
        end,
        onMenuSelect = self.onTapDownloadDict,
    }
    self:updateDownloadDictItemTable()
    UIManager:show(self.dl_dict_list)
end

function ReaderDictionary:updateDownloadDictItemTable()
    local item_table = {}
    for _, dict in ipairs(self.dl_dict_list.dicts) do
        if self.dl_dict_list.filter == nil or self.dl_dict_list.filter == (dict.lang_in == dict.lang_out) then
            table.insert(item_table, {
                text = dict.name,
                mandatory = dict.entries,
                dict = dict,
            })
        end
    end
    local title = T(_("Available dictionaries (%1)"), #item_table)
    local subtitle = T(_("Language: %1"), self.dl_dict_list.lang)
    if self.dl_dict_list.filter ~= nil then
        subtitle = subtitle .. " \u{F0B0}"
    end
    self.dl_dict_list:switchItemTable(title, item_table, nil, nil, subtitle)
end

function ReaderDictionary:filterDownloadDict()
    UIManager:show(ButtonSelector:new{
        current_value = self.dl_dict_list.filter,
        values = {
            { _("all"), nil },
            { self.dl_dict_list.lang, true },
            { _("bilingual"), false },
        },
        callback = function(value)
            self.dl_dict_list.filter = value
            self:updateDownloadDictItemTable()
        end,
    })
end

function ReaderDictionary:onTapDownloadDict(item)
    local dict = item.dict
    local t = {
        dict.name,
        "",
        T(_("Language: %1–%2"), dict.lang_in, dict.lang_out),
        T(_("Entries: %1"), dict.entries),
        T(_("License: %1"), dict.license),
        "",
    }
    UIManager:show(ConfirmBox:new{
        text = table.concat(t, "\n"),
        ok_text = _("Download"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function()
                self._manager:downloadDictionary(dict)
            end)
        end,
    })
end

local function extractDictionary(archive, extract_to)
    -- Ensure the parent directory exists.
    local ok, err = util.makePath(ffiUtil.dirname(extract_to))
    if not ok then
        return ok, err
    end
    -- If there's a previously extracted directory, remove it.
    if lfs.attributes(extract_to, "mode") then
        ok, err = ffiUtil.purgeDir(extract_to)
        if not ok then
            return ok, err
        end
    end
    -- Create a temporary directory alongside the final directory.
    local tmpdir_template = extract_to .. ".XXXXXX"
    local tmpdir = ffi.new("char[?]", #tmpdir_template + 1, tmpdir_template)
    if C.mkdtemp(tmpdir) == nil then
        return false, string.format("mkdtemp(%s): %s", ffi.string(tmpdir), posix.strerror())
    end
    tmpdir = ffi.string(tmpdir)
    -- Extract archive.
    local arc = Archiver.Reader:new()
    ok = arc:open(archive)
    if ok then
        for entry in arc:iterate() do
            if not arc:extractToPath(entry.path, tmpdir.."/"..entry.path) then
                break
            end
        end
        ok, err = not arc.err, arc.err
    end
    arc:close()
    os.remove(archive)
    -- Finalize.
    if ok then
        -- Determine root directory, if any.
        local archive_root
        for entry in lfs.dir(tmpdir) do
            if entry ~= ".." and entry ~= "." then
                if archive_root then
                    -- Multiple entries: no root.
                    archive_root = nil
                    break
                end
                archive_root = entry
            end
        end
        if archive_root then
            -- Rename root to final directory and remove temporary directory.
            ok, err = os.rename(tmpdir.."/"..archive_root, extract_to)
            os.remove(tmpdir)
        else
            -- No root, just rename the whole temporary directory.
            ok, err = os.rename(tmpdir, extract_to)
        end
    else
        ffiUtil.purgeDir(tmpdir)
    end
    return ok, err
end

function ReaderDictionary:downloadDictionary(dict)
    -- Ensure we're running in a coroutine.
    local co = coroutine.running()
    if not co then
        Trapper:wrap(function() self:downloadDictionary(dict) end)
        return
    end

    -- UI helper.
    local dialog
    local show_info = function(text)
        if dialog then
            UIManager:close(dialog)
            dialog = nil
        end
        dialog = InfoMessage:new{ text = text }
        UIManager:show(dialog)
        UIManager:forceRePaint()
    end

    -- Socket helper.
    local socket = require("socket")
    local socketutil = require("socketutil")
    local fetch = function(outfile)
        if outfile then
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        else
            socketutil:set_timeout()
        end
        local code, headers, status = socket.skip(1, socket.http.request{
            method = outfile and "GET" or "HEAD",
            sink   = outfile and socketutil.file_sink(io.open(outfile, "w")),
            url    = dict.url,
        })
        socketutil:reset_timeout()
        if code ~= 200 then
            local err = status or code
            logger.dbg("ReaderDictionary: Request failed:", err)
            logger.dbg("ReaderDictionary: Response headers:", headers)
            show_info(T(_("Download failed:\n\n%1"), BD.ltr(err)))
            return
        end
        return headers
    end

    -- Fetch content length.
    local headers = fetch()
    if not headers or not headers["content-length"] then
        return
    end

    dialog = ConfirmBox:new{
        text = T(_("Dictionary filesize is %1. Continue with download?"), util.getFriendlySize(headers["content-length"])),
        ok_text =  _("Download"),
        ok_callback = function() coroutine.resume(co, true) end,
        cancel_callback = function() coroutine.resume(co, false) end,
    }
    UIManager:show(dialog)
    if not coroutine.yield() then
        return
    end

    -- Download archive.
    show_info(_("Downloading…"))
    local dict_archive = self.data_dir.."/"..table.remove(socket.url.parse_path(dict.url))
    if not fetch(dict_archive) then
        return
    end
    logger.dbg("file downloaded to", dict_archive)

    -- Extract archive: a stable target directory is needed so we can look through the folder later.
    -- Additionally, make sure a safe directory name is used (so for example the "Dictionnaire de
    -- l'Académie Française: 8ème edition" dictionary can be installed on Kindle).
    local dict_dir = self.data_dir.."/"..util.getSafeFilename(dict.name, ffiUtil.realpath(self.data_dir))
    local ok, err = extractDictionary(dict_archive, dict_dir)
    if not ok then
        show_info(T(_("Extraction failed:\n\n%1"), BD.ltr(err)))
        return
    end

    -- Update available dictionaries.
    if dict.ifo_lang then
        self:extendIfoWithLanguage(dict_dir, dict.ifo_lang)
    end
    available_ifos = false
    self:init()
    show_info(_("Dictionary downloaded"))
end

function ReaderDictionary:extendIfoWithLanguage(dictionary_location, ifo_lang)
    local function cb(path, filename)
        if util.getFileNameSuffix(filename) == "ifo" then
            local fmt_string = "lang=%s"
            local f = io.open(path, "a+")
            if f then
                local ifo = f:read("a*")
                if ifo[#ifo] ~= "\n" then
                    fmt_string = "\n" .. fmt_string
                end
                f:write(fmt_string:format(ifo_lang))
                f:close()
            end
        end
    end
    util.findFiles(dictionary_location, cb)
end

function ReaderDictionary:onReadSettings(config)
    self.preferred_dictionaries = config:readSetting("preferred_dictionaries") or {}
    if #self.preferred_dictionaries == 0 then
        -- Legacy setting, when only one dict could be set as default/first to show
        local default_dictionary = config:readSetting("default_dictionary")
        if default_dictionary then
            table.insert(self.preferred_dictionaries, default_dictionary)
            config:delSetting("default_dictionary")
        end
    end
    if #self.preferred_dictionaries > 0 then
        self:updateSdcvDictNamesOptions()
    end
    if config:has("disable_fuzzy_search") then
        self.disable_fuzzy_search = config:isTrue("disable_fuzzy_search")
    else
        self.disable_fuzzy_search = G_reader_settings:isTrue("disable_fuzzy_search")
    end
    -- Disabled dictionary list for this book
    self.doc_disabled_dicts = config:readSetting("disabled_dicts") or {}
end

function ReaderDictionary:onSaveSettings()
    if self.ui.doc_settings then
        self.ui.doc_settings:saveSetting("preferred_dictionaries", next(self.preferred_dictionaries) and self.preferred_dictionaries or nil)
        self.ui.doc_settings:saveSetting("disabled_dicts", next(self.doc_disabled_dicts) and self.doc_disabled_dicts or nil)
    end
end

function ReaderDictionary:onTogglePreferredDict(dict)
    if not self.preferred_dictionaries then
        -- Invoked from FileManager: no preferred dict to manage
        return true
    end
    local removed = false
    for idx, name in ipairs(self.preferred_dictionaries) do
        if dict == name then
            removed = true
            table.remove(self.preferred_dictionaries, idx)
            break
        end
    end
    if not removed then -- insert it as first
        table.insert(self.preferred_dictionaries, 1, dict)
    end
    UIManager:show(InfoMessage:new{
        text = removed and T(_("%1 is no longer a preferred dictionary for this document."), dict)
                        or T(_("%1 is now the preferred dictionary for this document."), dict),
        timeout = 2,
    })
    self:updateSdcvDictNamesOptions()
    return true
end

function ReaderDictionary:toggleFuzzyDefault(touchmenu_instance)
    local disable_fuzzy_search = G_reader_settings:isTrue("disable_fuzzy_search")
    UIManager:show(MultiConfirmBox:new{
        text = T(
            disable_fuzzy_search
            and _([[
Would you like to enable or disable fuzzy search by default?

Fuzzy search can match epuisante, épuisante and épuisantes to épuisant, even if only the latter has an entry in the dictionary. It can be disabled to improve performance, but it might be worthwhile to look into disabling unneeded dictionaries before disabling fuzzy search.

The current default (★) is disabled.]])
            or _([[
Would you like to enable or disable fuzzy search by default?

Fuzzy search can match epuisante, épuisante and épuisantes to épuisant, even if only the latter has an entry in the dictionary. It can be disabled to improve performance, but it might be worthwhile to look into disabling unneeded dictionaries before disabling fuzzy search.

The current default (★) is enabled.]])
        ),
        choice1_text_func =  function()
            return disable_fuzzy_search and _("Disable (★)") or _("Disable")
        end,
        choice1_callback = function()
            G_reader_settings:makeTrue("disable_fuzzy_search")
            touchmenu_instance:updateItems()
        end,
        choice2_text_func = function()
            return disable_fuzzy_search and _("Enable") or _("Enable (★)")
        end,
        choice2_callback = function()
            G_reader_settings:makeFalse("disable_fuzzy_search")
            touchmenu_instance:updateItems()
        end,
    })
end

function ReaderDictionary:buildPreset()
    local preset = { enabled_dict_names = {} } -- Only store the names of enabled dictionaries.
    for _, name in ipairs(self.enabled_dict_names) do
        preset.enabled_dict_names[name] = true
    end
    return preset
end

function ReaderDictionary:loadPreset(preset, skip_notification)
    if not preset.enabled_dict_names then return end
    -- build a list of currently available dictionary names for validation
    local available_dict_names = {}
    for _, ifo in ipairs(available_ifos) do
        available_dict_names[ifo.name] = true
    end
    -- Only enable dictionaries from the preset that are still available, and re-build self.dicts_disabled
    -- to make sure dicts added after the creation of the preset, are disabled as well.
    local dicts_disabled, valid_enabled_names = {}, {}
    for _, ifo in ipairs(available_ifos) do
        if preset.enabled_dict_names[ifo.name] then
            table.insert(valid_enabled_names, ifo.name)
        else
            dicts_disabled[ifo.file] = true
        end
    end
    -- update both settings and save
    self.dicts_disabled = dicts_disabled
    self.enabled_dict_names = valid_enabled_names
    G_reader_settings:saveSetting("dicts_disabled", self.dicts_disabled)
    self:onSaveSettings()
    self:updateSdcvDictNamesOptions()
    -- Show a message if any dictionaries from the preset are missing.
    if not skip_notification and util.tableSize(preset.enabled_dict_names) > #valid_enabled_names then
        local missing_dicts = {}
        for preset_name, _ in pairs(preset.enabled_dict_names) do
            if not available_dict_names[preset_name] then
                table.insert(missing_dicts, preset_name)
            end
        end
        UIManager:show(InfoMessage:new{
            text = _("Some dictionaries from this preset have been deleted or are no longer available:") .. "\n\n• " .. table.concat(missing_dicts, "\n• "),
        })
    end
end

function ReaderDictionary:onCycleDictionaryPresets()
    return Presets.cycleThroughPresets(self.preset_obj, true)
end

function ReaderDictionary:onLoadDictionaryPreset(preset_name)
    return Presets.onLoadPreset(self.preset_obj, preset_name, true)
end

function ReaderDictionary.getPresets() -- for Dispatcher
    local dict_config = {
        presets = G_reader_settings:readSetting("dict_presets", {})
    }
    return Presets.getPresets(dict_config)
end

return ReaderDictionary
