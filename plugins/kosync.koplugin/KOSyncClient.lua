local UIManager = require("ui/uimanager")
local logger = require("logger")
local socketutil = require("socketutil")

-- Push/Pull
local PROGRESS_TIMEOUTS = { 2,  5 }
-- Login/Register
local AUTH_TIMEOUTS     = { 5, 10 }

local KOSyncClient = {
    service_spec = nil,
    custom_url = nil,
}

function KOSyncClient:new(o)
    if o == nil then o = {} end
    setmetatable(o, self)
    self.__index = self
    if o.init then o:init() end
    return o
end

function KOSyncClient:init()
    local Spore = require("Spore")
    self.client = Spore.new_from_spec(self.service_spec, {
        base_url = self.custom_url,
    })
    package.loaded["Spore.Middleware.GinClient"] = {}
    require("Spore.Middleware.GinClient").call = function(_, req)
        req.headers["accept"] = "application/vnd.koreader.v1+json"
    end
    package.loaded["Spore.Middleware.KOSyncAuth"] = {}
    require("Spore.Middleware.KOSyncAuth").call = function(args, req)
        req.headers["x-auth-user"] = args.username
        req.headers["x-auth-key"] = args.userkey
    end
    package.loaded["Spore.Middleware.AsyncHTTP"] = {}
    require("Spore.Middleware.AsyncHTTP").call = function(args, req)
        -- disable async http if Turbo looper is missing
        if not UIManager.looper then return end
        req:finalize()
        local result
        require("httpclient"):new():request({
            url = req.url,
            method = req.method,
            body = req.env.spore.payload,
            on_headers = function(headers)
                for header, value in pairs(req.headers) do
                    if type(header) == "string" then
                        headers:add(header, value)
                    end
                end
            end,
        }, function(res)
            result = res
            -- Turbo HTTP client uses code instead of status
            -- change to status so that Spore can understand
            result.status = res.code
            coroutine.resume(args.thread)
        end)
        return coroutine.create(function() coroutine.yield(result) end)
    end
end

function KOSyncClient:register(username, password)
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("GinClient")
    socketutil:set_timeout(AUTH_TIMEOUTS[1], AUTH_TIMEOUTS[2])
    local ok, res = pcall(function()
        return self.client:register({
            username = username,
            password = password,
        })
    end)
    socketutil:reset_timeout()
    if ok then
        return res.status == 201, res.body
    else
        logger.dbg("KOSyncClient:register failure:", res)
        return false, res.body
    end
end

function KOSyncClient:authorize(username, password)
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("GinClient")
    self.client:enable("KOSyncAuth", {
        username = username,
        userkey = password,
    })
    socketutil:set_timeout(AUTH_TIMEOUTS[1], AUTH_TIMEOUTS[2])
    local ok, res = pcall(function()
        return self.client:authorize()
    end)
    socketutil:reset_timeout()
    if ok then
        return res.status == 200, res.body
    else
        logger.dbg("KOSyncClient:authorize failure:", res)
        return false, res.body
    end
end

-- Default KOReader has no Turbo looper. A coroutine alone does not make
-- Spore's synchronous transport nonblocking. Bound workers across client
-- instances and retain at most one pending progress request.
function KOSyncClient:_runInSubprocess(task, callback, busy_text)
    local Queue = require("KOSyncQueue")
    local generation = Queue._generation
    local job = { task = task, callback = callback, text = busy_text, generation = generation }
    local start
    start = function(next_job)
        KOSyncClient._active_worker = next_job
        local watchdog
        local function finish(...)
            if watchdog then UIManager:unschedule(watchdog) end
            -- Keep the slot occupied during callbacks: a queue drain may
            -- synchronously request its next upload from this callback.
            local ok, err = pcall(next_job.callback, ...)
            KOSyncClient._active_worker = nil
            local pending = KOSyncClient._pending_worker
            KOSyncClient._pending_worker = nil
            if pending then start(pending) end
            if not ok then logger.warn("KOSyncClient: worker callback failed:", err) end
        end
        if next_job.generation ~= Queue._generation then
            finish(false, nil, "stale")
            return
        end
        local ffiUtil = require("ffi/util")
        if type(ffiUtil.runInSubProcess) ~= "function" then
            finish(false, nil, "start_failed")
            return
        end
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local trap = next_job.text
            if trap == nil then
                -- Background synchronization must not intercept normal input.
                trap = {}
                watchdog = function()
                    if KOSyncClient._active_worker == next_job and trap.dismiss_callback then
                        trap.dismiss_callback()
                    end
                end
                -- Cover blocking DNS as well as HTTP, allowing one extra
                -- second for the existing connect/read deadlines/result collector.
                UIManager:scheduleIn(PROGRESS_TIMEOUTS[1] + PROGRESS_TIMEOUTS[2] + 1, watchdog)
            end
            finish(Trapper:dismissableRunInSubprocess(next_job.task, trap))
        end)
    end
    if KOSyncClient._active_worker then
        -- Auth stays user driven: refuse a busy request rather than retain
        -- additional credentials or start another worker.
        if busy_text or KOSyncClient._pending_worker then
            callback(false, nil, "busy")
        else
            KOSyncClient._pending_worker = job
        end
        return
    end
    start(job)
