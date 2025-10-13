local handlers = require "features_handlers"
local Database = require "resources.functions.database"
local json = require("resources.functions.lunajson")

local dbh = Database.new("system")
assert(dbh:connected())

debug["sql"] = false;
--session:execute("info") 
-- Session setup
session:setVariable("continue_on_fail", "3,17,18,19,20,27,USER_NOT_REGISTERED")
session:setVariable("hangup_after_bridge", "true")

-- Session variables
local destination = session:getVariable("destination_number") or session:getVariable("sip_req_user") or
                        session:getVariable("sip_to_user")
local domain_name = session:getVariable("sip_req_host")
session:setVariable("domain_name",domain_name )
local src = session:getVariable("sip_from_user")

-- Failure prompt playback
function handle_prompt_cause()
    if not session:ready() then
        return
    end

    local disposition = session:getVariable("originate_disposition") or session:getVariable("DIALSTATUS") or
                            session:getVariable("originate_failed_cause") or ""
    local cause = disposition:upper()

    local prompts = {
        USER_BUSY = "ivr/ivr-user_busy.wav",
        NO_ANSWER = "ivr/no_answer.wav",
        CALL_REJECTED = "ivr/call_rejected.wav",
        UNALLOCATED_NUMBER = "ivr/ivr-unallocated_number.wav",
        USER_NOT_REGISTERED = "ivr/ivr-unallocated_number.wav",
        NO_USER_RESPONSE = "ivr/ivr-no_user_response.wav"
    }

    local prompt = prompts[cause]
    if prompt then
        freeswitch.consoleLog("err", string.format("[handle_prompt_cause] Cause: %s | Playing: %s\n", cause, prompt))
        session:execute("playback", prompt)
    end
end

---checking all required param is ready .........

if not session:ready() or not destination or destination == "" then
    freeswitch.consoleLog("err", "[routing.lua] Missing or invalid destination.\n")
    session:execute("playback", "ivr/ivr-no_route_destination.wav")
    return
end

freeswitch.consoleLog("info",
    string.format("[routing.lua] Dialed: %s | Domain: %s\n", destination, domain_name or "unknown"))

-- Fetch domain_uuid
local function get_domain_uuid(name)
    local sql = "SELECT domain_uuid FROM v_domains WHERE domain_name = :domain_name"
    local result
    dbh:query(sql, {
        domain_name = name
    }, function(row)
        result = row.domain_uuid
    end)
    return result
end

local domain_uuid = get_domain_uuid(domain_name)
session:setVariable("domain_uuid", domain_uuid)

-- session:execute("info") 

---channel update 

-- session:execute("info") 
-- local uuid = session:getVariable("uuid") 
-- local sip_call_id = session:getVariable("sip_call_id") or session:getVariable("variable_sip_call_id")
-- local did_num = destination 
--
-- freeswitch.consoleLog("console","uuid ---------".. uuid);
--
-- if uuid and domain_uuid then
--    local sql = [[
--        UPDATE channels
--        SET domain_name = :domain_name,
--            domain_uuid = :domain_uuid,
--            did_num = :did_num,
--            sip_call_id = :sip_call_id
--        WHERE uuid = :uuid
--    ]]
--
--    local params = {
--        domain_name = domain_name,
--        domain_uuid = domain_uuid,
--        did_num = did_num,
--        sip_call_id = sip_call_id,
--        uuid = uuid
--    }
--
--    -- Optional SQL debug
--    if debug["sql"] then
--        local json = require "resources.functions.lunajson"
--        freeswitch.consoleLog("notice",
--            "[routing.lua] SQL: " .. sql .. " | Params: " .. json.encode(params) .. "\n")
--    end
--
--    dbh:query(sql, params)
-- else
--    freeswitch.consoleLog("warning",
--        "[routing.lua] Skipping channel update — uuid or domain_uuid is missing.\n")
-- end

-- Routing args
local args = {
    destination = destination,
    domain = domain_name,
    domain_uuid = domain_uuid
}

