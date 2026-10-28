--!nonstrict
-- Udev properties are only a wake-up hint; aulaf75ctl verifies the device.
local M = {}
function M.parser(notify)
    local record = {}
    return function(line)
        if type(line) ~= "string" or #line > 4096 then return end
        if line:match("^UDEV%s") or line == "" then record = {}; return end
        local key, value = line:match("^([A-Z_]+)=(.*)$")
        if key == "ACTION" then record = { ACTION = value }
        elseif key == "ID_VENDOR_ID" or key == "ID_MODEL_ID" or key == "ID_USB_INTERFACE_NUM" then record[key] = value:lower() end
        if not record.sent and (record.ACTION == "add" or record.ACTION == "remove")
            and record.ID_VENDOR_ID == "258a" and record.ID_MODEL_ID == "010c"
            and record.ID_USB_INTERFACE_NUM == "01" then
            record.sent = true
            notify(record.ACTION)
        end
    end
end
return M
