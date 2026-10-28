--!nonstrict
local status = require("./status.luau")
local operations = require("./operations.luau")
local snapshot, presented, opened = nil, nil, false
local op = { phase = "idle" }
local hoveredPalette
local effectsOpen, effectCursor, effectHover, effectKeyboard = false, 1, nil, false
local visibleEffects = {}
local render
local palette = { "Red", "Green", "Blue", "Yellow", "Magenta", "Cyan", "White", "Random" }
-- These are the palette colors themselves, not interface/theme colors.
local colors = { "#ef4444", "#22c55e", "#3b82f6", "#eab308", "#d946ef", "#06b6d4", "#ffffff", "surface_container" }
-- API 43 ui.select exposes text options, not glyph/row props. Text-presentation
-- symbols keep both trigger and popup on the same native keyboard/scroll path.
local effectIcons = {
    [0] = "◐", [1] = "☀︎", [2] = "≋", [3] = "⌒", [4] = "ϟ", [5] = "☂︎",
    [6] = "◌", [7] = "◎", [8] = "✧", [10] = "↝", [11] = "↠", [12] = "✺",
    [13] = "∿", [15] = "✣", [16] = "⇣", [17] = "❀", [21] = "⚙︎",
}
local function effectLabel(id, name)
    return (effectIcons[id] or "◇") .. "  " .. name
