--!nonstrict
local M = { STATE = "aula_f75.status", REQUEST = "aula_f75.refresh" }

local problems = {
    missing_cli = { "missing", "aulaf75ctl not installed", "Install aulaf75ctl and make it available on Noctalia's PATH." },
    device_not_found = { "disconnected", "Keyboard disconnected", "Connect the F75 in wired USB mode, then refresh." },
    disconnected = { "disconnected", "Keyboard disconnected", "Connect the F75 in wired USB mode, then refresh." },
    permission_denied = { "error", "Keyboard access denied", "Check the backend's interface-scoped udev permissions. Do not use sudo." },
    unsupported = { "unsupported", "Unsupported device or transport", "A verified wired F75 is required." },
    competing_controller = { "error", "Unable to read keyboard status", "Close other keyboard controllers, including F75 Studio, then refresh." },
    device_busy = { "error", "Unable to read keyboard status", "Another keyboard request is running. Refresh after it finishes." },
}

function M.problem(code, detail)
    local p = problems[code] or { "error", "Unable to read keyboard status", "Check aulaf75ctl and refresh when ready." }
    return { phase = p[1], message = p[2], detail = detail or p[3] }
end

function M.request()
    local previous = noctalia.state.get(M.REQUEST)
    noctalia.state.set(M.REQUEST, (type(previous) == "number" and previous or 0) + 1)
end

local function integer(n, maximum)
    return type(n) == "number" and n >= 0 and n <= maximum and n % 1 == 0
end

function M.label(name)
    if type(name) ~= "string" or #name > 64 or not name:match("^[a-z][a-z0-9_]*$") then return "Unknown" end
    if name == "self_defined" then return "Self-defined" end
    return (name:gsub("_", " "):gsub("%f[%a]%l", string.upper))
end

local function effect(value)
    return type(value) == "table" and integer(value.id, 255) and type(value.name) == "string"
end

local modes = { per_key = "Per-key", solid = "Solid", hardware_effect = "Onboard effect", off = "Off", unknown = "Unknown" }
local function deviceProblem(device)
    for _, e in ipairs({ device.error or false, device.model_error or false }) do
        if type(e) == "table" then
            if e.code == "unsupported_model" or e.code == "unverified_interface" then return M.problem("unsupported") end
            return M.problem(e.code)
        end
    end
end

function M.read(result, decode)
    if type(result) ~= "table" then return M.problem() end
    if result.timedOut then return M.problem(nil, "Status request timed out. Refresh when ready.") end
    if result.stdoutTruncated or result.stderrTruncated then return M.problem(nil, "Status output was truncated. No settings are shown.") end
    if type(result.stdout) ~= "string" or #result.stdout > 65536 then return M.problem() end
    local decoded, report = pcall(decode, result.stdout)
    if not decoded or type(report) ~= "table" or report.schema_version ~= 1 or report.command ~= "status"
        or type(report.ok) ~= "boolean" or type(report.devices) ~= "table" then
        return M.problem(nil, "Invalid or incompatible CLI output. Check that aulaf75ctl is up to date.")
    end
    local wired = {}
    for _, d in pairs(report.devices) do
        if type(d) ~= "table" then return M.problem() end
        if d.transport == "wired" then table.insert(wired, d) end
    end
    if result.exitCode ~= 0 or not report.ok then
        for _, d in ipairs(wired) do
            local problem = deviceProblem(d)
            if problem then return problem end
        end
        local code = type(report.error) == "table" and report.error.code or nil
        return M.problem(code)
    end
    if #wired ~= 1 then return M.problem("unsupported") end
    local d = wired[1]
    local problem = deviceProblem(d)
    if problem then return problem end
    if d.keyboard_connected == false then return M.problem("disconnected") end
    if d.transport ~= "wired" or d.interface_verified ~= true or d.protocol_verified ~= true
        or d.keyboard_connected ~= true or type(d.model) ~= "table" or d.model.matches_expected ~= true then
        return M.problem("unsupported")
    end
    local c = d.configuration
    if type(c) ~= "table" or not modes[c.lighting_mode] then return M.problem() end
    if c.active_effect ~= nil and not effect(c.active_effect) then return M.problem() end
    if c.active_effect == nil and c.lighting_mode ~= "unknown" then
        return M.problem(nil, "Active lighting information is missing. Update aulaf75ctl, then refresh.")
    end
    local active = c.active_effect
    local state = {
        phase = "ready", message = "Connected · USB",
        active = active and M.label(active.name) or "Unknown", mode = modes[c.lighting_mode],
        brightness = integer(c.brightness, 9) and tostring(c.brightness) .. " / 9" or "Unavailable",
        speed = integer(c.speed, 4) and tostring(c.speed) .. " / 4" or "Unavailable",
        palette = integer(c.color_index, 7) and M.label(c.color_name) or "Unavailable",
    }
    if c.effect_name_scope == "saved_selection" and integer(c.stored_native_effect_id, 255)
        and active and c.stored_native_effect_id ~= active.id then
        state.stored = M.label(c.effect_name) .. " (" .. c.stored_native_effect_id .. ")"
    end
    if active and c.lighting_mode ~= "per_key" and c.lighting_mode ~= "off"
        and type(report.observed_native_effects) == "table" then
        state.nativeObserved = false
        for _, observed in pairs(report.observed_native_effects) do
            if effect(observed) and observed.id == active.id then state.nativeObserved = true end
        end
    end
    local capabilities = type(d.capabilities) == "table" and d.capabilities or {}
    local effects, seen = {}, {}
    for _, e in ipairs(type(report.observed_native_effects) == "table" and report.observed_native_effects or {}) do
        if effect(e) and e.id > 0 and e.id < 19 and e.id ~= 9 and e.id ~= 14 and e.id ~= 18 and not seen[e.id] then
            effects[#effects + 1] = { id = e.id, name = M.label(e.name) }; seen[e.id] = true
        end
    end
    effects[#effects + 1] = { id = 21, name = "Self-defined" }
    effects[#effects + 1] = { id = 0, name = "Off" }
    state.controls = { active = active and active.id, effects = effects,
        brightness = active and active.id ~= 0 and capabilities.brightness == true and integer(c.brightness, 9) and c.brightness or nil,
        speed = active and active.id >= 2 and active.id <= 18 and integer(c.speed, 4) and c.speed or nil,
        palette = active and active.id >= 1 and active.id <= 18 and integer(c.color_index, 7) and c.color_index or nil,
        power = capabilities.lighting_power == true,
        dimmingVerified = capabilities.brightness_visual_verified == true }
    return state
end
return M
