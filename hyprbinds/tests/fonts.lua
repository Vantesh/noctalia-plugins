local fonts = assert(loadfile("lib/fonts.luau"))()
local checks = 0
local function check(value, name) checks = checks + 1; assert(value, name) end
local function empty(entry) return entry.family == nil and next(entry.coverage) == nil end
local function success(output) return {exitCode = 0, stdout = output} end
local unicodeOutput = "Unicode Family\t2190-2193 2318\n"
local nerdOutput = "Symbols Nerd Font Mono\tf17a f17c f040e\n"
local profile = {unicode = fonts.parse(unicodeOutput), nerd = fonts.parse(nerdOutput, true)}
check(profile.unicode.coverage[0x2190] and profile.unicode.coverage[0x2193], "font coverage ranges")
check(fonts.family(profile, "unicode", 0x2318) == "Unicode Family", "covered Unicode symbol")
check(fonts.family(profile, "nerd", 0xf17c) == "Symbols Nerd Font Mono", "covered Linux symbol")
check(fonts.family(profile, "nerd", 0xf028) == nil, "missing glyph is not enabled")
check(empty(fonts.parse("Generic Font\tf17c\n", true)), "reject substituted non-Nerd font")
check(empty(fonts.parse(string.rep("x", 16385))), "reject oversized font output")
check(empty(fonts.parse("invalid output")), "reject malformed font output")
local bounded = fonts.parse("All Nerd Font\t0-10ffff\n", true)
check(bounded.coverage[0xf040e] and not bounded.coverage[0x2318], "font ranges stay within glyph allowlist")

check(fonts.same({}, {unicode = {coverage = {}}, nerd = {coverage = {}}}), "empty probe does not invalidate fallback presentation")
check(fonts.same(profile, {unicode = fonts.parse(unicodeOutput), nerd = fonts.parse(nerdOutput, true)}), "equal font profiles compare by contents")
check(not fonts.same(profile, {unicode = fonts.parse("Other Family\t2190-2193 2318\n"), nerd = profile.nerd}), "font family change invalidates presentation")
check(not fonts.same(profile, {unicode = fonts.parse("Unicode Family\t2190-2193\n"), nerd = profile.nerd}), "coverage loss invalidates presentation")
check(not fonts.same({unicode = fonts.parse("Unicode Family\t2190-2193\n"), nerd = profile.nerd}, profile), "coverage gain invalidates presentation")

local calls, result, completions = {}, nil, 0
fonts.probe({runAsync = function(argv, callback)
    check(type(argv) == "table" and argv[1] == "fc-match", "probe uses direct process arguments")
    calls[#calls + 1] = callback
end}, function(value) result = value; completions = completions + 1 end)
check(#calls == 2 and completions == 0, "probe waits for both commands")
calls[2](success(nerdOutput))
check(completions == 0, "out-of-order completion waits for Unicode query")
calls[1](success(unicodeOutput))
check(completions == 1 and result.nerd.family == "Symbols Nerd Font Mono", "probe returns verified font profile")
calls[1](nil)
check(completions == 1, "duplicate callback cannot complete twice")

for _, failure in ipairs({{exitCode = 1}, {exitCode = 0, stdout = nerdOutput, stdoutTruncated = true},
    {exitCode = 0, stdout = nerdOutput, timedOut = true}}) do
    fonts.probe({runAsync = function(_, callback) callback(failure) end}, function(value)
        check(empty(value.unicode) and empty(value.nerd), "failed probe leaves glyphs disabled")
    end)
end
fonts.probe({runAsync = function() return false end}, function(value)
    check(empty(value.unicode) and empty(value.nerd), "failed process launch stays readable")
end)
print("fonts: " .. checks .. " checks passed")
