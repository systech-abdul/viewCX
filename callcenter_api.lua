local api = freeswitch.API()
local Database = require "resources.functions.database"
local dbh = Database.new("system")
assert(dbh:connected())

local CallCenter = {}

-- Generate a UUID using FreeSWITCH API (synchronous)
local function uuid()
    return api:executeString("create_uuid")
end

-- Execute a SQL query with logging and error check
local function execute(sql)
    freeswitch.consoleLog("info", "[CallCenter] SQL: " .. sql .. "\n")
    local res, err = dbh:query(sql)
    if not res then
        freeswitch.consoleLog("err", "[CallCenter] SQL ERROR: " .. tostring(err) .. "\n")
        error(err)
    end
    return res
end

-- Helper to build and execute callcenter_config commands
local function exec(cmd, ...)
    local args = {...}
    local full_cmd = "callcenter_config " .. cmd
    if #args > 0 then
        full_cmd = full_cmd .. " " .. table.concat(args, " ")
    end
    freeswitch.consoleLog("info", "[CALLCENTER] Executing: " .. full_cmd .. "\n")
    return api:executeString(full_cmd)
end

-- ==== AGENT Commands ====

function CallCenter.add_agent(agent_name, agent_type)
    if not agent_name or agent_name == "" then
        return "Error: agent_name is required"
    end
    agent_type = agent_type or "callback"

    -- Add agent to FreeSWITCH CallCenter
    local res = exec("agent add", agent_name, agent_type)

    -- Add agent to database
    local agent_uuid = uuid()
    local sql = string.format([[
        INSERT INTO v_call_center_agents (
            call_center_agent_uuid, agent_name, agent_type, agent_status, agent_record, insert_date
        ) VALUES (
            '%s', '%s', '%s', 'Available', 'true', NOW()
        )
    ]], agent_uuid, agent_name, agent_type)
    execute(sql)

    return res
end

function CallCenter.set_agent(key, agent_name, value)
    if not key or not agent_name or not value then
        return "Error: key, agent_name and value are required"
    end

    local res = exec("agent set", key, agent_name, value)

    -- Update DB for agent accordingly (simple example for a few keys)
    local update_fields = {
        contact = "agent_contact",
        status = "agent_status",
        type = "agent_type",
        max_no_answer = "agent_max_no_answer",
        wrap_up_time = "agent_wrap_up_time",
        reject_delay_time = "agent_reject_delay_time",
        busy_delay_time = "agent_busy_delay_time"
    }
    local field = update_fields[key]
    if field then
        local sql = string.format([[
            UPDATE v_call_center_agents
            SET %s = '%s', update_date = NOW()
            WHERE agent_name = '%s'
        ]], field, value, agent_name)
        execute(sql)
    end

    return res
end

function CallCenter.del_agent(agent_name)
    if not agent_name then return "Error: agent_name is required" end

    local res = exec("agent del", agent_name)

    -- Delete from DB
    local sql = string.format([[
        DELETE FROM v_call_center_agents WHERE agent_name = '%s'
    ]], agent_name)
    execute(sql)

    return res
end

function CallCenter.list_agent(agent_name)
    return exec("agent list", agent_name or "")
end

function CallCenter.get_agent_uuid(agent_name)
    if not agent_name then return "Error: agent_name is required" end
    return exec("agent get uuid", agent_name)
end

-- ==== TIER Commands ====

