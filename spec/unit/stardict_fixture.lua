--[[--
Tiny StarDict dictionaries for unit tests (looked up with the real sdcv).

    local StarDict = require("stardict_fixture")
    StarDict.write(dir .. "/alpha", "alpha", "Alpha", { word = "definition", ... }, { lang = "en-en" })
]]

local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local StarDict = {}

local function be32(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
                       math.floor(n / 256) % 256, n % 256)
end

-- Sort order of StarDict .idx files (stardict_strcmp: ASCII case-insensitive, then bytes).
local function stardictLess(a, b)
    local la, lb = a:lower(), b:lower()
    if la ~= lb then
        return la < lb
    end
    return a < b
end

local function writeFile(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

--- Writes a dictionary (basename.ifo/.idx/.dict) in directory.
-- @tparam table entries word -> definition
-- @tparam table opts sametypesequence ("m"), lang ("en-en"), css (text), fix_lua (Lua source), res (create res/)
function StarDict.write(directory, basename, bookname, entries, opts)
    opts = opts or {}
    util.makePath(directory)
    local words = {}
    for word in pairs(entries) do
        table.insert(words, word)
    end
    table.sort(words, stardictLess)
    local idx, data, offset = {}, {}, 0
    for _, word in ipairs(words) do
        local definition = entries[word]
        table.insert(idx, word .. "\0" .. be32(offset) .. be32(#definition))
        table.insert(data, definition)
        offset = offset + #definition
    end
    idx = table.concat(idx)
    local base = directory .. "/" .. basename
    writeFile(base .. ".idx", idx)
    writeFile(base .. ".dict", table.concat(data))
    local ifo = {
        "StarDict's dict ifo file",
        "version=2.4.2",
        "wordcount=" .. #words,
        "idxfilesize=" .. #idx,
        "sametypesequence=" .. (opts.sametypesequence or "m"),
    }
    if bookname then -- (sdcv and KOReader ignore dictionaries without one)
        table.insert(ifo, "bookname=" .. bookname)
    end
    if opts.lang then
        table.insert(ifo, "lang=" .. opts.lang)
    end
    writeFile(base .. ".ifo", table.concat(ifo, "\n") .. "\n")
    if opts.css then
        writeFile(base .. ".css", opts.css)
    end
    if opts.fix_lua then
        writeFile(base .. ".lua", opts.fix_lua)
    end
    if opts.res then
        lfs.mkdir(directory .. "/res")
    end
    return base .. ".ifo"
end

--- Removes a directory tree (if it exists).
function StarDict.purge(directory)
    if lfs.attributes(directory, "mode") == "directory" then
        require("ffi/util").purgeDir(directory)
    end
end

return StarDict
