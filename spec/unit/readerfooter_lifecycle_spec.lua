describe("ReaderFooter delayed refresh lifecycle", function()
    local ReaderFooter, UIManager
    local saved_queue, saved_dirty

    setup(function()
        require("commonrequire")
        ReaderFooter = require("apps/reader/modules/readerfooter")
        UIManager = require("ui/uimanager")
    end)

    before_each(function()
        saved_queue = UIManager._task_queue
        saved_dirty = UIManager._task_queue_dirty
        UIManager._task_queue = {}
    end)

    after_each(function()
        UIManager._task_queue = saved_queue
        UIManager._task_queue_dirty = saved_dirty
    end)

    local function newFooter()
        return ReaderFooter:extend{
            ui = { document = {} },
            settings = { page_turning_inverted = true },
            updates = 0,
            shouldBeRepainted = function() return true, true end,
            onUpdateFooter = function(self, repaint, full)
                self.updates = self.updates + 1
                self.last_repaint, self.last_full = repaint, full
            end,
        }
    end

    it("delays inversion feedback and refreshes the live reader", function()
        local footer = newFooter()
        footer:onToggleReadingOrder()
        assert.are.equal(0, footer.updates)
        assert.are.equal(1, #UIManager._task_queue)
        local task = table.remove(UIManager._task_queue)
        assert.are.equal(footer._delayed_footer_refresh, task.action)
        task.action()
        assert.are.equal(1, footer.updates)
        assert.is_true(footer.last_repaint)
        assert.is_true(footer.last_full)
    end)

    it("cancels the delayed refresh even without an auto-refresh task", function()
        local footer = newFooter()
        footer:onSwapPageTurnButtons()
        footer:onCloseDocument()
        assert.are.equal(0, #UIManager._task_queue)
    end)

    it("cancels both refresh kinds when closing the document", function()
        local footer = newFooter()
        footer.autoRefreshFooter = function() end
        UIManager:scheduleIn(60, footer.autoRefreshFooter)
        footer:onSwapPageTurnButtons()
        footer:onCloseDocument()
        assert.are.equal(0, #UIManager._task_queue)
    end)

    it("does not cancel another reader's refresh or unrelated work", function()
        local old, current = newFooter(), newFooter()
        local unrelated = function() end
        old:onSwapPageTurnButtons()
        current:onSwapPageTurnButtons()
        UIManager:scheduleIn(1, unrelated)
        old:onCloseDocument()
        assert.are.equal(2, #UIManager._task_queue)
        assert.is_false(old._delayed_footer_refresh == current._delayed_footer_refresh)
        assert.is_true(UIManager:unschedule(current._delayed_footer_refresh))
        assert.is_true(UIManager:unschedule(unrelated))
    end)

    it("cancels repeated requests and tolerates repeated close notifications", function()
        local footer = newFooter()
        footer:onSwapPageTurnButtons()
        footer:onSwapPageTurnButtons()
        assert.are.equal(2, #UIManager._task_queue)
        footer:onCloseDocument()
        footer:onCloseDocument()
        assert.are.equal(0, #UIManager._task_queue)
    end)

    it("ignores a captured callback after the document has closed", function()
        local footer = newFooter()
        footer:onSwapPageTurnButtons()
        local callback = UIManager._task_queue[1].action
        footer:onCloseDocument()
        footer.ui.document = nil
        footer.shouldBeRepainted = function() error("closed footer inspected") end
        callback()
        assert.are.equal(0, footer.updates)
    end)

    it("also cancels pending work when the widget is closed directly", function()
        local footer = newFooter()
        local freed = false
        footer.free = function() freed = true end
        footer:onSwapPageTurnButtons()
        footer:onCloseWidget()
        assert.is_true(freed)
        assert.are.equal(0, #UIManager._task_queue)
    end)

    it("does not schedule disabled inversion feedback or require a pending task to close", function()
        local footer = newFooter()
        footer.settings.page_turning_inverted = false
        footer:onSwapPageTurnButtons()
        footer:onCloseDocument()
        assert.are.equal(0, #UIManager._task_queue)
    end)
end)
