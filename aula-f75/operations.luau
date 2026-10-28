--!nonstrict
-- Shared command/presentation helpers; raw reviews stay private to the service.
local M = { KEY = "aula_f75.operation", REQUEST = "aula_f75.action" }
local limits = { brightness = 9, speed = 4, palette = 7 }
function M.allowed(s, kind, value)
    if not s or s.phase ~= "ready" or s.busy or not s.controls then return false end
    local c = s.controls
    if type(c.active) ~= "number" then return false end
    if limits[kind] then
        return c[kind] ~= nil and type(value) == "number" and value % 1 == 0
            and value >= 0 and value <= limits[kind] and value ~= c[kind]
    end
    if kind == "effect" then
        for _, e in ipairs(c.effects) do if e.id == value then return value ~= c.active end end
    end
    return (kind == "off" and c.active ~= 0 and c.power == true) or (kind == "on" and c.active == 0 and c.onAvailable == true)
end
function M.args(kind, value)
    local args = { "aulaf75ctl", "lighting", kind }
    if limits[kind] or kind == "effect" then args[#args + 1] = tostring(value) end
    args[#args + 1] = "--transport"; args[#args + 1] = "wired"
    return args
end
function M.decode(result, kind)
    if type(result) ~= "table" or result.timedOut or result.stdoutTruncated or result.stderrTruncated
        or type(result.stdout) ~= "string" or #result.stdout > 262144 then return nil end
    local ok, r = pcall(noctalia.json.decode, result.stdout)
    if not ok or type(r) ~= "table" or r.schema_version ~= 1 or r.command ~= "lighting_" .. kind then return nil end
    return r
end
function M.plan(r, kind, value)
    local p = r and r[(kind == "off" or kind == "on") and "power_plan" or kind .. "_plan"]
    if not r or r.ok ~= true or r.review_ready ~= true or type(p) ~= "table"
        or p.persistent ~= true or p.approval_required ~= true or type(p.no_op) ~= "boolean" or type(p.review_state) ~= "table"
        or type(p.review_state.configuration_hex) ~= "string" or #p.review_state.configuration_hex ~= 256
        or type(p.review_state.matrix_hex) ~= "string" or #p.review_state.matrix_hex ~= 768
        or not p.review_state.configuration_hex:match("^%x+$") or not p.review_state.matrix_hex:match("^%x+$") then return nil end
    -- Reject malformed display objects before private storage is allocated.
    -- Otherwise indexing a number/null target can strand review preparation.
    for _, key in ipairs({ "previous_effect", "active_effect", "previous_palette", "requested_palette" }) do
        if p[key] ~= nil and (type(p[key]) ~= "table" or type(p[key].name) ~= "string") then return nil end
    end
    if kind == "on" then
        local target = type(p.power) == "table" and p.power.restoration_target
        if type(target) ~= "table" or type(target.name) ~= "string" or type(target.id) ~= "number"
            or target.id <= 0 or target.id > 255 or target.id % 1 ~= 0 then return nil end
    end
    if kind == "effect" and (type(p.requested_effect) ~= "table" or p.requested_effect.id ~= value) then return nil end
    if kind == "brightness" and p.requested_brightness ~= value then return nil end
    if kind == "speed" and p.requested_speed ~= value then return nil end
    if kind == "palette" and (type(p.requested_palette) ~= "table" or p.requested_palette.index ~= value) then return nil end
    if (kind == "off" or kind == "on") and (type(p.power) ~= "table" or p.power.action ~= kind) then return nil end
    return p
end
function M.error(report, fallback)
    local code = report and type(report.error) == "table" and report.error.code
    local messages = {
        review_mismatch = "Keyboard state changed; refresh and review again.",
        invalid_review = "Invalid review; prepare a new review.",
        incomplete_review = "Incomplete review; prepare a new review.",
        device_not_found = "Keyboard disconnected.", disconnected = "Keyboard disconnected.",
        permission_denied = "Keyboard access denied; check ordinary-user HID permissions.",
        unsupported = "Requested setting unsupported.", unsupported_effect = "Requested effect unsupported.",
        unsupported_configuration = "Requested setting unsupported in this mode.",
        restoration_unavailable = "Power restoration unavailable for this USB session.",
        restoration_instance_changed = "USB session changed; power restoration unavailable.",
        competing_controller = "Close other keyboard controllers, then refresh.",
    }
    return messages[code] or fallback
end
function M.send(action)
    local n = noctalia.state.get(M.REQUEST)
    action.nonce = type(n) == "table" and (n.nonce or 0) + 1 or 1
    noctalia.state.set(M.REQUEST, action)
end
return M
