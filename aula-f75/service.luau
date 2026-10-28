--!nonstrict
local status = require("./status.luau")
local operations = require("./operations.luau")
local hotplug = require("./hotplug.luau")
local usbDirty, usbDisconnected, alive = false, false, true
local drainUSB
local busy, generation = false, 0
local function publish(value) noctalia.state.set(status.STATE, value) end

local current
local run
local running, cancelled = false, false
local refresh
local phase = "idle"
local pending, directory
local function operation(value)
    phase = value.phase
    noctalia.state.set(operations.KEY, value)
end
local function cleanup()
    if directory then
        noctalia.removeFile(directory .. "/review.json")
        noctalia.runAsync({ "rmdir", "--", directory })
        directory = nil
    end
    pending = nil
end
refresh = function()
    if busy or phase == "reviewing" or phase == "ready" or phase == "applying" then return end
    generation = generation + 1
    local token, received = generation, false
    if not noctalia.commandExists("aulaf75ctl") then
        current = nil; publish(status.problem("missing_cli")); operation({ phase = "idle", error = "aulaf75ctl not installed" }); return
    end
    busy = true
    publish({ phase = "refreshing", message = "Refreshing…", disconnected = usbDisconnected })
    local started = noctalia.runAsync({ "aulaf75ctl", "status", "--transport", "wired", "--json" }, function(result)
        if received or token ~= generation then return end
        received, busy = true, false
        if usbDirty then drainUSB(); return end
        current = status.read(result, noctalia.json.decode)
        usbDisconnected = current.phase == "disconnected"
        publish(current)
        if phase == "refreshing" then
            local previous = noctalia.state.get(operations.KEY) or {}
            operation({ phase = "idle", error = previous.error })
        end
        if current.controls and current.controls.active == 0 and current.controls.power then
            busy = true
            local args = operations.args("on")
            for _, v in ipairs({ "--dry-run", "--details", "--json" }) do args[#args + 1] = v end
            run(args, 10000, function(r)
                busy = false
                local plan = operations.plan(operations.decode(r, "on"), "on")
                current.controls.onAvailable = r.exitCode == 0 and plan ~= nil and type(plan.power.restoration_target) == "table"
                publish(current)
            end)
        end
    end, 5000)
    if not started and not received then
        received, busy = true, false
        publish(status.problem(nil, "Could not start aulaf75ctl. Check Noctalia's PATH."))
    end
end

noctalia.state.watch(status.REQUEST, refresh)
function onIpc(event) if event == "refresh" then refresh() end end

publish(noctalia.commandExists("aulaf75ctl") and { phase = "idle", message = "Open to refresh" } or status.problem("missing_cli"))

-- One serialized subprocess at a time; callback guards also cover failed spawns.
run = function(args, timeout, receive)
    running = true
    local token, done = generation, false
    local function finish(r)
        if done or token ~= generation then return end
        done = true
        running = false
        if cancelled then
            cancelled = false
            if args[1] == "mktemp" and type(r.stdout) == "string" then noctalia.runAsync({ "rmdir", "--", r.stdout }) end
            busy = false
            cleanup(); operation({ phase = "idle" }); drainUSB(); return
        end
        receive(r)
        drainUSB()
    end
    if not noctalia.runAsync(args, finish, timeout) then finish({ exitCode = 125 }) end
end
local function errorState(message)
    cleanup()
    operation({ phase = "idle", error = message })
end
local function validResult(r)
    return r.exitCode == 0 and not r.timedOut and not r.stdoutTruncated and not r.stderrTruncated
end
local function prepare(action)
    if busy or phase ~= "idle" or not operations.allowed(current, action.kind, action.value) then return end
    generation = generation + 1
    operation({ phase = "reviewing" })
    local args = operations.args(action.kind, action.value)
    for _, v in ipairs({ "--dry-run", "--details", "--json" }) do args[#args + 1] = v end
    run(args, 10000, function(result)
        local report = operations.decode(result, action.kind)
        local plan = validResult(result) and operations.plan(report, action.kind, action.value)
        if not plan then errorState(operations.error(report, "Unable to prepare review. Refresh status and review again.")); current = nil; refresh(); return end
        if plan.no_op then operation({ phase = "idle", message = "Already set; no writes needed." }); refresh(); return end
        pending = { kind = action.kind, value = action.value, raw = result.stdout }
        -- No shell: allocate a private directory, then write with the native file API.
        run({ "printenv", "XDG_RUNTIME_DIR" }, 2000, function(env)
            local root = validResult(env) and type(env.stdout) == "string" and env.stdout:match("^(/[^%c]+)$")
            if not root then errorState("A private XDG_RUNTIME_DIR is required."); return end
            run({ "id", "-u" }, 2000, function(uid)
                local owner = validResult(uid) and type(uid.stdout) == "string" and uid.stdout:match("^(%d+)$")
                if not owner then errorState("Cannot verify runtime owner."); return end
                run({ "stat", "-c", "%F:%u:%a", "--", root }, 2000, function(info)
                    if not validResult(info) or info.stdout ~= "directory:" .. owner .. ":700" then
                        errorState("XDG_RUNTIME_DIR must be an owned mode-0700 directory, not a symlink."); return
                    end
                    run({ "mktemp", "--directory", "--tmpdir=" .. root, "noctalia-aula.XXXXXXXXXX" }, 2000, function(temp)
                        local path = validResult(temp) and type(temp.stdout) == "string" and temp.stdout
                        local prefix = root:gsub("/+$", "") .. "/noctalia-aula."
                        if not path or path:sub(1, #prefix) ~= prefix or not path:sub(#prefix + 1):match("^%w%w%w%w%w%w%w%w%w%w$") then
                            errorState("Cannot allocate private review storage."); return
                        end
                        directory = path
                        if not noctalia.writeFile(path .. "/review.json", pending.raw) then errorState("Cannot save review."); return end
                        pending.raw = nil
                        local c = current.controls
                        local previous = (action.kind == "effect" or action.kind == "off" or action.kind == "on")
                            and status.label((plan.previous_effect or plan.active_effect or {}).name)
                            or plan["previous_" .. action.kind]
                        if action.kind == "palette" then previous = status.label((plan.previous_palette or {}).name) end
                        local requested = action.kind == "palette" and status.label((plan.requested_palette or {}).name) or action.value
                        if action.kind == "effect" then
                            for _, e in ipairs(c.effects) do if e.id == action.value then requested = e.name end end
                        elseif action.kind == "off" then requested = "Off"
                        elseif action.kind == "on" then requested = status.label(plan.power.restoration_target.name) end
                        operation({ phase = "ready", setting = action.kind, previous = tostring(previous), requested = tostring(requested),
                            warning = action.kind == "brightness" and not c.dimmingVerified and "Saved brightness may not visibly dim the LEDs." or nil })
                    end)
                end)
            end)
        end)
    end)
end
local lastNonce = 0
noctalia.state.watch(operations.REQUEST, function(action)
    if type(action) ~= "table" or type(action.nonce) ~= "number" or action.nonce <= lastNonce then return end
    lastNonce = action.nonce
    if action.action == "cancel" then
        if phase == "applying" then return end
        if busy then return end
        if running then
            cancelled = true
            operation({ phase = "reviewing", message = "Cancelling…" })
        else
            cleanup(); operation({ phase = "idle" })
        end
    elseif action.action == "apply" then
        if phase ~= "ready" or not pending or not directory then return end
        local args = operations.args(pending.kind, pending.value)
        for _, v in ipairs({ "--apply", "--review", directory .. "/review.json", "--json" }) do args[#args + 1] = v end
        operation({ phase = "applying" })
        run(args, 30000, function(result)
            local report = operations.decode(result, pending.kind)
            cleanup()
            operation({ phase = "refreshing", message = "Refreshing hardware status…",
                error = (not validResult(result) or not report or report.ok ~= true)
                    and operations.error(report, "Apply outcome uncertain. Hardware may have changed; fresh status and review required.") or nil })
            usbDirty = false -- This post-apply status read covers all queued USB events.
            refresh()
        end)
    elseif action.action == "prepare" then prepare(action) end
end)
function onExit() alive = false; generation = generation + 1; cleanup() end
operation({ phase = "idle" })

-- Coalesce USB events while a subprocess owns the hardware. Never overlap it,
-- reuse a review after re-enumeration, interrupt an apply, or retry a mutation.
drainUSB = function()
    if not alive or not usbDirty or busy or running or phase == "applying" then return end
    usbDirty = false
    cleanup()
    operation({ phase = "idle" })
    refresh()
end
local function usbEvent(action)
    if not alive then return end
    usbDirty = true
    current = nil
    if action == "remove" then usbDisconnected = true; publish(status.problem("disconnected")) end
    if phase == "applying" then return end
    if running then
        cancelled = true
        operation({ phase = "reviewing", message = "USB connection changed; discarding review…" })
        return
    end
    drainUSB()
end
if noctalia.runStream and noctalia.commandExists("udevadm") then
    -- API 43's stream API accepts a shell string only. This is a fixed command
    -- with no interpolated input; exec gives the host direct process ownership.
    noctalia.runStream("exec udevadm monitor --udev --subsystem-match=hidraw --property", hotplug.parser(usbEvent))
    refresh() -- One startup read; subsequent checks are event-driven, not polled.
end
