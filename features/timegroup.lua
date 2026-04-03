local M = {}

-- Function to get IVR destination
function M.get_ivr_type_and_destination(dbh, ivr_menu_uuid, ivr_menu_option_digits, debug, json)
    local sql_ivr = [[
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

    local params_ivr = {
        ivr_menu_uuid = ivr_menu_uuid,
        ivr_menu_option_digits = ivr_menu_option_digits
    }

    if debug and debug["sql"] then
        freeswitch.consoleLog("notice", "[get_ivr_type_and_destination] SQL: " .. sql_ivr .. " | Params: " .. json.encode(params_ivr) .. "\n")
    end

    local ivr_data = nil
    local found = false

    dbh:query(sql_ivr, params_ivr, function(row)
        ivr_data = row
        found = true
    end)

    if not found then
        freeswitch.consoleLog("ERR", "[get_ivr_type_and_destination] No IVR destination found for UUID: " .. tostring(ivr_menu_uuid) .. " digits: " .. tostring(ivr_menu_option_digits) .. "\n")
        return false
    end

    return ivr_data
end

-- Modular timegroup function with logging
function M.handle(session, dbh, time_grp_uuid, ivr_menu_uuid, input, exit_node, route_action, debug, json)
    if not session:ready() then
        return false
    end

    exit_node = exit_node or false
    session:setVariable("current_application_data", "timegroup")

    local domain_name = session:getVariable("domain_name")
    local domain_uuid = session:getVariable("domain_uuid")
    local route_action = require "utils.route_action";
    
    ------------------------------------------------------------------
    -- Fetch time group
    ------------------------------------------------------------------
    local sql = [[
        WITH tg AS (
            SELECT *, (NOW() AT TIME ZONE time_zone) AS local_ts
            FROM time_group
            WHERE uuid = :uuid
            LIMIT 1
        ),
        calc AS (
            SELECT
                tg.*,
                lower(to_char(local_ts, 'Dy')) AS current_day,
                (local_ts::time) AS current_time,
                EXISTS (
                    SELECT 1
                    FROM json_array_elements(tg.time_condition::json) AS rule
                    WHERE
                        lower(to_char(local_ts, 'Dy')) IN (
                            SELECT lower(json_array_elements_text((rule->'days')::json))
                        )
                        AND (local_ts::time) >= (rule->>'start_time')::time
                        AND (tg.local_ts::time) <= (rule->>'end_time')::time
                ) AS is_match
            FROM tg
        )
        SELECT *, is_match AS final_is_within_time
        FROM calc
        LIMIT 1;
    ]]

    local row = nil
    dbh:query(sql, { uuid = time_grp_uuid }, function(r)
        row = r
    end)

    if not row then
        freeswitch.consoleLog("ERR", "[timegroup] Time group not found for UUID: " .. tostring(time_grp_uuid) .. "\n")
        session:setVariable("timegroup_working", "false")
        return false
    end

    ------------------------------------------------------------------
    -- Determine if within working time
    ------------------------------------------------------------------
    local within_working_time = tostring(row.final_is_within_time) == "t" or tostring(row.final_is_within_time) == "true"
    session:setVariable("timegroup_working", within_working_time and "true" or "false")

    ------------------------------------------------------------------
    -- Log details
    ------------------------------------------------------------------
    freeswitch.consoleLog("info", "[timegroup] Timezone : " .. row.time_zone .. "\n")
    freeswitch.consoleLog("info", "[timegroup] Current Day : " .. row.current_day .. ", Time: " .. row.current_time .. "\n")
    freeswitch.consoleLog("info", "[timegroup] Within working time : " .. tostring(within_working_time) .. "\n")
    freeswitch.consoleLog("info", "[timegroup] working_destination_type : " .. tostring(row.working_destination_type) .. ", num : " .. tostring(row.working_destination_num) .. "\n")
    freeswitch.consoleLog("info", "[timegroup] failover_destination_type : " .. tostring(row.failover_destination_type) .. ", num : " .. tostring(row.failover_destination_num) .. "\n")
    freeswitch.consoleLog("info", "[timegroup] is exit_action : " .. tostring(exit_node) .. "\n")

    ------------------------------------------------------------------
    -- Decide destination
    ------------------------------------------------------------------
    local destination_type, destination_number, routing_note

    if exit_node then
        if within_working_time then
            destination_type = row.working_destination_type
            destination_number = row.working_destination_num
            routing_note = "exit working"
        else
            destination_type = row.failover_destination_type
            destination_number = row.failover_destination_num
            routing_note = "exit failover"
        end
    else
        local ivr_data = M.get_ivr_type_and_destination(dbh, ivr_menu_uuid, input, debug, json)
        if not ivr_data then
            freeswitch.consoleLog("ERR", "[timegroup] IVR data missing for menu UUID: " .. tostring(ivr_menu_uuid) .. " input: " .. tostring(input) .. "\n")
            return false
        end

        if within_working_time then
            destination_type = ivr_data.working_destination_type
            destination_number = ivr_data.working_destination_num
            routing_note = "working"
        else
            destination_type = ivr_data.failover_destination_type
            destination_number = ivr_data.failover_destination_num
            routing_note = "failover"
            session:setVariable("information_node", "ivr_non_working_hour")
        end
    end

    freeswitch.consoleLog("info",
        string.format("[timegroup] Route: %s -> %s (%s)\n",
            tostring(destination_type),
            tostring(destination_number),
            routing_note)
    )

    if not destination_type or not destination_number then
        freeswitch.consoleLog("ERR", "[timegroup] Missing destination\n")
        return false
    end

    ------------------------------------------------------------------
    -- Call route_action table function
    ------------------------------------------------------------------
        route_action.route_action(session, dbh, destination_type, destination_number, domain_name, domain_uuid, ivr_menu_uuid)
        
   
       
    

    return true
end

return M