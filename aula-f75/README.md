# AULA F75

Read-only lighting status for an AULA F75 connected over USB. Shows the active
effect, brightness, speed and palette reported by [aulaf75ctl](https://github.com/Vantesh/aulaf75ctl).
Self-defined lighting is kept separate from its stored native-effect selection.

Requires Noctalia v5 with Plugin API 42 (native content-sized panels), plus a
current schema-1 `aulaf75ctl` with `configuration.active_effect`. Install the CLI
on the PATH visible to Noctalia. The plugin never uses a development build path.
Close F75 Studio and other keyboard controllers before refreshing.

Register this checkout as a local plugin source, then enable:

```sh
noctalia msg plugins source add noctalia-plugins path /absolute/path/to/noctalia-plugins
noctalia msg plugins enable vantesh/aula-f75
```

Add the AULA F75 widget through the bar editor, or search **AULA F75** in the
launcher. The panel refreshes on opening and has a manual Refresh action. There
is no polling, persistent cache or automatic retry. CLI requests use a five-second
timeout; a failed refresh clears the displayed settings.

Only `aulaf75ctl status --transport wired --json` is invoked, directly without a
shell. Wireless/Bluetooth control and all lighting changes are outside this plugin.
Brightness (0–9) and speed (0–4) are firmware levels, not percentages; unavailable
values stay unavailable. A successful readback does not verify visible LEDs.

Run the focused tests from the checkout root:

```sh
lua aula-f75/tests/status.lua
lua aula-f75/tests/ui.lua
noctalia plugins lint aula-f75
```

MIT — see [LICENSE](../LICENSE). Hardware interpretation and protocol attribution
remain with the standalone backend; no AULA protocol is implemented here.