end
local function choose(kind, value)
    if kind == "effect" and value == 0 then kind, value = "off", nil end
    if op.phase ~= "idle" or not operations.allowed(snapshot, kind, value) then return end
    effectsOpen = false
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
            ui.row({ key = "keyboard-identity", gap = 10, align = "center", flexGrow = 1 }, {
                ui.row({ width = 36, height = 36, radius = 10, align = "center", justify = "center", fill = "surface_container" }, {
                    ui.glyph({ name = "keyboard", size = 21, color = "primary" }),
                }),
                ui.column({ gap = 5, align = "start" }, {
                    ui.label({ text = "AULA F75", fontSize = 15, fontWeight = "semibold", baseline = "inkCentered", maxLines = 1 }),
                    ui.row({ key = "connection-status", gap = 4, align = "center" }, {
                        ui.label({ text = s.phase == "ready" and (s.connection and s.connection.label or s.message)
                            or refreshing and "Refreshing…" or s.phase == "disconnected" and "Disconnected" or "Unavailable",
                            fontSize = 10, baseline = "inkCentered", maxLines = 1 }),
                    }),
                }),
            }),
            ui.row({ key = "header-actions", gap = 5, align = "center" }, {
            ui.button({ glyph = "power", variant = "ghost", controlSize = "sm", width = 26,
                tooltip = powerKind == "on" and (c and c.onAvailable and "Turn On" or "On unavailable: no verified session restoration") or "Turn Off",
                enabled = enabled and operations.allowed(s, powerKind), onClick = function() if enabled then choose(powerKind) end end }),
            ui.button({ key = refreshing and "refresh-busy" or "refresh", glyph = "refresh", variant = "ghost", controlSize = "sm", width = 26,
                enabled = not refreshing and op.phase == "idle", tooltip = "Refresh status",
                onClick = function() if not refreshing and op.phase == "idle" then status.request() end end }),
            ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", width = 26, tooltip = "Close", onClick = function() panel.close() end }),
            }),
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
        if c and c.active == 0 and not effectsOpen then
            table.insert(rows, ui.column({ gap = 12, padding = 14, fill = "surface_container", radius = 10 }, {
                ui.glyph({ name = "moon", size = 26, color = "primary" }),
                ui.label({ text = "Lighting is off", fontSize = 15, fontWeight = "bold" }),
                ui.label({ text = c.onAvailable and "Turn on to restore the previous effect." or "Session restoration is unavailable. Choose an effect to turn lighting on.", maxLines = 3 }),
                ui.button({ text = "Turn On", glyph = "power", variant = "primary", enabled = enabled and c.onAvailable == true,
                    onClick = function() if enabled then choose("on") end end }),
            }))
        end
        table.insert(rows, ui.label({ text = "Lighting effect", fontSize = 12, color = "on_surface_variant" }))
        visibleEffects = c and c.effects or {}
        local function activateEffect(index)
            local effect = visibleEffects[index]
            if effect and enabled then effectsOpen, effectKeyboard = false, false; choose("effect", effect.id); render() end
        end
        table.insert(rows, ui.row({ key = "effect-select", gap = 12, paddingH = 14, paddingV = 12,
            minHeight = 48, align = "center", radius = 12, fill = "surface_container", border = "outline_variant", borderWidth = 1,
            tooltip = "Lighting effect; Enter to open, Up/Down to navigate",
            onClick = enabled and function()
                if effectsOpen and effectKeyboard then activateEffect(effectCursor); return end
                effectsOpen = not effectsOpen
                effectKeyboard, effectHover = false, nil
                if effectsOpen then
                    effectCursor = 1
                    for i, e in ipairs(visibleEffects) do if e.id == c.active then effectCursor = i end end
                end
                render()
            end or nil }, {
            ui.label({ text = effectLabel(c and c.active, view.active or "Unknown"), fontSize = 14, color = "on_surface", flexGrow = 1, maxLines = 1 }),
            ui.glyph({ name = effectsOpen and "chevron-up" or "chevron-down", size = 14, color = "on_surface_variant" }),
        }))
        if effectsOpen and enabled then
            local items = {}
            for i, e in ipairs(visibleEffects) do
                local selected, highlighted = e.id == c.active, effectHover == i or (effectKeyboard and effectCursor == i)
                items[#items + 1] = ui.row({ key = "effect-" .. e.id, minHeight = 40, paddingH = 12, paddingV = 8,
                    radius = 9, align = "center", fill = highlighted and "primary/0.08" or selected and "surface_container_high" or "surface_container",
                    border = highlighted and "outline_variant" or "surface_container", borderWidth = 1,
                    tooltip = e.name .. (selected and " (current)" or ""),
                    onClick = function() activateEffect(i) end,
                    onHover = function(inside)
                        local nextHover = inside == "true" and i or nil
                        if nextHover ~= effectHover then effectHover = nextHover; render() end
                    end }, {
                    ui.label({ text = effectLabel(e.id, e.name), fontSize = 14, color = "on_surface", fontWeight = selected and "semibold" or "normal", maxLines = 1 }),
                })
            end
            -- Constrain the viewport's parent; let the native scroll control fill
            -- that slot rather than min/max-clamping the ScrollView itself.
            table.insert(rows, ui.column({ key = "effect-viewport", height = math.min(#items, 5) * 42 + 8 }, {
                ui.scroll({ key = "effect-options", flexGrow = 1, gap = 2,
                    padding = 4, radius = 12, fill = "surface_container", border = "outline_variant", borderWidth = 1,
                    revealKey = effectKeyboard and visibleEffects[effectCursor] and "effect-" .. visibleEffects[effectCursor].id or nil }, items),
            }))
        end
        if c and not effectsOpen then
            for _, item in ipairs({ { "brightness", 9, "Brightness", "sun" }, { "speed", 4, "Animation speed", "wind" } }) do
                local kind, maximum, name, icon = item[1], item[2], item[3], item[4]
                if c[kind] ~= nil then
                    table.insert(rows, field(name, c[kind] .. " / " .. maximum))
                    local draft = c[kind]
                    table.insert(rows, ui.row({ gap = 10, align = "center" }, {
                        ui.glyph({ name = icon, size = 17, color = "primary" }),
                        ui.slider({ key = kind .. "-" .. c[kind], min = 0, max = maximum, step = 1, controlSize = "sm", flexGrow = 1,
                            value = c[kind], enabled = enabled, onChange = function(value) draft = tonumber(value) end,
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
                table.insert(rows, ui.label({ text = "Color palette", fontSize = 12, color = "on_surface_variant" }))
                local swatches = {}
                for index, name in ipairs(palette) do
                    local value, selected = index - 1, index - 1 == c.palette
                    local children = {}
                    if index == 8 then
                        children[1] = ui.image({ path = "palette-random.svg", width = 30, height = 30, fit = "contain", radius = 15 })
                    elseif selected then
                        children[1] = ui.glyph({ name = "check", size = 15, color = "on_primary" })
                    end
                    local hovered = hoveredPalette == value
                    swatches[#swatches + 1] = ui.row({ key = "palette-" .. value, width = 34, height = 34, radius = 17,
                        gap = 0, align = "center", justify = "center", fill = colors[index],
                        border = hovered and "secondary" or selected and "primary" or "outline_variant",
                        borderWidth = hovered and 3 or selected and 2 or 1,
                        tooltip = name .. (selected and " (selected)" or "") .. " (Alt+" .. index .. ")",
                        onClick = enabled and function() choose("palette", value) end or nil,
                        onHover = enabled and function(inside)
                            local nextHover = inside == "true" and value or nil
                            if nextHover ~= hoveredPalette then hoveredPalette = nextHover; render() end
                        end or nil }, children)
                end
                table.insert(rows, ui.row({ key = "palette-swatches", gap = 0, justify = "space_between", align = "center" }, swatches))
            end
        elseif not c then
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
    panel.render(ui.column({ key = "lighting-content", gap = 12, paddingH = 4, align = "stretch" }, rows))
end
function onOpen()
    op = noctalia.state.get(operations.KEY) or { phase = "idle" }
    effectsOpen, effectHover, effectKeyboard = false, nil, false
    opened = true
    snapshot = noctalia.state.get(status.STATE)
    presented = snapshot and snapshot.phase == "ready" and snapshot or nil
    render()
    status.request()
end
function onClose()
    opened, presented, hoveredPalette = false, nil, nil
    effectsOpen, effectHover, effectKeyboard = false, nil, false
    if op.phase == "ready" or op.phase == "reviewing" then cancel() end
end
noctalia.state.watch(operations.KEY, function(value) op = value; render() end)
noctalia.state.watch(status.STATE, function(value)
    snapshot = value
    if value.phase ~= "ready" then effectsOpen, effectKeyboard = false, false end
    if value.phase == "ready" then presented = value elseif value.phase ~= "refreshing" then presented = nil end
    render()
end)

-- The image swatch has no native button semantics. Captured palette chords keep
-- every color keyboard-accessible and still prepare a review, never an apply.
function onKey(chord, pressed)
    if not opened or not pressed then return end
    if effectsOpen and (chord == "Up" or chord == "Down" or chord == "Home" or chord == "End") then
        if chord == "Home" then effectCursor = 1
        elseif chord == "End" then effectCursor = #visibleEffects
        else effectCursor = math.max(1, math.min(#visibleEffects, effectCursor + (chord == "Down" and 1 or -1))) end
        effectKeyboard, effectHover = true, nil
        render()
        return
    end
    local index = type(chord) == "string" and chord:lower():match("^alt%+([1-8])$")
    if index then choose("palette", tonumber(index) - 1) end
end
