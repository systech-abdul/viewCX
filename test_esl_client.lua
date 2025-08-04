local esl = require("esl")

-- Connect to ESL
local conn = esl.ESLconnection("127.0.0.1", "8021", "ClueCon")

if conn:connected() then
    print("Connected to FreeSWITCH")

    -- Send an API command
    local reply = conn:api("status", "")
    print("API Reply:\n" .. reply:getBody())

    -- Run background API command
    -- conn:send("bgapi originate sofia/default/1000 &park")

else
    print("Failed to connect")
end
