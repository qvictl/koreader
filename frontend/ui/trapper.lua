--[[--
Trapper module: provides methods for simple interaction with UI,
without the need for explicit callbacks, for use by linear jobs
between their steps.

Allows code to trap UI (give progress info to UI, ask for user choice),
or get trapped by UI (get interrupted).
Mostly done with coroutines, but hides their usage for simplicity.
]]


local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local TrapWidget = require("ui/widget/trapwidget")
local UIManager = require("ui/uimanager")
local buffer = require("string.buffer")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")
local C = ffi.C

require("ffi/posix_h")

-- Whether a popen()'d command's output can be read now without blocking: either it has
-- output pending, or it is done (end of file: the command exited, possibly without
-- printing anything, which the FIONREAD check alone can't tell from "not yet").
local function isPipeReadable(luafile)
    if ffiutil.getNonBlockingReadSize(luafile) ~= 0 then
        return true
    end
    local pfd = ffi.new("struct pollfd[1]")
    pfd[0].fd = C.fileno(luafile)
    pfd[0].events = C.POLLIN
    return C.poll(pfd, 1, 0) > 0 and bit.band(pfd[0].revents, C.POLLHUP) ~= 0
end

local Trapper = {}

--[[--
Executes a function and allows it to be trapped (that is: to use our
other methods).

Simple wrapper function for a coroutine, which is a prerequisite
for all our methods (this simply abstracts the @{coroutine}
business to our callers), and execute it.

(If some code is not wrap()'ed, most of the other methods, when called,
will simply log or fallback to a non-UI action or OK choice.)

This call should be the last step in some event processing code,
as it may return early (the first @{coroutine.yield|coroutine.yield()} in any of the other
methods will return from this function), and later be resumed by @{ui.uimanager|UIManager}.
So any following (unwrapped) code would be then executed while `func`
is half-done, with unintended consequences.

@param func function reference to function to wrap and execute
]]
function Trapper:wrap(func)
    -- Catch and log any error happening in func (an error happening
    -- in a coroutine just aborts silently the coroutine)
    local pcalled_func = function()
        UIManager:preventStandby()
        -- we use xpcall as it can give a whole stacktrace, unlike pcall
        local ok, err = xpcall(func, debug.traceback)
        UIManager:allowStandby()
        if not ok then
            logger.warn("error in wrapped function:", err)
            return false
        end
        return true
        -- As a coroutine, we will return at first coroutine.yield(),
        -- and the above true/false won't probably be caught by
        -- any code, but let's do it anyway.
    end
    local co = coroutine.create(pcalled_func)
    return coroutine.resume(co)
end

--- Returns if code is wrapped
--
-- @treturn boolean true if code is wrapped by Trapper, false otherwise
function Trapper:isWrapped()
    if coroutine.running() then
        return true
    end
    return false
end

--- Clears left-over widget
function Trapper:clear()
    if self:isWrapped() then
        if self.current_widget then
            UIManager:close(self.current_widget)
            UIManager:forceRePaint()
            self.current_widget = nil
        end
    end
end

--- Clears left-over widget and resets Trapper state
function Trapper:reset()
    self:clear()
    -- Reset some properties
    self.paused_text = nil
    self.paused_continue_text = nil
    self.paused_abort_text = nil
    return true
end

--[[--
Displays an InfoMessage, and catches dismissal.

Display a InfoMessage with text, or keep existing InfoMessage if text = nil,
and return true.

UNLESS the previous widget was itself a InfoMessage and it has been
dismissed (by Tap on the screen), in which case the new InfoMessage
is not displayed, and false is returned.

One can only know a InfoMessage has been dismissed when trying to
display a new one (we can't do better than that with coroutines).
So, don't hesitate to call it regularly (each call costs 100ms), between
steps of the work, to provide good responsiveness.

Trapper:info() is a shortcut to get dismiss info while keeping
the existing InfoMessage displayed.

Optional fast_refresh parameter should only be used when
displaying an InfoMessage over a previous InfoMessage of the
exact same size.

@string text text to display as an InfoMessage (or nil to keep existing one)
@boolean fast_refresh[opt=false] true for faster refresh
@boolean skip_dismiss_check[opt=false] true to return immediately, to avoid the 100 ms delay for interim update
@treturn boolean true if InfoMessage was not dismissed, false if dismissed

@usage
    Trapper:info("some text about step or progress")
    go_on = Trapper:info()
]]
function Trapper:info(text, fast_refresh, skip_dismiss_check)
    local _coroutine = coroutine.running()
    if not _coroutine then
        logger.info("unwrapped info:", text)
        return true -- not dismissed
    end

    if self.current_widget and self.current_widget.is_infomessage then
        -- We are replacing a InfoMessage with a new InfoMessage: we want to check
        -- if the previous one was dismissed.
        -- We added a dismiss_callback to our previous InfoMessage. For a Tap
        -- to get processed and get our dismiss_callback called, we need to give
        -- control for a short time to UIManager: this will be done with
        -- the coroutine.yield() that follows.
        -- If no dismiss_callback was fired, we need to get this code resumed:
        -- that will be done with the following go_on_func schedule in 0.1 second.
        local go_on = true
        local go_on_func
        if not skip_dismiss_check then
            go_on_func = function() coroutine.resume(_coroutine, true) end
            -- delay matters: 0.05 or 0.1 seems fine
            -- 0.01 is too fast: go_on_func is called before our dismiss_callback is processed
            UIManager:scheduleIn(0.1, go_on_func)

            go_on = coroutine.yield() -- gives control back to UIManager
            -- go_on is the 2nd arg given to the coroutine.resume() that got us resumed:
            -- false if it was a dismiss_callback
            -- true if it was the schedule go_on_func
        end
        if not go_on then -- dismiss_callback called
            UIManager:unschedule(go_on_func) -- no more need for this scheduled action
            -- Don't just return false without confirmation (this tap may have been
            -- made by error, and we don't want to just cancel a long running job)
            local abort_box = ConfirmBox:new{
                text = self.paused_text and self.paused_text or _("Paused"),
                -- ok and cancel reversed, as tapping outside will
                -- get cancel_callback called: if tap outside was the
                -- result of a tap error, we want to continue. Cancelling
                -- will need an explicit tap on the ok_text button.
                cancel_text = self.paused_continue_text and self.paused_continue_text or _("Continue"),
                ok_text = self.paused_abort_text and self.paused_abort_text or _("Abort"),
                cancel_callback = function()
                    coroutine.resume(_coroutine, true)
                end,
                ok_callback = function()
                    coroutine.resume(_coroutine, false)
                end,
                -- flush any pending tap, so past events won't be considered
                -- action on the yet to be displayed widget
                flush_events_on_show = true,
            }
            UIManager:show(abort_box)
            -- no need to forceRePaint, UIManager will do it when we yield()
            go_on = coroutine.yield() -- abort_box ok/cancel from their coroutine.resume()
            UIManager:close(abort_box)
            if not go_on then
                UIManager:close(self.current_widget)
                UIManager:forceRePaint()
                return false
            end
            if self.current_widget then
                -- Resurrect a dead widget. This should only be performed by trained Necromancers.
                -- Do NOT do this at home, kids.
                -- Some state *might* be lost, but the basics should survive...
                self.current_widget:init()
                UIManager:show(self.current_widget)
            end
            UIManager:forceRePaint()
        end
        -- go_on_func returned result = true, or abort_box did not abort:
        -- continue processing
    end

    -- If fast_refresh option, avoid UIManager refresh overhead
    if fast_refresh and self.current_widget and self.current_widget.is_infomessage then
        local orig_moved_offset = self.current_widget.movable:getMovedOffset()
        self.current_widget:free()
        self.current_widget.text = text
        self.current_widget:init()
        self.current_widget.movable:setMovedOffset(orig_moved_offset)
        local Screen = require("device").screen
        self.current_widget:paintTo(Screen.bb, 0, 0)
        local d = self.current_widget[1][1].dimen
        Screen.refreshUI(Screen, d.x, d.y, d.w, d.h)
    else
        -- We're going to display a new widget, close previous one
        if self.current_widget then
            UIManager:close(self.current_widget)
            -- no repaint here, we'll do that below when a new one is shown
        end

        -- dismiss_callback will be checked for at start of next call
        self.current_widget = InfoMessage:new{
            text = text,
            dismiss_callback = function()
                coroutine.resume(_coroutine, false)
            end,
            is_infomessage = true, -- flag on our InfoMessages
            -- flush any pending tap, so past events won't be considered
            -- action on the yet to be displayed widget
            flush_events_on_show = true,
        }
        logger.dbg("Showing InfoMessage:", text)
        UIManager:show(self.current_widget)
        UIManager:forceRePaint()
    end
    return true
end

--[[--
Overrides text and button texts on the Paused ConfirmBox.

A ConfirmBox is displayed when an InfoMessage is dismissed
in Trapper:info(), with default text "Paused", and default
buttons "Abort" and "Continue".

@string text ConfirmBox text (default: "Paused")
@string abort_text ConfirmBox "Abort" button text (Trapper:info() returns false)
@string continue_text ConfirmBox "Continue" button text
]]
function Trapper:setPausedText(text, abort_text, continue_text)
    if self:isWrapped() then
        self.paused_text = text
        self.paused_abort_text = abort_text
        self.paused_continue_text = continue_text
    end
end


--[[--
Displays a ConfirmBox and gets user's choice.

Display a ConfirmBox with the text and cancel_text/ok_text buttons,
block and wait for user's choice, and return the choice made:
false if Cancel tapped or dismissed, true if OK tapped

@string text text to display in a ConfirmBox
@string cancel_text text for ConfirmBox Cancel button
@string ok_text text for ConfirmBox Ok button
@treturn boolean false if Cancel tapped or dismissed, true if OK tapped

@usage
    go_on = Trapper:confirm("Do you want to go on?")
    that_selected = Trapper:confirm("Do you want to do this or that?", "this", "that"))
]]
function Trapper:confirm(text, cancel_text, ok_text)
    -- With ConfirmBox, Cancel button is on the left, OK button on the right,
    -- so buttons order is consistent with this function args
    local _coroutine = coroutine.running()
    if not _coroutine then
        logger.info("unwrapped confirm, returning true to:", text)
        return true -- always select "OK" in ConfirmBox if no UI
    end

    -- Close any previous widget
    if self.current_widget then
        UIManager:close(self.current_widget)
        -- no repaint here, we'll do that below when a new one is shown
    end

    -- We will yield(), and both callbacks will resume() us
    self.current_widget = ConfirmBox:new{
        text = text,
        ok_text = ok_text,
        cancel_text = cancel_text,
        cancel_callback = function()
            coroutine.resume(_coroutine, false)
        end,
        ok_callback = function()
            coroutine.resume(_coroutine, true)
        end,
        -- flush any pending tap, so past events won't be considered
        -- action on the yet to be displayed widget
        flush_events_on_show = true,
    }
    logger.dbg("Showing ConfirmBox and waiting for answer:", text)
    UIManager:show(self.current_widget)
    -- no need to forceRePaint, UIManager will do it when we yield()
    local ret = coroutine.yield() -- wait for ConfirmBox callback
    logger.dbg("ConfirmBox answers", ret)
    return ret
end


--[[--
Dismissable wrapper for @{io.popen|io.popen(`cmd`)}.

Notes and limitations:

1) It is dismissable as long as `cmd` as not yet output anything.
   Once output has started, the reading will block till it is done.
   (Some shell tricks, included in `cmd`, could probably be used to
   accumulate `cmd` output in some variable, and to output the whole
   variable to stdout at the end.)

2) `cmd` may exit without outputting anything: that is detected (end of file),
   and the output is then the empty string.

3) We need a @{ui.widget.trapwidget|TrapWidget} or @{ui.widget.infomessage|InfoMessage},
   that, as a modal, will catch any @{ui.event|Tap event} happening during
   `cmd` execution. This can be an existing already displayed widget, or
   provided as a string (a new TrapWidget will be created). If nil, true or false,
   an invisible TrapWidget will be used instead (if nil or true, the event will be
   resent; if false, the event will not be resent).

