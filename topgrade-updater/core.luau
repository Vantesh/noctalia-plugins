--!nonstrict
-- Discovery follows community-plugins/topgrade-wrapper by nightwatch75 (MIT).
local M = {}

function M.quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

function M.hidden(state, enabled)
    if type(state) ~= "table" then state = {} end
    if state.dismissed == true then return true end
    if state.phase == "checking" and state.refreshingVisible == true then return false end
    if enabled == nil then enabled = true end
    local total = state.total or 0
    return enabled == true and total <= 0
end

function M.discover(text)
    local steps, current, summary, malformed = {}, nil, false, false
    text = text:gsub("\27%[[%d;]*m", "")
    for line in text:gmatch("[^\r\n]+") do
        local name = line:match("%d%d:%d%d:%d%d%s*%-%s*(.-)%s*―")
        if name then
            if name == "Summary" then summary = true; break end
            current = { name = name, commands = {} }
            table.insert(steps, current)
        else
            local command = line:match("^%s*Dry running:%s*(.+)$")
            if command then
                if not current then
                    malformed = true
                    current = { name = "Unrecognized step", commands = {} }
                    table.insert(steps, current)
                end
                table.insert(current.commands, command)
            elseif line:find("Dry running:", 1, true) or line:match("%d%d:%d%d:%d%d%s*%-%s*") then
                malformed = true
            end
        end
    end
    -- Empty or truncated output is not proof that the Arch scope is clean.
    return steps, summary and #steps > 0 and not malformed
end

-- Execute queries directly: no pipelines may mask a manager's exit status.
M.counters = {
    { key = "pacman", patterns = { "pacman.-%-Sy+u", "yay.-%-Sy+u", "paru.-%-Sy+u" }, argv = { "checkupdates" }, codes = { [0] = true, [2] = true } },
    { key = "AUR (yay)", patterns = { "yay.-%-Sy+u" }, argv = { "yay", "-Qua" } },
    { key = "AUR (paru)", patterns = { "paru.-%-Sy+u" }, argv = { "paru", "-Qua" } },
}

local function archCommand(command)
    -- Manager names in arguments (e.g. an npm package or notification) do not
    -- make an unrelated command an Arch source. Allow common launcher prefixes.
    for token in command:gmatch("%S+") do
        local executable = token:gsub('^["\']', ""):gsub('["\']$', ""):match("([^/]+)$")
        if executable == "pacman" or executable == "yay" or executable == "paru" then return true, false end
        if executable and executable:match("sh$") then
            -- Shell-wrapped Arch commands remain uncertain in the planner.
            return command:match("%f[%w]pacman%s") or command:match("%f[%w]yay%s") or command:match("%f[%w]paru%s"), true
        end
        if executable ~= "sudo" and executable ~= "doas" and executable ~= "env"
            and not token:match("^%-") and not token:match("^[%w_]+=") then return false end
    end
    return false
end

function M.plan(steps)
    local queue, unknown, seen = {}, {}, {}
    for _, step in ipairs(steps) do
        -- An empty System heading cannot establish which package manager runs.
        if #step.commands == 0 and step.name == "System" then
            table.insert(unknown, step.name .. ": no queryable command")
        end
        for _, command in ipairs(step.commands) do
            local relevant, shellWrapped = archCommand(command)
            -- Topgrade prints Arch news separately; this does not upgrade packages.
            local newsOnly = command:match("^%s*[%w/_.%-]*yay%s+%-Pw%s*$")
                or command:match("^%s*[%w/_.%-]*paru%s+%-Pw%s*$")
            if relevant and not newsOnly then
                local covered = false
                for _, counter in ipairs(M.counters) do
                    for _, pattern in ipairs(counter.patterns) do
                        if command:match(pattern) then
                            covered = true
                            if not seen[counter.key] then
                                seen[counter.key] = true
                                table.insert(queue, counter)
                            end
                            break
                        end
                    end
                end
                -- Default-installation queries cannot verify alternate targets
                -- or arbitrary shell scripts, even when an Arch manager matches.
                local special = command:find("--root", 1, true) or command:find("--dbpath", 1, true)
                    or command:find("--sysroot", 1, true) or command:find("--config", 1, true)
                    or command:find("&&", 1, true) or command:find(";", 1, true) or command:find("|", 1, true)
                    or command:match("%s%-[^%s%-]*[rb]%S*") or shellWrapped
                if not covered or special then table.insert(unknown, step.name .. ": " .. command) end
            end
        end
    end
    return queue, unknown
end

-- Yay v13.0.1 pkg/text/time.go: at most two units, minutes omitted for days.
local function yayAgeTag(tag)
    local days, hours = tag:match("^%[([1-9]%d*)d([1-9]%d*)h%]$")
    if days then return tonumber(hours) < 24 end
    if tag:match("^%[[1-9]%d*d%]$") then return true end
    local h, minutes = tag:match("^%[([1-9]%d*)h([1-9]%d*)m%]$")
    if h then return tonumber(h) < 24 and tonumber(minutes) < 60 end
    h = tag:match("^%[([1-9]%d*)h%]$")
    if h then return tonumber(h) < 24 end
    minutes = tag:match("^%[(%-?[1-9]%d*)m%]$")
    -- Future timestamps fall through FormatDuration to negative minutes.
    return tag == "[0m]" or (minutes ~= nil and math.abs(tonumber(minutes)) < 60)
