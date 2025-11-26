json = require "resources.functions.lunajson"
local caller_handler = require "caller_handler"
local vm = require "custom_voicemail"
local ai_ws = require "ai_ws"
local outbound_routes = require "outbound_routes"

api = freeswitch.API()
local handlers = {}

-- Connect to the database once
local Database = require "resources.functions.database"
local dbh = Database.new('system')
assert(dbh:connected())
debug["sql"] = true;

-- Helper: 
-- session:execute("info") -- Debug info

-- check session readiness upfront
local function check_session()
    if not session or not session:ready() then
        freeswitch.consoleLog("err", "[handlers] Session not ready\n")
        return false
    end
    return true
end

-- Linked list emulation: Add key-value to list
local function addLast(list, key, val)
    table.insert(list, {
        key = key,
        val = val
    })
end

-- Search key in linked list
local function search(list, key)
    for _, node in ipairs(list) do
        if node.key == key then
            return node.val
        end
    end
    return nil
end



-- Helper function to check if a file exists and is a regular file
-- Check if a path exists and is a regular file
function file_exists(filename)
    local f = io.open(filename, "r")
    if f then
        local ok, err, code = f:read(0) -- try reading zero bytes
        f:close()
        if ok or code ~= 21 then -- code 21 = EISDIR (is a directory)
            return true
        else
            return false
        end
    else
        return false
    end
end


-- ==========================================
-- Helper: Get MD5 hash of a string using fs_cli
-- ==========================================
local function md5_hash(text)
    local escaped_text = text:gsub('"', '\\"')
    -- Call fs_cli md5 command
    local handle = io.popen('fs_cli -x "md5 ' .. escaped_text .. '"')
    local result = handle:read("*a")
    handle:close()
    -- Extract only the hash
    result = result:match("([a-f0-9]+)")
    return result
end

-- String split utility
local function split(inputstr, sep)
    local t = {}
    if not inputstr then
        return t
    end
    sep = sep or ","
    for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
        table.insert(t, str)
    end
    return t
end

-- Counter utilities
local counter = {
    count = 0
}
function incrementCounter(c)
    c.count = c.count + 1
end
function getCurrentCount(c)
    return c.count
end



-- ==========================================
-- Get or create base path for recordings per domain
-- ==========================================
local function get_base_path(domain_name, file)
    local base = "/var/lib/freeswitch/recordings/"

    -- Ensure base recordings path exists
    local f = io.open(base, "r")
    if not f then
        os.execute("mkdir -p " .. base)
    else
        f:close()
    end

    -- Append domain
    local path = base .. domain_name .. "/"

    -- Append optional file
    if file and file ~= "" then
        path = path .. file .. ""
    end

    -- Ensure full domain/file path exists
    f = io.open(path, "r")
    if not f then
        os.execute("mkdir -p " .. path)
    else
        f:close()
    end

    return path
end



-- ============================================================
-- 🎤 Generate TTS audio file dynamically with optional params
-- ============================================================

-- Generate TTS file (or fetch from cache)
function generate_tts_file(tts_text, tts_server, tts_voice, tts_lang, tts_vocoder, tts_denoiser, tts_ssml)
    tts_text     = tts_text     or "Hello, this is a test message."
    tts_server   = tts_server   or "http://localhost:5500"
    tts_voice    = tts_voice    or "espeak:en-029"
    tts_lang     = tts_lang     or "en"
    tts_vocoder  = tts_vocoder  or "high"
    tts_denoiser = tts_denoiser or "0.005"
    tts_ssml     = tts_ssml     or "true"

    -- Helper: URL encode
    local function urlencode(str)
        if str then
            str = string.gsub(str, "\n", "%%0A")
            str = string.gsub(str, "([^%w%-_%.%~])", function(c)
                return string.format("%%%02X", string.byte(c))
            end)
        end
        return str
    end

    -- Ensure cache directory exists
    local tts_cache_dir = "/var/lib/freeswitch/tts_cache"
    os.execute("mkdir -p " .. tts_cache_dir)

    -- Use MD5 hash of text for cached filename
    local hash = md5_hash(tts_text)
    local output_file = string.format("%s/tts_%s.wav", tts_cache_dir, hash)

    -- Return cached file if exists
    if file_exists(output_file) then
        freeswitch.consoleLog("INFO", "[TTS] Using cached TTS file: " .. output_file .. "\n")
        return output_file
    end

    -- Build TTS request URL
    local tts_url = string.format(
        "%s/api/tts?voice=%s&lang=%s&vocoder=%s&denoiserStrength=%s&ssml=%s&text=%s&cache=true",
        tts_server,
        urlencode(tts_voice),
        urlencode(tts_lang),
        urlencode(tts_vocoder),
        urlencode(tts_denoiser),
        urlencode(tts_ssml),
        urlencode(tts_text)
    )

    freeswitch.consoleLog("INFO", "[TTS] Fetching new TTS: " .. tts_url .. "\n")

    -- Fetch TTS file
    os.execute(string.format('curl -s -o "%s" "%s"', output_file, tts_url))

    -- Wait for file to appear (max 5 seconds)
    local start = os.time()
    while os.time() - start < 5 do
        if file_exists(output_file) then break end
        freeswitch.msleep(100)
    end

    if not file_exists(output_file) then
        freeswitch.consoleLog("ERR", "[TTS] Failed to generate TTS file: " .. output_file .. "\n")
        return nil
    end

    freeswitch.consoleLog("INFO", "[TTS] TTS file ready: " .. output_file .. "\n")
    return output_file
end


