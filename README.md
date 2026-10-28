# Noctalia Plugins

Personal plugins for [Noctalia Shell](https://noctalia.dev), targeting plugin API 43
(Noctalia v5.4.0).

| Plugin           | Purpose                                          | Branch                  |
| ---------------- | ------------------------------------------------ | ----------------------- |
| Hyprbinds        | Read-only Hyprland Lua keybindings cheatsheet    | `feat/hyprbinds`        |
| Topgrade Updater | Pacman/AUR counts and on-demand Topgrade updates | `feat/topgrade-updater` |
| AULA F75         | Guarded wired keyboard lighting controls        | `feat/aula-f75-controls` |

## Installation

Until the plugins are merged into `main`, use the desired branch as a local source:

```sh
git clone --branch feat/hyprbinds https://github.com/Vantesh/noctalia-plugins.git
noctalia msg plugins source add noctalia-plugins path /absolute/path/to/noctalia-plugins
noctalia msg plugins enable vantesh/hyprbinds
```

For Topgrade Updater, use `feat/topgrade-updater` and enable
`vantesh/topgrade-updater`. The source path must point at the checkout root.
Each plugin's README lists its requirements and settings.

Once merged, use the Git source instead:

```sh
noctalia msg plugins source add noctalia-plugins git https://github.com/Vantesh/noctalia-plugins
```

`catalog.toml` is generated after merges to `main`; the PR check rejects changes
to it. Edit `plugin.toml` instead. For a local preview, run
`python3 .github/scripts/update-catalog.py` (Python 3.11+); keep the output out of PRs.

## Local validation

Run the existing tests for the plugin in your checkout:

```sh
(cd hyprbinds && lua tests/parser-fresh.lua && lua tests/fonts.lua && lua tests/ui.lua)
```

```sh
lua topgrade-updater/tests/run.lua &&
lua topgrade-updater/tests/completion.lua &&
lua topgrade-updater/tests/notifications.lua &&
lua topgrade-updater/tests/panel.lua &&
lua topgrade-updater/tests/sources.lua &&
lua topgrade-updater/tests/widget.lua
```

Then run `noctalia plugins lint .`, `luau-compile --null` on the plugin's `.luau`
files, and `git diff --check`. Tests require Lua 5.4+; Topgrade subprocess tests
also use Linux, POSIX utilities, and util-linux `flock`. Tests use mocks and
harmless fixtures, not real upgrades.

## License

[MIT](LICENSE). See each plugin for additional notices and attribution.
