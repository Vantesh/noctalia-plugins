--!nonstrict
local status = require("./status.luau")
local operations = require("./operations.luau")
local snapshot, opened = nil, false
local op, picker, query = { phase = "idle" }, false, ""
local render
local palette = { "Red", "Green", "Blue", "Yellow", "Magenta", "Cyan", "White", "Random" }
local colors = { "#ef4444", "#22c55e", "#3b82f6", "#eab308", "#d946ef", "#06b6d4", "#ffffff", "surface_container_high" }
local function choose(kind, value)
    if kind == "effect" and value == 0 then kind, value = "off", nil end
    if op.phase ~= "idle" or not operations.allowed(snapshot, kind, value) then return end
    picker = false
    operations.send({ action = "prepare", kind = kind, value = value })
end

local function field(name, value)
    return ui.row({ gap = 12, align = "center" }, {
        ui.label({ text = name, fontSize = 12, color = "on_surface_variant", flexGrow = 1 }),
        ui.label({ text = value, fontSize = 13, maxWidth = 220, maxLines = 2 }),
    })
end

render = function()
    if not opened then return end
    local s = snapshot or { phase = "idle", message = "Open to refresh" }
    local refreshing = s.phase == "refreshing"
    local enabled = s.phase == "ready" and op.phase == "idle" and s.controls ~= nil and s.controls.active ~= nil
    local c = s.controls
    local powerKind = c and c.active == 0 and "on" or "off"
    local rows = {
        ui.row({ gap = 10, align = "center" }, {
            ui.glyph({ name = "keyboard", size = 22, color = "primary" }),
            ui.label({ text = "AULA F75", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
            ui.button({ glyph = "power", variant = c and c.active ~= 0 and "primary" or "ghost",
                tooltip = powerKind == "on" and (c and c.onAvailable and "Turn On" or "On unavailable: no verified session restoration") or "Turn Off",
                enabled = enabled and c ~= nil and operations.allowed(s, powerKind),
                onClick = function() if enabled then choose(powerKind) end end }),
            ui.button({ key = refreshing and "refresh-busy" or "refresh", glyph = "refresh", variant = "ghost",
                enabled = not refreshing and op.phase == "idle", tooltip = "Refresh status", onClick = function() if not refreshing and op.phase == "idle" then status.request() end end }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = "Close", onClick = function() panel.close() end }),
        }),
        ui.label({ text = s.message, color = s.phase == "error" and "error" or "on_surface_variant", maxLines = 2 }),
    }
    if op.phase == "ready" then
        table.insert(rows, ui.label({ text = "Review lighting change", fontWeight = "bold" }))
        table.insert(rows, field("Setting", status.label(op.setting)))
        table.insert(rows, field("Current", op.previous))
        table.insert(rows, field("Requested", op.requested))
        if op.warning then table.insert(rows, ui.label({ text = op.warning, maxLines = 3 })) end
        table.insert(rows, ui.row({ gap = 8 }, {
            ui.button({ text = "Cancel", onClick = function() operations.send({ action = "cancel" }) end }),
            ui.button({ text = "Apply Change", onClick = function() operations.send({ action = "apply" }) end }),
        }))
    elseif op.phase == "reviewing" or op.phase == "applying" then
        table.insert(rows, ui.label({ text = op.phase == "applying" and "Applying… Do not disconnect." or "Preparing review…" }))
        if op.phase == "reviewing" then table.insert(rows, ui.button({ text = "Cancel", onClick = function() operations.send({ action = "cancel" }) end })) end
    elseif s.phase == "ready" then
        table.insert(rows, ui.separator({}))
        if not c then table.insert(rows, field("Active effect", s.active)) end
        table.insert(rows, field("Lighting mode", s.mode))
        if c then
            table.insert(rows, ui.button({ text = "Effect: " .. s.active, enabled = enabled, onClick = function()
                if enabled then picker = not picker; query = ""; render() end
            end }))
            if picker then
                table.insert(rows, ui.input({ key = "effect-search", placeholder = "Search effects…", value = query, focus = true,
                    onChange = function(text) query = text:lower(); render() end }))
                local options, ids = { "Choose an effect…" }, {}
                for _, e in ipairs(c.effects) do
                    if e.name:lower():find(query, 1, true) then options[#options + 1] = e.name; ids[#options - 1] = e.id end
                end
                table.insert(rows, ui.select({ options = options, selectedIndex = 0, enabled = enabled,
                    onChange = function(index) if ids[index] ~= nil then choose("effect", ids[index]) end end }))
                table.insert(rows, ui.button({ text = "Close effects", onClick = function() picker = false; render() end }))
            end
            for _, item in ipairs({ { "brightness", 9, "Brightness" }, { "speed", 4, "Animation speed" } }) do
                local kind, maximum, name = item[1], item[2], item[3]
                if c[kind] ~= nil then
                    table.insert(rows, field(name, c[kind] .. " / " .. maximum))
                    local draft = c[kind]
                    table.insert(rows, ui.slider({ key = kind .. "-" .. c[kind], min = 0, max = maximum, step = 1,
                        value = c[kind], enabled = enabled,
                        onChange = function(value) draft = value end,
                        onDragEnd = function() choose(kind, draft) end }))
                end
            end
            if c.brightness ~= nil and not c.dimmingVerified then
                table.insert(rows, ui.label({ text = "Saved brightness may not visibly dim LEDs.", fontSize = 11, maxLines = 2 }))
            end
            if c.palette ~= nil then
                table.insert(rows, field("Palette", palette[c.palette + 1]))
                local swatches = {}
                for index, name in ipairs(palette) do
                    local value = index - 1
                    swatches[#swatches + 1] = ui.column({ align = "center", gap = 2 }, {
                        ui.row({ padding = 3, radius = 20, border = value == c.palette and "primary" or "outline_variant", borderWidth = value == c.palette and 2 or 1 }, {
                            ui.row({ width = 26, height = 26, radius = 13, fill = colors[index], tooltip = name,
                                onClick = function() if enabled then choose("palette", value) end end }),
                        }),
                        ui.button({ text = (value == c.palette and "✓ " or "") .. name, controlSize = "sm", enabled = enabled,
                            tooltip = "Select " .. name, onClick = function() choose("palette", value) end }),
                    })
                end
                -- Two native rows keep labels readable at the compact panel width.
                table.insert(rows, ui.row({ gap = 5 }, { swatches[1], swatches[2], swatches[3], swatches[4] }))
                table.insert(rows, ui.row({ gap = 5 }, { swatches[5], swatches[6], swatches[7], swatches[8] }))
            end
        else
            table.insert(rows, field("Brightness", s.brightness))
            table.insert(rows, field("Speed", s.speed))
            table.insert(rows, field("Palette", s.palette))
        end
        if s.stored then table.insert(rows, field("Stored effect", s.stored)) end
        if s.nativeObserved == false then
            table.insert(rows, ui.label({ text = "Visual behavior is unconfirmed for this effect.", fontSize = 11, color = "on_surface_variant", maxLines = 2 }))
        end
    elseif s.detail then
        table.insert(rows, ui.label({ text = s.detail, fontSize = 12, color = "on_surface_variant", maxLines = 3 }))
    end
    if op.error or op.message then table.insert(rows, ui.label({ text = op.error or op.message, color = op.error and "error" or "on_surface_variant", maxLines = 4 })) end
    table.insert(rows, ui.separator({}))
    table.insert(rows, ui.label({ text = "Guarded controls · Wired USB", fontSize = 11, color = "on_surface_variant" }))
    panel.render(ui.column({ align = "stretch" }, { ui.scroll({ flexGrow = 1, gap = 8 }, rows) }))
end

function onOpen()
    op = noctalia.state.get(operations.KEY) or { phase = "idle" }
    opened = true
    snapshot = noctalia.state.get(status.STATE)
    render()
    status.request()
end
function onClose()
    opened, picker = false, false
    if op.phase == "ready" or op.phase == "reviewing" then operations.send({ action = "cancel" }) end
end
noctalia.state.watch(operations.KEY, function(value) op = value; render() end)
noctalia.state.watch(status.STATE, function(value) snapshot = value; render() end)
