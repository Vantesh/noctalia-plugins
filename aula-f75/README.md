# AULA F75

Compact wired lighting controls for [aulaf75ctl](https://github.com/Vantesh/aulaf75ctl).
Requires Noctalia v5.4 with Plugin API 43, coreutils, `udevadm` (systemd/udev),
and the current schema-1 backend with `configuration.active_effect` on Noctalia's PATH. Close F75 Studio
and other keyboard controllers before refreshing. Run as your ordinary user.

Register the checkout and enable the plugin:

```sh
noctalia msg plugins source add noctalia-plugins path /absolute/path/to/noctalia-plugins
noctalia msg plugins enable vantesh/aula-f75
```

Add the AULA F75 bar widget or use `/aula` in the launcher. Opening the panel or
pressing Refresh requests wired status. The icon-only bar widget hides after a
status check confirms disconnection and reappears after a verified connected read.
The service watches udev events for the wired F75 control interface through
`udevadm monitor` and performs one initial status read. Unplugging hides the icon;
reconnecting triggers a fresh verified read even while the panel is closed.
There is no recurring polling or mutation retry. USB events invalidate pending
reviews; an already-started apply finishes before another status read can begin.
The stream is owned and terminated by Noctalia's service runtime, not a separate
daemon. If udev monitoring is unavailable, launcher/manual refresh still works.
The panel distinguishes the active effect from any retained native selection.

Select an effect from the dropdown, choose a supported palette, or release a brightness
or speed slider to prepare a fresh review. The picker uses the backend's observed
native effects plus Self-defined and Off; Shadow Fade, Scanner and Storm are not
offered. Parameters appear only when the backend supplies supported values.
Levels are firmware values (brightness 0–9, speed 0–4), not percentages.
Saved brightness, especially in Self-defined mode, may not visibly dim the LEDs.

Every change first runs `lighting … --dry-run --details --json`. The inline review
shows current/requested values; only **Apply Change** starts `--apply --review`.
One operation runs at a time. Cancel or closing the panel discards a pending
review; a command already applying finishes without being retried. After apply,
fresh status confirms values. An error or timeout may mean hardware changed;
refresh and prepare a new review rather than retrying an old approval.

The header power button uses the same approval flow. Off preserves restoration
context in the backend; On is enabled only after a read-only backend probe confirms
a restoration target. USB reconnection or reboot can invalidate that context.
The plugin never invents or persists its own restoration target.

Reviews stay outside settings/shared state in a fresh private `mktemp` directory
under an owner-verified mode-0700 `XDG_RUNTIME_DIR`. Noctalia writes the JSON as
0600. Files are removed after cancellation, apply or failure; directories are
removed with coreutils. Hardware commands use explicit argument arrays; JSON is
written through Noctalia's file API. API 43's string-only stream API runs one
fixed `exec udevadm monitor` command with no interpolated input. No direct HID
access or generated shell scripts are used. Review files are invalidated on service exit; abrupt process termination
may leave private runtime debris, which is never reused and disappears on logout.
Backend state comparison remains the final check against changes since review.

Only wired USB is supported. No custom RGB/per-key editing, profiles or previews
are provided. Successful readbacks do not establish visible LED behavior.

```sh
lua aula-f75/tests/status.lua
lua aula-f75/tests/operations.lua
lua aula-f75/tests/ui.lua
noctalia plugins lint aula-f75
```

MIT — see [LICENSE](../LICENSE). Hardware interpretation and protocol attribution
remain with the standalone backend; no AULA protocol is implemented here.

## Panel layout

The 400 px content-sized panel places verified connection/transport beneath the
semibold title, beside a centered keyboard icon. Power, Refresh and Close form
the separate right-hand group. Native outer padding plus a small content inset
provides comfortable spacing without widening the panel.

The non-searchable effect selector uses rounded native containers. The expanded
list temporarily replaces the parameter sections and scrolls within a bounded
five-row viewport, uses subtle theme fills rather
than checkmarks or bright button backgrounds, and shares symbol labels with the
trigger. Tab/Enter activates rows; Up/Down or Home/End moves the highlighted
choice, and Enter on the trigger selects it. Escape and outside dismissal close
the panel and discard any pending review, as before. No overlay positioning or
frame/timer workaround is used.

Each supported slider has one left-hand icon. Eight 34 px palette circles share
the available width, with names retained in tooltips and the selected name omitted
from the heading. Alt+1 through Alt+8 prepares the corresponding palette review.
Circles remain native focusable click targets with separate hover outlines and
selected checks. Random uses a multicolor SVG and a selected outline.

Ordinary views measure their column directly. During refresh, the last verified
sections stay visible but disabled; an error or disconnect clears them. Only the
expanded effect list has a fixed, bounded viewport. On very small outputs the
host can clamp the complete panel; that screen-size case remains unverified.
