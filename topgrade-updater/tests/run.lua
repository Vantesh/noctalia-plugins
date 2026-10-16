-- Run from the repository root: lua topgrade-updater/tests/run.lua
local root = "topgrade-updater/"
local core = dofile(root .. "core.luau")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local function header(name) return "―― 12:34:56 - " .. name .. " ――\n" end
local function result(out, code, err) return { stdout = out or "", stderr = err or "", exitCode = code or 0 } end
local steps, valid = core.discover("\27[32m" .. header("System") .. "Dry running: /usr/bin/paru -Syu\n" .. header("Custom") .. "Dry running: unknown-upgrader\n" .. header("Summary") .. "Dry running: ignored\n")
expect(valid and #steps == 2, "discover all steps, strip ANSI, stop at summary")
local plan, unknown = core.plan(steps)
expect(#plan == 2 and #unknown == 0, "repository and AUR queries ignore unrelated custom source")
for _, text in ipairs({ "", "format changed", header("System"), "Dry running: brew upgrade\n" }) do
    local _, complete = core.discover(text)
    expect(not complete, "empty, malformed, or truncated discovery must remain unknown")
end
local _, noCommands = core.plan({ { name = "System", commands = {} } })
expect(#noCommands == 1, "empty System heading cannot establish Arch coverage")
local _, partial = core.plan({ { name = "System", commands = { "pacman -Syu", "pacman -Sc" } } })
expect(#partial == 1, "unmapped Arch maintenance command remains uncertain")
local _, orphanValid = core.discover("Dry running: brew upgrade\n" .. header("Summary"))
expect(not orphanValid, "orphan commands cannot establish full discovery")
local _, malformedValid = core.discover(header("System") .. "Dry running: pacman -Syu\nDry running:\n" .. header("Summary"))
expect(not malformedValid, "malformed dry-run records invalidate completeness")
for _, command in ipairs({ "pacman --root /other -Syu", "pacman -r /other -Syu", "pacman -Syu -b/other",
    "pacman -Syur/other", "sudo sh -c 'pacman -Syu'", "env LC_ALL=C /usr/bin/fish -c 'yay -Syu'" }) do
    local _, alternate = core.plan({ { name = "System", commands = { command } } })
    expect(#alternate == 1, "alternate targets and launcher-prefixed shells remain uncertain: " .. command)
end
local _, compound = core.plan({ { name = "Custom", commands = { "pacman -Syu && other-tool update" } } })
expect(#compound == 1, "compound custom command is not fully covered")
local wrapped, wrappedUnknown = core.plan({ { name = "System", commands = { "/usr/bin/sudo /usr/bin/pacman -Syu", "/usr/bin/env LC_ALL=C /usr/bin/yay -Syu" } } })
expect(#wrapped == 2 and #wrappedUnknown == 0, "launcher prefixes preserve deduplicated Pacman/AUR discovery")

local screenshot = "brave-bin 1:1.97.57-1 -> 1:1.97.59-1 [38m]"
for _, tag in ipairs({ "[0m]", "[59m]", "[-38m]", "[1h]", "[23h59m]", "[1d]", "[38d8h]" }) do
    local parsed = core.parse(core.counters[2], result("\27[1mbrave-bin\27[0m \27[1m\27[32m1:1.97.57-1\27[0m\27[0m -> \27[1m\27[32m1:1.97.59-1\27[0m\27[0m " .. tag))
    expect(parsed and #parsed == 1 and parsed[1].to == "1:1.97.59-1", "parse Yay duration forms and actual nested SGR styling")
end
local styledAge = core.parse(core.counters[2], result("linux 1 -> 2 \27[1m\27[31m[38m]\27[0m\27[0m"))
expect(styledAge and styledAge[1].to == "2", "strip nested SGR styling from Yay age tags")
for _, tail in ipairs({ "[unknown]", "[38m] extra", "[38m] [1h]", "[1d2m]", "[1h60m]", "[24h]", "[1d24h]", "[60m]", "[01m]", "[0h]", "[38m", "garbage", "\27[2K[38m]" }) do
    local parsed, err = core.parse(core.counters[2], result("linux 1 -> 2 " .. tail))
    expect(parsed == nil and err:find("unrecognized query output", 1, true), "unknown or malformed suffixes must remain errors")
end
for _, counter in ipairs({ core.counters[1], core.counters[3] }) do
    expect(core.parse(counter, result(screenshot)) == nil, "Yay suffix support must not relax other manager formats")
end
expect(core.parse(core.counters[1], result("", 2)) ~= nil, "checkupdates exit 2 means clean")
for _, r in ipairs({ result("", 1), result("unexpected output"), result("", 0, "partial failure"), { timedOut = true }, result("linux 1 -> 2", 2) }) do
    expect(core.parse(core.counters[1], r) == nil, "errors cannot masquerade as zero packages")
end

for _, total in ipairs({ -1, 0, 1 }) do
    local state = { phase = "unknown", complete = false, total = total, unknown = { "query failed" } }
    expect(core.hidden(state) == (total <= 0), "default visibility follows count, not uncertainty")
    expect(not core.hidden(state, false), "explicit false shows non-dismissed results")
    state.dismissed = true
    expect(core.hidden(state) and core.hidden(state, false), "dismissal overrides both visibility settings")
end
expect(core.hidden(nil), "startup without a snapshot hides by default")
expect(core.hidden({ phase = "unknown", unknown = { "query failed" } }), "missing total hides by default")
expect(not core.hidden(nil, false), "disabled hiding shows startup without a snapshot")
expect(not core.hidden({ phase = "error", total = 1, complete = false, error = "offline" }), "positive incomplete error counts remain visible")

local function metadata(name, size)
    return "Repository : core\nName : " .. name .. "\nDownload Size : " .. size .. "\nInstalled Size : 999 GiB"
end
local names = { "linux", "tool" }
expect(core.downloadBytes(names, result(metadata("linux", "1.5 MiB") .. "\n\n" .. metadata("tool", "512 KiB"))) == 2 * 1024^2,
    "sum exact Download Size fields across package boundaries, not installed sizes")
for unit, factor in pairs({ B = 1, KiB = 1024, MiB = 1024^2, GiB = 1024^3, TiB = 1024^4 }) do
    expect(core.downloadBytes({ "linux" }, result(metadata("linux", "2.25 " .. unit))) == 2.25 * factor, "convert " .. unit)
end
for _, output in ipairs({ "", metadata("linux", "1 MiB"), metadata("linux", "1 MB"),
    metadata("linux", "1,5 MiB"), metadata("other", "1 MiB"),
    metadata("linux", "1 MiB") .. "\n" .. metadata("tool", "2 MiB"),
    metadata("linux", "1 MiB") .. "\n\n" .. metadata("linux", "2 MiB"),
    metadata("linux", "1 MiB") .. "\n\nName : tool\nVersion : 2" }) do
    expect(core.downloadBytes(names, result(output)) == nil, "missing, duplicate, malformed or incomplete records omit the entire estimate")
end
for _, flag in ipairs({ "timedOut", "stdoutTruncated", "stderrTruncated" }) do
    local reply = result(metadata("linux", "1 MiB")); reply[flag] = true
    expect(core.downloadBytes({ "linux" }, reply) == nil, "metadata " .. flag .. " cannot produce a total")
end
expect(core.downloadBytes({ "linux" }, result(metadata("linux", "1 MiB"), 1)) == nil, "failed metadata is unavailable")
expect(core.downloadBytes({ "linux" }, result(metadata("linux", "1 MiB"), 0, "warning")) == nil, "partial metadata diagnostics are unavailable")
expect(core.downloadBytes({ "linux" }, result(string.rep("x", 1024 * 1024 + 1))) == nil, "bound metadata output")
expect(core.formatDownload(372.5 * 1024^2) == "372.5 MiB" and core.formatDownload(1024^3) == "1.0 GiB", "deterministic binary size formatting")
for _, name in ipairs({ "--help", "-", "../linux", "linux;touch", "$(id)", "a/b", string.rep("a", 256) }) do
    expect(core.downloadBatches({ { name = name } }) == nil, "untrusted target is not queried: " .. name)
end
local many = {}
for i = 1, 501 do many[i] = { name = "pkg-" .. i } end
expect(core.downloadBatches(many) == nil, "bound optional query count")
table.remove(many)
local batches = core.downloadBatches(many)
expect(#batches == 10 and #batches[1] == 50 and batches[10][50] == "pkg-500", "bounded argv batches retain all names")
expect(core.downloadBatches({}) == nil, "no repository updates means no estimate")

-- Load the actual service with host API fakes; callbacks remain asynchronous.
local nativeRequire = require
require = function(path)
    if path == "./core.luau" then return core end
    if path == "./completion.luau" then return dofile(root .. "completion.luau") end
    if path == "./shared.luau" then return { STATE = "state", REQUEST = "request" } end
    return nativeRequire(path)
end
local callbacks, watches, latest, terminal = {}, {}, nil, nil
local receipt
local removed = false
local settings = { auto_check_hours = 6, topgrade_config = "/tmp/config with 'quote.toml" }
noctalia = {
    getConfig = function(key) return settings[key] end,
    notify = function() end,
    tr = function(key) return key end,
    trp = function(key) return key end,
    expandPath = function(path) return path end,
    commandExists = function() return true end,
    state = { set = function(_, value) latest = value end, watch = function(key, cb) watches[key] = cb end },
    runAsync = function(args, cb)
        if args[1] == "sh" then cb(result("/run/user/1000/noctalia-topgrade.lock")); return true end
        if args[1] == "flock" then cb(result("")); return true end
        table.insert(callbacks, { args = args, callback = cb }); return true
    end,
    formatTime = function() return "12:34" end,
    setUpdateInterval = function() end,
    runInTerminal = function(command) terminal = command; return true end,
    nowMs = function() return 0 end,
    readFile = function() return receipt end,
    removeFile = function() removed = true; return true end,
}
dofile(root .. "service.luau")
expect(latest.phase == "idle" and not latest.complete and core.hidden(latest), "startup is hidden without claiming clean")
for _ = 1, 10 do update() end
expect(#callbacks == 1 and latest.phase == "checking", "automatic startup discovery")
expect(callbacks[1].args[6] == settings.topgrade_config, "config path stays a single argv argument")
onIpc("check")
expect(#callbacks == 1, "no overlapping checks")
callbacks[1].callback(result(header("System") .. "Dry running: pacman -Syu\n" .. header("Summary")))
callbacks[2].callback(result("", 2))
onIpc("update")
callbacks[3].callback(result("/tmp/noctalia-topgrade.test123"))
local updateCommand = "topgrade -k --no-self-update --notify-end never --config " .. core.quote(settings.topgrade_config)
expect(terminal == dofile(root .. "completion.luau").command("/tmp/noctalia-topgrade.test123",
    { "sh", "-c", updateCommand }, "/run/user/1000/noctalia-topgrade.lock"), "wrapped default update uses exact flags and the same quoted config")
receipt = "done 0\n"
update()
callbacks[4].callback(result("new format"))
expect(latest.phase == "unknown", "unrecognized discovery never becomes clean")
onIpc("check")
callbacks[5].callback(result(header("System") .. "Dry running: pacman -Syu\n" .. header("Summary"), 0, "Warning: some steps skipped"))
callbacks[6].callback(result("", 2))
expect(latest.phase == "unknown", "discovery warnings prevent clean classification")
settings.auto_check_hours = 0
local before = #callbacks
for _ = 1, 30 do update() end
expect(#callbacks == before, "zero disables automatic checks")
settings.topgrade_config = "/tmp/changed.toml"
update()
expect(latest.phase == "checking" and callbacks[7].args[6] == settings.topgrade_config, "config changes invalidate results")
callbacks[7].callback({ timedOut = true })
expect(latest.phase == "error" and not latest.complete and latest.error and core.hidden(latest), "discovery timeout hides zero but retains incomplete error state")
noctalia.runAsync = function() return false end
onIpc("check")
expect(latest.phase == "error", "spawn failure remains an error")
noctalia.commandExists = function() return false end
onIpc("check")
expect(latest.phase == "error" and latest.error:find("not installed", 1, true), "missing Topgrade retains actionable error")
-- Fresh singleton instance: dismissal is session-only, not restored from settings.
callbacks = {}
noctalia.commandExists = function() return true end
noctalia.runAsync = function(args, cb)
    if args[1] == "sh" then cb(result("/run/user/1000/noctalia-topgrade.lock")); return true end
    if args[1] == "flock" then cb(result("")); return true end
    table.insert(callbacks, { args = args, callback = cb })
    return true
end
settings.auto_check_hours = 1
receipt = nil
dofile(root .. "service.luau")
expect(not latest.dismissed, "startup does not restore dismissal")
local function tick(n) for _ = 1, n do update() end end
local function pending()
    callbacks[#callbacks].callback(result(header("System") .. "Dry running: pacman -Syu\n" .. header("Summary")))
    callbacks[#callbacks].callback(result("linux 1 -> 2\n", 0, "partial failure"))
end
local function ready()
    callbacks[#callbacks].callback(result(header("System") .. "Dry running: pacman -Syu\n" .. header("Summary")))
    callbacks[#callbacks].callback(result("linux 1 -> 2\n"))
    expect(latest.phase == "ready" and latest.total == 1, "publish counts before optional metadata finishes")
    callbacks[#callbacks].callback(result(metadata("linux", "372.5 MiB")))
end
onIpc("refresh")
expect(latest.phase == "checking" and #callbacks == 1, "refresh alias actually starts discovery")
ready()
tick(1800)
local counts, unknown = latest.counts, latest.unknown
watches.request({ nonce = 1, action = "dismiss" })
expect(core.hidden(latest, false) and latest.total == 1 and latest.counts == counts and latest.unknown == unknown,
    "service dismissal hides pending updates even with hide_on_empty false and retains results")
local beforeDismiss = #callbacks
tick(1799)
expect(latest.dismissed and #callbacks == beforeDismiss, "normal ticks cannot resurface or refresh dismissed results early")
tick(1)
expect(not latest.dismissed and latest.phase == "checking" and #callbacks == beforeDismiss + 1,
    "scheduled refresh clears dismissal at original interval, not an interval after dismissal")
-- Dismiss during discovery, then let real query callbacks republish and finish.
onIpc("dismiss")
onIpc("refresh")
onIpc("update")
expect(latest.dismissed and #callbacks == beforeDismiss + 1, "busy refresh/update cannot clear dismissal or overlap discovery")
pending()
expect(latest.dismissed and latest.phase == "unknown" and #latest.unknown == 1 and core.hidden(latest, false),
    "in-flight uncertain results retain dismissal through all publications")
settings.auto_check_hours = 0
local disabledCount = #callbacks
tick(7200)
expect(latest.dismissed and #callbacks == disabledCount, "interval zero leaves dismissal in place indefinitely")
watches.request({ nonce = 2, action = "refresh" })
expect(not latest.dismissed and latest.phase == "checking" and #callbacks == disabledCount + 1,
    "shared refresh request clears dismissal and starts discovery even with automatic checks disabled")
ready()
onIpc("dismiss")
onIpc("check")
expect(not latest.dismissed and latest.phase == "checking", "legacy check IPC also clears dismissal")
ready()
onIpc("dismiss")
onIpc("refresh")
expect(not latest.dismissed and latest.phase == "checking", "manual refresh IPC clears an existing dismissal")
ready()
-- Dismissing a running upgrade cannot remove its receipt or interrupt tracking.
onIpc("update")
callbacks[#callbacks].callback(result("/tmp/noctalia-topgrade.dismiss123"))
removed = false
onIpc("dismiss")
local runningCount = #callbacks
onIpc("refresh")
tick(3)
expect(latest.phase == "running" and latest.dismissed and #callbacks == runningCount and not removed,
    "dismiss and busy refresh leave active update tracking untouched")
receipt = "done 0\n"
update()
expect(latest.phase == "checking" and not latest.dismissed and removed,
    "post-update check is a new refresh and clears dismissal without losing completion tracking")
ready()
-- Metadata is optional work, not a checking phase or an update interlock.
onIpc("refresh")
callbacks[#callbacks].callback(result(header("System") .. "Dry running: pacman -Syu\n" .. header("Summary")))
callbacks[#callbacks].callback(result("linux 1 -> 2"))
local staleMetadata = callbacks[#callbacks].callback
onIpc("dismiss")
staleMetadata(result(metadata("linux", "1 MiB")))
expect(latest.dismissed and latest.downloadBytes == 1024^2 and core.hidden(latest, false), "metadata publications retain dismissal")
onIpc("refresh")
callbacks[#callbacks].callback(result(header("System") .. "Dry running: pacman -Syu\n" .. header("Summary")))
callbacks[#callbacks].callback(result("linux 1 -> 2"))
staleMetadata = callbacks[#callbacks].callback
onIpc("refresh")
staleMetadata(result(metadata("linux", "9 MiB")))
expect(latest.phase == "checking" and latest.downloadBytes == nil, "new check invalidates late metadata")
callbacks[#callbacks].callback(result(header("System") .. "Dry running: pacman -Syu\n" .. header("Summary")))
callbacks[#callbacks].callback(result("linux 1 -> 2"))
staleMetadata = callbacks[#callbacks].callback
onIpc("update")
staleMetadata(result(metadata("linux", "9 MiB")))
expect(latest.phase == "running" and latest.downloadBytes == nil, "update does not wait for metadata and invalidates its callback")
require = nativeRequire

print("Passed " .. checks .. " assertions")
