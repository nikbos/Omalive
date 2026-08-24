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
for entry in "${MANIFEST[@]}"; do
  name="${entry%% | *}"
  url="${entry#* | }"; url="${url%% | *}"
  lic="${entry##* | }"

  out_webm="$DEST/$name.webm"
  out_mp4="$DEST/$name.mp4"

  echo "── $name  ($lic)"
  if [ -f "$out_mp4" ] || { [ -f "$out_webm" ] && [ "$CODEC" = "keep" ]; }; then
    echo "   already present — skipping"
    continue
  fi

  if ! curl --fail --location --continue-at - --retry 3 --progress-bar \
       --output "$out_webm" "$url"; then
    err "download failed for $name"
    rm -f "$out_webm"
    continue
  fi

  if [ "$CODEC" = "transcode" ]; then
    if ffmpeg -y -nostdin -loglevel error -i "$out_webm" \
       -c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p \
       -c:a aac -b:a 128k -movflags +faststart "$out_mp4" >/dev/null 2>&1; then
      rm -f "$out_webm"
      echo "   transcoded to mp4 (h264)"
    else
      err "ffmpeg transcoding failed for $name — keeping webm"
    fi
  fi
  downloaded=$((downloaded + 1))
done

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