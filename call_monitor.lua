-- call_hangup_monitor.lua / call_monitor.lua
-- FreeSWITCH mod_lua script
-- Actions: snoop | whisper | barge | conference
--
-- Args:
--   1) action
--   2) user_ext
--   3) user_domain
--   4) target (UUID OR call_uuid OR SIP Call-ID / token)
--   5) hint (OPTIONAL): phone OR agent extension (e.g., adhil)
--
-- Example:
--   lua call_hangup_monitor.lua snoop abdulh syscarecc.systech.ae <sip_call_id> adhil
--   lua call_hangup_monitor.lua snoop abdulh syscarecc.systech.ae <sip_call_id> 0565477441

local api = freeswitch.API()

local function trim(s)
  if not s then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function log(level, msg)
  freeswitch.consoleLog(level, "[call_monitor.lua] " .. msg .. "\n")
end

-- IMPORTANT: ESL needs a reply; otherwise it returns "-ERR no reply"
local function reply(msg)
  msg = tostring(msg or "")
  if stream and stream.write then
    stream:write(msg .. "\n")
  else
    -- If run interactively without stream, still log
    freeswitch.consoleLog("INFO", "[call_monitor.lua] reply(no-stream): " .. msg .. "\n")
  end
end

local function reply_ok(payload) reply("+OK " .. tostring(payload or "")) end
local function reply_err(reason) reply("-ERR " .. tostring(reason or "")) end

local function uuid_exists(u)
  u = trim(u)
  if u == "" then return false end
  local r = trim(api:executeString("uuid_exists " .. u))
  return (r == "true")
end

local function normalize_callid(s)
  s = trim(s)
  if s == "" then return "" end
  s = s:gsub("^<", ""):gsub(">$", "")
  s = s:gsub("^['\"]+", ""):gsub("['\"]+$", "")
  return string.lower(trim(s))
end

local function uuid_getvar(uuid, var)
  if not uuid or uuid == "" then return "" end
  local r = api:executeString("uuid_getvar " .. uuid .. " " .. var)
  return trim(r or ""):gsub("\r", "")
end

local function split_csv_line(line)
  local t = {}
  local i = 1
  for field in (line .. ","):gmatch("(.-),") do
    t[i] = field
    i = i + 1
  end
  return t
end

local function parse_lines(s)
  local lines = {}
  if not s or s == "" then return lines end
  s = s:gsub("\r", "")
  for line in s:gmatch("[^\n]+") do
    line = trim(line)
    if line ~= "" then table.insert(lines, line) end
  end
  return lines
end

local function choose_side_from_input(target_key)
  if uuid_exists(trim(target_key)) then
    return "w1"  -- input is UUID
  end
  return "w2"    -- input is NOT UUID (sip_call_id / call_uuid / token)
end

----------------------------------------------------------------------
-- 1) Find A-leg call_uuid by: hint (phone/ext) + sip_call_id
--    First tries: "show calls like <hint>" (fast & accurate)
----------------------------------------------------------------------
local function find_call_uuid_by_hint_and_sipid(hint, sipid)
  hint = trim(hint or "")
  sipid = normalize_callid(sipid or "")
  if hint == "" or sipid == "" then
    return nil, "hint and sip_call_id required"
  end

  local resp = api:executeString("show calls like " .. hint) or ""
  local lines = parse_lines(resp)
  if #lines < 2 then
    return nil, "no active calls matched hint=" .. hint
  end

  -- show calls columns:
  --  1: uuid (A-leg call uuid)
  -- 23: b_uuid
  for idx = 2, #lines do
    local line = lines[idx]
    if not line:find(" total%.") then
      local cols = split_csv_line(line)
      local a_uuid = trim(cols[1] or "")
      local b_uuid = trim(cols[23] or "")

      if a_uuid ~= "" and uuid_exists(a_uuid) then
        local a_sip = normalize_callid(uuid_getvar(a_uuid, "sip_call_id"))
        local b_sip = normalize_callid(uuid_getvar(b_uuid, "sip_call_id"))

        if a_sip == sipid or b_sip == sipid then
          return a_uuid, nil
        end
      end
    end
  end

  return nil, "no matching call for hint=" .. hint .. " and sip_call_id=" .. sipid
