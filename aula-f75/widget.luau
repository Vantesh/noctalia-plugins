--!nonstrict
local status = require("./status.luau")
local visible = true
local function render(s)
    s = s or { phase = "idle", message = "Open to refresh" }
    if s.phase == "disconnected" then visible = false
    elseif s.phase == "ready" then visible = true end
    barWidget.setVisible(visible)
    barWidget.setGlyph("keyboard")
    barWidget.setGlyphColor(s.phase == "ready" and "primary" or ((s.phase == "error" or s.phase == "missing") and "error" or "on_surface_variant"))
    barWidget.setText("")
    barWidget.setTooltip("")
end
noctalia.state.watch(status.STATE, render)
function onClick() noctalia.togglePanel("vantesh/aula-f75:panel") end
render(noctalia.state.get(status.STATE))
