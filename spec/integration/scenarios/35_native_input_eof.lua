-- Linux native input poller -> frontend key handling -> a real ReaderUI page turn.
-- Only owned pipes are registered; the emulator keeps its normal SDL input backend.
return {
    name = "A dead native input producer does not block the reader",
    timeout = 30,
    run = function(T)
        local ffi = require("ffi")
        local C = ffi.C
        local Device = require("device")
        local Input = require("device/input")
        local UIManager = require("ui/uimanager")
        local logger = require("logger")
        local time = require("ui/time")
        local native = assert(package.loadlib("./libs/libkoreader-input-test.so", "luaopen_input_test"))()
        local input = Input:new{ device = Device, input = native, event_map = { [30] = "LPgFwd" } }
        local writers, paths = {}, {}
        local original_warn, warnings = logger.warn, 0
        local reader = T:openBook(T:fixture("books/en.epub"))
        local function pipe(path)
            local fds = ffi.new("int[2]")
            assert(C.pipe(fds) == 0)
            local rd, wr = tonumber(fds[0]), tonumber(fds[1])
            writers[wr] = true
            assert(C.fcntl(rd, C.F_SETFL, ffi.cast("int", C.O_NONBLOCK)) == 0)
            assert(Input.opened_devices[path] == nil)
            input:fdopen(rd, path)
            paths[path] = true
            return rd, wr
        end
        local function closeWriter(wr)
            assert(C.close(wr) == 0)
            writers[wr] = nil
        end
        local ok, err = xpcall(function()
            T:run(function()
                local dead_path, key_path = "native-eof/empty", "native-eof/keys"
                local dead_fd, dead_writer = pipe(dead_path)
                local key_fd, key_writer = pipe(key_path)
                closeWriter(dead_writer)
                local keys = ffi.new("struct input_event[2]")
                keys[0].type, keys[0].code, keys[0].value = C.EV_KEY, 30, 1
                keys[1].type, keys[1].code, keys[1].value = C.EV_KEY, 30, 0
                assert(C.write(key_writer, keys, ffi.sizeof(keys)) == ffi.sizeof(keys))
                closeWriter(key_writer)
                logger.warn = function(...)
                    local message, errno = ...
                    if message == "Polling for input events returned an error:" and errno == C.EPIPE then
                        warnings = warnings + 1
                    end
                    return original_warn(...)
                end
                local now = time.now()
                local error_events = input:waitEvent(now, now)
                T:eq(error_events[1].handler, "onInputError", "empty producer EOF is reported to the UI")
                T:eq(error_events[1].args[1], tonumber(C.EPIPE), "the one-shot input error retains EPIPE")
                T:eq(C.fcntl(dead_fd, C.F_GETFD), -1, "the dead descriptor is actually closed")
                T:eq(Input.opened_devices[dead_path], nil, "empty EOF forgets the frontend path")
                local events = input:waitEvent(now, now)
                T:check(events and #events == 2, "the next producer's final key press and release survive EOF")
                T:eq(events[1].handler, "onKeyPress", "the native key reaches frontend key handling")
                T:eq(C.fcntl(key_fd, C.F_GETFD), -1, "the final-event producer is retired too")
                T:eq(Input.opened_devices[key_path], nil, "final-event EOF forgets the frontend path")
                local replacement_fd, replacement_writer = pipe("native-eof/replacement")
                T:eq(replacement_fd, dead_fd, "the OS reuses the retired descriptor number")
                input:close(dead_path)
                T:check(C.fcntl(replacement_fd, C.F_GETFD) >= 0, "closing the old path cannot close the replacement input")
                input:close("native-eof/replacement")
                closeWriter(replacement_writer)
                for _, event in ipairs(events) do UIManager:sendEvent(event) end
                T:eq(input:waitEvent(now, now), nil, "a later empty poll returns normally")
                T:eq(warnings, 1, "EOF is reported once, without a repeated-warning loop")
                logger.warn = original_warn
            end)
            T:waitUntil(function() return reader:getCurrentPage() == 2 end, 5,
                "a native key turns the page after another producer dies")
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return reader:getCurrentPage() == 3 end, 5,
                "normal SDL input still turns pages after the native regression")
        end, debug.traceback)
        logger.warn = original_warn
        native.closeAll()
        for path in pairs(paths) do Input.opened_devices[path] = nil end
        for fd in pairs(writers) do C.close(fd) end
        if not ok then error(err, 0) end
        T:closeBook()
    end,
}
