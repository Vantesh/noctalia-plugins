--!nonstrict
local core = require("./core.luau")
local shared = require("./shared.luau")
local snapshot = noctalia.state.get(shared.STATE)
local function render()
    local s = snapshot or { phase = "idle", total = 0, unknown = {} }
    local total = s.total or 0
    local uncertain = #(s.unknown or {}) > 0
    local glyph = noctalia.getConfig("glyph") or ""
    barWidget.setGlyph(glyph ~= "" and glyph or (s.hasArchSources and "pacman" or "settings"))
    local checking = s.phase == "checking"
    barWidget.setGlyphColor(checking and "on_surface_variant"
        or ((s.phase == "error" or s.updateBlocked or s.updateError or uncertain) and "error"
        or (total > 0 and "primary" or "on_surface")))
    barWidget.setText(checking and "" or ((total > 0 and tostring(total) or "") .. (uncertain and "?" or "")))
    barWidget.setVisible(not core.hidden(s, noctalia.getConfig("hide_on_empty")))
    local status = s.updateBlocked and ("Updates blocked: " .. s.updateBlocked)
        or s.updateError or s.error or (checking and (s.step or "Checking for updates…"))
        or (s.phase == "running" and "Updating in terminal")
        or (uncertain and "Some update checks failed")
        or (total > 0 and "Updates available" or "No pending packages")
    local tooltip = {
        { key = "Topgrade", value = noctalia.commandExists("topgrade") and "OK" or "Not found" },
        { key = "Status", value = status },
        { key = "Pacman + AUR updates", value = checking and "Checking…" or tostring(total) },
    }
    if not checking then
        for _, source in ipairs(s.counts or {}) do
            table.insert(tooltip, { key = source.key == "pacman" and "Pacman" or source.key, value = tostring(source.n) })
        end
    end
    if uncertain then
        table.insert(tooltip, { key = "Check warnings", value = table.concat(s.unknown, "\n") })
    end
    if s.checkedAt then table.insert(tooltip, { key = "Last checked", value = s.checkedAt }) end
    barWidget.setTooltip(tooltip)
end
noctalia.state.watch(shared.STATE, function(value) snapshot = value; render() end)
function update() render() end
function onClick() noctalia.togglePanel("vantesh/topgrade-updater:panel") end
function onRightClick() shared.request("check") end
noctalia.setUpdateInterval(1000)
render()
