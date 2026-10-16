-- Run from the repository root: lua topgrade-updater/tests/notifications.lua
-- Each fixture loads the real service in isolation; no native side effects occur.
local root = "topgrade-updater/"
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local function result(stdout, code, stderr)
    return { stdout = stdout or "", exitCode = code or 0, stderr = stderr or "" }
end
local function fixture()
    -- The native service context resolves declared manifest defaults before load.
    local settings = { auto_check_hours = 1, notify_on_updates = true }
    local jobs, notifications, watches = {}, {}, {}
    local latest
    local env = setmetatable({}, { __index = _G })
    env.require = function(path)
        if path == "./core.luau" then return dofile(root .. "core.luau") end
        if path == "./completion.luau" then return assert(loadfile(root .. "completion.luau", "t", env))() end
        if path == "./shared.luau" then return { STATE = "state", REQUEST = "request" } end
        error("unexpected require: " .. path)
    end
    env.noctalia = {
        getConfig = function(key) return settings[key] end,
        commandExists = function() return true end,
        state = {
            set = function(_, value) latest = value end,
            watch = function(key, callback) watches[key] = callback end,
        },
        runAsync = function(args, callback)
            jobs[#jobs + 1] = { args = args, callback = callback }
            return true
        end,
        formatTime = function() return "12:34" end,
        setUpdateInterval = function() end,
        tr = function(key)
            expect(key == "title", "translate the notification title")
            return "Topgrade Updater"
        end,
        trp = function(key, count, args)
            expect(key == "notify_updates" and args.count == count, "native plural translation receives count")
            return count == 1 and "1 package to upgrade" or (count .. " packages to upgrade")
        end,
        notify = function(...)
            local args = { ... }
            expect(#args == 2, "native notify takes title/body only, with no sound override")
            notifications[#notifications + 1] = args
        end,
    }
    assert(loadfile(root .. "service.luau", "t", env))()
    local function reply(value, duplicate)
        local job = table.remove(jobs, 1)
        assert(job and job.callback, "expected pending asynchronous query")
        job.callback(value)
        if duplicate then job.callback(value) end
        return job.args
    end
    local function discover(command)
        reply(result("―― 12:34:56 - System ――\nDry running: " .. (command or "pacman -Syu") .. "\n―― 12:34:56 - Summary ――\n"))
    end
    local function start()
        for _ = 1, 10 do env.update() end
        discover()
    end
    return {
        env = env, settings = settings, jobs = jobs, notifications = notifications,
        watches = watches, reply = reply, discover = discover, start = start,
        state = function() return latest end,
    }
end

local f = fixture()
for _ = 1, 10 do f.env.update() end
f.discover("yay -Syu")
f.reply(result("linux 1 -> 2"))
expect(#f.notifications == 0 and f.state().phase == "checking", "progressive positive subtotal does not notify")
f.reply(result("aur-tool 1 -> 2"))
expect(#f.notifications == 1 and f.state().complete, "completed positive check notifies exactly once with default enabled")
expect(f.notifications[1][1] == "Topgrade Updater" and f.notifications[1][2] == "2 packages to upgrade", "native notification title and plural body")
local args = f.reply(result("Name : linux\nDownload Size : 1 MiB"))
expect(args[4] == "pacman" and f.state().downloadBytes == 1024^2, "complete the real optional metadata callback")
expect(#f.notifications == 1, "download metadata publication does not duplicate notification")
f.watches.request({ nonce = 1, action = "check" })
f.discover()
f.reply(result("linux 1 -> 2"))
expect(f.state().complete and f.state().total == 1 and #f.notifications == 1,
    "manual panel refresh updates packages without another notification")
f.reply(result("Name : linux\nDownload Size : 1 MiB"))
for _ = 1, 3600 do f.env.update() end
f.discover()
f.reply(result("linux 1 -> 2"))
expect(#f.notifications == 2 and f.notifications[2][2] == "1 package to upgrade",
    "scheduled checks still notify after a manual refresh")

f = fixture()
f.settings.notify_on_updates = false
f.start()
f.reply(result("linux 1 -> 2"))
expect(f.state().complete and f.state().total == 1 and #f.notifications == 0, "disabled setting preserves counts without notification")
f.reply(result("Name : linux\nDownload Size : 1 MiB"))
expect(#f.notifications == 0, "metadata cannot bypass disabled setting")

f = fixture()
f.start()
f.reply(result("", 2))
expect(f.state().complete and f.state().total == 0 and #f.notifications == 0, "clean zero check stays silent")

f = fixture()
f.start()
f.watches.request({ nonce = 1, action = "dismiss" })
f.reply(result("linux 1 -> 2"))
expect(f.state().complete and f.state().dismissed and #f.notifications == 0,
    "in-flight dismissal suppresses completed-check notifications")
f.reply(result("Name : linux\nDownload Size : 1 MiB"))
expect(#f.notifications == 0, "late metadata cannot notify after dismissal")

f = fixture()
for _ = 1, 10 do f.env.update() end
f.discover("yay -Syu")
f.reply(result("linux 1 -> 2"))
f.reply(result("", 1, "AUR unavailable"))
expect(f.state().total == 1 and not f.state().complete and #f.notifications == 0, "known positive subtotal with failed coverage does not notify")

f = fixture()
for _ = 1, 10 do f.env.update() end
f.reply(result("―― 12:34:56 - System ――\nDry running: pacman -Syu\n―― 12:34:56 - Summary ――\n", 0, "discovery warning"))
f.reply(result("linux 1 -> 2"))
expect(f.state().total == 1 and not f.state().complete and #f.notifications == 0, "discovery uncertainty with positive count stays silent")
f = fixture()
for _ = 1, 10 do f.env.update() end
f.reply(result("―― 12:34:56 - System ――\nDry running: pacman -Syu\n―― 12:34:56 - Summary ――\n"), true)
expect(#f.jobs == 1, "duplicate discovery callback cannot start a second package query")
f.reply(result("linux 1 -> 2"), true)
expect(f.state().total == 1 and #f.state().counts == 1 and #f.notifications == 1,
    "duplicate package callback cannot accumulate counts or notify again")
f.reply(result("Name : linux\nDownload Size : 1 MiB"), true)
expect(f.state().downloadBytes == 1024^2 and #f.notifications == 1,
    "duplicate metadata callback cannot accumulate bytes or notify again")
print("Passed " .. checks .. " notification assertions")
