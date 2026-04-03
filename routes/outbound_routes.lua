-- routes/outbound_routes.lua

local M = {}

function M.handle(session, dbh, args, route_info)
    if not session:ready() then
        return false
    end

    session:setVariable("direction", "outbound")
    session:setVariable("call_direction", "outbound")

    local domain_uuid = session:getVariable("domain_uuid")
    local dest = session:getVariable("destination_number")
    local preferred_gateway_uuid = session:getVariable("preferred_gateway_uuid")

    freeswitch.consoleLog("info",
        string.format("[outbound_routes] Dest: %s | Domain UUID: %s\n",
        tostring(dest), tostring(domain_uuid)))

    local gateways = {}
    local dial_number = dest

    ------------------------------------------------------------------
    -- Priority 1: Preferred Gateway
    ------------------------------------------------------------------
    if preferred_gateway_uuid and preferred_gateway_uuid ~= "" then
        table.insert(gateways, preferred_gateway_uuid)

        freeswitch.consoleLog("info",
            "[outbound_routes] Using preferred gateway: " .. preferred_gateway_uuid .. "\n")

    ------------------------------------------------------------------
    -- Priority 2: Route Info
    ------------------------------------------------------------------
    elseif route_info then
        dial_number = route_info.dial_number

        if route_info.did then
            session:setVariable("caller_id_number", route_info.did)

            freeswitch.consoleLog("info",
                "[outbound_routes] Using DID: " .. route_info.did .. "\n")
        end

        local route = route_info.route

        table.insert(gateways, route.gateway_uuid)

        if route.alternate1_gateway_uuid and route.alternate1_gateway_uuid ~= "" then
            table.insert(gateways, route.alternate1_gateway_uuid)
        end

        if route.alternate2_gateway_uuid and route.alternate2_gateway_uuid ~= "" then
            table.insert(gateways, route.alternate2_gateway_uuid)
        end

    ------------------------------------------------------------------
    -- Priority 3: DB Fallback
    ------------------------------------------------------------------
    else
        local sql = [[
            SELECT gateway_uuid
            FROM v_gateways
            WHERE domain_uuid = :domain_uuid
            ORDER BY gateway_uuid
            LIMIT 1
        ]]

        dbh:query(sql, { domain_uuid = domain_uuid }, function(row)
            if row.gateway_uuid then
                table.insert(gateways, row.gateway_uuid)
            end
        end)

        if #gateways == 0 then
            freeswitch.consoleLog("ERR", "[outbound_routes] No gateways found\n")
            session:execute("playback", "ivr/ivr-no_route_destination.wav")
            return false
        end
    end

    ------------------------------------------------------------------
    -- Build Bridge String
    ------------------------------------------------------------------
    local bridge_list = {}

    for _, gw in ipairs(gateways) do
        table.insert(bridge_list,
            string.format("sofia/gateway/%s/%s", gw, dial_number))
    end

    local bridge_dest = table.concat(bridge_list, "|")

    freeswitch.consoleLog("info",
        "[outbound_routes] Bridge => " .. bridge_dest .. "\n")

    ------------------------------------------------------------------
    -- Execute Bridge
    ------------------------------------------------------------------
    session:execute("bridge", bridge_dest)

    return true
end

return M
