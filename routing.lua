local handlers = require "features_handlers"
local caller_handler = require "caller_handler"
local Database = require "resources.functions.database"
local json = require("resources.functions.lunajson")

local dbh = Database.new("system")
assert(dbh:connected())

debug["sql"] = false;
-- session:execute("info") 
-- Session setup
session:setVariable("continue_on_fail", "3,17,18,19,20,27,USER_NOT_REGISTERED")
session:setVariable("hangup_after_bridge", "true")

-- Session variables
local did_destination = session:getVariable("destination_number") or session:getVariable("sip_req_user") or
                        session:getVariable("sip_to_user")
local domain_name = session:getVariable("domain_name") or session:getVariable("sip_req_host")
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

if not session:ready() or not did_destination or did_destination == "" then
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

local domain_uuid = session:getVariable("domain_uuid") 
if not domain_uuid or domain_uuid == "" then
    domain_uuid = get_domain_uuid(domain_name)
    session:setVariable("domain_uuid", domain_uuid)
end

-- session:execute("info") 

---channel update 

-- session:execute("info") 
-- local uuid = session:getVariable("uuid") 
-- local sip_call_id = session:getVariable("sip_call_id") or session:getVariable("variable_sip_call_id")
-- local did_num = destination 
--
-- freeswitch.consoleLog("console","uuid ---------".. uuid);


-- session:execute("hangup")
-- Routing args
local args = {
    destination = did_destination,
    domain = domain_name,
    domain_uuid = domain_uuid
}

-- DID validation
local function is_valid_did(dest)
    local caller_ip = session:getVariable("network_addr")
    freeswitch.consoleLog("info", "[Lua] Caller IP: " .. tostring(caller_ip) .. "\n")

    ------------------------------------------------------------------
    -- SQL: include failover_type, failover_destination, and day validity
    ------------------------------------------------------------------

    local function sql_escape(value)
        if value == nil then
            return "NULL"                  -- unquoted SQL NULL
        end
        local s = tostring(value)
        s = s:gsub("'", "''")            -- escape single quotes
        return "'" .. s .. "'"           -- wrap in single quotes
    end


    -- Build SQL safely-ish
    local sql = string.format([[
    SELECT fn_did_routing(
        %s,  -- p_did_num
        %s,  -- p_src_regex_pattern
        %s   -- p_caller_ip
    )::text AS route_json;
    ]],
    sql_escape(did_destination),
    sql_escape(src),
    sql_escape(caller_ip)
    )

    freeswitch.consoleLog("INFO", "[routing] SQL: " .. sql .. "\n")

    ------------------------------------------------------------------
    -- Execute SQL
    ------------------------------------------------------------------
    local found = nil
 
    local route_json_str

    dbh:query(sql, function(row)
    -- column alias: route_json
    route_json_str = row.route_json
    end)


    if not route_json_str or route_json_str == "" then
    freeswitch.consoleLog("WARNING", "[routing] No routing row returned\n")
    -- handle: maybe default / hard-coded failover
    return
    end

    -- Parse JSON
    local ok, route = pcall(json.decode, route_json_str)
    if not ok or type(route) ~= "table" then
    freeswitch.consoleLog("ERR", "[routing] Failed to decode JSON: " .. tostring(route_json_str) .. "\n")
    return
    end

    freeswitch.consoleLog("INFO", "[routing] Route type: " .. tostring(route.route_type) .. ", dest_type=" .. tostring(route.destination_type) .. ", dest=" .. tostring(route.destination) .. "\n")

    local destination_type = route.destination_type or ""
    local destination = route.destination or ""

    -- Example: set channel vars based on result
    if route.destination and route.destination_type then
    session:setVariable("v_did_route_uuid", route.did_route_uuid or "")
    session:setVariable("v_route_type", route.route_type or "")
    session:setVariable("v_destination_type", route.destination_type or "")
    session:setVariable("v_destination", route.destination or "")
    session:setVariable("match_type", route.match_type or "")
    -- session:setVariable("active_today", route.active_today or "")
    session:setVariable("route_type", route.route_type or "")
    session:setVariable("destination_type", route.destination_type or "")
    session:setVariable("destination", route.destination or "")
    session:setVariable("tenant_id", route.tenant_id or "")
    session:setVariable("process_id", route.process_id or "")
    session:setVariable("domain_uuid", route.domain_uuid or "")
    session:setVariable("domain_name", route.domain_name or "")
    session:setVariable("time_zone", route.time_zone or "")
    else
    -- Nothing usable, maybe log and hangup or go to a default IVR
    freeswitch.consoleLog("WARNING", "[routing] No destination resolved, fallback logic should run\n")
        if tostring(dest):len() >= 7 and tostring(dest):len() <= 15 then
            return handlers.outbound(args)
        end
    end


    ------------------------------------------------------------------
    -- Handle failover condition (inactive today)
    ------------------------------------------------------------------
    if args.active_today == "f" or args.active_today == false then
        if args.failover_destination and args.failover_destination ~= "" then
            freeswitch.consoleLog("WARNING", "[Routing] DID inactive today (" ..
                (args.time_zone or "local") .. "). Using failover: " ..
                args.failover_destination .. " (" .. (args.failover_type or "unknown") .. ")\n")

            -- Set variables for dialplan or next logic
            session:setVariable("did_type", args.failover_type or "")
            session:setVariable("did_destination", args.failover_destination or "")
            return true -- allow Lua to continue using failover
        else
            freeswitch.consoleLog("WARNING", "[Routing] DID inactive today and no failover defined.\n")
            return false
        end
    end

    ------------------------------------------------------------------
    -- If active today → proceed normally
    ------------------------------------------------------------------
    session:setVariable("did_type", args.destination_type or "")
    session:setVariable("did_destination", args.destination or "")
    freeswitch.consoleLog("info", "[Routing] Route active today, proceeding with normal DID.\n")
    return true
end

-- Returns: row table (columns as strings) on success, or nil on failure.



local function user_based_domain(args)

    freeswitch.consoleLog("info", "user_based_extension " .. tostring(args.destination) .. "\n")

    local destination = args.did_destination
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
local function dispatch_old(dest)
    local num_dest = tonumber(dest)
    local valid_did = is_valid_did(dest)
    local upsert_caller_profile = caller_handler.upsert_caller_profile()

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

-- Main dispatcher
local function dispatch(dest)
    local num_dest = tonumber(dest)
    local valid_did = is_valid_did(dest)
    local upsert_caller_profile = caller_handler.upsert_caller_profile()
    freeswitch.consoleLog("info", "[routing][dispatch] destination " .. dest .. "\n")

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

--session:execute("info") 

-- destination_type = session:getVariable("destination_type") or ""
-- destination = session:getVariable("destination") or ""

freeswitch.consoleLog("info", "[routing] destination " .. did_destination .. "\n")
-- 🚀 Execute
local routed = dispatch(did_destination)



if routed then
    handle_prompt_cause()
    freeswitch.consoleLog("info", "[routing.lua] Call routed successfully.\n")
else
    freeswitch.consoleLog("warning", "[routing.lua] No route found for: " .. did_destination .. "\n")
    session:execute("sleep", "1000")
    session:execute("playback", "ivr/ivr-no_route_destination.wav")
end

