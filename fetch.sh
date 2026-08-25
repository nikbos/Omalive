#!/usr/bin/env bash
# ==============================================================================
# omalive-fetch — download aerial-style clips into OmaLive's video folder.
#
# OmaLive does not bundle or serve Apple's copyrighted Aerial videos. Instead
# this downloads a small curated starter set of openly-licensed aerial drone
# footage from Wikimedia Commons (CC BY / CC BY-SA — see the attribution notes
# printed at the end). Drop your own clips into the folder afterwards; the
# panel and the shuffle feature pick them up automatically.
#
# Usage:
#   omalive-fetch [dest-dir]        default dest: ~/Videos/Aerial
#   omalive-fetch --list            print the manifest without downloading
#
# Requires: curl, ffmpeg (to transcode webm -> mp4 for compatibility with
# codecs QtMultimedia can be picky about). If ffmpeg is missing the clips are
# kept as webm, which the FFmpeg-backed QtMultimedia also decodes.
# ==============================================================================

set -euo pipefail

DEST="${1:-$HOME/Videos/Aerial}"

# Hard cap on any single downloaded clip (bytes). Aerial HD clips are large, so
# the default is 1 GiB — generous but bounded: a compromised or misbehaving
# source can never fill the disk. The cap is a HARD ceiling: OMALIVE_MAX_FILESIZE
# may lower it (e.g. "500M") but can never raise it past HARD_CAP_BYTES, and an
# unparseable value falls back to the default rather than disabling the check.
DEFAULT_CAP_BYTES=$(( 1024 * 1024 * 1024 ))   # 1 GiB
HARD_CAP_BYTES=$(( 2 * 1024 * 1024 * 1024 ))  # 2 GiB ceiling

cap_raw="${OMALIVE_MAX_FILESIZE:-1G}"
cap_bytes="$(numfmt --from=iec "${cap_raw}" 2>/dev/null \
  || numfmt --from=auto "${cap_raw}" 2>/dev/null \
  || printf '%s' '')"
# numfmt accepts "1G"/"1024M"/…; anything else (or an empty result) gets the
# default, and any value over the ceiling is clamped down to it.
if [[ ! "${cap_bytes}" =~ ^[0-9]+$ ]]; then
  cap_bytes="${DEFAULT_CAP_BYTES}"
fi
if (( cap_bytes > HARD_CAP_BYTES )); then
  cap_bytes="${HARD_CAP_BYTES}"
fi
MAX_FILESIZE_BYTES="${cap_bytes}"
# curl's --max-filesize takes plain bytes; the same numeric value backs the
# post-download `stat` check below.
MAX_FILESIZE="${MAX_FILESIZE_BYTES}"

# Hard cap on the transcoded output (mp4). Same pattern: OMALIVE_MAX_OUTPUT may
# lower it but never past the ceiling, and an unparseable value falls back.
DEFAULT_OUT_CAP_BYTES=$(( 2 * 1024 * 1024 * 1024 ))   # 2 GiB
HARD_OUT_CAP_BYTES=$(( 4 * 1024 * 1024 * 1024 ))      # 4 GiB ceiling
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

# Deadlines so a stalled transfer or encode cannot hang forever.
MAX_TIME="${OMALIVE_MAX_TIME:-3600}"               # curl transfer deadline (s)
TRANSCODE_TIME="${OMALIVE_TRANSCODE_TIME:-1800}"   # ffmpeg encode deadline (s)

# name | url | license
MANIFEST=(
  "New Haven aerial drone | https://upload.wikimedia.org/wikipedia/commons/4/41/New_Haven-CT_seen_from_above_-_Aerial_Drone_-_Yale_university_city.webm | CC BY 3.0"
  "Akureyri Iceland drone | https://upload.wikimedia.org/wikipedia/commons/b/b0/Akureyri_-_Capital_of_the_north_Iceland_-_city_drone_flight.webm | CC BY 3.0"
  "Sheboygan Falls drone | https://upload.wikimedia.org/wikipedia/commons/9/9a/Sheboygan_Falls%2C_Wisconsin%3B_aerial_drone_video.webm | CC BY 3.0"
  "Mianyang Expo drone | https://upload.wikimedia.org/wikipedia/commons/6/64/Drone_in_the_2nd_China_%28Mianyang%29_Science_%26_Technology_City_International_Hi-Tech_Expo.webm | CC BY-SA 4.0"
)

err() { echo "omalive-fetch: $*" >&2; }

if [ "${1:-}" = "--list" ]; then
  for entry in "${MANIFEST[@]}"; do
    name="${entry%% | *}"
    url="${entry#* | }"; url="${url%% | *}"
    lic="${entry##* | }"
    printf '%-28s %-90s %s\n' "$name" "$url" "$lic"
  done
  exit 0
