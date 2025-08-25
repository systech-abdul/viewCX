json = require "resources.functions.lunajson"

local handlers = {}

-- Connect to the database once
local Database = require "resources.functions.database"
local dbh = Database.new('system')
assert(dbh:connected())
debug["sql"] = false;

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

-- Extension (10000–19999)
function handlers.extension(args)
    if not check_session() then
        return false
    end

    freeswitch.consoleLog("info", "[handlers.extension] Routing to extension: " .. tostring(args.destination) .. "\n")

    -- Set codec preferences
    session:setVariable("codec_string", "PCMU,PCMA,G729")

    local dest = "{media_mix_inbound_outbound_codecs=true,ignore_early_media=true}user/" .. args.destination .. "@" ..
                     args.domain
    session:execute("bridge", dest)

    return true
end

-- Call Center (20000–29999)
function handlers.callcenter(args)
    if not check_session() then
        return false
    end

    freeswitch.consoleLog("info", "[handlers.callcenter] Routing to callcenter: " .. tostring(args.destination) .. "\n")

    session:answer()
    session:sleep(1000)

    local call_name = args.destination .. "@" .. args.domain
    session:execute("callcenter", call_name)

    return true
end

-- Ring Group (30000–39999)
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

    return true
end

-- IVR handler function for FreeSWITCH (40000–49999)
-- Main IVR Handler

