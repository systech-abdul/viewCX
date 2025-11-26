-- handlers/outbound.lua
local Database = require "resources.functions.database"
local json = require "resources.functions.lunajson"
local api = freeswitch.API()

-- Connect to the database once
local dbh = Database.new("system")
assert(dbh:connected(), "Database connection failed")

-- Debug table
local debug = { sql = false }

-- Helper: Convert custom patterns to Lua patterns
local function pattern_to_lua(pattern)
    if not pattern then return ".*" end
    pattern = pattern:gsub("%*", ".*")   -- * -> any length
    pattern = pattern:gsub("X", "%%d")   -- X -> one digit
    return "^" .. pattern .. "$"
end

-- Helper: Pick a random DID from did_pool JSON
local function pick_random_did(did_pool_json)
    if not did_pool_json or did_pool_json == "" then return nil end
    local clean = did_pool_json:gsub("^%s*(.-)%s*$", "%1") -- trim whitespace
    local ok, dids = pcall(json.decode, clean)
    if not ok or type(dids) ~= "table" or #dids == 0 then
        return nil
    end
    local index = math.random(1, #dids)
    return dids[index]
end

-- Apply dynamic values actions to session
local function apply_dynamic_actions(route)
    if not route.dynamic_values_actions or route.dynamic_values_actions == '' then return end
    local ok, actions = pcall(json.decode, route.dynamic_values_actions)
    if not ok or type(actions) ~= "table" then return end

    for _, act in ipairs(actions) do
        if act.enabled and act.action then
            local a_type = act.action.type
            local data = act.action.data or {}
            for k, v in pairs(data) do
                if a_type == "set" then
                    session:setVariable(k, v)
                elseif a_type == "unset" then
                    session:unsetVariable(k)
                elseif a_type == "export" then
                    session:execute("export", string.format("%s=%s", k, tostring(v)))
                end
            end
        end
    end
end

-- Main function: match outbound routes, pick DID, apply dynamic actions

   local function dialoutmatchForoutbound_routes(number, domain_uuid)
    if not number or not domain_uuid then
        return nil
    end

    -- Fetch all enabled outbound routes for this domain
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
        --[[ freeswitch.consoleLog("info",
            string.format("[handlers.outbound_routes] SQL returned route %s: id=%s, name=%s, pattern=%s, gateway_uuid=%s, did_pool=%s\n",
            #routes, row.id, row.name, row.pattern, row.gateway_uuid, row.did_pool or "nil")) ]]
    end)

    -- Sort by pattern specificity: longer patterns first, then priority
    table.sort(routes, function(a, b)
        local len_a = a.pattern and #a.pattern or 0
        local len_b = b.pattern and #b.pattern or 0
        if len_a ~= len_b then
            return len_a > len_b
        else
            return (a.priority or 0) < (b.priority or 0)
        end
    end)

    -- Iterate routes
    for _, route in ipairs(routes) do
        local lua_pattern = pattern_to_lua(route.pattern)
        if route.allowed_prefix and #route.allowed_prefix > 0 then
            lua_pattern = "^" .. route.allowed_prefix .. lua_pattern:sub(2)
        end

        freeswitch.consoleLog("notice",
            string.format("[handlers.outbound_routes] Checking route: %s | pattern: %s | lua_pattern: %s | number: %s\n",
            route.name, route.pattern, lua_pattern, number))

        if number:match(lua_pattern) then
            local stripped_number = number
            if route.strip and tonumber(route.strip) > 0 then
                stripped_number = number:sub(tonumber(route.strip) + 1)
            end

            -- Pick random DID
            local did = pick_random_did(route.did_pool)

            -- Apply dynamic values actions
            apply_dynamic_actions(route)

            freeswitch.consoleLog("info",
                string.format("[handlers.outbound_routes] via route '%s', stripped_number: %s, picked DID: %s\n",
                route.name or route.id, stripped_number, did or "nil"))

            return {
                route = route,
                dial_number = stripped_number,
                did = did
            }
        end
    end

    return nil
end


-- Return module
return {
    dialoutmatchForoutbound_routes = dialoutmatchForoutbound_routes,
    apply_dynamic_actions = apply_dynamic_actions,
    pick_random_did = pick_random_did
}
