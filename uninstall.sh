#!/usr/bin/env bash
# ==============================================================================
# OmaLive uninstaller — fully removes OmaLive and the OmaLiveLock companion.
#
# Reverses install.sh: deletes the CLI helpers, restores the stock ttfx
# screensaver toggle, reverts the menu Screensaver-row override, removes the
# OmaLive state dir, and removes both shell plugins (restoring the stock lock).
#
# Usage:
#   uninstall.sh                 full removal (helpers, menu, state, plugins)
#   uninstall.sh --files-only    remove helpers/menu/state, leave plugins
#   uninstall.sh --plugins-only  remove the omalive + omalive-lock plugins
#
# Run it from a checkout of this repository. It refuses while the session is
# locked (removing plugins writes into the plugin dir, which hot-reloads the
# shell and would tear down an active lock screen).
# ==============================================================================

set -euo pipefail

PLUGIN_ID="omalive"
LOCK_PLUGIN_ID="omalive-lock"
PLUGINS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
TOGGLES="$HOME/.local/state/omarchy/toggles"
MENU_EXT="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"

FILES_ONLY=0
PLUGINS_ONLY=0
case "${1:-}" in
  --files-only)  FILES_ONLY=1 ;;
  --plugins-only) PLUGINS_ONLY=1 ;;
  ""|-h|--help)
    ;;
  *)
    echo "unknown option: $1" >&2
    echo "usage: uninstall.sh [--files-only|--plugins-only]" >&2
    exit 1
    ;;
esac

echo "=== OmaLive uninstaller ==="

# ----- lock guard -----------------------------------------------------------
if command -v omarchy-shell >/dev/null 2>&1 &&
   [[ "$(omarchy-shell lock isLocked 2>/dev/null)" == "true" ]]; then
  echo "ERROR: Refusing to uninstall OmaLive while the session is locked." >&2
  echo "Unlock first, then re-run this script." >&2
  exit 1
fi

if [ "$PLUGINS_ONLY" -eq 0 ]; then
  # ----- CLI helpers --------------------------------------------------------
  for helper in omalive omalive-fetch omalive-optimize; do
    if [ -e "$HOME/.local/bin/$helper" ] || [ -L "$HOME/.local/bin/$helper" ]; then
      rm -f -- "$HOME/.local/bin/$helper"
      echo "✓ Removed ~/.local/bin/$helper"
    fi
  done

  # ----- OmaLive's own screensaver toggle -----------------------------------
  rm -f -- "$TOGGLES/omalive-screensaver-off"

  # ----- stock ttfx screensaver toggle (restored) ---------------------------
  # install.sh creates this only if absent; removing it re-enables the stock
  # ttfx screensaver that OmaLive suppressed.
  rm -f -- "$TOGGLES/screensaver-off"
  echo "✓ Restored the stock ttfx screensaver (removed the screensaver-off toggle)"

  # ----- menu Screensaver-row override --------------------------------------
  # Descriptor-bound revert: read through O_NOFOLLOW, rewrite atomically, and
  # remove the file if it only ever held the OmaLive override.
  if [ -e "$MENU_EXT" ] || [ -L "$MENU_EXT" ]; then
    python3 - "$MENU_EXT" <<'PY'
import sys, os, stat, tempfile, re
p = sys.argv[1]
if not os.path.lexists(p):
    sys.exit(0)
fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
try:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size > 1048576:
        sys.exit(0)
    s = os.read(fd, 1048576).decode("utf-8", "replace")
finally:
    os.close(fd)
if '"system.screensaver"' not in s:
    sys.exit(0)

new = re.sub(r'^[ \t]*"system\.screensaver"[^\n]*\n?', '', s, flags=re.M)
# The override was inserted as the last property; drop the now-dangling comma
# from the property that preceded it.
new = re.sub(r',(\s*)\}\s*$', r'\1}\n', new, flags=re.M)
# If nothing but comments/whitespace remains inside the braces, the file only
# ever held the OmaLive override — remove it.
remaining = "".join(re.sub(r'//[^\n]*', '', new).split())
if remaining in ('{}', '{', '}', ''):
    os.unlink(p)
    sys.exit(0)

d = os.path.dirname(p) or "."
fd2, tmp = tempfile.mkstemp(prefix=os.path.basename(p) + ".", dir=d)
try:
    with os.fdopen(fd2, "w", encoding="utf-8") as f:
        f.write(new.rstrip() + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
    echo "✓ Reverted the menu Screensaver-row override"
  fi

  # ----- state dir ----------------------------------------------------------
  rm -rf -- "$HOME/.local/state/omalive"
  echo "✓ Removed ~/.local/state/omalive"
fi

# ----- plugins --------------------------------------------------------------
if [ "$FILES_ONLY" -eq 0 ]; then
  for id in "$LOCK_PLUGIN_ID" "$PLUGIN_ID"; do
    if [ -e "$PLUGINS_DIR/$id" ] || [ -L "$PLUGINS_DIR/$id" ]; then
      if command -v omarchy-plugin-remove >/dev/null 2>&1 || command -v omarchy >/dev/null 2>&1; then
        omarchy plugin remove "$id" --yes >/dev/null 2>&1 \
          && echo "✓ Removed plugin $id" \
          || echo "⚠️  Could not remove plugin $id (run: omarchy plugin remove $id)" >&2
      else
        echo "⚠️  omarchy not found; remove the plugin folder manually: $PLUGINS_DIR/$id" >&2
      fi
    fi
  done
fi

echo
echo "=== Uninstall complete ==="
if command -v omarchy-restart-shell >/dev/null 2>&1; then
  echo "Restarting omarchy-shell…"
  omarchy-restart-shell >/dev/null 2>&1 || \
    echo "⚠️  Restart omarchy-shell manually (omarchy-restart-shell)."
fi