-- DID validation
local function is_valid_did(dest)

    local caller_ip = session:getVariable("network_addr")
    freeswitch.consoleLog("info", "[Lua] Caller IP: " .. tostring(caller_ip) .. "\n")
    local sql = [[
    SELECT r.*, d.domain_name,
    CASE
    WHEN r.src_regex_pattern = '*' THEN 'matched_star'
    WHEN string_to_array(REPLACE(r.src_regex_pattern, '+', ''), ',') 
    && ARRAY[REPLACE(:src, '+', '')]
    AND (r.ip_check IS NULL OR r.ip_check = :caller_ip) THEN 'match_both_src_and_caler_ip'
    WHEN string_to_array(REPLACE(r.src_regex_pattern, '+', ''), ',') 
    && ARRAY[REPLACE(:src, '+', '')] THEN 'matched_src'
    ELSE 'no_match'
    END AS match_type
    FROM v_did_routes r
    JOIN v_domains d ON d.domain_uuid = r.domain_uuid
    WHERE r.did_num = :dest
      AND (
        r.src_regex_pattern = '*'
        OR string_to_array(REPLACE(r.src_regex_pattern, '+', ''), ',') 
       && ARRAY[REPLACE(:src, '+', '')]
    )
    AND r.enabled = true
    AND (r.ip_check IS NULL OR r.ip_check = :caller_ip)
    ORDER BY 
    CASE 
    WHEN r.src_regex_pattern = '*' THEN 2
    WHEN string_to_array(REPLACE(r.src_regex_pattern, '+', ''), ',') 
         && ARRAY[REPLACE(:src, '+', '')]
         AND (r.ip_check IS NULL OR r.ip_check = :caller_ip) THEN 0
    WHEN string_to_array(REPLACE(r.src_regex_pattern, '+', ''), ',') 
         && ARRAY[REPLACE(:src, '+', '')] THEN 1
    ELSE 3
    END
    LIMIT 1
    ]]

    dbh:query(sql, {
        src = tostring(src),
        dest = tostring(dest),
        caller_ip = tostring(caller_ip)
    }, function(row)
        for k, v in pairs(row) do
            args[k] = v
        end
        found = true

        if row.match_type then
            freeswitch.consoleLog("CONSOLE", "[Routing] Match type: " .. row.match_type .. "\n")
        end
    end)

    

    if (debug["sql"]) then
        local json = require "resources.functions.lunajson"
        freeswitch.consoleLog("notice",
            "[is_valid_did] SQL: " .. sql .. "\nsrc: " .. tostring(src) .. "\ndest: " .. tostring(dest) ..
                "\ncaller_ip: " .. tostring(caller_ip) .. "\n")
    end

    if found == nil then

        local fallback_sql = [[
        SELECT d.domain_uuid, d.domain_name
        FROM v_did_routes r
        JOIN v_domains d ON d.domain_uuid = r.domain_uuid
        WHERE r.did_num = :dest
          AND r.enabled = true
        LIMIT 1
    ]]

    dbh:query(fallback_sql, { dest = tostring(dest) }, function(row)
        if row.domain_uuid then
            session:setVariable("domain_uuid", row.domain_uuid)
            session:setVariable("domain_name", row.domain_name)
            freeswitch.consoleLog("INFO", "[Routing] Fallback matched DID: " .. dest .. " => Domain: " .. row.domain_name .. " (UUID: " .. row.domain_uuid .. ")\n")
        end
    end)

    -- Continue with outbound fallback logic if needed
       freeswitch.consoleLog("DEBUG", "[Routing] Match type: No match with DID  Going for Outbound Call \n")
    end

    -- Check allowed days if any
    if found and args.days and args.days ~= "" then
        local ok, allowed_days = pcall(json.decode, args.days)
        if not ok then
            freeswitch.consoleLog("err", "[routing.lua] Invalid JSON in days\n")
            session:execute("hangup")
            return false
        end

        local today = ({"sun", "mon", "tue", "wed", "thu", "fri", "sat"})[tonumber(os.date("%w")) + 1]
        for _, day in ipairs(allowed_days) do
            if day == today then
                return true
            end
        end

        freeswitch.consoleLog("warning", "[routing.lua] Call not allowed on this day.\n")
        return false
    end

    return found
end

local function user_based_domain(args)

    freeswitch.consoleLog("info", "user_based_extension " .. tostring(args.destination) .. "\n")

    local destination = args.destination
    local domain_uuid = args.domain_uuid

    if not domain_uuid or not destination then
        freeswitch.consoleLog("err", "[user_based_extension] Missing domain_uuid or destination\n")
        return false
    end

    -- Lookup extension
    local extension = nil
    local sql = [[
        SELECT extension
        FROM v_extensions
        WHERE extension = :extension
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
            "[handlers.extensions] SQL: " .. sql .. " | Params: " .. json.encode(params) .. "\n")
    end

    dbh:query(sql, params, function(row)
        extension = row.extension
    end)

    if not extension then
        freeswitch.consoleLog("NOTICE",
            "[handlers.extensions] No extension_uuid found for  " .. tostring(destination) .. "\n")
        return false
    end

    return true

end

-- Main dispatcher
local function dispatch(dest)
    local num_dest = tonumber(dest)
    local valid_did = is_valid_did(dest)

    if valid_did then
        return handlers.handle_did_call(args)

    elseif args.days and args.days ~= "" then
        if args.failover_destination then
            freeswitch.consoleLog("notice",
                "[routing.lua] Failover due to day restriction → " .. args.failover_destination)
            session:execute("transfer", args.failover_destination .. " XML systech")
            return true
        else
            session:execute("playback", "ivr/ivr-day_not_allowed.wav")
            session:execute("hangup")
            return false
        end
    end

    if (num_dest and num_dest >= 1000 and num_dest <= 3999) or (user_based_domain(args)) then
        return handlers.extension(args)
    elseif num_dest and num_dest >= 4000 and num_dest <= 5999 then
        return handlers.callcenter(args)
    elseif num_dest and num_dest >= 6000 and num_dest <= 6999 then
        return handlers.ringgroup(args)
    elseif num_dest and num_dest >= 7000 and num_dest <= 8999 then
        return handlers.ivr(args)
    elseif tostring(dest):len() >= 7 and tostring(dest):len() <= 15 then
        return handlers.outbound(args)
    else
        return false -- No matching route found
    end
end

-- 🚀 Execute
local routed = dispatch(destination)

if routed then
    handle_prompt_cause()
    freeswitch.consoleLog("info", "[routing.lua] Call routed successfully.\n")
else
    freeswitch.consoleLog("warning", "[routing.lua] No route found for: " .. destination)
    session:execute("sleep", "1000")
    session:execute("playback", "ivr/ivr-no_route_destination.wav")
end

