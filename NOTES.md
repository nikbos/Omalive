# OmaLive — implementation notes

How OmaLive works, and why it is shaped the way it is. Written for the next
person maintaining it.

## What it does

macOS Sonoma ships an "Aerial" screensaver whose footage, on login, decelerates
and freezes into the desktop wallpaper. OmaLive reproduces that on omarchy 4:

1. **Screensaver** — fullscreen footage above all windows when idle.
2. **Login flourish** — at session start / after unlock the wallpaper footage
   plays briefly, then decelerates to a stop (`transitionSeconds`, default 2s).
3. **Frozen wallpaper** — the desktop wallpaper is the exact frame where the
   footage stopped, persisted so it survives reboot.
4. **Optional live mode** — `liveWallpaper: true` keeps the wallpaper slowly
   drifting instead of freezing.

## Rendering

Two `PanelWindow` layer-shell surfaces per monitor (in `WallpaperSurface.qml`
and `ScreensaverSurface.qml`):

- **Background** layer (`omalive-background`) — the wallpaper. Normally a paused
  `MediaPlayer` at the frozen frame. Driven by `playRequest`, `rate`, `blocked`
  (fullscreen auto-pause) and `opacityVisible` bindings from the service.
- **Overlay** layer (`omalive-screensaver`) — the screensaver. Black surface,
  `keyboardFocus: None`, no interactive region, so input passes through to the
  compositor and IdleMonitor still sees activity.

Both play the same clip, so the frozen frame hands off seamlessly. On screensaver
dismissal the overlay player's position is captured and the wallpaper player is
seeded to it before parking.

Surfaces register/unregister with the service root (`register*Surface`), which
commands them by reference. No A/B double-buffer yet — clip *switching* can
briefly blink the static wallpaper through (fine; a clip change is rare). The
Motion-Wallpaper reference has the A/B pattern if that ever matters.

## Idle integration

- Uses `IdleMonitor` (`Quickshell.Wayland`) exactly like omarchy's own idle
  service, with the timeout from `shell.json idle.screensaver` (default 150s).
- The stock ttfx screensaver is suppressed at install by writing the omarchy
  `screensaver-off` toggle; `omarchy-launch-screensaver` then exits early from
  both the hypridle path and omarchy's idle service. OmaLive owns idle.
- OmaLive's own screensaver is gated by `omalive-screensaver-off` (a toggle flag
  written by `omalive screensaver on|off`), plus omarchy's `stay-awake`
  indicator. The stock `screensaver-off` flag is ignored by OmaLive.
- `IdleMonitor` flicker on screensaver start is debounced (300ms) before
  dismissal.
- The lock is polled every 3s (`omarchy-shell lock isLocked`). On lock the
  screensaver yields immediately; on unlock the login flourish runs.

## Deceleration

`decelTick` advances a 0→1 progress and sets `playbackRate = (1-t)^3`
(ease-out — starts fast, glides to a stop, the Sonoma feel) on the target
surface set. On completion the frozen frame is captured and parked.

## Live lock screen (OmaLiveLock)

The lock screen is a separate plugin in its own repository
(`nikbos/OmaLiveLock`; the marketplace rule is one plugin per repository) — a
fork of the first-party `omarchy.lock` service (only the blocks marked
"OmaLive" differ; keep the rest in sync with upstream). Its manifest carries
`omarchy.clonedFrom: omarchy.lock`, which makes the registry auto-disable the
stock lock when it is enabled and restore the stock lock when it is disabled
or removed (see `PluginRegistry.setEnabled`). Both register the same `lock`
IPC target, so only one of them may be enabled at a time.

Continuity flow (all in-process, same Quickshell instance):

1. `beginLock()` — the lock service reads the current playback positions off
   the OmaLive service (`positionsObject()`: live screensaver surfaces first,
   then wallpaper surfaces, then the persisted frozen frames) and stores them
   as the per-screen seek targets.
2. `LockView.qml` — stock password UI with a muted, looping `MediaPlayer`
   behind it. The clip is `omalive.urlForScreen(name)` (per-monitor overrides
   work; `WlSessionLockSurface.screen` supplies the output), seeked to the
   captured position, then playing while locked. A 0.22 black scrim keeps the
   UI readable. No clip / player error → stock blurred wallpaper fallback.
3. While locked, each lock surface samples `player.position` every 250ms and
   reports it to the lock service (`recordLockPosition`).
