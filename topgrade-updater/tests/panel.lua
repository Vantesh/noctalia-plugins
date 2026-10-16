-- Run from the repository root: lua topgrade-updater/tests/panel.lua
-- Exercise panel actions and count safety without launching commands or a shell.
local core = dofile("topgrade-updater/core.luau")
local _, plannerWarnings = core.plan({ { name = "System", commands = { "pacman --root /other -Syu" } } })
local state = {
    phase = "ready", total = 3, complete = false, checkedAt = "14:02",
    counts = {
        { key = "pacman", n = 3, items = { { name = "linux", from = "1", to = "2" } } },
        { key = "AUR (yay)", n = 0, items = {} },
    },
    unknown = { plannerWarnings[1], "Topgrade discovery diagnostics: some steps skipped" },
}
local tree, watcher, closed, writes = nil, nil, 0, 0
local request
local showDownloadSize = true
local topgradeAvailable = true
noctalia = {
    commandExists = function(command)
        assert(command == "topgrade", "availability must check the actual Topgrade executable")
        return topgradeAvailable
    end,
    getConfig = function() return showDownloadSize end, state = {
    get = function(key)
        if key == "topgrade_updater_state" then return state end
        return request
    end,
    set = function(key, value)
        assert(key == "topgrade_updater_request", "panel must never mutate service results")
        request = value
        writes = writes + 1
    end,
    watch = function(_, callback) watcher = callback end,
} }
ui = setmetatable({}, { __index = function(_, kind)
    return function(props, children) return { kind = kind, props = props, children = children or {} } end
end })
panel = {
    render = function(value) tree = value end,
    close = function() closed = closed + 1 end,
}
local nativeRequire = require
require = function(path)
    if path == "./core.luau" then return core end
    if path == "./shared.luau" then return dofile("topgrade-updater/shared.luau") end
    return nativeRequire(path)
end
dofile("topgrade-updater/panel.luau")
require = nativeRequire
local function find(predicate, node)
    node = node or tree
    if predicate(node.props) then return node.props end
    for _, child in ipairs(node.children) do
        local found = find(predicate, child)
        if found then return found end
    end
end
local function text(value) return find(function(p) return p.text == value end) end
onOpen()
assert(not text("Topgrade") and not text("OK"), "installed Topgrade status belongs only in the tooltip")
topgradeAvailable = false
onOpen()
assert(text("Topgrade") and text("Not found") and text("Not found").color == "error" and not text("OK"),
    "missing Topgrade must remain visible in the panel")
topgradeAvailable = true
onOpen()
assert(not text("Topgrade") and not text("Not found"), "restored Topgrade must remove the panel warning")

state.downloadBytes = 372.5 * 1024^2
watcher(state)
assert(text("≈ 372.5 MiB to download"), "render deterministic repository estimate")

showDownloadSize = false
watcher(state)
assert(not text("≈ 372.5 MiB to download"), "setting hides estimate")
showDownloadSize, state.downloadBytes = true, nil
watcher(state)
assert(not find(function(p) return p.key == "download-size" end), "unavailable metadata has no zero placeholder")

find(function(p) return p.key == "source-pacman" end).onClick()
assert(text("linux") and text("1") and text("2"), "source expansion must still expose package versions")
assert(not text("Up to date: AUR (yay)"), "real planner warnings must suppress clean-source claims")
local warning = find(function(p) return p.key == "unknown-summary" end)
assert(warning, "unknown status must remain visible while details are collapsed")
warning.onClick()
assert(text(state.unknown[1]) and text(state.unknown[2]), "all unknown details must be inspectable")
find(function(p) return p.tooltip == "Close" end).onClick()
assert(closed == 1 and writes == 0, "close X must close without dismissing results")
text("Dismiss").onClick()
assert(closed == 2 and writes == 1 and request.action == "dismiss" and request.nonce == 1,
    "Dismiss must route through the service request protocol and close the panel")
onOpen()
find(function(p) return p.tooltip == "Check for updates" end).onClick()
assert(request.action == "check", "refresh must request a check")
assert(text("Update").enabled, "positive displayed counts must enable update when idle")
text("Update").onClick()
assert(request.action == "update" and request.nonce == 3, "update must use the existing request protocol")
assert(closed == 3, "update must close the panel to release focus to the terminal")
state.unknown, state.complete = {}, true
watcher(state)
assert(text("Up to date: AUR (yay)"), "verified zero sources still have clean labels")
state.updateBlocked = "Topgrade is already running. Waiting for its lock to clear automatically."
watcher(state)
assert(not text("Update").enabled, "an interlock disables update even with positive counts")
text("Update").onClick()
assert(writes == 3 and closed == 3, "blocked callbacks cannot launch or close")
assert(text("Updates blocked: " .. state.updateBlocked),
    "panel must show the actionable automatic recovery warning without extra recovery instructions")
local blockedRefresh = find(function(p) return p.tooltip == "Check for updates" end)
assert(not blockedRefresh.enabled, "unresolved active lock disables premature count refresh")
blockedRefresh.onClick()
assert(writes == 3, "blocked refresh callback cannot send a count request")
state.updateBlocked = nil
for _, phase in ipairs({ "checking", "running" }) do
    state.phase = phase
    watcher(state)

    assert(not text("Update").enabled, "update must be disabled while busy")
    text("Update").onClick()
    assert(writes == 3 and closed == 3, "busy update callbacks must not launch or close")
    assert(not find(function(p) return p.tooltip == "Check for updates" end).enabled, "refresh must be disabled while busy")
    assert(not text("Up to date: AUR (yay)"), "old zero results must not be advertised while busy")
end
state.total, state.counts, state.unknown = 0, {}, {}
for _, phase in ipairs({ "idle", "clean", "unknown", "error", "checking", "running" }) do
    state.phase = phase
    watcher(state)
    assert(not text("Update").enabled, "zero displayed count must disable update in every phase")

    text("Update").onClick()
    assert(writes == 3 and closed == 3, "zero-count callbacks must not launch or close")
end
state.phase, state.updateError = "checking", "Topgrade failed or was interrupted (exit 129)"
watcher(state)
assert(text(state.updateError), "update failure may be shown during refresh")
state.phase, state.updateError, state.complete = "clean", nil, true
watcher(state)
assert(text("No enabled Pacman/AUR sources"), "fresh clean state replaces transient update failure")
state.phase, state.error = "error", "Topgrade discovery failed: offline"
watcher(state)
assert(text(state.error), "genuine discovery errors must remain visible")
assert(closed == 3, "state refreshes must not close or reopen the panel")
for _, phase in ipairs({ "checking", "running" }) do
    state.phase = phase
    watcher(state)
    assert(text("Dismiss").enabled ~= false, "dismiss remains available without interrupting busy work")
    local before = writes
    text("Dismiss").onClick()
    assert(writes == before + 1 and request.action == "dismiss", "busy dismiss must still route to service")
end
assert(closed == 5, "busy dismiss closes the panel too")
print("Panel behavior checks passed")