function find_matching_condition(node_id, domain_name, domain_uuid, ivr_menu_uuid)
    if not node_id then
        freeswitch.consoleLog("ERR", "[find_matching_condition] Missing node_id\n")
        return
    end

    -- SQL query to fetch JSON conditions
    local sql = [[
        SELECT key_based_actions
        FROM ivr_condition_node
        WHERE id = :id AND enable = true AND is_active = true
        LIMIT 1;
    ]]
    local params = { id = node_id }

    -- 🪶 DEBUG: Print the SQL for verification
    local debug_sql = string.gsub(sql, ":id", tostring(node_id))
    freeswitch.consoleLog("INFO", "[find_matching_condition] Executing SQL: " .. debug_sql .. "\n")

    local condition_json

    -- Execute DB query
    local status = dbh:query(sql, params, function(row)
        condition_json = row.key_based_actions
    end)

    -- Validate query execution
    if not status then
        freeswitch.consoleLog("ERR", "[find_matching_condition] SQL execution failed for node_id " .. tostring(node_id) .. "\n")
        return nil
    end

    -- Validate fetched data
    if not condition_json or condition_json == "" or condition_json == "null" then
        freeswitch.consoleLog("ERR", "[find_matching_condition] No key_based_actions found for node_id " .. tostring(node_id) .. "\n")
        return nil
    end

    freeswitch.consoleLog("INFO", "[find_matching_condition] Loaded JSON: " .. condition_json .. "\n")
    -- SQL query to fetch variable from journey table
    local sql = [[
        SELECT variables
        FROM call_ivr_journeys
        WHERE call_uuid = :uuid AND domain_uuid = :domain_uuid LIMIT 1;
    ]]

    local call_uuid = session:getVariable("call_uuid")
    local domain_uuid = session:getVariable("domain_uuid")
    local params = { uuid = call_uuid,
                    domain_uuid = domain_uuid
            }

    -- 🪶 DEBUG: Print the SQL for verification
    -- session:execute("info")
    freeswitch.consoleLog("INFO", "session:getVariable(uuid): " .. session:getVariable("call_uuid") .. "\n")
    freeswitch.consoleLog("INFO", "session:getVariable(domain_uuid): " .. session:getVariable("domain_uuid") .. "\n")

    local variable_json = "{}"

    -- Execute query
    dbh:query(sql, params, function(row)
        variable_json = row.variables
    end)

    -- Validate fetched data
    if not variable_json or variable_json == "" or variable_json == "null" then
        freeswitch.consoleLog("ERR", "[find_matching_condition] No key_based_actions found for call_uuid " .. tostring(call_uuid) .. "\n")
        -- return nil
    end

    -- freeswitch.consoleLog("INFO", "[find_matching_condition] Loaded JSON: " .. variable_json .. "\n")
    -- Collect runtime caller/session data as JSON
    



-- Decode JSON
local key_actions = json.decode(condition_json)
local variables = json.decode(variable_json)

-- Function to check condition
local function is_match(value, condition, expected)
    value = tostring(value):lower()
    expected = tostring(expected):lower()

    if condition == "equal" then
        return value == expected
    elseif condition == "contains" then
        return string.find(value, expected, 1, true) ~= nil
    else
        return false
    end
end

-- Main matcher
local function get_matching_action(key_actions, variables)
    for _, rule in ipairs(key_actions) do
        local key = rule.key
        local expected = rule.string
        local condition = rule.condition

        -- 1. Check if key exists
        if variables[key] ~= nil then
            local value = variables[key]

            -- 2. Apply rule
            if is_match(value, condition, expected) then
                return rule  -- return full rule object
            end
        end
    end

    return nil  -- nothing matched
end

-- Execute
local matched = get_matching_action(key_actions, variables)

-- Print result
if matched then
    freeswitch.consoleLog("INFO", "Matched Rule: " .. json.encode(matched) .. "\n")
else
    freeswitch.consoleLog("INFO", "No matching rule found\n")
end

    -- Route using the common handler
    route_action(match_action, match_destination, domain_name, domain_uuid, ivr_menu_uuid)
end





-- Reusable function to handle IVR routing actions
function route_action(action_type, target, domain_name, domain_uuid, ivr_menu_uuid)

    freeswitch.consoleLog("INFO", string.format("[feature_handler][route_action] : action_type=%s | target=%s | domain_name=%s | domain_uuid=%s | ivr_menu_uuid=%s \n", action_type, target, domain_name, domain_uuid, ivr_menu_uuid ))

    if not check_session() then
        return false
    end

    session:answer()
    if action_type == "voicemail" then
        session:setVariable("destination_number", target)
        voicemail_handler(target, domain_name, domain_uuid)

    elseif action_type == "api" then
        local encoded_payload = json.encode(lua_ivr_vars or {})
        session:setVariable("encoded_payload", encoded_payload)
        session:setVariable("api_id", target)
        session:setVariable("should_hangup", "false")
        session:setVariable("ivr_menu_uuid", ivr_menu_uuid)
        session:execute("lua", "api_handler.lua")

        -- Handle API failover if no match
        local api_match_action = session:getVariable("api_match_action")
        
        if api_match_action and api_match_action == "no_match" then
        freeswitch.consoleLog("console", "[route_action] API no_match, retrying IVR\n")
        local last_input = session:getVariable("input_digits") or ""
        local ivr_data = get_ivr_type_and_destination(ivr_menu_uuid, last_input)

            if ivr_data then
                local next_target = ivr_data.failover_destination_num
                local next_type = ivr_data.failover_destination_type
                route_action(next_type, next_target, domain_name, domain_uuid, ivr_menu_uuid)
            end
        end

    elseif action_type == "hangup" then
        session:execute("hangup")

    elseif action_type == "playback" then
        local sql_playback = [[
            SELECT recording_filename
            FROM v_recordings
            WHERE recording_uuid = :recording_uuid
            LIMIT 1;
        ]]
        local params_playback = { recording_uuid = target }
        local recording_filename

        dbh:query(sql_playback, params_playback, function(row)
            recording_filename = row.recording_filename
        end)

        if recording_filename and recording_filename ~= '' then
            local play_sound = get_base_path(domain_name,recording_filename)
            session:execute("playback", play_sound)
        else
            freeswitch.consoleLog("ERR", "[route_action] Recording not found for playback.\n")
        end

    elseif action_type == "lua" then
        ai_ws.run_ai_engine(session)
        return
        -- session:execute("lua", target)


    elseif action_type == "node" or action_type == "condition-node" then
        find_matching_condition(tonumber(target), domain_name, domain_uuid, ivr_menu_uuid)
        return

    elseif action_type == "timegroup" then
        session:setVariable("parent_ivr_id", destination)
        timegroup(target, ivr_menu_uuid, input)

    elseif action_type == "backtoivr" then
         local parent = session:getVariable("parent_ivr_id")
         freeswitch.consoleLog("console", "[route_action] backtoivr  parent_ivr_id  "..tostring(parent))
         session:execute("transfer", parent .. " XML systech")

    else
        session:execute("transfer", target .. " XML systech")
    end

    return true
end


-- Common function to fetch IVR destinations
function get_ivr_type_and_destination(ivr_menu_uuid, ivr_menu_option_digits)
    local sql_ivr = [[
        SELECT
            working_destination_type,
            working_destination_num,
            failover_destination_type,
            failover_destination_num
        FROM v_ivr_menu_options
        WHERE ivr_menu_uuid = :ivr_menu_uuid
          AND ivr_menu_option_digits = :ivr_menu_option_digits
        LIMIT 1;
    ]]

    local params_ivr = {
        ivr_menu_uuid = ivr_menu_uuid,
        ivr_menu_option_digits = ivr_menu_option_digits
    }

    if debug and debug["sql"] then
        freeswitch.consoleLog("notice", "[get_ivr_type_and_destination] SQL: " .. sql_ivr .. " | Params: " .. json.encode(params_ivr) .. "\n")
    end

    local ivr_data = {}
    local found = false

    dbh:query(sql_ivr, params_ivr, function(row)
        ivr_data = row
        found = true
    end)

    if not found then
        freeswitch.consoleLog("ERR", "[get_ivr_type_and_destination] No IVR destination found for UUID: " .. tostring(ivr_menu_uuid) .. " digits: " .. tostring(ivr_menu_option_digits) .. "\n")
        return nil
    end

    return ivr_data
