json = require "resources.functions.lunajson"
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
    session:execute("lua", "list_agents.lua")
    end

    -- Run background announcement/prompt Lua
  
  local recording_filename= queue_data.recording_filename 
  
  if recording_filename ~= nil and recording_filename ~= '' then
    local base_path = "/var/lib/freeswitch/recordings/" .. args.domain .. "/"
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
    local domain_uuid = args.domain_uuid or  session:getVariable("domain_uuid")
    local domain = args.domain
    local modified_ivr_id = args.modified_ivr_id or destination
    local visited = args.visited_ivr or {}
    local MAX_PATH_STEPS = 20
 
    -- Ensure variable tracking table exists ivr_vars default values
    lua_ivr_vars = lua_ivr_vars or {}
   
    session:execute("info")
 
 
    local src_phone = session:getVariable("sip_from_user")
    local dest_phone = session:getVariable("destination_number") or session:getVariable("sip_req_user") or
                           session:getVariable("sip_to_user")
    local call_start_time = session:getVariable("start_stamp")
    local call_uuid = session:getVariable("uuid")
 
    lua_ivr_vars["src_phone"] = src_phone
    lua_ivr_vars["dest_phone"] = dest_phone
    lua_ivr_vars["call_start_time"] = call_start_time
    lua_ivr_vars["call_uuid"] = call_uuid
 
    -- for ivr journey path
    args.ivr_path = args.ivr_path or {}
    counter = counter or {
        count = 0
    }
 
    freeswitch.consoleLog("info", "[handlers.ivr] Routing to IVR: " .. tostring(destination) .." domain_uuid " ..tostring(domain_uuid).. "\n")
 
    -- Fetch IVR config
    -- local query = [[
    --     SELECT
    --         string_agg(DISTINCT op.ivr_menu_option_digits, ',' ORDER BY op.ivr_menu_option_digits) AS option_key,
    --         string_agg(op.ivr_menu_option_action || '_' || op.ivr_menu_option_param, ',' ORDER BY op.ivr_menu_option_digits) AS actions,
    --         m.ivr_menu_greet_long AS greet_long,
    --         m.ivr_menu_invalid_sound AS invalid_sound,
    --         m.ivr_menu_exit_sound AS exit_sound,
    --         1 AS min_digit,
    --         MAX(m.ivr_menu_digit_len) AS max_digit,
    --         MAX(m.ivr_menu_inter_digit_timeout) AS inter_digit_timeout,
    --         MAX(m.ivr_menu_timeout) AS timeout,
    --         MIN(CASE WHEN m.ivr_menu_max_failures > 5 THEN 5 ELSE m.ivr_menu_max_failures END) AS max_failures,
    --         m.ivr_menu_confirm_macro,
    --         m.ivr_menu_name AS name,
    --         MIN(op.preferred_gateway_uuid::text) AS preferred_gateway_uuid,
           
    --         m.ivr_menu_uuid,MIN(d.domain_name::text) AS domain_name,
    --         MIN(m.variables::text) AS parent_variable
    --     FROM v_ivr_menu_options op
    --     JOIN v_ivr_menus m ON m.ivr_menu_uuid = op.ivr_menu_uuid
    --     JOIN v_domains d ON  d.domain_uuid =  m.domain_uuid
    --     WHERE m.ivr_menu_extension = :destination AND m.domain_uuid = :domain_uuid
    --     GROUP BY
    --         m.ivr_menu_greet_long, m.ivr_menu_invalid_sound, m.ivr_menu_exit_sound,
    --         m.ivr_menu_confirm_macro, m.ivr_menu_name,m.ivr_menu_uuid
    -- ]]
    local query = [[
        SELECT
            string_agg(DISTINCT op.ivr_menu_option_digits, ',' ORDER BY op.ivr_menu_option_digits) AS option_key,
            string_agg(op.ivr_menu_option_action || '_' || op.ivr_menu_option_param, ',' ORDER BY op.ivr_menu_option_digits) AS actions,
            m.ivr_menu_greet_long AS greet_long,
            m.ivr_menu_invalid_sound AS invalid_sound,
            r.recording_filename AS recording_filename,
            m.ivr_menu_exit_sound AS exit_sound,
            1 AS min_digit,
            MAX(m.ivr_menu_digit_len) AS max_digit,
            MAX(m.ivr_menu_inter_digit_timeout) AS inter_digit_timeout,
            MAX(m.ivr_menu_timeout) AS timeout,
            MIN(CASE WHEN m.ivr_menu_max_failures > 5 THEN 5 ELSE m.ivr_menu_max_failures END) AS max_failures,
            m.ivr_menu_confirm_macro,
            m.ivr_menu_name AS name,
            MIN(op.preferred_gateway_uuid::text) AS preferred_gateway_uuid,
           
            m.ivr_menu_uuid,MIN(d.domain_name::text) AS domain_name,
            MIN(m.variables::text) AS parent_variable
        FROM v_ivr_menu_options op
        JOIN v_ivr_menus m ON m.ivr_menu_uuid = op.ivr_menu_uuid
        JOIN v_domains d ON  d.domain_uuid =  m.domain_uuid
        LEFT join v_recordings r on r.recording_uuid::text = m.ivr_menu_greet_long
        LEFT join v_recordings r1 on r1.recording_uuid::text = m.ivr_menu_greet_short
        WHERE m.ivr_menu_extension = :destination AND m.domain_uuid = :domain_uuid
        GROUP BY
            m.ivr_menu_greet_long, m.ivr_menu_invalid_sound, m.ivr_menu_exit_sound,
            m.ivr_menu_confirm_macro, m.ivr_menu_name,m.ivr_menu_uuid,r.recording_filename
    ]]
    local ivr_data = {}
    dbh:query(query, {
        destination = destination,
        domain_uuid = domain_uuid
    }, function(row)
        ivr_data = row
    end)
 
    if not ivr_data.option_key or not ivr_data.actions then
        freeswitch.consoleLog("ERR", "[IVR] No options/actions found for IVR " .. tostring(modified_ivr_id) .. "\n")
        return
    end
 
 
    local ivr_menu_uuid = ivr_data.ivr_menu_uuid
    local domain_name = ivr_data.domain_name
    local greet_long_path = ivr_data.recording_filename
 
    freeswitch.consoleLog("INFO", "greet_long_path " .. tostring(greet_long_path) .. "\n")
 
    -- local query_recording  =  [[
    --     SELECT recording_filename, recording_name
    --     FROM v_recordings
    --     WHERE recording_uuid = :greet_long_path
    --       AND domain_uuid = :domain_uuid
    --     LIMIT 1
    -- ]]
 
    -- freeswitch.consoleLog("INFO", "query_recording " .. tostring(query_recording) .. "\n")
 
    -- local ivr_recordings = {}
    -- dbh:query(query_recording, {
    --     greet_long_path = greet_long_path,
    --     domain_uuid = domain_uuid
    -- }, function(row)
    --     ivr_recordings = row
    -- end)
 
    -- if not ivr_recordings.recording_filename or not ivr_recordings.recording_name then
    --     freeswitch.consoleLog("ERR", "[IVR] No recording for IVR " .. tostring(greet_long_path) .. "\n")
    --     return
    -- end
 
    greet_long = greet_long_path
    local base_path = "/var/lib/freeswitch/recordings/" .. domain_name .. "/"
    local greet_long_path =
        (greet_long and greet_long ~= "") and (base_path .. greet_long) or ""
 
    freeswitch.consoleLog("INFO", "greet_long_path " .. tostring(greet_long_path) .. "\n")
 
    local invalid_sound_path = (ivr_data.invalid_sound and ivr_data.invalid_sound ~= "") and
                                   (base_path .. ivr_data.invalid_sound) or ""
    local exit_sound_path =
        (ivr_data.exit_sound and ivr_data.exit_sound ~= "") and (base_path .. ivr_data.exit_sound) or ""
 
    local min_digit = tonumber(ivr_data.min_digit) or 1
    local max_digit = tonumber(ivr_data.max_digit) or 1
    local timeout = tonumber(ivr_data.timeout) or 3000
    local inter_digit_timeout = tonumber(ivr_data.inter_digit_timeout) or 2000
    local max_failures = tonumber(ivr_data.max_failures) or 3
    local parent_variable = ivr_data.parent_variable
   
    local keys = split(ivr_data.option_key, ",")
    local actions = split(ivr_data.actions, ",")
    local preferred_gateway_uuid = ivr_data.preferred_gateway_uuid
 
    local key_action_list = {}
    for i = 1, #keys do
        addLast(key_action_list, keys[i], actions[i])
    end
 
    session:execute("set", "application_state=ivr")
    if ivr_data.name and ivr_data.name ~= "" then
        session:execute("set", ivr_data.name)
    end
 
    session:answer()
 
    local digit_regex = "[" .. table.concat(keys, "") .. "]"
    local input = session:playAndGetDigits(min_digit, max_digit, max_failures, timeout, "#", greet_long_path,
        invalid_sound_path, digit_regex, "input_digits", inter_digit_timeout, nil)
 
 
    local matched_action = search(key_action_list, input)
    local action_type, target = nil, nil
 
    if matched_action then
        action_type, target = matched_action:match("^([^_]+)_(.+)$")
        if not action_type then
            action_type = matched_action
            target = ""
        end
    end
     
    freeswitch.consoleLog("console", "[IVR] Selected input: " .. input .. " action_type: "..tostring(action_type).." \n")
 
    -- Update variable with current input
    if parent_variable and input then
        lua_ivr_vars[parent_variable] = input
    end
    -- Append to IVR journey path
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
 
    -- Upsert journey
    local journey_query = [[
    INSERT INTO call_ivr_journeys (call_uuid, domain_uuid, full_path, variables, updated_at)
    VALUES (:call_uuid, :domain_uuid, :full_path::jsonb, :variables::jsonb, NOW())
    ON CONFLICT (call_uuid)
    DO UPDATE SET
        full_path = EXCLUDED.full_path,
        variables = EXCLUDED.variables,
        updated_at = NOW()
]]
 
    dbh:query(journey_query, {
        call_uuid = session:get_uuid(),
        domain_uuid = domain_uuid,
        full_path = json.encode(args.ivr_path),
        variables = json.encode(lua_ivr_vars or {})
    })
 
    -- Route to action
    if matched_action then
        if action_type == "ivr" then
            incrementCounter(counter)
            if getCurrentCount(counter) < max_failures then
                session:setVariable("parent_ivr_id", modified_ivr_id)
                session:setVariable("ivr_id", target)
                args.modified_ivr_id = target
                args.destination = target
                args.visited_ivr = visited
                return handlers.ivr(args, counter)
            else
                freeswitch.consoleLog("warning", "Max IVR traversals reached\n")
                session:execute("playback", "ivr/ivr-call_failed.wav")
                return true
 
            end
 
        elseif action_type == "backtoivr" then
            local parent = session:getVariable("parent_ivr_id")
            if parent and not visited[parent] then
                visited[parent] = true
                session:setVariable("ivr_id", parent)
                args.modified_ivr_id = parent
                args.destination = parent
                args.visited_ivr = visited
                return handlers.ivr(args, counter)
            else
                session:execute("playback", exit_sound_path)
                return true
            end
 
          
        elseif action_type == "timegroup" then
            timegroup(target, ivr_menu_uuid, input)
               
       
        elseif action_type == "hangup" then
            return session:execute("hangup")
 
        elseif action_type == "lua" then
            -- usr/share/freeswitch/scripts  please paste lua file here to make it executable
            incrementCounter(counter)
            if getCurrentCount(counter) >= max_failures then
                session:execute("playback", exit_sound_path)
                return true
            end
            session:execute("lua", target)
           
            args.modified_ivr_id = modified_ivr_id
            args.destination = destination
            args.visited_ivr = visited
            return handlers.ivr(args, counter)
 
        elseif action_type == "outbound" then
            session:setVariable("preferred_gateway_uuid", preferred_gateway_uuid)
            session:setVariable("destination_number", target)
            handlers.outbound(args)
 
        elseif action_type == "extension" or action_type == "ringgroup" or action_type == "callcenter" or action_type ==
            "conf" then
            session:setVariable("destination_number", target)
            return session:execute("transfer", target .. " XML systech")
 
        elseif action_type == "voicemail" then
            freeswitch.consoleLog("info", " " .. tostring(action_type) .. "\n");
            session:setVariable("destination_number", target)
            voicemail_handler(target, domain_name, domain_uuid)
 
        elseif action_type == "api" then
            --dynamic_variables = json.encode(lua_ivr_vars or {})
            -- freeswitch.consoleLog("info", " lua_ivr_vars" .. (dynamic_variables ) .. "\n");
 
            --api_handler(target, dynamic_variables)
        local encoded_payload = json.encode(lua_ivr_vars or {})
 
        session:setVariable("encoded_payload", encoded_payload)
        session:setVariable("api_id", target)
        session:setVariable("should_hangup", "false")
        session:setVariable("ivr_menu_uuid", ivr_menu_uuid)
        session:execute("lua", "api_handler.lua")
        local api_match_action=session:getVariable("api_match_action")
        if api_match_action and api_match_action =="no_match" then 
        freeswitch.consoleLog("console", "[ivr_handler] out of api function..    ."..tostring(api_match_action))
        local ivr_data = get_ivr_type_and_destination(ivr_menu_uuid, input)
        if not ivr_data then
            return false
        end

        local destination_number = ivr_data.failover_destination_num
        session:execute("transfer", destination_number .. " XML systech") 

        end

        else
            session:execute("playback", exit_sound_path)
        end
    else
        session:execute("playback", exit_sound_path)
    end
 
    return true
