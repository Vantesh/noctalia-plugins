# AULA F75

Compact wired lighting controls for [aulaf75ctl](https://github.com/Vantesh/aulaf75ctl).
Requires Noctalia v5.4 with Plugin API 43, coreutils, and the current schema-1
backend with `configuration.active_effect` on Noctalia's PATH. Close F75 Studio
and other keyboard controllers before refreshing. Run as your ordinary user.

Register the checkout and enable the plugin:

```sh
noctalia msg plugins source add noctalia-plugins path /absolute/path/to/noctalia-plugins
noctalia msg plugins enable vantesh/aula-f75
```

Add the AULA F75 bar widget or use `/aula` in the launcher. Opening the panel or
pressing Refresh requests wired status. There is no polling or automatic retry.
The panel distinguishes the active effect from any retained native selection.

Select an effect from the native dropdown, choose a supported palette, or release a brightness
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
removed with coreutils. No shell scripts, interpolation or direct HID access are
used. Review files are invalidated on service exit; abrupt process termination
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

The header keeps connection status beside the title. Discrete sliders have one
left-hand icon, and eight palette circles share one row; Alt+1 through Alt+8
prepare the corresponding palette review while the panel is open. Random uses
a multicolor SVG because native buttons cannot take an image background.

Ordinary views use a directly measured column rather than a growing root scroll
viewport. The plain native effect dropdown owns its scrolling, selection checkmark and keyboard navigation;
it has no search field or custom clickable overlay. API 43 accepts text options
only, so one shared symbol mapping supplies monochrome effect icons inside both
the trigger and list labels. The 44 px trigger has more breathing room. Popup row padding remains
Noctalia-owned: API 43 exposes no per-row padding or font-size override. The panel is 480 px wide and remains
content-sized; popup placement and screen-edge handling stay native. During refresh, the last
verified sections stay visible but disabled to preserve their measured layout;
an error or disconnect clears them. The first read without cached status still
uses a compact loading view. Very small outputs can clamp the panel; a complete
responsive layout for such outputs has not been physically verified.
