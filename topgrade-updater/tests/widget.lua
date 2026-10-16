-- Run from the repository root: lua topgrade-updater/tests/widget.lua
-- Execute the production widget with host fakes, without commands or upgrades.
-- Guard the scope as well as rendering: global declarations pass lint but do
-- not receive named-widget overrides in Noctalia's settings seeding.
local manifest = assert(io.open("topgrade-updater/plugin.toml"))
local scope, field
local declared = {}
for line in manifest:lines() do
    local header = line:match("^%[%[(.-)%]%]$")
    if header then
        scope, field = header, nil
    else
        local key = line:match('^key = "(.-)"$')
        if key then
            field = { scope = scope }
            declared[key] = field
        elseif field then
            field.type = line:match('^type = "(.-)"$') or field.type
            field.default = line:match('^default = (.+)$') or field.default
        end
    end
end
manifest:close()
assert(declared.glyph.scope == "widget.setting" and declared.glyph.type == "glyph"
    and declared.glyph.default == '"pacman"', "glyph must be a widget setting with its native picker and pacman default")
assert(declared.hide_on_empty.scope == "widget.setting" and declared.hide_on_empty.type == "bool"
    and declared.hide_on_empty.default == "true", "hide_on_empty must be a per-widget setting enabled by default")
local settings, rendered = {}, {}
local state, watcher
local topgradeAvailable = true
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local function tooltipValue(key)
    for _, row in ipairs(rendered.tooltip) do
        if row.key == key then return row.value end
    end
end
noctalia = {
    commandExists = function(command)
        assert(command == "topgrade", "widget must check Topgrade on Noctalia's PATH")
        return topgradeAvailable
    end,
    getConfig = function(key)
        assert(declared[key], "widget read undeclared setting: " .. key)
        return settings[key]
    end,
    state = {
        get = function() return state end,
        watch = function(_, callback) watcher = callback end,
    },
    setUpdateInterval = function() end,
}
barWidget = {
    setGlyph = function(value) rendered.glyph = value end,
    setGlyphColor = function(value) rendered.color = value end,
    setText = function(value) rendered.text = value end,
    setVisible = function(value) rendered.visible = value end,
    setTooltip = function(value) rendered.tooltip = value end,
}
local nativeRequire = require
require = function(path)
    if path == "./core.luau" then return dofile("topgrade-updater/core.luau") end
    if path == "./shared.luau" then return dofile("topgrade-updater/shared.luau") end
    return nativeRequire(path)
end
dofile("topgrade-updater/widget.luau")
require = nativeRequire

expect(tooltipValue("Topgrade") == "OK", "startup tooltip must show Topgrade PATH availability")
topgradeAvailable = false
update()
expect(tooltipValue("Topgrade") == "Not found" and tooltipValue("Status") == "No pending packages",
    "missing Topgrade must not replace the separate update status")
topgradeAvailable = true
update()
expect(tooltipValue("Topgrade") == "OK", "timer rendering must refresh Topgrade PATH availability")
expect(not rendered.visible, "startup without a snapshot must hide the empty pacman icon")

local function publish(value)
    state = value
    watcher(value)
end
local clean = { phase = "clean", complete = true, total = 0, unknown = {} }
publish(clean)
expect(not rendered.visible, "unset hide setting must hide confirmed clean results")
settings.hide_on_empty = false
update()
expect(rendered.visible, "explicit false must override default hiding on the same clean result")
settings.glyph = "package"
publish({ phase = "ready", complete = true, total = 4, unknown = {},
    counts = { { key = "pacman", n = 3 }, { key = "AUR (yay)", n = 1 } }, checkedAt = "12:34" })
expect(tooltipValue("Topgrade") == "OK" and tooltipValue("Status") == "Updates available",
    "pending updates must not replace Topgrade PATH availability")
expect(tooltipValue("Pacman + AUR updates") == "4" and tooltipValue("Pacman") == "3"
    and tooltipValue("AUR (yay)") == "1" and tooltipValue("Last checked") == "12:34",
    "tooltip must preserve aggregate and source counts and check time")
expect(rendered.visible and rendered.text == "4" and rendered.glyph == "package",
    "updates must display their count with the configured glyph")

settings.glyph, settings.hide_on_empty = nil, nil
update()

publish({ phase = "ready", total = 2, unknown = {}, updateBlocked = "tracking was lost" })
expect(rendered.visible and rendered.color == "error" and tooltipValue("Status") == "Updates blocked: tracking was lost"
    and tooltipValue("Topgrade") == "OK" and tooltipValue("Pacman + AUR updates") == "2",
    "the safety interlock remains visible in diagnostics without discarding counts")
publish({ phase = "unknown", unknown = { "query failed" } })
expect(not rendered.visible and rendered.text == "?", "missing total must render safely and hide by default")

publish({ phase = "clean", complete = true, total = 0, unknown = { "query failed" } })
expect(not rendered.visible and rendered.text == "?", "uncertain zero counts hide without discarding warning badge")
publish({ phase = "clean", complete = true, total = 0, unknown = {}, updateError = "Update failed" })
expect(not rendered.visible and tooltipValue("Status") == "Update failed",
    "zero counts hide without discarding update errors")
publish({ phase = "error", complete = false, total = 1, unknown = { "query failed" }, error = "offline" })
expect(rendered.visible and rendered.text == "1?" and rendered.color == "error"
    and tooltipValue("Status") == "offline" and tooltipValue("Check warnings") == "query failed",
        "positive incomplete error counts remain visible with diagnostics")