end



-- Outbound (others)
function handlers.outbound(args)
    if not check_session() then
        return false
    end

    local domain_uuid = session:getVariable("domain_uuid")
    local dest = session:getVariable("destination_number")
    local preferred_gateway_uuid = session:getVariable("preferred_gateway_uuid")

    freeswitch.consoleLog("info", "[handlers.outbound] Routing outbound to: " .. tostring(dest) .. " | Domain UUID: " ..
        tostring(domain_uuid) .. "\n")

    local gateway_uuid = nil

    if preferred_gateway_uuid and preferred_gateway_uuid ~= "" then
        gateway_uuid = preferred_gateway_uuid
        freeswitch.consoleLog("console",
            "[handlers.outbound] Using preferred gateway UUID from session: " .. gateway_uuid .. "\n")
    else
        -- Query one from DB if no preferred_gateway_uuid
        local sql = [[
            SELECT gateway_uuid
            FROM v_gateways
            WHERE domain_uuid = :domain_uuid
            ORDER BY gateway_uuid  -- Or use a priority field if available
            LIMIT 1
        ]]
        local params = {
            domain_uuid = domain_uuid
        }

        if debug["sql"] then
            local json = require "resources.functions.lunajson"
            freeswitch.consoleLog("notice",
                "[handlers.outbound] SQL: " .. sql .. " | Params: " .. json.encode(params) .. "\n")
        end

        dbh:query(sql, params, function(row)
            gateway_uuid = row.gateway_uuid
        end)

        if not gateway_uuid then
            freeswitch.consoleLog("err", "[handlers.outbound] No gateway_uuid found in DB\n")
            return false
        end
    end

    local bridge_dest =
        "{media_mix_inbound_outbound_codecs=true,ignore_early_media=true}sofia/gateway/" .. gateway_uuid .. "/" .. dest

    freeswitch.consoleLog("info", "[handlers.outbound] Bridging to: " .. bridge_dest .. "\n")

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
    for k, v in pairs(args) do
        log_message = log_message .. string.format("  %s = %s\n", tostring(k), tostring(v))
    end
    freeswitch.consoleLog("info", log_message)

    session:setVariable("verified_did", "true")
    local v_did_id = args.destination;
    freeswitch.consoleLog("info", "[DID ] args.domain_name " .. args.domain_name .." v_did_id "..v_did_id.."\n")

    
    session:setVariable("domain_name", args.domain_name)
     args.domain = args.domain_name;
  
      
     if v_did_id then
        
        did_ivrs(v_did_id);
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

    --------------------------------------------------------------------
    -- Step 1: Fetch time group info & determine if within working hours
    --------------------------------------------------------------------

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

    if debug["sql"] then
        freeswitch.consoleLog("notice", "[timegroup] SQL: " .. sql_timegroup .. " | Params: " .. json.encode(params_timegroup) .. "\n")
    end

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

    --------------------------------------------------------------------
    -- Step 2: Store session variable
    --------------------------------------------------------------------
    if within_working_time == "t" or within_working_time == "true" then
        session:setVariable("timegroup_working", "true")
        freeswitch.consoleLog("info", "[timegroup] Session var set: timegroup_working = true\n")
    else
        session:setVariable("timegroup_working", "false")
        freeswitch.consoleLog("info", "[timegroup] Session var set: timegroup_working = false\n")
    end

    --------------------------------------------------------------------
    -- Step 3: Fetch IVR destination info
    --------------------------------------------------------------------
        local ivr_data = get_ivr_type_and_destination(ivr_menu_uuid, input)
        if not ivr_data then
            return false
        end
    ------------------------------------------------------------------
    -- Step 4: Determine routing based on time group result
    --------------------------------------------------------------------
    local destination_type, destination_number, tm_group_routing

    if within_working_time == "t" or within_working_time == "true" then
        destination_type = ivr_data.working_destination_type
        destination_number = ivr_data.working_destination_num
        tm_group_routing = "working timegroup routing"
    else
        destination_type = ivr_data.failover_destination_type
        destination_number = ivr_data.failover_destination_num
        tm_group_routing = "failover timegroup routing"
    end

    --------------------------------------------------------------------
    -- Step 5: Log and transfer
    --------------------------------------------------------------------
    freeswitch.consoleLog("info", string.format("[timegroup] Routing to: %s - %s\n", tostring(destination_type), tostring(destination_number)))
    freeswitch.consoleLog("info", string.format("[timegroup] Routing type: %s\n", tostring(tm_group_routing)))

    if not (destination_type and destination_number) then
        freeswitch.consoleLog("ERR", "[timegroup] Destination type/number missing.\n")
        return false
    end

    -- Handle routing actions
    if destination_type == "voicemail" then
        session:setVariable("destination_number", destination_number)
        voicemail_handler(destination_number, domain_name, domain_uuid)

    elseif destination_type == "api" then
        local encoded_payload = json.encode(lua_ivr_vars or {})
        session:setVariable("encoded_payload", encoded_payload)
        session:setVariable("api_id", destination_number)
        session:setVariable("should_hangup", "false")
        session:execute("lua", "api_handler.lua")

    elseif destination_type == "hangup" then
        session:execute("hangup")

    elseif destination_type == "playback" then
        local sql_playback = [[
            SELECT recording_filename
            FROM v_recordings
            WHERE recording_uuid = :recording_uuid
            LIMIT 1;
        ]]
        local params_playback = { recording_uuid = destination_number }
        local recording_filename

        dbh:query(sql_playback, params_playback, function(row)
            recording_filename = row.recording_filename
        end)

        if recording_filename and recording_filename ~= '' then
            local base_path = "/var/lib/freeswitch/recordings/" .. domain_name .. "/"
            local play_sound = base_path .. recording_filename
            session:execute("playback", play_sound)
        else
            freeswitch.consoleLog("ERR", "[timegroup] Recording not found for playback.\n")
        end

    elseif destination_type == "lua" then
        session:execute("lua", destination_number)

    elseif destination_type == "backtoivr" then 

      freeswitch.consoleLog("ERR", "[timegroup] backtoivr  not found in Time group.\n")

    else
        session:execute("transfer", destination_number .. " XML systech")
    end

    return true
