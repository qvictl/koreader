local ffi = require("ffi")
local util = require("util")
local ffiUtil = require("ffi/util")
local json = require("rapidjson")
local Server = {}
Server.__index = Server

local function read(path)
    local file = io.open(path, "r")
    if not file then return end
    local data = file:read("*a")
    file:close()
    local ok, result = pcall(json.decode, data)
    if ok then return result end
end

function Server.start(T)
    local root = os.getenv("KO_HOME") .. "/loopback-http"
    util.makePath(root)
    local script = T.spec_dir .. "/mock_http_server.py"
    local pid, err = ffiUtil.runInSubProcess(function()
        ffi.C.execlp("python3", "python3", script, root, ffi.cast("char *", nil))
        ffi.C._exit(127)
    end)
    assert(pid, err)
    local self = setmetatable({ T = T, root = root, pid = pid, jobs = {} }, Server)
    local ok, ready = pcall(T.waitUntil, T, function() return read(root .. "/ready.json") end, 5, "loopback HTTP server")
    if not ok then pcall(self.close, self); error(ready, 0) end
    self.url = "http://127.0.0.1:" .. ready.port
    return self
end

function Server:plan(status, body, delay)
    local job = { dir = self.root .. "/" .. (#self.jobs + 1) }
    util.makePath(job.dir)
    local file = assert(io.open(job.dir .. "/plan.json", "w"))
    assert(file:write(json.encode{ status = status, body = body, delay = delay }))
    assert(file:close())
    self.jobs[#self.jobs + 1] = job
    return job
end

function Server:received(job) return read(job.dir .. "/received.json") end
function Server:waitReceived(job)
    return self.T:waitUntil(function() return self:received(job) end, 5, "real HTTP request arrival")
end
function Server:release(job)
    local file = assert(io.open(job.dir .. "/release", "w"))
    assert(file:close())
end
function Server:waitFinished(job)
    local result = self.T:waitUntil(function() return read(job.dir .. "/finished.json") end, 5, "HTTP fixture response")
    assert(not result.expired, "HTTP fixture release gate expired")
    return result
end
function Server:close()
    for _, job in ipairs(self.jobs) do self:release(job) end
    if self.pid then
        local pid = self.pid
        if not ffiUtil.isSubProcessDone(pid) then
            ffi.C.kill(pid, 15)
            self.T:waitUntil(function() return ffiUtil.isSubProcessDone(pid) end, 5, "HTTP fixture reaped")
        end
        self.pid = nil
    end
end
return Server
