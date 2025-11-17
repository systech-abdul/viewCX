-- /usr/share/freeswitch/scripts/ai_ws.lua

local api = freeswitch.API()

-- simple JSON encoder
local function json_encode(tbl)
    if not tbl then return "" end
    local first = true
    local parts = {}
    table.insert(parts, "{")
    for k, v in pairs(tbl) do
        if not first then table.insert(parts, ",") end
        first = false
        table.insert(parts, string.format("%q:%q", tostring(k), tostring(v)))
    end
    table.insert(parts, "}")
    return table.concat(parts)
end

-- endpoints to try (in order)
local ENDPOINTS = {
    "wss://10.40.1.50:2881/stream",      -- primary secure
    "ws://10.40.1.50:2881/stream",       -- fallback non-TLS
}

local function set_tls_vars_for_url(session, url)
    if url:match("^wss://") then
        -- TLS enabled
        -- You can tighten these later (SYSTEM + hostname validation)
        session:setVariable("STREAM_TLS_CA_FILE", "NONE")
        session:setVariable("STREAM_TLS_DISABLE_HOSTNAME_VALIDATION", "true")
    else
        -- no TLS vars for plain ws
        session:setVariable("STREAM_TLS_CA_FILE", "")
        session:setVariable("STREAM_TLS_DISABLE_HOSTNAME_VALIDATION", "")
    end
end

-- tries each endpoint until one returns non-error from uuid_audio_stream
local function start_audio_stream_with_failover(session, meta_tbl)
    local uuid = session:get_uuid()

    -- audio chunk duration
    session:setVariable("STREAM_BUFFER_SIZE", "40")

    -- extra headers (e.g. auth)
    if meta_tbl and meta_tbl.headers then
        local headers_json = json_encode(meta_tbl.headers)
        session:setVariable("STREAM_EXTRA_HEADERS", headers_json)
    end

    local meta = ""
    if meta_tbl and meta_tbl.meta then
        meta = json_encode(meta_tbl.meta)
    end

    for _, url in ipairs(ENDPOINTS) do
        set_tls_vars_for_url(session, url)

        local cmd = string.format(
            "uuid_audio_stream %s start %s mono 8k %s",
            uuid, url, meta
        )

        freeswitch.consoleLog("INFO",
            string.format("[AI-WS] Trying endpoint: %s\n", url)
        )
        freeswitch.consoleLog("INFO",
            string.format("[AI-WS] Command: %s\n", cmd)
        )

        local res = api:executeString(cmd) or ""
        freeswitch.consoleLog("INFO",
            string.format("[AI-WS] Result for %s: %s\n", url, res)
        )

        -- very simple check: treat anything starting with "-ERR" as failure
        if not res:match("^%-ERR") then
            session:setVariable("ai_ws_active_url", url)
            freeswitch.consoleLog("INFO",
                string.format("[AI-WS] Using endpoint: %s\n", url)
            )
            return true, url
        else
            freeswitch.consoleLog("ERR",
                string.format("[AI-WS] Endpoint failed: %s (res=%s)\n", url, res)
            )
        end
    end

    freeswitch.consoleLog("ERR",
        "[AI-WS] All endpoints failed, no audio stream started.\n"
    )
    return false, nil
end

local function stop_audio_stream(session, final_meta_tbl)
    local uuid = session:get_uuid()
    local meta = ""
    if final_meta_tbl then
        meta = json_encode(final_meta_tbl)
    end

    local cmd = string.format("uuid_audio_stream %s stop %s", uuid, meta)
    freeswitch.consoleLog("INFO", "[AI-WS] Stop command: " .. cmd .. "\n")
    local res = api:executeString(cmd) or ""
    freeswitch.consoleLog("INFO", "[AI-WS] Stop result: " .. res .. "\n")
end

local function run_ai_engine(session)
    if not session:ready() then return end

    session:answer()
    session:sleep(500)

    local ok, active_url = start_audio_stream_with_failover(session, {
        meta = {
            tenant_id   = session:getVariable("tenant_id") or "1",
            process_id  = "ivr_ai_test",
            caller      = session:getVariable("caller_id_number") or "",
            domain      = session:getVariable("domain_name") or "",
        },
        headers = {
            ["X-Auth-Token"] = "some-shared-secret"
        }
    })

    if not ok then
        freeswitch.consoleLog("ERR",
            "[AI-WS] Could not start audio stream on any endpoint. Falling back to normal IVR.\n"
        )
        return
    end

    -- Keep call alive; later we’ll add logic to break out based on AI
    while session:ready() do
        session:sleep(200)
    end

    if session:ready() then
        stop_audio_stream(session)
    end
end

local M = {
    run_ai_engine = run_ai_engine,
    start_audio_stream_with_failover = start_audio_stream_with_failover,
    stop_audio_stream  = stop_audio_stream
}

return M
