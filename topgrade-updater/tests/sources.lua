-- Run from the repository root: lua topgrade-updater/tests/sources.lua
-- Scope regressions exercise the real service with no external commands.
local core = dofile("topgrade-updater/core.luau")
local function result(stdout, exitCode, stderr)
    return { stdout = stdout or "", stderr = stderr or "", exitCode = exitCode or 0 }
end
local function header(name) return "―― 13:49:31 - " .. name .. " ――\n" end
local unrelated = header("Node Package Manager")
    .. "Dry running: /usr/bin/npm update --location=global\n"
    .. header("GitHub CLI Extensions") .. "Dry running: /usr/bin/gh extension upgrade --all\n"
    .. header("Firmware") .. header("Custom") .. "Dry running: /usr/bin/fish -c 'yazi --update'\n"
    .. header("Flatpak") .. "Dry running: flatpak update\n"
    .. header("Homebrew") .. "Dry running: brew upgrade\n"
    .. header("RubyGems") .. "Dry running: gem update\n"
    .. header("Unsupported") .. "Dry running: other-tool update\n"
    .. header("Custom notification") .. "Dry running: notify-send 'pacman updates'\n"
    .. header("Node packages") .. "Dry running: npm update --global yay\n"
local function serviceResult(plan, replies, discoveryFlags, options)
    options = options or {}
    local latest, queries = nil, {}
    local discovery = result(plan)
    for key, value in pairs(discoveryFlags or {}) do discovery[key] = value end
    local responses = { discovery }
    for _, reply in ipairs(replies or {}) do table.insert(responses, reply) end
    local env = setmetatable({}, { __index = _G })
    env.require = function(path)
        if path == "./core.luau" then return core end
        if path == "./completion.luau" then return {} end
        if path == "./shared.luau" then return { STATE = "state", REQUEST = "request" } end
        error("unexpected module: " .. path)
    end
    env.noctalia = {
        getConfig = function(key) return (options.settings or {})[key] end,
        commandExists = function(name) return not (name == "pacman" and options.missingPacman) end,
        state = { set = function(_, value) latest = value end, watch = function() end },
        setUpdateInterval = function() end,
        formatTime = function() return "13:49" end,
        runAsync = function(args, callback)
            table.insert(queries, table.concat(args, " "))
            if args[4] == "pacman" then
                assert(args[1] == "env" and args[2] == "LC_ALL=C" and args[3] == "NO_COLOR=1"
                    and args[5] == "-Si" and args[6] == "--", "metadata must use fixed argv and option terminator")
                if options.spawnFailure then return false end
                local reply = options.metadata
                if type(reply) == "function" then reply = reply(args) end
                callback(reply or result("", 1))
            else
                callback(assert(table.remove(responses, 1), "unexpected query: " .. queries[#queries]))
            end
            return true
        end,
    }
    assert(loadfile("topgrade-updater/service.luau", "t", env))()
    env.onIpc("check")
    assert(#responses == 0, "expected Arch queries must run")
    return assert(latest, "service must publish a result"), queries
end
local arch = header("System") .. "Dry running: /usr/bin/paru -Syu\n"
local clean, queries = serviceResult(arch .. unrelated .. header("Summary"), { result("", 2), result("") })
assert(core.hidden(clean, true) and clean.complete and #clean.counts == 2 and #clean.unknown == 0,
    "unrelated enabled steps must not block a confirmed zero Pacman/AUR count")
assert(#queries == 3 and queries[2] == "env LC_ALL=C NO_COLOR=1 checkupdates"
    and queries[3] == "env LC_ALL=C NO_COLOR=1 paru -Qua", "only repository and AUR queries may run")
for _, replies in ipairs({
    { result("", 1, "offline"), result("") },
    { result("", 2), result("", 1, "AUR unavailable") },
}) do
    local failed = serviceResult(arch .. unrelated .. header("Summary"), replies)
    assert(failed.total == 0 and failed.phase == "unknown" and not failed.complete and #failed.unknown == 1
        and core.hidden(failed) and not core.hidden(failed, false),
        "failed repository or AUR query hides zero by default while retaining uncertainty and the setting override")
end

local yayPlan = header("System") .. "Dry running: /usr/bin/yay -Syu\n"
    .. header("System update") .. "Dry running: /usr/bin/yay -Pw\n" .. header("Summary")
local yayPending, yayQueries = serviceResult(yayPlan, {
    result("linux 1 -> 2\n"), result("brave-bin 1:1.97.57-1 -> 1:1.97.59-1 [38m]\n"),
})
assert(yayPending.complete and yayPending.total == 2 and #yayPending.unknown == 0
    and yayPending.counts[2].key == "AUR (yay)" and yayPending.counts[2].n == 1
    and yayPending.counts[2].items[1].name == "brave-bin"
    and yayPending.counts[2].items[1].to == "1:1.97.59-1",
    "screenshot age-tagged Brave upgrade must contribute to AUR count and version-only list")
assert(yayQueries[3] == "env LC_ALL=C NO_COLOR=1 yay -Qua", "Yay query must retain NO_COLOR")
local malformed = serviceResult(yayPlan, {
    result("linux 1 -> 2\n"), result("brave-bin 1:1.97.57-1 -> 1:1.97.59-1 [38m]\nbroken output\n"),
})
assert(not malformed.complete and malformed.total == 1 and #malformed.counts == 1
    and not core.hidden(malformed) and #malformed.unknown == 1 and malformed.unknown[1]:find("AUR (yay): unrecognized query output: broken output", 1, true),
    "one valid age-tagged row must not mask malformed AUR output or count partial results")
local yayClean = serviceResult(yayPlan, { result("", 2), result("", 1) })
assert(yayClean.complete and #yayClean.counts == 2 and core.hidden(yayClean, true),
    "yay's silent exit 1 means no AUR upgrades, not a failed check")
for _, reply in ipairs({ result("", 1, "AUR unavailable"), result("unexpected output", 1), { timedOut = true, exitCode = 1 } }) do
    local yayFailed = serviceResult(yayPlan, { result("", 2), reply })
    assert(yayFailed.phase == "unknown" and not yayFailed.complete and #yayFailed.unknown == 1 and core.hidden(yayFailed),
        "yay diagnostics, unexpected output, and timeouts hide zero without becoming clean")
end
local noArch, disabledQueries = serviceResult(unrelated .. header("Summary"))
assert(noArch.complete and noArch.total == 0 and #noArch.counts == 0 and core.hidden(noArch, true)
    and #disabledQueries == 1, "disabled System source must not trigger Arch queries; no relevant sources is scoped zero")
local otherSystem, otherQueries = serviceResult(header("System") .. "Dry running: apt upgrade\n" .. header("Summary"))
assert(core.hidden(otherSystem, true) and #otherQueries == 1, "non-Arch System commands are outside the count scope")
local emptySystem = serviceResult(header("System") .. unrelated .. header("Summary"))
assert(emptySystem.phase == "unknown" and not emptySystem.complete and #emptySystem.unknown > 0
    and core.hidden(emptySystem), "an empty System heading stays uncertain even though zero hides")
for _, text in ipairs({ "", header("Summary"), arch .. unrelated }) do
    local uncertain = serviceResult(text, text == arch .. unrelated and { result("", 2), result("") } or {})
    assert(uncertain.phase == "unknown" and not uncertain.complete and #uncertain.unknown > 0
            and core.hidden(uncertain), "empty or truncated discovery hides zero without becoming clean")
end
for _, flag in ipairs({ "stdoutTruncated", "stderrTruncated" }) do
    local discovery, commands = serviceResult(arch .. header("Summary"), {}, { [flag] = true })
    assert(discovery.phase == "error" and not discovery.complete and #commands == 1
        and discovery.error:find("truncated", 1, true), "truncated discovery cannot establish coverage or start queries")
    local reply = result("linux 1 -> 2\n")
    reply[flag] = true
    local query = serviceResult(header("System") .. "Dry running: pacman -Syu\n" .. header("Summary"), { reply })
    assert(query.phase == "unknown" and not query.complete and query.total == 0 and #query.counts == 0
        and query.unknown[1]:find("truncated", 1, true), "truncated queries cannot become zero or partial complete counts")
end
local metadata = "Repository      : core\nName            : linux\nDownload Size   : 372.50 MiB\nInstalled Size  : 999 MiB"
local sized, sizeQueries = serviceResult(yayPlan, { result("linux 1 -> 2"), result("aur-tool 1 -> 2") }, nil, { metadata = result(metadata) })
assert(sized.downloadBytes == 372.5 * 1024^2 and sized.total == 2 and sized.complete
    and sizeQueries[4] == "env LC_ALL=C NO_COLOR=1 pacman -Si -- linux", "estimate queries repository names only after real counts")
for _, options in ipairs({ { spawnFailure = true }, { missingPacman = true },
    { metadata = result("Name : linux") }, { metadata = { exitCode = 0, stdout = metadata, stdoutTruncated = true } },
    { settings = { show_download_size = false } } }) do
    local s = serviceResult(yayPlan, { result("linux 1 -> 2"), result("aur-tool 1 -> 2") }, nil, options)
    assert(s.downloadBytes == nil and s.total == 2 and s.complete and #s.unknown == 0 and not core.hidden(s),
        "optional metadata failures/disable cannot affect counts, completeness, warnings, or visibility")
end
local rows = {}
for i = 1, 51 do rows[i] = "pkg-" .. i .. " 1 -> 2" end
local function batchMetadata(args)
    local records = {}
    assert(#args <= 56, "metadata argv is capped at 50 targets")
    for i = 7, #args do records[#records + 1] = "Name : " .. args[i] .. "\nDownload Size : 1 MiB" end
    return result(table.concat(records, "\n\n"))
end
local batched, batchQueries = serviceResult(yayPlan, { result(table.concat(rows, "\n")), result("") }, nil,
    { metadata = batchMetadata })
assert(batched.total == 51 and batched.downloadBytes == 51 * 1024^2 and #batchQueries == 5,
    "sum all batches rather than the panel's displayed subset")
local partial = serviceResult(yayPlan, { result(table.concat(rows, "\n")), result("") }, nil,
    { metadata = function(args) return args[7] == "pkg-51" and result("", 1) or batchMetadata(args) end })
assert(partial.downloadBytes == nil and partial.complete and partial.total == 51, "failed later batch cannot publish a partial estimate")
for _, name in ipairs({ "--help", "linux;touch" }) do
    local unsafe, unsafeQueries = serviceResult(yayPlan, { result(name .. " 1 -> 2"), result("") })
    assert(unsafe.total == 1 and unsafe.complete and unsafe.downloadBytes == nil and #unsafeQueries == 3,
        "invalid metadata targets skip optional work, never execute shell syntax or alter real counts")
end
local aurOnly, aurQueries = serviceResult(yayPlan, { result("", 2), result("aur-tool 1 -> 2") })
assert(aurOnly.downloadBytes == nil and #aurQueries == 3, "AUR-only pending updates have no repository estimate")
print("Arch scope regressions passed")
