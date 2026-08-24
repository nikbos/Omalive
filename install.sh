#!/usr/bin/env bash
# ==============================================================================
# OmaLive installer for Omarchy 4 (Quickshell / omarchy-shell).
#
# The plugin itself is installed the supported way — `omarchy plugin add`, which
# clones this repo into ~/.config/omarchy/plugins/ and registers it. This script
# is a convenience wrapper around that plus the extras a plugin repo cannot
# carry on its own:
#
#   ~/.config/omarchy/plugins/omalive/                 the plugin (git clone)
#   ~/.local/bin/omalive                               CLI control
#   ~/.local/bin/omalive-fetch                         clip downloader
#   ~/.local/state/omarchy/toggles/screensaver-off     suppresses the stock
#                                                      ttfx screensaver so
#                                                      OmaLive owns idle
#
# If you only want the plugin, skip this script entirely:
#   omarchy plugin add <url> --enable
#
# Dependencies: qt6-multimedia (video decode), jq, python3, hyprland.
# The shell plugin does the rendering, idle detection, transition and state
# persistence itself — no external daemon, watcher or systemd unit.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="omalive"
CLI_SRC="$SCRIPT_DIR/omalive"
FETCH_SRC="$SCRIPT_DIR/fetch.sh"
PLUGINS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
PLUGIN_DIR="$PLUGINS_DIR/$PLUGIN_ID"

echo "=== OmaLive installer (Omarchy 4 / Quickshell) ==="

if ! command -v pacman >/dev/null 2>&1; then
  echo "This installer expects a pacman-based system (Arch/Omarchy)." >&2
  exit 1
fi

if ! command -v omarchy-shell >/dev/null 2>&1 || ! command -v omarchy-plugin-add >/dev/null 2>&1; then
  cat >&2 <<MSG
ERROR: omarchy-shell / omarchy-plugin-add not found on PATH.
OmaLive requires Omarchy 4+.
MSG
  exit 1
fi

# ----- lock guard -----------------------------------------------------------
# Any write under ~/.config/omarchy/plugins trips omarchy-shell's inotify
# watcher, which reloads ALL plugin services — including the lock screen
# holding the active session lock — and the in-process re-lock can hang,
# stranding the session behind Hyprland's failsafe. omarchy-restart-shell
# refuses for the same reason; this installer must too, before it touches the
# plugin directory (its copy/clone steps would otherwise reload mid-lock well
# before the guarded restart at the end).
if [[ "$(omarchy-shell lock isLocked 2>/dev/null)" == "true" ]]; then
  cat >&2 <<MSG
ERROR: Refusing to install/update OmaLive while the session is locked.
Writing plugin files hot-reloads the shell and would tear down the lock
screen (and can strand you behind Hyprland's failsafe with no way in but a
reboot). Unlock first, then re-run this installer.
MSG
  exit 1
fi

for f in "$SCRIPT_DIR/manifest.json" "$SCRIPT_DIR/Service.qml" \
         "$SCRIPT_DIR/BarWidget.qml" "$SCRIPT_DIR/Panel.qml" \
         "$SCRIPT_DIR/WallpaperSurface.qml" "$SCRIPT_DIR/ScreensaverSurface.qml" \
         "$CLI_SRC" "$FETCH_SRC" "$SCRIPT_DIR/optimize.sh"; do
  [ -f "$f" ] || { echo "Missing installer asset: $f" >&2; exit 1; }
done

# ----- dependencies -----------------------------------------------------------
MISSING_PKGS=()
command -v jq       >/dev/null 2>&1 || MISSING_PKGS+=("jq")
command -v python3  >/dev/null 2>&1 || MISSING_PKGS+=("python")
command -v hyprctl  >/dev/null 2>&1 || MISSING_PKGS+=("hyprland")
pacman -Qq qt6-multimedia >/dev/null 2>&1 || MISSING_PKGS+=("qt6-multimedia")

if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
  echo "Installing required packages: ${MISSING_PKGS[*]}"
  sudo pacman -S --needed "${MISSING_PKGS[@]}"
else
  echo "✓ Dependencies present (qt6-multimedia, jq, python3, hyprland)"
fi

