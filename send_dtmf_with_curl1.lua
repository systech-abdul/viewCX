if session:ready() then
    freeswitch.consoleLog("NOTICE", "Complete Session Data:\n")
    
    -- Get and print the session UUID first
    local uuid = session:get_uuid()
    freeswitch.consoleLog("NOTICE", "lua Session UUID: " .. uuid .. "\n")
    
	freeswitch.consoleLog("NOTICE", "lua DTMF History: " .. session:serialize() .. "\n")
end
