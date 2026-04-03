local did_ivrs   = require "routes.did_ivrs"
--local route_action   = require "utils/route_action"

local M = {}

-- You can require dependencies here if needed
-- local some_service = require "services.some_service"

function M.handle(session,dbh, args)
    if not session:ready() then
        return false
    end

    freeswitch.consoleLog("info", "[did_routes] Handling DID call\n")

    session:setVariable("verified_did", "true")

    local did_type        = session:getVariable("did_type") 
                            or session:getVariable("destination_type") 
                            or ""

    local destination     = session:getVariable("v_destination") 
                            or session:getVariable("destination") 
                            or ""

    local did_destination = session:getVariable("did_destination") or ""
    local domain_name     = session:getVariable("domain_name") or ""
    local domain_uuid     = session:getVariable("domain_uuid") or ""

    args.domain = domain_name

    if did_type == "" then
        freeswitch.consoleLog("WARNING", "[did_routes] No did_type\n")
        return false
    end

    if did_destination == "" then
        freeswitch.consoleLog("WARNING", "[did_routes] No did_destination\n")
        return false
    end

    freeswitch.consoleLog(
        "info",
        string.format(
            "[DID ROUTE] domain=%s, type=%s, did_dest=%s, dest=%s\n",
            domain_name, did_type, did_destination, destination or "nil"
        )
    )

    ------------------------------------------------------------------
    -- IVR handling
    ------------------------------------------------------------------
    if did_type == "ivr" then
        did_destination = destination ~= "" and destination or did_destination

        
        if did_ivrs.did_ivrs then
            did_ivrs.did_ivrs(session, dbh,did_destination)
        else
            freeswitch.consoleLog("ERR", "[did_routes] did_ivrs not found\n")
        end

    else
        ------------------------------------------------------------------
        -- Generic routing (extensions, ringgroup, callcenter etc.)
        ------------------------------------------------------------------
        if route_action then
            route_action.route_action(session, dbh,did_type, did_destination, domain_name, domain_uuid, nil)
        else
            freeswitch.consoleLog("ERR", "[did_routes] route_action not found\n")
        end
    end

    return true
end

return M