end



function did_ivrs(id)


    -- Prepare args table
    local args = {}

    -- Single query to join ivrs and v_ivr_menus
    local sql = string.format([[
        SELECT menu.ivr_menu_uuid, menu.ivr_menu_extension, menu.domain_uuid
        FROM v_ivr_menus AS menu
        JOIN ivrs ON ivrs.start_node = menu.ivr_menu_uuid
        WHERE ivrs.id = %d
    ]], id)

    local found = false

    dbh:query(sql, function(row)
        found = true
        args.start_node = row.ivr_menu_uuid
        args.destination = row.ivr_menu_extension
        args.domain_uuid = row.domain_uuid
    end)

    

    if found then
        freeswitch.consoleLog("info", "[did_ivrs] IVR Menu found: " ..
            "UUID = " .. tostring(args.start_node) ..
            ", destination = " .. tostring(args.destination) ..
            ", domain_uuid = " .. tostring(args.domain_uuid) .. "\n")

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

    -- Log start
    freeswitch.consoleLog("INFO",
        "[voicemail] Starting handler for: " .. destination_number .. "@" .. domain_name .. "\n")

    -- Build SQL query
    local sql = string.format([[
        SELECT *
        FROM v_voicemails v
        LEFT JOIN v_voicemail_greetings g ON g.voicemail_id = v.voicemail_id
        WHERE v.voicemail_id = '%s'
          AND v.domain_uuid = '%s';
    ]], destination_number, domain_uuid)

    -- Run SQL
    dbh:query(sql, function(row)
        -- Log results or use them
        freeswitch.consoleLog("INFO", "[voicemail] Found voicemail record for ID: " .. row.voicemail_id .. "\n")
        greeting_id = row.greeting_id;

    end)

    freeswitch.consoleLog("INFO", "[voicemail] greeting_id: " .. greeting_id .. "\n")
    if greeting_id then
        session:setVariable("voicemail_greeting_number", "1")
    end

    -- Continue to voicemail
    local profile = "default"
    -- session:setVariable("voicemail_skip_goodbye", "true")

    session:setVariable("voicemail_terminate_on_silence", "false")
    session:setVariable("domain_name", domain_name)

    local args = string.format("%s %s %s", profile, domain_name, destination_number)
    session:execute("voicemail", args)

    return true
end


return handlers
