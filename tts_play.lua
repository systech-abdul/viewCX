-- tts_play.lua
-- FreeSWITCH Lua script: dynamically generate TTS and play
-- Usage: lua tts_play.lua "Text to speak" [voice] [tts_server] [lang] [vocoder] [denoiserStrength] [cache] [ssml]

if not session or not session:ready() then
    freeswitch.consoleLog("ERR", "[TTS] No active session\n")
    return
end

-- Arguments
local tts_text         = argv[1] or "Hello world"
local tts_voice        = argv[2] or "coqui-tts:en_ljspeech"
local tts_server       = argv[3] or "http://localhost:5500"
local tts_lang         = argv[4] or "en"
local tts_vocoder      = argv[5] or "high"
local tts_denoiser     = argv[6] or "0.005"
local tts_cache        = argv[7] or "true"
local tts_ssml         = argv[8] or "false"

-- Generate unique output filename
local call_uuid = session:getVariable("uuid") or tostring(os.time())
local output_file = "/tmp/tts_" .. call_uuid .. ".wav"

-- URL encode helper
local function urlencode(str)
    if str then
        str = string.gsub(str, "\n", "%%0A")
        str = string.gsub(str, "([^%w%-_%.%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

-- Build dynamic TTS URL
local tts_url = string.format(
    "%s/api/tts?voice=%s&lang=%s&vocoder=%s&denoiserStrength=%s&ssml=%s&text=%s&cache=%s",
    tts_server,
    urlencode(tts_voice),
    urlencode(tts_lang),
    urlencode(tts_vocoder),
    urlencode(tts_denoiser),
    urlencode(tts_ssml),
    urlencode(tts_text),
    urlencode(tts_cache)
)

-- Fetch TTS file
freeswitch.consoleLog("INFO", "[TTS] Fetching: " .. tts_url .. "\n")
os.execute(string.format('curl -s -o %s "%s"', output_file, tts_url))

-- Wait for file
local function wait_for_file(file_path, timeout)
    local start = os.time()
    while os.time() - start < timeout do
        local f = io.open(file_path, "rb")
        if f then f:close(); return true end
        freeswitch.msleep(100)
    end
    return false
end

if not wait_for_file(output_file, 5) then
    freeswitch.consoleLog("ERR", "[TTS] File not found: " .. output_file .. "\n")
    return
end

-- Play TTS
--freeswitch.consoleLog("INFO", "[TTS] Playing file: " .. output_file .. "\n")
--session:streamFile(output_file)
--
---- Cleanup
--os.remove(output_file)
--freeswitch.consoleLog("INFO", "[TTS] Deleted file: " .. output_file .. "\n")
--

return output_file;