-- send_dtmf_with_curl.lua
-- Lua script to send DTMF selection to a webhook using curl
local session = freeswitch.Session()
local dtmf_input = session:getVariable("digits") -- DTMF input captured from IVR
local caller_number = session:getVariable("caller_id_number")

freeswitch.consoleLog("NOTICE", "lua : " .. caller_number .. "\n")
freeswitch.consoleLog("NOTICE", "lua : " .. dtmf_input .. "\n")
-- Webhook URL
local webhook_url = "https://seec.view360.cx/flow/surveyIVR"

-- Curl command to send a POST request
local curl_cmd = string.format(
    'curl -X POST -d "selection=%s" %s',
    tostring(dtmf_input),
    webhook_url
)

-- Execute the curl command
local handle = io.popen(curl_cmd)
local response = handle:read("*a")
local result_code = handle:close()

-- Log the result
if result_code then
    freeswitch.consoleLog("NOTICE", "Webhook Response: " .. response .. "\n")
else
    freeswitch.consoleLog("ERROR", "Failed to send DTMF to webhook.\n")
end