end

----------------------------------------------------------------------
-- 2) Fallback: use "show channels like <hint>" to collect candidate UUIDs,
--    then check uuid_getvar sip_call_id and return A-leg call_uuid if needed.
----------------------------------------------------------------------
local function find_call_uuid_via_channels_like(hint, sipid)
  hint = trim(hint or "")
  sipid = normalize_callid(sipid or "")
  if hint == "" or sipid == "" then
    return nil, "hint and sip_call_id required"
  end

  local resp = api:executeString("show channels like " .. hint) or ""
  local lines = parse_lines(resp)
  if #lines < 2 then
    return nil, "no channels matched hint=" .. hint
  end

  -- show channels columns: uuid is col 1, call_uuid is col 30 (from your header)
  for idx = 2, #lines do
    local line = lines[idx]
    if not line:find(" total%.") then
      local cols = split_csv_line(line)
      local u  = trim(cols[1] or "")
      local cu = trim(cols[30] or "")

      if u ~= "" and uuid_exists(u) then
        local sc = normalize_callid(uuid_getvar(u, "sip_call_id"))
        if sc == sipid then
          -- If we have a call_uuid, prefer returning A-leg call_uuid
          if cu ~= "" and uuid_exists(cu) then return cu, nil end
          return u, nil
        end
      end
    end
  end

  return nil, "no matching sip_call_id in channels for hint=" .. hint
end

----------------------------------------------------------------------
-- Resolve target UUID from:
-- - direct uuid_exists
-- - match uuid/b_uuid/call_uuid via show channels json
-- - match sip_call_id by scanning live channel uuids
-- - if not uuid and hint provided: match sip_call_id only within calls/channels filtered by hint
----------------------------------------------------------------------
local function resolve_target_uuid(input_key, hint_opt)
  input_key = trim(input_key)
  if input_key == "" then
    return nil, "Empty target provided", nil
  end

  -- 1) direct UUID
  if uuid_exists(input_key) then
    return input_key, nil, "uuid_exists"
  end

  local wanted_callid = normalize_callid(input_key)

  -- 1.5) If hint provided and input looks like call-id/token: try hint-based exact resolution first
  if hint_opt and trim(hint_opt) ~= "" and wanted_callid ~= "" then
    local cu, e = find_call_uuid_by_hint_and_sipid(hint_opt, wanted_callid)
    if cu and uuid_exists(cu) then
      return cu, nil, "show_calls_like(hint)+sip_call_id"
    end
    -- fallback to channels-like
    local cu2, e2 = find_call_uuid_via_channels_like(hint_opt, wanted_callid)
    if cu2 and uuid_exists(cu2) then
      return cu2, nil, "show_channels_like(hint)+sip_call_id"
    end
    -- keep going (global resolution)
  end

  local json_str = api:executeString("show channels as json")
  if not json_str or json_str == "" then
    return nil, "Could not read channels", nil
  end

  local ok, decoded = pcall(function()
    return require("cjson").decode(json_str)
  end)

  if not ok or not decoded then
    return nil, "Failed to decode channel JSON (cjson missing?)", nil
  end

  local rows = decoded.rows or {}

  -- 2) match by uuid / b_uuid / call_uuid (FAST path)
  for _, row in ipairs(rows) do
    local u  = trim(row.uuid or "")
    local bu = trim(row.b_uuid or "")
    local cu = trim(row.call_uuid or "")

    if u == input_key and uuid_exists(u) then
      return u, nil, "match.uuid"
    end
    if bu == input_key and uuid_exists(bu) then
      return bu, nil, "match.b_uuid"
    end

    if cu ~= "" and cu == input_key then
      if uuid_exists(u) then return u, nil, "match.call_uuid->uuid" end
      if uuid_exists(bu) then return bu, nil, "match.call_uuid->b_uuid" end
    end
  end

  -- 3) best-effort SIP Call-ID scan across all live channels (SLOW)
  if wanted_callid ~= "" then
    for _, row in ipairs(rows) do
      local u = trim(row.uuid or "")
      if uuid_exists(u) then
        local sc = normalize_callid(uuid_getvar(u, "sip_call_id"))
        if sc ~= "" and sc == wanted_callid then
          return u, nil, "scan.uuid_getvar(sip_call_id)"
        end
      end
    end
  end

  return nil, "Target not found (uuid/b_uuid/call_uuid/sip_call_id)", nil