# ----- suppress the stock ttfx screensaver -----------------------------------
# omarchy-launch-screensaver exits early when this toggle exists, so BOTH the
# hypridle path and omarchy's idle service stop launching ttfx. OmaLive's own
# IdleMonitor then owns the screensaver. The user can still flip the stock
# toggle (it only affects stock; OmaLive ignores it) — use `omalive screensaver
# on|off` to control OmaLive's screensaver.
TOGGLES="$HOME/.local/state/omarchy/toggles"
mkdir -p "$TOGGLES"
if [ ! -f "$TOGGLES/screensaver-off" ]; then
  touch "$TOGGLES/screensaver-off"
  echo "✓ Disabled the stock ttfx screensaver (OmaLive now owns idle)"
else
  echo "✓ Stock screensaver toggle already set"
fi

# ----- install the plugin -----------------------------------------------------
interactive() { [ -t 0 ] && [ -t 1 ]; }
PLACEMENT_CHOSEN=0

install_plugin() {
  if [ "$SCRIPT_DIR" = "$PLUGIN_DIR" ]; then
    echo "✓ Running from the installed plugin — leaving it alone"
    omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || true
    return
  fi

  if [ -e "$PLUGIN_DIR" ] || [ -L "$PLUGIN_DIR" ]; then
    if [ -d "$PLUGIN_DIR/.git" ]; then
      echo "✓ Plugin already installed as a git checkout"
      echo "  Update it with: omarchy plugin update $PLUGIN_ID"
      return
    fi
    if [ -L "$PLUGIN_DIR" ]; then
      echo "✓ Plugin is a dev symlink — leaving it alone"
      return
    fi
    if [ -f "$PLUGIN_DIR/manifest.json" ] &&
       [ "$(jq -r '.id // ""' "$PLUGIN_DIR/manifest.json")" = "$PLUGIN_ID" ]; then
      echo "→ Replacing a legacy copy-install with a git checkout (so updates work)"
      rm -rf "$PLUGIN_DIR"
    else
      echo "⚠️  $PLUGIN_DIR exists and is not this plugin — leaving it alone." >&2
      return
    fi
  fi

  local url
  url="$(git -C "$SCRIPT_DIR" remote get-url github 2>/dev/null \
      || git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null \
      || echo "$SCRIPT_DIR")"
  echo "→ Adding the plugin from $url"
  if interactive; then
    omarchy plugin add "$url" --enable
    PLACEMENT_CHOSEN=1
  else
    omarchy plugin add "$url" --enable --yes
  fi
}
install_plugin

place_widget() {
  if (( PLACEMENT_CHOSEN )); then return 0; fi
  local want current
  want="$(jq -r '.barWidget.defaultSection // "center"' "$SCRIPT_DIR/manifest.json")"
  current="$(jq -r --arg id "$PLUGIN_ID" '
      .bar.layout // {} | to_entries[]
      | select(.value | any(.id == $id)) | .key' \
      "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json" 2>/dev/null || true)"
  [ -n "$current" ] || return 0
  [ "$current" != "$want" ] || return 0
  omarchy bar move "$PLUGIN_ID" --section "$want" >/dev/null 2>&1 &&
    echo "✓ Moved the bar widget to the $want section"
}
place_widget

# ----- install the OmaLive lock screen plugin ---------------------------------
# OmaLiveLock is a fork of the first-party omarchy.lock that plays the OmaLive
# aerial footage on the lock screen (Sonoma style). It lives in its own
# repository (one plugin per repo is the marketplace rule). Its manifest
# declares omarchy.clonedFrom = omarchy.lock, so ENABLING it automatically
# DISABLES the stock lock screen, and disabling/removing it restores the stock
# lock.
LOCK_PLUGIN_ID="omalive-lock"
LOCK_URL="https://github.com/nikbos/OmaLiveLock"
LOCK_DIR="$PLUGINS_DIR/$LOCK_PLUGIN_ID"

