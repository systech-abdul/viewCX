local M = {}

------------------------------------------------------------
-- logger
------------------------------------------------------------
local function log(level, msg)
    freeswitch.consoleLog(level or "info", "[holiday] " .. tostring(msg) .. "\n")
end

------------------------------------------------------------
-- VALIDATE HOLIDAY (ACTIVE + TIME MATCH + ID CHECK)
------------------------------------------------------------
function M.validate_holiday(dbh, holiday_id, domain_uuid)

    if not holiday_id or holiday_id == "" then
        return false
    end

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
          AND id = :holiday_id
          AND is_active = TRUE
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
        LIMIT 1;
    ]]

    local params = {
        domain_uuid = domain_uuid,
        holiday_id = holiday_id
    }

    local row = nil

    dbh:query(sql, params, function(r)
        row = r
    end)

    return row
end

------------------------------------------------------------
-- IVR DESTINATION FETCH
------------------------------------------------------------
function M.get_ivr_type_and_destination(dbh, ivr_menu_uuid, ivr_menu_option_digits, debug, json)

    if not ivr_menu_uuid or not ivr_menu_option_digits then
        log("err", "IVR params missing")
        return false
    end

    local sql = [[
        SELECT
            working_destination_type,
            working_destination_num,
            failover_destination_type,
            failover_destination_num
        FROM v_ivr_menu_options
        WHERE ivr_menu_uuid = :ivr_menu_uuid
          AND ivr_menu_option_digits = :ivr_menu_option_digits
        LIMIT 1;
    ]]

    local params = {
        ivr_menu_uuid = ivr_menu_uuid,
        ivr_menu_option_digits = ivr_menu_option_digits
    }

    local row = nil

    dbh:query(sql, params, function(r)
        row = r
    end)

    return row
end

------------------------------------------------------------
-- ROUTER
------------------------------------------------------------
local function route(session, dbh, dest_type, dest_num, domain_name, domain_uuid)

    if not session:ready() then
        log("err", "Session not ready")
        return false
    end

    if not dest_type or not dest_num then
        log("err", "Missing destination")
        return false
    end

    local route_action = require "utils.route_action"

    route_action.route_action(
        session,
        dbh,
        dest_type,
        dest_num,
        domain_name,
        domain_uuid
    )

    return true
end

------------------------------------------------------------
-- MAIN HANDLER
------------------------------------------------------------
function M.handle(session, dbh, holiday_id, ivr_menu_uuid, ivr_menu_option_digits, debug, json)

    log("NOTICE",
        "holiday_id: " .. tostring(holiday_id) ..
        " ivr_menu_uuid: " .. tostring(ivr_menu_uuid)
    )

    if not session:ready() then
        return false
    end

    local domain_uuid = session:getVariable("domain_uuid")
    local domain_name = session:getVariable("domain_name")

    if not domain_uuid then
        log("err", "Missing domain_uuid")
        return false
    end

    session:setVariable("current_application_data", "holiday")
    session:setVariable("information_node", "holiday")
 

    --------------------------------------------------------
    -- CHECK HOLIDAY
    --------------------------------------------------------
    local holiday = M.validate_holiday(dbh, holiday_id, domain_uuid)

    --------------------------------------------------------
    -- FETCH IVR DESTINATION
    --------------------------------------------------------
    local ivr_data = M.get_ivr_type_and_destination(
        dbh,
        ivr_menu_uuid,
        ivr_menu_option_digits,
        debug,
        json
    )

    if not ivr_data then
        log("err", "No IVR data found")
        --return false
    end

    --------------------------------------------------------
    -- DECISION ENGINE
    --------------------------------------------------------
   

    local dest_type
    local dest_num
        
    -- default source: IVR
    if ivr_data then
    
        if holiday then
            session:setVariable("is_holiday", "true")
            session:setVariable("holiday_name", tostring(holiday.holiday_name))
        
            log("INFO", "HOLIDAY ACTIVE → " .. tostring(holiday.holiday_name))
        
            dest_type = ivr_data.working_destination_type
            dest_num  = ivr_data.working_destination_num
        else
            session:setVariable("is_holiday", "false")
        
            log("INFO", "NORMAL ROUTE (FAILOVER)")
        
            dest_type = ivr_data.failover_destination_type
            dest_num  = ivr_data.failover_destination_num
        end
    
    else
        ----------------------------------------------------
        -- NO IVR → USE HOLIDAY FALLBACK ONLY ONCE
        ----------------------------------------------------
        log("WARN", "IVR missing → using fallback logic")
    
        if holiday and holiday.action_type and holiday.action_data then
            dest_type = holiday.action_type
            dest_num  = holiday.action_data
        
            log("INFO", "FALLBACK ROUTE → " .. dest_type .. ":" .. dest_num)
        else
            log("ERR", "No IVR and no holiday fallback")
            return false
        end
    end


    --------------------------------------------------------
    -- EXECUTE ROUTE
    --------------------------------------------------------
    return route(session, dbh, dest_type, dest_num, domain_name, domain_uuid)

end

return M