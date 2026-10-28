--!nonstrict
local status = require("./status.luau")
local busy, generation = false, 0
local function publish(value) noctalia.state.set(status.STATE, value) end

local function refresh()
    if busy then return end
    generation = generation + 1
    local token, received = generation, false
    if not noctalia.commandExists("aulaf75ctl") then publish(status.problem("missing_cli")); return end
    busy = true
    publish({ phase = "refreshing", message = "Refreshing…" })
    local started = noctalia.runAsync({ "aulaf75ctl", "status", "--transport", "wired", "--json" }, function(result)
        if received or token ~= generation then return end
        received, busy = true, false
        publish(status.read(result, noctalia.json.decode))
    end, 5000)
    if not started and not received then
        received, busy = true, false
        publish(status.problem(nil, "Could not start aulaf75ctl. Check Noctalia's PATH."))
    end
end

noctalia.state.watch(status.REQUEST, refresh)
function onIpc(event) if event == "refresh" then refresh() end end
function onExit() generation = generation + 1 end
publish(noctalia.commandExists("aulaf75ctl") and { phase = "idle", message = "Open to refresh" } or status.problem("missing_cli"))
