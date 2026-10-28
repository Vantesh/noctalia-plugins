-- Run from the repository root: lua aula-f75/tests/status.lua
local status = dofile("aula-f75/status.luau")
local checks = 0
local function expect(value, why) checks = checks + 1; assert(value, why) end
local function fixture()
    return { schema_version = 1, command = "status", ok = true,
        observed_native_effects = {{ id = 2, name = "respire" }},
        devices = {{ transport = "wired", interface_verified = true, keyboard_connected = true,
            protocol_verified = true, state = "verified_read_only", model = { matches_expected = true },
            configuration = { lighting_mode = "hardware_effect", active_effect = { id = 2, name = "respire" },
                stored_native_effect_id = 2, effect_id = 2, effect_name = "respire", effect_name_scope = "active",
                brightness = 9, speed = 2, color_name = "green", color_index = 1 } }} }
end
local function read(report, code)
    return status.read({ stdout = "captured JSON", exitCode = code or 0 }, function() return report end)
end
local native = read(fixture())
expect(native.connection.transport == "wired" and native.connection.label == "Connected · USB", "connection label derives from verified backend transport")
expect(native.phase == "ready" and native.active == "Respire" and native.nativeObserved, "verified Respire uses active_effect and root observations")
expect(native.brightness == "9 / 9" and native.speed == "2 / 4" and native.palette == "Green", "firmware levels are not percentages")
expect(status.label("rainbow_wheel") == "Rainbow Wheel" and status.label("self_defined") == "Self-defined", "human-readable effect names")
local report = fixture()
local c = report.devices[1].configuration
c.lighting_mode, c.active_effect = "per_key", { id = 21, name = "self_defined" }
c.stored_native_effect_id, c.effect_id, c.effect_name, c.effect_name_scope = 18, 18, "storm", "saved_selection"
c.speed, c.color_index, c.color_name = nil, nil, "red"
c.observed_native_effects = {{ id = 18, name = "storm" }}
local custom = read(report)
expect(custom.active == "Self-defined" and custom.stored == "Storm (18)", "retained Storm is never presented as active")
expect(custom.speed == "Unavailable" and custom.palette == "Unavailable", "null/unsupported fields never become zero or active palette")
expect(custom.nativeObserved == nil, "per-key mode is not a native observation")
report = fixture(); c = report.devices[1].configuration
c.active_effect, c.effect_id = { id = 18, name = "storm" }, 18
c.observed_native_effects = {{ id = 18, name = "storm" }}
expect(read(report).nativeObserved == false, "configuration observations cannot override the root field")
report = fixture(); c = report.devices[1].configuration
c.brightness, c.speed, c.color_index, c.color_name = 0, 0, 0, "red"
expect(read(report).brightness == "0 / 9" and read(report).speed == "0 / 4", "zero is a valid firmware level")
c.brightness, c.speed, c.color_index = 12, -1, nil
expect(read(report).brightness == "Unavailable" and read(report).speed == "Unavailable" and read(report).palette == "Unavailable", "invalid levels stay unavailable")
for _, field in ipairs({"interface_verified", "keyboard_connected", "protocol_verified"}) do
    report = fixture(); report.devices[1][field] = false
    expect(read(report).phase ~= "ready", "unverified device cannot show current settings: " .. field)
end
report = fixture(); report.devices[1].model.matches_expected = false
expect(read(report).phase == "unsupported", "model mismatch is unsupported")
report = fixture(); report.ok = false; report.error = { code = "status_unavailable" }
report.devices[1].error = { code = "permission_denied" }
expect(read(report, 1).message == "Keyboard access denied", "specific per-device errors take priority over status_unavailable")
report.devices[1].error = { code = "unverified_interface" }
expect(read(report, 1).message == "Unsupported device or transport", "actual backend interface error is recognized")
report.devices = {}; report.error = { code = "device_not_found" }
expect(read(report, 1).message == "Keyboard disconnected", "missing hardware is not a zero-valued lighting state")
report = fixture()
expect(read(report, 1).phase == "error", "nonzero exit cannot produce a verified status")
report.schema_version = 2
expect(read(report).phase == "error", "unsupported schema is rejected")
report = fixture(); report.devices[1].configuration.active_effect = nil
expect(read(report).phase == "error", "old fields cannot substitute for missing active_effect")
for _, result in ipairs({
    { stdout = "{", exitCode = 0 },
    { stdout = "{}", exitCode = 0, timedOut = true },
    { stdout = "{}", exitCode = 0, stdoutTruncated = true },
    { stdout = "{}", exitCode = 0, stderrTruncated = true },
    { stdout = string.rep("x", 65537), exitCode = 0 },
}) do
    expect(status.read(result, function() return nil, "invalid JSON" end).phase == "error", "malformed, truncated and timed-out output is rejected")
end
expect(status.read({ stdout = "{}", exitCode = 0 }, function() error("decode failure") end).phase == "error", "decoder exceptions do not escape")

-- Execute the real service with host fakes. No process or keyboard is opened.
local values, watchers, jobs, available, started = {}, {}, {}, true, true
noctalia = {
    state = { get = function(key) return values[key] end,
        set = function(key, value) values[key] = value; if watchers[key] then watchers[key](value) end end,
        watch = function(key, callback) watchers[key] = callback end },
    commandExists = function(name) expect(name == "aulaf75ctl", "only backend PATH lookup"); return available end,
    json = { decode = function(raw) if raw == "broken" then return nil, "invalid JSON" end; return fixture() end },
    runAsync = function(args, callback, timeout)
        expect(table.concat(args, " ") == "aulaf75ctl status --transport wired --json" and #args == 5, "only fixed read-only argv is permitted")
        expect(timeout == 5000, "bounded process timeout")
        jobs[#jobs + 1] = callback; return started
    end,
}
local originalRequire = require
require = function(path) if path == "./operations.luau" then return dofile("aula-f75/operations.luau") end; assert(path == "./status.luau"); return status end
dofile("aula-f75/service.luau")
require = originalRequire
expect(#jobs == 0 and values[status.STATE].phase == "idle", "service startup never reads hardware or polls")
status.request()
expect(#jobs == 1 and values[status.STATE].phase == "refreshing", "opening/request begins one refresh")
status.request(); expect(#jobs == 1, "overlapping requests are refused")
local first = jobs[1]
first({ stdout = "valid", exitCode = 0 })
expect(values[status.STATE].phase == "ready", "completed refresh publishes parsed status")
status.request(); expect(#jobs == 2, "manual refresh can follow completion")
first({ stdout = "broken", exitCode = 1 })
expect(values[status.STATE].phase == "refreshing", "late old callbacks cannot overwrite a newer request")
jobs[2]({ stdout = "broken", exitCode = 1 })
expect(values[status.STATE].phase == "error" and not values[status.STATE].active, "failed refresh clears old lighting settings")
expect(#jobs == 2, "malformed output never retries")
available = false; status.request()
expect(#jobs == 2 and values[status.STATE].message == "aulaf75ctl not installed", "missing CLI is detected before spawning")
available, started = true, false; status.request()
expect(values[status.STATE].phase == "error", "spawn failure is visible")
jobs[3]({ stdout = "valid", exitCode = 0 })
expect(values[status.STATE].phase == "error", "callback after failed spawn is ignored")
started = true; status.request()
local before = values[status.STATE]
onExit(); jobs[4]({ stdout = "valid", exitCode = 0 })
expect(values[status.STATE] == before, "destroyed service ignores pending callbacks")
print("AULA F75 status/service: " .. checks .. " checks passed")
