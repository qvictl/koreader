--[[--
Integration test driver, running inside a real KOReader (emulator) process.

It is loaded by a "late" user patch (see tools/run_integration_tests.sh), i.e. once
UIManager is ready but before the file manager is shown, and runs one scenario
(`IT_SCENARIO`, a Lua file returning a table with a `run(T)` function) in a coroutine
that is resumed from UIManager tasks, so that the real event loop keeps running
(painting, scheduled tasks, subprocess polling…) while the scenario waits.

User actions are run from the main (non-coroutine) context with `T:run(fn)`, like
real input events are, so that code relying on coroutines (Trapper, dictionary
lookups) behaves as in normal use.

Results are written as JSON to `IT_RESULT`; the process then quits. A crash (Lua
error in the UI loop) is detected by the runner as a missing/incomplete result.

Environment:
    IT_SCENARIO   scenario file (required)
    IT_RESULT     result JSON file (required)
    IT_FIXTURES   fixtures directory
    IT_NO_BUDGETS when set, budget violations are only reported (e.g. coverage runs)
    IT_BUDGET_SCALE multiply every budget by this factor (default 1)
]]

local scenario_file = os.getenv("IT_SCENARIO")
local result_file = os.getenv("IT_RESULT")
if not scenario_file or not result_file then
    return
end

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")

pcall(ffi.cdef, "int getpid(void);")

