local Database = require "resources.functions.database"

local dbh = Database.new("system")
assert(dbh:connected())

-- custom_voicemail.lua (module style with DB insert)
local api = freeswitch.API()

-- FusionPBX Database helper
local Database = require "resources.functions.database"

local M = {}

-- === CONFIG SECTION (defaults) ===
local default_welcome_file = "/usr/share/freeswitch/sounds/en/us/callie/voicemail/vm-record_message.wav"
local default_thanks_file  = "/usr/share/freeswitch/sounds/en/us/callie/voicemail/vm-thank_you.wav"

-- where to store the .wav recordings
local default_record_dir   = "/var/lib/freeswitch/recordings/custom_voicemail"

-- 10 minutes max
local default_max_len      = 600        -- seconds

-- silence threshold (energy); adjust if needed
local default_silence_thr  = 500

-- beep before recording
local default_beep_tone    = "tone_stream://%(500,0,640)"

-- DB table
local default_table_name   = "custom_voicemail_messages"
-- ======================

function M.record_voicemail(session, opts)
    opts = opts or {}

    local welcome_file      = opts.welcome_file       or default_welcome_file
    local thanks_file       = opts.thanks_file        or default_thanks_file
    local record_base_dir   = opts.record_base_dir    or default_record_dir
    local max_len_seconds   = opts.max_len_seconds    or default_max_len
    local silence_threshold = opts.silence_threshold  or default_silence_thr
    local beep_tone         = opts.beep_tone          or default_beep_tone
    local playback_terminator = opts.playback_terminator or "#"
    local table_name        = opts.table_name         or default_table_name

    api:execute("system", "mkdir -p " .. record_base_dir)

    if not session or not session:ready() then
        freeswitch.consoleLog("ERR", "[vm-lua] No active session or not ready.\n")
        return
    end

    session:answer()
    session:flushDigits()
    session:setVariable("playback_terminators", playback_terminator)

    if session:ready() then
        session:streamFile(welcome_file)
    end

    if session:ready() then
        session:streamFile(beep_tone)
    end

    if not session:ready() then
        -- caller hung up before recording even started
        return
    end

    -- Build unique filename
    local uuid = session:get_uuid()
    local ts   = os.date("%Y%m%d-%H%M%S")
    local recording_path = string.format("%s/%s_%s.wav", record_base_dir, ts, uuid)

    freeswitch.consoleLog("INFO", "[vm-lua] Recording to: " .. recording_path .. "\n")

    -- Start recording; stops on #, max_len, silence, or hangup.
    session:execute("record", string.format("%s %d %d", recording_path, max_len_seconds, silence_threshold))

    -- After record() returns, file is already written.
    -- Even if the caller hung up, this code still runs (session may not be ready,
    -- but we can still log to DB).

    -- Grab some channel variables
    local domain_uuid        = session:getVariable("domain_uuid")
    local call_uuid          = session:getVariable("call_uuid")
    local voicemail_id       = session:getVariable("voicemail_id") or ""
    local caller_number      = session:getVariable("caller_id_number")
    local destination_number = session:getVariable("destination_number")
    local record_ms          = session:getVariable("record_ms") or "0"
    local tenant_id          = session:getVariable("tenant_id")  or 0
    local process_id         = session:getVariable("process_id") or 0
    -- session:execute("info") -- Debug info
    -- Insert into DB
    -- local dbh = Database.new('system')
    if dbh:connected() then
        local sql = string.format([[
            INSERT INTO %s
                (voicemail_uuid, domain_uuid, tenant_id, process_id, call_uuid, voicemail_id, caller_number, destination_number, recording_path, record_ms, created_at)
            VALUES
                (:voicemail_uuid, :domain_uuid, :tenant_id, :process_id, :call_uuid, :voicemail_id, :caller_number, :destination_number, :recording_path, :record_ms, NOW())
        ]], table_name)

        dbh:query(sql, {
            voicemail_uuid    = uuid,
            domain_uuid       = domain_uuid,
            tenant_id         = tenant_id,
            process_id        = process_id,
            call_uuid         = call_uuid,
            voicemail_id      = voicemail_id,
            caller_number     = caller_number,
            destination_number= destination_number,
            recording_path    = recording_path,
            record_ms         = record_ms
        })

        dbh:release()
        freeswitch.consoleLog("INFO", "[vm-lua] DB row inserted for voicemail " .. uuid .. "\n")
    else
        freeswitch.consoleLog("ERR", "[vm-lua] Could not connect to database to save voicemail metadata.\n")
    end

    -- Thank-you message ONLY if caller still connected
    if session:ready() then
        session:streamFile(thanks_file)
    end

    freeswitch.consoleLog("INFO", "[vm-lua] Recording finished. Duration ms: " .. tostring(record_ms) .. "\n")
end

return M