end

-- Only protocol scalars cross the worker pipe. Unknown response fields stay
-- in the child; reject oversized/nested values in the fields the UI consumes.
function KOSyncClient:_workerBody(body, auth_only)
    if type(body) ~= "table" then return nil, true end
    local fields = auth_only and { "message" } or {
        "progress", "percentage", "device", "device_id", "timestamp", "message",
    }
    local limits = { progress = 65536, device = 1024, device_id = 1024, message = 4096 }
    local remaining, result = 65536, {}
    for _, key in ipairs(fields) do
        local value = body[key]
        if value ~= nil then
            if type(value) == "string" and limits[key] then
                if #value > limits[key] or #value > remaining then return nil, false end
                remaining = remaining - #value
            elseif type(value) == "number" and (key == "progress" or key == "percentage" or key == "timestamp") then
                if value ~= value or value == math.huge or value == -math.huge then return nil, false end
            else
                return nil, false
            end
            result[key] = value
        end
    end
    return result, true
end

function KOSyncClient:_syncProgress(method, username, password, params)
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("GinClient")
    self.client:enable("KOSyncAuth", { username = username, userkey = password })
    socketutil:set_timeout(PROGRESS_TIMEOUTS[1], PROGRESS_TIMEOUTS[2])
    local ok, res = pcall(self.client[method], self.client, params)
    socketutil:reset_timeout()
    if not ok then
        logger.dbg("KOSyncClient: progress request failure:", res)
        return false, nil, nil
    end
    local body, valid = self:_workerBody(res.body)
    if not valid then return false, res.status, nil end
    return res.status == 200, res.status, body
end

function KOSyncClient:update_progress(
        username,
        password,
        document,
        metadata,
        progress,
        percentage,
        device,
        device_id,
        callback)
    if not UIManager.looper then
        self:_runInSubprocess(function()
            return self:_syncProgress("update_progress", username, password, {
                document = document, metadata = metadata, progress = tostring(progress),
                percentage = percentage, device = device, device_id = device_id,
            })
        end, function(completed, ok, status, body)
            if completed then callback(ok == true, status, body) else callback(false, nil, nil) end
        end)
        return
    end
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("GinClient")
    self.client:enable("KOSyncAuth", {
        username = username,
        userkey = password,
    })
    -- Set *very* tight timeouts to avoid blocking for too long...
    socketutil:set_timeout(PROGRESS_TIMEOUTS[1], PROGRESS_TIMEOUTS[2])
    local co = coroutine.create(function()
        local ok, res = pcall(function()
            return self.client:update_progress({
                document = document,
                metadata = metadata,
                progress = tostring(progress),
                percentage = percentage,
                device = device,
                device_id = device_id,
            })
        end)
        if ok then
            callback(res.status == 200, res.status, res.body)
        else
            logger.dbg("KOSyncClient:update_progress failure:", res)
            callback(false, nil, nil)
        end
    end)
    self.client:enable("AsyncHTTP", {thread = co})
    coroutine.resume(co)
    if UIManager.looper then UIManager:setInputTimeout() end
    socketutil:reset_timeout()
end

function KOSyncClient:get_progress(
        username,
        password,
        document,
        callback)
    if not UIManager.looper then
        self:_runInSubprocess(function()
            return self:_syncProgress("get_progress", username, password, { document = document })
        end, function(completed, ok, _, body)
            if completed then callback(ok == true, body) else callback(false, nil) end
        end)
        return
    end
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("GinClient")
    self.client:enable("KOSyncAuth", {
        username = username,
        userkey = password,
    })
    socketutil:set_timeout(PROGRESS_TIMEOUTS[1], PROGRESS_TIMEOUTS[2])
    local co = coroutine.create(function()
        local ok, res = pcall(function()
            return self.client:get_progress({
                document = document,
            })
        end)
        if ok then
            callback(res.status == 200, res.body)
        else
            logger.dbg("KOSyncClient:get_progress failure:", res)
            callback(false, res.body)
        end
    end)
    self.client:enable("AsyncHTTP", {thread = co})
    coroutine.resume(co)
    if UIManager.looper then UIManager:setInputTimeout() end
    socketutil:reset_timeout()
end

return KOSyncClient
