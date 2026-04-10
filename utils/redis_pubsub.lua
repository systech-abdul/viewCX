ub.lua
local redis = require "redis"
local cjson = require "cjson"

local M = {}

-- Connect to Redis
local function get_redis_client()
    local ok, client = pcall(function()
        return redis.connect("127.0.0.1", 6379)
    end)
    if ok and client then
        return client
    else
        freeswitch.consoleLog("ERR", "[redis] Connection failed\n")
        return nil
    end
end

-- Publish DB update for a table + id
function M.publish_update(table_name, id)
    local r = get_redis_client()
    if not r then return end

    local channel = "db_update:" .. table_name
    r:publish(channel, id)
    freeswitch.consoleLog("INFO", "[redis] Published update on " .. channel .. " for " .. id .. "\n")
end

-- Subscribe to table updates
-- callback(id) should handle cache invalidation or refresh
function M.subscribe(table_name, callback)
    local r = get_redis_client()
    if not r then return end

    local channel = "db_update:" .. table_name
    freeswitch.consoleLog("INFO", "[redis] Subscribing to " .. channel .. "\n")

    local sub = r:subscribe(channel)
    while true do
        local msg = sub:read_reply()
        if msg and msg[1] == "message" then
            local id = msg[2]
            freeswitch.consoleLog("INFO", "[redis] Received update for table " .. table_name .. " id=" .. id .. "\n")
            pcall(function() callback(id) end)
        end
    end
end

return M-- redis_pubsub.lua
local redis = require "redis"
local cjson = require "cjson"

local M = {}

-- Connect to Redis
local function get_redis_client()
    local ok, client = pcall(function()
        return redis.connect("127.0.0.1", 6379)
    end)
    if ok and client then
        return client
    else
        freeswitch.consoleLog("ERR", "[redis] Connection failed\n")
        return nil
    end
end

-- Publish DB update for a table + id
function M.publish_update(table_name, id)
    local r = get_redis_client()
    if not r then return end

    local channel = "db_update:" .. table_name
    r:publish(channel, id)
    freeswitch.consoleLog("INFO", "[redis] Published update on " .. channel .. " for " .. id .. "\n")
end

-- Subscribe to table updates
-- callback(id) should handle cache invalidation or refresh
function M.subscribe(table_name, callback)
    local r = get_redis_client()
    if not r then return end

    local channel = "db_update:" .. table_name
    freeswitch.consoleLog("INFO", "[redis] Subscribing to " .. channel .. "\n")

    local sub = r:subscribe(channel)
    while true do
        local msg = sub:read_reply()
        if msg and msg[1] == "message" then
            local id = msg[2]
            freeswitch.consoleLog("INFO", "[redis] Received update for table " .. table_name .. " id=" .. id .. "\n")
            pcall(function() callback(id) end)
        end
    end
end

return M
