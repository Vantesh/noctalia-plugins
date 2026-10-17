--!nonstrict
local core = require("./core.luau")
local M = {}

-- Query the service environment, not a terminal's potentially different environment.
M.runtimeScript = [[
dir=${XDG_RUNTIME_DIR-}
case "$dir" in /*) ;; *) echo 'Set XDG_RUNTIME_DIR to a private user-owned runtime directory' >&2; exit 125 ;; esac
case "$dir" in *'
'*) exit 125 ;; esac
[ -d "$dir" ] && [ ! -L "$dir" ] && [ -w "$dir" ] && [ -x "$dir" ] &&
[ "$(stat -c '%u:%a' -- "$dir")" = "$(id -u):700" ] || {
    echo 'XDG_RUNTIME_DIR must be writable, owned by this user, and mode 0700' >&2
    exit 125
}
printf '%s/noctalia-topgrade.lock' "${dir%/}"
]]

M.revokeScript = [[
if [ -e "$1" ]; then printf 'cancelled\n' > "$1"; fi
]]

-- Keep FD 9 open in the supervisor, including while Topgrade waits at -k.
-- Normal descendants inherit it; code that closes inherited FDs cannot be tracked.
-- Never unlink the lock: contenders must always lock the same inode.
local script = [[
receipt=$1
lock=$2
shift 2
valid_gate() {
    [ -f "$receipt" ] || return 1
    marker=
    { IFS= read -r marker || [ -z "$marker" ]; } < "$receipt" || return 1
    [ "$marker" != cancelled ]
}
valid_gate || exit 125
umask 077
exec 9>>"$lock" || { printf 'done 125\n' > "$receipt"; exit 125; }
flock --nonblock --conflict-exit-code 75 9
code=$?
if [ "$code" -ne 0 ]; then
    if [ "$code" -eq 75 ]; then
        printf 'conflict 75\n' > "$receipt"
    else
        printf 'done %s\n' "$code" > "$receipt"
    fi
    exit "$code"
fi
valid_gate || exit 125
child=
interrupted=
finish() {
    code=$?
    trap - EXIT HUP INT TERM
    if [ -n "$interrupted" ]; then
        printf 'interrupted %s\n' "$interrupted" > "$receipt"
    else
        printf 'done %s\n' "$code" > "$receipt"
    fi
    exit "$code"
}
interrupt() {
    trap '' HUP INT TERM
    interrupted=$2
    if [ -n "$child" ]; then
        kill -s "$1" "$child" 2>/dev/null
        wait "$child"
    fi
    exit "$interrupted"
}
trap finish EXIT
trap 'interrupt HUP 129' HUP
trap 'interrupt INT 130' INT
trap 'interrupt TERM 143' TERM
printf 'running\n' > "$receipt" || exit 125
"$@" <&0 &
child=$!
wait "$child"
exit $?
]]

function M.command(receipt, argv, lock)
    local parts = { "sh", "-c", script, "topgrade-updater", receipt, lock }
    for _, arg in ipairs(argv) do table.insert(parts, arg) end
    for i, arg in ipairs(parts) do parts[i] = core.quote(arg) end
    return table.concat(parts, " ")
end

function M.receipt(text)
    if text == "running\n" then return "running" end
    local kind, code = (text or ""):match("^(%a+) (%d+)\n$")
    if kind == "conflict" and code == "75" then return kind, 75 end
    if (kind == "done" or kind == "interrupted") and tonumber(code) <= 255 then return kind, tonumber(code) end
    return nil
end

return M
