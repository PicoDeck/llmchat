-- In-memory stand-in for picocalc.fs (host tests). picocalc.json comes from tests/json.lua.
local M = {}

-- Keeps the device semantics that matter: rename fails when the destination
-- exists; mkdir succeeds when the directory is already there.
-- Failure knobs, set on the returned table by a test:
--   fs.failOpen    fs.open returns nil
--   fs.failWrite   fs.write returns -1
--   fs.shortClose  fs.close keeps one byte less than was written
--   fs.failRename  fs.rename always fails
--   fs.failRead    fs.readFile returns nil, even for a file that exists
function M.fs()
    local files, dirs = {}, {}
    local fs = {}
    function fs.mkdir(p) dirs[p] = true; return true end
    function fs.exists(p) return files[p] ~= nil or dirs[p] == true end
    function fs.readFile(p)
        if fs.failRead then return nil end
        return files[p]
    end
    function fs.size(p)
        if files[p] == nil then return -1 end
        return #files[p]
    end
    function fs.delete(p)
        if files[p] == nil then return false, "delete failed" end
        files[p] = nil
        return true
    end
    function fs.rename(a, b)
        if fs.failRename or files[a] == nil or files[b] ~= nil then return false, "rename failed" end
        files[b], files[a] = files[a], nil
        return true
    end
    function fs.open(p, mode)
        if fs.failOpen or mode ~= "w" then return nil, "cannot open file" end
        return { path = p, parts = {} }
    end
    function fs.write(h, s)
        if fs.failWrite then return -1 end
        h.parts[#h.parts + 1] = s
        return #s
    end
    function fs.close(h)
        local text = table.concat(h.parts)
        if fs.shortClose then text = text:sub(1, -2) end
        files[h.path] = text
    end
    return fs, files
end

return M
