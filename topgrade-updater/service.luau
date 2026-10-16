--!nonstrict
local core = require("./core.luau")
local shared = require("./shared.luau")
local completion = require("./completion.luau")
local state = { phase = "idle", complete = false, total = 0, counts = {}, unknown = {} }
local elapsed, startup = 0, 0
local activeRun, updateBlocked, lockPath
local recovering, lockPending, nextLockCheck = false, false, 0

-- Each process result may advance its workflow only once, even if delivered late
-- after a failed spawn or delivered again while the same generation is active.
local function runOnce(args, receive, timeout)
    local received = false
    local function once(result)
        if received then return end
        received = true
        receive(result)
    end
    local started = noctalia.runAsync(args, once, timeout)
    if not started then received = true end
    return started
end

local function probeLock(receive)
    local started = runOnce({ "flock", "--nonblock", "--conflict-exit-code", "75", lockPath, "sh", "-c", ":" }, receive, 5000)
    if not started then receive({ exitCode = 125 }) end
end

local function lockStatus(result)
    if result.timedOut or result.stdoutTruncated or result.stderrTruncated then return nil end
    if result.exitCode == 0 then return "clear" end
    if result.exitCode == 75 then return "locked" end
    return nil
end

local generation, lastRequest = 0, 0
local configPath = noctalia.getConfig("topgrade_config") or ""

local function publish()
    state.updateBlocked = updateBlocked
    noctalia.state.set(shared.STATE, state)
end

local function dismiss()
    state.dismissed = true
    publish()
end

local function discoveryArgs()
    local args = { "topgrade" }
    if configPath ~= "" then
        table.insert(args, "--config")
        table.insert(args, noctalia.expandPath(configPath))
    end
    table.insert(args, "--dry-run")
    table.insert(args, "--no-self-update")
    return args
end

local function fail(message)
    state.phase, state.complete, state.error = "error", false, message
    state.updateError = nil
    elapsed = 0
    publish()
end

local function check(updateError, automatic)
    if recovering or state.phase == "checking" or state.phase == "running" then return end
    generation = generation + 1
    local token = generation
    local repoBatches
    local function estimateDownload()
        if not repoBatches or noctalia.getConfig("show_download_size") == false or not noctalia.commandExists("pacman") then return end
        local index, total = 0, 0
        local function nextBatch()
            if token ~= generation or noctalia.getConfig("show_download_size") == false then return end
            index = index + 1
            local names = repoBatches[index]
            if not names then
                state.downloadBytes = total
                publish()
                return
            end
            local args = { "env", "LC_ALL=C", "NO_COLOR=1", "pacman", "-Si", "--" }
            for _, name in ipairs(names) do table.insert(args, name) end
            -- Failure is informational only: retain the already-published counts.
            runOnce(args, function(result)
                if token ~= generation then return end
                local bytes = core.downloadBytes(names, result)
                if bytes == nil then return end
                total = total + bytes
                nextBatch()
            end, 10000)
        end
        nextBatch()
    end
    -- Only an accepted new check clears dismissal; in-flight results retain it.
    -- Retain visibility, not counts: fresh queries must never accumulate old totals.
    local refreshingVisible = not core.hidden(state)
    state = { phase = "checking", refreshingVisible = refreshingVisible, dismissed = false, complete = false, total = 0, counts = {}, unknown = {}, step = "Discovering Pacman/AUR in Topgrade plan", updateError = updateError }
    publish()
    if not noctalia.commandExists("topgrade") then fail("Topgrade is not installed"); return end
    local dry = { "env", "LC_ALL=C", "NO_COLOR=1" }
    for _, arg in ipairs(discoveryArgs()) do table.insert(dry, arg) end
    local started = runOnce(dry, function(result)
        if token ~= generation then return end
        if result.timedOut or result.exitCode ~= 0 then
            fail("Topgrade discovery failed: " .. (result.stderr or "") .. (result.timedOut and " (timeout)" or ""))
            return
        end
        if result.stdoutTruncated or result.stderrTruncated then
            fail("Topgrade discovery output was truncated; coverage is unknown")
            return
        end
        local steps, valid = core.discover(result.stdout or "")
        local queue, unknown = core.plan(steps)
        if (result.stderr or ""):match("%S") then
            table.insert(unknown, "Topgrade discovery diagnostics: " .. result.stderr)
        end
        state.unknown = unknown
        if not valid then table.insert(unknown, "Incomplete or unrecognized Topgrade discovery output") end
        local pump
        pump = function()
            if token ~= generation then return end
            local counter = table.remove(queue, 1)
            if not counter then
                state.complete = valid and #state.unknown == 0
                state.phase = state.total > 0 and "ready" or (state.complete and "clean" or "unknown")
                state.updateError = nil
                state.step = nil
                state.checkedAt = noctalia.formatTime("%H:%M")
                elapsed = 0
                publish()
                -- Notify only verified totals, once at check completion; never on
                -- progressive publications or optional download metadata results.
                if automatic and state.complete and state.total > 0 and not state.dismissed
                    and noctalia.getConfig("notify_on_updates") == true then
                    noctalia.notify(noctalia.tr("title"), noctalia.trp("notify_updates", state.total, { count = state.total }))
                end
                estimateDownload()
                return
            end
            state.step = counter.key
            publish()
            local function unknownQuery(message)
                table.insert(state.unknown, counter.key .. ": " .. message)
                pump()
            end
            if not noctalia.commandExists(counter.argv[1]) then unknownQuery("missing " .. counter.argv[1]); return end
            local args = { "env", "LC_ALL=C", "NO_COLOR=1" }
            for _, arg in ipairs(counter.argv) do table.insert(args, arg) end
            local spawned = runOnce(args, function(queryResult)
                if token ~= generation then return end
                local items, err = core.parse(counter, queryResult)
                if not items then unknownQuery(err); return end

                local n = #items
                if counter.key == "pacman" then repoBatches = core.downloadBatches(items) end
                -- Bound shared-state size without understating the count.
                while #items > 200 do table.remove(items) end
                table.insert(state.counts, { key = counter.key, n = n, items = items })
                state.total = state.total + n
                pump()
            end, 60000)
            if not spawned then unknownQuery("could not start query") end
        end
        pump()
    end, 45000)
    if not started then fail("Could not start Topgrade discovery") end
