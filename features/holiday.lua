local M = {}

------------------------------------------------------------
-- logger
------------------------------------------------------------
local function log(level, msg)
    freeswitch.consoleLog(level or "info", "[holiday] " .. tostring(msg) .. "\n")
end

------------------------------------------------------------
-- SINGLE QUERY: Find active holiday (NEW SCHEMA + tz_now FIX)
------------------------------------------------------------
function M.get_holiday(dbh, domain_uuid)

    local sql = [[
        SELECT
            id,
            domain_uuid,
            holiday_date,
            end_date,
            holiday_name,
            start_time,
            end_time,
            is_recurring,
            recurrence_rule,
            timezone,
            (NOW() AT TIME ZONE COALESCE(timezone, 'UTC')) AS tz_now,
            priority,
            action_type,
            action_data
        FROM tenant_holidays
        WHERE domain_uuid = :domain_uuid
          AND is_active = true
          AND (
                (
                    is_recurring = true
                    AND EXTRACT(MONTH FROM holiday_date) =
                        EXTRACT(MONTH FROM (NOW() AT TIME ZONE COALESCE(timezone,'UTC')))
                    AND EXTRACT(DAY FROM holiday_date) =
                        EXTRACT(DAY FROM (NOW() AT TIME ZONE COALESCE(timezone,'UTC')))
                )
                OR
                (
                    is_recurring = false
                    AND (
                        (NOW() AT TIME ZONE COALESCE(timezone,'UTC'))::date
                        BETWEEN holiday_date AND COALESCE(end_date, holiday_date)
                    )
                )
          )
        ORDER BY priority DESC
        LIMIT 1;
    ]]

    local row

    dbh:query(sql, { domain_uuid = domain_uuid }, function(r)
        row = r
    end)

    return row
end

------------------------------------------------------------
-- SAFE ROUTER
------------------------------------------------------------
local function safe_route(session, dbh, action_type, action_data, domain_name, domain_uuid)

    if not session:ready() then
        log("err", "Session not ready")
        return false
    end

    if not action_type or action_type == "" then
        log("err", "Missing action_type")
        return false
    end

    log("info", "Holiday action -> " .. action_type .. "\t action_data -> " .. action_data)

    local route_action = require "utils.route_action"

    route_action.route_action(session,dbh,action_type,action_data,domain_name,domain_uuid)

   
    return true;
end

------------------------------------------------------------
-- MAIN HANDLER
------------------------------------------------------------
function M.handle(session, dbh, debug, json)

    if not session:ready() then
        return false
    end

    session:setVariable("current_application_data", "holiday")

    local domain_uuid = session:getVariable("domain_uuid")
    local domain_name = session:getVariable("domain_name")

    if not domain_uuid then
        log("err", "Missing domain_uuid")
        return false
    end

    --------------------------------------------------------
    -- SINGLE DB CALL ONLY
    --------------------------------------------------------
    local holiday = M.get_holiday(dbh, domain_uuid)

    if not holiday then
        log("info", "No holiday match → normal routing")
        return false
    end

 
    log("info", "MATCH: " .. tostring(holiday.holiday_name))

    log("info", string.format(
    "Tenant TZ: %s | Tenant Time: %s",
    tostring(holiday.timezone),
    tostring(holiday.tz_now)
    ))

    log("info", "Server Local Time: " .. os.date("%Y-%m-%d %H:%M:%S"))

    session:setVariable("is_holiday", "true")

    --------------------------------------------------------
    -- ROUTING
    --------------------------------------------------------
    if not holiday.action_type then
        log("warn", "Holiday matched but no action_type → fallback")
        return false
    end

    return safe_route(
        session,
        dbh,
        holiday.action_type,
        holiday.action_data,
        domain_name,
        domain_uuid
    )
end

return M