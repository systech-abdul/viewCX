--local handlers = require "features_handlers"
--local Database = require "resources.functions.database"
--local dbh = Database.new("system")
--assert(dbh:connected())

local M = {}

function M.did_ivrs(session, dbh,id)
    if not session:ready() then
        freeswitch.consoleLog("ERR", "[did_ivrs] Session not ready\n")
        return false
    end

    local args = {}
     
    freeswitch.consoleLog("INFO", string.format("[did_ivrs] ID type=%s, value=%s\n", type(id), tostring(id)))

    local sql = string.format([[
        SELECT menu.ivr_menu_uuid, menu.ivr_menu_name, menu.ivr_menu_extension, menu.domain_uuid
        FROM v_ivr_menus AS menu
        JOIN ivrs ON ivrs.start_node = menu.ivr_menu_uuid
        WHERE ivrs.id = %d
    ]], id)

    local found = false

    dbh:query(sql, function(row)
        found = true
        args.start_node = row.ivr_menu_uuid
        args.menu_name = row.ivr_menu_name
        args.destination = row.ivr_menu_extension
        args.domain_uuid = row.domain_uuid
    end)

    if found then
        freeswitch.consoleLog("INFO", string.format(
            "[did_ivrs] IVR Menu found: UUID=%s, menu_name=%s, destination=%s, domain_uuid=%s\n",
            tostring(args.start_node),
            tostring(args.menu_name),
            tostring(args.destination),
            tostring(args.domain_uuid)
        ))

        -- Set session variables for IVR
        session:setVariable("ivr_menu_extension", tostring(args.destination))
        session:setVariable("parent_ivr_id", tostring(args.destination))

        -- Call IVR handler from your features_handlers module
        handlers.ivr(args)
    else
        freeswitch.consoleLog("ERR", "[did_ivrs] No IVR Menu found for ivrs.id = " .. tostring(id) .. "\n")
        session:execute("playback", "ivr/ivr-not_available.wav")
    end

    return true
end

return M
