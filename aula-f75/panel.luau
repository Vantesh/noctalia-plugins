--!nonstrict
local status = require("./status.luau")
local operations = require("./operations.luau")
local snapshot, presented, opened = nil, nil, false
local op = { phase = "idle" }
local render
local palette = { "Red", "Green", "Blue", "Yellow", "Magenta", "Cyan", "White", "Random" }
-- These are the palette colors themselves, not interface/theme colors.
local colors = { "#ef4444", "#22c55e", "#3b82f6", "#eab308", "#d946ef", "#06b6d4", "#ffffff", "surface_container" }
local effectIcons = { [0] = "moon", [1] = "sun", [2] = "wave-sine", [3] = "rainbow", [21] = "settings" }
local function choose(kind, value)
    if kind == "effect" and value == 0 then kind, value = "off", nil end
    if op.phase ~= "idle" or not operations.allowed(snapshot, kind, value) then return end
    operations.send({ action = "prepare", kind = kind, value = value })
end
local function field(name, value)
    return ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = name, fontSize = 12, color = "on_surface_variant", flexGrow = 1 }),
        ui.label({ text = value, fontSize = 13, maxWidth = 230, maxLines = 2 }),
    })
end
local function cancel() operations.send({ action = "cancel" }) end
render = function()
    if not opened then return end
    local s = snapshot or { phase = "idle", message = "Open to refresh" }
    local refreshing = s.phase == "refreshing"
    -- Keep the last measured sections during a read, clearly disabled; never use
    -- this presentation cache to authorize actions or survive an error/disconnect.
    local view = refreshing and presented or s
    view = view or s
    local c = view.controls
    local enabled = s.phase == "ready" and op.phase == "idle" and c ~= nil and c.active ~= nil
    local powerKind = c and c.active == 0 and "on" or "off"
    local rows = {
        ui.row({ key = "header", gap = 5, align = "center" }, {
            ui.glyph({ name = "keyboard", size = 19, color = "primary" }),
            ui.label({ text = "AULA F75", fontSize = 14, fontWeight = "bold", maxLines = 1 }),
            ui.glyph({ name = s.phase == "ready" and "circle-check" or "circle", size = 11, color = "primary" }),
            ui.label({ text = s.phase == "ready" and "Connected · USB" or refreshing and "Refreshing…" or "Not connected",
                fontSize = 10, flexGrow = 1, maxLines = 1 }),
            ui.button({ glyph = "power", variant = "ghost", controlSize = "sm", width = 26,
                tooltip = powerKind == "on" and (c and c.onAvailable and "Turn On" or "On unavailable: no verified session restoration") or "Turn Off",
                enabled = enabled and operations.allowed(s, powerKind), onClick = function() if enabled then choose(powerKind) end end }),
            ui.button({ key = refreshing and "refresh-busy" or "refresh", glyph = "refresh", variant = "ghost", controlSize = "sm", width = 26,
                enabled = not refreshing and op.phase == "idle", tooltip = "Refresh status",
                onClick = function() if not refreshing and op.phase == "idle" then status.request() end end }),
            ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", width = 26, tooltip = "Close", onClick = function() panel.close() end }),
        }),
        ui.separator({}),
    }
    if op.phase == "ready" then
        table.insert(rows, ui.label({ text = "Review lighting change", fontWeight = "bold", fontSize = 15 }))
        table.insert(rows, field("Setting", op.setting == "palette" and "Color palette" or status.label(op.setting)))
        table.insert(rows, field("Current", op.previous))
        table.insert(rows, field("Requested", op.requested))
        if op.warning then table.insert(rows, ui.label({ text = op.warning, maxLines = 3 })) end
        table.insert(rows, ui.row({ gap = 10 }, {
            ui.button({ text = "Cancel", variant = "outline", flexGrow = 1, onClick = cancel }),
            ui.button({ text = "Apply Change", variant = "primary", flexGrow = 1, onClick = function() operations.send({ action = "apply" }) end }),
        }))
    elseif op.error then
        table.insert(rows, ui.column({ gap = 12, padding = 12, fill = "surface_container", radius = 10, border = "outline_variant", borderWidth = 1 }, {
            ui.label({ text = "Unable to apply change", color = "error", fontWeight = "bold" }),
            ui.label({ text = op.error, maxLines = 5 }),
            ui.button({ text = "OK", variant = "outline", onClick = cancel }),
        }))
    elseif op.phase == "reviewing" or op.phase == "applying" then
        table.insert(rows, ui.label({ text = op.phase == "applying" and "Applying… Do not disconnect." or "Preparing review…" }))
        if op.phase == "reviewing" then table.insert(rows, ui.button({ text = "Cancel", onClick = cancel })) end
    elseif view.phase == "ready" then
        if c and c.active == 0 then
            table.insert(rows, ui.column({ gap = 12, padding = 14, fill = "surface_container", radius = 10 }, {
                ui.glyph({ name = "moon", size = 26, color = "primary" }),
                ui.label({ text = "Lighting is off", fontSize = 15, fontWeight = "bold" }),
                ui.label({ text = c.onAvailable and "Turn on to restore the previous effect." or "Session restoration is unavailable. Choose an effect to turn lighting on.", maxLines = 3 }),
                ui.button({ text = "Turn On", glyph = "power", variant = "primary", enabled = enabled and c.onAvailable == true,
                    onClick = function() if enabled then choose("on") end end }),
            }))
        end
        table.insert(rows, ui.label({ text = "Lighting effect", fontSize = 12, color = "on_surface_variant" }))
        local options, ids, selectedIndex = {}, {}, 0
        for _, e in ipairs(c and c.effects or {}) do
            ids[#options] = e.id
            if c and e.id == c.active then selectedIndex = #options end
            options[#options + 1] = e.name
        end
        if #options == 0 then options[1] = view.active or "Unknown" end
        table.insert(rows, ui.row({ key = "effect-picker", gap = 8, align = "center" }, {
            ui.glyph({ name = effectIcons[c and c.active] or "sparkles", size = 20, color = "primary" }),
            ui.select({ key = "effect-select", options = options, selectedIndex = selectedIndex, flexGrow = 1,
                enabled = enabled, controlSize = "sm",
                onChange = function(index) if ids[index] ~= nil then choose("effect", ids[index]) end end }),
        }))
        if c then
            for _, item in ipairs({ { "brightness", 9, "Brightness", "sun" }, { "speed", 4, "Animation speed", "wind" } }) do
                local kind, maximum, name, icon = item[1], item[2], item[3], item[4]
                if c[kind] ~= nil then
                    table.insert(rows, field(name, c[kind] .. " / " .. maximum))
                    local draft = c[kind]
                    table.insert(rows, ui.row({ gap = 10, align = "center" }, {
                        ui.glyph({ name = icon, size = 17, color = "primary" }),
                        ui.slider({ key = kind .. "-" .. c[kind], min = 0, max = maximum, step = 1, controlSize = "sm", flexGrow = 1,
                            value = c[kind], enabled = enabled, onChange = function(value) draft = value end,
                            onDragEnd = function() choose(kind, draft) end }),
                    }))
                end
            end
            if c.active == 21 and c.brightness ~= nil and not c.dimmingVerified then
                table.insert(rows, ui.column({ padding = 10, fill = "surface_container", radius = 8, border = "outline_variant", borderWidth = 1 }, {
                    ui.label({ text = "Saved brightness may not visibly dim LEDs in Self-defined mode.", fontSize = 11, maxLines = 3 }),
                }))
            end
            if c.palette ~= nil then
                table.insert(rows, field("Color palette", palette[c.palette + 1]))
                local swatches = {}
                for index, name in ipairs(palette) do
                    local value, selected = index - 1, index - 1 == c.palette
                    local children = {}
                    if index == 8 then
                        children[1] = ui.image({ path = "palette-random.svg", width = 32, height = 32, fit = "contain", radius = 16,
                            tooltip = "Random (Alt+8)", onClick = function() if enabled then choose("palette", value) end end })
                    else
                        children[1] = ui.button({ key = "palette-" .. value, glyph = selected and "check" or nil, glyphSize = 12,
                            variant = "ghost", controlSize = "sm", width = 32, height = 32,
                            tooltip = name .. (selected and " (selected)" or "") .. " (Alt+" .. index .. ")", enabled = enabled,
                            onClick = function() choose("palette", value) end })
                    end
                    swatches[#swatches + 1] = ui.row({ width = 38, height = 38, radius = 19, padding = 2, gap = 0, align = "center", justify = "center",
                        fill = colors[index], border = selected and "primary" or "outline_variant", borderWidth = selected and 2 or 1, tooltip = name }, children)
                end
                table.insert(rows, ui.row({ key = "palette-swatches", gap = 7, align = "center" }, swatches))
            end
        else
            table.insert(rows, field("Brightness", view.brightness))
            table.insert(rows, field("Speed", view.speed))
            table.insert(rows, field("Palette", view.palette))
        end
        if view.stored then table.insert(rows, field("Stored effect", view.stored)) end
        if view.nativeObserved == false then table.insert(rows, ui.label({ text = "Visual behavior is unconfirmed for this effect.", fontSize = 11, maxLines = 2 })) end
    else
        table.insert(rows, ui.label({ text = s.message, color = s.phase == "error" and "error" or "on_surface_variant", maxLines = 2 }))
        if s.detail then table.insert(rows, ui.label({ text = s.detail, fontSize = 12, maxLines = 3 })) end
    end
    table.insert(rows, ui.separator({}))
    local verified = s.phase == "ready" and op.phase == "idle"
    table.insert(rows, ui.row({ key = "footer", gap = 6, align = "center" }, {
        ui.glyph({ name = verified and "shield-check" or "shield", size = 13, color = "primary" }),
        ui.label({ text = verified and "Verified device state" or "Status pending", fontSize = 10, flexGrow = 1 }),
        ui.label({ text = "Changes require approval", fontSize = 10, color = "on_surface_variant" }),
    }))
    -- Measure intrinsic content directly. A root ScrollView retains viewport
    -- geometry and cannot be the source of ordinary content-panel height.
    panel.render(ui.column({ key = "lighting-content", gap = 12, align = "stretch" }, rows))
end
function onOpen()
    op = noctalia.state.get(operations.KEY) or { phase = "idle" }
    opened = true
    snapshot = noctalia.state.get(status.STATE)
    presented = snapshot and snapshot.phase == "ready" and snapshot or nil
    render()
    status.request()
end
function onClose()
    opened, presented = false, nil
    if op.phase == "ready" or op.phase == "reviewing" then cancel() end
end
noctalia.state.watch(operations.KEY, function(value) op = value; render() end)
noctalia.state.watch(status.STATE, function(value)
    snapshot = value
    if value.phase == "ready" then presented = value elseif value.phase ~= "refreshing" then presented = nil end
    render()
end)

-- The image swatch has no native button semantics. Captured palette chords keep
-- every color keyboard-accessible and still prepare a review, never an apply.
function onKey(chord, pressed)
    if not opened or not pressed then return end
    local index = type(chord) == "string" and chord:lower():match("^alt%+([1-8])$")
    if index then choose("palette", tonumber(index) - 1) end
end
