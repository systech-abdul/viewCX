-- ==============================================================
--  FreeSWITCH Lua API Handler (Refined per mod_curl documentation)
-- ==============================================================
--  Description:
--   Executes REST API calls via FreeSWITCH’s native `mod_curl`.
--   Supports DB-driven endpoint configuration, JSON payloads,
--   Basic/Bearer auth, and key-based response routing.
-- ==============================================================

json = require "resources.functions.lunajson"
local Database = require "resources.functions.database"
local b64 = require "resources.functions.base64"
local api = freeswitch.API()

-- --------------------------------------------------------------
-- Step 0: Connect to database
-- --------------------------------------------------------------
local dbh = Database.new('system')
assert(dbh:connected(), "[api_handler] DB connection failed")

-- --------------------------------------------------------------
-- Step 1: Get runtime variables
-- --------------------------------------------------------------
local encoded_payload = session:getVariable("encoded_payload") or "{}"
local api_id = tonumber(session:getVariable("api_id"))
local should_hangup = session:getVariable("should_hangup")

freeswitch.consoleLog("INFO",
    string.format("[api_handler] api_id=%s | should_hangup=%s | encoded_payload=%s\n",
        tostring(api_id), tostring(should_hangup), tostring(encoded_payload))
)

-- --------------------------------------------------------------
-- Step 2: Fetch API settings
-- --------------------------------------------------------------
local sql = string.format(
    "SELECT * FROM api_settings WHERE enable = true AND id = %d LIMIT 1",
    tonumber(api_id or 0)
)
local api_settings = nil
dbh:query(sql, function(row) api_settings = row end)

if not api_settings then
    freeswitch.consoleLog("ERR",
        "[api_handler] No enabled API found for ID: " .. tostring(api_id) .. "\n")
    return false
end

-- --------------------------------------------------------------
-- Step 3: Parse settings and auth
-- --------------------------------------------------------------
local endpoint = api_settings.endpoint or ""
local method = string.lower(api_settings.method or "post")
local headers = json.decode(api_settings.headers or "{}") or {}
local static_payload = json.decode(api_settings.payload or "{}") or {}
local key_based_actions = json.decode(api_settings.key_based_actions or "{}") or {}

-- Handle authentication
if api_settings.authentication == "true" or api_settings.authentication == true then
    if api_settings.token and api_settings.token ~= "" then
        headers["Authorization"] = "Bearer " .. api_settings.token
    elseif api_settings.username and api_settings.password then
        local auth_str = b64.encode(api_settings.username .. ":" .. api_settings.password)
        headers["Authorization"] = "Basic " .. auth_str
    else
        freeswitch.consoleLog("ERR", "[api_handler] Auth enabled but missing credentials.\n")
    end
end

-- --------------------------------------------------------------
-- Step 4: Build final payload
-- --------------------------------------------------------------
local dynamic_data = json.decode(encoded_payload or "{}") or {}
static_payload["variables"] = dynamic_data
local json_payload = json.encode(static_payload)

-- --------------------------------------------------------------
-- Step 5: Prepare FreeSWITCH curl vars
-- --------------------------------------------------------------
-- According to mod_curl docs:
--   curl <url> [headers|json] [get|head|post [data]]
-- Example for JSON POST:
--   curl https://example.com/jsonapi json post {"foo":"bar"}

-- Build header string (semicolon-separated per doc)
local header_str = ""
for k, v in pairs(headers) do
    header_str = header_str .. k .. ": " .. tostring(v) .. ";"
end
header_str = header_str:gsub(";$", "")

if header_str ~= "" then
    session:setVariable("curl_headers", header_str)
end

session:setVariable("curl_timeout", "10")
session:setVariable("curl_content_type", "application/json")

-- --------------------------------------------------------------
-- Step 6: Build curl command (per documentation)
-- --------------------------------------------------------------
local curl_command = string.format("%s json %s", endpoint, method)
if method == "post" or method == "put" or method == "patch" then
    curl_command = string.format("%s %s", curl_command, json_payload)
else
    curl_command = curl_command .. " nopost"
end

freeswitch.consoleLog("INFO",
    string.format("[api_handler] Executing curl command:\n%s\n", curl_command)
)

-- --------------------------------------------------------------
-- Step 7: Execute and capture response
-- --------------------------------------------------------------
-- mod_curl sets:
--   curl_response_code
--   curl_response_data
-- so we can read them after executing
session:execute("curl", curl_command)

local status_code = session:getVariable("curl_response_code") or "nil"
local response_data = session:getVariable("curl_response_data") or "nil"

freeswitch.consoleLog("INFO", "\n[api_handler] --- API Response ---\n")
freeswitch.consoleLog("INFO", "[api_handler] URL: " .. endpoint .. "\n")
freeswitch.consoleLog("INFO", "[api_handler] Method: " .. method:upper() .. "\n")
freeswitch.consoleLog("INFO", "[api_handler] Headers: " .. header_str .. "\n")
freeswitch.consoleLog("INFO", "[api_handler] Payload: " .. json_payload .. "\n")
freeswitch.consoleLog("INFO", "[api_handler] Status Code: " .. status_code .. "\n")
freeswitch.consoleLog("INFO", "[api_handler] Response Data: " .. response_data .. "\n")

-- --------------------------------------------------------------
-- Step 8: Decode response and handle routing logic
-- --------------------------------------------------------------
local decoded_response = {}
local ok1, top = pcall(json.decode, response_data or "{}")
if ok1 and type(top) == "table" then
    if top["body"] and type(top["body"]) == "string" then
        local ok2, inner = pcall(json.decode, top["body"])
        if ok2 and type(inner) == "table" then
            decoded_response = inner
        else
            decoded_response = top
        end
    else
        decoded_response = top
    end
else
    freeswitch.consoleLog("ERR", "[api_handler] Could not parse response JSON.\n")
    return false
end

-- --------------------------------------------------------------
-- Step 9: Match key-based actions
-- --------------------------------------------------------------
local next_action = nil
for key, mappings in pairs(key_based_actions) do
    local val = decoded_response[key]
    if val then
        if type(val) == "string" and mappings[val] then
            next_action = mappings[val]
            break
        elseif type(val) == "table" then
            for subkey, subval in pairs(val) do
                if subval and mappings[subkey] then
                    next_action = mappings[subkey]
                    break
                end
            end
            if next_action then break end
        end
    end
end

if next_action then
    freeswitch.consoleLog("INFO",
        "[api_handler] Next Action (from key_based_actions): " .. tostring(next_action) .. "\n")
    session:execute("transfer", next_action .. " XML systech")
else
    freeswitch.consoleLog("INFO", "[api_handler] No matching key_based_action found.\n")
end

-- --------------------------------------------------------------
-- Step 10: Hangup if requested
-- --------------------------------------------------------------
if should_hangup == "true" then
    session:hangup("NORMAL_CLEARING")
end

return true
