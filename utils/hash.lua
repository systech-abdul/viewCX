
local M = {}

function M.md5(text)
    if not text then return nil end

    -- escape quotes
    local escaped = text:gsub('"', '\\"')

    local handle = io.popen('fs_cli -x "md5 ' .. escaped .. '"')
    if not handle then
        return nil
    end

    local result = handle:read("*a")
    handle:close()

    if result then
        return result:match("([a-f0-9]+)")
    end

    return nil
end

return M
