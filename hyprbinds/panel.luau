--!nonstrict
local parser = require("./lib/parser.luau")
local icons = require("./lib/icons.luau")
local view = require("./lib/view.luau")
local fonts = require("./lib/fonts.luau")
local opened, loading = false, false
local bindings, diagnostics, nodes = {}, {}, {}
local query, style, message = "", "text", ""
local normalizedQuery = ""
local prepared, preparation, presentationVersion, tokenVersion = {}, nil, 0, 0
local frameBudget, iterationLimit = 0.003, 4096
local job, build = nil, nil
local count, headerCount, contentWidth = 0, 0, 1340
local collected, viewReady, renderedQuery = false, false, ""
local columns, columnWidth = view.layout(contentWidth)
local inputKey = 0
local iconStyle, fontProfile, fontPending, fontStarted = "auto", {}, nil, false
local cacheVersion = 1
-- Noctalia recreates panel VMs when settings change. Retain only source results,
-- not controls, so presentation preferences never trigger configuration reads.
local cached = noctalia.state and noctalia.state.get("keycaps.source")
if cached and cached.version == cacheVersion and cached.path == noctalia.getConfig("config_path") then
    bindings, diagnostics, collected = cached.bindings, cached.diagnostics, true
end

local function render()
    local contents = nodes
    if #contents == 0 then
        contents = {ui.column({paddingV = 48, gap = 12, align = "center"}, {
            ui.glyph({name = "keyboard", size = 36, color = "on_surface_variant"}),
            ui.label({text = loading and "Reading Lua configuration…" or build and "Filtering shortcuts…"
                or query ~= "" and "No matching shortcuts" or "No literal hl.bind declarations found", fontSize = 17}),
            ui.label({text = "Read-only • Your Lua configuration is never executed", color = "on_surface_variant", fontSize = 12}),
        })}
    end
    local title = ui.row({gap = 12, align = "center", width = contentWidth >= 1000 and 330 or contentWidth - 60}, {
        ui.row({width = 44, height = 44, radius = 10, fill = "primary/0.12", border = "primary/0.5", borderWidth = 1,
            align = "center", justify = "center"}, {ui.glyph({name = "keyboard", size = 27, color = "primary"})}),
        ui.column({gap = 4, flexGrow = 1}, {
            ui.label({text = "Hyprland Keybindings", fontSize = 21, fontWeight = "bold"}),
            ui.label({text = "Quick reference for your shortcuts", fontSize = 12, color = "on_surface_variant"}),
        }),
    })
    local search = ui.row({gap = 8, paddingH = 10, radius = 9, fill = "surface/0.65", border = "outline_variant/0.45", borderWidth = 1, flexGrow = 1, align = "center"}, {
        ui.glyph({name = "search", size = 17, color = "on_surface_variant"}),
        ui.input({key = "search-" .. inputKey, value = query, placeholder = "Search keybindings…", frameVisible = false,
            flexGrow = 1, focus = true, onChange = "searchChanged"}),
    })
    local settings = ui.button({glyph = "settings", variant = "outline", tooltip = "Plugin settings", onClick = "openPreferences"})
    local refreshButton = ui.button({glyph = "refresh", text = "Refresh", variant = "primary", enabled = not loading, onClick = "refresh"})
    local close = ui.button({glyph = "x", variant = "outline", tooltip = "Close", onClick = "closeCheatsheet"})
    local toolbar
    if contentWidth >= 1000 then
        toolbar = ui.row({gap = 12, align = "center"}, {title, search, settings, refreshButton, close})
    else
        toolbar = ui.column({gap = 12}, {
            ui.row({gap = 12, align = "center", justify = "space_between"}, {title, close}),
            ui.row({gap = 8, align = "center"}, {search, settings, refreshButton}),
        })
    end
    panel.render(ui.column({gap = 14, flexGrow = 1}, {
        toolbar,
        ui.label({text = tostring(#bindings) .. " discovered  ·  " .. tostring(count) .. " shown  ·  " .. tostring(headerCount) .. " headers"
            .. (loading and "  ·  Refreshing…" or build and "  ·  Filtering…" or ""), color = "on_surface_variant", fontSize = 12}),
        ui.label({text = message, visible = message ~= "", color = "on_surface_variant", fontSize = 12}),
        ui.scroll({key = "results", flexGrow = 1, gap = 14}, contents),
        ui.label({text = "Read-only cheatsheet  ·  Esc to close", fontSize = 11, color = "on_surface_variant"}),
    }))
end

local function wake()
    if opened then panel.setNeedsFrameTick(true) end
end
local function startBuild()
    build = {index = 1, groups = {}, count = 0, headers = 0, query = normalizedQuery}
    wake()
end

local function preparePresentation(sourceChanged, tokensChanged)
    if sourceChanged then prepared = {} end
    if tokensChanged then tokenVersion = tokenVersion + 1 end
    presentationVersion = presentationVersion + 1
    preparation = {index = 1}
    viewReady = false
    startBuild()
end

local function prepareOne()
    local index = preparation.index
    local binding = bindings[index]
    if not binding then preparation = nil; return end
    local entry = prepared[index]
    if not entry then
        entry = {search = icons.prepareSearch(binding), description = icons.wrapText(binding.description)}
        prepared[index] = entry
    end
    if entry.tokenVersion ~= tokenVersion then
        entry.tokens = icons.tokens(binding.shortcut, style, iconStyle, fontProfile)
        entry.tokenVersion = tokenVersion
    end
    if entry.version ~= presentationVersion then
        entry.shortcut, entry.width = view.shortcut(binding.shortcut, style, view.keyBudget(columnWidth),
            iconStyle, fontProfile, entry.tokens)
        entry.row, entry.rowWidth = nil, nil
        entry.version = presentationVersion
    end
    preparation.index = index + 1
end

function refresh()
    if not opened then return end
    if job then job:cancel() end
    loading, message, build = true, "", nil
    job = parser.new({readFileAsync = noctalia.readFileAsync, home = noctalia.expandPath("~")},
        noctalia.getConfig("config_path"), wake)
    wake()
    render()
end

function onOpen()
    opened = true
    inputKey = inputKey + 1
    local previousStyle, previousColumnWidth, previousColumns, previousIcons = style, columnWidth, columns, iconStyle
    style = noctalia.getConfig("super_style")
    iconStyle = noctalia.getConfig("icon_style") or "auto"
    if not fontStarted then
        fontStarted = true
        fonts.probe(noctalia, function(profile)
            -- Async completion stores data only; tree work stays in bounded frames.
            fontPending = profile
            wake()
        end)
    end
    contentWidth = 1340
    local focused = noctalia.focusedOutputName()
    for _, output in ipairs(noctalia.outputs()) do
        if output.name == focused then
            contentWidth = math.max(240, math.min(1400, output.width / math.max(1, output.scale or 1) - 80) - 60)
        end
    end
    columns, columnWidth = view.layout(contentWidth)
    if not collected then
        refresh()
    elseif presentationVersion == 0 or previousStyle ~= style or previousColumnWidth ~= columnWidth or previousIcons ~= iconStyle then
        preparePresentation(false, previousStyle ~= style or previousIcons ~= iconStyle)
        render()
    elseif not viewReady or preparation or previousColumns ~= columns then
        startBuild()
        render()
    else
        -- Keep the completed tree: reopening requires neither I/O nor rebuilding.
        render()
    end
    if fontPending then wake() end
end

function onFrameTick()
    if not opened then panel.setNeedsFrameTick(false); return end
    local started = os.clock()
    if fontPending then
        local changed = not fonts.same(fontProfile, fontPending)
        fontProfile, fontPending = fontPending, nil
        if changed and collected then preparePresentation(false, true) end
    end
    local runnable = false
    local collecting = job ~= nil
    if job then
        -- Finite batches avoid a frame per tiny scanner step; keep I/O separate.
        for _ = 1, 64 do
            runnable = job:step()
            if job.done or not runnable or os.clock() - started >= frameBudget then break end
        end
        if job.done then
            local result = job
            job, loading, collected = nil, false, true
            diagnostics = result.diagnostics
            if result.files > 0 then
                bindings = result.bindings
                preparePresentation(true)
                if noctalia.state then
                    noctalia.state.set("keycaps.source", {version = cacheVersion, path = noctalia.getConfig("config_path"),
                        bindings = bindings, diagnostics = diagnostics})
                end
            else
                message = "Could not read the main configuration. Check the path in plugin settings. Previous results retained."
                startBuild()
            end
            if #diagnostics > 0 and message == "" then
                message = tostring(#diagnostics) .. " source diagnostic(s); unsupported or unreadable imports may be omitted."
            end
        end
    end
    if not collecting then
        -- os.clock() is monotonic elapsed time in Noctalia's Luau runtime.
        -- Preparation and building share one slice, with a finite safety ceiling.
        for _ = 1, iterationLimit do
            if os.clock() - started >= frameBudget then break end
            if preparation then
                prepareOne()
            elseif not build then
                break
            elseif build.phase == "commit" then
                -- Leave headroom for native tree conversion; it cannot yield.
                if os.clock() - started >= 0.001 then break end
                nodes = view.cards(build.groups, columns, columnWidth)
                renderedQuery, viewReady = query, true
                count, headerCount, build = build.count, build.headers, nil
                render()
                break
            elseif build.phase == "rows" then
                local group = build.groups[build.groupIndex]
                if not group then
                    build.phase = "commit"
                else
                    local index = group.entries[build.rowIndex]
                    if index then
                        local entry = prepared[index]
                        -- One row per binding, not one cache per query/alignment.
                        if not entry.row or entry.rowWidth ~= group.keyWidth then
                            entry.row = view.binding(bindings[index], index, style, columnWidth,
                                iconStyle, fontProfile, group.keyWidth, entry.shortcut, entry.description)
                            entry.rowWidth = group.keyWidth
                        end
                        group.rows[#group.rows + 1] = entry.row
                        build.rowIndex = build.rowIndex + 1
                    else
                        group.entries = nil
                        build.groupIndex, build.rowIndex = build.groupIndex + 1, 1
                    end
                end
            else
                local index = build.index
                local binding = bindings[index]
                if not binding then
                    build.phase, build.groupIndex, build.rowIndex = "rows", 1, 1
                else
                    build.index = index + 1
                    local entry = prepared[index]
                    if icons.matchesPrepared(entry.search, build.query) then
                        local group = build.groups[#build.groups]
                        if not group or binding.header ~= group.header or binding.file ~= group.file then
                            group = {header = binding.header, file = binding.file, rows = {}, entries = {}, keyWidth = 0}
                            build.groups[#build.groups + 1] = group
                            if binding.header then build.headers = build.headers + 1 end
                        end
                        group.keyWidth = math.max(group.keyWidth, entry.width)
                        group.entries[#group.entries + 1] = index
                        build.count = build.count + 1
                    end
                end
            end
        end
    end
    panel.setNeedsFrameTick(runnable or build ~= nil or preparation ~= nil)
end

function searchChanged(value)
    if not opened then return end
    query = value
    local normalized = string.lower(value)
    if normalized == normalizedQuery then
        if normalized == string.lower(renderedQuery) then renderedQuery = value end
        return
    end
    normalizedQuery = normalized
    startBuild()
end
function closeCheatsheet() panel.close() end
function openPreferences() noctalia.openSettings() end
function onClose()
    opened = false
    if job then job:cancel() end
    job, build, loading = nil, nil, false
    query = renderedQuery
    normalizedQuery = string.lower(query)
    panel.setNeedsFrameTick(false)
end
