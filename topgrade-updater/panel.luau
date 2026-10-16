--!nonstrict
local shared = require("./shared.luau")
local core = require("./core.luau")
local snapshot = noctalia.state.get(shared.STATE)
local expanded = {}
local unknownOpen = false
local render

local function sourceLabel(key)
    return key == "pacman" and "Pacman" or key
end

local function sourceGlyph(key)
    return key:match("^AUR") and "cloud" or "package"
end

local function headline(s)
    if s.phase == "error" then return s.error or s.updateError or "Check failed", "error" end
    if s.phase == "checking" then return "Checking packages with Topgrade", "secondary" end
    if s.phase == "running" then return "Updating in terminal…", "secondary" end
    if s.total > 0 then return "Count: " .. tostring(s.total), "primary" end
    if s.phase == "clean" and s.complete then
        return #(s.counts or {}) == 0 and "No enabled Pacman/AUR sources" or "Pacman/AUR up to date", "on_surface"
    end
    if s.phase == "idle" then return "Check for updates", "on_surface_variant" end
    return "Update counts incomplete", "warning"
end

render = function()
    local s = snapshot or { phase = "idle", total = 0, counts = {}, unknown = {} }
    local busy = s.phase == "checking" or s.phase == "running"
    local canCheck = not busy and not s.updateBlocked
    local canUpdate = canCheck and s.total > 0
    local unknown = s.unknown or {}
    local text, color = headline(s)

    local rows = {
        ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = "Topgrade Updater", fontWeight = "bold", fontSize = 16, color = "on_surface", flexGrow = 1 }),
            ui.button({
                key = "check" .. (canCheck and "" or "-off"), glyph = "refresh", variant = "ghost",
                enabled = canCheck, tooltip = "Check for updates",
                onClick = function() if canCheck then shared.request("check") end end,
            }),
            ui.button({
                glyph = "close", variant = "ghost", tooltip = "Close",
                onClick = function() panel.close() end,
            }),
        }),
    }
    if not noctalia.commandExists("topgrade") then
        table.insert(rows, ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = "Topgrade", color = "on_surface_variant", fontSize = 11, flexGrow = 1 }),
            ui.label({ text = "Not found", color = "error", fontSize = 11 }),
        }))
    end
    table.insert(rows, ui.label({ text = text, color = color, maxLines = 3 }))
    if s.updateError and (s.phase ~= "error" or s.error) then
        table.insert(rows, ui.label({ text = s.updateError, color = "error", maxLines = 3 }))
    end
    if s.updateBlocked then
        table.insert(rows, ui.label({
            text = "Updates blocked: " .. s.updateBlocked,
            color = "error", maxLines = 6,
        }))
    end
    local content, clean = {}, {}
    for _, entry in ipairs(s.counts or {}) do
        local key = entry.key
        if entry.n > 0 then
            local open = expanded[key] == true
            table.insert(content, ui.row({
                key = "source-" .. key .. (open and "-open" or ""), gap = 8, align = "center",
                onClick = function() expanded[key] = not expanded[key]; render() end,
            }, {
                ui.glyph({ name = open and "chevron-down" or "chevron-right", size = 12, color = "on_surface_variant" }),
                ui.glyph({ name = sourceGlyph(key), size = 13, color = "on_surface_variant" }),
                ui.label({ text = sourceLabel(key), color = "on_surface", flexGrow = 1 }),
                ui.label({ text = tostring(entry.n), color = "primary", fontWeight = "bold" }),
            }))
            if open then
                for index, item in ipairs(entry.items) do
                    table.insert(content, ui.row({ key = "pkg-" .. key .. "-" .. index, paddingH = 18, gap = 4, align = "center" }, {
                        ui.label({ text = item.name, fontSize = 11, color = "on_surface", flexGrow = 1, maxLines = 2 }),
                        ui.label({ text = item.from, fontSize = 11, color = "on_surface_variant", maxWidth = 78, maxLines = 1 }),
                        ui.label({ text = "→", fontSize = 11, color = "on_surface_variant" }),
                        ui.label({ text = item.to, fontSize = 11, color = "primary", maxWidth = 78, maxLines = 1 }),
                    }))
                end
                if entry.n > #entry.items then
                    table.insert(content, ui.label({
                        text = tostring(entry.n - #entry.items) .. " more packages (list capped at 200)",
                        fontSize = 11, color = "on_surface_variant",
                    }))
                end
            end
        elseif not busy and s.complete and #unknown == 0 then
            table.insert(clean, sourceLabel(key))
        end
    end
    if unknownOpen and #unknown > 0 then
        for index, detail in ipairs(unknown) do
            table.insert(content, ui.label({ key = "unknown-" .. index, text = detail, fontSize = 11, color = "on_surface_variant", maxLines = 4 }))
        end
    end
    if #content > 0 then
        table.insert(rows, ui.scroll({ key = "sources", flexGrow = 1, gap = 6 }, content))
    else
        table.insert(rows, ui.spacer({ flexGrow = 1 }))
    end
    if #clean > 0 then
        table.insert(rows, ui.label({
            text = "Up to date: " .. table.concat(clean, ", "), fontSize = 11,
            color = "on_surface_variant", maxLines = 2,
        }))
    end
    if #unknown > 0 then
        table.insert(rows, ui.row({
            key = "unknown-summary" .. (unknownOpen and "-open" or ""), gap = 6, align = "center",
            onClick = function() unknownOpen = not unknownOpen; render() end,
        }, {
            ui.glyph({ name = unknownOpen and "chevron-down" or "chevron-right", size = 12, color = "warning" }),
            ui.glyph({ name = "alert-triangle", size = 13, color = "warning" }),
            ui.label({
                text = "Check warnings: " .. #unknown,
                fontSize = 11, color = "warning", flexGrow = 1, maxLines = 2,
            }),
        }))
    end
    if not busy and noctalia.getConfig("show_download_size") ~= false and type(s.downloadBytes) == "number" then
        table.insert(rows, ui.row({ key = "download-size", gap = 6, align = "center" }, {
            ui.glyph({ name = "download", size = 13, color = "on_surface_variant" }),
            ui.label({ text = "≈ " .. core.formatDownload(s.downloadBytes) .. " to download", fontSize = 11, color = "on_surface_variant" }),
        }))
    end
    table.insert(rows, ui.separator({}))
    if s.checkedAt then
        table.insert(rows, ui.label({ text = "checked " .. s.checkedAt, fontSize = 11, color = "on_surface_variant" }))
    end
    table.insert(rows, ui.row({ gap = 8, align = "center", justify = "end" }, {
        ui.button({
            text = "Dismiss", variant = "ghost",
            onClick = function()
                shared.request("dismiss")
                panel.close()
            end,
        }),
        ui.button({
            key = "update" .. (canUpdate and "" or "-off"), glyph = "terminal", text = "Update", variant = "primary",
            enabled = canUpdate, tooltip = "Run full configured Topgrade in terminal, including uncounted steps",
            onClick = function()
                if not canUpdate then return end
                shared.request("update")
                panel.close()
            end,
        }),
    }))
    panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, rows))
end
function onOpen() snapshot = noctalia.state.get(shared.STATE); render() end
noctalia.state.watch(shared.STATE, function(value) snapshot = value; render() end)
