--!nonstrict
function onQuery(text)
    local score = text == "" and 0 or noctalia.fuzzyScore(text, "AULA F75 keyboard lighting status")
    launcher.setResults(text, score and {{ id = "open", title = "AULA F75", subtitle = "View wired keyboard lighting status", glyph = "keyboard", score = score }} or {})
end
function onActivate(id) if id == "open" then noctalia.togglePanel("vantesh/aula-f75:panel") end end
