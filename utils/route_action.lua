-- utils/route_action.lua
--local handlers   = require "features_handlers"
local did_ivrs   = require "routes.did_ivrs"
local path_util  = require "utils.path"
local file       = require "utils.file"
local voicemail  = require "features.voicemail"

local M = {}

function M.route_action(session, dbh, action_type, target, domain_name, domain_uuid, ivr_menu_uuid, exit_node)
    exit_node = exit_node or false

    if not session:ready() then
        freeswitch.consoleLog("ERR", "[route_action] Session not ready\n")
        return false
    end

    session:answer()
    freeswitch.consoleLog("INFO",
        string.format("[route_action] action_type=%s | target=%s | domain=%s | domain_uuid=%s | ivr_menu_uuid=%s\n",
            action_type, tostring(target), domain_name, domain_uuid, tostring(ivr_menu_uuid))
    )

    if action_type == "voicemail" then
        voicemail.handle(session, dbh, target, domain_name, domain_uuid)

    elseif action_type == "ivr" then
        local is_uuid = string.match(target, "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
        if is_uuid then
            session:setVariable("parent_ivr_id", ivr_menu_uuid)
            handlers.ivr({ destination = target, domain = domain_name, domain_uuid = domain_uuid })
        else
          freeswitch.consoleLog("INFO", string.format("[[route_action]] IVR ID type=%s, value=%s\n", type(target), tostring(target)))
            did_ivrs.did_ivrs(session, dbh, target)
        end

    elseif action_type == "callcenter" then
        session:setVariable("parent_ivr_id", ivr_menu_uuid)
        callcenter_routes.handle(session,dbh,{ destination = target, domain = domain_name, domain_uuid = domain_uuid })

    elseif action_type == "hangup" then
        session:execute("hangup")

    elseif action_type == "playback" then
        local path = path_util.recording_path(domain_name, target)
        if path and file.exists(path) then
            session:execute("playback", path)
        else
            freeswitch.consoleLog("ERR", "[route_action] Playback file missing: " .. tostring(path) .. "\n")
        end

    else
        session:execute("transfer", target .. " XML systech")
    end

    return true
end

return M