If we really need to have more control, we would need to use `select()` via `ffi`
or do low level non-blocking reading on the file descriptor.
If there are `cmd` that may not exit, that we would be trying to
collect indefinitely, the best option would be to compile any `timeout.c`
and use it as a wrapper.

@string cmd shell `cmd` to execute and get output from
@param trap_widget_or_string already shown widget, string, or nil, true or false
@treturn boolean completed (`true` if not interrupted, `false` if dismissed)
@treturn string output of command
]]
function Trapper:dismissablePopen(cmd, trap_widget_or_string)
    local _coroutine = coroutine.running()
    -- assert(_coroutine ~= nil, "Need to be called from a coroutine")
    if not _coroutine then
        logger.warn("unwrapped dismissablePopen(), falling back to blocking io.popen()")
        local std_out = io.popen(cmd, "r")
        if std_out then
            local output = std_out:read("*all")
            std_out:close()
            return true, output
        end
        return false
    end

    local trap_widget
    local own_trap_widget = false
    local own_trap_widget_invisible = false
    if type(trap_widget_or_string) == "table" then
        -- Assume it is a usable already displayed trap'able widget with
        -- a dismiss_callback (ie: InfoMessage or TrapWidget)
        trap_widget = trap_widget_or_string
    else
        if type(trap_widget_or_string) == "string" then
            -- Use a TrapWidget with this as text
            trap_widget = TrapWidget:new{
                text = trap_widget_or_string,
            }
            UIManager:show(trap_widget)
            UIManager:forceRePaint()
        else
            -- Use an invisible TrapWidget that resend event, but not if
            -- trap_widget_or_string is false (rather than nil or true)
            local resend_event = true
            if trap_widget_or_string == false then
                resend_event = false
            end
            trap_widget = TrapWidget:new{
                text = nil,
                resend_event = resend_event,
            }
            UIManager:show(trap_widget)
            own_trap_widget_invisible = true
        end
        own_trap_widget = true
    end
    -- Remember the caller's dismiss_callback, so we can restore it when we're done:
    -- otherwise a later tap on a caller-provided widget would resume our coroutine
    -- at whatever unrelated yield it is then parked on.
    local orig_dismiss_callback = trap_widget.dismiss_callback
    trap_widget.dismiss_callback = function()
        -- this callback will resume us at coroutine.yield() below
        -- with a go_on = false
        coroutine.resume(_coroutine, false)
    end

    local collect_interval_sec = 5 -- collect cancelled cmd every 5 second, no hurry
    local check_interval_sec = 0.125 -- start with checking for output every 125ms
    local check_num = 0

    local completed = false
    local output = nil

    local std_out = io.popen(cmd, "r")
    if std_out then
        -- We check regularly if data is available to be read, and we give control
        -- in the meantime to UIManager so our trap_widget's dismiss_callback
        -- get a chance to be triggered, in which case we won't wait for reading,
        -- We'll schedule a background function to collect the unneeded output and
        -- close the pipe later.
        while true do
            -- Every 10 iterations, increase interval until a max of 1 sec is reached
            check_num = check_num + 1
            if check_interval_sec < 1 and check_num % 10 == 0 then
                check_interval_sec = math.min(check_interval_sec * 2, 1)
            end
            -- The following function will resume us at coroutine.yield() below
            -- with a go_on = true
            local go_on_func = function() coroutine.resume(_coroutine, true) end
            UIManager:scheduleIn(check_interval_sec, go_on_func) -- called in 100ms by default
            local go_on = coroutine.yield() -- gives control back to UIManager
            if not go_on then -- the dismiss_callback resumed us
                UIManager:unschedule(go_on_func)
                -- We forget cmd here, but something has to collect
                -- its output and close the pipe to not leak file handles and
                -- zombie processes.
                local collect_and_clean
                collect_and_clean = function()
                    if isPipeReadable(std_out) then -- cmd started outputting, or is done
                        std_out:read("*all")
                        std_out:close()
                        logger.dbg("collected cancelled cmd output")
                    else -- no output yet, reschedule
                        UIManager:scheduleIn(collect_interval_sec, collect_and_clean)
                        logger.dbg("cancelled cmd output not yet collectable")
                    end
                end
                UIManager:scheduleIn(collect_interval_sec, collect_and_clean)
                break
            end
            -- The go_on_func resumed us: we have not been dismissed.
            -- Check if pipe is ready to be read
            if isPipeReadable(std_out) then
                -- Some data is available for reading (or cmd is done): read it all,
                -- but we may block from now on
                output = std_out:read("*all")
                std_out:close()
                completed = true
                break
            end
            -- logger.dbg("no cmd output yet, will check again soon")
        end
    end
    if own_trap_widget then
        -- Remove our own trap_widget
        UIManager:close(trap_widget)
        if not own_trap_widget_invisible then
            UIManager:forceRePaint()
        end
    else
        trap_widget.dismiss_callback = orig_dismiss_callback
    end
    -- return what we got or not to our caller
    return completed, output
