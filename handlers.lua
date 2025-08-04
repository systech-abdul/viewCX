-- scripts/handlers.lua

local handlers = {}

-- Extension (10k–19k)
function handlers.extension(destination, domain)
    return "{media_mix_inbound_outbound_codecs=true,ignore_early_media=true}user/" .. destination .. "@" .. domain
end

-- Call Center (20k–29k)
function handlers.callcenter(destination, domain)
    return "{media_mix_inbound_outbound_codecs=true,ignore_early_media=true}callcenter/" .. destination .. "@" .. domain
end

-- Ring Group (30k–39k)
function handlers.ringgroup(destination, domain)
    return "{media_mix_inbound_outbound_codecs=true,ignore_early_media=true}group/" .. destination .. "@" .. domain
end

-- IVR (40k–49k)
function handlers.ivr(destination, domain)
    return "{media_mix_inbound_outbound_codecs=true,ignore_early_media=true}ivr/" .. destination .. "@" .. domain
end

-- Outbound (anything else)
function handlers.outbound(destination)
    return "{media_mix_inbound_outbound_codecs=true,ignore_early_media=true}sofia/gateway/ebd0d60b-e1ac-4ac7-9ecf-279bb01e2055/" .. destination
end

return handlers
