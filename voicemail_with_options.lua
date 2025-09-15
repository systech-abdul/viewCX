api = freeswitch.API()

local voicemail_id = session:getVariable("voicemail_id") or "2008"
local domain_name = session:getVariable("domain_name") or "cc.systech.ae"
local voicemail_password = session:getVariable("voicemail_password") or "12345"
local greeting = "/var/lib/freeswitch/storage/voicemail/default/" .. domain_name .. "/" .. voicemail_id .. "/greeting_1.wav"

local options = {
  ["1"] = { action = "transfer", destination = "4000", context = "systech" },
  ["2"] = { action = "transfer", destination = "2008", context = "systech" }
}

function do_transfer(destination, context)
  session:execute("transfer", destination .. " XML " .. context)
end

function play_greeting_and_get_option()
  session:answer()
  session:setAutoHangup(false)
  session:sleep(1000)

  if api:execute("file_exists", greeting) == "true" then
    session:streamFile(greeting)
  else
    session:streamFile("voicemail/vm-please-leave-message.wav")
  end

  session:streamFile("voicemail/vm-options.wav")
  session:streamFile("voicemail/vm-press.wav")
  session:streamFile("digits/1.wav")
  session:streamFile("voicemail/vm-for-the-operator.wav")
  session:streamFile("voicemail/vm-press.wav")
  session:streamFile("digits/2.wav")
  session:streamFile("voicemail/vm-to-retry.wav")

  local digit = session:playAndGetDigits(1, 1, 3, 5000, "#", "", "\\d", "")

  freeswitch.consoleLog("INFO", "[Voicemail Options] Digit pressed: " .. digit .. "\n")

  return digit
end

if session:ready() then
  local digit = play_greeting_and_get_option()

  if digit and options[digit] then
    local opt = options[digit]
    freeswitch.consoleLog("INFO", "[Voicemail Options] Transferring to " .. opt.destination .. " in context " .. opt.context .. "\n")
    do_transfer(opt.destination, opt.context)
  else
    freeswitch.consoleLog("INFO", "[Voicemail Options] No valid digit. Recording voicemail.\n")
    
            local profile = "default"
            local args = string.format("%s %s %s", profile, domain_name, voicemail_id)
            session:execute("voicemail", args)
   
  end
end
