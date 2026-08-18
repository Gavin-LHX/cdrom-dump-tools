#!/usr/bin/env bash

set -Eeuo pipefail

PROGRAM="$(basename "$0")"
DEVICE="${CDROM_DEVICE:-/dev/cdrom}"
OUTPUT_DIR="${CDROM_DUMP_DIR:-/mnt/hdd2/cdrom-dumps}"
IMAGE_NAME=""
CUSTOM_NAME=0
READ_SPEED=""
EJECT_AFTER=0
DRY_RUN=0
METADATA_LOOKUP=1
WORK_DIR=""

if [[ "${CDROM_NO_METADATA:-0}" == 1 ]]; then
  METADATA_LOOKUP=0
fi

usage() {
  cat <<EOF
Usage: $PROGRAM [options]

Create a complete CD image as a BIN/TOC pair. This format preserves audio,
data, and mixed-mode tracks; an ISO file cannot represent every CD type.

Options:
  -d, --device DEVICE       Optical drive (default: $DEVICE)
  -o, --output-dir DIR      Destination root (default: $OUTPUT_DIR)
  -n, --name NAME           Image/directory name (default: timestamped)
  -s, --speed SPEED         Limit the drive read speed
      --no-metadata         Do not query album metadata or rename the folder
      --eject               Eject the disc after a successful dump
      --dry-run             Validate and show what would be done
  -h, --help                Show this help

Environment variables:
  CDROM_DEVICE, CDROM_DUMP_DIR, CDROM_NO_METADATA

Example:
  $PROGRAM --name album-01
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

need_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
}

while (($#)); do
  case "$1" in
    -d|--device)
      need_value "$@"
      DEVICE="$2"
      shift 2
      ;;
    -o|--output-dir)
      need_value "$@"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -n|--name)
      need_value "$@"
      IMAGE_NAME="$2"
      CUSTOM_NAME=1
      shift 2
      ;;
    -s|--speed)
      need_value "$@"
      READ_SPEED="$2"
      shift 2
      ;;
    --eject)
      EJECT_AFTER=1
      shift
      ;;
    --no-metadata)
      METADATA_LOOKUP=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

for command_name in cdrdao sha256sum lsblk df mktemp realpath; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "required command not found: $command_name"
done

if [[ ! -b "$DEVICE" ]]; then
  detected_device="$(lsblk -dnpo NAME,TYPE | awk '$2 == "rom" { print $1; exit }')"
  [[ -n "$detected_device" ]] || die "no optical drive was detected"
  DEVICE="$detected_device"
fi

DEVICE="$(realpath -e -- "$DEVICE")"
[[ -b "$DEVICE" ]] || die "not a block device: $DEVICE"
[[ -r "$DEVICE" ]] || die "cannot read $DEVICE; try running with sudo"

if ! cdrdao disk-info --device "$DEVICE" >/dev/null 2>&1; then
  die "no readable CD is present in $DEVICE"
fi

if [[ -z "$IMAGE_NAME" ]]; then
  IMAGE_NAME="cdrom-$(date +%Y%m%d-%H%M%S)"