end

local function pollRecovery()
    if not recovering or activeRun or state.phase == "checking" or lockPending or noctalia.nowMs() < nextLockCheck then return end
    local recovery = recovering
    lockPending = true
    nextLockCheck = noctalia.nowMs() + 5000
    local function receive(result)
        if recovering ~= recovery or not lockPending or activeRun then return end
        lockPending = false
        local status = lockStatus(result)
        if not status then
            updateBlocked = "Cannot check Topgrade lock. Check flock and runtime directory access; retrying automatically."
        elseif status == "locked" then
            updateBlocked = "Topgrade is already running. Waiting for its lock to clear automatically."
        else
            recovering, updateBlocked = false, nil
            if recovery.refresh then check(state.updateError) end
        end
        publish()
    end
    probeLock(receive)
end

local function finishRun(message, blocked, rejected)
    if blocked then
        recovering = { refresh = not rejected }
        nextLockCheck = 0
        updateBlocked = "Checking Topgrade lock; recovery will continue automatically."
    end
    local run = activeRun
    activeRun = nil
    if not blocked then updateBlocked = nil end
    if run and run.path then noctalia.removeFile(run.path) end
    state.phase = "idle"
    if blocked then
        state.updateError = message
        publish()
        pollRecovery()
    else
        check(message)
    end
end

