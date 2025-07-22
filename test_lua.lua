freeswitch.consoleLog("info","INSIDE THE Test Lua") ;
local TheSound = "/var/lib/freeswitch/recordings/fusion.systech.ae/playMainMenu_Ar.wav"


if (session:ready() == true) then
    session:execute("playback", TheSound)

end
