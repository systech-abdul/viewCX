
local M = {}

function M.exists(filename)
    local f = io.open(filename, "r")

    if f then
        local ok, err, code = f:read(0)
        f:close()

        -- code 21 = EISDIR (directory)
        if ok or code ~= 21 then
            return true
        end
    end

    return false
end

return M