function CallCenter.add_tier(queue_name, agent_name, level, position)
    if not queue_name or not agent_name then
        return "Error: queue_name and agent_name are required"
    end

    local res = exec("tier add", queue_name, agent_name, level or "", position or "")

    -- Add tier to DB
    local tier_uuid = uuid()

    -- Fetch agent UUID and queue UUID for DB references
    local agent_uuid = nil
    local queue_uuid = nil

    -- Get agent UUID
    local agent_sql = string.format("SELECT call_center_agent_uuid FROM v_call_center_agents WHERE agent_name = '%s'", agent_name)
    dbh:query(agent_sql, function(row)
        agent_uuid = row.call_center_agent_uuid
    end)

    -- Get queue UUID
    local queue_sql = string.format("SELECT call_center_queue_uuid FROM v_call_center_queues WHERE queue_name = '%s'", queue_name)
    dbh:query(queue_sql, function(row)
        queue_uuid = row.call_center_queue_uuid
    end)

    -- Wait briefly to ensure UUIDs are fetched (basic busy wait)
    local tries = 0
    while (not agent_uuid or not queue_uuid) and tries < 10 do
        freeswitch.msleep(10)
        tries = tries + 1
    end
    if not agent_uuid or not queue_uuid then
        freeswitch.consoleLog("err", "[CallCenter] Failed to fetch UUIDs for tier add\n")
        return res
    end

    local sql = string.format([[
        INSERT INTO v_call_center_tiers (
            call_center_tier_uuid, call_center_queue_uuid, call_center_agent_uuid,
            agent_name, queue_name, tier_level, tier_position, insert_date, flag
        ) VALUES (
            '%s', '%s', '%s', '%s', '%s', %s, %s, NOW(), 1
        )
    ]], tier_uuid, queue_uuid, agent_uuid, agent_name, queue_name, level or 0, position or 0)
    execute(sql)

    return res
end

function CallCenter.set_tier(key, queue_name, agent_name, value)
    if not key or not queue_name or not agent_name or not value then
        return "Error: key, queue_name, agent_name and value are required"
    end

    local res = exec("tier set", key, queue_name, agent_name, value)

    -- Update DB for tier accordingly
    local update_fields = {
        level = "tier_level",
        position = "tier_position",
        flag = "flag"
    }
    local field = update_fields[key]
    if field then
        local sql = string.format([[
            UPDATE v_call_center_tiers
            SET %s = %s, update_date = NOW()
            WHERE queue_name = '%s' AND agent_name = '%s'
        ]], field, tonumber(value) or ("'" .. value .. "'"), queue_name, agent_name)
        execute(sql)
    end

    return res
end

function CallCenter.del_tier(queue_name, agent_name)
    if not queue_name or not agent_name then
        return "Error: queue_name and agent_name are required"
    end

    local res = exec("tier del", queue_name, agent_name)

    -- Delete from DB
    local sql = string.format([[
        DELETE FROM v_call_center_tiers WHERE queue_name = '%s' AND agent_name = '%s'
    ]], queue_name, agent_name)
    execute(sql)

    return res
end

function CallCenter.list_tiers()
    return exec("tier list")
end

-- ==== QUEUE Commands ====

function CallCenter.load_queue(queue_name)
    if not queue_name then return "Error: queue_name is required" end
    local res = exec("queue load", queue_name)

    -- Optionally insert or update queue in DB
    -- This assumes you have the queue details — can expand here if needed

    return res
end

function CallCenter.unload_queue(queue_name)
    if not queue_name then return "Error: queue_name is required" end
    local res = exec("queue unload", queue_name)

    -- Optionally delete queue from DB if needed

    return res
end

function CallCenter.reload_queue(queue_name)
    if not queue_name then return "Error: queue_name is required" end
    return exec("queue reload", queue_name)
end

function CallCenter.list_queues()
    return exec("queue list")
end

function CallCenter.list_queue_agents(queue_name, status, state)
    if not queue_name then return "Error: queue_name is required" end
    local args = {queue_name}
    if status then table.insert(args, status) end
    if state then table.insert(args, state) end
    return exec("queue list agents", table.unpack(args))
end

function CallCenter.list_queue_members(queue_name)
    if not queue_name then return "Error: queue_name is required" end
    return exec("queue list members", queue_name)
end

function CallCenter.list_queue_tiers(queue_name)
    if not queue_name then return "Error: queue_name is required" end
    return exec("queue list tiers", queue_name)
end

function CallCenter.count_queues()
    return exec("queue count")
end

function CallCenter.count_queue_agents(queue_name, status)
    if not queue_name then return "Error: queue_name is required" end
    if status then
        return exec("queue count agents", queue_name, status)
    else
        return exec("queue count agents", queue_name)
    end
