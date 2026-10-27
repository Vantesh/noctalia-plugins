-- Run from the repository root: lua aula-f75/tests/ui.lua
local status = dofile("aula-f75/status.luau")
local state, watchers, rendered, requests, closes, toggles = nil, {}, nil, 0, 0, 0
local widget = {}
local function ready()
    return { phase = "ready", message = "Connected · USB", active = "Self-defined", mode = "Per-key",
        brightness = "9 / 9", speed = "Unavailable", palette = "Unavailable", stored = "Storm (18)" }
end
noctalia = {
    state = { get = function() return state end,
        set = function(key) assert(key == status.REQUEST); requests = requests + 1 end,
        watch = function(key, callback) assert(key == status.STATE); watchers[#watchers + 1] = callback end },
    togglePanel = function(id) assert(id == "vantesh/aula-f75:panel"); toggles = toggles + 1 end,
    fuzzyScore = function() return 1 end,
    runAsync = function() error("UI must never spawn a process") end,
}
local originalRequire = require
require = function(path) assert(path == "./status.luau"); return status end
ui = setmetatable({}, { __index = function(_, kind) return function(props, children) return { kind = kind, props = props, children = children or {} } end end })
panel = { render = function(tree) rendered = tree end, close = function() closes = closes + 1 end }
barWidget = {
    setGlyph = function(v) widget.glyph = v end, setGlyphColor = function(v) widget.color = v end,
    setText = function(v) widget.text = v end, setTooltip = function(v) widget.tooltip = v end,
}
local function publish(value) state = value; for _, cb in ipairs(watchers) do cb(value) end end
local function find(tree, predicate)
    if predicate(tree) then return tree end
    for _, child in ipairs(tree.children) do local found = find(child, predicate); if found then return found end end
end
local function text(value) return find(rendered, function(n) return n.props.text == value end) end
dofile("aula-f75/panel.luau")
local open, close = onOpen, onClose
assert(rendered == nil and requests == 0)
state = ready(); open()
assert(requests == 1 and text("Self-defined") and text("Storm (18)") and text("Unavailable"))
local refresh = find(rendered, function(n) return n.props.tooltip == "Refresh status" end)
refresh.props.onClick(); assert(requests == 2)
publish({ phase = "refreshing", message = "Refreshing…" })
assert(text("Refreshing…") and not text("Self-defined"))
refresh = find(rendered, function(n) return n.props.tooltip == "Refresh status" end)
assert(not refresh.props.enabled); refresh.props.onClick(); assert(requests == 2)
local previous = rendered; close(); publish(ready()); assert(rendered == previous, "closed panel must not render")
open(); assert(requests == 3 and text("Self-defined"))
find(rendered, function(n) return n.props.tooltip == "Close" end).props.onClick(); assert(closes == 1)
publish(status.problem("missing_cli")); assert(text("aulaf75ctl not installed") and not text("Self-defined"))
close()
dofile("aula-f75/widget.luau")
assert(widget.glyph == "keyboard" and widget.tooltip:find("not installed", 1, true))
onClick(); assert(toggles == 1)
publish(ready()); assert(widget.color == "primary" and widget.tooltip:find("Self-defined", 1, true))
launcher = { setResults = function(query, results) assert(query == "aula"); assert(results[1].id == "open") end }
dofile("aula-f75/launcher.luau")
onQuery("aula"); onActivate("open"); assert(toggles == 2)
require = originalRequire
assert(requests == 3, "widget, launcher and close do not request hardware reads")
print("AULA F75 UI: panel lifecycle, refresh, errors, widget and launcher passed")
