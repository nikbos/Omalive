#!/usr/bin/env bash
# ==============================================================================
# omalive-optimize — one-time transcode of OmaLive clips into a wallpaper-
# friendly form:
#
#   * 60fps motion interpolation (ffmpeg `framerate` filter) so the 0.35x live
#     drift is ~21fps instead of a ~10fps slideshow.
#   * The tail crossfaded into the head (xfade) so MediaPlayer's Infinite loop
#     has no hard cut at the seam.
#   * Dense keyframes (one every GOP frames = 1s at 60fps) so any seek — the
#     lock-screen handoff, the screensaver resume — decodes at most ~1s of
#     footage instead of up to a full GOP (x264's default 250 frames at 60fps
#     is a 4.17s keyframe gap, which made unlock/screensaver seeks visibly
#     stall).
#   * No audio stream (-an), h264/yuv420p + faststart for QtMultimedia.
#
# Output is written next to each source as <clip>.opt.mp4. The OmaLive service
# auto-prefers the .opt.mp4 sibling when it exists, so originals stay untouched
# and the library/shuffle lists never show the optimized copies.
#
# Usage:
#   omalive-optimize [file-or-dir]      default dir: ~/Videos/Aerial
#   omalive-optimize -f [file-or-dir]   re-encode even up-to-date clips
#
# Idempotent: files whose .opt.mp4 is newer than the source are skipped (unless
# -f/--force). Requires: ffmpeg, ffprobe.
# ==============================================================================

set -euo pipefail

FORCE=0
if [[ "${1:-}" == "-f" || "${1:-}" == "--force" ]]; then
  FORCE=1
  shift
fi

DEST="${1:-$HOME/Videos/Aerial}"
X=0.8          # seam crossfade length (seconds)
FPS=60
CRF=24
GOP=60         # keyframe interval in frames (60 = every 1s at 60fps)
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
LOG_FILE="$LOG_DIR/omalive.log"
# A symlinked or non-regular log path must never be followed; drop to /dev/null.
if [ -L "$LOG_FILE" ] || { [ -e "$LOG_FILE" ] && [ ! -f "$LOG_FILE" ]; }; then
  LOG_FILE=/dev/null
fi
mkdir -p "$LOG_DIR"

# Output ceiling for the transcoded .opt.mp4 (default 2 GiB, hard 4 GiB ceiling)
# and an encode deadline so a stuck transcode cannot hang forever.
DEFAULT_OUT_CAP_BYTES=$(( 2 * 1024 * 1024 * 1024 ))
HARD_OUT_CAP_BYTES=$(( 4 * 1024 * 1024 * 1024 ))
out_raw="${OMALIVE_MAX_OUTPUT:-2G}"
out_bytes="$(numfmt --from=iec "${out_raw}" 2>/dev/null \
  || numfmt --from=auto "${out_raw}" 2>/dev/null \
  || printf '%s' '')"
if [[ ! "${out_bytes}" =~ ^[0-9]+$ ]]; then
  out_bytes="${DEFAULT_OUT_CAP_BYTES}"
fi
if (( out_bytes > HARD_OUT_CAP_BYTES )); then
  out_bytes="${HARD_OUT_CAP_BYTES}"
fi
MAX_OUTPUT_BYTES="${out_bytes}"
TRANSCODE_TIME="${OMALIVE_TRANSCODE_TIME:-1800}"

err() { echo "omalive-optimize: $*" >&2; }
log() { printf '%s\n' "$*" >> "$LOG_FILE"; }

