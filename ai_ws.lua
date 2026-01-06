-- /usr/share/freeswitch/scripts/ai_ws.lua

local M = {}
-- Your Node gateway endpoints
local ENDPOINTS = {
    "ws://10.40.1.50:3001", -- Updated to match our gateway port
}

-- Minimal JSON string escaper for our simple string fields
local function json_escape(str)
    if not str then return "" end
    str = tostring(str)
    str = str:gsub("\\", "\\\\")
             :gsub("\"", "\\\"")
             :gsub("\n", "\\n")
             :gsub("\r", "\\r")
             :gsub("\t", "\\t")
    return str
end

local function build_metadata_json(session, ai_config)
    ai_config_str = ai_config or {}
    ai_config = json.decode(ai_config_str)
    freeswitch.consoleLog("info","[ai_ws.build_metadata_json] Info " .. json.encode(ai_config) .. "\n")
    -- Helper to get value from config first, then session variable
    local function val(key, default) 
        if ai_config[key] then return ai_config[key] end
        local v = session:getVariable(key)
        return (v and v ~= "") and v or default or ""
    end

    local uuid       = session:get_uuid()
    local caller     = val("caller_id_number")
    local domain     = val("domain_name")
    local tenant_id  = val("tenant_id")
    -- Check for "process_id" in config, then session, default to "ivr_ai_test"
    local process_id = val("process_id", "ivr_ai_test")
    
    local ai_provider = val("ai_provider")
    freeswitch.consoleLog("info","[ai_ws.ai_provider] Provider Info " .. ai_provider .."\n")

    local config = {}

    if ai_provider == "elevenlabs-convai" then
        config = {
            agent_id = val("elevenlabs_agent_id"),
            api_key  = val("elevenlabs_api_key"),
            -- Analytics
            summarize       = val("summarize"),
            get_analytics   = val("get_analytics"),
            customer_mood   = val("customer_mood")
        }
    elseif ai_provider == "deepgram-convai" then
        config = {
            api_key       = val("deepgram_api_key"),
            listen_model  = val("deepgram_listen_model"),
            speak_model   = val("deepgram_speak_model"),
            llm_model     = val("llm_model"),
            system_prompt = val("system_prompt"),
            greeting      = val("greeting"),
            first_message = val("first_message"),
            -- Analytics
            summarize       = val("summarize"),
            get_analytics   = val("get_analytics"),
            customer_mood   = val("customer_mood")
        }
    else 
        -- Fallback "modular" or default
        ai_provider = "modular"
        config = {
            stt_provider = val("stt_provider", "deepgram"),
            llm_provider = val("llm_provider", "openai"),
            tts_provider = val("tts_provider", "elevenlabs"),
            -- Analytics
            summarize       = val("summarize"),
            get_analytics   = val("get_analytics"),
            customer_mood   = val("customer_mood")
        }
    end

    -- Manual JSON construction
    local config_json_parts = {}
    for k, v in pairs(config) do
        if v ~= "" then
            table.insert(config_json_parts, string.format('"%s":"%s"', k, json_escape(v)))
        end
    end
    local config_json = "{" .. table.concat(config_json_parts, ",") .. "}"

    local json = string.format(
        '{"uuid":"%s","caller":"%s","domain":"%s","tenant_id":"%s","process_id":"%s","ai_provider":"%s","config":%s}',
        json_escape(uuid),
        json_escape(caller),
        json_escape(domain),
        json_escape(tenant_id),
        json_escape(process_id),
        json_escape(ai_provider),
        config_json
    )

    return json
end

local function set_tls_vars_for_url(session, url)
    if url:match("^wss://") then
        session:setVariable("STREAM_TLS_CA_FILE", "NONE")
        session:setVariable("STREAM_TLS_DISABLE_HOSTNAME_VALIDATION", "true")
    else
        session:setVariable("STREAM_TLS_CA_FILE", "")
        session:setVariable("STREAM_TLS_DISABLE_HOSTNAME_VALIDATION", "")
    end
end

local function try_start_stream(session, uuid, url, meta_json)
    set_tls_vars_for_url(session, url)

    session:setVariable("STREAM_BUFFER_SIZE", "40")
    session:setVariable("STREAM_EXTRA_HEADERS", '{"X-Auth-Token":"voicebot-secret"}')

    local api = freeswitch.API()
    -- Requesting mono 16k L16 as before
    local cmd = string.format("uuid_audio_stream %s start %s mono 16k %s",
                              uuid, url, meta_json)

    freeswitch.consoleLog("INFO", "[AI-WS] Command: " .. cmd .. "\n")
    local res = api:executeString(cmd)
    freeswitch.consoleLog("INFO", "[AI-WS] Result: " .. tostring(res) .. "\n")

    if res and res:match("^%+OK") then
        session:setVariable("ai_ws_active_url", url)
        freeswitch.consoleLog("INFO", "[AI-WS] Using endpoint: " .. url .. "\n")
        return true
    end
    return false
