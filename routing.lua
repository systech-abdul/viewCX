local handlers = require "features_handlers"
local caller_handler = require "caller_handler"
local Database = require "resources.functions.database"
local json = require("resources.functions.lunajson")
local outbound_routes = require "outbound_routes"

local dbh = Database.new("system")
assert(dbh:connected())

debug["sql"] = false;
-- session:execute("info") 
-- Session setup
session:setVariable("continue_on_fail", "3,17,18,19,20,27,USER_NOT_REGISTERED")
session:setVariable("hangup_after_bridge", "true")


-- =========================
-- get_extension_uuid helpers
-- =========================

local function get_extension_uuid(domain_uuid, user)
    local sql = [[
        SELECT extension_uuid
        FROM v_extensions
        WHERE domain_uuid = :domain_uuid
          AND enabled = 'true'
          AND (extension = :user OR number_alias = :user)
        LIMIT 1
    ]]
    local ext_uuid
    dbh:query(sql, { domain_uuid = domain_uuid, user = user }, function(row)
        ext_uuid = row.extension_uuid
    end)
    return ext_uuid
end

-- =========================
-- Recording helpers
-- =========================
local function mkdir_p(path)
    -- create nested dirs if not present
    os.execute("mkdir -p " .. path)
end

local function build_record_path_in(domain, uuid, ext)
    ext = ext or "wav"
    local dir = string.format("/var/lib/freeswitch/recordings/%s/archive/%s/%s/%s",
        domain, os.date("%Y"), os.date("%b"), os.date("%d")
    )
    mkdir_p(dir)
    return dir -- .. "/" .. uuid .. "." .. ext
end
local function build_record_path_out(domain, uuid, ext)
    ext = ext or "wav"
    local dir = string.format("/var/lib/freeswitch/recordings/%s/archive/%s/%s/%s",
        domain, os.date("%Y"), os.date("%b"), os.date("%d")
    )
    mkdir_p(dir)
    return dir .. "/" .. uuid .. "." .. ext
end
function enable_recording_if_needed(call_type)
    -- Only record outbound here (you can expand later if needed)
    -- if call_type ~= "outbound" then return end

    -- Optional feature flag: allow disabling per call
    -- (set this variable elsewhere if you want to skip recording)
    local disabled = session:getVariable("recording_disabled")
    if disabled == "true" or disabled == "1" then
        freeswitch.consoleLog("INFO", "[recording] recording_disabled=true, skipping\n")
        return
    end

    local domain = session:getVariable("domain_name") or "default"
    local uuid   = session:getVariable("uuid")
    local rec_ext = session:getVariable("record_ext") or "wav"
    local filename = session:getVariable("record_name") or uuid .. "." .. rec_ext ;
    -- Create dirs + build file
    localrecfile = ""

    -- Recommended vars
    session:setVariable("RECORD_STEREO", "true")
    session:setVariable("recording_follow_transfer", "true")

    -- Start on answer (avoids ringing)
    

    -- Helpful for debugging / CDR
    
    if call_type == "inbound" then
        recfile = build_record_path_in(domain, uuid, rec_ext)
        -- To this:
        session:setVariable("record_path", recfile)
        session:setVariable("record_name", filename)
    -- Set variables as 'sticky' so they survive the bridge to the agent
        session:execute("bridge_export", "record_path=" .. recfile)
        session:execute("bridge_export", "record_name=" .. filename)
    else
        recfile = build_record_path_out(domain, uuid, rec_ext)
        session:setVariable("execute_on_answer", "record_session::" .. recfile)
    end

    -- session:execute("set", "sticky:record_path=" .. recfile)
    -- session:execute("set", "sticky:record_name=" .. filename)

    -- -- Export them to the B-leg (Agent) as well
    -- session:execute("export", "sticky:record_path=" .. recfile)
    -- session:execute("export", "sticky:record_name=" .. filename)

    freeswitch.consoleLog("NOTICE", "[recording] execute_on_answer=record_session::" .. recfile .. "\n")
end

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

local refer_to = session:getVariable("sip_refer_to")
local refer_domain = nil
local refer_extension = nil
if refer_to then
    refer_domain = refer_to:match("@([^%]]+)")
    refer_extension = refer_to:match(":([^@]+)@")
    session:setVariable("refer_domain", refer_domain)
    session:setVariable("refer_extension", refer_extension)
end

freeswitch.consoleLog("info",
    string.format("[routing.lua] Dialed: %s | Domain: %s\n", destination or refer_extension, domain_name or refer_domain or "unknown"))
-- session:execute("info") -- Debug info
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
    domain_uuid = get_domain_uuid(domain_name or refer_domain or "")
    session:setVariable("domain_uuid", domain_uuid)
end

