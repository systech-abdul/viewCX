-- routes/extension_routes.lua


local M = {}

function M.handle(session,dbh, args)

    ------------------------------------------------------------------
    -- Session Safety Check
    ------------------------------------------------------------------
    if not session:ready() then
        return false
    end
    
    local destination =  args.destination
    local domain = args.domain or  session:getVariable("domain_name")
    local domain_uuid =  args.domain_uuid  or  session:getVariable("domain_uuid")
      
    freeswitch.consoleLog("INFO",
    string.format(
        "[extension_routes] destination=%s | domain=%s | domain_uuid=%s\n",
        tostring(destination),
        tostring(domain),
        tostring(domain_uuid)
    )
     )
    ------------------------------------------------------------------
    -- Validate Input
    ------------------------------------------------------------------
    if not destination or destination == "" then
        freeswitch.consoleLog("ERR", "[extension_routes] Missing destination\n")
        return false
    end

    
    local kam_source = session:getVariable("sip_h_X-Kamailio-Source")

    ------------------------------------------------------------------
    -- Fetch Kamailio Config from PostgreSQL
    ------------------------------------------------------------------
    local kam_data
    
  

    dbh:query([[
        SELECT 
            kamailio_enable,
            kamailio_domain,
            kamailio_port
        FROM call_app_settings
        WHERE domain_uuid = :du
        AND deleted_at IS NULL
        LIMIT 1
    ]], { du = domain_uuid }, function(row)
        kam_data = row
    end)

    ------------------------------------------------------------------
    -- Extract Values
    ------------------------------------------------------------------
    local kam_enabled = false
    local kam_ip = nil
    local kam_port = nil

    if kam_data then
        kam_enabled = (
            kam_data.kamailio_enable == true or
            kam_data.kamailio_enable == "true" or
            kam_data.kamailio_enable == "t"
        )

        kam_ip = kam_data.kamailio_domain
        kam_port = tonumber(kam_data.kamailio_port)
    end

    ------------------------------------------------------------------
    -- Logging
    ------------------------------------------------------------------
    freeswitch.consoleLog("INFO",
        string.format("[extension_routes] Dest=%s Domain=%s KamEnable=%s KamIP=%s KamPort=%s kam_source=%s\n",
            tostring(destination),
            tostring(domain),
            tostring(kam_enabled),
            tostring(kam_ip),
            tostring(kam_port),
            tostring(kam_source)

        )
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
    -- Routing Logic
    ------------------------------------------------------------------

    -- Case 1: Route via Kamailio (WebRTC -> SIP failover)
    if kam_source ~= nil and kam_source ~= "" and kam_ip ~= nil and kam_ip ~= "" then


      local webrtc_leg =
        "{media_webrtc=true,media_mix_inbound_outbound_codecs=true,ignore_early_media=true}" ..
        "sofia/internal/" .. destination .. "@" .. (kam_ip or "") ..":".. tostring(kam_port or "") ..";transport=tls"

      local sip_leg =
        "{media_mix_inbound_outbound_codecs=true,ignore_early_media=true}" ..
        "sofia/internal/" .. destination .. "@" .. (kam_ip or "") .. ":5060"

        freeswitch.consoleLog("INFO",
            "[extension_routes] Routing via Kamailio\n"
        )

        local bridge_cmd =
            webrtc_leg ..
            "|" ..  
            sip_leg 
        session:execute("bridge", bridge_cmd)
        return true
    end

    ------------------------------------------------------------------
    -- Case 2: Local User Only
    ------------------------------------------------------------------

     local user_leg =
        "{media_mix_inbound_outbound_codecs=true,ignore_early_media=true}" ..
        "user/" .. destination .. "@" .. domain

    freeswitch.consoleLog("INFO",
        "[extension_routes] Routing to local user\n"
    )

    session:execute("bridge", user_leg)

    return true
end

return M