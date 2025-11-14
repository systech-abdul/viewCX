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

    ------------------------------------------------------------------
    -- SQL: include failover_type, failover_destination, and day validity
    ------------------------------------------------------------------
    local sql = [[
        SELECT 
            r.*, 
            r.time_zone, 
            r.failover_type,
            r.failover_destination,
            r.tenant_id,
            r.process_id,
            d.domain_name,
            CASE
                WHEN r.src_regex_pattern = '*' THEN 'matched_star'
                WHEN string_to_array(REPLACE(r.src_regex_pattern, '+', ''), ',')
                     && ARRAY[REPLACE(:src, '+', '')]
                     AND (r.ip_check IS NULL OR r.ip_check = :caller_ip) THEN 'match_both_src_and_caler_ip'
                WHEN string_to_array(REPLACE(r.src_regex_pattern, '+', ''), ',')
                     && ARRAY[REPLACE(:src, '+', '')] THEN 'matched_src'
                ELSE 'no_match'
            END AS match_type,
            --  Check if current day matches in timezone

            CASE
      WHEN r.days IS NULL
           OR r.days = 'null'::jsonb
           OR (jsonb_typeof(r.days) = 'array' AND jsonb_array_length(r.days) = 0)
        THEN true
      WHEN jsonb_typeof(r.days) = 'array' THEN
        EXISTS (
          SELECT 1
          FROM jsonb_array_elements_text(r.days) AS d(day_txt)
          WHERE left(lower(d.day_txt), 3) =
                lower(to_char((CURRENT_TIMESTAMP AT TIME ZONE coalesce(r.time_zone::text,'UTC')), 'Dy'))
        )
      ELSE false
    END AS active_today

        FROM v_did_routes r
        JOIN v_domains d ON d.domain_uuid = r.domain_uuid
        WHERE 
            r.did_num = :dest
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

    ------------------------------------------------------------------
    -- Execute SQL
    ------------------------------------------------------------------
    local found = nil
 

    dbh:query(sql, {
        src = tostring(src),
        dest = tostring(dest),
        caller_ip = tostring(caller_ip)
    }, function(row)
        for k, v in pairs(row) do
            args[k] = v
        end
        found = true

        freeswitch.consoleLog("info", "[Routing] DID found for " .. dest .. "\n")
        freeswitch.consoleLog("info", "[Routing] caller number " .. tostring(caller_id_number) .. "\n")
        freeswitch.consoleLog("info", "[Routing] Time Zone: " .. tostring(row.time_zone) .. "\n")
        freeswitch.consoleLog("console", "[Routing] Active Today: " .. tostring(row.active_today) .. "\n")
        session:setVariable("tenant_id",tostring(row.tenant_id) )
        session:setVariable("process_id",tostring(row.process_id) )
        session:setVariable("domain_name",tostring(row.domain_name) )
        session:setVariable("domain_uuid",tostring(row.domain_uuid) )
        freeswitch.consoleLog("console", "[Routing] domain_name: " .. tostring(row.domain_name) .. "\n")
        freeswitch.consoleLog("console", "[Routing] domain_uuid: " .. tostring(row.domain_uuid) .. "\n")
--[[ 
        if row.failover_destination and row.failover_destination ~= "" then
            freeswitch.consoleLog("info", "[Routing] Failover Number: " .. row.failover_destination .. "\n")
        end ]]
    end)

    ------------------------------------------------------------------
    -- If no DID match at all
    ------------------------------------------------------------------
  if not found then
    freeswitch.consoleLog(
        "warning",
        string.format(
            "[Routing] No DID match found | Dest: %s | Src: %s | SrcIP: %s\n",
            tostring(dest or "nil"),
            tostring(src or "nil"),
            tostring(caller_ip or "nil")
        )
    )
    return false
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
local function upsert_caller_profile()
    if not dbh then
        freeswitch.consoleLog("ERR", "[caller_profile] dbh is nil\n")
        return nil
    end


    local domain_uuid = session:getVariable("domain_uuid") or ""
    local tenant_id = session:getVariable("tenant_id") or 0
    local process_id = session:getVariable("process_id") or 0
    local caller_number = session:getVariable("caller_id_number") or ""
    local last_xml_cdr_uuid = session:getVariable("call_uuid") or ""
    local language_code = session:getVariable("language_code") or ""

    -- IMPORTANT for language behavior:
    --   - nil or ""  => do NOT update language on conflict (as per SQL function)
    --   - non-empty  => update language on conflict

    local sql = [[
        SELECT *
        FROM public.upsert_caller_profile(
            :domain_uuid,
            :tenant_id,
            :process_id,
            :caller_number,
            :last_xml_cdr_uuid,
            :language_code
        )
    ]]

    local row = nil

    freeswitch.consoleLog(
  "info",
  string.format(
    "[caller_profile] domain_uuid=%s, tenant_id=%s, process_id=%s, caller_number=%s, last_xml_cdr_uuid=%s, language_code=%s\n",
    tostring(domain_uuid),
    tostring(tenant_id),
    tostring(process_id),
    tostring(caller_number),
    tostring(last_xml_cdr_uuid),
    tostring(language_code)
  )
)

    local ok = dbh:query(sql, {
        domain_uuid       = domain_uuid,
        tenant_id         = tenant_id,
        process_id        = process_id,
        caller_number     = caller_number,
        last_xml_cdr_uuid = last_xml_cdr_uuid,
        language_code     = language_code,
    }, function(r)
        row = r
    end)

    if not ok then
        freeswitch.consoleLog("ERR", "[caller_profile] DB query failed\n")
        return nil
    end

    if not row then
        freeswitch.consoleLog("ERR", "[caller_profile] no row returned from upsert\n")
        return nil
    end

    session:setVariable("language_code", row.language_code)
    -- optional logging
    freeswitch.consoleLog("INFO", string.format(
        "[caller_profile] caller=%s tenant=%s process=%s calls=%s lang=%s id=%s\n",
        row.caller_number or "nil",
        row.tenant_id or "nil",
        row.process_id or "nil",
        row.call_count or "nil",
        row.language_code or "nil",
        row.id or "nil"
    ))

    return row
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
    local upsert_caller_profile = upsert_caller_profile()

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