fi
[[ "$IMAGE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die "name may contain only letters, numbers, dot, underscore, and hyphen"
[[ "$READ_SPEED" =~ ^$|^[1-9][0-9]*$ ]] || die "speed must be a positive integer"

if ((DRY_RUN)); then
  printf 'Device:      %s\n' "$DEVICE"
  printf 'Destination: %s/%s\n' "$OUTPUT_DIR" "$IMAGE_NAME"
  if ((METADATA_LOOKUP && !CUSTOM_NAME)); then
    printf 'Folder name: album metadata when available; timestamp fallback\n'
  fi
  printf 'Format:      BIN/TOC (raw sectors, paranoia mode 3)\n'
  [[ -z "$READ_SPEED" ]] || printf 'Read speed:  %sx\n' "$READ_SPEED"
  exit 0
fi

mkdir -p -- "$OUTPUT_DIR"
OUTPUT_DIR="$(realpath -e -- "$OUTPUT_DIR")"
[[ -d "$OUTPUT_DIR" && -w "$OUTPUT_DIR" ]] ||
  die "output directory is not writable: $OUTPUT_DIR"

FINAL_DIR="$OUTPUT_DIR/$IMAGE_NAME"
if ((CUSTOM_NAME)) && [[ -e "$FINAL_DIR" ]]; then
  die "destination already exists: $FINAL_DIR"
fi

disc_bytes="$(blockdev --getsize64 "$DEVICE" 2>/dev/null || printf '0')"
available_bytes="$(df --output=avail -B1 "$OUTPUT_DIR" | awk 'NR == 2 { print $1 }')"
if [[ "$disc_bytes" =~ ^[0-9]+$ && "$available_bytes" =~ ^[0-9]+$ ]] &&
   ((disc_bytes > 0 && available_bytes < disc_bytes + 67108864)); then
  die "not enough free space in $OUTPUT_DIR"
fi

WORK_DIR="$(mktemp -d --tmpdir="$OUTPUT_DIR" ".${IMAGE_NAME}.partial.XXXXXX")"

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    work_parent="$(dirname -- "$WORK_DIR")"
    work_base="$(basename -- "$WORK_DIR")"
    if [[ "$work_parent" == "$OUTPUT_DIR" && "$work_base" == ".${IMAGE_NAME}.partial."* ]]; then
      rm -rf --one-file-system -- "$WORK_DIR"
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Reading %s into a temporary %s image ...\n' "$DEVICE" "$IMAGE_NAME"

read_options=(
  read-cd
  --device "$DEVICE"
  --read-raw
  --paranoia-mode 3
)
if [[ -n "$READ_SPEED" ]]; then
  read_options+=(--rspeed "$READ_SPEED")
fi

(
  cd "$WORK_DIR"
  cdrdao "${read_options[@]}" \
    --datafile "$IMAGE_NAME.bin" \
    "$IMAGE_NAME.toc"

  cdrdao disk-info --device "$DEVICE" > disc-info.txt 2>&1 || true
  {
    printf 'Created (UTC): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Host: %s\n' "$(hostname)"
    printf 'Source device: %s\n' "$DEVICE"
    lsblk -dn -o NAME,VENDOR,MODEL,REV,SIZE,TYPE "$DEVICE"
  } > dump-metadata.txt

  sha256sum -- "$IMAGE_NAME.bin" "$IMAGE_NAME.toc" > SHA256SUMS
)

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

lookup_album_folder() {
  local toc_path="$1"
  local bin_path="$2"
  local cache_dir cache_file cache_age disc_info disc_id toc_encoded track_count
  local metadata_json metadata_tmp metadata_source base_url lookup_url album_folder

  command -v python3 >/dev/null 2>&1 || {
    warn 'python3 is unavailable; using the timestamp folder name'
    return 1
  }

  disc_info="$(python3 - "$toc_path" "$bin_path" <<'PY'
import base64
import hashlib
import os
import re
import sys
import urllib.parse

toc_path, bin_path = sys.argv[1:3]

def to_sector(value):
    if re.fullmatch(r"\d{1,3}:\d{2}:\d{2}", value):
        minutes, seconds, frames = map(int, value.split(":"))
        if seconds >= 60 or frames >= 75:
            raise ValueError("invalid MSF position")
        return minutes * 60 * 75 + seconds * 75 + frames
    if value.isdigit():
        samples = int(value)
        if samples % 588:
            raise ValueError("sample offset is not sector aligned")
        return samples // 588
    raise ValueError("unsupported TOC position")

track_offsets = []
waiting_for_file = False
with open(toc_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        if re.match(r"^TRACK\s+", line, re.IGNORECASE):
            waiting_for_file = True
            continue
        if not waiting_for_file:
            continue
        match = re.match(
            r'^(?:FILE|AUDIOFILE|DATAFILE)\s+"[^"]+"\s+(\S+)',
            line,
            re.IGNORECASE,
        )
        if match:
            track_offsets.append(to_sector(match.group(1)) + 150)
            waiting_for_file = False

if not track_offsets or len(track_offsets) > 99:
    raise ValueError("TOC contains no usable tracks")

bin_size = os.path.getsize(bin_path)
if bin_size <= 0 or bin_size % 2352:
    raise ValueError("BIN size is not aligned to 2352-byte raw sectors")

leadout = bin_size // 2352 + 150
hash_text = f"{1:02X}{len(track_offsets):02X}{leadout:08X}"
hash_text += "".join(
    f"{(track_offsets[index] if index < len(track_offsets) else 0):08X}"
    for index in range(99)
)
digest = hashlib.sha1(hash_text.encode("ascii")).digest()
disc_id = base64.b64encode(digest).decode("ascii").replace("+", ".").replace("/", "_").replace("=", "-")
toc = " ".join(map(str, [1, len(track_offsets), leadout, *track_offsets]))

print(disc_id)
print(urllib.parse.quote(toc, safe=""))
print(len(track_offsets))
PY
)" || {
    warn 'could not calculate a MusicBrainz Disc ID; using the timestamp folder name'
    return 1
  }

  mapfile -t disc_fields <<<"$disc_info"
  disc_id="${disc_fields[0]:-}"
  toc_encoded="${disc_fields[1]:-}"
  track_count="${disc_fields[2]:-}"
  [[ -n "$disc_id" && -n "$toc_encoded" && "$track_count" =~ ^[1-9][0-9]*$ ]] || return 1

  printf 'MusicBrainz Disc ID: %s\n' "$disc_id" >&2
  cache_dir="$OUTPUT_DIR/.metadata-cache/musicbrainz"
  cache_file="$cache_dir/$disc_id.json"
  metadata_json="$WORK_DIR/musicbrainz-metadata.json"
  metadata_tmp="$WORK_DIR/.musicbrainz-metadata.tmp.json"
  metadata_source=""

  if [[ -f "$cache_file" ]]; then
    cache_age="$(( $(date +%s) - $(stat -c %Y -- "$cache_file" 2>/dev/null || printf '0') ))"
    if ((cache_age >= 0 && cache_age < 2592000)); then
      cp -- "$cache_file" "$metadata_json"
      metadata_source="MusicBrainz cache (fresh)"
    fi
  fi

  if [[ -z "$metadata_source" ]] && command -v curl >/dev/null 2>&1; then
    for base_url in https://musicbrainz.org https://musicbrainz.eu; do
      lookup_url="${base_url}/ws/2/discid/${disc_id}?inc=recordings%2Bartist-credits%2Brelease-groups%2Bisrcs&toc=${toc_encoded}&cdstubs=no&fmt=json"
      if curl --silent --show-error --fail --location \
          --connect-timeout 8 --max-time 35 --retry 2 --retry-delay 2 --retry-all-errors \
          --header 'Accept: application/json' \
          --user-agent 'dump-cdrom/2.1 (https://github.com/Gavin-LHX/cdrom-dump-tools)' \
          --output "$metadata_tmp" "$lookup_url" &&
         python3 - "$metadata_tmp" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
if not isinstance(payload, dict) or not isinstance(payload.get("releases"), list):
    raise SystemExit(1)
PY
      then
        mv -- "$metadata_tmp" "$metadata_json"
        if [[ "$base_url" == https://musicbrainz.org ]]; then
          metadata_source="MusicBrainz primary"
        else
          metadata_source="MusicBrainz mirror"
        fi
        if mkdir -p -- "$cache_dir" 2>/dev/null; then
          cp -- "$metadata_json" "$cache_file" 2>/dev/null || true
        fi
        break
      fi
      rm -f -- "$metadata_tmp"
    done
  fi

  if [[ -z "$metadata_source" && -f "$cache_file" ]]; then
    cp -- "$cache_file" "$metadata_json"
    metadata_source="MusicBrainz cache (stale fallback)"
  fi

  [[ -n "$metadata_source" && -s "$metadata_json" ]] || {
    warn 'album lookup failed on the primary endpoint and mirror, with no usable cache; using the timestamp folder name'
    return 1
  }

  album_folder="$(python3 - "$metadata_json" "$disc_id" "$track_count" <<'PY'
import json
import re
import sys

metadata_path, disc_id, expected_tracks = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(metadata_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

def artist_credit_text(value):
    if not isinstance(value, list):
        return ""
    pieces = []
    for item in value:
        if isinstance(item, str):
            pieces.append(item)
        elif isinstance(item, dict):
            pieces.append(str(item.get("name") or "") + str(item.get("joinphrase") or ""))
    return "".join(pieces).strip()

def medium_score(medium):
    score = 0
    count = medium.get("track-count")
    if count is None and isinstance(medium.get("tracks"), list):
        count = len(medium["tracks"])
    if count == expected_tracks:
        score += 100
    for disc in medium.get("discs") or []:
        if isinstance(disc, dict) and disc.get("id") == disc_id:
            score += 1000
    return score

candidates = []
for index, release in enumerate(payload.get("releases") or []):
    if not isinstance(release, dict):
        continue
    media = release.get("media") or []
    best_medium = max((medium_score(m) for m in media if isinstance(m, dict)), default=0)
    score = best_medium
    if str(release.get("status") or "").lower() == "official":
        score += 20
    if release.get("date"):
        score += 5
    candidates.append((score, -index, release))

if not candidates:
    raise SystemExit(1)

release = max(candidates, key=lambda item: (item[0], item[1]))[2]
release_group = release.get("release-group") if isinstance(release.get("release-group"), dict) else {}
title = str(release.get("title") or release_group.get("title") or "").strip()
artist = artist_credit_text(release.get("artist-credit")) or artist_credit_text(release_group.get("artist-credit"))
date = str(release.get("date") or release_group.get("first-release-date") or "")
year_match = re.match(r"^(\d{4})", date)
year = year_match.group(1) if year_match else ""
if not title:
    raise SystemExit(1)

folder = f"{artist} - {title}" if artist else title
if year:
    folder += f" ({year})"
folder += " [BIN-TOC]"
folder = re.sub(r'[\x00-\x1f<>:"/\\|?*]+', "_", folder)
folder = re.sub(r"\s+", " ", folder).strip(" .")
while len(folder.encode("utf-8")) > 220:
    folder = folder[:-1].rstrip()
if not folder or folder in {".", ".."}:
    raise SystemExit(1)
print(folder)
PY
)" || {
    warn 'metadata was returned but no matching album could be resolved; using the timestamp folder name'
    return 1
  }

  [[ -n "$album_folder" ]] || return 1
  {
    printf 'MusicBrainz Disc ID: %s\n' "$disc_id"
    printf 'Metadata source: %s\n' "$metadata_source"
    printf 'Resolved folder: %s\n' "$album_folder"
  } >> "$WORK_DIR/dump-metadata.txt"
  printf 'Album metadata: %s\n' "$metadata_source" >&2
  printf '%s\n' "$album_folder"
}

FINAL_NAME="$IMAGE_NAME"
if ((METADATA_LOOKUP && !CUSTOM_NAME)); then
  if resolved_folder="$(lookup_album_folder "$WORK_DIR/$IMAGE_NAME.toc" "$WORK_DIR/$IMAGE_NAME.bin")"; then
    FINAL_NAME="$resolved_folder"
  fi
fi

FINAL_DIR="$OUTPUT_DIR/$FINAL_NAME"
if [[ -e "$FINAL_DIR" ]]; then
  if ((CUSTOM_NAME)); then
    die "destination already exists: $FINAL_DIR"
  fi
  base_final_dir="$FINAL_DIR"
  suffix=2
  while [[ -e "$FINAL_DIR" ]]; do
    FINAL_DIR="$base_final_dir-$suffix"
    ((suffix += 1))
  done
fi

mv -- "$WORK_DIR" "$FINAL_DIR"
WORK_DIR=""

if ((EUID == 0)) && [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  owner_group="$(id -gn "$SUDO_USER")"
  chown -R -- "$SUDO_USER:$owner_group" "$FINAL_DIR"
fi

if ((EJECT_AFTER)); then
  eject "$DEVICE"
fi

printf 'Done. Image: %s/%s.bin\n' "$FINAL_DIR" "$IMAGE_NAME"
printf 'TOC:        %s/%s.toc\n' "$FINAL_DIR" "$IMAGE_NAME"
printf 'Checksums:  %s/SHA256SUMS\n' "$FINAL_DIR"
