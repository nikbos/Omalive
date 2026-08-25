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
mkdir -p "$LOG_DIR"

err() { echo "omalive-optimize: $*" >&2; }

log() { printf '%s\n' "$*" >> "$LOG_FILE"; }

command -v ffmpeg  >/dev/null 2>&1 || { err "ffmpeg is required."; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { err "ffprobe is required."; exit 1; }

transcode() {
  local src="$1" out="$2" dur="$3"
  local mid_end
  mid_end="$(awk -v d="$dur" -v x="$X" 'BEGIN { printf "%.4f", d - x }')"
  # Tier 1: 60fps interpolation + baked seam crossfade.
  ffmpeg -y -hide_banner -loglevel error -i "$src" -filter_complex "
[0:v]framerate=fps=${FPS}[m];
[m]split=3[a][b][c];
[a]trim=duration=${X},setpts=PTS-STARTPTS[head];
[b]trim=start=0:end=${mid_end},setpts=PTS-STARTPTS[mid];
[c]trim=start=${mid_end},setpts=PTS-STARTPTS[tail];
[tail][head]xfade=transition=fade:duration=${X}:offset=0[xf];
[mid][xf]concat=n=2:v=1:a=0[out]
" -map "[out]" -c:v libx264 -preset medium -crf "$CRF" -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -an -movflags +faststart "$out.tmp.mp4" \
    && return 0
  # Tier 2 (xfade unavailable/errored): 60fps only; the loop seam stays a cut.
  err "seam crossfade failed for $src — falling back to interpolation only"
  rm -f "$out.tmp.mp4"
  ffmpeg -y -hide_banner -loglevel error -i "$src" -vf "framerate=fps=${FPS}" \
      -c:v libx264 -preset medium -crf "$CRF" -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -an -movflags +faststart "$out.tmp.mp4"
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
    mv -f "$out.tmp.mp4" "$out"
    echo "  ✓ $out"
    log "optimized: $f -> $out"
  else
    err "transcode failed for $f — keeping the original in use"
    rm -f "$out.tmp.mp4"
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