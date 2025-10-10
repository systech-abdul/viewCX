-- callcenter_api.lua
local api = freeswitch.API()

local CallCenter = {}

-- Execute and return response from callcenter_config
function CallCenter.execute(cmd)
    local full_cmd = "callcenter_config " .. cmd
    freeswitch.consoleLog("info", "[CALLCENTER] Executing: " .. full_cmd .. "\n")
    local response = api:executeString(full_cmd)
    return response
end

-- ==== AGENT Commands ====

-- Add agent
function CallCenter.add_agent(agent_name, agent_type)
    return CallCenter.execute("agent add " .. agent_name .. " " .. (agent_type or "Callback"))
end



 --callcenter_config agent set
 --[key(contact|status|state|type|max_no_answer|wrap_up_time|ready_time|reject_delay_time|busy_delay_time)]
 --[agent name] 
 --[value]


-- Set agent value
function CallCenter.set_agent(key, agent_name, value)
    return CallCenter.execute("agent set " .. key .. " " .. agent_name .. " " .. value)
end

-- Delete agent
function CallCenter.del_agent(agent_name)
    return CallCenter.execute("agent del " .. agent_name)
end

-- List agent(s)
function CallCenter.list_agent(agent_name)
    return CallCenter.execute("agent list " .. (agent_name or ""))
end

-- Get agent's UUID
function CallCenter.get_agent_uuid(agent_name)
    return CallCenter.execute("agent get uuid " .. agent_name)
end

-- ==== TIER Commands ====

-- Add tier
function CallCenter.add_tier(queue_name, agent_name, level, position)
    local cmd = "tier add " .. queue_name .. " " .. agent_name
    if level then cmd = cmd .. " " .. level end
    if position then cmd = cmd .. " " .. position end
    return CallCenter.execute(cmd)
end


--callcenter_config tier add [queue name] [agent name] [[level]] [[position]]

-- Set tier value
function CallCenter.set_tier(key, queue_name, agent_name, value)
    return CallCenter.execute("tier set " .. key .. " " .. queue_name .. " " .. agent_name .. " " .. value)
end

-- Delete tier
function CallCenter.del_tier(queue_name, agent_name)
    return CallCenter.execute("tier del " .. queue_name .. " " .. agent_name)
end

-- List tiers
function CallCenter.list_tiers()
    return CallCenter.execute("tier list")
end

-- ==== QUEUE Commands ====

-- Load queue
function CallCenter.load_queue(queue_name)
    return CallCenter.execute("queue load " .. queue_name)
end

-- Unload queue
function CallCenter.unload_queue(queue_name)
    return CallCenter.execute("queue unload " .. queue_name)
end

-- Reload queue
function CallCenter.reload_queue(queue_name)
    return CallCenter.execute("queue reload " .. queue_name)
end

-- List queues
function CallCenter.list_queues()
    return CallCenter.execute("queue list")
end

-- List agents in a queue
function CallCenter.list_queue_agents(queue_name, status, state)
    local cmd = "queue list agents " .. queue_name
    if status then cmd = cmd .. " " .. status end
    if state then cmd = cmd .. " " .. state end
    return CallCenter.execute(cmd)
end

-- List members in a queue
function CallCenter.list_queue_members(queue_name)
    return CallCenter.execute("queue list members " .. queue_name)
end

-- List tiers in a queue
function CallCenter.list_queue_tiers(queue_name)
    return CallCenter.execute("queue list tiers " .. queue_name)
end

-- Count queues
function CallCenter.count_queues()
    return CallCenter.execute("queue count")
end

-- Count agents in a queue
function CallCenter.count_queue_agents(queue_name, status)
    local cmd = "queue count agents " .. queue_name
    if status then cmd = cmd .. " " .. status end
    return CallCenter.execute(cmd)
end

-- Count members in a queue
function CallCenter.count_queue_members(queue_name)
    return CallCenter.execute("queue count members " .. queue_name)
end

-- Count tiers in a queue
function CallCenter.count_queue_tiers(queue_name)
    return CallCenter.execute("queue count tiers " .. queue_name)
end

return CallCenter