end

--[[--
Run a function (task) in a sub-process, allowing it to be dismissed,
and returns its return value(s).

Notes and limitations:

1) As function is run in a sub-process, it can't modify the main
   KOReader process (its parent). It has access to the state of
   KOReader at the time the sub-process was started. It should not
   use any service/driver that would make the parent process vision
   of the device state incoherent (ie: it should not use UIManager,
   display widgets, change settings, enable wifi...).
   It is allowed to modify the filesystem, as long as KOreader
   has not a cached vision of this filesystem part.
   Its returned value(s) are returned to the parent.

2) task may return complex data structures (but with simple lua types,
   no function) or a single string. If task returns a string or nil,
   set task_returns_simple_string to true, allowing for some
   optimisations to be made.

3) If dismissed, the sub-process is killed with SIGKILL, and
   task is aborted without any chance for cleanup work: use of temporary
   files should so be limited (do some cleanup of dirty files from
   previous aborted executions at the start of each new execution if
   needed), and try to keep important operations as atomic as possible.

4) We need a @{ui.widget.trapwidget|TrapWidget} or @{ui.widget.infomessage|InfoMessage},
   that, as a modal, will catch any @{ui.event|Tap event} happening during
   `cmd` execution. This can be an existing already displayed widget, or
   provided as a string (a new TrapWidget will be created). If nil, true or false,
   an invisible TrapWidget will be used instead (if nil or true, the event will be
   resent; if false, the event will not be resent).

