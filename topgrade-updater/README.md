# Topgrade Updater

Pacman/AUR update counts, package lists, and on-demand Topgrade updates in a
terminal. Never upgrades automatically.

## Requirements

- Noctalia plugin API 43 (v5.4.0); `topgrade`, `env`, `flock` (util-linux), `sh`, `mktemp`,
  `stat`, and `id` on Noctalia's `PATH`.
- A supported terminal and a private, user-owned, writable mode-0700
  `XDG_RUNTIME_DIR` that is not a symlink.
- `checkupdates` (`pacman-contrib`) for Pacman counts; `yay` or `paru` for AUR.
  Missing query tools produce unknown results, not zero counts.

API 43 supports the current palette role names and retains content-sized panels:
short states use less space, while expanded package lists scroll within the existing 540 px height limit.
Settings changes use the native service callback to retain timers and active
update tracking. Unsupported `warning` color tokens now explicitly use
`on_surface`, preserving the native fallback color without runtime warnings.

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
| `glyph`              | Empty                                             | Automatic Pacman/gear icon; set a glyph to override        |
| `hide_on_empty`      | `true`                                            | Per-widget hiding for missing/non-positive counts          |

Automatic checks default to every 6 hours, with the first after about 10 seconds;
set `0` to disable them. The automatic icon is Pacman for detected Arch sources,
otherwise a gear; this does not add support for other systems. Existing saved
intervals and glyphs are preserved; clear the glyph to enable automatic selection.
Positive incomplete counts show `?`; a hidden widget does not prove the system
is up to date.

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
- After closing a terminal, the update shortcut can reopen it once the lock is
  clear. Retries revoke the old launch gate under lock; held or unverifiable
  locks never queue another upgrade. An IPC update can supersede a package check.
- Counts refresh after completion and lock release. Exit status does not guarantee
  every step succeeded; the default `-k` waits for Topgrade's final key prompt.
- Do not reload/disable the plugin during an update: service restarts lose run
  tracking. Editing settings preserves tracking; a changed Topgrade config is
  used for the next check or update. Saved commands are not automatically migrated
  to new defaults.
  Topgrade config can override `--notify-end never`; custom steps may notify too.

[MIT license](LICENSE)

Discovery and UI patterns draw on
[nightwatch75's topgrade-wrapper](https://github.com/noctalia-dev/community-plugins/tree/main/topgrade-wrapper)
and [yuuto's arch-updater](https://github.com/noctalia-dev/community-plugins/tree/main/arch-updater).