end

local function start_ai_stream(session, ai_config)
    local uuid = session:get_uuid()
    local meta_json = build_metadata_json(session, ai_config)
    freeswitch.consoleLog("INFO", "[AI-WS] ai_config: " .. ai_config .. "\n")
    freeswitch.consoleLog("INFO", "[AI-WS] Metadata: " .. meta_json .. "\n")

    for _, url in ipairs(ENDPOINTS) do
        if try_start_stream(session, uuid, url, meta_json) then
            return true
        end
    end

    freeswitch.consoleLog("ERR", "[AI-WS] Failed to start stream on all endpoints\n")
    return false
end

local function stop_ai_stream(session)
    local uuid = session:get_uuid()
    local api = freeswitch.API()
    local cmd = string.format("uuid_audio_stream %s stop", uuid)
    freeswitch.consoleLog("INFO", "[AI-WS] Stopping stream: " .. cmd .. "\n")
    api:executeString(cmd)
end

-- This is what you're already calling: ai_ws.run_ai_engine(session)
function M.run_ai_engine(session, ai_config)
    if not session:ready() then return end
    freeswitch.consoleLog("info","[ai_ws.run_ai_engine] Provider Info " .. json.encode(ai_config) .."\n")
    session:answer()

    -- Optional: initial greeting before handing to the bot
    -- session:streamFile("/var/lib/freeswitch/recordings/bot_welcome.wav")
    -- session:execute("gentones", "%(1000,0,800)") -- Keep the beep check? User didn't ask to remove it but this script overwrites previous logic.

    local ok = start_ai_stream(session, ai_config)
    if not ok then
        session:streamFile("ivr/ivr-lost_contact.wav")
        return
    end

    local uuid = session:get_uuid()

    -- Subscribe to all CUSTOM events; we will filter for mod_audio_stream::play
    local custom_consumer = freeswitch.EventConsumer("CUSTOM")

    local max_seconds = 300  -- 5 min
    local elapsed = 0
    local last_dtmf = nil

    while session:ready() and elapsed < max_seconds do
        ----------------------------------------------------------------
        -- 1) Handle mod_audio_stream::play events from Node (TTS audio)
        ----------------------------------------------------------------
        local ev = custom_consumer:pop(0)
        while ev do
            local ev_name     = ev:getHeader("Event-Name") or ""
            local ev_subclass = ev:getHeader("Event-Subclass") or ""
            local ev_uuid     = ev:getHeader("Unique-ID") or ev:getHeader("Channel-UUID") or ""

            if ev_name == "CUSTOM" and ev_subclass == "mod_audio_stream::play" and ev_uuid == uuid then
                local body = ev:getBody() or ""
                freeswitch.consoleLog("INFO", "[AI-WS] play event body: " .. body .. "\n")

                -- Body is JSON, e.g. {"audioDataType":"raw","sampleRate":8000,"file":"/tmp/....tmp.r8"}
                local file = body:match('"file"%s*:%s*"([^"]+)"')
                if file and file ~= "" then
                    freeswitch.consoleLog("INFO", "[AI-WS] Streaming AI TTS file: " .. file .. "\n")
                    if session:ready() then
                        session:streamFile(file)
                    end
                else
                    freeswitch.consoleLog("ERR", "[AI-WS] play event without 'file' field\n")
                end
            end

            ev = custom_consumer:pop(0)
        end

        ----------------------------------------------------------------
        -- 2) Handle DTMF (e.g. 0 to break to agent)
        ----------------------------------------------------------------
        local dtmf = session:getDigits(1, "", 100)
        if dtmf and dtmf ~= "" then
            last_dtmf = dtmf
            freeswitch.consoleLog("INFO", "[AI-WS] DTMF detected: " .. dtmf .. "\n")
            if dtmf == "0" then
                freeswitch.consoleLog("INFO", "[AI-WS] Caller pressed 0, break to agent.\n")
                break
            end
        end

        session:sleep(200)
        elapsed = elapsed + 0.2
    end

    stop_ai_stream(session)

    -- Check for transfer request from Node
    local transfer_to = session:getVariable("ai_transfer_to")
    if transfer_to == "agent" then
        freeswitch.consoleLog("INFO", "[AI-WS] Transferring to agent...\n")
        session:transfer("1000", "XML", "default") -- Replace 1000 with your agent extension/queue
    elseif transfer_to == "error" then
        freeswitch.consoleLog("ERR", "[AI-WS] AI Service Error. Routing to fallback.\n")
        session:transfer("error_route", "XML", "default") -- Replace with error route
    elseif last_dtmf == "0" then
        freeswitch.consoleLog("INFO", "[AI-WS] User pressed 0. Transferring to agent...\n")
        session:transfer("1000", "XML", "default")
    end
end

return M
