json = require "resources.functions.lunajson"
local caller_handler = require "utils.caller_handler"
local base64 = require "resources.functions.base64"

local extension_routes = require "routes.extension_routes"

local tts = require "features.tts"
local ai_ws = require "features.ai_ws"
local voicemail = require "features.voicemail"
local outbound_routes_handler = require "routes.outbound_routes"
local timegroup = require "features.timegroup"
local file = require "utils.file"
local path_util  = require "utils.path"




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
    
    session:setVariable("information_node", "ivr_hangup");
    --session:execute("export", "information_node=ivr_hangup")

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
    if type(counter) ~= "table" then
        counter = { count = 0 }
    end

    freeswitch.consoleLog("INFO", string.format("[IVR] Routing to %s domain_uuid %s\n", tostring(destination), tostring(domain_uuid)))

        -- === SQL Query (with greet_short, invalid, exit) ===
    local query = [[
    SELECT
        COALESCE(string_agg(DISTINCT op.ivr_menu_option_digits, ',' ORDER BY op.ivr_menu_option_digits), '') AS option_key,
        COALESCE(string_agg(op.ivr_menu_option_action || '_' || op.ivr_menu_option_param, ',' ORDER BY op.ivr_menu_option_digits), '') AS actions,

        m.ivr_menu_greet_long AS greet_long,
        m.ivr_menu_greet_short AS greet_short,
        m.ivr_menu_invalid_sound AS invalid_sound,
        m.ivr_menu_exit_sound AS exit_sound,
        m.ivr_menu_no_input_sound AS no_input_sound,
        m.language AS language,

        r_long.recording_filename AS greet_long_filename,
        r_short.recording_filename AS greet_short_filename,
        r_invalid.recording_filename AS invalid_sound_filename,
        r_exit.recording_filename AS exit_sound_filename,
        r_no_input.recording_filename AS no_input_sound_filename,

        1 AS min_digit,
        MAX(m.ivr_menu_digit_len) AS max_digit,
        MAX(m.ivr_menu_inter_digit_timeout) AS inter_digit_timeout,
        MAX(m.ivr_menu_timeout) AS timeout,

        MIN(CASE WHEN m.ivr_menu_max_failures > 5 THEN 5 ELSE m.ivr_menu_max_failures END) AS max_failures,
        MIN(CASE WHEN m.ivr_menu_max_timeouts > 5 THEN 5 ELSE m.ivr_menu_max_timeouts END) AS max_no_input,

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
        m.ivr_menu_exit_data,
        m.information_node

    FROM v_ivr_menus m
    LEFT JOIN v_ivr_menu_options op ON m.ivr_menu_uuid = op.ivr_menu_uuid
    JOIN v_domains d ON d.domain_uuid = m.domain_uuid

    LEFT JOIN v_recordings r_long ON r_long.recording_uuid::text = m.ivr_menu_greet_long
    LEFT JOIN v_recordings r_short ON r_short.recording_uuid::text = m.ivr_menu_greet_short
    LEFT JOIN v_recordings r_invalid ON r_invalid.recording_uuid::text = m.ivr_menu_invalid_sound
    LEFT JOIN v_recordings r_exit ON r_exit.recording_uuid::text = m.ivr_menu_exit_sound
    LEFT JOIN v_recordings r_no_input ON r_no_input.recording_uuid::text = m.ivr_menu_no_input_sound

        WHERE (
        m.ivr_menu_uuid::text = :destination
     OR m.ivr_menu_extension::text  = :destination
      )
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
        r_no_input.recording_filename,
        m.playback_type,
        m.playback_type_short,
        m.playback_text,
        m.playback_text_short,
        m.ivr_menu_exit_app,
        m.ivr_menu_exit_data,
        m.information_node
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
    local base_path =path_util.recording_path(domain_name)

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

      
        local tts_file = tts.generate(session, dbh, tts_text, domain_uuid)

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

        
        local tts_file = tts.generate(session, dbh, tts_text, domain_uuid)

        if tts_file and tts_file ~= "" then
            greet_short_path = tts_file
            freeswitch.consoleLog("INFO", "[IVR] Using generated TTS file: " .. greet_short_path .. "\n")
        else
            freeswitch.consoleLog("ERR", "[IVR] Failed to generate TTS file\n")
        end
    end


   
    
     
  ------------------------------------------------------
 -- Timing and logic setup
 ------------------------------------------------------
 local min_digit = tonumber(ivr_data.min_digit) or 1
 local max_digit = tonumber(ivr_data.max_digit) or 1
 local timeout = tonumber(ivr_data.timeout) or 3000
 local inter_digit_timeout = tonumber(ivr_data.inter_digit_timeout) or 2000
 
 local max_failures = tonumber(ivr_data.max_failures) or 3
 local max_no_input = tonumber(ivr_data.max_no_input) or 3
 
 -- Working counters
 local remaining_failures = max_failures
 local remaining_no_input = max_no_input
 
 local parent_variable = ivr_data.parent_variable
 local preferred_gateway_uuid = ivr_data.preferred_gateway_uuid
 local ivr_menu_exit_app = ivr_data.ivr_menu_exit_app
 local ivr_menu_exit_data = ivr_data.ivr_menu_exit_data
 local information_node = ivr_data.information_node
 
 if information_node then
     session:setVariable("information_node", information_node or "ivr_node")
 end
 
 -- Ensure the data exists before splitting to avoid nil errors
 local raw_keys = ivr_data.option_key or ""
 local raw_actions = ivr_data.actions or ""
 
 local keys = split(ivr_data.option_key or "", ",")
 local actions = split(ivr_data.actions or ",", ",")
 
 local no_input_action = false
 
 -- if raw_keys == "" or raw_actions == "" then
 --     freeswitch.consoleLog("ERR", "[IVR] Missing keys or actions continue Exit Action\n")
 
 --     action_type = ivr_menu_exit_app
 --     target = ivr_menu_exit_data
 --     input = ""
 --     no_input_action = true
 --     freeswitch.consoleLog("INFO", string.format("[IVR] Exit Actions -> action: %s target: %s\n",
 --         tostring(action_type), tostring(target)))
 -- end
 
 local key_action_list = {}
 
 for i = 1, #keys do
     addLast(key_action_list, keys[i], actions[i])
 
     -- Log key → action mapping (no logic change)
     local key = keys[i] or ""
     local action_string = actions[i] or ""
 
     local action_type, target = action_string:match("^([^_]+)_(.+)$")
     action_type = action_type or action_string
     target = target or ""
 
     freeswitch.consoleLog("INFO",
         string.format("[IVR MAP] Key: %s → Action: %s | Target: %s\n",
             tostring(key),
             tostring(action_type),
             tostring(target)
         )
     )
 end
 
 
 session:answer()
 session:execute("set", "application_state=ivr")
 
 ------------------------------------------------------
 -- Collect Input
 ------------------------------------------------------
 local input, matched_action, action_type, target = nil, nil, nil, nil
 local greet_counter = 0
 
 while check_session() do
 
     if remaining_failures <= 0 and remaining_no_input <= 0 then
         freeswitch.consoleLog("WARNING", "[IVR] All attempt limits reached\n")
         break
     end
 
     --------------------------------------------------
     -- Greeting Selection
     --------------------------------------------------
     local play_greeting = ""
 
     if greet_counter == 0 then
         play_greeting = greet_long_path
     else
         if greet_short_path ~= "" and file.exists(greet_short_path) then
             play_greeting = greet_short_path
         elseif greet_long_path ~= "" and file.exists(greet_long_path) then
             play_greeting = greet_long_path
         end
     end
 
     --------------------------------------------------
     -- Play & Collect Digits
     --------------------------------------------------
     input = session:playAndGetDigits(
         min_digit,
         max_digit,
         1,
         timeout,
         "#",
         play_greeting,
         nil,
         "[0-9*#]",
         "input_digits",
         inter_digit_timeout,
         nil
     )
 
     freeswitch.consoleLog("INFO", "[IVR] User input: " .. tostring(input) .. "\n")
 
     --------------------------------------------------
     -- NO INPUT
     --------------------------------------------------
         if raw_keys == "" or raw_actions == "" then
             freeswitch.consoleLog("WARNING", "[IVR] Missing keys or actions; proceeding with Exit Action\n")
             no_input_action = true
             if ivr_menu_exit_app and ivr_menu_exit_data then
                 freeswitch.consoleLog("INFO", string.format("[IVR] Executing exit action: %s %s\n", ivr_menu_exit_app, ivr_menu_exit_data))
                 action_type = ivr_menu_exit_app or ""
                 target = ivr_menu_exit_data or ""
             else
                 freeswitch.consoleLog("ERR", "[IVR] No exit action defined for this menu\n")
             end
         elseif not input or input == "" then
         remaining_no_input = remaining_no_input - 1
 
         freeswitch.consoleLog("INFO",
             "[IVR] No input. Remaining no-input: "
             .. remaining_no_input .. "\n")
 
         if no_input_sound_path ~= "" then
             session:execute("playback", no_input_sound_path)
         end
 
         greet_counter = greet_counter + 1
 
         if remaining_no_input <= 0 then
             freeswitch.consoleLog("WARNING", "[IVR] Max no-input reached\n")
             break
         end
 
         goto continue
     end

    --------------------------------------------------
    -- Match Action
    --------------------------------------------------
    matched_action = search(key_action_list, input)

    if matched_action and no_input_action == false then
        action_type, target = matched_action:match("^([^_]+)_(.+)$")
        action_type = action_type or matched_action
        target = target or ""
    elseif no_input_action == false then
            action_type, target = nil, nil
    end

    --------------------------------------------------
    -- INVALID INPUT
    --------------------------------------------------
    if not action_type then
        remaining_failures = remaining_failures - 1

        freeswitch.consoleLog("INFO",
            "[IVR] Invalid input. Remaining invalid: "
            .. remaining_failures .. "\n")

        if invalid_sound_path ~= "" then
            session:execute("playback", invalid_sound_path)
        end

        greet_counter = greet_counter + 1

        if remaining_failures <= 0 then
            freeswitch.consoleLog("WARNING", "[IVR] Max invalid reached\n")
            break
        end

        goto continue
    end

    --------------------------------------------------
    -- VALID INPUT
    --------------------------------------------------
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


    freeswitch.consoleLog("console","parent_variable   " ..parent_variable);
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
                route_action.route_action(session, dbh,ivr_data.ivr_menu_exit_app, ivr_data.ivr_menu_exit_data, domain_name, domain_uuid, ivr_menu_uuid, true)
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

       -- we already have handle for callcenter  

    elseif action_type == "callcenter" then

        session:setVariable("meta_data",  json.encode(lua_ivr_vars or {}))
        local parent = session:getVariable("parent_ivr_id") or 1
        if parent and not visited[parent] then
            
            visited[parent] = true
            args.destination = parent

            args.destination = target
            args.domain_uuid = domain_uuid
            args.domain = domain_name

            freeswitch.consoleLog("INFO ", "destination " .. destination .. "\n")
            freeswitch.consoleLog("INFO ", "domain_uuid " .. domain_uuid .. "\n")
            freeswitch.consoleLog("INFO ", "domain " .. domain_name .. "\n")

            return  callcenter_routes.handle(session, dbh, args)
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
        timegroup.handle(session, dbh,target, ivr_menu_uuid, input)

    elseif action_type == "node" then
      
        node_routes.find_matching_condition(session, dbh, tonumber(target), domain, domain_uuid, ivr_menu_uuid)

    elseif action_type == "outbound" then
        session:setVariable("preferred_gateway_uuid", preferred_gateway_uuid)
        session:setVariable("destination_number", target)
        return outbound_routes_handler.handle(session, dbh, args, route_info)
        

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
                ai.metadata      = row.metadata
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
            freeswitch.consoleLog("info","[ivr.aiagent] Provider Info " .. json.encode(ai.metadata) .."\n")
            freeswitch.consoleLog("info","[ivr.aiagent] Loaded AI Agent ID " .. target .."\n")
        
          
            local config = ai.metadata;
            
            session:setVariable("information_node","bot_answered");
            ai_ws.run_ai_engine(session,config)
            return
        
        
    elseif action_type == "extension" or action_type == "ringgroup" --[[ or action_type == "callcenter" ]] or action_type == "conf" then
        session:setVariable("meta_data",  json.encode(lua_ivr_vars or {}))
        session:execute("transfer", target .. " XML systech")

    elseif action_type == "voicemail" then
           voicemail.handle(session, dbh, target, domain_name, domain_uuid)

    elseif action_type == "api" then
        session:setVariable("encoded_payload", json.encode(lua_ivr_vars or {}))
        session:setVariable("api_id", target)
        session:setVariable("ivr_menu_uuid", ivr_menu_uuid)
        session:execute("lua", "utils/api_handler.lua")

    elseif action_type == "hangup" then
        session:execute("hangup")
    else
        session:execute("playback", exit_sound_path)
    end

    return true
end




return handlers