install_lock_plugin() {
  if [ -L "$LOCK_DIR" ]; then
    echo "✓ Lock plugin is a dev symlink — leaving it alone"
    return
  fi
  if [ -e "$LOCK_DIR" ]; then
    if [ -d "$LOCK_DIR/.git" ]; then
      echo "✓ Lock plugin already installed as a git checkout"
      echo "  Update it with: omarchy plugin update $LOCK_PLUGIN_ID"
      return
    fi
    if [ -f "$LOCK_DIR/manifest.json" ] &&
       [ "$(jq -r '.id // ""' "$LOCK_DIR/manifest.json")" = "$LOCK_PLUGIN_ID" ]; then
      echo "→ Replacing a legacy copy-install of $LOCK_PLUGIN_ID with a git checkout"
      rm -rf "$LOCK_DIR"
    else
      echo "⚠️  $LOCK_DIR exists and is not $LOCK_PLUGIN_ID — leaving it alone." >&2
      return
    fi
  fi

  echo "→ Adding the lock plugin from $LOCK_URL"
  if interactive; then
    omarchy plugin add "$LOCK_URL" --enable
  else
    omarchy plugin add "$LOCK_URL" --enable --yes
  fi
}
install_lock_plugin

# ----- point the Omarchy menu "Screensaver" row at OmaLive -------------------
# The stock row runs `omarchy-launch-screensaver force`, which bypasses the
# screensaver-off toggle. Override it per-key so the menu starts the OmaLive
# aerial screensaver instead. Idempotent: never touches the row once present.
MENU_EXT="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
mkdir -p "$(dirname "$MENU_EXT")"
python3 - "$MENU_EXT" <<'PY'
import sys, os
p = sys.argv[1]
override = '  "system.screensaver": { "action": "omarchy-shell omalive screensaver start" },'
if os.path.exists(p):
    s = open(p).read()
    if '"system.screensaver"' in s:
        print("✓ Menu Screensaver row already overridden")
        sys.exit(0)
    idx = s.rstrip().rfind('}')
    if idx < 0:
        s = s.rstrip() + '\n' + override[:-1] + '\n}\n'
    else:
        s = s[:idx] + override + '\n' + s[idx:]
else:
    s = '{\n  // OmaLive: the System > Screensaver row launches the aerial screensaver.\n' + override + '\n}\n'
open(p, 'w').write(s)
print("✓ Overrode the menu Screensaver row to start OmaLive")
PY

# ----- install the CLI + fetch/optimize helpers -------------------------------
install -D -m 755 "$CLI_SRC" "$HOME/.local/bin/omalive"
install -D -m 755 "$FETCH_SRC" "$HOME/.local/bin/omalive-fetch"
install -D -m 755 "$SCRIPT_DIR/optimize.sh" "$HOME/.local/bin/omalive-optimize"
echo "✓ CLI installed to ~/.local/bin/omalive"

# ----- load the plugin now ----------------------------------------------------
echo
echo "Restarting omarchy-shell to load the plugin…"
omarchy-restart-shell >/dev/null 2>&1 || \
  echo "⚠️  Restart omarchy-shell manually to load the plugin (omarchy-restart-shell)."
echo "✓ Shell restarted"

# ----- done -------------------------------------------------------------------
cat <<EOF

=== Install complete ===

✓ Bar widget added — click the film icon in the bar for the control panel
✓ CLI: omalive  (scripting / keybinds)
✓ Stock ttfx screensaver disabled; OmaLive owns the idle screensaver

Quick start:
  omalive fetch                  # download aerial-style clips to ~/Videos/Aerial
  omalive play ~/Videos/Aerial/any.mp4
  omalive status
  omalive screensaver start      # preview the screensaver now
  omalive freeze                 # glide to a stop; frozen frame is the wallpaper

The frozen wallpaper resumes automatically after reboot — no autostart step.

Optional keybind — Omarchy 4 keeps user binds in ~/.config/hypr/bindings.lua:
  o.bind("SUPER + ALT + W", "OmaLive toggle", "omalive toggle")
  o.bind("SUPER + ALT + V", "OmaLive panel", "omarchy-shell shell toggle omalive")

Updating later:  omarchy plugin update $PLUGIN_ID
Removing:        omarchy plugin remove $PLUGIN_ID

Logs: ~/.cache/omalive.log
EOF

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo
  echo "⚠️  ~/.local/bin is not in your PATH. Add: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi