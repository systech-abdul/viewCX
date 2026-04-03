-- routes/extension_routes.lua

local M = {}

function M.handle(session, args)
    if not session:ready() then
        return false
    end

    local destination = args.destination
    local domain = args.domain

    local kam_ip = session:getVariable("sip_h_X-Kamailio-Source")

    freeswitch.consoleLog("INFO",
        "[extension_routes] Routing to extension: " .. tostring(destination) .. "\n"
    )

    ------------------------------------------------------------------
    -- Codec Preferences
    ------------------------------------------------------------------
    local codec_string = session:getVariable("global_codec_prefs")
    if codec_string then
        session:setVariable("codec_string", codec_string)
    end

    ------------------------------------------------------------------
    -- Call Behavior
    ------------------------------------------------------------------
    session:setVariable("hangup_after_bridge", "true")
    session:setVariable("continue_on_fail", "true")

    ------------------------------------------------------------------
    -- Kamailio Path (WebRTC + SIP)
    ------------------------------------------------------------------
    if kam_ip and kam_ip ~= "" then

        freeswitch.consoleLog("INFO",
            "[extension_routes] Using Kamailio IP: " .. tostring(kam_ip) .. "\n"
        )

        if session:ready() then

            -- WebRTC (TLS 8443)
            local webrtc_cmd =
                "{media_webrtc=true,media_mix_inbound_outbound_codecs=true,ignore_early_media=true}" ..
                "sofia/internal/" .. destination .. "@" .. kam_ip .. ":8443;transport=tls"

            session:execute("bridge", webrtc_cmd)

            -- Fallback SIP (5070)
            local sip_cmd =
                "{media_mix_inbound_outbound_codecs=true,ignore_early_media=true}" ..
                "sofia/internal/" .. destination .. "@" .. kam_ip .. ":5070"

            session:execute("bridge", sip_cmd)
        end

        return true
    end

    ------------------------------------------------------------------
    -- Local User Path
    ------------------------------------------------------------------
    local user_cmd =
        "{media_mix_inbound_outbound_codecs=true,ignore_early_media=true}" ..
        "user/" .. destination .. "@" .. domain

    session:execute("bridge", user_cmd)

    return true
end

return M
