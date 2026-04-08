-- routes/callcenter_routes.lua

local path_util = require "utils.path"
local file = require "utils.file"
local sticky_agent = require "features.sticky_agent"
local check_queue_wait = require "features.queue_wait_check"
local did_ivrs         = require "routes.did_ivrs"
local route_action = require "utils.route_action"
local extension_routes = require "routes.extension_routes"
local M = {}

function M.handle(session, dbh, args)
    if not session:ready() then
        return false
    end

    session:answer()
    session:sleep(1000)

    if not session:ready() then
        freeswitch.consoleLog("ERR", "[CallCenter] Session not ready\n")
        return false
    end

    ------------------------------------------------------------------
    -- Dependencies (inject for clean design)
    ------------------------------------------------------------------
    --local extension_routes = deps.extension_routes

    ------------------------------------------------------------------
    -- Basic Info
    ------------------------------------------------------------------
    local queue_extension = args.destination or session:getVariable("refer_extension")
    local domain_uuid = args.domain_uuid
    local domain_name = args.domain or session:getVariable("refer_domain")
    local queue = queue_extension .. "@" .. domain_name

    freeswitch.consoleLog("INFO", "[CallCenter] Queue dyamic route: " .. queue .. "\n")

    ------------------------------------------------------------------
    -- Fetch Queue Data
    ------------------------------------------------------------------
    local queue_data

    dbh:query([[
        SELECT q.*, r.recording_filename
        FROM v_call_center_queues q
        LEFT JOIN v_recordings r 
        ON r.recording_uuid::text = q.queue_announce_sound
        WHERE q.queue_extension = :ext
        AND q.domain_uuid = :du
        LIMIT 1
    ]], { ext = queue_extension, du = domain_uuid }, function(row)
        queue_data = row
    end)

    if not queue_data then
        freeswitch.consoleLog("WARNING", "[CallCenter] Queue not found\n")
        return false
    end

    session:setVariable("queue_name", queue_data.queue_name or "default")
    session:setVariable("queue", queue)
    session:setVariable("information_node", "queue_answered")

    ------------------------------------------------------------------
    -- High Wait Handling
    ------------------------------------------------------------------
    local threshold = tonumber(queue_data.high_wait_threshold) or 0
    local ivr_node = tonumber(queue_data.ivr_node_queue)

    if threshold > 0 and check_queue_wait then
        if check_queue_wait(session, queue, threshold) then
            if ivr_node then
               did_ivrs.did_ivrs(ivr_node)
            end
        end
    end

    ------------------------------------------------------------------
    -- Recording
    ------------------------------------------------------------------
    local direction = session:getVariable("direction") or "inbound"
    enable_recording_if_needed(direction)
    ------------------------------------------------------------------
    -- Priority
    ------------------------------------------------------------------
    local priority = tonumber(queue_data.priority) or 10
    local score = 0

    if priority >= 1 and priority <= 9 then
        score = 1100 - (priority * 100)
        session:setVariable("cc_base_score", tostring(score))
    end

    ------------------------------------------------------------------
    -- Greeting
    ------------------------------------------------------------------
    local greeting_file = queue_data.queue_greeting
    local greeting_path = greeting_file and
        path_util.recording_path(domain_name, greeting_file)

    if greeting_path and file.exists(greeting_path) then
        session:execute("playback", greeting_path)
        session:sleep(1000)
    end

    ------------------------------------------------------------------
    -- Sticky Agent Routing
    ------------------------------------------------------------------
     freeswitch.consoleLog("INFO",
                "[CallCenter] Sticky agent:  \n")
     local agent_name, agent_id, available, fallback_action, fallback_dest =
            sticky_agent.route(session)

        if available and agent_name then
            freeswitch.consoleLog("INFO",
                "[CallCenter] Sticky agent: " .. agent_name .. "\n")

            local args = {
                destination = agent_name,
                domain = domain_name,
                domain_uuid = domain_uuid
            }

            extension_routes.handle(session,dbh,args)
            return true
        elseif fallback_action and fallback_dest then 
            route_action.route_action(session, dbh,fallback_action, fallback_dest, domain_name, domain_uuid, nil)
        end
   



   local agent_moh = queue_data.agent_moh_sound
   local queue_moh = queue_data.queue_moh_sound

   
    if queue_moh and queue_moh ~= "" then
        session:execute("set", "cc_moh_override=" .. queue_moh)
    end

    if agent_moh and agent_moh ~= "" then
        session:execute("set", "hold_music=" .. agent_moh)
        session:execute("set", "cc_export_vars=hold_music")
    end


    ------------------------------------------------------------------
    -- Join Queue
    ------------------------------------------------------------------
    session:execute("callcenter", queue)

    session:execute("clear_digit_action", "queue_control")

    return true
end

return M
