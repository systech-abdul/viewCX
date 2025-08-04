-- Utility function to safely split a pipe-delimited line with nested `{}` handling
local function safeSplit(line)
    local fields = {}
    local field = ""
    local inside_braces = false

    for i = 1, #line do
        local char = line:sub(i, i)

        if char == "{" then
            inside_braces = true
        elseif char == "}" then
            inside_braces = false
        end

        if char == "|" and not inside_braces then
            table.insert(fields, field)
            field = ""
        else
            field = field .. char
        end
    end

    -- Insert last field
    if field ~= "" then
        table.insert(fields, field)
    end

    return fields
end

-- Get queue name from arguments or use default
local queue_name = argv[1] or "4000@cc.systech.ae"
local timestamp = os.date("%Y-%m-%d %H:%M:%S")

-- Session/caller/UUID metadata
local uuid = session and session:ready() and session:get_uuid() or freeswitch.getGlobalVariable("uuid") or "N/A"
local caller_number = session and session:ready() and (session:getVariable("caller_id_number") or "unknown") or "N/A"

-- Context-aware logging function
local function log(level, message)
    if session and session:ready() then
        session:consoleLog(level, message)
    else
        freeswitch.consoleLog(level, message)
    end
end

-- Log header info
log("info", string.format(" [%s] Caller: %s | UUID: %s\n", timestamp, caller_number, uuid))
log("info", " Fetching agents for queue: " .. queue_name .. "\n")

-- Execute API command
local api = freeswitch.API()
local cmd = "callcenter_config queue list agents " .. queue_name
local ok, output = pcall(function() return api:executeString(cmd) end)

if not ok or not output then
    log("err", " API command failed.\n")
    return
end

-- Clean up output, remove +OK, and split lines
local lines = {}
for line in output:gmatch("[^\r\n]+") do
    if not line:match("^%+OK") then
        table.insert(lines, line)
    end
end

if #lines < 2 then
    log("info", " No agent data found.\n")
    return
end

-- Parse header line to find column indexes
local headers = safeSplit(lines[1])
local col_index = {}
for i, h in ipairs(headers) do
    if h == "contact" then col_index.contact = i end
    if h == "status" then col_index.status = i end
    if h == "state" then col_index.state = i end
end

-- Check required columns exist
if not col_index.contact or not col_index.status or not col_index.state then
    log("err", " Required columns not found in header.\n")
    return
end

-- Log parsed agent info
log("info", " Filtered Agent Info (contact | status | state | extension_uuid):\n")
for i = 2, #lines do
    local fields = safeSplit(lines[i])

    local contact = fields[col_index.contact] or "N/A"
    local status = fields[col_index.status] or "N/A"
    local state = fields[col_index.state] or "N/A"

    -- Extract extension_uuid from inside contact
    local extension_uuid = "N/A"
    local match = contact:match("extension_uuid=([%w%-]+)")
    if match then
        extension_uuid = match
    end

    log("NOTICE", string.format("  Contact: %s | Status: %s | State: %s | extension_uuid: %s\n",
        contact, status, state, extension_uuid))
end

