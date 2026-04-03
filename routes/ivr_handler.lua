local json = require "resources.functions.lunajson"
local path_util = require "utils.path"
local file = require "utils.file"
local route_action = require "utils.route_action"
local tts = require "features.tts"

local M = {}

-- Constants
local MAX_PATH_STEPS = 20

------------------------------------------------------
-- Internal Helpers
------------------------------------------------------
local function split(inputstr, sep)
    local t = {}
    if not inputstr then return t end
    sep = sep or ","
    for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
        table.insert(t, str)
    end
    return t
end

local function search_action(list, key)
    for _, node in ipairs(list) do
        if node.key == key then return node.val end
    end
    return nil
end

local function check_session(session)
    if not session or not session:ready() then
        freeswitch.consoleLog("err", "[IVR Module] Session not ready\n")
        return false
    end
    return true
end

------------------------------------------------------
-- Core Logic
------------------------------------------------------
function M.run(session, dbh, args)
    if not check_session(session) then return false end

    -- 1. Setup Parameters
    local destination = args.destination or session:getVariable("ivr_menu_extension")
    local domain_uuid = args.domain_uuid or session:getVariable("domain_uuid")
    local counter = args.counter or { count = 0 }
    local ivr_path = args.ivr_path or {}
    local visited = args.visited_ivr or {}
    
    if not destination or not domain_uuid then
        freeswitch.consoleLog("ERR", "[IVR] Missing destination or domain_uuid\n")
        return false
    end

    -- 2. Fetch IVR Menu Data
    local query = [[
        SELECT m.*, d.domain_name,
               r_long.recording_filename AS greet_long_fn,
               r_short.recording_filename AS greet_short_fn,
               r_invalid.recording_filename AS invalid_fn,
               r_exit.recording_filename AS exit_fn,
               r_no_input.recording_filename AS no_input_fn,
               COALESCE(string_agg(DISTINCT op.ivr_menu_option_digits, ',' ORDER BY op.ivr_menu_option_digits), '') AS option_keys,
               COALESCE(string_agg(op.ivr_menu_option_action || '_' || op.ivr_menu_option_param, ','), '') AS option_actions,
               MIN(op.preferred_gateway_uuid::text) AS preferred_gateway_uuid
        FROM v_ivr_menus m
        JOIN v_domains d ON d.domain_uuid = m.domain_uuid
        LEFT JOIN v_ivr_menu_options op ON m.ivr_menu_uuid = op.ivr_menu_uuid
        LEFT JOIN v_recordings r_long ON r_long.recording_uuid::text = m.ivr_menu_greet_long
        LEFT JOIN v_recordings r_short ON r_short.recording_uuid::text = m.ivr_menu_greet_short
        LEFT JOIN v_recordings r_invalid ON r_invalid.recording_uuid::text = m.ivr_menu_invalid_sound
        LEFT JOIN v_recordings r_exit ON r_exit.recording_uuid::text = m.ivr_menu_exit_sound
        LEFT JOIN v_recordings r_no_input ON r_no_input.recording_uuid::text = m.ivr_menu_no_input_sound
        WHERE (m.ivr_menu_uuid::text = :dest OR m.ivr_menu_extension::text = :dest)
          AND m.domain_uuid = :duid AND m.deleted_at IS NULL
        GROUP BY m.ivr_menu_uuid, d.domain_name, r_long.recording_filename, r_short.recording_filename, 
                 r_invalid.recording_filename, r_exit.recording_filename, r_no_input.recording_filename
    ]]

    local ivr_data = {}
    dbh:query(query, { dest = destination, duid = domain_uuid }, function(row) ivr_data = row end)

    if not ivr_data.ivr_menu_uuid then
        freeswitch.consoleLog("ERR", "[IVR] Menu not found: " .. destination .. "\n")
        return false
    end

    -- 3. Path & Language Setup
    local base_path = path_util.recording_path(ivr_data.domain_name)
    local sounds = {
        long    = ivr_data.greet_long_fn and (base_path .. ivr_data.greet_long_fn) or "",
        short   = ivr_data.greet_short_fn and (base_path .. ivr_data.greet_short_fn) or "",
        invalid = ivr_data.invalid_fn and (base_path .. ivr_data.invalid_fn) or "",
        exit    = ivr_data.exit_fn and (base_path .. ivr_data.exit_fn) or "",
        no_input= ivr_data.no_input_fn and (base_path .. ivr_data.no_input_fn) or ""
    }

    if ivr_data.language and ivr_data.language ~= "" then
        session:setVariable("language_code", ivr_data.language)
    end

    -- 4. TTS Logic
    local function get_tts(text, type_key)
        if ivr_data[type_key] == "text" and text and text ~= "" then
            local parsed_text = text:gsub("%${(.-)}", function(v) return session:getVariable(v) or "" end)
            return tts.generate(session, dbh, parsed_text, domain_uuid)
        end
        return nil
    end

    sounds.long = get_tts(ivr_data.playback_text, "playback_type") or sounds.long
    sounds.short = get_tts(ivr_data.playback_text_short, "playback_type_short") or sounds.short

    -- 5. Interaction Loop
    local remaining_tries = tonumber(ivr_data.ivr_menu_max_failures) or 3
    local remaining_timeouts = tonumber(ivr_data.ivr_menu_max_timeouts) or 3
    local input, action_type, target = nil, nil, nil
    local attempt = 0

    session:answer()
    
    while check_session(session) do
        if remaining_tries <= 0 or remaining_timeouts <= 0 then break end

        local prompt = (attempt == 0 or sounds.short == "") and sounds.long or sounds.short
        
        input = session:playAndGetDigits(
            1, tonumber(ivr_data.ivr_menu_digit_len) or 1, 1, 
            tonumber(ivr_data.ivr_menu_timeout) or 3000, "#", 
            prompt, nil, "[0-9*#]", "ivr_digits", 
            tonumber(ivr_data.ivr_menu_inter_digit_timeout) or 2000, ""
        )

        if not input or input == "" then
            remaining_timeouts = remaining_timeouts - 1
            if sounds.no_input ~= "" then session:execute("playback", sounds.no_input) end
            attempt = attempt + 1
        else
            -- Match Option
            local keys = split(ivr_data.option_keys, ",")
            local actions = split(ivr_data.option_actions, ",")
            local matched = nil
            for i, k in ipairs(keys) do if k == input then matched = actions[i] break end end

            if matched then
                action_type, target = matched:match("^([^_]+)_(.+)$")
                action_type = action_type or matched
                break 
            else
                remaining_tries = remaining_tries - 1
                if sounds.invalid ~= "" then session:execute("playback", sounds.invalid) end
                attempt = attempt + 1
            end
        end
    end

    -- 6. Execute Routing (Delegated to specialized handlers)
    if action_type then
        -- Record Journey
        table.insert(ivr_path, { ivr_id = ivr_data.ivr_menu_uuid, input = input, action = action_type })
        
        if action_type == "ivr" then
            counter.count = counter.count + 1
            if counter.count < 10 then
                args.destination = target
                args.ivr_path = ivr_path
                return M.run(session, dbh, args)
            end
        elseif action_type == "transfer" or action_type == "extension" then
            session:execute("transfer", target .. " XML " .. ivr_data.domain_name)
        elseif action_type == "hangup" then
            session:execute("hangup")
        -- Add other types (callcenter, voicemail, etc.) as needed
        end
    else
        -- Default Exit Action
        if sounds.exit ~= "" then session:execute("playback", sounds.exit) end
        if ivr_data.ivr_menu_exit_app then
            route_action.route_action(session, dbh, ivr_data.ivr_menu_exit_app, ivr_data.ivr_menu_exit_data, ivr_data.domain_name, domain_uuid, ivr_data.ivr_menu_uuid, true)
        end
    end

    return true
end

return M