end

function CallCenter.count_queue_members(queue_name)
    if not queue_name then return "Error: queue_name is required" end
    return exec("queue count members", queue_name)
end

function CallCenter.count_queue_tiers(queue_name)
    if not queue_name then return "Error: queue_name is required" end
    return exec("queue count tiers", queue_name)
end

return CallCenter



--------agent operation ---------------------
--[[

CallCenter Runner CLI Commands & Examples
Agent Commands

Action	Command Example	Description

Add Agent	
fs_cli -x "luarun callcenter_runner.lua add_agent 1001"	Add agent with default type "Callback"

Delete Agent	
fs_cli -x "luarun callcenter_runner.lua del_agent 1001"	Delete agent 1001

List Agent	
fs_cli -x "luarun callcenter_runner.lua list_agent"	List all agents

List Agent	
fs_cli -x "luarun callcenter_runner.lua list_agent 1001"	List specific agent 1001

Set Agent	
fs_cli -x "luarun callcenter_runner.lua set_agent contact 1001 'user/2008@cc.systech.ae'"	Set contact field of agent 1001

Get Agent UUID	
fs_cli -x "luarun callcenter_runner.lua get_agent_uuid 1001"	Get UUID of bridged agent

Tier Commands
Action	Command Example	Description

Add Tier	
fs_cli -x "luarun callcenter_runner.lua add_tier 4003@cc.systech.ae 1001 1 1"	Add agent 1001 to queue support_queue with level=1 position=1

Delete Tier	
fs_cli -x "luarun callcenter_runner.lua del_tier 4003@cc.systech.ae 1001"	Delete agent 1001 from queue support_queue

List Tiers	
fs_cli -x "luarun callcenter_runner.lua list_tiers"	List all tiers

Set Tier	
fs_cli -x "luarun callcenter_runner.lua set_tier state  10014003@cc.systech.ae Ready"	Set agent 1001 state in queue support_queue to "Ready"
Queue Commands
Action	Command Example	Description

Load Queue	
fs_cli -x "luarun callcenter_runner.lua load_queue 4003@cc.systech.ae"	Load queue named 4003@cc.systech.ae

Unload Queue	
fs_cli -x "luarun callcenter_runner.lua unload_queue 4003@cc.systech.ae"	Unload queue 4003@cc.systech.ae

Reload Queue	
fs_cli -x "luarun callcenter_runner.lua reload_queue 4003@cc.systech.ae"	Reload queue 4003@cc.systech.ae

List Queues	
fs_cli -x "luarun callcenter_runner.lua list_queues"	List all configured queues

List Queue Agents	
fs_cli -x "luarun callcenter_runner.lua list_queue_agents 4003@cc.systech.ae"	List agents in 4003@cc.systech.ae

List Queue Agents	
fs_cli -x "luarun callcenter_runner.lua list_queue_agents 4003@cc.systech.ae Ready"	List ready agents in queue

List Queue Members	
fs_cli -x "luarun callcenter_runner.lua list_queue_members 4003@cc.systech.ae"	List callers in 4003@cc.systech.ae

List Queue Tiers	
fs_cli -x "luarun callcenter_runner.lua list_queue_tiers 4003@cc.systech.ae"	List tiers in 4003@cc.systech.ae

Count Queues	
fs_cli -x "luarun callcenter_runner.lua count_queues"	Count total number of queues

Count Queue Agents	
fs_cli -x "luarun callcenter_runner.lua count_queue_agents 4003@cc.systech.ae"	Count agents in queue

Count Queue Agents	
fs_cli -x "luarun callcenter_runner.lua count_queue_agents 4003@cc.systech.ae Ready"	Count ready agents in queue

Count Queue Members	
fs_cli -x "luarun callcenter_runner.lua count_queue_members 4003@cc.systech.ae"	Count callers in queue

Count Queue Tiers	
fs_cli -x "luarun callcenter_runner.lua count_queue_tiers 4003@cc.systech.ae" 

]]