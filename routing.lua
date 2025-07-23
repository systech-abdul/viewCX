-- Get destination number and domain from session
local destination = session:getVariable("destination_number") or
                    session:getVariable("sip_req_user") or
                    session:getVariable("sip_to_user")

local domain_name = session:getVariable("sip_req_host")






--dump channels 
session:execute("info");

freeswitch.consoleLog("console", "[routing.lua] Dialed number: " .. (destination or "nil") .. " | domain_name`: " .. (domain_name or "unknown") .. "\n")


-- Safety checks
if not session:ready() then return end
if not destination or destination == "" then
    freeswitch.consoleLog("err", "[routing.lua] Missing destination number.\n")
    session:execute("playback", "ivr/ivr-no_route_destination.wav")
    return
end

-- Log dialed number and domain
freeswitch.consoleLog("info", "[routing.lua] Dialed number: " .. destination .. " | Domain: " .. (domain_name or "unknown") .. "\n")

-- Routing map (easily extendable)

session:setVariable("codec_string", "PCMU,PCMA,G729");

route= "{media_mix_inbound_outbound_codecs=true,ignore_early_media=true}user/" ..destination.. "@" .. domain_name;


   


if route then
    freeswitch.consoleLog("info", "[routing.lua] Routing to: " .. route .. "\n")
    session:execute("bridge", route)
else
    freeswitch.consoleLog("warning", "[routing.lua] No route found for: " .. destination .. "\n")
    session:execute("playback", "ivr/ivr-not_available.wav")
end
