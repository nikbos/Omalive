# OmaLive

<img width="2560" height="1440" alt="screenshot-2026-08-24_03-03-09" src="https://github.com/user-attachments/assets/ae2e017c-7fef-4df4-a732-92f8384cc7e4" />


A macOS Sonoma-style **Aerial screensaver** and **live wallpaper** for Omarchy 4
(Quickshell / Hyprland).

- **Screensaver** — when the system is idle, fullscreen aerial footage plays
  above everything (cursor hidden, like the stock ttfx screensaver).
- **Live lock screen** — the lock screen plays the aerial footage too (macOS
  Sonoma style): locking resumes the footage exactly where it was, it keeps
  drifting while locked, and on unlock the wallpaper freezes on the exact
  frame the lock last showed. Provided by the companion `OmaLiveLock` plugin
  (own repository), a fork of the stock `omarchy.lock`.
- **Sonoma freeze transition** — when you dismiss it (or after unlocking), the
  footage **decelerates to a stop** over ~2 seconds and the desktop wallpaper
  becomes the **exact frozen frame** where the footage stopped.
- **Live wallpaper** — optionally keep the wallpaper slowly drifting instead of
  freezing (`omalive live on`).
- **Multi-monitor** — one clip per screen or one clip everywhere.
- **No daemon, no systemd unit** — it is one `omarchy-shell` plugin doing the
  rendering, idle detection, transition and state persistence.

## Install

```bash
git clone <this-repo> ~/Projects/omalive/OmaLive
~/Projects/omalive/OmaLive/install.sh
```

The installer installs dependencies (`qt6-multimedia`, `jq`, `python3`),
suppresses the stock ttfx screensaver so OmaLive owns idle, adds the plugin,
installs the `omalive` CLI, installs and enables the companion `OmaLiveLock`
lock screen, and restarts the shell.

To install only the plugin (no extras), review the exact commit you are about
to run and register the plugin from that **local checkout** — never from a
moving remote branch. `omarchy plugin add` executes the code as an unsandboxed
plugin, so pin to a reviewed commit:

```bash
# review the pinned commit first, then add the local checkout (git clone of a
# local dir copies exactly the checked-out commit — nothing newer)
git clone https://github.com/nikbos/Omalive ~/Projects/omalive/OmaLive
git -C ~/Projects/omalive/OmaLive checkout 68091e3fb555b740c91d05694080871cec1c93a4
omarchy plugin add ~/Projects/omalive/OmaLive --enable
omarchy restart shell
```

The companion lock screen is a separate plugin in its own repository
([`nikbos/OmaLiveLock`](https://github.com/nikbos/OmaLiveLock)). Review and add
it from a pinned local checkout the same way — do not `plugin add` an unpinned
remote URL:

```bash
git clone https://github.com/nikbos/OmaLiveLock ~/Projects/omalive/OmaLiveLock
# review the checked-out commit, then:
omarchy plugin add ~/Projects/omalive/OmaLiveLock --enable
omarchy restart shell
```

> **Locked?** The installer and `omarchy plugin add/update` refuse or should be
> avoided while the session is locked: writing into the plugin folder hot-reloads
> the shell and tears down the active lock screen. Unlock first.

## Quick start

```bash
omalive fetch                          # download aerial-style clips to ~/Videos/Aerial
omalive play ~/Videos/Aerial/clip.mp4  # play everywhere
omalive screensaver start              # preview the screensaver now
omalive freeze                         # glide to a stop; frozen frame becomes the wallpaper
omalive status
```

## CLI

| Command | What it does |
|---|---|
| `omalive status` | Current state, per monitor |
| `omalive play <file> [screen]` | Play a clip everywhere, or on one monitor |
| `omalive off <screen>` | Blank one monitor |
| `omalive freeze` | Decelerate to a stop; the frozen frame is the wallpaper |
| `omalive flourish` | Play from the frozen frame, then glide to a stop |
| `omalive screensaver <on\|off\|start\|stop\|status>` | Control the screensaver |
| `omalive live <on\|off>` | Live wallpaper (keeps drifting) vs frozen frame |
| `omalive transition <seconds>` | Length of the freeze transition (1–10) |
| `omalive autopause <on\|off>` | Pause under fullscreen windows |
| `omalive shuffle <on\|off>` | Rotate clips while the screensaver is up |
| `omalive fetch [dest]` | Download aerial-style clips |

## Bar widget

Click the film glyph in the bar for the control panel: clip library, per-screen
assignment, screensaver toggle, live-wallpaper toggle, transition length, and
transport (Play / Freeze / Screensaver). Right-click the icon to flip between
playing and frozen.

## Keybinds

Add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + W", "OmaLive toggle", "omalive toggle")
o.bind("SUPER + ALT + V", "OmaLive panel", "omarchy-shell shell toggle omalive")
```

## Configuration

All options live in `~/.config/omarchy/shell.json` under a `plugins[]` entry
(optional; defaults apply without it):

```json
{ "id": "omalive",
  "videoPath": "~/Videos/Aerial/any.mp4",
  "screenVideos": { "DP-1": "~/Videos/Aerial/a.mp4", "DP-2": "" },
  "videoDir": "~/Videos/Aerial",
  "transitionSeconds": 2,
  "pauseOnFullscreen": true,
  "liveWallpaper": false,
  "shuffle": true,
  "flourishOnLogin": true }
```

Runtime changes from the panel/CLI persist to `~/.local/state/omalive/state.json`
and survive restarts — no autostart step.

## Videos

Apple's Aerial footage is copyrighted and too large to bundle, so OmaLive plays
whatever is in the video folder (default `~/Videos/Aerial`, scanned at startup
for shuffle). `omalive fetch` downloads a small starter set of openly-licensed
aerial drone clips from Wikimedia Commons. Drop in your own `.mp4` / `.mkv` /
`.webm` / `.mov` / `.avi` files — the panel and shuffle pick them up.

## Live lock screen (OmaLiveLock)

`install.sh` also installs and enables the companion `OmaLiveLock` plugin from
its own repository ([`nikbos/OmaLiveLock`](https://github.com/nikbos/OmaLiveLock))
— a fork of the stock `omarchy.lock` that plays the OmaLive aerial footage on
the lock screen:

- Locking resumes the footage exactly where it was (screensaver or wallpaper)
  and keeps it playing behind the stock password UI with a light scrim.
- While locked, the lock surfaces sample their playback position; on unlock it
  is handed back to OmaLive, which parks the wallpaper on the exact frame the
  lock last showed and then runs the usual login flourish from there.
- Fallback: with OmaLive disabled, no clip assigned, or a player error, the
  lock shows the stock blurred wallpaper — it never degrades to a broken
  surface.

The manifest declares `omarchy.clonedFrom: omarchy.lock`, so enabling
`omalive-lock` automatically disables the stock lock; disable or remove it to
get the stock lock back:

```bash
omarchy plugin disable omalive-lock   # restores the stock lock screen
omarchy plugin enable omalive-lock    # back to the live aerial lock
```

## License

MIT# Omalive
