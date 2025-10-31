-- ==============================================================
--  FreeSWITCH Lua API Handler + Key-based Conditional Routing
-- ==============================================================
--  Description:
--   - Executes an HTTP API call using mod_curl.
--   - Reads per-API configuration from api_settings table.
--   - Supports authentication, dynamic payload, and key-based routing.
--   - Uses `key_based_actions` JSON from DB to decide routing destination.
-- ==============================================================

json = require "resources.functions.lunajson"
local Database = require "resources.functions.database"
local b64 = require "resources.functions.base64"
local api = freeswitch.API()

-- --------------------------------------------------------------
-- Function: find_matching_condition
-- --------------------------------------------------------------
local function find_matching_condition(condition_json, data_json)
    local ok1, conditions = pcall(json.decode, condition_json or "[]")
    local ok2, data = pcall(json.decode, data_json or "{}")

    if not ok1 or not ok2 then
        return json.encode({ action = "error", destination = "invalid_json" })
    end

    -- Normalize single object to array
    if conditions and conditions.key then
        conditions = { conditions }
    end

    for _, cond in ipairs(conditions) do
        local key = cond.key
        local value_in_data = data[key]

        if value_in_data ~= nil then
            if cond.condition == "equal" and tostring(value_in_data) == tostring(cond.string) then
                return json.encode({
                    action = cond.action,
                    destination = cond.destination
                })
            end
        end
    end

    return json.encode({ action = "no_match", destination = "fall_back" })
end

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
local ivr_menu_uuid = tonumber(session:getVariable("ivr_menu_uuid"))
local should_hangup = session:getVariable("should_hangup")

freeswitch.consoleLog("INFO",
    string.format("[api_handler] api_id=%s | should_hangup=%s | encoded_payload=%s\n",
        tostring(api_id), tostring(should_hangup), tostring(encoded_payload))
)

-- --------------------------------------------------------------
-- Step 2: Fetch API settings from DB
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
-- Step 3: Parse settings and authentication
-- --------------------------------------------------------------
local endpoint = api_settings.endpoint or ""
local method = string.lower(api_settings.method or "post")
local headers = json.decode(api_settings.headers or "{}") or {}
local static_payload = json.decode(api_settings.payload or "{}") or {}
local key_based_actions = api_settings.key_based_actions or "[]"  -- comes as JSON text

-- Handle authentication if enabled
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
-- Step 4: Build request payload
-- --------------------------------------------------------------
local dynamic_data = json.decode(encoded_payload or "{}") or {}
static_payload["variables"] = dynamic_data
local json_payload = json.encode(static_payload)

-- --------------------------------------------------------------
-- Step 5: Prepare FreeSWITCH curl vars
-- --------------------------------------------------------------
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
-- Step 6: Build curl command (mod_curl format)
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
session:execute("curl", curl_command)

local status_code = session:getVariable("curl_response_code") or "nil"
local response_data = session:getVariable("curl_response_data") or "nil"

freeswitch.consoleLog("INFO", "\n[api_handler] --- API Response ---\n")
freeswitch.consoleLog("INFO", "[api_handler] Status Code: " .. status_code .. "\n")
freeswitch.consoleLog("INFO", "[api_handler] Response Data: " .. response_data .. "\n")

-- --------------------------------------------------------------
-- Step 8: Decode API response body safely
-- --------------------------------------------------------------
local decoded_response = {}
local ok1, top = pcall(json.decode, response_data or "{}")
if ok1 and type(top) == "table" then
    if top["body"] and type(top["body"]) == "string" then
        local ok2, inner = pcall(json.decode, top["body"])
        decoded_response = (ok2 and inner) or top
    else
        decoded_response = top
    end
else
    freeswitch.consoleLog("ERR", "[api_handler] Could not parse response JSON.\n")
    return false
end

-- --------------------------------------------------------------
-- Step 9: Apply key-based matching (compare against API response)
-- --------------------------------------------------------------
freeswitch.consoleLog("INFO", "[api_handler] Evaluating key_based_actions...\n")

local response_json = json.encode(decoded_response or {})
local match_result_json = find_matching_condition(key_based_actions, response_json)
local match_result = json.decode(match_result_json)

freeswitch.consoleLog("INFO",
    string.format("[api_handler] Match result: action=%s | destination=%s\n",
        tostring(match_result.action), tostring(match_result.destination))
)

-- Set FreeSWITCH channel variables
session:setVariable("api_match_action", tostring(match_result.action))
session:setVariable("api_match_destination", tostring(match_result.destination))

-- Perform routing based on match result
if match_result.action ~= "no_match" then
    session:execute("transfer", match_result.destination .. " XML systech")
    return true
else
    freeswitch.consoleLog("INFO", "[api_handler] No match found, fallback transfer.\n")
    return false
end

-- --------------------------------------------------------------
-- Step 10: Hangup if requested
-- --------------------------------------------------------------
if should_hangup == "true" then
    session:hangup("NORMAL_CLEARING")
end

return true
