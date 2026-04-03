-- ==========================================
-- Get or create base path for recordings per domain
-- ==========================================

local M = {}

-- Reusable mkdir
local function ensure_dir(path)
    os.execute("mkdir -p " .. path)
end

-- ==========================================
-- Get base recording path per domain
-- ==========================================
function M.recording_path(domain_name, subpath)
    local base = "/var/lib/freeswitch/recordings/"

    -- Ensure base exists
    ensure_dir(base)

    -- Domain path
    local path = base .. (domain_name or "default") .. "/"

    -- Append subpath (like date or filename)
    if subpath and subpath ~= "" then
        path = path .. subpath
    end

    -- Ensure final path exists
    ensure_dir(path)

    return path
end

return M