end




-- Extension (1000–3999)
function handlers.extension(args)
    if not check_session() then
        return false
    end

    freeswitch.consoleLog("info", "[handlers.extension] Routing to extension: " .. tostring(args.destination) .. "\n")

    -- Set codec preferences
    local codec_string = session:getVariable("global_codec_prefs")

    session:setVariable("codec_string", codec_string)

    local dest = "{media_mix_inbound_outbound_codecs=true,ignore_early_media=true}user/" .. args.destination .. "@" ..
                     args.domain
    session:execute("bridge", dest)

    return true
end

-- Call Center (4000–4999)

function handlers.callcenter(args)
    if not check_session() then
        return false
    end

    session:answer()
    session:sleep(1000)
     
    if not session:ready() then
        freeswitch.consoleLog("err", "Session not ready for bindDigitAction\n")
        return false
    end

    local uuid = session:get_uuid()
    local queue_extension = args.destination
    local domain_uuid = args.domain_uuid
    local queue = queue_extension .. "@" .. args.domain

    -- Query the database for queue info
    local queue_data = nil
    local sql = [[
        SELECT 
            q.*,
            r.recording_filename
        FROM v_call_center_queues q
        LEFT JOIN v_recordings r 
            ON r.recording_uuid::text = q.queue_announce_sound
        WHERE q.queue_extension = :queue_extension
          AND q.domain_uuid = :domain_uuid
        LIMIT 1
    ]]

    local params = {
        queue_extension = queue_extension,
        domain_uuid = domain_uuid
    }


    dbh:query(sql, params, function(row)
        queue_data = row
    end)

    if not queue_data then
        freeswitch.consoleLog("WARNING", "[CallCenter] Queue not found for extension: " .. queue_extension .. "\n")
        return false
    end

    session:setVariable("queue_name", queue_data.queue_name or "default")
    session:setVariable("queue", queue)

        -- Run background announcement/prompt Lua
    local queue_greeting = queue_data.queue_greeting 
  
    if queue_greeting ~= nil and queue_greeting ~= '' then
        local queue_greeting_sound = queue_greeting 
        freeswitch.consoleLog("console", "[CallCenter] queue_greeting_sound: " .. tostring(queue_greeting_sound) .. "\n")
        session:execute("playback", queue_greeting_sound)
        session:sleep(1000)
    end
    
 
    -- Parse JSON options from queue_flow_json
    local options = {}
    if queue_data.queue_flow_json and queue_data.queue_flow_json ~= '' then
        local success, decoded = pcall(json.decode, queue_data.queue_flow_json)
        if success and decoded and decoded.options then
            options = decoded.options
        else
            freeswitch.consoleLog("WARNING", "[CallCenter] Failed to parse JSON options\n")
        end
    else
        freeswitch.consoleLog("INFO", "[CallCenter] No queue_flow_json or empty string\n")
    end

    -- Dynamically bind digit actions
    


   for key, config in pairs(options) do
    if key and type(config) == "table" and config.action and config.value then
        local action = config.action
        local value = config.value
        local hangup = config.hangup 

        local bind_str = nil

        if action == "transfer" then
            bind_str = string.format("queue_control,%s,exec:transfer,%s XML systech,both,self", key, value)
        elseif action == "callback" then
            bind_str = string.format("queue_control,%s,exec:lua,callback.lua %s", key, value)
        elseif action == "api" then
            --session:setVariable("encoded_payload", {})
            session:setVariable("api_id", value)
            session:setVariable("should_hangup", tostring(hangup))

            bind_str = string.format("queue_control,%s,exec:lua,api_handler.lua %s ",key,value)

            freeswitch.consoleLog("INFO", "[CallCenter] hangup after api calll " .. tostring(hangup) .. "\n")
            

        else
            freeswitch.consoleLog("WARNING", "[CallCenter] Unknown action for key " .. tostring(key) .. ": " .. tostring(action) .. "\n")
        end

        if bind_str then
            freeswitch.consoleLog("INFO", "[CallCenter] Binding digit " .. tostring(key) .. " to action " .. tostring(action) .. " with value " .. tostring(value) .. "\n")
            session:execute("bind_digit_action", bind_str)
        end
    else
        freeswitch.consoleLog("WARNING", "[CallCenter] Invalid or missing config for key: " .. tostring(key) .. "\n")
    end
    end



    -- Prepare variables for announcement script
    local queue_announce_frequency = tonumber(queue_data.queue_announce_frequency) or 5000
    local agent_log = (queue_data.agent_log) 
    
    
   

    if agent_log == "t" then
    -- Run list_agents.lua
    session:execute("lua", "list_agents.lua " .. queue)
    end

    -- Run background announcement/prompt Lua
  
  local recording_filename= queue_data.recording_filename 
  
  if recording_filename ~= nil and recording_filename ~= '' then
    local base_path = get_base_path(args.domain)
    local queue_announce_sound = base_path .. queue_data.recording_filename 

    freeswitch.consoleLog("console", "[CallCenter] queue_announce_sound: " .. tostring(queue_announce_sound) .. "\n")

    local api = freeswitch.API()
    api:execute("luarun", string.format(
        "callcenter-announce-and-prompt.lua %s %s %d %s",
        uuid,
        queue,
        queue_announce_frequency,
        queue_announce_sound
    ))
end


    -- Transfer to queue
    session:execute("callcenter", queue)
   
     -- clear_digit_action  from  queue action
    session:execute("clear_digit_action", "queue_control")
    return true
end



