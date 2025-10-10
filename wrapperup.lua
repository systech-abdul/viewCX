local ESL = require "ESL"

-- Connect to FreeSWITCH ESL
local con = ESL.ESLconnection("127.0.0.1", "8021", "ClueCon")

if con:connected() then
    con:events("plain", "CUSTOM")
    con:filter("Event-Subclass", "callcenter::info")

    print("Listening for callcenter::info events...")

    while true do
        local e = con:recvEvent()
        if e then
            local agent = e:getHeader("CC-Agent")
            local new_state = e:getHeader("CC-Agent-State")
            local old_state = e:getHeader("CC-Agent-Previous-State")

            if new_state == "Idle" and old_state == "In-Use" then
                print("Agent " .. agent .. " wrap-up started.")

                os.execute("fs_cli -x \"callcenter_config agent set status " .. agent .. " 'On Break'\"")
                os.execute("fs_cli -x \"callcenter_config agent set state " .. agent .. " 'Idle'\"")

                -- Later reset to Available/Ready after a delay
                os.execute("sleep 30") -- or use socket.sleep or a better timer
                os.execute("fs_cli -x \"callcenter_config agent set status " .. agent .. " 'Available'\"")
                os.execute("fs_cli -x \"callcenter_config agent set state " .. agent .. " 'Ready'\"")

                print("Agent " .. agent .. " wrap-up completed.")
            end
        end
    end
else
    print("Failed to connect to FreeSWITCH ESL.")
end
