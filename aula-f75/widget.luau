--!nonstrict
local status = require("./status.luau")
local function render(s)
    s = s or { phase = "idle", message = "Open to refresh" }
    barWidget.setGlyph("keyboard")
    barWidget.setGlyphColor(s.phase == "ready" and "primary" or ((s.phase == "error" or s.phase == "missing") and "error" or "on_surface_variant"))
    barWidget.setText(s.phase == "refreshing" and "…" or "")
    barWidget.setTooltip("")
end
noctalia.state.watch(status.STATE, render)
function onClick() noctalia.togglePanel("vantesh/aula-f75:panel") end
render(noctalia.state.get(status.STATE))