local process_start = time.now() -- (close enough: we're loaded during startup)

-- JSON encoding (results only hold strings, numbers, booleans and tables of those). {{{

local function json_encode(v)
    local t = type(v)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if math.floor(v) == v and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.3f", v)
    elseif t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c)
            local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
            return map[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    elseif t == "table" then
        if #v > 0 or next(v) == nil then
            local parts = {}
            for _, e in ipairs(v) do table.insert(parts, json_encode(e)) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do table.insert(keys, tostring(k)) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            table.insert(parts, json_encode(k) .. ":" .. json_encode(v[k]))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return json_encode(tostring(v))
end

-- }}}

local result = {
    scenario = scenario_file:match("([^/]+)%.lua$") or scenario_file,
    status = "running",
    checks = {},
    metrics = {},
    budgets = {},
    failures = {},
    log = {},
}

local function writeResult()
    local f = io.open(result_file .. ".tmp", "w")
    if not f then
        logger.err("IT: cannot write", result_file)
        return
    end
    f:write(json_encode(result), "\n")
    f:close()
    os.rename(result_file .. ".tmp", result_file)
end

-- The test API. {{{

local T = {
    fixtures = os.getenv("IT_FIXTURES") or ".",
    spec_dir = (os.getenv("IT_SCENARIO") or ""):match("^(.*)/scenarios/[^/]*$") or "spec/integration",
    no_budgets = os.getenv("IT_NO_BUDGETS") ~= nil and os.getenv("IT_NO_BUDGETS") ~= "",
    budget_scale = tonumber(os.getenv("IT_BUDGET_SCALE") or "") or 1,
    screen_w = Device.screen:getWidth(),
    screen_h = Device.screen:getHeight(),
}

local co -- the scenario coroutine

local function fail(msg, level)
    error({ it_failure = true, msg = msg, where = debug.traceback("", (level or 1) + 1) }, 0)
end

--- Logs a message to the result (and KOReader's log).
function T:log(...)
    local t = {}
    for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
    local msg = table.concat(t, " ")
    table.insert(result.log, string.format("%.3f %s", time.to_s(time.since(process_start)), msg))
    logger.info("IT:", msg)
end

--- Current time, in ms (monotonic).
function T:now()
    return time.to_ms(time.now())
end

--- Path of a fixture file.
function T:fixture(rel)
    return self.fixtures .. "/" .. rel
end

--- Yields to the UI loop, for `sec` seconds (default: one tick).
function T:wait(sec)
    local me = co
    UIManager:scheduleIn(sec or 0, function()
        local ok, err = coroutine.resume(me)
        if not ok then
            -- Errors are handled by the resume loop below: this only happens if the
            -- coroutine died in an unexpected way.
            logger.err("IT: scenario coroutine died:", err)
        end
    end)
    coroutine.yield()
end

--- Waits until `pred()` returns a truthy value (returned), polling every `step` seconds.
function T:waitUntil(pred, timeout, what, step)
    local deadline = self:now() + (timeout or 10) * 1000
    while true do
        local v = pred()
        if v then return v end
        if self:now() > deadline then
            fail("timeout (" .. (timeout or 10) .. " s) waiting for " .. (what or "condition"), 2)
        end
        self:wait(step or 0.02)
    end
end

--- Runs `fn` in the main context (outside of the scenario coroutine), as an input
-- handler would, then returns its results. Errors are propagated to the scenario.
function T:run(fn, ...)
    local args = { n = select("#", ...), ... }
    local done, ret
    UIManager:nextTick(function()
        ret = { xpcall(function() return fn(unpack(args, 1, args.n)) end, debug.traceback) }
        done = true
    end)
    while not done do
        self:wait(0)
    end
    if not ret[1] then
        fail("error in UI action: " .. tostring(ret[2]), 2)
    end
    return unpack(ret, 2)
end

--- Records a (hard) check: a failure aborts the scenario.
function T:check(cond, msg)
    table.insert(result.checks, { ok = cond and true or false, msg = msg })
    if not cond then
        fail("check failed: " .. tostring(msg), 2)
    end
    return cond
end

--- Records a soft check: a failure is reported, but the scenario goes on.
function T:expect(cond, msg)
    table.insert(result.checks, { ok = cond and true or false, msg = msg })
    if not cond then
        table.insert(result.failures, { msg = "expectation failed: " .. tostring(msg), where = debug.traceback("", 2) })
    end
    return cond
end

local function show(v)
    if type(v) == "table" then return json_encode(v) end
    return tostring(v)
end

function T:eq(actual, expected, msg)
    local same = actual == expected
    if not same and type(actual) == "table" and type(expected) == "table" then
        same = json_encode(actual) == json_encode(expected)
    end
    return self:check(same, string.format("%s (expected %s, got %s)", msg, show(expected), show(actual)))
end

--- Records a metric.
function T:metric(name, value, unit)
    result.metrics[name] = { value = value, unit = unit }
    self:log("metric", name, value, unit or "")
end

--- Records a metric, and checks it is at most `max` (times IT_BUDGET_SCALE).
function T:budget(name, value, max, unit)
    max = max * self.budget_scale
    local ok = value <= max
    result.budgets[name] = { value = value, max = max, unit = unit, ok = ok }
    self:log("budget", name, value, "<=", max, unit or "", ok and "OK" or "EXCEEDED")
    if not ok and not self.no_budgets then
        table.insert(result.failures, { msg = string.format("budget exceeded: %s = %s %s > %s", name, value, unit or "", max) })
    end
    return ok
end

--- Forces a repaint of everything that is dirty.
function T:repaint()
    UIManager:forceRePaint()
end

local function gesture(ges, x, y, extra)
    local g = {
        ges = ges,
        pos = Geom:new{ x = x, y = y, w = 0, h = 0 },
        time = time.now(),
    }
    for k, v in pairs(extra or {}) do g[k] = v end
    return Event:new("Gesture", g)
end

--- Sends a tap gesture at (x, y), as the gesture detector would (from the main context).
function T:tap(x, y)
    return self:run(function() return UIManager:sendEvent(gesture("tap", x, y)) end)
end

--- Returns a tap gesture event (to be sent with UIManager:sendEvent from a T:run action).
function T:tapEvent(x, y)
    return gesture("tap", x, y)
end

--- Taps the center of a (painted) widget.
function T:tapWidget(w, what)
    local d = w and w.dimen
    self:check(d and d.w and d.w > 0, "widget to tap has been painted: " .. tostring(what))
    return self:tap(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
end

--- Swipes from (x, y) in `direction` ("west", "east", "north", "south").
function T:swipe(x, y, direction, distance)
    return self:run(function()
        return UIManager:sendEvent(gesture("swipe", x, y, { direction = direction, distance = distance or 200 }))
    end)
end

--- Depth-first search of a widget tree (array children, plus `[1]` of containers) for a widget matching `pred`.
function T:findWidget(root, pred, seen)
    if type(root) ~= "table" then return end
    seen = seen or {}
    if seen[root] then return end
    seen[root] = true
    if pred(root) then return root end
    for _, child in ipairs(root) do
        local found = self:findWidget(child, pred, seen)
        if found then return found end
    end
    -- Some widgets keep their content out of the array part.
    for _, k in ipairs({ "item_group", "content_group", "file_chooser", "movable", "frame" }) do
        if type(root[k]) == "table" then
            local found = self:findWidget(root[k], pred, seen)
            if found then return found end
        end
    end
end

--- Names of the widgets in the window stack (bottom to top), for diagnostics.
function T:windowStack()
    local names = {}
    for _, w in ipairs(UIManager._window_stack) do
        local wg = w.widget
        table.insert(names, tostring(wg and (wg.name or wg.id or (wg.text and tostring(wg.text):sub(1, 40))) or "?"))
    end
    return table.concat(names, " > ")
end

--- Top-most widget of the window stack.
function T:topWidget()
    local top = UIManager._window_stack[#UIManager._window_stack]
    return top and top.widget
end

--- The FileManager instance, if shown.
function T:fileManager()
    return require("apps/filemanager/filemanager").instance
end

--- The ReaderUI instance, if shown.
function T:reader()
    return require("apps/reader/readerui").instance
end

--- Opens a book and waits for it to be ready (first page shown). Returns the ReaderUI and the time it took (ms).
function T:openBook(path)
    local ReaderUI = require("apps/reader/readerui")
    local t0 = self:now()
    self:run(function()
        if ReaderUI.instance then
            ReaderUI.instance:switchDocument(path)
        else
            ReaderUI:showReader(path)
        end
    end)
    local ui = self:waitUntil(function()
        local ui = ReaderUI.instance
        return ui and ui.document and ui.document.file == path and ui.view and ui.view.dimen and ui
    end, 60, "book to open: " .. path)
    -- Wait for the first paint of the reader.
    self:run(function() UIManager:forceRePaint() end)
    return ui, self:now() - t0
end

--- Closes the current book (back to the file manager). Returns the time it took (ms).
function T:closeBook()
    local ReaderUI = require("apps/reader/readerui")
    local t0 = self:now()
    if ReaderUI.instance then
        self:run(function() ReaderUI.instance:onHome() end)
    end
    self:waitUntil(function() return not ReaderUI.instance and self:fileManager() end, 30, "book to close")
    self:run(function() UIManager:forceRePaint() end)
    return self:now() - t0
end

--- Resident set size, in kB.
function T:rssKb()
    local f = io.open("/proc/self/statm", "r")
    if not f then return 0 end
    local _, resident = f:read("*l"):match("^(%d+)%s+(%d+)")
    f:close()
    return tonumber(resident) * 4
end

--- Lua heap, in kB (after a full GC).
function T:luaKb()
    collectgarbage()
    collectgarbage()
    return collectgarbage("count")
end

--- Number of open file descriptors.
function T:fdCount()
    local n = 0
    for f in lfs.dir("/proc/self/fd") do
        if f ~= "." and f ~= ".." then n = n + 1 end
    end
    return n
end

--- Description of the open file descriptors (fd -> target), for diagnostics.
function T:fdList()
    local t = {}
    for f in lfs.dir("/proc/self/fd") do
        if f ~= "." and f ~= ".." then
            local p = io.popen("readlink /proc/" .. ffi.C.getpid() .. "/fd/" .. f .. " 2>/dev/null")
            local target = p and p:read("*l") or "?"
            if p then p:close() end
            table.insert(t, f .. "=" .. tostring(target))
        end
    end
    table.sort(t)
    return table.concat(t, " ")
end

--- PIDs of our live (non-zombie) child processes.
function T:children()
    local pids = {}
    local mypid = tostring(ffi.C.getpid())
    for d in lfs.dir("/proc") do
        if d:match("^%d+$") then
            local f = io.open("/proc/" .. d .. "/stat", "r")
            if f then
                local stat = f:read("*l") or ""
                f:close()
                -- pid (comm) state ppid …
                local state, ppid = stat:match("^%d+ %b() (%S) (%d+)")
                if ppid == mypid and state ~= "Z" then
                    table.insert(pids, tonumber(d))
                end
            end
        end
    end
    return pids
end

--- Wraps `obj[method]` to count calls (and record their arguments). Returns the stats table.
function T:spy(obj, method)
    local stats = { calls = 0, args = {} }
    local orig = obj[method]
    obj[method] = function(...)
        stats.calls = stats.calls + 1
        table.insert(stats.args, { ... })
        return orig(...)
    end
    stats.restore = function() obj[method] = orig end
    return stats
end

-- }}}

-- Load and run the scenario. {{{

local ok, scenario = pcall(dofile, scenario_file)
if not ok or type(scenario) ~= "table" or type(scenario.run) ~= "function" then
    result.status = "error"
    table.insert(result.failures, { msg = "cannot load scenario: " .. tostring(scenario) })
    writeResult()
    UIManager:nextTick(function() UIManager:quit() end)
    return
end
result.name = scenario.name
result.description = scenario.description

-- Optional synchronous setup, run now (during startup, before the file manager is shown),
-- e.g. to install spies on things that are initialized at startup.
if type(scenario.setup) == "function" then
    local setup_ok, setup_err = xpcall(scenario.setup, debug.traceback, T)
    if not setup_ok then
        result.status = "failed"
        table.insert(result.failures, { msg = "scenario setup failed: " .. tostring(setup_err) })
        writeResult()
        UIManager:nextTick(function() UIManager:quit() end)
        return
    end
end

local finished = false
local function finish(status)
    if finished then return end
    finished = true
    result.status = status
    if status == "passed" and #result.failures > 0 then
        result.status = "failed"
    end
    result.duration_s = time.to_s(time.since(process_start))
    writeResult()
    logger.info("IT: scenario", result.scenario, result.status)
    -- Flush coverage data now, rather than relying on exit handlers.
    if package.loaded["luacov.runner"] then
        pcall(function() package.loaded["luacov.runner"].save_stats() end)
    end
    UIManager:quit()
end

co = coroutine.create(function()
    -- Let the startup finish (file manager shown & painted).
    T:waitUntil(function() return T:fileManager() end, 60, "file manager to show")
    T:wait(0.2)
    -- First start informational popups (e.g., "Book info cache database updated") are not
    -- what we're testing: dismiss them, so that the file manager is on top.
    local deadline = T:now() + 10000
    while T:topWidget() ~= T:fileManager() and T:now() < deadline do
        local top = T:topWidget()
        if top and top.text and not top.is_always_active then
            T:log("dismissing startup popup:", tostring(top.text):sub(1, 80))
            T:run(function() UIManager:close(top) end)
        end
        T:wait(0.1)
    end
    result.startup_ms = time.to_ms(time.since(process_start))
    T.startup_ms = result.startup_ms
    scenario.run(T)
end)

local function step()
    -- First resume (errors are handled by the coroutine.resume wrapper below).
    coroutine.resume(co)
end

-- Detect the end of the scenario (or its death) from the UI loop.
local function poll()
    if finished then return end
    local status = coroutine.status(co)
    if status == "dead" then
        finish(#result.failures == 0 and "passed" or "failed")
        return
    end
    UIManager:scheduleIn(0.05, poll)
end

-- T:wait resumes the coroutine itself; errors raised after a T:wait resume end up here:
local raw_resume = coroutine.resume
-- luacheck: push ignore 122
coroutine.resume = function(c, ...)
    local res = { raw_resume(c, ...) }
    if c == co and not res[1] and not finished then
        local err = res[2]
        if type(err) == "table" and err.it_failure then
            table.insert(result.failures, { msg = err.msg, where = err.where })
        else
            table.insert(result.failures, { msg = "error: " .. tostring(err), where = debug.traceback(co) })
        end
        finish("failed")
    end
    return unpack(res)
end
-- luacheck: pop

local timeout = tonumber(os.getenv("IT_TIMEOUT") or "") or scenario.timeout or 120
UIManager:scheduleIn(timeout, function()
    if not finished then
        table.insert(result.failures, { msg = "scenario timeout (" .. timeout .. " s)", where = debug.traceback(co) })
        finish("failed")
    end
end)

UIManager:scheduleIn(0.1, step)
UIManager:scheduleIn(0.2, poll)
writeResult()

-- }}}

-- vim: foldmethod=marker foldlevel=0