A failure to start or read the worker returns `false, nil, "start_failed"` or
`false, nil, "read_failed"`. A user dismissal returns only `false`.

@param task lua function to execute and get return values from
@param trap_widget_or_string already shown widget, string, or nil, true or false
@boolean task_returns_simple_string[opt=false] true if task returns a single string
@treturn boolean completed (`true` if not interrupted, `false` if dismissed)
@return ... return values of task
]]
function Trapper:dismissableRunInSubprocess(task, trap_widget_or_string, task_returns_simple_string)
    local _coroutine, is_main = coroutine.running()
    if not _coroutine or is_main then
        logger.warn("unwrapped dismissableRunInSubprocess(), falling back to blocking in-process run")
        return true, task()
    end

    local trap_widget
    local own_trap_widget = false
    local own_trap_widget_invisible = false
    if type(trap_widget_or_string) == "table" then
        -- Assume it is a usable already displayed trap'able widget with
        -- a dismiss_callback (ie: InfoMessage or TrapWidget)
        trap_widget = trap_widget_or_string
    else
        if type(trap_widget_or_string) == "string" then
            -- Use a TrapWidget with this as text
            trap_widget = TrapWidget:new{
                text = trap_widget_or_string,
            }
            UIManager:show(trap_widget)
            UIManager:forceRePaint()
        else
            -- Use an invisible TrapWidget that resend event, but not if
            -- trap_widget_or_string is false (rather than nil or true)
            local resend_event = true
            if trap_widget_or_string == false then
                resend_event = false
            end
            trap_widget = TrapWidget:new{
                text = nil,
                resend_event = resend_event,
            }
            UIManager:show(trap_widget)
            own_trap_widget_invisible = true
        end
        own_trap_widget = true
    end
    -- Remember the caller's dismiss_callback, so we can restore it when we're done:
    -- otherwise a later tap on a caller-provided widget would resume our coroutine
    -- at whatever unrelated yield it is then parked on.
    local orig_dismiss_callback = trap_widget.dismiss_callback
    trap_widget.dismiss_callback = function()
        -- this callback will resume us at coroutine.yield() below
        -- with a go_on = false
        coroutine.resume(_coroutine, false)
    end

    local collect_interval_sec = 5 -- collect cancelled cmd every 5 second, no hurry
    local check_interval_sec = 0.125 -- start with checking for output every 125ms
    local check_num = 0

    local completed = false
    local ret_values
    local failure_reason
    local output_chunks = {}

    local pid, parent_read_fd = ffiutil.runInSubProcess(function(pid, child_write_fd)
        local output_str = ""
        if task_returns_simple_string then
            -- task is assumed to return only a string or nil,
            -- so avoid a possibly expensive ser/deser roundtrip.
            local result = task()
            if type(result) == "string" then
                output_str = result
            elseif result ~= nil then
                logger.warn("returned value from task is not a string:", result)
            end
        else
            -- task may return complex data structures, that we serialize.
            -- NOTE: LuaJIT's serializer currently doesn't support:
            --       functions, coroutines, non-numerical FFI cdata & full userdata.
            local results = table.pack(task())
            local ok, str = pcall(buffer.encode, results)
            if not ok then
                logger.warn("cannot serialize", tostring(results), "->", str)
            else
                output_str = str
            end
        end
        ffiutil.writeToFD(child_write_fd, output_str, true)
    end, true) -- with_pipe = true

    if not pid then
        -- On failure, the 2nd return value is the error message (e.g., fork failed under memory pressure)
        logger.warn("dismissableRunInSubprocess: could not start subprocess:", parent_read_fd)
        failure_reason = "start_failed"
    end
    if pid then
        -- We check regularly if subprocess is done, and we give control
        -- in the meantime to UIManager so our trap_widget's dismiss_callback
        -- get a chance to be triggered, in which case we'll terminate the
        -- subprocess and schedule a background function to collect it.
        while true do
            -- Every 10 iterations, increase interval until a max of 1 sec is reached
            check_num = check_num + 1
            if check_interval_sec < 1 and check_num % 10 == 0 then
                check_interval_sec = math.min(check_interval_sec * 2, 1)
            end
            -- The following function will resume us at coroutine.yield() below
            -- with a go_on = true
            local go_on_func = function() coroutine.resume(_coroutine, true) end
            UIManager:scheduleIn(check_interval_sec, go_on_func) -- called in 100ms by default
            local go_on = coroutine.yield() -- gives control back to UIManager
            if not go_on then -- the dismiss_callback resumed us
                UIManager:unschedule(go_on_func)
                -- We kill and forget the sub-process here, but something has
                -- to collect it so it does not become a zombie
                ffiutil.terminateSubProcess(pid)
                C.close(parent_read_fd)
                local collect_and_clean
                collect_and_clean = function()
                    if ffiutil.isSubProcessDone(pid) then
                        logger.dbg("collected previously dismissed subprocess")
                    else
                        UIManager:scheduleIn(collect_interval_sec, collect_and_clean)
                        logger.dbg("previously dismissed subprocess not yet collectable")
                    end
                end
                UIManager:scheduleIn(collect_interval_sec, collect_and_clean)
                break
            end
            -- Drain only bytes currently available. A child may still be writing,
            -- or a descendant may hold the pipe open after the child exits.
            local subprocess_done = ffiutil.isSubProcessDone(pid)
            local chunk, eof, drained, read_error = ffiutil.readAvailableFromFD(parent_read_fd)
            if chunk and #chunk > 0 then
                output_chunks[#output_chunks + 1] = chunk
            end
            if not chunk or eof or (subprocess_done and drained) then
                completed = chunk ~= nil
                C.close(parent_read_fd)
                if not chunk then
                    logger.warn("cannot read subprocess result:", read_error)
                    failure_reason = "read_failed"
                    ffiutil.terminateSubProcess(pid)
                else
                    local ret_str = table.concat(output_chunks)
                    if #ret_str > 0 then
                        if task_returns_simple_string then
                            ret_values = ret_str
                        else
                            local ok, t = pcall(buffer.decode, ret_str)
                            if ok and t then
                                ret_values = t
                            else
                                logger.warn("malformed serialized data:", t)
                            end
                        end
                    end
                end
                if not subprocess_done then
                    local collect_and_clean
                    collect_and_clean = function()
                        if ffiutil.isSubProcessDone(pid) then
                            logger.dbg("collected subprocess")
                        else
                            UIManager:scheduleIn(1, collect_and_clean)
                        end
                    end
                    UIManager:scheduleIn(1, collect_and_clean)
                end
                break
            end
            if #chunk > 0 or not drained then
                -- Continue active transfers promptly, allowing input between reads.
                check_interval_sec = 0.01
                check_num = 0
            end
            logger.dbg("process not yet done, will check again soon")
        end
    end
    if own_trap_widget then
        -- Remove our own trap_widget
        UIManager:close(trap_widget)
        if not own_trap_widget_invisible then
            UIManager:forceRePaint()
        end
    else
        trap_widget.dismiss_callback = orig_dismiss_callback
    end
    -- Failure reasons distinguish operational errors from a user dismissal.
    if failure_reason then return false, nil, failure_reason end
    -- return what we got or not to our caller
    if ret_values then
        if task_returns_simple_string then
            return completed, ret_values
        else
            return completed, unpack(ret_values, 1, ret_values.n)
        end
    end
    return completed
end

return Trapper
