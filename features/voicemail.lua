-- features/voicemail.lua

local path_util = require "utils.path"
local vm = require "custom_voicemail"
local M = {}

function M.handle(session, dbh, destination_number, domain_name, domain_uuid)
    if not session:ready() then
        freeswitch.consoleLog("ERR", "[voicemail] Session not ready\n")
        return false
    end

    freeswitch.consoleLog("INFO",
        "[voicemail] Start: " .. destination_number .. "@" .. domain_name .. "\n")

    ------------------------------------------------------------------
    -- Fetch voicemail config
    ------------------------------------------------------------------
    local greeting_file, thanks_file
    local playback_terminator, beep_tone

    local sql = [[
        SELECT 
            v.voicemail_id, v.playback_terminator, v.beep_tone,
            r1.recording_filename AS greeting_filename,
            r2.recording_filename AS thanks_filename
        FROM v_voicemails v
        LEFT JOIN v_recordings r1 ON v.greeting_id = r1.recording_uuid
        LEFT JOIN v_recordings r2 ON v.thanks_greet = r2.recording_uuid
        WHERE v.voicemail_id = :vm_id
        AND v.domain_uuid = :domain_uuid
    ]]

    dbh:query(sql, {
        vm_id = destination_number,
        domain_uuid = domain_uuid
    }, function(row)
        greeting_file = row.greeting_filename
        thanks_file = row.thanks_filename
        playback_terminator = row.playback_terminator
        beep_tone = row.beep_tone
    end)

    ------------------------------------------------------------------
    -- Paths
    ------------------------------------------------------------------
    local base_path = path_util.recording_path(domain_name)

    local greeting_path = greeting_file and (base_path .. greeting_file) or ""
    local thanks_path   = thanks_file and (base_path .. thanks_file) or ""

    ------------------------------------------------------------------
    -- Session Variables
    ------------------------------------------------------------------
    session:setVariable("playback_terminators", "")
    session:setVariable("skip_greeting", "true")
    session:setVariable("skip_instructions", "true")
    session:setVariable("voicemail_terminate_on_silence", "false")
    session:setVariable("domain_name", domain_name)
    session:setVariable("voicemail_id", destination_number)

    ------------------------------------------------------------------
    -- Recording Directory
    ------------------------------------------------------------------
    local record_base_dir = string.format(
        "/var/lib/freeswitch/recordings/%s/voicemails",
        domain_name
    )

    ------------------------------------------------------------------
    -- Record Voicemail (custom module)
    ------------------------------------------------------------------
    if vm and vm.record_voicemail then
        vm.record_voicemail(session, {
            beep_tone          = beep_tone,
            playback_terminator= playback_terminator,
            record_base_dir    = record_base_dir,
            welcome_file       = greeting_path,
            thanks_file        = thanks_path,
            max_len_seconds    = 600,
            silence_threshold  = 0,
        })
    else
        freeswitch.consoleLog("ERR", "[voicemail] vm.record_voicemail not found\n")
        return false
    end

    return true
end

return M
