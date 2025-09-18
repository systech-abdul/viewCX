-- callcenter-announce-position.lua
-- Usage: luarun callcenter-announce-position.lua <caller_uuid> <queue_name> <interval_ms> <destination_extension>

local api = freeswitch.API()
local caller_uuid = argv[1]
local queue_name = argv[2]
local mseconds = tonumber(argv[3]) or 10000
local play_file = argv[4] or nil  -- optional: play_file announce-sound

if not caller_uuid or not queue_name or not mseconds then
    freeswitch.consoleLog("err", "[CallcenterAnnounce] Missing arguments.\n")
    return
end

local session = freeswitch.Session(caller_uuid)

    


freeswitch.consoleLog("info", "[CallcenterAnnounce] Starting for UUID: " .. caller_uuid .. ", queue: " .. queue_name .. ", interval: " .. mseconds .. "ms\n")

while true do
    freeswitch.msleep(mseconds)

    local members = api:executeString("callcenter_config queue list members " .. queue_name)
    local pos = 1
    local found = false

    for line in members:gmatch("[^\r\n]+") do
        if line:find("Waiting") or line:find("Trying") then
            if line:find(caller_uuid, 1, true) then
                found = true

                -- Announce queue position
                api:executeString("uuid_broadcast " .. caller_uuid .. " ivr/ivr-you_are_number.wav aleg")
                api:executeString("uuid_broadcast " .. caller_uuid .. " digits/" .. pos .. ".wav aleg")

              
                --[[ 
                if session:ready() then
                     freeswitch.consoleLog("WARNING", "[CallcenterAnnounce] session is ready.\n")

               
                      -- Prompt the caller for input
                      local min_digits = 1
                      local max_digits = 1
                      local max_tries = 1
                      local timeout = 5000 -- milliseconds
                      local terminators = "#"
                     
                  
                      local digits = session:playAndGetDigits(min_digits, max_digits, max_tries, timeout, terminators, NULL, NULL, "\\d")
                  
                      freeswitch.consoleLog("info", "[CallcenterAnnounce] Caller input: " .. digits .. "\n")
                  
                      if digits == "9" then
                          freeswitch.consoleLog("info", "[CallcenterAnnounce] Caller chose to exit queue.\n")
                         
                          session:hangup()
                          return
                      elseif digits ~= "1" then
                          freeswitch.consoleLog("info", "[CallcenterAnnounce] Invalid input or timeout, continuing...\n")
                      end
                 

                    
                  end ]]



                -- Optional: Transfer only once when a condition is met
                --[[ if transfer_ext then
                    freeswitch.consoleLog("info", "[CallcenterAnnounce] Transferring UUID: " .. caller_uuid .. " to " .. transfer_ext .. "\n")
                    api:executeString("uuid_transfer " .. caller_uuid .. " " .. transfer_ext .. " XML systech")
                    
                end ]]
            end
            pos = pos + 1
        end
    end

    if not found then
        freeswitch.consoleLog("info", "[CallcenterAnnounce] Caller no longer in queue. Stopping.\n")
        

        return
    end
end
