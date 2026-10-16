# Topgrade Updater

Pacman/AUR update counts, package lists, and on-demand Topgrade updates in a
terminal. Never upgrades automatically.

## Requirements

- Noctalia plugin API 33; `topgrade`, `env`, `flock` (util-linux), `sh`, `mktemp`,
  `stat`, and `id` on Noctalia's `PATH`.
- A supported terminal and a private, user-owned, writable mode-0700
  `XDG_RUNTIME_DIR` that is not a symlink.
- `checkupdates` (`pacman-contrib`) for Pacman counts; `yay` or `paru` for AUR.
  Missing query tools produce unknown results, not zero counts.

## Usage

Follow the [installation instructions](../README.md#installation), enable
`vantesh/topgrade-updater`, and add **Topgrade Updater** to the bar.

- **Left-click:** open package lists and warnings.
- **Right-click / Refresh:** check for updates.
- **Update:** run the configured command, including all enabled Topgrade steps.
  The panel button requires a positive Pacman/AUR count; IPC does not.
- **Dismiss:** hide until the next accepted refresh; does not cancel work.

Open the panel even when the widget is hidden:

```sh
noctalia msg panel-toggle vantesh/topgrade-updater:panel
```

For service IPC, replace `refresh` with `check` (alias), `update`, or `dismiss`:

```sh
noctalia msg plugin vantesh/topgrade-updater:service all refresh
```

## Settings

| Setting              | Default                                           | Purpose                                                    |
| -------------------- | ------------------------------------------------- | ---------------------------------------------------------- |
| `update_cmd`         | `topgrade -k --no-self-update --notify-end never` | Trusted shell command                                      |
| `terminal_cmd`       | Empty                                             | Auto-detect; otherwise a launch prefix, e.g. `kitty -e`    |
| `topgrade_config`    | Empty                                             | Normal lookup; otherwise append `--config PATH`            |
| `auto_check_hours`   | `6`                                               | Check interval, 0–168 hours; `0` disables automatic checks |
| `notify_on_updates`  | `true`                                            | Notify when automatic checks find updates                  |
| `show_download_size` | `true`                                            | Estimated Pacman archive sizes, not remaining traffic      |
| `glyph`              | `pacman`                                          | Per-widget icon                                            |
| `hide_on_empty`      | `true`                                            | Per-widget hiding for missing/non-positive counts          |

Automatic checks start about 10 seconds after service startup. Positive but
incomplete counts show `?`; a hidden widget does not prove the system is up to date.
Move any old global `glyph`/`hide_on_empty` overrides into widget settings.

## Safety and limitations

- **Counts cover Pacman/AUR; updates run the full configured command.** Discovery
  parses Topgrade dry-run output, so unsupported commands or warnings can leave
  counts incomplete. Checks may access the network and tool-owned caches.
- Commands, terminal prefixes, and Topgrade configuration/hooks are trusted code,
  not sandboxed. Custom update commands must accept an appended `--config PATH`
  when selected; terminal prefixes must include any required separator.
- Updates use `$XDG_RUNTIME_DIR/noctalia-topgrade.lock`. This only coordinates
  cooperating commands, not independently launched package managers. Never delete
  the lock file to unlock it. Descendants retaining the lock keep updates blocked.
- Checks and updates are blocked while busy or recovering a lock. Counts refresh
  after completion and lock release. Exit status does not guarantee every step
  succeeded; the default `-k` waits for Topgrade's final key prompt.
- Do not reload/disable the plugin during an update: service restarts lose run
  tracking. Saved commands are not automatically migrated to new defaults.
  Topgrade config can override `--notify-end never`; custom steps may notify too.

[MIT license](LICENSE)

Discovery and UI patterns draw on
[nightwatch75's topgrade-wrapper](https://github.com/noctalia-dev/community-plugins/tree/main/topgrade-wrapper)
and [yuuto's arch-updater](https://github.com/noctalia-dev/community-plugins/tree/main/arch-updater).
