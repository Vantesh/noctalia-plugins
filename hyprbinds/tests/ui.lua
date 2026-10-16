-- Mock only host I/O and UI constructors; parse real fixture text, never execute it.
local originalRequire = require
require = function(path)
    if path == "./fonts.luau" then return assert(loadfile("lib/fonts.luau"))() end
    if path == "./icons.luau" then return assert(loadfile("lib/icons.luau"))() end
    if string.sub(path, 1, 2) == "./" then return assert(loadfile(string.sub(path, 3)))() end
    return originalRequire(path)
end
local function fuzzyScore(query, text)
    if query == "obr" and string.lower(text) == "open browser" then return 0 end
    return string.find(string.lower(text), query, 1, true) and 1 or nil
end
noctalia = {fuzzyScore = fuzzyScore}
local icons = assert(loadfile("lib/icons.luau"))()
local checks = 0
local function check(value, name) checks = checks + 1; assert(value, name) end
check(icons.tokens("SUPER + A", "windows")[1].glyph == "brand-windows", "Windows")
local fonts = assert(loadfile("lib/fonts.luau"))()
local profile = {
    unicode = fonts.parse("Keyboard Symbols\t2190-2193 21a9 21e5 21e7 21ea 2303 2318 2325 232b 238b\n"),
    nerd = fonts.parse("JetBrainsMono Nerd Font Mono\tf000-f385 eee8 efba f040e\n", true),
}
check(icons.tokens("SUPER + A", "apple", "auto", profile)[1].symbol == "⌘", "macOS Command, never Apple brand")
local linux = icons.tokens("SUPER + A", "linux", "auto", profile)[1]
check(linux.symbol == "" and linux.fontFamily == profile.nerd.family, "Linux uses verified Nerd Font glyph")
local missingLinux = icons.tokens("SUPER + A", "linux", "auto", {})[1]
check(missingLinux.text == "Linux" and not missingLinux.symbol and not missingLinux.glyph, "missing Linux glyph stays readable")
check(icons.tokens("SUPER + A", "text")[1].text == "Super", "text")

check(icons.tokens("SUPER + +", "text")[2].text == "+", "literal plus")
local binding = {shortcut = "SUPER + A", description = "Open browser", header = "Applications"}
local preparedSearch = icons.prepareSearch(binding)
for query, expected in pairs({super = true, browser = true, obr = true, applications = true,
    apln = false, ["%"] = false, ["private-action"] = false, [""] = true}) do
    check(icons.matchesPrepared(preparedSearch, query) == expected, "prepared search matches descriptions, shortcuts and literal headers")
end
check(icons.wrapText("abcdefghijklmnop"):find("\226\128\139", 1, true), "long word break")

ui = {}
local keycapBuilds, rowBuilds = 0, 0
for _, name in ipairs({"row", "column", "label", "glyph", "separator", "scroll", "button", "input"}) do
    ui[name] = function(props, children)
        if name == "row" and props.minHeight == 30 then keycapBuilds = keycapBuilds + 1 end
        if name == "column" and props.key and props.key:match("^binding%-%d+$") then rowBuilds = rowBuilds + 1 end
        return {type = name, props = props, children = children or {}}
    end
end
local view = assert(loadfile("lib/view.luau"))()

check(view.layout(1099) == 2 and view.layout(1100) == 3, "three-column width threshold")
check(view.layout(759) == 1 and view.layout(760) == 2, "two-column width threshold")

