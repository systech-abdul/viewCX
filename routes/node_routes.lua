-- utils/find_matching_condition.lua
local json         = require "resources.functions.lunajson"
local route_action = require "utils.route_action"

local M = {}

--- Find matching condition for IVR nodes
-- @param session      FreeSWITCH session object
-- @param dbh          Database handle
-- @param node_id      IVR condition node ID
-- @param domain_name  Domain name
-- @param domain_uuid  Domain UUID
-- @param ivr_menu_uuid Parent IVR UUID (optional)
function M.find_matching_condition(session, dbh, node_id, domain_name, domain_uuid, ivr_menu_uuid)
    if not node_id then
        freeswitch.consoleLog("ERR", "[find_matching_condition] Missing node_id\n")
        return
    end

    -- 1️⃣ Fetch key-based actions for the node
    local sql = [[
        SELECT key_based_actions
        FROM ivr_condition_node
        WHERE id = :id AND enable = true AND is_active = true
        LIMIT 1;
    ]]
    local params = { id = node_id }
    local condition_json

    dbh:query(sql, params, function(row)
        condition_json = row.key_based_actions
    end)

    if not condition_json or condition_json == "" or condition_json == "null" then
        freeswitch.consoleLog("ERR", "[find_matching_condition] No key_based_actions for node_id " .. tostring(node_id) .. "\n")
        return
    end

    -- 2️⃣ Fetch current call variables
    local call_uuid = session:getVariable("call_uuid")
    local var_sql = [[
        SELECT variables
        FROM call_ivr_journeys
        WHERE call_uuid = :uuid AND domain_uuid = :domain_uuid
        LIMIT 1;
    ]]
    local var_params = { uuid = call_uuid, domain_uuid = domain_uuid }
    local variable_json = "{}"

    dbh:query(var_sql, var_params, function(row)
        variable_json = row.variables
    end)

    -- Decode JSON
    local key_actions = json.decode(condition_json)
    local variables   = json.decode(variable_json)

    -- 3️⃣ Condition matching
    local function is_match(value, condition, expected)
        value    = tostring(value):lower()
        expected = tostring(expected):lower()
        if condition == "equal" then
            return value == expected
        elseif condition == "contains" then
            return string.find(value, expected, 1, true) ~= nil
        else
            return false
        end
    end

    local function get_matching_action(key_actions, variables)
        for _, rule in ipairs(key_actions) do
            local key       = rule.key
            local expected  = rule.string
            local condition = rule.condition
            if variables[key] ~= nil then
                local value = variables[key]
                if is_match(value, condition, expected) then
                    return rule
                end
            end
        end
        return nil
    end

    -- 4️⃣ Execute matched action
    local matched = get_matching_action(key_actions, variables)
    if matched then
        freeswitch.consoleLog("INFO", "[find_matching_condition] Matched Rule: " .. json.encode(matched) .. "\n")
        route_action.route_action(session, dbh, matched.action, matched.destination, domain_name, domain_uuid, ivr_menu_uuid)
    else
        freeswitch.consoleLog("INFO", "[find_matching_condition] No matching rule found for node_id " .. tostring(node_id) .. "\n")
    end
end

return M