4. `finishUnlock()` — BEFORE releasing the session lock, the sampled positions
   are handed to OmaLive (`applyLockHandoff`, exposed as IPC too). OmaLive
   validates the payload the same way as state.json (byte cap +
   `normalizeScreenPositions`), updates `screenPositions`/`frozenPosition`,
   parks the wallpaper surfaces on those exact frames and persists. The
   existing unlock poll (≤3s) then runs the login flourish from there — the
   Sonoma glide-to-stop.

The ordering is race-free: `omarchy-shell lock isLocked` only flips after
`finishUnlock()` clears `lockRequested`/`sessionLock.locked`, and the handoff
runs before that, so OmaLive's poll can never observe "unlocked" before the
handoff landed.

Security notes: the fork keeps the stock PAM gate (`beginLock` refuses without
`/etc/pam.d/omarchy-lock-password`), the real lock stays on the
`ext-session-lock-v1` protocol (never layer-shell), and the OmaLive hooks can
only park wallpaper frames — they cannot unlock. The one genuine risk point is
video decode on session-lock surfaces under Hyprland; the image fallback
covers a failing player.

## State & security

Mirrors Motion-Wallpaper's hardening: 256KB byte cap before `JSON.parse`, path
length caps, per-field length caps, entry caps on `screenVideos`/
`screenPositions`, `timeout` on every subprocess, atomic state writes
(`mktemp` + `mv`), and `textFormat: Text.PlainText` on every text that renders
hostile (file name) input. `Model.js` holds the pure, unit-tested helpers.

## Screensaver trigger summary

| Path | Before | After install |
|---|---|---|
| hypridle 150s | `omarchy-launch-screensaver` (ttfx) | exits early (screensaver-off) |
| omarchy idle service 150s | `omarchy-launch-screensaver` (ttfx) | exits early |
| OmaLive IdleMonitor 150s | — | shows the aerial overlay |

## Installing / updating / removing

Two repositories, one plugin each (the marketplace rule):
`nikbos/Omalive` (this repo, the screensaver/wallpaper) and
`nikbos/OmaLiveLock` (the lock screen companion).

- `omarchy plugin add <url> --enable` clones the repo — **never copy files**;
  copies can't be updated.
- `omarchy plugin update omalive`; `omarchy plugin update omalive-lock`;
  `omarchy plugin remove omalive`; `omarchy plugin remove omalive-lock`.
- `install.sh` additionally installs the CLI (`~/.local/bin/omalive`) and
  `omalive-fetch`, sets the `screensaver-off` toggle, installs/enables the
  lock-screen plugin from `nikbos/OmaLiveLock`, and restarts the shell.
- **Hard rule: never write into `~/.config/omarchy/plugins/` while the session
  is locked.** The shell watches that directory with inotify, and *any* file
  change reloads ALL plugin services — including the lock screen holding the
  active session lock. The in-process re-lock can hang, stranding the session
  behind Hyprland's failsafe with no way back in but a reboot. This includes
  `omarchy plugin update`, raw `cp`, and editor writes. `omarchy-restart-shell`
  refuses while locked for the same reason — the file watcher has no such
  guard. `install.sh` now refuses too.
- Dev loop (this is how the live install is set up — symlinks, never copies):
  ```bash
  rm -rf ~/.config/omarchy/plugins/omalive ~/.config/omarchy/plugins/omalive-lock
  ln -s /path/to/Omalive/checkout      ~/.config/omarchy/plugins/omalive
  ln -s /path/to/OmaLiveLock/checkout  ~/.config/omarchy/plugins/omalive-lock
  omarchy restart shell
  ```
  Symlinks *inside* the plugin folder are rejected by validation, but a
  symlinked folder is fine. The inotify watcher does not follow the symlink, so
  editing in the checkouts triggers nothing — reloads only happen when you run
  `omarchy-restart-shell` (safe: it refuses while locked). After QML edits:
  `omarchy-restart-shell`. Never `omarchy-refresh-shell` — it resets
  `shell.json`.

## Known limits / next steps

- No A/B clip cross-fade yet (see Rendering).
- Per-monitor frozen positions are persisted, but the default clip's frozen
  position is shared across monitors that have no override.
- `shuffle` rotates the default clip while the screensaver is up, but does not
  shuffle per-monitor overrides.
- The settings UI (schema) is not used — service options live in the
  `plugins[]` config entry / `state.json` and are changed via the panel or CLI,
  matching the Motion-Wallpaper model.
- Lock handoff samples the lock player positions every 250ms, so the unlocked
  wallpaper can land up to ~250ms behind the true last frame (imperceptible in
  practice; a last-millisecond sample would need a signal handshake).
- The lock plays the footage at normal rate; no idle "pause the lock video"
  yet — the stock 5s display blank covers the power side.