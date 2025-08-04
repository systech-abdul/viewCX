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
    session:execute("lua", "/usr/share/freeswitch/scripts/app/ring_groups/index.lua")

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
    local modified_ivr_id = args.modified_ivr_id or destination
    local visited = args.visited_ivr or {}

    counter = counter or {
        count = 0
    }

    freeswitch.consoleLog("info", "[handlers.ivr] Routing to IVR: " .. tostring(destination) .. "\n")


    return true
end

-- Outbound (others)
function handlers.outbound(args)
    if not check_session() then
        return false
    end

    local domain_uuid = args.domain_uuid

    freeswitch.consoleLog("info",
        "[handlers.outbound] Routing outbound to: " .. tostring(args.destination) .. "d_uuid " ..
            tostring(args.domain_uuid) .. "\n")

    local sql = [[
        SELECT gateway_uuid
        FROM v_gateways
        WHERE  domain_uuid = :domain_uuid
        LIMIT 1
    ]]
    local params = {
        domain_uuid = domain_uuid
    }

    -- Optional SQL debug
    if (debug["sql"]) then
        local json = require "resources.functions.lunajson"
        freeswitch.consoleLog("notice",
            "[handlers.outbound] SQL: " .. sql .. " | Params: " .. json.encode(params) .. "\n")
    end

    dbh:query(sql, params, function(row)
        args.gateway_uuid = row.gateway_uuid
    end)

    if not args.gateway_uuid then
        freeswitch.consoleLog("err", "[handlers.outbound] Missing gateway_uuid\n")
        return false
    end

    local bridge_dest = "{media_mix_inbound_outbound_codecs=true,ignore_early_media=true}sofia/gateway/" ..
                            args.gateway_uuid .. "/" .. args.destination
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

return handlers
