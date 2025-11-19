-- handlers/outbound.lua
local Database = require "resources.functions.database"
local json = require "resources.functions.lunajson"
local api = freeswitch.API()

-- Connect to the database once
local dbh = Database.new("system")
assert(dbh:connected())

-- Debug table
local debug = {}
debug["sql"] = false

-- Helper: Convert custom patterns to Lua patterns
local function pattern_to_lua(pattern)
    pattern = pattern:gsub("%*", ".*")   -- * -> any length
    pattern = pattern:gsub("X", "%%d")   -- X -> one digit
    return "^" .. pattern .. "$"
end

-- Main function: match outbound routes
local function dialoutmatchForoutbound_routes(number, domain_uuid)
    if not number or not domain_uuid then
        return nil
    end

    local sql = [[
        SELECT *
        FROM outbound_routes
        WHERE domain_uuid = :domain_uuid
          AND enabled = TRUE
        ORDER BY priority ASC, id ASC
    ]]

    local routes = {}
    dbh:query(sql, {domain_uuid = domain_uuid}, function(row)
        table.insert(routes, row)
    end)

    -- Iterate routes by priority
    for _, route in ipairs(routes) do
        local lua_pattern = pattern_to_lua(route.pattern)

        -- Prepend allowed prefix if exists
        if route.allowed_prefix and #route.allowed_prefix > 0 then
            lua_pattern = "^" .. route.allowed_prefix .. lua_pattern:sub(2)
        end

        -- Match number
        if number:match(lua_pattern) then
            local stripped_number = number
            if route.strip and tonumber(route.strip) > 0 then
                stripped_number = number:sub(tonumber(route.strip) + 1)
            end

            return {
                route = route,
                dial_number = stripped_number
            }
        end
    end

    return nil
end

-- Function to perform outbound dial
local function outbound(args)
    local destination = args.destination
    local domain_uuid = args.domain_uuid

    if not destination or not domain_uuid then
        freeswitch.consoleLog("err", "[handlers.outbound] Missing destination or domain_uuid\n")
        return false
    end

    local match = dialoutmatchForoutbound_routes(destination, domain_uuid)

    if not match then
        freeswitch.consoleLog("warning",
            string.format("[handlers.outbound] No outbound route for %s | domain_uuid: %s\n",
            tostring(destination), tostring(domain_uuid)))
        session:execute("playback", "ivr/ivr-no_route_destination.wav")
        return false
    end

    local dial_number = match.dial_number
    local route = match.route

    freeswitch.consoleLog("info",
        string.format("[handlers.outbound] Routing %s via route %s, stripped_number: %s\n",
        destination, route.id, dial_number))

    -- Set session variables for dialplan
    session:setVariable("outbound_route_id", route.id)
    session:setVariable("outbound_route_name", route.name or "")
    session:setVariable("dial_number", dial_number)

    -- Example: Dial using gateway (assumes route.gateway exists)
    if route.gateway then
        local dial_string = string.format("%s/%s", route.gateway, dial_number)
        freeswitch.consoleLog("info", "[handlers.outbound] Dial string: " .. dial_string .. "\n")
        session:execute("bridge", dial_string)
        return true
    else
        freeswitch.consoleLog("err", "[handlers.outbound] No gateway configured for this route\n")
        session:execute("playback", "ivr/ivr-no_route_destination.wav")
        return false
    end
end

-- Return module
return {
    dialoutmatchForoutbound_routes = dialoutmatchForoutbound_routes,
    outbound = outbound
}