topgradeAvailable = false
update()
expect(tooltipValue("Topgrade") == "Not found" and tooltipValue("Status") == "offline",
    "missing Topgrade must not discard check errors")
topgradeAvailable = true

local dismissed = { phase = "ready", total = 4, complete = false,
    unknown = { "query failed" }, dismissed = true }
publish(dismissed)
expect(not rendered.visible and rendered.text == "4?", "dismiss hides positive incomplete counts with default hiding")
settings.hide_on_empty = false
update()
expect(not rendered.visible, "dismiss hides independently even with hiding disabled")

publish({ phase = "checking", total = 0, unknown = {}, dismissed = false })
expect(rendered.visible, "a new check clears dismissal and renders checking")

-- Exercise both native entry routes against the production singleton and bus.
local file = assert(io.open("topgrade-updater/plugin.toml"))
local text = file:read("*a")
file:close()
local rightAction = assert(text:match('%[widget%.actions%]%s+right = "([^"]+)"'))
local endpoint, target, event = rightAction:match("^plugin (%S+) (%S+) (%S+)$")
expect(endpoint == "vantesh/topgrade-updater:service" and target == "all" and event == "refresh",
    "native right-click default must route refresh to the singleton service")
local shared = dofile("topgrade-updater/shared.luau")
local bus, watchers, jobs = {}, {}, {}
settings = { auto_check_hours = 1, show_download_size = false }
noctalia.state = {
    get = function(key) return bus[key] end,
    set = function(key, value)
        bus[key] = value
        for _, callback in ipairs(watchers[key] or {}) do callback(value) end
    end,
    watch = function(key, callback)
        watchers[key] = watchers[key] or {}
        table.insert(watchers[key], callback)
    end,
}
noctalia.getConfig = function(key) return settings[key] end
noctalia.commandExists = function() return true end
noctalia.runAsync = function(args, callback)
    jobs[#jobs + 1] = { args = args, callback = callback }
    return true
end
noctalia.formatTime = function() return "12:34" end
local panels = 0
noctalia.togglePanel = function(id)
    assert(id == "vantesh/topgrade-updater:panel")
    panels = panels + 1
end
require = function(path)
    if path == "./core.luau" then return dofile("topgrade-updater/core.luau") end
    if path == "./shared.luau" then return shared end
    if path == "./completion.luau" then return dofile("topgrade-updater/completion.luau") end
    return nativeRequire(path)
end
dofile("topgrade-updater/service.luau")
local serviceTick, serviceIpc = update, onIpc
dofile("topgrade-updater/widget.luau")
require = nativeRequire
local function latest() return bus[shared.STATE] end
local function reply(stdout, code)
    jobs[#jobs].callback({ stdout = stdout, stderr = "", exitCode = code or 0 })
end
local function discover()
    reply(" 12:00:00 - System ―\nDry running: pacman -Syu\n 12:00:00 - Summary ―\n")
    expect(jobs[#jobs].args[4] == "checkupdates", "refresh must reach the actual manager query argv")
end
expect(not rendered.visible, "integrated startup remains hidden")
for _ = 1, 10 do serviceTick() end
expect(latest().phase == "checking" and not rendered.visible, "automatic startup check cannot flash an empty icon")
discover()
reply("linux 1 -> 2\nvim 1 -> 2\n")
expect(rendered.visible and rendered.text == "2", "startup pending result shows fresh count")
onClick()
expect(panels == 1 and latest().phase == "ready", "left-click opens panel without refreshing")
-- Native action dispatch invokes onIpc, not the suppressed onRightClick callback.
serviceIpc(event)
expect(latest().phase == "checking" and latest().total == 0 and not latest().complete
    and rendered.visible and rendered.text == ""
    and tooltipValue("Pacman + AUR updates") == "Checking…",
    "native right-click refresh retains visible icon without claiming zero or reusing counts")
expect(tooltipValue("Pacman") == nil and tooltipValue("Last checked") == latest().checkedAt,
    "checking tooltip must omit stale source counts and preserve the snapshot check time")
discover()

reply("linux 2 -> 3\n")
expect(rendered.visible and rendered.text == "1" and latest().total == 1 and #latest().counts == 1,
    "replacement result must not accumulate the previous count")
onRightClick()
expect(bus[shared.REQUEST].action == "check" and latest().phase == "checking" and rendered.visible,
    "unbound native right-click callback sends a shared manual check to the real service")
discover()
reply("", 2)
expect(not rendered.visible and latest().phase == "clean", "refresh ending at zero hides the icon")
onRightClick()
expect(not rendered.visible, "refresh from zero does not flash an empty icon")
discover()
reply("linux 2 -> 3\n")
serviceIpc("refresh")
serviceIpc("dismiss")
expect(not rendered.visible, "dismissal overrides the in-flight visibility latch")
local before = #jobs
onRightClick()
expect(latest().dismissed and #jobs == before, "busy refresh cannot undo dismissal")
discover()
reply("linux 2 -> 3\n")
expect(not rendered.visible and latest().dismissed, "completion cannot undo in-flight dismissal")
onRightClick()
expect(not latest().dismissed and not rendered.visible,
    "accepted refresh clears dismissal but does not latch a previously dismissed icon")
discover()
reply("linux 2 -> 3\n")
expect(rendered.visible, "accepted refresh with pending results restores dismissed icon")
serviceIpc("refresh")
reply("", 1)
expect(latest().phase == "error" and not rendered.visible,
    "visibility exception expires on discovery failure, not just successful completion")
print("Passed " .. checks .. " widget assertions")