local function runUpdate()
    if updateBlocked or state.phase == "checking" or state.phase == "running" then return end
    if not noctalia.commandExists("topgrade") then fail("Topgrade is not installed"); return end
    for _, dependency in ipairs({ "sh", "mktemp", "flock", "stat", "id" }) do
        if not noctalia.commandExists(dependency) then
            fail("Update tracking requires " .. dependency .. " (flock is provided by util-linux)"); return
        end
    end
    local command = noctalia.getConfig("update_cmd") or "topgrade -k --no-self-update --notify-end never"
    if not command:match("%S") then fail("Update command is empty"); return end
    if configPath ~= "" then
        command = command .. " --config " .. core.quote(noctalia.expandPath(configPath))
    end
    local args = { "sh", "-c", command }
    local terminal = (noctalia.getConfig("terminal_cmd") or ""):match("^%s*(.-)%s*$")
    local run = { startedAt = noctalia.nowMs() }
    activeRun = run
    generation = generation + 1 -- Invalidate optional metadata callbacks before updating.
    state.downloadBytes = nil
    state.phase, state.complete, state.error, state.updateError = "running", false, nil, nil
    publish()
    local function allocate()
        local started = runOnce({ "mktemp", "/tmp/noctalia-topgrade.XXXXXXXXXX" }, function(result)
            if activeRun ~= run then return end
            -- Native runAsync strips trailing line endings; raw shell fixtures may
            -- retain the newline. Accept either, without accepting extra output/paths.
            local path = (result.stdout or ""):match("^(/tmp/noctalia%-topgrade%.[%w]+)\n?$")
            run.path = path
            if result.timedOut or result.exitCode ~= 0 or result.stdoutTruncated or not path then
                local reason = result.timedOut and "timeout" or ("exit " .. tostring(result.exitCode))
                if result.stdoutTruncated then reason = reason .. "; truncated stdout" end
                if not path then reason = reason .. "; invalid receipt path output" end
                if (result.stderr or ""):match("%S") then reason = reason .. "; " .. result.stderr end
                finishRun("Could not create update completion receipt (" .. reason .. ")"); return
            end
            local supervised = completion.command(path, args, lockPath)
            local launched
            if terminal == "" then
                launched = noctalia.runInTerminal(supervised)
            else
                -- No callback selects Noctalia's detached overload: no query timeout
                -- or terminal-lifetime wait. Only the receipt determines completion.
                launched = noctalia.runAsync({ "sh", "-c", terminal .. " sh -c " .. core.quote(supervised) })
            end
            if not launched then finishRun("Could not launch a terminal") end
        end, 5000)
        if not started then finishRun("Could not start update tracking") end
    end
    local started = runOnce({ "sh", "-c", completion.runtimeScript }, function(result)
        if activeRun ~= run then return end
        local path = (result.stdout or ""):match("^(/[^\r\n]+)\n?$")
        if result.exitCode ~= 0 or result.timedOut or result.stdoutTruncated or not path then
            finishRun("Cannot use XDG_RUNTIME_DIR for the Topgrade lock: " .. (result.stderr or "set a private user-owned mode 0700 runtime directory")); return
        end
        lockPath = path
        allocate()
    end, 5000)
    if not started then finishRun("Could not query XDG_RUNTIME_DIR for the Topgrade lock") end
end

local function pollRun()
    local run = activeRun
    if not run or not run.path then return end
    local kind, value = completion.receipt(noctalia.readFile(run.path))
    if kind == "conflict" then
        finishRun("Topgrade is already running; no update was started (lock conflict, exit 75)", true, true)
        return
    end
    local completed = kind == "done" or kind == "interrupted"
    if kind == "running" then run.seen = true end
    -- A receipt records the immediate command's exit, not the last FD holder.
    -- Retain this run's ownership until descendants have released the lock too.
    if not completed and not run.seen and noctalia.nowMs() - run.startedAt < 30000 then return end
    if run.probing or noctalia.nowMs() < (run.nextProbe or 0) then return end
    run.probing, run.nextProbe = true, noctalia.nowMs() + 5000
    probeLock(function(result)
        if activeRun ~= run or not run.probing then return end
        run.probing = false
        local status = lockStatus(result)
        if status == "clear" then
            -- Read again: a running/missing receipt may have completed in flight.
            local latest, code = completion.receipt(noctalia.readFile(run.path))
            if latest == "done" or latest == "interrupted" then
                local message = code ~= 0 and ("Topgrade failed or was interrupted (exit " .. code .. ")") or nil
                finishRun(message)
                return
            end
            if latest == "conflict" then return end
            run.missing = (run.missing or 0) + 1
            if run.missing >= 2 then
                finishRun("Topgrade completion tracking was lost; update result is unknown", true)
            end
        else
            run.missing = 0
            if not status then
                updateBlocked = "Cannot check Topgrade lock; updates remain disabled while tracking is unresolved"
                publish()
            end
        end
    end)
end

local function dispatch(action)
    if action == "check" or action == "refresh" then check()
    elseif action == "dismiss" then dismiss()
    elseif action == "update" then runUpdate() end
end

noctalia.state.watch(shared.REQUEST, function(request)
    if type(request) ~= "table" or (request.nonce or 0) <= lastRequest then return end
    lastRequest = request.nonce
    dispatch(request.action)
end)

function update()
    local path = noctalia.getConfig("topgrade_config") or ""
    if path ~= configPath then
        configPath = path
        generation = generation + 1
        if state.phase ~= "running" then
            state = { phase = "idle", complete = false, total = 0, counts = {}, unknown = {} }
            publish()
            check()
        end
    end
    if state.phase == "running" then
        pollRun()
        return
    end
    pollRecovery()
    elapsed, startup = elapsed + 1, startup + 1
    local hours = tonumber(noctalia.getConfig("auto_check_hours")) or 0
    if hours > 0 and ((startup >= 10 and state.phase == "idle") or elapsed >= hours * 3600) then check(nil, true) end
end

function onIpc(event, _payload)
    dispatch(event)
end

noctalia.setUpdateInterval(1000)
publish()
