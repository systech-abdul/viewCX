local Database = require "resources.functions.database"

local caller_handler = {}

local dbh = Database.new("system")
assert(dbh:connected())

function caller_handler.upsert_caller_profile()
    if not dbh then
        freeswitch.consoleLog("ERR", "[caller_profile] dbh is nil\n")
        return nil
    end


    local domain_uuid = session:getVariable("domain_uuid") or ""
    local tenant_id = session:getVariable("tenant_id") or 0
    local process_id = session:getVariable("process_id") or 0
    local caller_number = session:getVariable("caller_id_number") or ""
    local last_xml_cdr_uuid = session:getVariable("call_uuid") or ""
    local language_code = session:getVariable("language_code") or ""

    -- IMPORTANT for language behavior:
    --   - nil or ""  => do NOT update language on conflict (as per SQL function)
    --   - non-empty  => update language on conflict
    -- session:execute("info") 
    local sql = [[
        SELECT *
        FROM public.upsert_caller_profile(
            :domain_uuid,
            :tenant_id,
            :process_id,
            :caller_number,
            :last_xml_cdr_uuid,
            :language_code
        )
    ]]

    local row = nil

    freeswitch.consoleLog(
  "info",
  string.format(
    "[caller_profile] domain_uuid=%s, tenant_id=%s, process_id=%s, caller_number=%s, last_xml_cdr_uuid=%s, language_code=%s\n",
    tostring(domain_uuid),
    tostring(tenant_id),
    tostring(process_id),
    tostring(caller_number),
    tostring(last_xml_cdr_uuid),
    tostring(language_code)
  )
)

    local ok = dbh:query(sql, {
        domain_uuid       = domain_uuid,
        tenant_id         = tenant_id,
        process_id        = process_id,
        caller_number     = caller_number,
        last_xml_cdr_uuid = last_xml_cdr_uuid,
        language_code     = language_code,
    }, function(r)
        row = r
    end)

    if not ok then
        freeswitch.consoleLog("ERR", "[caller_profile] DB query failed\n")
        return nil
    end

    if not row then
        freeswitch.consoleLog("ERR", "[caller_profile] no row returned from upsert\n")
        return nil
    end

    session:setVariable("language_code", row.language_code)
    -- optional logging
    freeswitch.consoleLog("INFO", string.format(
        "[caller_profile] caller=%s tenant=%s process=%s calls=%s lang=%s id=%s\n",
        row.caller_number or "nil",
        row.tenant_id or "nil",
        row.process_id or "nil",
        row.call_count or "nil",
        row.language_code or "nil",
        row.id or "nil"
    ))

    return row
end

return caller_handler 