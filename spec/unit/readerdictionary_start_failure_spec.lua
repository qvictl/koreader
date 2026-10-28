-- When sdcv can't be started (missing binary, pipe/posix_spawn failure under memory or
-- fd pressure), the lookup ends like a quick dismissal: it must not leave its delayed
-- "Searching dictionary for: …" message up, with nothing else ever shown.
describe("ReaderDictionary when sdcv can't be started", function()
    local DataStorage, DocumentRegistry, ReaderUI, UIManager, Screen
    local StarDict, ffiUtil, time, util
    local readerui, rd, ReaderDictionary, tmp

    local function waitFor(cond, timeout)
        local deadline = time.now() + time.s(timeout or 5)
        while not cond() do
            if time.now() > deadline then return false end
            UIManager:_checkTasks()
            ffiUtil.usleep(2000)
        end
        return true
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        DataStorage = require("datastorage")
        DocumentRegistry = require("document/documentregistry")
        UIManager = require("ui/uimanager")
        Screen = require("device").screen
        StarDict = require("stardict_fixture")
        ffiUtil = require("ffi/util")
        time = require("ui/time")
        util = require("util")
        tmp = DataStorage:getDataDir() .. "/readerdictionary_start_failure"
        StarDict.purge(tmp)
        util.makePath(tmp)
        StarDict.write(tmp .. "/dict/alpha", "alpha", "Alpha", { harbor = "alpha: a sheltered port" })
        G_defaults:saveSetting("STARDICT_DATA_DIR", tmp .. "/dict")
        ReaderUI = require("apps/reader/readerui")
        ReaderDictionary = require("apps/reader/modules/readerdictionary")
        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument("spec/front/unit/data/sample.txt"),
        }
        rd = readerui.dictionary
        -- Use an sdcv that doesn't exist.
        rd.getSdcvArgs = function(this, ...)
            local args = ReaderDictionary.getSdcvArgs(this, ...)
            args[1] = tmp .. "/no/such/sdcv"
            return args
        end
    end)

    teardown(function()
        readerui:closeDocument()
        readerui:onClose()
        G_defaults:delSetting("STARDICT_DATA_DIR")
        G_reader_settings:delSetting("dict_progressive_lookup")
        UIManager:quit()
        UIManager._exit_code = nil
        StarDict.purge(tmp)
    end)

    for _, progressive in ipairs{ false, true } do
        it("closes the 'Searching…' message (" .. (progressive and "progressive" or "classic") .. " lookup)", function()
            G_reader_settings:saveSetting("dict_progressive_lookup", progressive)
            ReaderUI.instance = readerui
            UIManager:show(readerui)
            local highlight = { clear = spy.new(function() end) }
            local closed = spy.new(function() end)
            rd:onLookupWord("harbor", true, nil, highlight, nil, closed)
            assert.is_true(waitFor(function() return #closed.calls > 0 end))
            local msg = rd.lookup_progress_msg
            -- Past the message's show delay.
            waitFor(function() return false end, 0.7)
            assert.is_nil(rd.lookup_progress_msg)
            if msg then
                assert.is_false(UIManager:isWidgetShown(msg))
            end
            for _, w in ipairs(UIManager._window_stack) do
                assert.are_not.equal(msg, w.widget)
                assert.is_falsy(w.widget.text and w.widget.text:find("Searching dictionary"))
            end
            assert.spy(highlight.clear).was_called()
            assert.is_nil(rd.dict_window)
        end)
    end
end)
