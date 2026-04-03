
-- ============================================================
-- 🎤 Generate TTS audio file dynamically with optional params
-- ============================================================

local json = require("resources.functions.lunajson")
local file = require "utils.file"
local hash = require "utils.hash"

local M = {}

-- Helpers (you can later move to utils/)
local function urlencode(str)
    if str then
        str = string.gsub(str, "\n", "%%0A")
        str = string.gsub(str, "([^%w%-_%.%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

local function ensure_dir(path)
    os.execute("mkdir -p " .. path)
end

function M.generate(session, dbh, tts_text, domain_uuid)
    ------------------------------------------------------------------
    -- Default Config
    ------------------------------------------------------------------
    local tts_config = {
        tts_text     = tts_text or "Hello, this is a test message.",
        tts_server   = "http://localhost:5500",
        tts_voice    = "espeak:en-029",
        tts_lang     = "en",
        tts_vocoder  = "high",
        tts_denoiser = "0.005",
        tts_ssml     = "true"
    }

    ------------------------------------------------------------------
    -- Load DB Config
    ------------------------------------------------------------------
    local sql = [[
        SELECT tts_setting
        FROM call_app_settings
        WHERE domain_uuid = :domain_uuid
        AND deleted_at IS NULL
        LIMIT 1
    ]]

    local row, err = dbh:first_row(sql, { domain_uuid = domain_uuid })

    if err then
        freeswitch.consoleLog("ERR", "[TTS] SQL Error: " .. tostring(err) .. "\n")
    elseif row and row.tts_setting then
        local decoded = json.decode(row.tts_setting)

        if decoded then
            for k, v in pairs(decoded) do
                if tts_config[k] ~= nil then
                    tts_config[k] = v
                end
            end
        end
    end

    freeswitch.consoleLog("INFO",
        "[TTS] Config: " .. json.encode(tts_config) .. "\n")

    ------------------------------------------------------------------
    -- Cache Handling
    ------------------------------------------------------------------
    local cache_dir = "/var/lib/freeswitch/tts_cache"
    ensure_dir(cache_dir)

    local hash = hash.md5(tts_config.tts_text)
    local output_file = string.format("%s/tts_%s.wav", cache_dir, hash)

    if file.exists(output_file) then
        freeswitch.consoleLog("INFO",
            "[TTS] Using cache: " .. output_file .. "\n")
        return output_file
    end

    ------------------------------------------------------------------
    -- Build URL
    ------------------------------------------------------------------
    local tts_url = string.format(
        "%s/api/tts?voice=%s&lang=%s&vocoder=%s&denoiserStrength=%s&ssml=%s&text=%s&cache=true",
        tts_config.tts_server,
        urlencode(tts_config.tts_voice),
        urlencode(tts_config.tts_lang),
        urlencode(tts_config.tts_vocoder),
        urlencode(tts_config.tts_denoiser),
        urlencode(tts_config.tts_ssml),
        urlencode(tts_config.tts_text)
    )

    freeswitch.consoleLog("INFO",
        "[TTS] Fetching: " .. tts_url .. "\n")

    ------------------------------------------------------------------
    -- Fetch Audio
    ------------------------------------------------------------------
    os.execute(string.format('curl -s -o "%s" "%s"', output_file, tts_url))

    ------------------------------------------------------------------
    -- Wait for file
    ------------------------------------------------------------------
    local start = os.time()

    while os.time() - start < 5 do
        if file.exists(output_file) then break end
        freeswitch.msleep(100)
    end

    if not file.exists(output_file) then
        freeswitch.consoleLog("ERR",
            "[TTS] Failed: " .. output_file .. "\n")
        return nil
    end

    freeswitch.consoleLog("INFO",
        "[TTS] Ready: " .. output_file .. "\n")

    return output_file
end

return M
