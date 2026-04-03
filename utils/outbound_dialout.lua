-- handlers/outbound.lua
local Database = require "resources.functions.database"
local json = require "resources.functions.lunajson"
local api = freeswitch.API()

-- Connect to DB
local dbh = Database.new("system")
assert(dbh:connected(), "Database connection failed")

---------------------------------------------------------
-- Convert custom outbound route pattern → Lua pattern
---------------------------------------------------------
local function pattern_to_lua(pattern)
    if not pattern then return ".*" end

    pattern = pattern:gsub("%*", ".*")   -- * → any length
    pattern = pattern:gsub("X", "%%d")   -- X → one digit

    return "^" .. pattern .. "$"
end

---------------------------------------------------------
-- Pick random DID from did_pool JSON
---------------------------------------------------------
local function pick_random_did(did_pool_json)
    if not did_pool_json or did_pool_json == "" then return nil end

    local clean = did_pool_json:gsub("^%s*(.-)%s*$", "%1")
    local ok, dids = pcall(json.decode, clean)

    if not ok or type(dids) ~= "table" or #dids == 0 then
        return nil
    end

    return dids[math.random(1, #dids)]
end

---------------------------------------------------------
-- Apply dynamic actions on session
---------------------------------------------------------
local function apply_dynamic_actions(route)
    if not route.dynamic_values_actions or route.dynamic_values_actions == "" then return end

    local ok, actions = pcall(json.decode, route.dynamic_values_actions)
    if not ok or type(actions) ~= "table" then return end

    for _, act in ipairs(actions) do
        if act.enabled and act.action then
            local t = act.action.type
            local data = act.action.data or {}

            for k, v in pairs(data) do
                if t == "set" then
                    session:setVariable(k, v)
                elseif t == "unset" then
                    session:unsetVariable(k)
                elseif t == "export" then
                    session:execute("export", string.format("%s=%s", k, tostring(v)))
                end
            end
        end
    end
end

---------------------------------------------------------
-- MAIN outbound matcher
---------------------------------------------------------
local function dialoutmatchForoutbound_routes(number, domain_uuid)
    if not number or not domain_uuid then return nil end

    ---------------------------------------------------------
    -- Fetch routes for domain
    ---------------------------------------------------------
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

    ---------------------------------------------------------
    -- Sort by longest pattern first, then by priority    
    ---------------------------------------------------------
    table.sort(routes, function(a, b)
        local len_a = a.pattern and #a.pattern or 0
        local len_b = b.pattern and #b.pattern or 0

        if len_a ~= len_b then
            return len_a > len_b
        end

        return (a.priority or 0) < (b.priority or 0)
    end)

    ---------------------------------------------------------
    -- Try each route for pattern match
    ---------------------------------------------------------
    for _, route in ipairs(routes) do

        local lua_pattern = pattern_to_lua(route.pattern)

        freeswitch.consoleLog("notice",
            string.format(
                "[handlers.outbound_routes] Checking route: %s | pattern: %s | lua_pattern: %s | number: %s\n",
                route.name, route.pattern, lua_pattern, number
            )
        )

        -----------------------------------------------------
        -- FIRST: match number with pattern only
        -----------------------------------------------------
        if number:match(lua_pattern) then

            -----------------------------------------------------
            -- STEP 1 — Apply allowed_prefix BEFORE strip
            -- Example:
            --   number = 91XXXXXXXXXX
            --   prefix = ++
            --   final_before_strip = ++91XXXXXXXXXX
            -----------------------------------------------------
            local dial_number = number

            if route.allowed_prefix and route.allowed_prefix ~= "" then
                dial_number = route.allowed_prefix .. number
            end

            -----------------------------------------------------
            -- STEP 2 — Apply strip to FINAL STRING (prefix included)
            -- strip = 1 → remove 1 char from LEFT:
            --   ++91XXXXXXXXXX → +91XXXXXXXXXX
            -----------------------------------------------------
            if route.strip and tonumber(route.strip) > 0 then
                local s = tonumber(route.strip)
                dial_number = dial_number:sub(s + 1)
            end

            -----------------------------------------------------
            -- STEP 3 — Pick DID
            -----------------------------------------------------
            local did = pick_random_did(route.did_pool)

            -----------------------------------------------------
            -- STEP 4 — Dynamic actions
            -----------------------------------------------------
            apply_dynamic_actions(route)

            -----------------------------------------------------
            -- Logging
            -----------------------------------------------------
            freeswitch.consoleLog("info",
                string.format(
                    "[handlers.outbound_routes] MATCH route '%s' | FINAL DIAL: %s | DID: %s\n",
                    route.name or route.id, dial_number, did or "nil"
                )
            )

            -----------------------------------------------------
            -- Return final decision
            -----------------------------------------------------
            return {
                route       = route,
                dial_number = dial_number,
                did         = did
            }
        end
    end

    return nil
end

---------------------------------------------------------
-- EXPORT
---------------------------------------------------------
return {
    dialoutmatchForoutbound_routes = dialoutmatchForoutbound_routes,
    apply_dynamic_actions          = apply_dynamic_actions,
    pick_random_did                = pick_random_did
}
