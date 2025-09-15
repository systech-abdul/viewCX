local esl = require("esl")

-- Connect to FreeSWITCH ESL
local con = esl.Connection("127.0.0.1", "8021", "ClueCon")

if not con or not con:connected() then
    print("Failed to connect to FreeSWITCH ESL")
    return
end

print("Connected to FreeSWITCH ESL")

-- Subscribe to custom callcenter events
con:events("plain", "CUSTOM")

while true do
    local e = con:recvEvent()

    if e then
        local event_name = e:getHeader("Event-Name")
        local subclass = e:getHeader("Event-Subclass")

        -- Only process callcenter events
        if subclass == "callcenter::info" then
            local cc_event = e:getHeader("CC-Action")
            local agent = e:getHeader("CC-Agent")
            local queue = e:getHeader("CC-Queue")
            local uuid = e:getHeader("Unique-ID")

            if cc_event == "agent-offer" then
                print("[OFFER] Agent: " .. agent .. " | Queue: " .. queue .. " | UUID: " .. uuid)
            elseif cc_event == "agent-answer" then
                print("[ANSWER] Agent: " .. agent .. " | UUID: " .. uuid)
            elseif cc_event == "agent-no-answer" then
                print("[NO ANSWER] Agent: " .. agent .. " | UUID: " .. uuid)
            end
        end
    end
end