fi

command -v curl >/dev/null 2>&1 || { err "curl is required."; exit 1; }

mkdir -p "$DEST"

if command -v ffmpeg >/dev/null 2>&1; then
  CODEC="transcode"
else
  CODEC="keep"
  err "ffmpeg not found — clips will be kept as .webm (QtMultimedia FFmpeg backend decodes them, but transcoding to mp4/h264 is safer)"
fi

downloaded=0
# Private same-filesystem staging dir: downloads and transcodes land here, are
# validated, then are moved into place with an atomic rename that replaces any
# pre-existing symlink at the destination instead of following it. Using the
# destination filesystem keeps `mv` a rename (never a copy), and the random
# directory name makes a pre-planted symlink at our staging paths infeasible.
tmpdir="$(mktemp -d "$DEST/.omalive-fetch.XXXXXX" 2>/dev/null)" || {
  err "could not create a staging directory in $DEST"
  exit 1
}
trap 'rm -rf -- "$tmpdir"' EXIT

for entry in "${MANIFEST[@]}"; do
  name="${entry%% | *}"
  url="${entry#* | }"; url="${url%% | *}"
  lic="${entry##* | }"

  out_webm="$DEST/$name.webm"
  out_mp4="$DEST/$name.mp4"
  stage_webm="$tmpdir/$name.webm"
  stage_mp4="$tmpdir/$name.mp4"

  echo "── $name  ($lic)"
  if [ -f "$out_mp4" ] || { [ -f "$out_webm" ] && [ "$CODEC" = "keep" ]; }; then
    echo "   already present — skipping"
    continue
  fi

  if ! curl --fail --location --retry 3 --progress-bar \
       --max-filesize "$MAX_FILESIZE" --max-time "$MAX_TIME" \
       --output "$stage_webm" "$url"; then
    err "download failed for $name (exceeds ${MAX_FILESIZE} bytes or ${MAX_TIME}s deadline)"
    rm -f "$stage_webm"
    continue
  fi

  # Validate the staged download before it ever touches a final path: only a
  # regular file under the cap is accepted, and never a symlink.
  if [ ! -f "$stage_webm" ] || [ -L "$stage_webm" ] ||
     [ "$(stat -c %s "$stage_webm" 2>/dev/null || echo 0)" -gt "$MAX_FILESIZE_BYTES" ]; then
    err "refusing out-of-range or non-regular result for $name"
    rm -f "$stage_webm"
    continue
  fi

  installed=0
  if [ "$CODEC" = "transcode" ]; then
    if ffmpeg -y -nostdin -timelimit "$TRANSCODE_TIME" -loglevel error -i "$stage_webm" \
       -c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p \
       -c:a aac -b:a 128k -movflags +faststart "$stage_mp4" >/dev/null 2>&1; then
      if [ -f "$stage_mp4" ] && [ ! -L "$stage_mp4" ] &&
         [ "$(stat -c %s "$stage_mp4" 2>/dev/null || echo 0)" -le "$MAX_OUTPUT_BYTES" ]; then
        mv -f "$stage_mp4" "$out_mp4"
        installed=1
        echo "   transcoded to mp4 (h264)"
      else
        err "refusing out-of-range or non-regular transcode output for $name (over ${MAX_OUTPUT_BYTES} bytes) — keeping webm"
      fi
    else
      err "ffmpeg transcoding failed for $name (deadline ${TRANSCODE_TIME}s) — keeping webm"
    fi
  fi
  if [ "$installed" -eq 0 ]; then
    mv -f "$stage_webm" "$out_webm"
    installed=1
  fi
  downloaded=$((downloaded + installed))
done

rm -rf -- "$tmpdir"
trap - EXIT

echo
echo "Done — $downloaded clip(s) downloaded to $DEST"
echo "Try: omalive play \"$DEST\"/<clip>"

# Pre-optimize new clips (60fps + seamless loop) so playback is smooth at once.
if command -v omalive-optimize >/dev/null 2>&1; then
  omalive-optimize "$DEST"
else
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -x "$script_dir/optimize.sh" ] && "$script_dir/optimize.sh" "$DEST"
fi
cat <<ATTRIBUTION

Attribution (Wikimedia Commons):
  - "New Haven aerial drone" — CC BY 3.0, via Wikimedia Commons
  - "Akureyri Iceland drone" — CC BY 3.0, via Wikimedia Commons
  - "Sheboygan Falls drone"  — CC BY 3.0, via Wikimedia Commons
  - "Mianyang Expo drone"    — CC BY-SA 4.0, via Wikimedia Commons
Licences require attribution for redistribution; for personal desktop use
credit the original uploaders per the file pages.
ATTRIBUTION