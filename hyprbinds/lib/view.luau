--!nonstrict

local icons = require("./icons.luau")
local view = {}

function view.layout(width)
    local columns = width >= 1100 and 3 or width >= 760 and 2 or 1
    return columns, math.floor((width - (columns - 1) * 14) / columns)
end

function view.shortcut(shortcut, style, budget, iconStyle, profile, preparedTokens)
    local tokens = preparedTokens or icons.tokens(shortcut, style, iconStyle, profile)
    if #tokens > 32 then tokens = {{text = shortcut}} end
    local lines, line, used, widest = {}, {}, 0, 0
    local function flush()
        if #line > 0 then
            widest = math.max(widest, used)
            lines[#lines + 1] = ui.row({gap = 4, align = "center"}, line)
            line, used = {}, 0
        end
    end
    for index, token in ipairs(tokens) do
        local symbolic = token.symbol or token.glyph
        local label = token.label or token.text
        local showText = not symbolic or token.label
        local desired = showText and math.max(28, 14 + #label * 6.5 + (symbolic and 20 or 0)) or 30
        -- Keep each separator with its following cap, including across wraps.
        local separatorWidth = index > 1 and 12 or 0
        local width = math.min(budget - separatorWidth, desired)
        local gap = #line > 0 and 4 or 0
        if used + gap + separatorWidth + width > budget then flush(); gap = 0 end
        if index > 1 then
            line[#line + 1] = ui.label({text = "+", width = 8, fontSize = 11,
                textAlign = "center", color = "on_surface_variant"})
        end
        local children = {}
        if token.symbol then
            children[1] = ui.label({text = token.symbol, fontFamily = token.fontFamily, fontSize = 16,
                width = 18, textAlign = "center", color = "on_surface"})
        elseif symbolic then children[1] = ui.glyph({name = token.glyph, size = 15, color = "on_surface"}) end
        if showText then
            children[#children + 1] = ui.label({text = icons.wrapText(label), fontSize = 11,
                fontWeight = "medium", maxWidth = math.max(12, width - 12 - (symbolic and 20 or 0)), flexGrow = 1, textAlign = "center"})
        end
        line[#line + 1] = ui.row({width = width, minHeight = 30, gap = 4, paddingH = 6, paddingV = 5, align = "center", justify = "center",
            fill = "surface_container/0.7", radius = 5, border = "outline_variant/0.4", borderWidth = 1, tooltip = token.text}, children)
        used = used + gap + separatorWidth + width
    end
    flush()
    return ui.column({gap = 4, width = widest, tooltip = shortcut}, lines), widest
end

function view.keyBudget(width)
    return math.min(width >= 600 and 240 or 220, math.floor((width - 32) * 0.6))
end

function view.binding(binding, index, style, width, iconStyle, profile, alignedWidth, preparedShortcut, wrappedDescription)
    local shortcut, shortcutWidth
    if preparedShortcut then
        shortcut, shortcutWidth = preparedShortcut, alignedWidth
    else
        shortcut, shortcutWidth = view.shortcut(binding.shortcut, style, view.keyBudget(width), iconStyle, profile)
    end
    if alignedWidth then
        shortcutWidth = alignedWidth
        shortcut = ui.column({width = alignedWidth}, {shortcut})
    end
    return ui.column({key = "binding-" .. index, gap = 0}, {
        ui.row({gap = 12, paddingH = 12, paddingV = 7, align = "center"}, {
            shortcut,
            ui.label({text = wrappedDescription or icons.wrapText(binding.description), fontSize = 13, flexGrow = 1,
                maxWidth = math.max(50, width - shortcutWidth - 40)}),
        }),
        ui.separator({color = "outline_variant/0.14", thickness = 1}),
    })
end

function view.pack(nodes, gap)
    if #nodes <= 128 then return nodes end
    local groups = {}
    for start = 1, #nodes, 128 do
        local children = {}
        for index = start, math.min(start + 127, #nodes) do children[#children + 1] = nodes[index] end
        groups[#groups + 1] = ui.column({key = "chunk-" .. start, gap = gap or 0}, children)
    end
    return view.pack(groups, gap)
end

local function headerIcon(header)
    local text = string.lower(header)
    if string.find(text, "application", 1, true) then return "apps"
    elseif string.find(text, "monitor", 1, true) then return "device-desktop"
    elseif string.find(text, "window", 1, true) then return "window"
    elseif string.find(text, "workspace", 1, true) then return "layout-grid"
    elseif string.find(text, "mouse", 1, true) then return "mouse"
    elseif string.find(text, "system", 1, true) then return "settings"
    elseif string.find(text, "help", 1, true) then return "help" end
    return "keyboard"
end

function view.cards(groups, columns, width)
    if #groups == 0 then return {} end
    local stacks, weights, total = {}, {}, 0
    for index, group in ipairs(groups) do
        weights[index] = #group.rows + (group.header and 2 or 0)
        total = total + weights[index]
    end
    for index = 1, columns do stacks[index] = {} end
    local column, used, remaining = 1, 0, total
    for index, group in ipairs(groups) do
        local target = remaining / (columns - column + 1)
        if column < columns and used > 0 and math.abs(used - target) < math.abs(used + weights[index] - target) then
            remaining, column, used = remaining - used, column + 1, 0
        end
        local children = {}
        if group.header then
            children[#children + 1] = ui.row({gap = 10, paddingH = 12, paddingV = 12,
                align = "center", fill = "surface_container/0.4", radius = 9}, {
                ui.glyph({name = headerIcon(group.header), size = 21, color = "primary"}),
                ui.label({text = icons.wrapText(group.header), fontSize = 15, fontWeight = "bold", flexGrow = 1}),
                ui.row({paddingH = 7, paddingV = 3, fill = "surface_container/0.8", radius = 5}, {
                    ui.label({text = tostring(#group.rows), fontSize = 11, fontWeight = "medium"}),
                }),
            })
        end
        children[#children + 1] = ui.column({gap = 0, paddingV = 4}, view.pack(group.rows))
        stacks[column][#stacks[column] + 1] = ui.column({key = "group-" .. index, gap = 0,
            fill = "surface/0.65", radius = 11, border = "outline_variant/0.35", borderWidth = 1}, children)
        used = used + weights[index]
    end
    local result = {}
    for index = 1, columns do
        result[#result + 1] = ui.column({key = "column-" .. index, width = width, flexGrow = 1, gap = 14}, view.pack(stacks[index], 14))
    end
    return {ui.row({key = "cards", gap = 14, align = "start"}, result)}
end
return view
