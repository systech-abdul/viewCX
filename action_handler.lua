-- action_handler.lua
-- Unified wrapper for timegroup() and voicemail_handler()

-- Load main features handlers
dofile("/usr/share/freeswitch/scripts/features_handlers.lua")  -- adjust path if needed

-- Arguments from FreeSWITCH
local action           = argv[1]  -- "timegroup" or "voicemail"
local target           = argv[2]  -- timegroup UUID or voicemail ID
local ivr_menu_uuid    = argv[3]  -- optional, used for timegroup
local input_digit      = argv[4]  -- optional, used for timegroup
local exit_node_flag   = argv[5]  -- optional, true/false for timegroup
local domain_name      =  session:getVariable("domain_name")
local domain_uuid      =  session:getVariable("domain_uuid")

-- Helper to convert exit_node_flag to boolean
local function to_boolean(str)
    return str == "true"
end

if not action or not target then
    freeswitch.consoleLog("ERR", "[action_handler] Missing required arguments\n")
    return
end

if action == "timegroup" then
    local exit_node = to_boolean(exit_node_flag or "false")
    freeswitch.consoleLog("INFO", string.format(
        "[action_handler] Calling timegroup() uuid=%s ivr=%s input=%s exit=%s\n",
        target, tostring(ivr_menu_uuid), tostring(input_digit), tostring(exit_node)
    ))
    timegroup(target, ivr_menu_uuid, input_digit, exit_node)

elseif action == "voicemail" then
    if not domain_name or not domain_uuid then
        freeswitch.consoleLog("ERR", "[action_handler] Missing domain_name or domain_uuid for voicemail\n")
        return
    end
    freeswitch.consoleLog("INFO", string.format(
        "[action_handler] Calling voicemail_handler() for %s@%s\n",
        target, domain_name
    ))
    voicemail_handler(target, domain_name, domain_uuid)
 
elseif action == "hangup" then
session:execute("hangup")  

else
    freeswitch.consoleLog("ERR", "[action_handler] Unsupported action: " .. tostring(action) .. "\n")
end