end

-- Originate commands
local function originate_snoop(ext, domain, uuid)
  return string.format(
    "originate {origination_caller_id_name='CallSnoop',origination_caller_id_number=0000,absolute_codec_string='PCMU'}user/%s@%s &eavesdrop(%s)",
    ext, domain, uuid
  )
end

local function originate_whisper(ext, domain, uuid, side)
  side = side or "w2"
  return string.format(
    "originate {origination_caller_id_name='CallWhisper',origination_caller_id_number=0000,absolute_codec_string=PCMU,media_bug_answer_req=true}user/%s@%s 'queue_dtmf:%s@500,eavesdrop:%s' inline",
    ext, domain, side, uuid
  )
end

local function originate_barge(ext, domain, uuid, side)
  side = side or "w2"
  return string.format(
    "originate {origination_caller_id_name='CallBarge',origination_caller_id_number=0000,absolute_codec_string=PCMU,media_bug_answer_req=true}user/%s@%s 'queue_dtmf:%s@500,eavesdrop:%s' inline",
    ext, domain, side, uuid
  )
end

local function originate_conference(ext, domain, uuid)
  return string.format(
    "originate {absolute_codec_string=PCMU,media_bug_answer_req=true}user/%s@%s 'queue_dtmf:w3@500,eavesdrop:%s' inline",
    ext, domain, uuid
  )
end

-- ---- main ----
local action      = trim(argv[1])
local user_ext    = trim(argv[2])
local user_domain = trim(argv[3])
local target_key  = trim(argv[4])
local hint_opt    = trim(argv[5] or "") -- phone OR agent extension

if action == "" or user_ext == "" or user_domain == "" or target_key == "" then
  log("ERR", "Usage: lua call_monitor.lua <snoop|whisper|barge|conference> <user_ext> <user_domain> <uuid|call_uuid|sip_call_id> [phone|agent_ext]")
  reply_err("Usage")
  return
end

local target_uuid, err, how = resolve_target_uuid(target_key, hint_opt)
if not target_uuid then
  log("ERR", "Could not resolve target [" .. target_key .. "]: " .. (err or "unknown error"))
  reply_err("resolve_failed: " .. (err or "unknown"))
  return
end

local target_key  = trim(argv[4])       -- original input
local side = choose_side_from_input(target_key)

local cmd
if action == "snoop" then
  cmd = originate_snoop(user_ext, user_domain, target_uuid)
if action == "whisper" then
  cmd = originate_whisper(user_ext, user_domain, target_uuid, side)
elseif action == "barge" then
  cmd = originate_barge(user_ext, user_domain, target_uuid, side)
elseif action == "conference" then
  cmd = originate_conference(user_ext, user_domain, target_uuid)
else
  log("ERR", "Invalid action: " .. action .. " (use snoop|whisper|barge|conference)")
  reply_err("invalid_action")
  return
end

log("INFO", "Resolved target [" .. target_key .. "] -> uuid=" .. target_uuid .. " via " .. tostring(how))
log("INFO", "Executing: " .. cmd)

local res = api:executeString(cmd)
log("INFO", "Result: " .. (res or ""))

-- Return ONLY the resolved UUID (clean for ESL callers)
reply_ok(target_uuid)
