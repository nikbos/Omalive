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
# If you only want the plugin, skip this script entirely. `omarchy plugin add`
# executes plugin code unsandboxed, so add it from a reviewed, pinned local
# checkout — never from a moving remote URL:
#   git clone https://github.com/nikbos/Omalive ~/Projects/omalive/OmaLive
#   git -C ~/Projects/omalive/OmaLive checkout <full-commit-sha>
#   omarchy plugin add ~/Projects/omalive/OmaLive --enable
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

  # Register the plugin from THIS local checkout, not from a moving remote
  # branch. `omarchy plugin add` runs the plugin's code unsandboxed, and a git
  # clone of a local dir copies exactly the reviewed commit that's checked out
  # here — pinning installs to a reproducible, auditable state.
  echo "→ Adding the plugin from the reviewed checkout $SCRIPT_DIR"
  if interactive; then
    omarchy plugin add "$SCRIPT_DIR" --enable
    PLACEMENT_CHOSEN=1
  else
    omarchy plugin add "$SCRIPT_DIR" --enable --yes
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
LOCK_DIR="$PLUGINS_DIR/$LOCK_PLUGIN_ID"
# Path to a REVIEWED local checkout of nikbos/OmaLiveLock to install from
# (override with OMALIVE_LOCK_SRC). Never a moving remote URL.
LOCK_SRC="${OMALIVE_LOCK_SRC:-$HOME/Projects/omalive/OmaLiveLock}"

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

  # Install the lock plugin from a REVIEWED local checkout only. `omarchy
  # plugin add` runs unsandboxed code, so we never silently clone a moving
  # remote branch (see README "Install"): the user reviews a pinned checkout
  # of nikbos/OmaLiveLock first and adds that directory.
  if [ -d "$LOCK_SRC/.git" ] || [ -d "$LOCK_SRC" ]; then
    echo "→ Adding the lock plugin from the reviewed checkout $LOCK_SRC"
    if interactive; then
      omarchy plugin add "$LOCK_SRC" --enable
    else
      omarchy plugin add "$LOCK_SRC" --enable --yes
    fi
  else
    cat >&2 <<MSG

⚠️  Skipping the OmaLive lock screen plugin.

The companion lock plugin lives in its own repository (nikbos/OmaLiveLock). To
stay safe it is only installed from a local, reviewed checkout — never from an
unpinned remote. Add it separately:

    git clone https://github.com/nikbos/OmaLiveLock ~/Projects/omalive/OmaLiveLock
    git -C ~/Projects/omalive/OmaLiveLock checkout 9f160be35a0d15eede0f4cb0f63d9a4c1d20933d
    # review the checked-out commit, then:
    omarchy plugin add ~/Projects/omalive/OmaLiveLock --enable

MSG
  fi
}
install_lock_plugin

# ----- point the Omarchy menu "Screensaver" row at OmaLive -------------------
# The stock row runs `omarchy-launch-screensaver force`, which bypasses the
# screensaver-off toggle. Override it per-key so the menu starts the OmaLive
# aerial screensaver instead. Idempotent: never touches the row once present.
# Reads and writes are descriptor-bound: the existing file is read through an
# O_NOFOLLOW descriptor (refusing a symlink), and the new content is written to
# a fresh temp file and atomically renamed over the target — a pre-existing
# symlink is replaced, never written through.
MENU_EXT="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
mkdir -p "$(dirname "$MENU_EXT")"
python3 - "$MENU_EXT" <<'PY'
import sys, os, stat, tempfile
p = sys.argv[1]
override = '  "system.screensaver": { "icon": "󱄄", "label": "Screensaver", "action": "omarchy-shell omalive screensaver start" },'

def read_refusing_symlink(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size > 1048576:
            raise OSError("refusing non-regular, foreign, or oversized menu file")
        return os.read(fd, 1048576).decode("utf-8", "replace")
    finally:
        os.close(fd)

def write_atomic(path, s):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(s)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

try:
    if os.path.lexists(p):
        s = read_refusing_symlink(p)
        if '"system.screensaver"' in s:
            print("✓ Menu Screensaver row already overridden")
            sys.exit(0)
        idx = s.rstrip().rfind("}")
        if idx < 0:
            s = s.rstrip() + "\n" + override[:-1] + "\n}\n"
        else:
            s = s[:idx] + override + "\n" + s[idx:]
    else:
        s = '{\n  // OmaLive: the System > Screensaver row launches the aerial screensaver.\n' + override + '\n}\n'
    write_atomic(p, s)
    print("✓ Overrode the menu Screensaver row to start OmaLive")
except OSError as e:
    print("✗ Could not update the menu extension:", e)
    sys.exit(1)
PY

# ----- install the CLI + fetch/optimize helpers -------------------------------
# Each helper is installed to a fresh temp file and then renamed into place, so
# a pre-existing symlink at the final path is replaced, never written through.
install_helper() {
  local src="$1" dest="$2" dir tmp
  dir="$(dirname "$dest")"
  mkdir -p -- "$dir"
  tmp="$(mktemp "$dir/.omalive-install.XXXXXX")" || { echo "could not stage $dest" >&2; return 1; }
  install -m 755 "$src" "$tmp" && mv -f "$tmp" "$dest" && return 0
  rm -f -- "$tmp"
  return 1
}
install_helper "$CLI_SRC" "$HOME/.local/bin/omalive"
install_helper "$FETCH_SRC" "$HOME/.local/bin/omalive-fetch"
install_helper "$SCRIPT_DIR/optimize.sh" "$HOME/.local/bin/omalive-optimize"
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
Removing:        run ~/Projects/omalive/OmaLive/uninstall.sh (removes helpers,
                 restores the stock screensaver/menu, and removes both plugins)

Logs: ~/.cache/omalive.log
EOF

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo
  echo "⚠️  ~/.local/bin is not in your PATH. Add: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi