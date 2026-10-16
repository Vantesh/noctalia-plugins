--!nonstrict

local fonts = require("./fonts.luau")
local icons = {}
local names = {
    CTRL = {"Ctrl"}, CONTROL = {"Ctrl"},
    ALT = {"Alt"}, SHIFT = {"Shift"},
    LEFT = {"Left", "arrow-left"}, RIGHT = {"Right", "arrow-right"},
    UP = {"Up", "arrow-up"}, DOWN = {"Down", "arrow-down"},
    RETURN = {"Enter"}, ENTER = {"Enter"},
    ESCAPE = {"Esc"}, ESC = {"Esc"}, TAB = {"Tab"},
    SPACE = {"Space"}, BACKSPACE = {"Backspace"},
    CAPS = {"Caps Lock"}, CAPS_LOCK = {"Caps Lock"}, CAPSLOCK = {"Caps Lock"},
    PRINT = {"PrintScrn"}, PRINTSCREEN = {"PrintScrn"}, PRINTSCRN = {"PrintScrn"},
    PRINT_SCREEN = {"PrintScrn"}, SYSRQ = {"PrintScrn"},
    XF86SCREENSHOT = {"PrintScrn"},
    DELETE = {"DEL"}, DEL = {"DEL"}, COMMA = {","}, PERIOD = {"."}, SLASH = {"/"},
    BACKSLASH = {"\\"}, SEMICOLON = {";"}, APOSTROPHE = {"'"}, GRAVE = {"`"},
    MINUS = {"-"}, EQUAL = {"="}, PLUS = {"+"}, BRACKETLEFT = {"["}, BRACKETRIGHT = {"]"},
    ["MOUSE:272"] = {"Left click", "mouse"}, ["MOUSE:273"] = {"Right click", "mouse"},
    ["MOUSE:274"] = {"Middle click", "mouse"},
    MOUSE_UP = {"Scroll up", "arrow-up"}, MOUSE_DOWN = {"Scroll down", "arrow-down"},
    MOUSE_LEFT = {"Scroll left", "arrow-left"}, MOUSE_RIGHT = {"Scroll right", "arrow-right"},
    XF86AUDIORAISEVOLUME = {"Volume up", "volume"},
    XF86AUDIOLOWERVOLUME = {"Volume down", "volume-2"}, XF86AUDIOMUTE = {"Mute", "volume-off"},
    XF86AUDIOMICMUTE = {"Mic mute", "microphone-off"},
    XF86MONBRIGHTNESSUP = {"Brightness up", "brightness-up"},
    XF86MONBRIGHTNESSDOWN = {"Brightness down", "brightness-down"},
    XF86AUDIOPLAY = {"Play / pause", "player-play"}, XF86AUDIOPAUSE = {"Pause", "player-pause"},
    XF86AUDIONEXT = {"Next", "player-skip-forward"}, XF86AUDIOPREV = {"Previous", "player-skip-back"},
    XF86AUDIOSTOP = {"Stop", "player-stop"}, XF86POWEROFF = {"Power", "power"},
}

-- Prefer Unicode notation when the selected font covers it.
local notation = {
    LEFT = {"←", 0x2190}, UP = {"↑", 0x2191}, RIGHT = {"→", 0x2192}, DOWN = {"↓", 0x2193},
}
local macModifiers = {
    SUPER = {"⌘", 0x2318, "Command"},
}
-- Nerd Fonts 3 glyph names:
-- https://github.com/ryanoasis/nerd-fonts/blob/master/glyphnames.json
local nerd = {
    WINDOWS = {"", 0xf17a}, LINUX = {"", 0xf17c},
    ["MOUSE:272"] = {"", 0xefba}, ["MOUSE:273"] = {"", 0xefba}, ["MOUSE:274"] = {"", 0xefba},
    XF86AUDIORAISEVOLUME = {"", 0xf028}, XF86AUDIOLOWERVOLUME = {"", 0xf027},
    XF86AUDIOMUTE = {"", 0xeee8}, XF86AUDIOMICMUTE = {"", 0xf131},
    XF86MONBRIGHTNESSUP = {"", 0xf185, "+"}, XF86MONBRIGHTNESSDOWN = {"", 0xf185, "-"},
    XF86AUDIOPLAY = {"󰐎", 0xf040e}, XF86AUDIOPAUSE = {"", 0xf04c},
    XF86AUDIONEXT = {"", 0xf051}, XF86AUDIOPREV = {"", 0xf048}, XF86AUDIOSTOP = {"", 0xf04d},
}

local function symbol(token, entry, profile, kind)
    local family = entry and fonts.family(profile, kind, entry[2])
    if not family then return false end
    token.symbol, token.fontFamily, token.glyph = entry[1], family, nil
    return true
end

function icons.tokens(shortcut, style, iconStyle, profile)
    local result = {}
    -- A literal '+' key is represented by an empty final component in SUPER + +.
    for part in string.gmatch(shortcut .. "+", "(.-)%+") do
        local raw = string.match(part, "^%s*(.-)%s*$")
        if raw ~= "" then
            local upper = string.upper(raw)
            local item = names[upper]
            local super = upper == "SUPER" or upper == "META" or upper == "MOD4"
            local mac = style == "apple" or style == "macos"
            if super then
                upper = "SUPER"
                item = {mac and "Command" or style == "linux" and "Linux" or "Super",
                    style == "windows" and "brand-windows" or nil}
            end
            local token = {text = item and item[1] or raw, glyph = item and item[2]}
            local textOnly = iconStyle == "text" or style == "text"
            if textOnly then
                token.glyph = nil
                if super then token.text = "Super" end
            else
                local entry = mac and macModifiers[upper] or notation[upper]
                if mac and macModifiers[upper] then
                    token.text, token.glyph = macModifiers[upper][3], nil
                end
                local mapped = symbol(token, entry, profile, "unicode")
                if not mapped and super and not mac then
                    symbol(token, nerd[string.upper(style or "")], profile, "nerd")
                elseif not mapped and iconStyle == "nerd" then
                    if symbol(token, nerd[upper], profile, "nerd") then token.label = nerd[upper][3] end
                end
                local button = string.match(token.text, "^(%a+) click$")
                local wheel = string.sub(token.text, 1, 7) == "Scroll "
                token.label = button or (wheel and "Scroll" or token.label)
            end
            result[#result + 1] = token
        end
    end
    if string.match(shortcut, "%+%s*$") then result[#result + 1] = {text = "+"} end
    if #result == 0 then result[1] = {text = "Unknown shortcut"} end
    return result
end

function icons.prepareSearch(binding)
    return {shortcut = string.lower(binding.shortcut), description = string.lower(binding.description),
        header = string.lower(binding.header or "")}
end

function icons.matchesPrepared(prepared, query)
    return query == "" or string.find(prepared.shortcut, query, 1, true) ~= nil
        or noctalia.fuzzyScore(query, prepared.description) ~= nil
        or string.find(prepared.header, query, 1, true) ~= nil
end


-- Insert soft break opportunities, preserving UTF-8. Also neutralize controls
-- so a source string cannot introduce invisible layout instructions.
function icons.wrapText(text)
    local out, count = {}, 0
    for sourceChar in string.gmatch(text, "[%z\1-\127\194-\244][\128-\191]*") do
        local char = sourceChar
        local byte = string.byte(char)
        if byte < 32 or byte == 127 then char = " " end
        out[#out + 1] = char
        if char == " " then count = 0 else count = count + 1 end
        if count >= 12 then out[#out + 1] = "\226\128\139"; count = 0 end
    end
    return table.concat(out)
end
return icons
