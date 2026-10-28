-- Run from the repository root: lua aula-f75/tests/ui.lua
local status = dofile("aula-f75/status.luau")
local state, watchers, rendered, requests, closes, toggles = nil, {}, nil, 0, 0, 0
local widget = {}
local actions, operationWatcher = {}, nil
local function ready()
    return { phase = "ready", message = "Connected · USB", active = "Self-defined", mode = "Per-key",
        brightness = "9 / 9", speed = "Unavailable", palette = "Unavailable", stored = "Storm (18)" }
end
noctalia = {
    state = { get = function(key) if key == "aula_f75.operation" then return nil end; return state end,
        set = function(key, value) if key == "aula_f75.action" then actions[#actions + 1] = value; return end; assert(key == status.REQUEST); requests = requests + 1 end,
        watch = function(key, callback) if key == "aula_f75.operation" then operationWatcher = callback; return end; assert(key == status.STATE); watchers[#watchers + 1] = callback end },
    togglePanel = function(id) assert(id == "vantesh/aula-f75:panel"); toggles = toggles + 1 end,
    fuzzyScore = function() return 1 end,
    runAsync = function() error("UI must never spawn a process") end,
}
local originalRequire = require
require = function(path) if path == "./operations.luau" then return dofile("aula-f75/operations.luau") end; assert(path == "./status.luau"); return status end
ui = setmetatable({}, { __index = function(_, kind) return function(props, children) return { kind = kind, props = props, children = children or {} } end end })
panel = { render = function(tree) rendered = tree end, close = function() closes = closes + 1 end }
barWidget = {
    setGlyph = function(v) widget.glyph = v end, setGlyphColor = function(v) widget.color = v end,
    setVisible = function(v) widget.visible = v end,
    setText = function(v) widget.text = v end, setTooltip = function(v) widget.tooltip = v end,
}
local function publish(value) state = value; for _, cb in ipairs(watchers) do cb(value) end end
local function find(tree, predicate)
    if predicate(tree) then return tree end
    for _, child in ipairs(tree.children) do local found = find(child, predicate); if found then return found end end
end
local function text(value) return find(rendered, function(n) return n.props.text == value or (type(n.props.text)=="string" and n.props.text:sub(-#value)==value) or (n.props.options and n.props.options[(n.props.selectedIndex or 0) + 1]:sub(-#value) == value) end) end
dofile("aula-f75/panel.luau")
local open, close = onOpen, onClose
assert(rendered == nil and requests == 0)
state = ready(); open()
assert(requests == 1 and text("Self-defined") and text("Storm (18)") and text("Unavailable"))
local refresh = find(rendered, function(n) return n.props.key == "refresh" or n.props.key == "refresh-busy" end)
refresh.props.onClick(); assert(requests == 2)
publish({ phase = "refreshing", message = "Refreshing…" })
assert(text("Refreshing…") and text("Self-defined"), "retain measured sections while refreshing, with controls disabled")
refresh = find(rendered, function(n) return n.props.key == "refresh" or n.props.key == "refresh-busy" end)
assert(not refresh.props.enabled); refresh.props.onClick(); assert(requests == 2)
local previous = rendered; close(); publish(ready()); assert(rendered == previous, "closed panel must not render")
open(); assert(requests == 3 and text("Self-defined"))
find(rendered, function(n) return n.props.glyph == "x" end).props.onClick(); assert(closes == 1)
publish(status.problem("missing_cli")); assert(text("aulaf75ctl not installed") and not text("Self-defined"))
close()
dofile("aula-f75/widget.luau")
assert(widget.glyph == "keyboard" and widget.tooltip == "")
onClick(); assert(toggles == 1)
publish(ready()); assert(widget.color == "primary" and widget.tooltip == "")
publish({phase="refreshing",message="Refreshing…"})
assert(widget.text=="" and widget.visible, "busy refresh never adds dots")
publish(status.problem("disconnected"));assert(not widget.visible, "confirmed disconnection hides the capsule")
publish({phase="refreshing",message="Refreshing…"});assert(not widget.visible,"refresh does not flash a disconnected widget")
publish(ready());assert(widget.visible and widget.text=="", "verified reconnection restores icon-only widget")

launcher = { setResults = function(query, results) assert(query == "aula"); assert(results[1].id == "open") end }
dofile("aula-f75/launcher.luau")
onQuery("aula"); onActivate("open"); assert(toggles == 2)
-- Native controls: slider onDragEnd has no argument, select indices are zero-based.
state = ready(); state.controls = { active = 21, brightness = 9, effects = {{id=1,name="Fixed On"},{id=2,name="Respire"},{id=21,name="Self-defined"},{id=0,name="Off"}},power=true }
open()
local slider = find(rendered, function(n) return n.kind == "slider" end)
slider.props.onChange("4"); assert(#actions == 0, "drag changes must not launch review")
slider.props.onDragEnd(); assert(#actions == 1 and actions[1].kind == "brightness" and actions[1].value == 4)
local trigger = find(rendered, function(n) return n.props.key == "effect-select" end)
trigger.props.onClick()
local list = find(rendered,function(n)return n.props.key=="effect-options"end)
assert(list and #list.children==4 and list.props.flexGrow==1)
assert(find(rendered,function(n)return n.props.key=="effect-viewport"end).props.height==176)
assert(not find(rendered,function(n)return n.kind=="input"end), "no search")
find(rendered,function(n)return n.props.key=="effect-2"end).props.onClick()
assert(actions[2].kind=="effect" and actions[2].value==2)
operationWatcher({phase="ready",setting="effect",previous="Self-defined",requested="Respire"})
assert(text("Review lighting change") and text("Apply Change"))
text("Cancel").props.onClick(); assert(actions[#actions].action == "cancel")
operationWatcher({phase="applying"}); assert(not text("Apply Change") and not find(rendered,function(n)return n.kind=="slider"end))
local beforeActions = #actions; close(); assert(#actions == beforeActions, "closing during apply must not queue writes or cancel apply")
operationWatcher({phase="idle"})
state.controls = nil
require = originalRequire
assert(requests == 4, "widget, launcher and close do not request hardware reads")
print("AULA F75 UI: panel lifecycle, refresh, errors, widget and launcher passed")

-- Layout regression: ordinary dynamic views measure a column, never a root viewport.
for _, id in ipairs({1,2,3,21,0}) do
    local r = ready()
    r.controls = { active=id, effects={{id=1,name="Fixed On"}}, power=true,
        brightness=id~=0 and 5 or nil, speed=(id==2 or id==3) and 3 or nil,
        palette=(id==1 or id==2) and 2 or nil }
    open(); publish(r)
    assert(rendered.kind=="column" and not find(rendered,function(n)return n.kind=="scroll"end))
    local header=find(rendered,function(n)return n.props.key=="header"end)
    assert(find(header,function(n)return n.props.text=="Connected · USB"end), "connection is in header")
    local swatches=find(rendered,function(n)return n.props.key=="palette-swatches"end)
    assert((swatches~=nil)==(r.controls.palette~=nil))
    if swatches then assert(#swatches.children==8, "eight equal swatches in one row") end
    local count=#rendered.children
    publish({phase="refreshing",message="Refreshing…"})
    assert(#rendered.children==count, "refresh keeps measured sections while disabling controls")
    publish(status.problem("disconnected"))
    assert(not find(rendered,function(n)return n.kind=="slider"end), "disconnect drops retained controls")
    close()
end
print("AULA layout: intrinsic root, aligned header, dynamic views, single-row palette and stable refresh passed")

-- Trigger/list share labels and use restrained, contained native primitives.
for _, e in ipairs({{1,"Fixed On","☀︎"},{2,"Respire","≋"},{4,"Flash Away","ϟ"},{21,"Self-defined","⚙︎"}}) do
    local r=ready();r.active=e[2];r.controls={active=e[1],effects={{id=e[1],name=e[2]}},power=true}
    open();publish(r)
    local selector=find(rendered,function(n)return n.props.key=="effect-select"end)
    assert(selector.props.radius==12 and selector.props.minHeight>=48)
    selector.props.onClick()
    local row=find(rendered,function(n)return n.props.key=="effect-"..e[1]end)
    assert(row.children[1].props.text==e[3].."  "..e[2])
    assert(row.props.fill=="surface_container_high" and #row.children==1,"selected row has subtle fill, no checkmark")
    local before=#actions;row.props.onClick();assert(#actions==before,"active effect is a no-op")
    close()
end
local r=ready();r.controls={active=1,effects={{id=1,name="Fixed On"},{id=2,name="Respire"},{id=21,name="Self-defined"}},palette=1,power=true}
open();publish(r)
local selector=find(rendered,function(n)return n.props.key=="effect-select"end)
selector.props.onClick();onKey("End",true)
assert(find(rendered,function(n)return n.props.key=="effect-options"end).props.revealKey=="effect-21")
local before=#actions;find(rendered,function(n)return n.props.key=="effect-select"end).props.onClick()
assert(#actions==before+1 and actions[#actions].value==21,"arrow cursor activation requests review")
publish(r)
local swatches=find(rendered,function(n)return n.props.key=="palette-swatches"end)
assert(swatches.props.justify=="space_between" and #swatches.children==8)
for _,circle in ipairs(swatches.children)do
 assert(circle.props.width==34 and circle.props.height==34 and circle.props.radius==17)
 assert(circle.props.onClick and not find(circle,function(n)return n.kind=="button"end),"focusable circle has no rectangular ghost button")
end
swatches.children[3].props.onClick();assert(actions[#actions].kind=="palette" and actions[#actions].value==2)
swatches.children[3].props.onHover("true")
swatches=find(rendered,function(n)return n.props.key=="palette-swatches"end)
assert(swatches.children[3].props.border=="secondary" and swatches.children[3].props.borderWidth==3)
assert(swatches.children[3].props.fill=="#3b82f6","hover changes outline, not fill")
close()
print("AULA callbacks/palette: native string indices/values, review dispatch, circular targets and even spacing passed")

local stateWithTransport=ready()
stateWithTransport.connection={transport="test_transport",label="Connected · Test transport"}
stateWithTransport.controls={active=1,effects={{id=1,name="Fixed On"}},palette=1,power=true}
open();publish(stateWithTransport)
local header=find(rendered,function(n)return n.props.key=="header"end)
assert(#header.children==2 and text("Connected · Test transport"),"two header groups keep transport under identity")
local heading=text("Color palette")
assert(heading and heading.kind=="label" and not text("Green"),"palette heading has no repeated selected color name")
assert(find(rendered,function(n)return n.props.key=="effect-select"end).props.minHeight==48)
publish(status.problem("disconnected"));assert(text("Disconnected") and not text("Connected · Test transport"))
close()
print("AULA header/palette: transport presentation, grouping, taller selector and concise heading passed")
