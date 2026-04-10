local Database = require "resources.functions.database"

local sticky_agent = {}

-- Route a call to sticky agent
-- Returns: agent_name, agent_id, available, fallback_action, fallback_destination
function sticky_agent.route(session)
    if not session then return nil end

    local caller = session:getVariable("caller_id_number")
    local domain_uuid = session:getVariable("domain_uuid")

    local dbh = Database.new("system")
    assert(dbh:connected())

    -- Lookup sticky agent
    local sql = [[
        SELECT a.agent_name, a.call_center_agent_uuid AS agent_id,
               s.fallback_action, s.fallback_destination
        FROM sticky_agent_map s
        JOIN v_call_center_agents a
          ON s.agent_id = a.call_center_agent_uuid
        WHERE s.caller_number = :caller
          AND s.domain_uuid = :domain_uuid
        LIMIT 1
    ]]

    
    local agent_name, agent_id, fallback_action, fallback_destination
    dbh:query(sql, { caller = caller, domain_uuid = domain_uuid }, function(row)
        agent_name = row.agent_name
        agent_id = row.agent_id
        fallback_action = row.fallback_action
        fallback_destination = row.fallback_destination
    end)
    
    freeswitch.consoleLog("INFO","[Sticky agent]  : " .. agent_name .. "\n")
    
    -- Check agent availability
    local available = false
    if agent_id then
        local status = freeswitch.API():executeString("callcenter_config agent get status " .. agent_id)
        local state  = freeswitch.API():executeString("callcenter_config agent get state " .. agent_id)
        if status:match("Available") and state:match("Waiting") then
            available = true
        end
    end

    dbh:release()

    return agent_name, agent_id, available, fallback_action, fallback_destination
end

return sticky_agent