-- =========================
-- Ensure extension_uuid is set for CDR (especially outbound via custom routing.lua)
-- =========================
local src_user = session:getVariable("sip_from_user") or session:getVariable("caller_id_number")

if src_user and domain_uuid then
    local ext_uuid = session:getVariable("extension_uuid")
    if not ext_uuid or ext_uuid == "" then
        ext_uuid = get_extension_uuid(domain_uuid, src_user)
        if ext_uuid and ext_uuid ~= "" then
            session:setVariable("extension_uuid", ext_uuid)
            -- optional but useful for reporting:
            session:setVariable("accountcode", src_user)
            session:setVariable("extension", src_user)
            freeswitch.consoleLog("NOTICE", "[routing.lua] extension_uuid set to " .. ext_uuid .. " for user=" .. src_user .. "\n")
        else
            freeswitch.consoleLog("WARNING", "[routing.lua] Could not resolve extension_uuid for user=" .. tostring(src_user) .. "\n")
        end
    end
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
    return false;
    end

    ------------------------------------------------------------------
    -- Handle failover condition (inactive today)
    ------------------------------------------------------------------
    if route.active_today == "f" or route.active_today == false and  route.failover_destination ~= ""   then
        
            freeswitch.consoleLog("WARNING", "[Routing] DID inactive today (" ..
                (route.time_zone or "local") .. "). Using failover: " ..
                route.destination_type .. " (" .. (route.destination or "unknown") .. ")\n")

            -- Set variables for dialplan or next logsic
            session:setVariable("did_type", route.destination_type or "")
            session:setVariable("did_destination", route.destination or "")

            if route.destination ~= ""  then
            session:execute("transfer", route.destination .. " XML systech")

             else
            session:execute("playback", "ivr/ivr-day_not_allowed.wav")
            session:execute("hangup")
            return false
        end
        
            
            return false
        
    end

    ------------------------------------------------------------------
    -- If active today → proceed normally
    ------------------------------------------------------------------
    session:setVariable("did_type", route.destination_type or "")
    session:setVariable("did_destination", route.destination or "")
    session:setVariable("sip_h_X-Tenant-Domain", route.domain_name)
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
local function dispatch(dest)
    local num_dest = tonumber(dest)
    local valid_did = is_valid_did(dest)
    local domain_uuid = session:getVariable("domain_uuid")

    freeswitch.consoleLog("info", "[routing] call direction " .. tostring(session:getVariable("call_direction")) .. "\n")

    if (session:getVariable("call_direction") == nil) then
        session:setVariable("call_direction", "inbound")
    end

    if valid_did then
        return handlers.handle_did_call(args)
    end

    -- Compute outbound routing only ONCE
    local route_info = outbound_routes.dialoutmatchForoutbound_routes(dest, domain_uuid)

    -- If outbound route matched → handle outbound
    if route_info then
        freeswitch.consoleLog("info", "[routing] Outbound route matched, proceeding with outbound call.\n")
            -- set CDR-friendly fields before outbound bridge
        local dialed = did_destination or session:getVariable("destination_number") or session:getVariable("sip_req_user")
        if dialed and dialed ~= "" then
            session:setVariable("destination_number", dialed)
            session:setVariable("caller_destination", dialed)
            session:setVariable("dialed_number", dialed)
            session:setVariable("original_destination_number", dialed)
        end

        local src_user = session:getVariable("sip_from_user") or session:getVariable("caller_id_number")
        if src_user and src_user ~= "" then
            session:setVariable("source_number", src_user)
        end

        enable_recording_if_needed("outbound")
        freeswitch.consoleLog("info", "[routing.lua] Setting sip_rh_X-FS-UUID " .. session:getVariable("uuid") .. "\n")
        session:setVariable("sip_rh_X-FS-UUID", session:getVariable("uuid"))
        session:setVariable("sip_rh_X-Call-ID", session:getVariable("sip_call_id"))
        return handlers.outbound(args, route_info)
    else
        freeswitch.consoleLog("info", "[routing] No outbound route matched, proceeding with local extensions.\n")   
    end

    -- Local extension ranges
    if (num_dest and num_dest >= 1000 and num_dest <= 3999) or user_based_domain(args) then
        return handlers.extension(args)
    elseif num_dest and num_dest >= 4000 and num_dest <= 5999 then
        return handlers.callcenter(args)
    elseif num_dest and num_dest >= 6000 and num_dest <= 6999 then
        return handlers.ringgroup(args)
    elseif num_dest and num_dest >= 7000 and num_dest <= 8999 then
        return handlers.ivr(args)
        
   --[[  elseif tostring(dest):len() >= 7 and tostring(dest):len() <= 15 then
        -- fallback outbound (no route matched)
        return handlers.outbound(args, nil) ]]
    end

    return false -- No match
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

