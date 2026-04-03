-- routes/ringgroup_routes.lua

local M = {}

function M.handle(session, dbh, args, debug)
    if not session:ready() then
        return false
    end

    local destination = args.destination
    local domain_uuid = args.domain_uuid

    freeswitch.consoleLog("info",
        "[ringgroup_routes] Routing to ring group: " .. tostring(destination) .. "\n")

    if not domain_uuid or not destination then
        freeswitch.consoleLog("err",
            "[ringgroup_routes] Missing domain_uuid or destination\n")
        return false
    end

    ------------------------------------------------------------------
    -- Lookup ring_group_uuid
    ------------------------------------------------------------------
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

    ------------------------------------------------------------------
    -- Debug SQL
    ------------------------------------------------------------------
    if debug and debug["sql"] then
        local json = require "resources.functions.lunajson"

        freeswitch.consoleLog("notice",
            "[ringgroup_routes] SQL: " .. sql ..
            " | Params: " .. json.encode(params) .. "\n")
    end

    dbh:query(sql, params, function(row)
        ring_group_uuid = row.ring_group_uuid
    end)

    if not ring_group_uuid then
        freeswitch.consoleLog("err",
            "[ringgroup_routes] No ring_group found for: " ..
            tostring(destination) .. "\n")
        return false
    end

    ------------------------------------------------------------------
    -- Execute Ring Group App
    ------------------------------------------------------------------
    session:setVariable("ring_group_uuid", ring_group_uuid)

    -- Calls FusionPBX app
    session:execute("lua", "app.lua ring_groups")

    return true
end

return M