-- Ring Group (6000-6999)
function handlers.ringgroup(args)
    if not check_session() then
        return false
    end

    freeswitch.consoleLog("info", "[handlers.ringgroup] Routing to ring group: " .. tostring(args.destination) .. "\n")

    local destination = args.destination
    local domain_uuid = args.domain_uuid

    if not domain_uuid or not destination then
        freeswitch.consoleLog("err", "[handlers.ringgroup] Missing domain_uuid or destination\n")
        return false
    end

    -- Lookup ring_group_uuid
    local ring_group_uuid = nil
    local sql = [[
        SELECT ring_group_uuid
        FROM v_ring_groups
        WHERE ring_group_extension = :extension
          AND domain_uuid = :domain_uuid
        LIMIT 1
    ]]
    local params = {
        extension = destination,
        domain_uuid = domain_uuid
    }

    -- Optional SQL debug
    if (debug["sql"]) then
        local json = require "resources.functions.lunajson"
        freeswitch.consoleLog("notice",
            "[handlers.ringgroup] SQL: " .. sql .. " | Params: " .. json.encode(params) .. "\n")
    end

    dbh:query(sql, params, function(row)
        ring_group_uuid = row.ring_group_uuid
    end)

    if not ring_group_uuid then
        freeswitch.consoleLog("err", "[handlers.ringgroup] No ring_group_uuid found for extension " ..
            tostring(destination) .. "\n")
        return false
    end

    session:setVariable("ring_group_uuid", ring_group_uuid)
    session:execute("lua", "app.lua ring_groups")

    return true
end

-- IVR handler function for FreeSWITCH (7000–7999)

