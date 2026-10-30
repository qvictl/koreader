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
        retained[kc] = nil
        return
    end
    join(worker)
    kc:free()
    worker.freed = true
    ffi.gc(kc, nil)
    retained[kc] = nil
end

local function finalize(kc, worker)
    local ok, err = pcall(free, kc, worker)
    if not ok then
        -- Never let GC reclaim the struct while native code may still use it.
        -- Keep the failed owner available for a later explicit retry.
        retained[kc] = worker
        logger.err("Unable to release background KOPT context:", err)
    end
end

function KoptThread.reap()
    local complete = true
    for kc, worker in pairs(retained) do
        local ok, err = pcall(free, kc, worker)
        if not ok then
            complete = false
            logger.err("Unable to reap background KOPT context:", err)
        end
    end
    return complete
end

function KoptThread.start(kc, pthread, entry)
    KoptThread.reap()
    local worker = { pthread = pthread, thread = ffi.new("pthread_t[1]"), pid = getpid() }
    workers[kc] = worker
    -- Capture only the worker. Capturing kc here would keep the context alive.
    -- The weak-key table may already have lost its entry when this runs.
    ffi.gc(kc, function(context) finalize(context, worker) end)
    local status = "pthread unavailable"
    if pthread then
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
    if not worker.started then
        logger.warn("Unable to start background KOPT worker; reflowing synchronously:", status)
        entry(kc)
    end
    return worker.started
end

function KoptThread.wait(kc)
    local worker = workers[kc]
    if worker then
        if worker.freed then error("KOPT context has already been freed") end
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
