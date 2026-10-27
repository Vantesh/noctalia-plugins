--!nonstrict
local status = require("./status.luau")
local snapshot, opened = nil, false

local function field(name, value)
    return ui.row({ gap = 12, align = "center" }, {
        ui.label({ text = name, fontSize = 12, color = "on_surface_variant", flexGrow = 1 }),
        ui.label({ text = value, fontSize = 13, maxWidth = 220, maxLines = 2 }),
    })
end

local function render()
    if not opened then return end
    local s = snapshot or { phase = "idle", message = "Open to refresh" }
    local refreshing = s.phase == "refreshing"
    local rows = {
        ui.row({ gap = 10, align = "center" }, {
            ui.glyph({ name = "keyboard", size = 22, color = "primary" }),
            ui.label({ text = "AULA F75", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
            ui.button({ key = refreshing and "refresh-busy" or "refresh", glyph = "refresh", variant = "ghost",
                enabled = not refreshing, tooltip = "Refresh status", onClick = function() if not refreshing then status.request() end end }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = "Close", onClick = function() panel.close() end }),
        }),
        ui.label({ text = s.message, color = s.phase == "error" and "error" or "on_surface_variant", maxLines = 2 }),
    }
    if s.phase == "ready" then
        table.insert(rows, ui.separator({}))
        table.insert(rows, field("Active effect", s.active))
        table.insert(rows, field("Lighting mode", s.mode))
        table.insert(rows, field("Brightness", s.brightness))
        table.insert(rows, field("Speed", s.speed))
        table.insert(rows, field("Palette", s.palette))
        if s.stored then table.insert(rows, field("Stored effect", s.stored)) end
        if s.nativeObserved == false then
            table.insert(rows, ui.label({ text = "Visual behavior is unconfirmed for this effect.", fontSize = 11, color = "on_surface_variant", maxLines = 2 }))
        end
    elseif s.detail then
        table.insert(rows, ui.label({ text = s.detail, fontSize = 12, color = "on_surface_variant", maxLines = 3 }))
    end
    table.insert(rows, ui.separator({}))
    table.insert(rows, ui.label({ text = "Read-only · Wired USB", fontSize = 11, color = "on_surface_variant" }))
    panel.render(ui.column({ gap = 10, align = "stretch" }, rows))
end

function onOpen()
    opened = true
    snapshot = noctalia.state.get(status.STATE)
    render()
    status.request()
end
function onClose() opened = false end
noctalia.state.watch(status.STATE, function(value) snapshot = value; render() end)