local many = {}
for i = 1, 257 do many[i] = ui.label({text = tostring(i)}) end
local packed = view.pack(many)
local total = 0
local function countLeaves(node)
    assert(#node.children <= 128, "packed child limit")
    if node.type == "label" then total = total + 1 end
    for _, child in ipairs(node.children) do countLeaves(child) end
end
for _, node in ipairs(packed) do countLeaves(node) end
check(#packed <= 128 and total == 257, "large lists stay within child limits without dropping rows")

local wrapped = view.shortcut("SUPER + SHIFT + DEL + PrintScreen + " .. string.rep("X", 300), "windows", 95, "auto", profile)
local separators = 0
for _, line in ipairs(wrapped.children) do
    local width = math.max(0, #line.children - 1) * line.props.gap
    for _, child in ipairs(line.children) do
        width = width + child.props.width
        if child.type == "label" then separators = separators + 1; check(child.props.text == "+", "separator label") end
    end
    check(width <= 95, "separators included in wrap budget")
    check(line.children[#line.children].type == "row", "no orphan trailing separator")
end
check(separators == 4, "one separator per shortcut boundary")
for _, width in ipairs({370, 700}) do
    local row = view.binding({shortcut = "SUPER + SHIFT + CTRL + Left",
        description = "Move window to monitor"}, 1, "windows", width, "auto", profile).children[1]
    local shortcut = row.children[1]
    check(#shortcut.children == 1 and #shortcut.children[1].children == 7, "four keys fit on one line")
    local lineWidth = (#shortcut.children[1].children - 1) * shortcut.children[1].props.gap
    for _, child in ipairs(shortcut.children[1].children) do lineWidth = lineWidth + child.props.width end
    check(lineWidth <= shortcut.props.width, "four-key line fits shortcut budget")
    check(shortcut.props.width + row.props.gap + row.props.paddingH * 2 + row.children[2].props.maxWidth <= width,
        "shortcut and description fit card")
end
local narrow = view.binding({shortcut = "SUPER + SHIFT + CTRL + Left", description = "Move window"},
    1, "windows", 260, "auto", profile).children[1].children[1]
check(#narrow.children > 1, "four keys still wrap on narrow cards")

local text = '-- === Applications ===\nhl.bind("SUPER + CTRL + Left", opaque(), {description = "Open browser"})\nhl.bind("mouse_down", opaque())'
local callbacks, ticks, tree, reads = {}, false, nil, 0
local config = {config_path = "/fixture/main.lua", super_style = "windows", icon_style = "auto"}
local state, outputWidth = {}, 800
noctalia = {
    fuzzyScore = fuzzyScore,
    state = {get = function(key) return state[key] end, set = function(key, value) state[key] = value end},
    getConfig = function(key) return config[key] end,
    expandPath = function() return "/fixture" end,
    focusedOutputName = function() return "test" end,
    outputs = function() return {{name = "test", width = outputWidth, scale = 1}} end,
    readFileAsync = function(_, cb) reads = reads + 1; callbacks[#callbacks + 1] = cb; return true end,
    openSettings = function() end,
}
panel = {
    render = function(value) tree = value end,
    setNeedsFrameTick = function(value) ticks = value end,
    close = function() onClose() end,
}
assert(loadfile("panel.luau"))()
local function drain()
    for _ = 1, 10000 do
        if #callbacks > 0 then local cb = table.remove(callbacks, 1); cb(text, nil) end
        if ticks then onFrameTick() else return end
    end
    error("panel failed to settle")
end
local function labels(node, out)
    out = out or {}
    if node.type == "label" then out[#out + 1] = node.props.text end
    for _, child in ipairs(node.children) do labels(child, out) end
    return table.concat(out, "\n")
end
onOpen(); drain()
check(labels(tree):find("2 discovered", 1, true), "panel discovers all rows")
check(labels(tree):find("No description", 1, true), "missing description visible")
check(labels(tree):find("Applications", 1, true), "header visible")
local alignedRows = {}
local function findAlignedRows(node)
    if node.props.key and node.props.key:match("^binding%-%d+$") then
        alignedRows[#alignedRows + 1] = node.children[1]
    end
    for _, child in ipairs(node.children) do findAlignedRows(child) end
end
findAlignedRows(tree)
check(#alignedRows == 2, "alignment fixture renders both rows")
check(alignedRows[1].children[1].props.width == alignedRows[2].children[1].props.width,
    "different shortcut lengths share a category-wide description offset")
check(alignedRows[1].children[2].props.maxWidth == alignedRows[2].children[2].props.maxWidth,
    "aligned descriptions share the same wrapping width")
local longestShortcut = 0
for _, row in ipairs(alignedRows) do
    longestShortcut = math.max(longestShortcut, row.children[1].children[1].props.width)
end
check(alignedRows[1].children[1].props.width == longestShortcut, "category width matches longest packed shortcut")
searchChanged("OBR"); drain()
check(labels(tree):find("1 shown", 1, true), "fuzzy description filter")
searchChanged("unmatched"); drain()
check(labels(tree):find("No matching shortcuts", 1, true), "search empty state")
searchChanged(""); drain()
text = nil; refresh(); drain()
check(labels(tree):find("2 discovered", 1, true), "failed refresh retains results")
check(labels(tree):find("Could not read", 1, true), "read error visible")
text = 'hl.bind("F1", opaque(), {desc = "Help"})'
refresh(); drain()
check(labels(tree):find("1 discovered", 1, true), "refresh recovers")
refresh(); onFrameTick(); onClose()
for _, cb in ipairs(callbacks) do cb(text, nil) end
callbacks = {}
check(not ticks, "closed callbacks do not restart frames")
local before = reads
text = 'hl.bind("F2", opaque(), {desc = "Changed on disk"})'
onOpen()
check(reads == before, "reopen does not reread configuration")
check(not ticks, "cached reopen requires no build frames")
check(labels(tree):find("Help", 1, true), "cached rows render immediately")
check(not labels(tree):find("Changed on disk", 1, true), "disk changes require Refresh")
searchChanged("unmatched"); onClose(); onOpen()
check(not ticks and labels(tree):find("Help", 1, true), "closing during filtering restores completed view")
refresh(); drain()
check(reads > before and labels(tree):find("Changed on disk", 1, true), "Refresh replaces cached data")
onClose()
config.super_style, config.icon_style = "text", "nerd"
assert(loadfile("panel.luau"))()
before = reads
onOpen(); drain()
check(reads == before and labels(tree):find("Changed on disk", 1, true), "settings reload preserves nonempty source results")
onClose()
config.config_path = "/fixture/other.lua"
assert(loadfile("panel.luau"))()
before = reads
onOpen(); drain()
check(reads > before, "source path change invalidates process cache")
text = ""; refresh(); drain(); onClose()
before = reads
onOpen()
check(reads == before and not ticks, "empty results are cached too")
check(labels(tree):find("No literal", 1, true), "cached empty state is immediate")
onClose()

state = {}
-- Closing an unfinished initial read must not leave the panel stuck forever.
assert(loadfile("panel.luau"))()
text = 'hl.bind("F3", opaque(), {desc = "First load recovery"})'
onOpen(); onFrameTick(); onClose()
for _, cb in ipairs(callbacks) do cb(text, nil) end
callbacks = {}
check(not ticks, "cancelled first read cannot wake a closed panel")
onOpen(); drain()
check(labels(tree):find("First load recovery", 1, true), "unfinished first load retries on reopen")
onClose()
state = {}
assert(loadfile("panel.luau"))()
onOpen(); onFrameTick()
for _, cb in ipairs(callbacks) do cb(text, nil) end
callbacks = {}
onFrameTick() -- Collection completes; presentation has not been built yet.
before = reads
onClose(); onOpen(); drain()
check(reads == before, "closing after collection does not reread source")
check(labels(tree):find("First load recovery", 1, true), "unfinished view rebuilds from cached bindings")
onClose()

-- Deterministic elapsed-time slices exercise preparation and query supersession.
local realClock, elapsed = os.clock, 0
os.clock = function() elapsed = elapsed + 0.0001; return elapsed end
local fixture = {}
for header = 1, 7 do
    fixture[#fixture + 1] = "-- === Group " .. header .. " ==="
    for index = 1, 14 do
        local shortcut = index == 1 and "F1" or "SUPER + CTRL + SHIFT + Left"
        local description = index == 1 and "Shared narrow action" or "Shared long action " .. string.rep("x", 80)
        fixture[#fixture + 1] = string.format("hl.bind(%q, opaque(), {description = %q})", shortcut, description)
    end
end
text, state, outputWidth = table.concat(fixture, "\n"), {}, 577
config.super_style, config.icon_style = "windows", "auto"
local fontCallbacks = {}
noctalia.runAsync = function(_, cb) fontCallbacks[#fontCallbacks + 1] = cb; return true end
local testRequire, tokenBuilds, searchPreparations, descriptionWraps = require, 0, 0, 0
require = function(path)
    local module = testRequire(path)
    if path == "./lib/icons.luau" then
        local tokens, prepareSearch, wrapText = module.tokens, module.prepareSearch, module.wrapText
        module.tokens = function(...) tokenBuilds = tokenBuilds + 1; return tokens(...) end
        module.prepareSearch = function(...) searchPreparations = searchPreparations + 1; return prepareSearch(...) end
        module.wrapText = function(...) descriptionWraps = descriptionWraps + 1; return wrapText(...) end
    end
    return module
end
assert(loadfile("panel.luau"))()
require = testRequire
onOpen(); drain()
check(labels(tree):find("98 discovered  ·  98 shown  ·  7 headers", 1, true), "all seven headers and bindings survive preparation")
check(tokenBuilds == 98 and searchPreparations == 98 and descriptionWraps == 98, "source data prepared once per binding")
local caps, rows, sourceReads = keycapBuilds, rowBuilds, reads
searchChanged("shared"); drain()
check(keycapBuilds == caps and rowBuilds == rows, "warm search reuses keycaps and aligned rows")
searchChanged("SHARED")
check(not ticks, "case-only query change requires no build")
onClose(); onOpen()
local function find(node, key)
    if node.props.key == key then return node end
    for _, child in ipairs(node.children) do
        local result = find(child, key)
        if result then return result end
    end
end
check(find(tree, "search-2").props.value == "SHARED", "case-only query spelling survives reopen")
check(#find(tree, "cards").children == 1, "narrow output has one column")
onClose(); outputWidth = 1480; onOpen(); drain()
check(#find(tree, "cards").children == 3, "column-count change rebuilds cards even at identical column width")
local orderedRows, orderedHeaders = 0, {}
local function inspectOrder(node)
    assert(#node.children <= 256, "native child limit")
    if node.props.key and node.props.key:match("^binding%-%d+$") then
        orderedRows = orderedRows + 1
        assert(node.props.key == "binding-" .. orderedRows, "column-major source order")
    end
    if node.type == "label" and node.props.fontSize == 15 then orderedHeaders[#orderedHeaders + 1] = node.props.text end
    for _, child in ipairs(node.children) do inspectOrder(child) end
end
inspectOrder(tree)
check(orderedRows == 98 and table.concat(orderedHeaders, ",") == "Group 1,Group 2,Group 3,Group 4,Group 5,Group 6,Group 7",
    "all bindings and seven headers retain source order across columns")
check(keycapBuilds == caps and rowBuilds == rows, "column-count-only change reuses binding presentation")
local completed = tree
searchChanged("obsolete"); onFrameTick()
check(tree == completed and ticks, "unfinished search preserves the previous completed tree")
searchChanged("narrow"); onFrameTick()
searchChanged("shared"); drain()
check(labels(tree):find("98 shown  ·  7 headers", 1, true), "latest rapid query supersedes unfinished searches")
check(reads == sourceReads and tokenBuilds == 98 and descriptionWraps == 98, "search never rereads or reprepares source data")
searchChanged("narrow action"); drain()
check(labels(tree):find("7 shown  ·  7 headers", 1, true), "multiword/category subsets retain matching headers")
alignedRows = {}; findAlignedRows(tree)
for _, row in ipairs(alignedRows) do
    check(row.children[1].props.width == row.children[1].children[1].props.width, "filtered alignment shrinks to the matching shortcuts")
end
searchChanged("no-such-binding"); drain()
check(labels(tree):find("0 shown  ·  0 headers", 1, true), "no-match search drops empty headers")
searchChanged(""); drain()
onClose()
fontCallbacks[1]({exitCode = 0, stdout = "Keyboard Symbols\t2190-2193\n"})
fontCallbacks[2]({exitCode = 0, stdout = "Symbols Nerd Font Mono\tf17a f17c\n"})
check(not ticks, "font completion does not wake a closed panel")
onOpen(); check(ticks, "reopen schedules pending font coverage")
drain()
check(labels(tree):find("←", 1, true), "pending verified glyphs are applied on reopen")
check(tokenBuilds == 196 and searchPreparations == 98 and descriptionWraps == 98, "font change invalidates presentation but retains prepared text")
caps = keycapBuilds
onClose(); outputWidth = 900; onOpen(); drain()
check(keycapBuilds > caps and tokenBuilds == 196, "width change repacks keycaps without reparsing tokens")
check(searchPreparations == 98 and descriptionWraps == 98, "width change retains prepared search and description data")
onClose(); config.icon_style = "text"; onOpen(); drain()
check(tokenBuilds == 294 and not labels(tree):find("←", 1, true), "icon setting changes refresh platform representations")
check(reads == sourceReads, "presentation invalidation never rereads source")
os.clock = function() return elapsed end
searchChanged("no-such-binding"); onFrameTick()
check(not ticks and labels(tree):find("0 shown", 1, true), "inexpensive filtering finishes in one frame without the 24-step limit")
searchChanged(""); onFrameTick()
check(not ticks and labels(tree):find("98 shown", 1, true), "cached all-visible build can complete in one frame")
onClose()
noctalia.runAsync = nil
os.clock = realClock

local previousBarWidget, previousToggle = barWidget, noctalia.togglePanel
local glyph, tooltip, toggled, toggles = nil, nil, nil, 0
barWidget = {
    setGlyph = function(value) glyph = value end,
    setTooltip = function(value) tooltip = value end,
}
noctalia.togglePanel = function(id) toggled = id; toggles = toggles + 1 end
before = reads
assert(loadfile("widget.luau"))()
check(glyph == "keyboard" and tooltip == "Hyprland Keybindings", "bar widget presentation")
check(reads == before and toggles == 0, "loading bar widget does not scan files or open panel")
onClick(); onClick()
check(toggled == "vantesh/hyprbinds:cheatsheet" and toggles == 2, "each bar click toggles the cheatsheet")
barWidget = previousBarWidget
local previousLauncher, results, resultQuery = launcher, nil, nil
launcher = {setResults = function(query, value) resultQuery, results = query, value end}
before = reads
assert(loadfile("launcher.luau"))()
onQuery("")
check(resultQuery == "" and #results == 1 and results[1].id == "open", "empty launcher query offers panel action")
onQuery("shortcuts")
check(resultQuery == "shortcuts" and #results == 1, "launcher filters action keywords")
onQuery("no-such-action")
check(resultQuery == "no-such-action" and #results == 0, "unmatched launcher query clears results")
onActivate("unknown")
check(toggles == 2, "unknown launcher action does not toggle panel")
onActivate("open")
check(toggles == 3 and toggled == "vantesh/hyprbinds:cheatsheet", "launcher action toggles existing cheatsheet")
check(reads == before, "launcher queries and activation never scan configuration")
launcher, noctalia.togglePanel = previousLauncher, previousToggle
require = originalRequire
print("ui: " .. checks .. " checks passed")
