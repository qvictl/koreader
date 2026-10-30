-- A context's precache flag is progress, not a native thread completion barrier.
local ffi = require("ffi")
local logger = require("logger")

require("ffi/posix_h")
ffi.cdef[[
int pthread_join(pthread_t, void **);
int _getpid(void);
]]

local KoptThread = {}
local workers = setmetatable({}, { __mode = "k" })
local retained = {}
local retained_count = 0

local function forget(kc)
    if retained[kc] then
        retained[kc] = nil
        retained_count = retained_count - 1
    end
end

local function reportFailure(worker, err)
    if not worker.reported then
        worker.reported = true
        logger.err("Unable to release background KOPT context:", err)
    end
end

local function getpid()
    if ffi.os == "Windows" then return ffi.C._getpid() end
    return ffi.C.getpid()
end

local function inherited(worker)
    return worker.pid ~= getpid()
end

local function join(worker)
    if worker.started and not worker.joined then
        if inherited(worker) then error("KOPT context belongs to another process") end
        -- Keep the array: a test barrier may defer pthread_create's write to it.
        local status = worker.pthread.pthread_join(worker.thread[0], nil)
        if status ~= 0 then error("pthread_join failed: " .. status) end
        worker.joined = true
    end
end

local function free(kc, worker)
    if worker.freed then return end
    if inherited(worker) then
        -- A fork child has no copy of the parent's worker. Neither joining its
        -- thread ID nor destroying its in-progress buffer snapshot is valid.
        -- The child process exit reclaims this inherited allocation instead.
        worker.freed = true
        ffi.gc(kc, nil)
        forget(kc)
        return
    end
    join(worker)
    kc:free()
    worker.freed = true
    ffi.gc(kc, nil)
    forget(kc)
end

local function finalize(kc, worker)
    local ok, err = pcall(free, kc, worker)
    if not ok then
        -- Never let GC reclaim the struct while native code may still use it.
        -- Keep the failed owner available for a later explicit retry.
        if not retained[kc] then retained_count = retained_count + 1 end
        retained[kc] = worker
        reportFailure(worker, err)
    end
end

function KoptThread.reap()
    local complete = true
    for kc, worker in pairs(retained) do
        local ok, err = pcall(free, kc, worker)
        if not ok then
            complete = false
            reportFailure(worker, err)
        end
    end
    return complete
end

function KoptThread.start(kc, pthread, entry)
    KoptThread.reap()
    local worker = { pthread = pthread, thread = ffi.new("pthread_t[1]"), pid = getpid(), started = false }
    workers[kc] = worker
    -- Capture only the worker. Capturing kc here would keep the context alive.
    -- The weak-key table may already have lost its entry when this runs.
    ffi.gc(kc, function(context) finalize(context, worker) end)
    local status = "pthread unavailable"
    -- Stop prefetching while any failed owner remains. A later foreground
    -- request can render the page without blocking the UI's hint callback.
    local deferred = retained_count > 0
    if pthread and not deferred then
        local attr = ffi.new("pthread_attr_t[1]")
        -- POSIX attributes are joinable by default.
        status = pthread.pthread_attr_init(attr)
        if status == 0 then
            status = pthread.pthread_create(worker.thread, attr, entry, ffi.cast("void*", kc))
            worker.started = status == 0
            local destroyed = pthread.pthread_attr_destroy(attr)
            if destroyed ~= 0 then logger.warn("pthread_attr_destroy failed:", destroyed) end
        end
    end
    if not worker.started and not deferred then
        logger.warn("Unable to start background KOPT worker; skipping prefetch:", status)
    end
    return worker.started
end

function KoptThread.isInherited(kc)
    local worker = workers[kc]
    return worker ~= nil and inherited(worker)
end

function KoptThread.canStart(pthread)
    KoptThread.reap()
    return pthread ~= nil and retained_count == 0
end

function KoptThread.wait(kc)
    local worker = workers[kc]
    if worker then
        if worker.freed then error("KOPT context has already been freed") end
        if not worker.started then error("KOPT worker did not start") end
        join(worker)
    end
end

function KoptThread.free(kc)
    local worker = workers[kc]
    if worker then
        free(kc, worker)
    else
        kc:free()
    end
end

return KoptThread