-- Main IVR Handler
function handlers.ivr(args, counter)
    if not check_session() then
        return false
    end

    local destination = args.destination or session:getVariable("ivr_menu_extension")
    local domain_uuid = args.domain_uuid or session:getVariable("domain_uuid")
    local domain = args.domain
    local modified_ivr_id = args.modified_ivr_id or destination
    local visited = args.visited_ivr or {}
    local MAX_PATH_STEPS = 20

    lua_ivr_vars = lua_ivr_vars or {}

    -- Caller info
    local src_phone = session:getVariable("sip_from_user")
    local dest_phone = session:getVariable("destination_number") or session:getVariable("sip_req_user") or session:getVariable("sip_to_user")
    local call_start_time = session:getVariable("start_stamp")
    local call_uuid = session:getVariable("uuid")
    local language_code = session:getVariable("language_code") or ""

    lua_ivr_vars["src_phone"] = src_phone
    lua_ivr_vars["dest_phone"] = dest_phone
    lua_ivr_vars["call_start_time"] = call_start_time
    lua_ivr_vars["call_uuid"] = call_uuid
    lua_ivr_vars["language"] = language_code

    args.ivr_path = args.ivr_path or {}
    counter = counter or { count = 0 }

    freeswitch.consoleLog("INFO", string.format("[IVR] Routing to %s domain_uuid %s\n", tostring(destination), tostring(domain_uuid)))

        -- === SQL Query (with greet_short, invalid, exit) ===
    local query = [[
        SELECT
            COALESCE(string_agg(DISTINCT op.ivr_menu_option_digits, ',' ORDER BY op.ivr_menu_option_digits), '') AS option_key,
            COALESCE(string_agg(op.ivr_menu_option_action || '_' || op.ivr_menu_option_param, ',' ORDER BY op.ivr_menu_option_digits), '') AS actions,

            -- IVR sound UUIDs
            m.ivr_menu_greet_long AS greet_long,
            m.ivr_menu_greet_short AS greet_short,
            m.ivr_menu_invalid_sound AS invalid_sound,
            m.ivr_menu_exit_sound AS exit_sound,
            m.ivr_menu_no_input_sound AS no_input_sound,  
            m.language AS language,  
            -- Recording filenames
            r_long.recording_filename   AS greet_long_filename,
            r_short.recording_filename  AS greet_short_filename,
            r_invalid.recording_filename AS invalid_sound_filename,
            r_exit.recording_filename   AS exit_sound_filename,
            r_no_input.recording_filename AS no_input_sound_filename, 

            1 AS min_digit,
            MAX(m.ivr_menu_digit_len) AS max_digit,
            MAX(m.ivr_menu_inter_digit_timeout) AS inter_digit_timeout,
            MAX(m.ivr_menu_timeout) AS timeout,
            MIN(CASE WHEN m.ivr_menu_max_failures > 5 THEN 5 ELSE m.ivr_menu_max_failures END) AS max_failures,

            m.ivr_menu_confirm_macro,
            m.ivr_menu_name AS name,
            MIN(op.preferred_gateway_uuid::text) AS preferred_gateway_uuid,
            m.ivr_menu_uuid,
            MIN(d.domain_name::text) AS domain_name,
            MIN(m.variables::text) AS parent_variable,
            m.playback_type,
            m.playback_type_short,
            m.playback_text,
            m.playback_text_short,
            m.ivr_menu_exit_app,
            m.ivr_menu_exit_data

        FROM v_ivr_menus m
        LEFT JOIN v_ivr_menu_options op ON m.ivr_menu_uuid = op.ivr_menu_uuid
        JOIN v_domains d ON d.domain_uuid = m.domain_uuid

        -- Recording joins
        LEFT JOIN v_recordings r_long     ON r_long.recording_uuid::text    = m.ivr_menu_greet_long
        LEFT JOIN v_recordings r_short    ON r_short.recording_uuid::text   = m.ivr_menu_greet_short
        LEFT JOIN v_recordings r_invalid  ON r_invalid.recording_uuid::text = m.ivr_menu_invalid_sound
        LEFT JOIN v_recordings r_exit     ON r_exit.recording_uuid::text    = m.ivr_menu_exit_sound
        LEFT JOIN v_recordings r_no_input ON r_no_input.recording_uuid::text = m.ivr_menu_no_input_sound

        WHERE m.ivr_menu_extension = :destination
          AND m.domain_uuid = :domain_uuid
        AND m.deleted_at IS NULL
        GROUP BY
            m.ivr_menu_greet_long,
            m.ivr_menu_greet_short,
            m.ivr_menu_invalid_sound,
            m.ivr_menu_exit_sound,
            m.ivr_menu_no_input_sound,  
            m.language,
            m.ivr_menu_confirm_macro,
            m.ivr_menu_name,
            m.ivr_menu_uuid,
            r_long.recording_filename,
            r_short.recording_filename,
            r_invalid.recording_filename,
            r_exit.recording_filename,
            r_no_input.recording_filename  
    ]]


    
    local ivr_data = {}
    dbh:query(query, { destination = destination, domain_uuid = domain_uuid }, function(row)
        ivr_data = row
    end)

    if not ivr_data.ivr_menu_uuid then
        freeswitch.consoleLog("ERR", "[IVR] No IVR menu found for " .. tostring(destination) .. "\n")
        return
    end

    local ivr_menu_uuid = ivr_data.ivr_menu_uuid
    local domain_name = ivr_data.domain_name
    local base_path =get_base_path(domain_name)

    --  Build full paths for all sounds
    local greet_long_path = ivr_data.greet_long_filename and (base_path .. ivr_data.greet_long_filename) or ""
    local greet_short_path = ivr_data.greet_short_filename and (base_path .. ivr_data.greet_short_filename) or ""
    local invalid_sound_path = ivr_data.invalid_sound_filename and (base_path .. ivr_data.invalid_sound_filename) or ""
    local exit_sound_path = ivr_data.exit_sound_filename and (base_path .. ivr_data.exit_sound_filename) or ""
    local no_input_sound_path = ivr_data.no_input_sound_filename and (base_path .. ivr_data.no_input_sound_filename) or ""
    local language = ivr_data.language or ""

    local current_language = session:getVariable("language_code") or ""

    freeswitch.consoleLog("INFO", "[IVR] Session language : " .. tostring(current_language) .. " | Menu Language : " .. tostring(language) .. "\n")
    -- if language is not nil/empty, save to session
    if language ~= nil and language ~= "" then
        if current_language ~= language then
            session:setVariable("language_code", language)
            session:setVariable("domain_uuid", domain_uuid)
            freeswitch.consoleLog("INFO", "[IVR] Set session language_code = " .. tostring(language) .. "\n")
            -- If caller_handler.lua returns a module with the function:
            if caller_handler and caller_handler.upsert_caller_profile then
                caller_handler.upsert_caller_profile(params)
            else
                freeswitch.consoleLog("ERR", "[IVR] upsert_caller_profile not found on caller_handler\n")
            end
        end
    end

     freeswitch.consoleLog("console", "[IVR] ivr_data.playback_type ".. ivr_data.playback_type)
    --  Generate dynamic TTS (if playback_type=text)
    if ivr_data.playback_type == "text" and ivr_data.playback_text and ivr_data.playback_text ~= "" then
        local tts_text = ivr_data.playback_text:gsub("%${(.-)}", function(var)
            return lua_ivr_vars[var] or session:getVariable(var) or ""
        end)

        freeswitch.consoleLog("INFO", "[IVR] Generating TTS for text: " .. tts_text .. "\n")

        local tts_file = generate_tts_file(
            tts_text, "http://localhost:5500", "coqui-tts:en_ljspeech", "en", "high", "0.005", "true", "true"
        )

        if tts_file and tts_file ~= "" then
            greet_long_path = tts_file
            freeswitch.consoleLog("INFO", "[IVR] Using generated TTS file: " .. greet_long_path .. "\n")
        else
            freeswitch.consoleLog("ERR", "[IVR] Failed to generate TTS file\n")
        end
    end

     freeswitch.consoleLog("console", "[IVR] ivr_data.playback_type_short ".. ivr_data.playback_type_short)
    --  Generate dynamic TTS (if playback_type_short=text)
    if ivr_data.playback_type_short == "text" and ivr_data.playback_text_short and ivr_data.playback_text_short ~= "" then
        local tts_text = ivr_data.playback_text_short:gsub("%${(.-)}", function(var)
            return lua_ivr_vars[var] or session:getVariable(var) or ""
        end)

        freeswitch.consoleLog("INFO", "[IVR] Generating TTS for text: " .. tts_text .. "\n")

        local tts_file = generate_tts_file(
            tts_text, "http://localhost:5500", "coqui-tts:en_ljspeech", "en", "high", "0.005", "true", "true"
        )

        if tts_file and tts_file ~= "" then
            greet_short_path = tts_file
            freeswitch.consoleLog("INFO", "[IVR] Using generated TTS file: " .. greet_short_path .. "\n")
        else
            freeswitch.consoleLog("ERR", "[IVR] Failed to generate TTS file\n")
        end
    end


   
    
     
    --  Timing and logic setup
    local min_digit = tonumber(ivr_data.min_digit) or 1
    local max_digit = tonumber(ivr_data.max_digit) or 1
    local timeout = tonumber(ivr_data.timeout) or 3000
    local inter_digit_timeout = tonumber(ivr_data.inter_digit_timeout) or 2000
    local max_failures = tonumber(ivr_data.max_failures) or 3
    local parent_variable = ivr_data.parent_variable
    local preferred_gateway_uuid = ivr_data.preferred_gateway_uuid
    local ivr_menu_exit_app = ivr_data.ivr_menu_exit_app
    local ivr_menu_exit_data = ivr_data.ivr_menu_exit_data

    local keys = split(ivr_data.option_key or "", ",")
    local actions = split(ivr_data.actions or "", ",")

    --  Build digit regex safely
    local digit_regex = "[0-9]"
   --[[  if keys and #keys > 0 then
        local safe_keys = {}
        for _, k in ipairs(keys) do
            if k and k ~= "" then
                local clean = k:gsub("[^%w%*#]", "")
                if clean ~= "" then table.insert(safe_keys, clean) end
            end
        end
        digit_regex = (#safe_keys > 0) and "[" .. table.concat(safe_keys, "") .. "]" or "\\d"
    else
        freeswitch.consoleLog("WARNING", "[IVR] No keys found, using fallback regex \\d\n")
        digit_regex = "\\d"
    end

    freeswitch.consoleLog("INFO", "[IVR] Using digit regex: " .. tostring(digit_regex) .. "\n") ]]

    local key_action_list = {}
    for i = 1, #keys do
        addLast(key_action_list, keys[i], actions[i])
    end

    session:answer()
    session:execute("set", "application_state=ivr")

    --  Smart greeting selection (root vs nested IVR)
    local parent_ivr_id = session:getVariable("parent_ivr_id")
   


    
    ------------------------------------------------------
    -- Collect input
    ------------------------------------------------------
    local input, matched_action, action_type, target = nil, nil, nil, nil

    --  Play greeting and collect digits 
   
    local play_greeting = ""
    local greet_counter =0
    while max_failures > 0  and check_session()  do

         if greet_counter ==0 then
            freeswitch.consoleLog("console", "[IVR] welcome greet at greet_counter 0 " .. greet_long_path .. "\n")
             --welcome from greet_long_path only for first time 
            play_greeting = greet_long_path;
        
        
         else
              if greet_short_path ~= "" and file_exists(greet_short_path) then
        play_greeting = greet_short_path
        freeswitch.consoleLog("INFO", "[IVR] Using greet_short: " .. play_greeting .. "\n")
          -- Fallback to greet_long
          elseif greet_long_path ~= "" and file_exists(greet_long_path) then
              play_greeting = greet_long_path
              freeswitch.consoleLog("INFO", "[IVR] Fallback to greet_long: " .. play_greeting .. "\n")
          else
              freeswitch.consoleLog("WARNING", "[IVR] No valid greeting file found\n")
          end
            

        end

            
        
      

        input = session:playAndGetDigits(
            min_digit, max_digit, 1, timeout, "#",
            play_greeting, nil, "[0-9*#]", "input_digits", inter_digit_timeout, nil
        )

        freeswitch.consoleLog("INFO", "[IVR] playAndGetDigits input: " .. tostring(input) .. "\n")


        if not input or input == "" then
            freeswitch.consoleLog("INFO", "[IVR] No input, playing no_input sound\n")
            if no_input_sound_path ~= "" then session:execute("playback", no_input_sound_path) end
            max_failures = max_failures - 1
            greet_counter =greet_counter+1
            goto continue
        end

        matched_action = search(key_action_list, input)
        if matched_action then
            action_type, target = matched_action:match("^([^_]+)_(.+)$")
            action_type = action_type or matched_action
            target = target or ""
        else
            action_type, target = nil, nil
        end

        freeswitch.consoleLog("INFO", string.format("[IVR] Selected input: %s -> action: %s target: %s\n",
            tostring(input), tostring(action_type), tostring(target)))

        if not action_type then
            freeswitch.consoleLog("INFO", "[IVR] Invalid input, playing invalid sound\n")
            if invalid_sound_path ~= "" then session:execute("playback", invalid_sound_path) end
            max_failures = max_failures - 1
            greet_counter =greet_counter+1
            goto continue
        end

        -- Valid action
        break

        ::continue::
    end


    if parent_variable and input then
        lua_ivr_vars[parent_variable] = input
    end

    if #args.ivr_path < MAX_PATH_STEPS then
        table.insert(args.ivr_path, {
            ivr_id = ivr_menu_uuid,
            ivr_menu_extension = modified_ivr_id,
            input = input,
            action = action_type or "unknown",
            target = target or "",
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
        })
    end

    -- Save IVR journey
    dbh:query([[
        INSERT INTO call_ivr_journeys (call_uuid, domain_uuid, full_path, variables, updated_at)
        VALUES (:call_uuid, :domain_uuid, :full_path::jsonb, :variables::jsonb, NOW())
        ON CONFLICT (call_uuid) DO UPDATE
        SET full_path = EXCLUDED.full_path, variables = EXCLUDED.variables, updated_at = NOW()
    ]], {
        call_uuid = session:get_uuid(),
        domain_uuid = domain_uuid,
        full_path = json.encode(args.ivr_path),
        variables = json.encode(lua_ivr_vars or {})
    })

   
    --  Route based on action
            if not matched_action and   check_session() then
                freeswitch.consoleLog(
                    "WARNING",
                    string.format(
                        "[IVR] No action matched. Playing exit sound → Exit App: %s | Exit Data: %s\n",
                        tostring(ivr_data.ivr_menu_exit_app or "nil"),
                        tostring(ivr_data.ivr_menu_exit_data or "nil")
                    )
                )
            
                if exit_sound_path ~= "" then
                    session:execute("playback", exit_sound_path)
                end
            
            --  Perform exit action
            if ivr_data.ivr_menu_exit_app and ivr_data.ivr_menu_exit_data then
                freeswitch.consoleLog(
                    "INFO",
                    string.format("[IVR] Executing exit action: %s %s\n", ivr_data.ivr_menu_exit_app, ivr_data.ivr_menu_exit_data)
                )
                route_action(ivr_data.ivr_menu_exit_app, ivr_data.ivr_menu_exit_data, domain_name, domain_uuid, ivr_menu_uuid)
            end
            return true
        end


    if action_type == "ivr" then
        incrementCounter(counter)
        if getCurrentCount(counter) <= max_failures then
            session:setVariable("parent_ivr_id", modified_ivr_id)
            args.destination = target
            return handlers.ivr(args, counter)
        else
            freeswitch.consoleLog("WARNING", "Max IVR traversals reached\n")
            session:execute("playback", "ivr/ivr-call_failed.wav")
            return true
        end

    elseif action_type == "callcenter" then
        local parent = session:getVariable("parent_ivr_id")
        if parent and not visited[parent] then
            visited[parent] = true
            args.destination = parent

            args.destination = target
            args.domain_uuid = domain_uuid
            args.domain = domain_name

            freeswitch.consoleLog("INFO ", "destination " .. destination .. "\n")
            freeswitch.consoleLog("INFO ", "domain_uuid " .. domain_uuid .. "\n")
            freeswitch.consoleLog("INFO ", "domain " .. domain_name .. "\n")

            return handlers.callcenter(args)
        else
            session:execute("playback", exit_sound_path)
        end
    elseif action_type == "backtoivr" then
        local parent = session:getVariable("parent_ivr_id")
        if parent and not visited[parent] then
            visited[parent] = true
            args.destination = parent
            return handlers.ivr(args, counter)
        else
            session:execute("playback", exit_sound_path)
        end

    elseif action_type == "timegroup" then
        session:setVariable("parent_ivr_id", destination)
        timegroup(target, ivr_menu_uuid, input)

    elseif action_type == "node" then
        find_matching_condition(tonumber(target), domain, domain_uuid, ivr_menu_uuid)

    elseif action_type == "outbound" then
        session:setVariable("preferred_gateway_uuid", preferred_gateway_uuid)
        session:setVariable("destination_number", target)
        handlers.outbound(args)

    elseif action_type == "lua" then
        session:execute("lua", target)
        return handlers.ivr(args, counter)


    elseif action_type == "aiagent" then
        
            ------------------------------------------------------------------
            -- SQL Query
            ------------------------------------------------------------------
            local sql = [[
                SELECT *
                FROM ai_agent
                WHERE domain_uuid = :domain_uuid
                AND id = :id
                LIMIT 1
            ]]
        
            local params = {
                domain_uuid = domain_uuid,
                id = target
            }
        
            if debug["sql"] then
                local json = require "resources.functions.lunajson"
                freeswitch.consoleLog("notice",
                    "[handlers.aiagent] SQL: " .. sql ..
                    " | Params: " .. json.encode(params) .. "\n")
            end
        
            local ai = {}
            local found = false
        
            dbh:query(sql, params, function(row)
                found = true
                ai.tenant_id     = row.tenant_id
                ai.process_id      = row.process_id
            
            end)
        
            if not found then
                freeswitch.consoleLog("err",
                    "[ivr.aiagent] No AI agent found: id=" .. tostring(target) ..
                    " domain=" .. tostring(domain_uuid) .. "\n")
                return
            end
        
        
            session:setVariable("domain_name", domain_name)
            if ai.tenant_id     then session:setVariable("tenant_id",    ai.tenant_id) end
            if ai.process_id     then session:setVariable("process_id",     ai.process_id) end
        
            freeswitch.consoleLog("info","[ivr.aiagent] Loaded AI Agent ID " .. target .."\n")
        
        
            ai_ws.run_ai_engine(session)
            return
        
        
    elseif action_type == "extension" or action_type == "ringgroup" or action_type == "callcenter" or action_type == "conf" then
        session:execute("transfer", target .. " XML systech")

    elseif action_type == "voicemail" then
        voicemail_handler(target, domain_name, domain_uuid)

    elseif action_type == "api" then
        session:setVariable("encoded_payload", json.encode(lua_ivr_vars or {}))
        session:setVariable("api_id", target)
        session:setVariable("ivr_menu_uuid", ivr_menu_uuid)
        session:execute("lua", "api_handler.lua")

    else
        session:execute("playback", exit_sound_path)
    end

    return true
end





-- Outbound (others)
-- Outbound handler
function handlers.outbound(args)
    if not check_session() then
        return false
    end

    session:setVariable("direction", "outbound")
    session:setVariable("call_direction", "outbound")

    local domain_uuid = session:getVariable("domain_uuid")
    local dest = session:getVariable("destination_number")
    local preferred_gateway_uuid = session:getVariable("preferred_gateway_uuid")

    freeswitch.consoleLog("info",
        string.format("[handlers.outbound] Routing outbound to: %s | Domain UUID: %s\n",
        tostring(dest), tostring(domain_uuid)))

    local gateways = {}
    local dial_number = dest
    local route_info = nil

    if preferred_gateway_uuid and preferred_gateway_uuid ~= "" then
        table.insert(gateways, preferred_gateway_uuid)
        freeswitch.consoleLog("info", "[handlers.outbound] Using preferred gateway UUID: " .. preferred_gateway_uuid .. "\n")
    else
        route_info = outbound_routes.dialoutmatchForoutbound_routes(dest, domain_uuid)
        if route_info then
            dial_number = route_info.dial_number

            -- Set DID if available
            if route_info.did then
                freeswitch.consoleLog("info", "[handlers.outbound] Using DID: " .. route_info.did .. "\n")
                session:setVariable("caller_id_number", route_info.did)
            end

            local route = route_info.route
            table.insert(gateways, route.gateway_uuid)
            if route.alternate1_gateway_uuid and route.alternate1_gateway_uuid ~= "" then
                table.insert(gateways, route.alternate1_gateway_uuid)
            end
            if route.alternate2_gateway_uuid and route.alternate2_gateway_uuid ~= "" then
                table.insert(gateways, route.alternate2_gateway_uuid)
            end

            freeswitch.consoleLog("info",
                string.format("[handlers.outbound] Matched route: %s | Gateways: %s | Dial number: %s\n",
                route.name or route.id, table.concat(gateways, ","), dial_number))
        else
            -- fallback
            local sql = [[
                SELECT gateway_uuid
                FROM v_gateways
                WHERE domain_uuid = :domain_uuid
                ORDER BY gateway_uuid
                LIMIT 1
            ]]
            local params = { domain_uuid = domain_uuid }
            dbh:query(sql, params, function(row)
                if row.gateway_uuid then
                    table.insert(gateways, row.gateway_uuid)
                    freeswitch.consoleLog("info", "[handlers.outbound] Fallback gateway: " .. row.gateway_uuid .. "\n")
                end
            end)

            if #gateways == 0 then
                freeswitch.consoleLog("err", "[handlers.outbound] No gateways found in DB\n")
                session:execute("playback", "ivr/ivr-no_route_destination.wav")
                return false
            end
        end
    end

    -- Bridge via multiple gateways in one call   
    local bridge_dest_list = {}
    for _, gw in ipairs(gateways) do
        table.insert(bridge_dest_list, string.format("sofia/gateway/%s/%s", gw, dial_number))
    end
    --Implementing Failover 
    local bridge_dest = table.concat(bridge_dest_list, "|")
    freeswitch.consoleLog("info", "[handlers.outbound] Attempting bridge to: " .. bridge_dest .. "\n")

    session:execute("bridge", bridge_dest)
   
  

    return true
end





-- DID-based call dispatcher
function handlers.handle_did_call(args)
    if not check_session() then
        return false
    end


    --session:execute("info");
    local log_message = "[handlers.handle_did_call] Routing args:\n"
   --[[  for k, v in pairs(args) do
        log_message = log_message .. string.format("  %s = %s\n", tostring(k), tostring(v))
    end
    freeswitch.consoleLog("info", log_message) ]]

    session:setVariable("verified_did", "true")
    

    local did_type        = session:getVariable("did_type") or session:getVariable("destination_type") or ""
    local did_destination = session:getVariable("did_destination") or ""
    local domain_name     = session:getVariable("domain_name") or ""
    local domain_uuid     = session:getVariable("domain_uuid") or ""
    args.domain = domain_name;
   
    if not did_type or did_type == "" then
        freeswitch.consoleLog("WARNING", "[routing] No did_type \n")
        return
    end

    if not did_destination or did_destination == "" then
        freeswitch.consoleLog("WARNING", "[routing] No did_destination \n")
        return
    end


    freeswitch.consoleLog(
        "info",
        string.format(
            "[DID] domain_name=%s, did_type=%s, did_destination=%s\n",
            domain_name, did_type, did_destination
        )
     )
  
      
     if did_type and did_type=='ivr' then
        
        did_ivrs(did_destination);
     
    else  
           -- Route the action using reusable function
    route_action(did_type, did_destination, domain_name, domain_uuid, nil)

    end
    return true
end


function timegroup(time_grp_uuid, ivr_menu_uuid, input)
    if not check_session() then
        return false
    end

    local domain_name = session:getVariable("domain_name")
    local domain_uuid = session:getVariable("domain_uuid")

    freeswitch.consoleLog("info", "[timegroup] Processing time group: " .. tostring(time_grp_uuid) .. "\n")

    -- Fetch time group info & determine if within working hours
    local sql_timegroup = [[
        SELECT 
            *,
            trim(to_char(now() AT TIME ZONE time_zone, 'Day')) AS current_day_trimmed,
            to_char(now() AT TIME ZONE time_zone, 'HH24:MI:SS') AS current_time,
            trim(to_char(now() AT TIME ZONE time_zone, 'Day')) = ANY (
                string_to_array(trim(both '{}' from working_days), ',')
            ) AS is_today_working,
            (to_char(now() AT TIME ZONE time_zone, 'HH24:MI:SS'))::time BETWEEN working_time_start AND working_time_end AS is_time_in_range,
            (
                trim(to_char(now() AT TIME ZONE time_zone, 'Day')) = ANY (
                    string_to_array(trim(both '{}' from working_days), ',')
                )
                AND (to_char(now() AT TIME ZONE time_zone, 'HH24:MI:SS'))::time 
                    BETWEEN working_time_start AND working_time_end
            ) AS is_within_working_time
        FROM time_group
        WHERE uuid = :time_grp_uuid
        LIMIT 1;
    ]]

    local params_timegroup = { time_grp_uuid = time_grp_uuid }

    local within_working_time = "false"
    local found = false

    dbh:query(sql_timegroup, params_timegroup, function(row)
        found = true
        within_working_time = tostring(row.is_within_working_time)
        freeswitch.consoleLog("info", "[timegroup] Timezone: " .. row.time_zone .. "\n")
        freeswitch.consoleLog("info", "[timegroup] Current Day: " .. row.current_day_trimmed .. ", Time: " .. row.current_time .. "\n")
        freeswitch.consoleLog("info", "[timegroup] Within working time: " .. within_working_time .. "\n")
    end)

    if not found then
        freeswitch.consoleLog("ERR", "[timegroup] No time group found for UUID: " .. tostring(time_grp_uuid) .. "\n")
        session:setVariable("timegroup_working", "false")
        return false
    end

    -- Store session variable
    local is_working = within_working_time == "t" or within_working_time == "true"
    session:setVariable("timegroup_working", is_working and "true" or "false")

    -- Fetch IVR destination info
    local ivr_data = get_ivr_type_and_destination(ivr_menu_uuid, input)
    if not ivr_data then
        return false
    end

    -- Determine routing based on time group result
    local destination_type, destination_number, routing_note
    if is_working then
        destination_type = ivr_data.working_destination_type
        destination_number = ivr_data.working_destination_num
        routing_note = "working timegroup routing"
    else
        destination_type = ivr_data.failover_destination_type
        destination_number = ivr_data.failover_destination_num
        routing_note = "failover timegroup routing"
    end

    freeswitch.consoleLog("info", string.format("[timegroup] Routing to: %s - %s\n", tostring(destination_type), tostring(destination_number)))
    freeswitch.consoleLog("info", string.format("[timegroup] Routing type: %s\n", routing_note))

    if not (destination_type and destination_number) then
        freeswitch.consoleLog("ERR", "[timegroup] Destination type/number missing.\n")
        return false
    end

    -- Route the action using reusable function
    route_action(destination_type, destination_number, domain_name, domain_uuid, ivr_menu_uuid)

    return true
end



function did_ivrs(id)


    -- Prepare args table
    local args = {}

    -- Single query to join ivrs and v_ivr_menus
    local sql = string.format([[
        SELECT menu.ivr_menu_uuid, menu.ivr_menu_name, menu.ivr_menu_extension, menu.domain_uuid
        FROM v_ivr_menus AS menu
        JOIN ivrs ON ivrs.start_node = menu.ivr_menu_uuid
        WHERE ivrs.id = %d
    ]], id)

    local found = false

    dbh:query(sql, function(row)
        found = true
        args.start_node = row.ivr_menu_uuid
        args.menu_name = row.ivr_menu_name
        args.destination = row.ivr_menu_extension
        args.domain_uuid = row.domain_uuid
    end)

    

    if found then
        freeswitch.consoleLog("info", "[did_ivrs] IVR Menu found: " .. "UUID = " .. tostring(args.start_node) .. ", menu_name = " .. tostring(args.menu_name) .. ", destination = " .. tostring(args.destination) .. ", domain_uuid = " .. tostring(args.domain_uuid) .. "\n")

        -- Call IVR handler with args  
        
        
        session:setVariable("ivr_menu_extension", tostring(args.destination) )
        handlers.ivr(args)
    else
        freeswitch.consoleLog("err", "[did_ivrs] No IVR Menu found for ivrs.id = " .. tostring(id) .. "\n")
        session:execute("playback", "ivr/ivr-not_available.wav")
    end

    return true
end


function voicemail_handler(destination_number, domain_name, domain_uuid)
    if not session:ready() then
        freeswitch.consoleLog("ERR", "[voicemail] Session not ready\n")
        return false
    end

    freeswitch.consoleLog("INFO",
        "[voicemail] Starting handler for: " .. destination_number .. "@" .. domain_name .. "\n")

    local greeting_file = nil
    local thanks_file = nil

    -- Build SQL query
    local sql = string.format([[ 
        SELECT 
            v.voicemail_id, v.playback_terminator, v.beep_tone,
            r1.recording_filename AS greeting_filename,
            r2.recording_filename AS thanks_filename
        FROM v_voicemails v
        LEFT JOIN v_recordings r1 ON v.greeting_id = r1.recording_uuid
        LEFT JOIN v_recordings r2 ON v.thanks_greet = r2.recording_uuid
        WHERE v.voicemail_id = '%s'
          AND v.domain_uuid = '%s';
    ]], destination_number, domain_uuid)

    -- Run SQL
    dbh:query(sql, function(row)
        freeswitch.consoleLog("INFO", "[voicemail] Found voicemail record for ID: " .. row.voicemail_id .. "\n")
        greeting_file = row.greeting_filename
        thanks_file = row.thanks_filename
        playback_terminator = row.playback_terminator
        beep_tone = row.beep_tone
    end)

    -- Base path for recordings
    local base_path =get_base_path(domain_name)

    -- Build full paths for files
    local greeting_path = greeting_file and (base_path .. greeting_file) or ""
    local thanks_path = thanks_file and (base_path .. thanks_file) or ""

    -- Play greeting first if exists
    if greeting_path ~= "" then
        -- freeswitch.consoleLog("INFO", "[voicemail] Playing greeting: " .. greeting_path .. "\n")
        -- session:execute("playback", greeting_path)
    end

    -- Continue to voicemail
    local profile = "default"
    session:setVariable("playback_terminators", "")
    session:setVariable("skip_greeting", "true")
    session:setVariable("skip_instructions", "true")
    session:setVariable("voicemail_terminate_on_silence", "false")
    session:setVariable("domain_name", domain_name)
    session:setVariable("voicemail_id", destination_number)
    local record_base_dir = string.format("/var/lib/freeswitch/recordings/%s", domain_name)
    record_base_dir = record_base_dir .. "/voicemails"
    local args = string.format("%s %s %s", profile, domain_name, destination_number)
    -- session:execute("voicemail", args)

    vm.record_voicemail(session, {
        -- all optional: override defaults only if you need to
        beep_tone        = beep_tone,
        playback_terminator = playback_terminator,
        record_base_dir   = record_base_dir,
        welcome_file      = greeting_path,
        thanks_file       = thanks_path,
        max_len_seconds   = 600,
        silence_threshold = 0,
    })

    -- Play thank-you message after recording, if exists
    if thanks_path ~= "" then
        -- freeswitch.consoleLog("INFO", "[voicemail] Playing thanks message: " .. thanks_path .. "\n")
        -- session:execute("playback", thanks_path)
    end

    return true
end




return handlers
