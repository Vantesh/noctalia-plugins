--!nonstrict
local panelId = "vantesh/hyprbinds:cheatsheet"
local searchText = "Hyprbinds Hyprland keybindings shortcuts cheatsheet"

function onQuery(text)
    local score = text == "" and 0 or noctalia.fuzzyScore(text, searchText)
    local results = {}
    if score then
        results[1] = {id = "open", title = "Open Hyprland Keybindings",
            subtitle = "Browse and search your shortcut cheatsheet", glyph = "keyboard", score = score}
    end
    launcher.setResults(text, results)
end

function onActivate(id)
    if id == "open" then noctalia.togglePanel(panelId) end
end