function handlers.ivr(args, counter)
    if not check_session() then
        return false
    end

    local destination = args.destination
    local domain_uuid = args.domain_uuid
    local domain = args.domain
    local modified_ivr_id = args.modified_ivr_id or destination
    local visited = args.visited_ivr or {}
    local MAX_PATH_STEPS = 20

    args.ivr_path = args.ivr_path or {}
    counter = counter or {
        count = 0
    }

    freeswitch.consoleLog("info", "[handlers.ivr] Routing to IVR: " .. tostring(destination) .. "\n")

    -- Fetch IVR config
    local query = [[
        SELECT
            string_agg(DISTINCT op.ivr_menu_option_digits, ',' ORDER BY op.ivr_menu_option_digits) AS option_key,
            string_agg(op.ivr_menu_option_action || '_' || op.ivr_menu_option_param, ',' ORDER BY op.ivr_menu_option_digits) AS actions,
            m.ivr_menu_greet_long AS greet_long,
            m.ivr_menu_invalid_sound AS invalid_sound,
            m.ivr_menu_exit_sound AS exit_sound,
            1 AS min_digit,
            MAX(m.ivr_menu_digit_len) AS max_digit,
            MAX(m.ivr_menu_inter_digit_timeout) AS inter_digit_timeout,
            MAX(m.ivr_menu_timeout) AS timeout,
            MIN(CASE WHEN m.ivr_menu_max_failures > 5 THEN 5 ELSE m.ivr_menu_max_failures END) AS max_failures,
            m.ivr_menu_confirm_macro,
            m.ivr_menu_name AS name,
            MIN(op.preferred_gateway_uuid::text) AS preferred_gateway_uuid,
            
            m.ivr_menu_uuid,MIN(d.domain_name::text) AS domain_name
        FROM v_ivr_menu_options op
        JOIN v_ivr_menus m ON m.ivr_menu_uuid = op.ivr_menu_uuid
        JOIN v_domains d ON  d.domain_uuid =  m.domain_uuid
        WHERE m.ivr_menu_extension = :destination AND m.domain_uuid = :domain_uuid
        GROUP BY
            m.ivr_menu_greet_long, m.ivr_menu_invalid_sound, m.ivr_menu_exit_sound,
            m.ivr_menu_confirm_macro, m.ivr_menu_name,m.ivr_menu_uuid
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
    local base_path = "/var/lib/freeswitch/recordings/" .. domain .. "/"
    local greet_long_path =
        (ivr_data.greet_long and ivr_data.greet_long ~= "") and (base_path .. ivr_data.greet_long) or ""
    local invalid_sound_path = (ivr_data.invalid_sound and ivr_data.invalid_sound ~= "") and
                                   (base_path .. ivr_data.invalid_sound) or ""
    local exit_sound_path =
        (ivr_data.exit_sound and ivr_data.exit_sound ~= "") and (base_path .. ivr_data.exit_sound) or ""

    local min_digit = tonumber(ivr_data.min_digit) or 1
    local max_digit = tonumber(ivr_data.max_digit) or 1
    local timeout = tonumber(ivr_data.timeout) or 3000
    local inter_digit_timeout = tonumber(ivr_data.inter_digit_timeout) or 2000
    local max_failures = tonumber(ivr_data.max_failures) or 3
    local domain_name = ivr_data.domain_name

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

    freeswitch.consoleLog("console", "[IVR] Selected input: " .. input .. "\n")

    local matched_action = search(key_action_list, input)
    local action_type, target = nil, nil

    if matched_action then
        action_type, target = matched_action:match("^([^_]+)_(.+)$")
        if not action_type then
            action_type = matched_action
            target = ""
        end
    end

    -- Log single step
    --[[ local log_query = [[
        INSERT INTO call_logging_ivr 
        (call_uuid, domain_uuid, ivr_id, input_digits, timestamp, action_type, action_target) 
        VALUES 
        (:call_uuid, :domain_uuid, :ivr_id, :input_digits, NOW(), :action_type, :action_target)
    ]]

    --[[  dbh:query(log_query, {
        call_uuid = session:get_uuid(),
        domain_uuid = domain_uuid,
        ivr_id = modified_ivr_id,
        input_digits = input,
        action_type = action_type or 'unknown',
        action_target = target or ''
    }) ]]

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
        INSERT INTO call_ivr_journeys (call_uuid, domain_uuid, full_path, updated_at)
        VALUES (:call_uuid, :domain_uuid, :full_path::jsonb, NOW())
        ON CONFLICT (call_uuid)
        DO UPDATE SET full_path = EXCLUDED.full_path, updated_at = NOW()
    ]]
    dbh:query(journey_query, {
        call_uuid = session:get_uuid(),
        domain_uuid = domain_uuid,
        full_path = json.encode(args.ivr_path)
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

            local within_working_time = timegroup(target) -- keep as boolean

            freeswitch.consoleLog("ERR", "[IVR] Selected input: " .. input .. " | working time: " ..
                tostring(within_working_time) .. "\n")

            local sql = [[
                        SELECT 
                            working_destination_type,
                            working_destination_num,
                            failover_destination_type,
                            failover_destination_num
                        FROM v_ivr_menu_options
                        WHERE ivr_menu_uuid = :ivr_menu_uuid
                          AND ivr_menu_option_digits = :ivr_menu_option_digits
                        LIMIT 1
                    ]]

            if debug["sql"] then
                freeswitch.consoleLog("notice", "[handlers.timegroup_ivr] SQL: " .. sql .. "\n")
            end

            local params = {
                ivr_menu_uuid = ivr_menu_uuid,
                ivr_menu_option_digits = input
            }

            local timegroup_data = {}
            dbh:query(sql, params, function(row)
                timegroup_data = row
            end)

            -- Wait for result and pick destination
            if next(timegroup_data) ~= nil then
                local destination_type, destination_number

                if within_working_time then
                    destination_type = timegroup_data.working_destination_type
                    destination_number = timegroup_data.working_destination_num
                else
                    destination_type = timegroup_data.failover_destination_type
                    destination_number = timegroup_data.failover_destination_num
                end

                -- Log result
                freeswitch.consoleLog("info", "[IVR] Routing to: " .. tostring(destination_type) .. " - " ..
                    tostring(destination_number) .. "\n")
                if destination_type and destination_number then

                    return session:execute("transfer", destination_number .. " XML systech")
                end

            else
                freeswitch.consoleLog("ERR", "[IVR] No destination found for timegroup option.\n")
            end

        elseif action_type == "hangup" then
            return session:execute("hangup")

        elseif action_type == "lua" then
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

        elseif action_type == "extension" or action_type == "ringgroup" or action_type == "queue" or action_type ==
            "conf" then
            session:setVariable("destination_number", target)
            return session:execute("transfer", target .. " XML systech")

        elseif action_type == "voicemail" then
            freeswitch.consoleLog("info", " " .. tostring(action_type) .. "\n");
            session:setVariable("destination_number", target)
            -- session:setVariable("domain_name", "cc.systech.ae")
            -- session:setVariable("voicemail_id", "9ea536c1-080b-439f-bd2e-a4fceba46ea4")
            -- session:execute("lua", "/usr/share/freeswitch/scripts/app/voicemail/index.lua")
            local profile = "default"
            local mailbox = target

            -- Execute voicemail app
            local args = string.format("%s %s %s", profile, domain_name, mailbox)
            session:execute("voicemail", args)

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

    local log_message = "[handlers.handle_did_call] Routing args:\n"
    for k, v in pairs(args) do
        log_message = log_message .. string.format("  %s = %s\n", tostring(k), tostring(v))
    end
    freeswitch.consoleLog("info", log_message)

    -- Set caller ID if available
    if args.caller_id_name then
        session:setVariable("effective_caller_id_name", args.caller_id_name)
    end
    if args.caller_id_number then
        session:setVariable("effective_caller_id_number", args.caller_id_number)
    end

    session:setVariable("verified_did", "true")

    local handler_map = {
        extension = handlers.extension,
        callcenter = handlers.callcenter,
        ringgroup = handlers.ringgroup,
        ivr = handlers.ivr,
        outbound = handlers.outbound
    }

    local handler = handler_map[args.destination_type]

    if handler then
        local result = handler(args)
    else
        freeswitch.consoleLog("err", "[handlers.handle_did_call] Unknown destination_type: " ..
            tostring(args.destination_type) .. "\n")
        session:execute("playback", "ivr/ivr-not_available.wav")
    end

    return true
end

function timegroup(time_grp_uuid)

    if not check_session() then
        return false
    end

    freeswitch.consoleLog("info", "[timegroup] Routing to time group: " .. tostring(time_grp_uuid) .. "\n")

    local sql = [[
        SELECT 
            *,
            -- Convert current timestamp to the row's timezone
            trim(to_char(now() AT TIME ZONE time_zone, 'Day')) AS current_day_trimmed,
            to_char(now() AT TIME ZONE time_zone, 'HH24:MI:SS') AS current_time,

            -- Is today a working day?
            trim(to_char(now() AT TIME ZONE time_zone, 'Day'))::weekday_enum = ANY (working_days) AS is_today_working,

            -- Is current time within working hours?
            (to_char(now() AT TIME ZONE time_zone, 'HH24:MI:SS'))::time >= working_time_start 
            AND (to_char(now() AT TIME ZONE time_zone, 'HH24:MI:SS'))::time <= working_time_end AS is_time_in_range,

            -- Final working time check
            (
                trim(to_char(now() AT TIME ZONE time_zone, 'Day'))::weekday_enum = ANY (working_days)
                AND (to_char(now() AT TIME ZONE time_zone, 'HH24:MI:SS'))::time BETWEEN working_time_start AND working_time_end
            ) AS is_within_working_time,

            -- Decide the destination
            CASE
                WHEN trim(to_char(now() AT TIME ZONE time_zone, 'Day'))::weekday_enum = ANY (working_days)
                     AND (to_char(now() AT TIME ZONE time_zone, 'HH24:MI:SS'))::time BETWEEN working_time_start AND working_time_end
                THEN working_destination_num
                ELSE failover_destination_num
            END AS resolved_destination

        FROM time_group
        WHERE uuid = :time_grp_uuid
        LIMIT 1;
    ]]

    local params = {
        time_grp_uuid = time_grp_uuid
    }

    if debug["sql"] then
        freeswitch.consoleLog("notice", "[timegroup] SQL: " .. sql .. " | Params: " .. json.encode(params) .. "\n")
    end

    local found = false

    dbh:query(sql, params, function(row)
        found = true

        local working_type = row.working_destination_type
        local working_num = row.working_destination_num
        local failover_type = row.failover_destination_type
        local failover_num = row.failover_destination_num
        local resolved_dest = row.resolved_destination
        local working_time = tostring(row.is_within_working_time)

        freeswitch.consoleLog("info", "[timegroup] Timezone: " .. row.time_zone .. "\n")
        freeswitch.consoleLog("info", "[timegroup] Current Day: " .. row.current_day_trimmed .. ", Time: " ..
            row.current_time .. "\n")
        freeswitch.consoleLog("info", "[timegroup] is_within_working_time: " .. working_time .. "\n")
        freeswitch.consoleLog("info", "[timegroup] Routing to: " .. resolved_dest .. "\n")

        if working_time == 't' then

            return true
        else
            freeswitch.consoleLog("warning",
                "[timegroup] false time group found for UUID: " .. tostring(time_grp_uuid) .. "\n")

            return false
        end

    end)

    if not found then
        freeswitch.consoleLog("warning", "[timegroup] No time group found for UUID: " .. tostring(time_grp_uuid) .. "\n")
        return false
    end

end

-- Transfers the call to the given destination number with a specified dialplan context
function transfer(destination_number, destination_type, context)
    if not session:ready() then
        freeswitch.consoleLog("ERR", "[transfer] Session not ready\n")
        return false
    end

    -- Log transfer info
    freeswitch.consoleLog("INFO",
        string.format("[transfer] Transferring to %s (%s) in context %s\n", tostring(destination_number),
            tostring(destination_type), tostring(context)))

    -- Compose the transfer string
    -- Format: <number>@<context>
    -- If you have destination_type (like 'sip', 'user', etc), you may prepend it to number
    local dial_string
    if destination_type and destination_type ~= "" then
        dial_string = destination_type .. "/" .. destination_number
    else
        dial_string = destination_number
    end

    -- Transfer the call
    session:execute("transfer", dial_string .. " XML " .. context)

    return true
end

return handlers