command -v ffmpeg  >/dev/null 2>&1 || { err "ffmpeg is required."; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { err "ffprobe is required."; exit 1; }

transcode() {
  local src="$1" out="$2" dur="$3"
  local mid_end tmpdir staged
  mid_end="$(awk -v d="$dur" -v x="$X" 'BEGIN { printf "%.4f", d - x }')"
  # Same-filesystem private staging so the final `mv` is a rename that replaces
  # any pre-existing symlink instead of following it, and the encode output is
  # validated (regular, under the cap) before it ever touches the final path.
  tmpdir="$(mktemp -d "$(dirname "$out")/.omalive-opt.XXXXXX")" || return 1
  staged="$tmpdir/out.mp4"

  # Tier 1: 60fps interpolation + baked seam crossfade.
  if ffmpeg -y -hide_banner -timelimit "$TRANSCODE_TIME" -loglevel error -i "$src" -filter_complex "
[0:v]framerate=fps=${FPS}[m];
[m]split=3[a][b][c];
[a]trim=duration=${X},setpts=PTS-STARTPTS[head];
[b]trim=start=0:end=${mid_end},setpts=PTS-STARTPTS[mid];
[c]trim=start=${mid_end},setpts=PTS-STARTPTS[tail];
[tail][head]xfade=transition=fade:duration=${X}:offset=0[xf];
[mid][xf]concat=n=2:v=1:a=0[out]
" -map "[out]" -c:v libx264 -preset medium -crf "$CRF" -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -an -movflags +faststart "$staged"; then
    if install_staged "$staged" "$out" "$tmpdir"; then
      return 0
    fi
    return 1
  fi
  # Tier 2 (xfade unavailable/errored): 60fps only; the loop seam stays a cut.
  err "seam crossfade failed for $src — falling back to interpolation only"
  rm -f "$staged"
  if ffmpeg -y -hide_banner -timelimit "$TRANSCODE_TIME" -loglevel error -i "$src" -vf "framerate=fps=${FPS}" \
      -c:v libx264 -preset medium -crf "$CRF" -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -an -movflags +faststart "$staged"; then
    if install_staged "$staged" "$out" "$tmpdir"; then
      return 0
    fi
    return 1
  fi
  rm -rf "$tmpdir"
  return 1
}

# Validate a freshly transcoded file (regular, not a symlink, under the output
# cap) and atomically move it into place; the rename replaces a pre-existing
# symlink at the destination rather than following it.
install_staged() {
  local staged="$1" out="$2" tmpdir="$3"
  if [ -f "$staged" ] && [ ! -L "$staged" ] &&
     [ "$(stat -c %s "$staged" 2>/dev/null || echo 0)" -le "$MAX_OUTPUT_BYTES" ]; then
    mv -f "$staged" "$out" || { rm -rf "$tmpdir"; return 1; }
    rm -rf "$tmpdir"
    return 0
  fi
  err "refusing out-of-range or non-regular transcode output (over ${MAX_OUTPUT_BYTES} bytes)"
  rm -rf "$tmpdir"
  return 1
}

optimize_one() {
  local f="$1"
  [ -f "$f" ] || return 0
  case "$f" in *.opt.mp4) return 0 ;; esac
  local out="$f.opt.mp4"
  if [ "$FORCE" -ne 1 ] && [ -f "$out" ] && [ "$out" -nt "$f" ]; then
    echo "  ✓ $out (up to date)"
    return 0
  fi
  local dur
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$f" 2>/dev/null)" || {
    err "could not probe $f"; return 0
  }
  dur="${dur%%,*}"
  if ! awk -v d="$dur" 'BEGIN { exit !(d > 1.5) }'; then
    err "clip too short to loop: $f"; return 0
  fi
  echo "  → $f -> $out ($(awk -v d="$dur" 'BEGIN { printf "%.1fs", d }'), ${FPS}fps interpolated)"
  if transcode "$f" "$out" "$dur"; then
    echo "  ✓ $out"
    log "optimized: $f -> $out"
  else
    err "transcode failed for $f — keeping the original in use"
  fi
}

if [ -d "$DEST" ]; then
  echo "Optimizing clips in $DEST"
  count=0
  for f in "$DEST"/*.mp4 "$DEST"/*.mkv "$DEST"/*.webm "$DEST"/*.mov "$DEST"/*.avi; do
    [ -f "$f" ] || continue
    optimize_one "$f"
    count=$((count + 1))
  done
  echo "Done — processed $count clip(s)"
else
  optimize_one "$DEST"
fi