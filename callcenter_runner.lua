local cc = require("callcenter_api")

if not argv or #argv == 0 then
    print("Usage: luarun callcenter_runner.lua <action> [params...]")
    return
end

local action = argv[1]
local params = {}

for i = 2, #argv do
    table.insert(params, argv[i])
end

local function print_result(result)
    if not result then
        freeswitch.consoleLog("info", "[CALLCENTER_RUNNER] Result: <nil>\n")
        print("<nil>")
    elseif type(result) == "string" then
        freeswitch.consoleLog("info", "[CALLCENTER_RUNNER] Result:\n" .. result .. "\n")
        print(result)
    else
        local serialized = tostring(result)
        freeswitch.consoleLog("info", "[CALLCENTER_RUNNER] Result: " .. serialized .. "\n")
        print(serialized)
    end
end

local actions = {
    -- AGENT
    add_agent = function() 
        assert(params[1], "missing agent_name")
        return cc.add_agent(params[1], params[2]) 
    end,
    del_agent = function() 
        assert(params[1], "missing agent_name")
        return cc.del_agent(params[1]) 
    end,
    list_agent = function() 
        return cc.list_agent(params[1]) 
    end,
    set_agent = function() 
        assert(params[1] and params[2] and params[3], "missing key, agent_name, or value")
        return cc.set_agent(params[1], params[2], params[3]) 
    end,
    get_agent_uuid = function()
        assert(params[1], "missing agent_name")
        return cc.get_agent_uuid(params[1])
    end,

    -- TIER
    add_tier = function() 
        assert(params[1] and params[2], "missing queue_name or agent_name")
        return cc.add_tier(params[1], params[2], params[3], params[4]) 
    end,
    set_tier = function() 
        assert(params[1] and params[2] and params[3] and params[4], "missing key, queue_name, agent_name, or value")
        return cc.set_tier(params[1], params[2], params[3], params[4]) 
    end,
    del_tier = function() 
        assert(params[1] and params[2], "missing queue_name or agent_name")
        return cc.del_tier(params[1], params[2]) 
    end,
    list_tiers = function() 
        return cc.list_tiers() 
    end,

    -- QUEUE
    load_queue = function() 
        assert(params[1], "missing queue_name")
        return cc.load_queue(params[1]) 
    end,
    unload_queue = function() 
        assert(params[1], "missing queue_name")
        return cc.unload_queue(params[1]) 
    end,
    reload_queue = function() 
        assert(params[1], "missing queue_name")
        return cc.reload_queue(params[1]) 
    end,
    list_queues = function() 
        return cc.list_queues() 
    end,
    list_queue_agents = function() 
        assert(params[1], "missing queue_name")
        return cc.list_queue_agents(params[1], params[2], params[3]) 
    end,
    list_queue_members = function() 
        assert(params[1], "missing queue_name")
        return cc.list_queue_members(params[1]) 
    end,
    list_queue_tiers = function() 
        assert(params[1], "missing queue_name")
        return cc.list_queue_tiers(params[1]) 
    end,
    count_queues = function() 
        return cc.count_queues() 
    end,
    count_queue_agents = function() 
        assert(params[1], "missing queue_name")
        return cc.count_queue_agents(params[1], params[2]) 
    end,
    count_queue_members = function() 
        assert(params[1], "missing queue_name")
        return cc.count_queue_members(params[1]) 
    end,
    count_queue_tiers = function() 
        assert(params[1], "missing queue_name")
        return cc.count_queue_tiers(params[1]) 
    end,
}

local fn = actions[action]
if not fn then
    print("Unknown action: " .. action)
    return
end

local status, result = pcall(fn)
if status then
    print_result(result)
else
    print("Error executing action: " .. tostring(result))
end
