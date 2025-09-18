    json = require "resources.functions.lunajson"
    api = freeswitch.API()

    -- Connect to the database once
    local Database = require "resources.functions.database"
    local dbh = Database.new('system')
    assert(dbh:connected())
    debug["sql"] = false;

  
    
    -- SAFELY parse input args
    local encoded_payload = session:getVariable("encoded_payload") or "{}"
    local api_id = tonumber(session:getVariable("api_id"))
    local should_hangup = session:getVariable("should_hangup") == "true"

    freeswitch.consoleLog("INFO", "[api_handler] api_id: " .. tostring(api_id) .. "\n")

    

  

    -- Step 1: Fetch API settings from DB
    
    local api_settings = nil
    local sql = string.format("SELECT * FROM api_settings WHERE enable = true AND id = %d LIMIT 1", tonumber(api_id))
    dbh:query(sql, function(row)
        api_settings = row
    end)

    if not api_settings then
        freeswitch.consoleLog("ERR", "[api_handler] No enabled API settings found for ID: " .. tostring(api_id) .. "\n")
        return false
    end

    -- Step 2: Parse API settings
    local endpoint = api_settings.endpoint or ""
    local method = string.lower(api_settings.method or "post")
    local headers = json.decode(api_settings.headers or "{}") or {}
    local static_payload = json.decode(api_settings.payload or "{}") or {}
    local key_based_actions = json.decode(api_settings.key_based_actions or "{}") or {}

    local auth_enabled = api_settings.authentication == "true" or api_settings.authentication == true
    local username = api_settings.username
    local password = api_settings.password
    local token = api_settings.token

    local api_name = api_settings.name or "API Call"
    local api_type = api_settings["type"] or "REST"

    -- Step 3: Merge dynamic_payload into static_payload
    local dynamic_data = json.decode(dynamic_payload or "{}") or {}
    static_payload["variables"] = dynamic_data

    local final_payload = static_payload
    local json_payload = json.encode(final_payload)

    -- Step 4: Authentication
    if auth_enabled then
        if token and token ~= "" then
            headers["Authorization"] = "Bearer " .. token
        elseif username and password then
            local b64 = require("resources.functions.base64")
            local auth_str = b64.encode(username .. ":" .. password)
            headers["Authorization"] = "Basic " .. auth_str
        else
            freeswitch.consoleLog("ERR", "[api_handler] Auth enabled but missing credentials/token.\n")
            return false
        end
    end

    -- Step 5: Prepare headers
    local header_str = ""
    for k, v in pairs(headers) do
        header_str = header_str .. k .. ": " .. tostring(v) .. ","
    end
    header_str = header_str:gsub(",$", "")

    -- Step 6: Set curl variables
    session:setVariable("curl_timeout", "10")
    if header_str ~= "" then
        session:setVariable("curl_headers", header_str)
    end
    if method == "post" or method == "put" or method == "patch" then
        session:setVariable("curl_post_data", json_payload)
    end

    -- Step 7: Execute curl
    session:execute("curl", endpoint .. " json " .. method)

    -- Step 8: Capture response
    local status_code = session:getVariable("curl_response_code") or "nil"
    local response_data = session:getVariable("curl_response_data") or "nil"

    -- Step 9: Log request/response
    freeswitch.consoleLog("INFO", "[api_handler] --- API Call: " .. api_name .. " ---\n")
    freeswitch.consoleLog("INFO", "[api_handler] URL: " .. endpoint .. "\n")
    freeswitch.consoleLog("INFO", "[api_handler] Method: " .. method:upper() .. "\n")
    freeswitch.consoleLog("INFO", "[api_handler] Headers: " .. header_str .. "\n")
    freeswitch.consoleLog("INFO", "[api_handler] Payload: " .. json_payload .. "\n")
    freeswitch.consoleLog("INFO", "[api_handler] Status Code: " .. status_code .. "\n")
    freeswitch.consoleLog("INFO", "[api_handler] Response Data: " .. response_data .. "\n")

    -- Step 10: Handle key_based_actions
    local next_action = nil
    local decoded_response = {}

    -- Try decoding the top-level response
    local ok1, top = pcall(json.decode, response_data or "{}")
    if ok1 and type(top) == "table" then
        -- If it has a 'body' field that's a JSON string, decode it too
        if top["body"] and type(top["body"]) == "string" then
            freeswitch.consoleLog("DEBUG", "[api_handler] Detected nested 'body' field in response, decoding...\n")
            local ok2, inner = pcall(json.decode, top["body"])
            if ok2 and type(inner) == "table" then
                decoded_response = inner
                freeswitch.consoleLog("DEBUG", "[api_handler] Decoded body content: " .. json.encode(decoded_response) .. "\n")
            else
                freeswitch.consoleLog("ERR", "[api_handler] Failed to decode 'body' as JSON.\n")
                decoded_response = top
            end
        else
            decoded_response = top
        end
    else
        freeswitch.consoleLog("ERR", "[api_handler] Failed to decode API response as JSON.\n")
        return false
    end

    -- Match key_based_actions intelligently for nested values
    for key, mappings in pairs(key_based_actions) do
        local val = decoded_response[key]
        if val then
            if type(val) == "string" then
                -- Simple string match
                if mappings[val] then
                    next_action = mappings[val]
                    break
                end
            elseif type(val) == "table" then
                -- val is a nested table, check which key is truthy in val and also exists in mappings
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

    -- Execute next action if matched
    if next_action then
        freeswitch.consoleLog("INFO", "[api_handler] Next Action (from key_based_actions): " .. tostring(next_action) .. "\n")

        session:execute("transfer", next_action .. " XML systech")
        
    else
        freeswitch.consoleLog("WARNING", "[api_handler] No matching key_based_action found in response.\n")
    end

    return true
--end
