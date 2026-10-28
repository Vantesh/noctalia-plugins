-- Run from the repository root: lua topgrade-updater/tests/completion.lua
-- Host mocks never execute Topgrade; shell tests execute only harmless sh fixtures.
local core = dofile("topgrade-updater/core.luau")
local env = setmetatable({ require = function() return core end }, { __index = _G })
local completion = assert(loadfile("topgrade-updater/completion.luau", "t", env))()
local plan = "―― 12:00:00 - System ――\nDry running: pacman -Syu\n―― 12:00:00 - Summary ――\n"
local function result(text, code) return { stdout = text or "", stderr = "", exitCode = code or 0 } end
local testLock = os.tmpname()
local rawCommand = completion.command
completion.command = function(receipt, argv, lock) return rawCommand(receipt, argv, lock or testLock) end
local function harness(options)
    options = options or {}
    local latest, terminal, removed, reads, now = nil, nil, {}, {}, 0
    local pending, queries, detached, lockChecks = {}, {}, {}, {}
    local requestWatcher, nonce
    local env = setmetatable({}, { __index = _G })
    env.require = function(path)
        if path == "./core.luau" then return core end
        if path == "./completion.luau" then return completion end
        if path == "./shared.luau" then return { STATE = "state", REQUEST = "request" } end
        error(path)
    end
    env.noctalia = {
        getConfig = function(key) return (options.settings or {})[key] end,
        expandPath = function(path) return path end,
        commandExists = function(name) return name ~= options.missing end,
        state = { set = function(_, value) latest = value end, watch = function(_, callback) requestWatcher = callback end },
        setUpdateInterval = function() end,
        formatTime = function() return "12:00" end,
        nowMs = function() return now end,
        runAsync = function(args, callback, timeout)
            if not callback then
                assert(timeout == nil, "terminal launches must use the detached overload without a timeout")
                table.insert(detached, args)
                return not options.launchFailure
            end
            if args[1] == "sh" and args[3] == completion.runtimeScript then
                if options.delayRuntime then options.runtimeCallback = callback; return true end
                callback(options.runtimeResult or result(testLock))
                return true
            end
            if args[1] == "flock" then
                assert(timeout == 5000, "lock probe must have a bounded timeout")
                table.insert(lockChecks, args)
                if options.lockSpawnFailure then return false end
                if options.delayLock then options.lockCallback = callback; return true end
                if options.realLock then
                    local parts = {}
                    for _, arg in ipairs(args) do parts[#parts + 1] = core.quote(arg) end
                    local ok, _, code = os.execute(table.concat(parts, " "))
                    callback(result("", ok and 0 or code))
                else
                    callback(options.lockResult or result())
                end
                return true
            end
            if args[1] == "mktemp" and options.spawnFailure then
                options.allocationCallback = callback
                return false
            end
            table.insert(queries, args)
            table.insert(pending, callback)
            return true
        end,
        runInTerminal = function(command) terminal = command; return not options.launchFailure end,
        readFile = function(path) return reads[path] end,
        removeFile = function(path) removed[path] = true; reads[path] = nil; return true end,
    }
    assert(loadfile("topgrade-updater/service.luau", "t", env))()
    local h = { path = "/tmp/noctalia-topgrade.fixture" .. testLock:match("[%w]+$"), queries = queries, detached = detached, removed = removed, reads = reads, lockChecks = lockChecks }
    function h.state() return latest end
    function h.request(action) env.onIpc(action) end
    function h.sharedRequest(action)
        nonce = (nonce or 0) + 1
        requestWatcher({ action = action, nonce = nonce })
    end
    function h.assertBlocked()
        assert(latest.updateBlocked, "unresolved runs must retain an independent safety interlock")
        local count = #queries
        h.request("update")
        h.sharedRequest("update")
        assert(#queries == count, "neither IPC nor UI requests may bypass the interlock")
    end
    function h.reply(value)
        local callback = assert(table.remove(pending, 1), "expected pending command")
        callback(value)
        return callback
    end
    function h.tick(ms) now = now + (ms or 1000); env.update() end
    function h.configure(key, value)
        options.settings = options.settings or {}
        options.settings[key] = value
        env.onConfigChanged()
    end
    function h.launch()
        h.request("update")
        h.reply(result(h.path))
        return terminal
    end
    function h.refresh()
        local discovery = queries[#queries]
        assert(table.concat(discovery, " "):find("--dry-run --no-self-update", 1, true),
            "refresh must actually launch discovery, not just reset state")
        h.reply(result(plan))
        assert(table.concat(queries[#queries], " ") == "env LC_ALL=C NO_COLOR=1 checkupdates",
            "refresh must actually launch the package query")
        h.reply(result("", 2))
        assert(latest.phase == "clean" and not latest.updateError and core.hidden(latest, true),
            "fresh verified zero counts replace the last run's error and permit hiding")
        local count = #queries
        h.tick()
        assert(#queries == count, "completion refresh must not loop or rerun upgrades")
    end
    return h
end

do
    local h = harness()
    h.launch()
    local running = h.state()
    h.configure("auto_check_hours", 0)
    h.configure("topgrade_config", "/tmp/new config.toml")
    assert(h.state() == running and h.state().phase == "running" and #h.queries == 1,
        "settings callbacks must preserve the active run and receipt without launching another command")
    h.reads[h.path] = "done 7\n"
    h.tick()
    assert(h.removed[h.path] and h.state().updateError:find("exit 7", 1, true)
        and h.queries[2][6] == "/tmp/new config.toml",
        "completion tracking survives settings changes and refresh uses the latest configuration")
    h.refresh()
end

do
    local h = harness()
    h.request("check")
    h.configure("topgrade_config", "/tmp/new config.toml")
    assert(#h.queries == 2 and h.queries[2][6] == "/tmp/new config.toml",
        "a configuration callback replaces an in-flight check immediately")
    h.reply(result(plan))
    assert(h.state().phase == "checking" and #h.queries == 2,
        "the superseded discovery cannot publish results or launch queries")
    h.refresh()
end

-- Noctalia v5.3.0's native process runner trims trailing CR/LF before the
-- runAsync callback. Allocate a real receipt, but keep ALL launch APIs mocked.
local allocator = assert(io.popen("mktemp /tmp/noctalia-topgrade.XXXXXXXXXX", "r"))
local rawPath = allocator:read("*a")
assert(allocator:close())
local allocatedPath = rawPath:gsub("[\r\n]+$", "")
local allocated = assert(io.open(allocatedPath, "r")); allocated:close()
assert(os.remove(allocatedPath))
for _, fixture in ipairs({ { allocatedPath, "" }, { rawPath, 'xdg-terminal-exec --title="System Update"' } }) do
    local h = harness({ settings = { terminal_cmd = fixture[2] } })
    h.request("update")
    h.reply(result(fixture[1]))
    assert(h.state().phase == "running" and not h.state().updateError,
        "successful mktemp output, including native-trimmed stdout, must reach terminal launch")
    assert(#h.queries == 1, "receipt allocation must not trigger a failure refresh")
    assert((#h.detached == 1) == (fixture[2] ~= ""))
    h.reads[allocatedPath] = "done 7\n"
    h.tick()
    assert(h.removed[allocatedPath] and h.state().updateError:find("exit 7", 1, true),
        "native-trimmed allocation must retain exact exit receipt tracking and cleanup")
end

-- Runtime and receipt allocation callbacks may only advance their launch once.
local duplicateOptions = { delayRuntime = true, settings = { terminal_cmd = "fake-terminal" } }
local duplicate = harness(duplicateOptions)
duplicate.request("update")
local runtimeCallback = duplicateOptions.runtimeCallback
runtimeCallback(result(testLock))
runtimeCallback(result(testLock))
assert(#duplicate.queries == 1, "duplicate runtime callback must not allocate a second receipt")
local allocationCallback = duplicate.reply(result(duplicate.path))
allocationCallback(result(duplicate.path))
assert(#duplicate.detached == 1, "duplicate allocation callback must not launch a second terminal")
duplicate.reads[duplicate.path] = "done 0\n"
duplicate.tick(); duplicate.refresh()
duplicate.request("update")
local queryCount = #duplicate.queries
runtimeCallback(result(testLock)); allocationCallback(result(duplicate.path))
assert(#duplicate.queries == queryCount and #duplicate.detached == 1,
    "stale launch callbacks cannot allocate or launch for a subsequent run")

do
    local h = harness({ settings = { terminal_cmd = " \t\n " } })
    assert(h.launch() == completion.command(h.path, { "sh", "-c", "topgrade -k --no-self-update --notify-end never" }))
    assert(#h.detached == 0, "empty terminal prefix must preserve native detection")
end

-- A real fake terminal records argv, then executes the supervised harmless update.
local directory = os.tmpname()
os.remove(directory)
assert(os.execute("mkdir -m 700 " .. core.quote(directory)))
local terminalOutput, updateOutput = directory .. "/argv", directory .. "/updated"
local fixture = assert(io.open(directory .. "/xdg-terminal-exec", "w"))
fixture:write('#!/bin/sh\nprintf "%s\\n" "$#" "$@" > ' .. core.quote(terminalOutput)
    .. '\nshift\nexec "$@"\n')
fixture:close()
assert(os.execute("chmod 700 " .. core.quote(directory .. "/xdg-terminal-exec")))
do
    local code = 7
    local h = harness({ settings = {
        terminal_cmd = 'xdg-terminal-exec --title="System Update"',
        update_cmd = 'printf "%s" "update reached terminal" > ' .. core.quote(updateOutput) .. '; exit ' .. code,
    } })
    h.path = "/tmp/noctalia-topgrade.fixture" .. directory:match("[%w]+$")
    local gate = assert(io.open(h.path, "w")); gate:close()
    assert(h.launch() == nil and #h.detached == 1, "custom terminal must bypass native detection")
    local args = h.detached[1]
    assert(#args == 3 and args[1] == "sh" and args[2] == "-c")
    local parts = {}
    for _, arg in ipairs(args) do table.insert(parts, core.quote(arg)) end
    local ok = os.execute("PATH=" .. core.quote(directory) .. ':"$PATH" ' .. table.concat(parts, " "))
    assert((ok == true) == (code == 0), "supervised exit must survive the custom launcher")
    local file = assert(io.open(terminalOutput))
    assert(file:read("*a") == "4\n--title=System Update\nsh\n-c\n"
        .. completion.command(h.path, { "sh", "-c",
            'printf "%s" "update reached terminal" > ' .. core.quote(updateOutput) .. '; exit ' .. code }) .. "\n",
        "title must be one argv token and supervised command one intact sh -c argument")
    file:close()
    file = assert(io.open(updateOutput)); assert(file:read("*a") == "update reached terminal"); file:close()
    file = assert(io.open(h.path)); h.reads[h.path] = file:read("*a"); file:close()
    h.tick(); h.refresh()

    os.remove(h.path)
end
for _, name in ipairs({ "xdg-terminal-exec", "argv", "updated" }) do os.remove(directory .. "/" .. name) end
assert(os.execute("rmdir " .. core.quote(directory)))


-- Run the service-produced override through the real supervisor, not Topgrade.
local overrideReceipt, overrideOutput = os.tmpname(), os.tmpname()
local config = "/tmp/config with 'quote; $(not-a-command).toml"
local custom = "sh -c " .. core.quote('printf "%s\\n" "$@" > ' .. core.quote(overrideOutput) .. '; exit 7') .. " fixture"
local override = harness({ settings = { update_cmd = custom, topgrade_config = config } })
-- Keep the production mktemp path shape and pre-create the supervisor's gate.
override.path = "/tmp/noctalia-topgrade.override" .. overrideReceipt:match("[%w]+$")
local gate = assert(io.open(override.path, "w")); gate:close()
local launch = override.launch()
assert(launch == completion.command(override.path,
    { "sh", "-c", custom .. " --config " .. core.quote(config) }), "override is passed intact with a literal config argument")
assert(not os.execute(launch), "nonzero override must not become successful")
local file = assert(io.open(overrideOutput))
assert(file:read("*a") == "--config\n" .. config .. "\n", "configuration metacharacters must remain literal through both shells")
file:close()
file = assert(io.open(override.path))
override.reads[override.path] = file:read("*a"); file:close()
override.tick()
assert(override.state().updateError:find("exit 7", 1, true), "override exit code must remain visible")
assert(table.concat(override.queries[2], " ") ==
    "env LC_ALL=C NO_COLOR=1 topgrade --config " .. config .. " --dry-run --no-self-update",
    "post-update discovery must not execute the override")
os.remove(override.path); os.remove(overrideReceipt); os.remove(overrideOutput)

local remaining = harness()
remaining.launch()
remaining.reads[remaining.path] = "done 1\n"
remaining.tick()
remaining.reply(result(plan))
remaining.reply(result("linux 1 -> 2\nother 3 -> 4\n"))
assert(remaining.state().total == 2 and #remaining.state().counts[1].items == 2
    and remaining.state().phase == "ready" and not remaining.state().updateError,
    "failed update must settle to ready with freshly queried pending packages")
assert(not core.hidden(remaining.state(), true), "remaining updates must keep the widget visible")

local unknown = harness()
unknown.launch()
unknown.reads[unknown.path] = "done 1\n"
unknown.tick()
unknown.reply(result(plan))
unknown.reply(result("", 1))
assert(unknown.state().phase == "unknown" and not unknown.state().updateError and #unknown.state().unknown > 0
    and not unknown.state().complete and core.hidden(unknown.state(), true),
        "query failure hides zero but preserves fresh uncertainty, not the last update error")

local failedCheck = harness()
failedCheck.launch()
failedCheck.reads[failedCheck.path] = "done 143\n"
failedCheck.tick()
failedCheck.reply({ exitCode = 1, stderr = "offline" })
assert(failedCheck.state().phase == "error" and failedCheck.state().error:find("offline", 1, true)
    and not failedCheck.state().updateError and not failedCheck.state().complete and core.hidden(failedCheck.state(), true),
    "genuine discovery failure hides zero but retains actionable error metadata after an interrupted update")
local queryCount = #failedCheck.queries
failedCheck.tick(31000)
assert(#failedCheck.queries == queryCount, "failed automatic recheck must not immediately retry")
failedCheck.request("check")
failedCheck.refresh()

for _, output in ipairs({ "", "/unexpected/path\n", "/tmp/noctalia-topgrade.valid\nextra",
    "/tmp/noctalia-topgrade.valid;echo bad", "/tmp/noctalia-topgrade.valid/../other" }) do
    local h = harness({ settings = { terminal_cmd = 'xdg-terminal-exec --title="System Update"' } })
    h.request("update")
    h.reply(result(output))
    assert(h.state().phase == "checking" and not h.state().updateBlocked and h.state().updateError:find("invalid receipt path output", 1, true)
        and #h.detached == 0, "invalid receipt allocation fails safely before terminal launch")
end
for _, allocation in ipairs({
    { stdout = "", exitCode = 1, stderr = "mktemp: Permission denied" },
    { stdout = "/tmp/noctalia-topgrade.valid", exitCode = 0, timedOut = true },
    { stdout = "/tmp/noctalia-topgrade.valid", exitCode = 0, stdoutTruncated = true },
    { stdout = "/tmp/noctalia-topgrade.valid", exitCode = 1 },
}) do
    local h = harness({ settings = { terminal_cmd = "fake-terminal" } })
    h.request("update")
    h.reply(allocation)
    local message = h.state().updateError or ""
    assert(h.state().phase == "checking" and not h.state().updateBlocked and #h.detached == 0, "failed allocation cannot launch or block an update")
    local reason = allocation.timedOut and "timeout" or (allocation.stdoutTruncated and "truncated stdout" or "exit 1")
    assert(message:find(reason, 1, true), "allocation failures include actionable native result details")
    if allocation.stderr then assert(message:find(allocation.stderr, 1, true)) end
    if allocation.stdout ~= "" then assert(h.removed[allocation.stdout], "failed allocation cleans a known receipt") end
end

-- Execute the production shell wrapper with fake commands, never Topgrade.
for _, fixture in ipairs({ { "exit 0", 0 }, { "exit 7", 7 }, { "exit 75", 75 }, { 'kill -HUP "$PPID"; exit 0', 129 },
    { 'kill -TERM "$PPID"; exit 0', 143 }, { 'kill -INT "$PPID"; exit 0', 130 } }) do
    local receipt = os.tmpname()
    os.execute(completion.command(receipt, { "sh", "-c", fixture[1] }) .. " >/dev/null 2>&1")
    local file = assert(io.open(receipt))
    local kind, code = completion.receipt(file:read("*a"))
    file:close()
    os.remove(receipt)
    assert(kind == (fixture[2] >= 128 and "interrupted" or "done") and code == fixture[2],
        "wrapper must distinguish actual exit from supervisor interruption: " .. fixture[1])
end
-- The child ignores TERM, observes the receipt while still alive, then exits.
-- Reading the pipe to EOF also waits for the child if a broken supervisor exits early.
local waitingReceipt = os.tmpname()
local stubborn = 'trap "" TERM; kill -TERM "$PPID"; sleep 0.2; IFS= read -r status < '
    .. core.quote(waitingReceipt) .. '; case "$status" in running) printf "still running\\n";; esac'
local pipe = assert(io.popen(completion.command(waitingReceipt, { "sh", "-c", stubborn }), "r"))
local observed = pipe:read("*a")
pipe:close()
local waited = assert(io.open(waitingReceipt))
local kind, code = completion.receipt(waited:read("*a"))
waited:close(); os.remove(waitingReceipt)
assert(observed == "still running\n", "interruption must not publish completion while the immediate child is alive")
assert(kind == "interrupted" and code == 143, "interrupted receipt is written only after confirmed child exit")

-- A delayed terminal must not start after the launch deadline removed its gate.
local missing = os.tmpname()
os.remove(missing)
local success = os.execute(completion.command(missing, { "sh", "-c", "exit 0" }))
assert(not success and not io.open(missing), "expired launch gate prevents a late update")
local cancelled = os.tmpname()
assert(os.execute("flock -n -E 75 " .. core.quote(testLock) .. " sh -c "
    .. core.quote(completion.revokeScript) .. " topgrade-updater " .. core.quote(cancelled)))
assert(not os.execute(completion.command(cancelled, { "sh", "-c", "exit 0" })),
    "atomically revoked gate must prevent a delayed terminal from starting")
os.remove(cancelled)


-- An explicit retry reconciles a cancelled terminal without opening the panel.
for _, receipt in ipairs({ "interrupted 130\n", "" }) do
    local h = harness({ settings = { terminal_cmd = "fake-terminal" } })
    h.launch()
    h.reads[h.path] = receipt
    h.request("update")
    h.reply(result(h.path .. "retry"))
    assert(h.removed[h.path] and h.state().phase == "running" and #h.detached == 2,
        "retry must revoke the old gate and launch a replacement terminal")
end

local refreshRetry = harness({ settings = { terminal_cmd = "fake-terminal" } })
refreshRetry.launch()
refreshRetry.reads[refreshRetry.path] = "interrupted 130\n"
refreshRetry.tick()
refreshRetry.request("update")
refreshRetry.reply(result(plan))
refreshRetry.reply(result(refreshRetry.path .. "retry"))
assert(refreshRetry.state().phase == "running" and #refreshRetry.detached == 2,
    "retry must supersede the completion refresh and ignore its late callback")

local probingOptions = { delayLock = true, settings = { terminal_cmd = "fake-terminal" } }
local probingRetry = harness(probingOptions)
probingRetry.launch(); probingRetry.reads[probingRetry.path] = "interrupted 130\n"; probingRetry.tick()
probingRetry.request("update")
probingOptions.lockCallback(result())
assert(#probingRetry.lockChecks == 2 and probingRetry.lockChecks[2][8] == completion.revokeScript,
    "retry during a periodic probe must revoke the gate under a fresh lock before replacing")
probingOptions.lockCallback(result())
probingRetry.reply(result(probingRetry.path .. "retry"))
assert(#probingRetry.detached == 2, "an in-flight periodic probe must not lose an explicit retry")

local invalidRetry = harness({ settings = { update_cmd = "" } })
invalidRetry.request("refresh"); invalidRetry.request("update"); invalidRetry.reply(result(plan))
assert(invalidRetry.state().phase == "error" and invalidRetry.state().error == "Update command is empty",
    "superseded refresh callbacks cannot hide failed update validation")

-- A command's exit 75 is not a lock conflict. Every outcome refreshes counts.
for _, code in ipairs({ 0, 75 }) do
    local options = { lockResult = result("", 75), settings = { terminal_cmd = "fake-terminal" } }
    local h = harness(options)
    h.launch()
    h.reads[h.path] = "running\n"
    h.request("update"); h.request("check")
    assert(#h.queries == 1, "active update excludes overlapping requests")
    options.lockResult = result()
    h.reads[h.path] = "done " .. code .. "\n"
    h.tick(5000)
    assert(h.state().phase == "checking")
    if code ~= 0 then
        assert(h.state().updateError:find("exit " .. code, 1, true))
        assert(not h.state().updateError:find("already running", 1, true))
    end
    h.refresh()
    assert(#h.detached == 1, "requests rejected by a held lock must not queue another upgrade")
end
local opts = { lockResult = result("", 75) }
local blocked = harness(opts)
blocked.launch()
blocked.reads[blocked.path] = "conflict 75\n"
blocked.tick()
assert(blocked.state().updateError:find("no update was started", 1, true))
blocked.assertBlocked()
for _ = 1, 4 do blocked.tick() end
assert(#blocked.lockChecks == 1, "lock probes run at most every five seconds")
-- A rejected attempt owns no completion: neither manual nor automatic recovery
-- may query counts while the real update continues, or synthesize its refresh.
local rejectedQueries = #blocked.queries
blocked.request("refresh"); blocked.tick(3600000); blocked.assertBlocked()
assert(#blocked.queries == rejectedQueries, "rejection cannot refresh counts while the active lock is held")
opts.lockResult = result()
blocked.tick(5000)
assert(not blocked.state().updateBlocked and #blocked.queries == rejectedQueries,
    "rejection recovery unblocks without claiming or refreshing another run's completion")
blocked.request("refresh"); blocked.refresh()

local lostOpts = { lockResult = result("", 75) }
local lost = harness(lostOpts)
lost.launch(); lost.reads[lost.path] = "running\n"; lost.tick()
lost.reads[lost.path] = "damaged receipt"
lost.tick(120000)
assert(lost.state().phase == "running", "a held lock has no update duration limit even without a receipt")
lostOpts.lockResult = result()
lost.tick(5000); lost.tick(5000)
assert(lost.state().updateError:find("unknown", 1, true))
lost.refresh()

local launchTimeout = harness()
launchTimeout.launch(); launchTimeout.tick(30000); launchTimeout.tick(5000)
assert(launchTimeout.removed[launchTimeout.path], "expired launch gate is removed")
local revoked = false
for _, args in ipairs(launchTimeout.lockChecks) do
    if args[8] == completion.revokeScript and args[10] == launchTimeout.path then revoked = true end
end
assert(revoked, "automatic expiry must revoke the old gate under lock before relinquishing ownership")
launchTimeout.refresh()

local brokenOpts = { lockResult = { exitCode = 2, stderr = "denied" } }
local broken = harness(brokenOpts)
broken.launch(); broken.reads[broken.path] = "done 0\n"; broken.tick()
broken.assertBlocked()
assert(broken.state().updateBlocked:find("Cannot check", 1, true))
brokenOpts.lockResult = result(); broken.tick(5000); broken.refresh()
local delayedOpts = { delayLock = true }
local delayed = harness(delayedOpts)
delayed.launch(); delayed.reads[delayed.path] = "done 0\n"; delayed.tick()
for _ = 1, 20 do delayed.tick() end
assert(#delayed.lockChecks == 1, "only one completion probe may be in flight")
local staleCallback = delayedOpts.lockCallback
delayedOpts.lockCallback(result()); delayed.refresh()
delayed.launch()
local newQueries = #delayed.queries
staleCallback(result())
assert(delayed.state().phase == "running" and #delayed.queries == newQueries,
    "duplicate old probe cannot complete or refresh a subsequent run")

local spawnOptions = { spawnFailure = true }
local spawnFailed = harness(spawnOptions)
spawnFailed.request("update")
local queriesAfterFailure = #spawnFailed.queries
spawnOptions.allocationCallback(result(spawnFailed.path))
assert(spawnFailed.state().phase == "checking" and #spawnFailed.queries == queriesAfterFailure,
    "late allocation callback after failed spawn cannot launch or finalize again")
spawnFailed.refresh()

for _, terminal in ipairs({ "", "fake-terminal" }) do
    local failedLaunch = harness({ launchFailure = true, settings = { terminal_cmd = terminal } })
    failedLaunch.launch()
    assert(failedLaunch.removed[failedLaunch.path] and failedLaunch.state().updateError == "Could not launch a terminal",
        "failed native or detached terminal launch cleans only its receipt and refreshes")
    failedLaunch.refresh()
end

local failedProbeOptions = { lockSpawnFailure = true }
local failedProbe = harness(failedProbeOptions)
failedProbe.launch(); failedProbe.reads[failedProbe.path] = "done 0\n"; failedProbe.tick()
failedProbe.assertBlocked()
failedProbeOptions.lockSpawnFailure = false
failedProbe.tick(5000); failedProbe.refresh()

local missingFlock = harness({ missing = "flock" })
missingFlock.request("update")
assert(missingFlock.state().error:find("flock", 1, true) and #missingFlock.queries == 0)
local missingRuntime = harness({ runtimeResult = { exitCode = 125, stderr = "Set XDG_RUNTIME_DIR" } })
missingRuntime.request("update")
assert(missingRuntime.state().updateError:find("XDG_RUNTIME_DIR", 1, true) and #missingRuntime.detached == 0)
missingRuntime.refresh()

-- Validate the exact environment query without touching real runtime directories.
local runtime = os.tmpname(); os.remove(runtime)
assert(os.execute("mkdir -m 700 " .. core.quote(runtime)))
local function runtimeProbe(value)
    local pipe = assert(io.popen("XDG_RUNTIME_DIR=" .. core.quote(value) .. " sh -c " .. core.quote(completion.runtimeScript) .. " 2>/dev/null"))
    local text = pipe:read("*a"); local ok = pipe:close()
    return ok, text
end
local ok, path = runtimeProbe(runtime)
assert(ok and path == runtime .. "/noctalia-topgrade.lock")
for _, path in ipairs({ "", "relative", runtime .. "/missing" }) do assert(not runtimeProbe(path)) end
assert(os.execute("chmod 755 " .. core.quote(runtime)))
assert(not runtimeProbe(runtime), "shared runtime directory must be rejected")
assert(os.execute("chmod 700 " .. core.quote(runtime)))

-- Real concurrent flock fixture: a second supervisor must not execute its command.
-- The first command invokes the second while still holding FD 9 (no timing sleeps).
local first, second, marker = os.tmpname(), os.tmpname(), os.tmpname()
os.remove(marker)
local contender = completion.command(second, { "sh", "-c", "printf unsafe > " .. core.quote(marker) })
local firstCommand = contender .. '; code=$?; [ "$code" = 75 ]'
assert(os.execute(completion.command(first, { "sh", "-c", firstCommand })))
local file = assert(io.open(second)); local kind, code = completion.receipt(file:read("*a")); file:close()
assert(kind == "conflict" and code == 75 and not io.open(marker), "contender reports conflict and never executes")
assert(os.execute(completion.command(second, { "sh", "-c", "exit 75" })) == nil)
file = assert(io.open(second)); kind, code = completion.receipt(file:read("*a")); file:close()
assert(kind == "done" and code == 75, "command exit 75 remains an actual command result")
assert(os.execute(completion.command(second, { "sh", "-c", "printf safe > " .. core.quote(marker) })))
file = assert(io.open(marker)); assert(file:read("*a") == "safe"); file:close()
-- SIGKILL cannot run the supervisor's traps. Its surviving child still holds
-- FD 9, so a new supervisor must remain excluded without any PID inspection.
os.remove(marker)
local survivor = 'kill -KILL "$PPID"; ' .. contender .. '; code=$?; [ "$code" = 75 ] && printf held'
local survivorPipe = assert(io.popen(completion.command(first, { "sh", "-c", survivor }) .. " 2>/dev/null"))
assert(survivorPipe:read("*a") == "held", "descendant retains lock after supervisor death")
survivorPipe:close()
assert(not io.open(marker), "surviving descendant's contender never executes")
assert(os.execute("flock -n -E 75 " .. core.quote(testLock) .. " sh -c ':'"), "kernel releases lock after last descendant exits")
-- A normal shell may exit while a background descendant still holds FD 9.
-- Exercise real receipts and real lock probes through the production service.
for _, interrupted in ipairs({ false, true }) do
    local gatePath = runtime .. "/release"
    assert(os.execute("mkfifo -m 600 " .. core.quote(gatePath)))
    local h = harness({ realLock = true })
    h.launch()
    local receiptFile = assert(io.open(h.path, "w")); receiptFile:close()
    local background = '( while ! grep -q "' .. (interrupted and "interrupted" or "done")
        .. ' " ' .. core.quote(h.path) .. '; do sleep 0.01; done; printf "ready\\n"; read -r release < '
        .. core.quote(gatePath) .. ' ) & '
        .. (interrupted and 'kill -TERM "$PPID"; exit 0' or 'exit 0')
    local childPipe = assert(io.popen(completion.command(h.path, { "sh", "-c", background }), "r"))
    assert(childPipe:read("*l") == "ready", "descendant observes parent's exact completion receipt")
    receiptFile = assert(io.open(h.path)); h.reads[h.path] = receiptFile:read("*a"); receiptFile:close()
    h.tick()
    local queries = #h.queries
    assert(h.state().phase == "running" and not h.removed[h.path],
        "done/interrupted receipt retains run ownership while descendant holds lock")
    h.request("refresh"); h.request("update"); h.sharedRequest("update"); h.tick(5000)
    assert(#h.queries == queries, "no early refresh or replacement launch while child lives")
    local rejected = harness({ realLock = true })
    rejected.path = h.path .. "rejected"
    local rejectedFile = assert(io.open(rejected.path, "w")); rejectedFile:close()
    local rejectedCommand = rejected.launch()
    -- Replace only the harmless command; use the same production supervisor.
    assert(not os.execute(completion.command(rejected.path, { "sh", "-c", "exit 0" })),
        "another plugin supervisor is excluded after immediate command exits")
    assert(rejectedCommand, "second service reached its terminal launch")
    rejectedFile = assert(io.open(rejected.path)); rejected.reads[rejected.path] = rejectedFile:read("*a"); rejectedFile:close()
    rejected.tick()
    local rejectedQueries = #rejected.queries
    rejected.request("refresh"); rejected.tick(5000)
    assert(rejected.state().updateBlocked and #rejected.queries == rejectedQueries
        and rejected.removed[rejected.path] and not rejected.removed[h.path],
        "real contention cleans only rejected receipt, without refresh or active ownership interference")
    assert(h.state().phase == "running" and not h.removed[h.path], "first service still owns its completed-but-locked run")
    assert(os.execute("printf 'release\\n' > " .. core.quote(gatePath)))
    childPipe:read("*a"); childPipe:close()
    h.tick(5000)
    assert(h.state().phase == "checking" and h.removed[h.path], "last descendant release permits completion refresh")
    h.refresh()
    rejected.tick(5000); rejected.tick(5000)
    assert(not rejected.state().updateBlocked and #rejected.queries == rejectedQueries,
        "rejected service does not duplicate the owner's completion refresh after real release")
    assert(os.execute(completion.command(second, { "sh", "-c", "exit 0" })), "subsequent launch acquires released lock")
    os.remove(h.path); os.remove(rejected.path); os.remove(gatePath)
end
for _, path in ipairs({ first, second, marker, testLock }) do os.remove(path) end
assert(os.execute("rmdir " .. core.quote(runtime)))
print("Completion, flock exclusion, runtime validation, recovery, and quoting checks passed")
