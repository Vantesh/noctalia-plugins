--!nonstrict
local fonts = {}

local unicode = {
    0x2318, 0x2190, 0x2191, 0x2192, 0x2193,
}
local nerd = {
    0xf17a, 0xf17c, 0xefba, 0xf028, 0xf027, 0xeee8, 0xf131,
    0xf04c, 0xf051, 0xf048, 0xf04d, 0xf185, 0xf040e,
}
local unicodePattern = ":charset=2318 2325 2303 21e7 21ea 2190 2191 2192 2193 21a9 232b 238b 21e5"
local nerdPattern = "Symbols Nerd Font Mono,Symbols Nerd Font,JetBrainsMono Nerd Font Mono,JetBrainsMono Nerd Font,FiraCode Nerd Font Mono,Hack Nerd Font Mono"
local format = "%{family[0]}\t%{charset}\n"
local maxOutput = 16384

function fonts.parse(output, nerdOnly)
    local entry = {coverage = {}}
    if type(output) ~= "string" or #output > maxOutput then return entry end
    local family, charset = string.match(output, "^([^\t\r\n]+)\t([^\r\n]*)\r?\n?$")
    if not family then return entry end
    family = string.match(family, "^%s*(.-)%s*$")
    if family == "" or string.find(family, "%c") then return entry end
    if nerdOnly and not string.find(family, "Nerd Font", 1, true) then return entry end
    entry.family = family
    local supported = nerdOnly and nerd or unicode
    for token in string.gmatch(charset, "%S+") do
        local first, last = string.match(token, "^(%x+)%-(%x+)$")
        if not first then first = string.match(token, "^%x+$"); last = first end
        if first then
            first, last = tonumber(first, 16), tonumber(last, 16)
            -- Intersect ranges with a finite allowlist; never expand font charsets.
            for _, codepoint in ipairs(supported) do
                if codepoint >= first and codepoint <= last then entry.coverage[codepoint] = true end
            end
        end
    end
    return entry
end

function fonts.family(profile, kind, codepoint)
    if type(profile) ~= "table" or (kind ~= "unicode" and kind ~= "nerd") then return nil end
    local entry = profile[kind]
    if type(entry) == "table" and type(entry.coverage) == "table" and entry.coverage[codepoint] == true then
        return entry.family
    end
    return nil
end

function fonts.same(left, right)
    for _, kind in ipairs({"unicode", "nerd"}) do
        local a, b = left[kind] or {}, right[kind] or {}
        if a.family ~= b.family then return false end
        local ac, bc = a.coverage or {}, b.coverage or {}
        for codepoint, covered in pairs(ac) do if covered ~= bc[codepoint] then return false end end
        for codepoint, covered in pairs(bc) do if covered ~= ac[codepoint] then return false end end
    end
    return true
end

function fonts.probe(host, done)
    local profile = {unicode = {coverage = {}}, nerd = {coverage = {}}}
    if type(host) ~= "table" or type(host.runAsync) ~= "function" then done(profile); return end
    local pending, launching, finished = 2, true, false
    local settled = {}
    local function complete()
        if pending == 0 and not launching and not finished then
            finished = true
            done(profile)
        end
    end
    local function settle(kind, result)
        if settled[kind] then return end
        settled[kind] = true
        if type(result) == "table" and result.exitCode == 0
            and not result.stdoutTruncated and not result.timedOut then
            profile[kind] = fonts.parse(result.stdout, kind == "nerd")
        end
        pending = pending - 1
        complete()
    end
    local function launch(kind, pattern)
        local ok, started = pcall(host.runAsync, {"fc-match", "--format", format, pattern}, function(result)
            settle(kind, result)
        end)
        if not ok or started == false then settle(kind, nil) end
    end
    launch("unicode", unicodePattern)
    launch("nerd", nerdPattern)
    launching = false
    complete()
end

return fonts
