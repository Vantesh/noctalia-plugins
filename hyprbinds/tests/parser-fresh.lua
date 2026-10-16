-- Source fixtures are scanned, never executed.
local parser = assert(loadfile("lib/parser.luau"))()
local checks = 0
local function check(value, name) checks = checks + 1; assert(value, name) end
local function diagnostic(job, code)
    for _, item in ipairs(job.diagnostics) do if item.code == code then return true end end
    return false
end
local function scan(source)
    local job = parser.scan(source, "fixture.lua")
    for _ = 1, 200000 do if job:step(37, 7) then return job end end
    error("scanner stalled")
end
local job = scan([=[
-- === Applications ===
-- hl.bind('COMMENT', secret())
local ignored = "hl.bind('STRING', secret())"
--[[ hl.bind('LONG COMMENT', secret()) ]]
obj.hl.bind('MEMBER', secret())
function hl.bind(a, b) end
hl.bind('SUPER + A', secret({nested(1, 2)}), {desc = 'Alias', description = 'Open browser'})
hl.bind('SUPER' .. suffix, secret(), {description = computed()})
hl.bind("F1", secret(), {desc = "Line\nTwo"})
hl.bind('F2', secret())
]=])
check(#job.events == 4, "ignore comments, strings, member calls and declarations")
local first = job.events[1].binding
check(first.shortcut == "SUPER + A" and first.description == "Open browser", "literal shortcut and description precedence")
check(first.header == "Applications", "category header")
local allowed = {shortcut = true, description = true, header = true, file = true,
    line = true, computed = true, descriptionMissing = true}
for _, event in ipairs(job.events) do
    for key in pairs(event.binding) do check(allowed[key], "only presentation fields are retained") end
end
check(job.events[2].binding.computed and diagnostic(job, "computed-shortcut"), "computed shortcuts are diagnosed")
check(job.events[2].binding.descriptionMissing, "computed descriptions are not evaluated")
check(job.events[3].binding.description == "Line\nTwo", "decode literal escapes")
check(job.events[4].binding.description == "No description", "missing description fallback")
check(diagnostic(scan("hl.bind('F1', nil"), "delimiter"), "incomplete calls are diagnosed")
check(diagnostic(scan("require(variable)"), "computed-import"), "computed imports are not evaluated")

job = scan([====[
hl.bind('BEFORE', nil)
-- Ordinary comment
-- ==== Not a category ====
-- === ===
--[[ === Not a category either === ]]
hl.bind('STILL BEFORE', nil)
-- === Multiline ===
hl.bind(
    [=[SUPER + F1]=],
    opaque({nested = {1, 2}}),
    {['desc'] = 'Alias'; ["description"] = [==[
First line
Second line]==];}
)
-- Subheader
hl.bind('F2', nil, {desc = 'Alias', description = computed()})
hl.bind('F3', nil, {description = '', desc = 'Alias'})
hl.bind('F4', nil, {desc = 'First', desc = 'Last',})
]====])
check(#job.events == 6, "multiline calls and table separators preserve all bindings")
check(job.events[1].binding.header == nil and job.events[2].binding.header == nil, "only exact nonempty line headers create categories")
check(job.events[3].binding.shortcut == "SUPER + F1", "long-bracket shortcut literal")
check(job.events[3].binding.description == "First line\nSecond line", "multiline description skips initial long-string newline")
check(job.events[3].binding.header == "Multiline" and job.events[6].binding.header == "Multiline", "ordinary subheaders do not replace categories")
check(job.events[4].binding.descriptionMissing and job.events[5].binding.descriptionMissing, "computed or empty description overrides desc alias")
check(job.events[6].binding.description == "Last", "last duplicate description field wins")

job = scan([=[hl.bind('F1', nil, {description = '\065\x42\u{2190}\z
  C\\\"\''})]=])
check(job.events[1].binding.description == "AB←C\\\"'", "decimal, hexadecimal, Unicode, whitespace and quote escapes")
for _, escape in ipairs({"\\256", "\\xQ0", "\\u{d800}", "\\u{110000}", "\\q"}) do
    local invalid = scan("hl.bind('F1', nil, {description = '" .. escape .. "'})")
    check(diagnostic(invalid, "string") and invalid.events[1].binding.descriptionMissing, "invalid escape stays unresolved: " .. escape)
end
for _, suffix in ipairs({"", " "}) do
    check(diagnostic(scan(string.rep("x", 129) .. suffix), "identifier-limit"), "oversized identifier is diagnosed at EOF or delimiter")
    check(not diagnostic(scan(string.rep("x", 128) .. suffix), "identifier-limit"), "identifier at limit is accepted at EOF or delimiter")
end

local huge = parser.scan("hl.bind([=[" .. string.rep("x", 10000) .. "]=], nil)\nhl.bind('AFTER', nil)", "large.lua")
for _ = 1, 20000 do
    local previous = huge.pos
    huge:step(13, 2)
    assert(huge.pos - previous <= 13, "scanner byte budget exceeded")
    if huge.done then break end
end
check(huge.done and diagnostic(huge, "literal-limit"), "oversized literals yield and stop retaining text")
check(huge.events[2].binding.shortcut == "AFTER", "scan continues after oversized literal")
check(diagnostic(scan("hl.bind('F1', nil)\n--" .. string.rep("x", 140000)), "file-limit"), "file size is bounded")
check(diagnostic(scan("hl.bind('F1', nil)\n" .. string.rep(";", 40000)), "token-limit"), "token count is bounded")

local function load(files, path)
    local pending, reads = {}, {}
    local result = parser.new({readFileAsync = function(file, callback)
        reads[#reads + 1] = file
        pending[#pending + 1] = {file = file, callback = callback}
    end}, path or "/cfg/main.lua")
    local function drive()
        for _ = 1, 200000 do
            local runnable = result:step()
            if result.done then return end
            if not runnable then
                local item = assert(table.remove(pending, 1), "loader has no pending read")
                local before = #result.bindings
                item.callback(files[item.file], "unreadable")
                assert(#result.bindings == before, "file callback must not parse source")
            end
        end
        error("loader stalled")
    end
    return result, drive, pending, reads
end
local result, drive = load({
    ["/cfg/main.lua"] = "-- === Main ===\nhl.bind('M1', nil)\nrequire 'child'\nrequire 'child'\nrequire 'missing'\nhl.bind('M2', nil)",
    ["/cfg/child.lua"] = "hl.bind('C1', nil)\n-- === Child ===\nhl.bind('C2', nil)\nrequire 'main'",
})
drive()
local order = {}
for _, binding in ipairs(result.bindings) do order[#order + 1] = binding.shortcut end
check(table.concat(order, ",") == "M1,C1,C2,M2", "imports preserve source order and break cycles")
check(result.bindings[2].header == nil and result.bindings[3].header == "Child", "headers are scoped to imported files")
check(result.bindings[4].header == "Main", "parent header survives import")
check(diagnostic(result, "read-failed"), "missing import preserves partial results")
local cancelled, _, pending = load({})
cancelled:step()
cancelled:cancel()
pending[1].callback("hl.bind('LATE', nil)")
check(not cancelled:step() and #cancelled.bindings == 0, "cancelled reads cannot publish bindings")

local files = {}
for i = 0, 20 do files["/cfg/n" .. i .. ".lua"] = "hl.bind('N', nil) require 'n" .. (i + 1) .. "'" end
result, drive = load(files, "/cfg/n0.lua"); drive()
check(diagnostic(result, "depth-limit"), "import depth is bounded")
local imports = {}
files = {}
for i = 1, 70 do
    imports[#imports + 1] = "require 'f" .. i .. "'"
    files["/cfg/f" .. i .. ".lua"] = "hl.bind('F', nil)"
end
files["/cfg/main.lua"] = table.concat(imports, "\n")
result, drive = load(files); drive()
check(result.files == 64 and diagnostic(result, "load-limit"), "loaded file count is bounded")
imports = {}
for i = 1, 100 do imports[#imports + 1] = "require 'missing" .. i .. "'" end
result, drive = load({["/cfg/main.lua"] = table.concat(imports, "\n")}); drive()
check(result.reads == 160 and diagnostic(result, "read-limit"), "missing imports cannot cause unlimited reads")
imports, files = {}, {}
for i = 1, 10 do
    imports[#imports + 1] = "require 'large" .. i .. "'"
    files["/cfg/large" .. i .. ".lua"] = "hl.bind('F', nil)\n--" .. string.rep("x", 131072)
end
files["/cfg/main.lua"] = table.concat(imports, "\n")
result, drive = load(files); drive()
check(result.total == 1048576 and diagnostic(result, "total-limit"), "aggregate source size is bounded")
print("parser-fresh: " .. checks .. " checks passed")