end

function M.parse(counter, result)
    if result.timedOut then return nil, "query timed out" end
    if result.stdoutTruncated or result.stderrTruncated then return nil, "query output was truncated" end
    -- Both AUR helpers report an empty upgrade list with a silent exit 1.
    local aurEmpty = (counter.key == "AUR (yay)" or counter.key == "AUR (paru)") and result.exitCode == 1
        and not (result.stdout or ""):match("%S") and not (result.stderr or ""):match("%S")
    if aurEmpty then return {} end
    local codes = counter.codes or { [0] = true }
    if not codes[result.exitCode] then return nil, "query failed (exit " .. tostring(result.exitCode) .. "): " .. (result.stderr or "") end
    -- Warnings can indicate partial results; never classify them as clean.
    if (result.stderr or ""):match("%S") then return nil, result.stderr end
    local items = {}
    for line in (result.stdout or ""):gmatch("[^\r\n]+") do
        local row = line
        if counter.key == "AUR (yay)" then
            -- Yay styles names, versions, and age tags even though we request NO_COLOR.
            row = row:gsub("\27%[[%d;]*m", "")
            local versions, tag = row:match("^(.-)%s+(%[[^%]]+%])%s*$")
            if tag and yayAgeTag(tag) then row = versions end
        end
        local name, from, to = row:match("^(%S+)%s+(%S+)%s+%-%>%s+(%S+)%s*$")
        if not name or row:find("\27", 1, true) then return nil, "unrecognized query output: " .. line end
        table.insert(items, { name = name, from = from, to = to })
    end
    if result.exitCode == 2 and #items > 0 then return nil, "inconsistent checkupdates result" end
    return items
end

-- Keep optional metadata work bounded independently of the displayed list cap.
function M.downloadBatches(items)
    if #items == 0 or #items > 500 then return nil end
    local batches, seen = {}, {}
    for i, item in ipairs(items) do
        local name = item.name
        -- Arch pkgname characters; leading dots/hyphens are not valid names.
        if type(name) ~= "string" or #name > 255 or not name:match("^[%w_+][%w@._+%-]*$") or seen[name] then return nil end
        seen[name] = true
        if (i - 1) % 50 == 0 then table.insert(batches, {}) end
        table.insert(batches[#batches], name)
    end
    return batches
end

local sizeUnits = { B = 1, KiB = 1024, MiB = 1024^2, GiB = 1024^3, TiB = 1024^4 }
function M.downloadBytes(names, result)
    if result.timedOut or result.stdoutTruncated or result.stderrTruncated or result.exitCode ~= 0
        or (result.stderr or ""):match("%S") or #(result.stdout or "") > 256 * 1024 then return nil end
    local expected, found, total = {}, {}, 0
    for _, name in ipairs(names) do expected[name] = true end
    local name, bytes, invalid
    local function record()
        if not name or bytes == nil or invalid or not expected[name] or found[name] then return false end
        found[name], total = true, total + bytes
        name, bytes, invalid = nil, nil, nil
        return true
    end
    local active, lines = false, 0
    for raw in ((result.stdout or "") .. "\n\n"):gmatch("([^\n]*)\n") do
        lines = lines + 1
        if lines > 2048 or #raw > 8192 then return nil end
        local line = raw:gsub("\r$", "")
        if not line:match("%S") then
            if active and not record() then return nil end
            active = false
        else
            active = true
            local field, value = line:match("^(Name)%s*:%s*(.*)$")
            if not field then field, value = line:match("^(Download Size)%s*:%s*(.*)$") end
            if value then
                -- Trim from the end without backtracking across internal whitespace.
                local trailing = value:reverse():match("^%s*()") - 1
                value = value:sub(1, #value - trailing)
            end
            if field == "Name" then
                if name then invalid = true end
                name = value
            elseif field == "Download Size" then
                if bytes ~= nil then invalid = true end
                if #value > 64 then return nil end
                local amount, unit = value:match("^(%S+)%s+(%a+)$")
                if not amount or not (amount:match("^%d+$") or amount:match("^%d+%.%d*$"))
                    or not sizeUnits[unit] then return nil end
                bytes = tonumber(amount) * sizeUnits[unit]
                if bytes ~= bytes or bytes == math.huge then return nil end
            end
        end
    end
    for _, wanted in ipairs(names) do if not found[wanted] then return nil end end
    return total
end

function M.formatDownload(bytes)
    local units, index = { "B", "KiB", "MiB", "GiB", "TiB" }, 1
    while bytes >= 1024 and index < #units do bytes, index = bytes / 1024, index + 1 end
    return string.format("%.1f %s", bytes, units[index])
end

return M
