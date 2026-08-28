#!/usr/bin/env bash

set -Eeuo pipefail

PROGRAM="$(basename "$0")"
DEVICE="${CDROM_DEVICE:-/dev/cdrom}"
OUTPUT_DIR="${CDROM_DUMP_DIR:-/mnt/hdd2/cdrom-dumps}"
IMAGE_NAME=""
CUSTOM_NAME=0
READ_SPEED=""
VERIFY_PASSES="${CDROM_VERIFY_PASSES:-1}"
VERIFY_SPEED="${CDROM_VERIFY_SPEED:-4}"
RELEASE_INDEX="${CDROM_RELEASE_INDEX:-0}"
VERIFY_MISMATCH=0
VERIFY_RESULT="SINGLE_PASS"
EJECT_AFTER=0
DRY_RUN=0
METADATA_LOOKUP=1
METADATA_SELECTION_FAILED=0
WORK_DIR=""
KEEP_WORK_DIR=0

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
      --verify-passes 1|2   Read once, or read twice and compare (default: $VERIFY_PASSES)
      --verify-speed SPEED  Default speed for verification reads (default: ${VERIFY_SPEED}x)
      --release-index N     Select displayed MusicBrainz release N (default: prompt)
      --no-metadata         Do not query album metadata or rename the folder
      --eject               Eject the disc after a successful dump
      --dry-run             Validate and show what would be done
  -h, --help                Show this help

Environment variables:
  CDROM_DEVICE, CDROM_DUMP_DIR, CDROM_NO_METADATA,
  CDROM_VERIFY_PASSES, CDROM_VERIFY_SPEED, CDROM_RELEASE_INDEX

Example:
  $PROGRAM --verify-passes 2
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

need_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
}

prepare_musicbrainz_release_candidates() {
  local metadata_path="$1"
  local disc_id="$2"
  local expected_tracks="$3"
  local candidate_path="$4"

  python3 - "$metadata_path" "$disc_id" "$expected_tracks" "$candidate_path" <<'PY'
import json
import os
import re
import sys
import unicodedata

metadata_path, disc_id, expected_tracks_text, candidate_path = sys.argv[1:5]
expected_tracks = int(expected_tracks_text)
with open(metadata_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

def clean_text(value):
    text = "".join(
        character if not unicodedata.category(character).startswith("C") else " "
        for character in str(value or "")
    )
    return " ".join(text.split()).strip()[:500]

def artist_credit_text(value):
    if not isinstance(value, list):
        return ""
    pieces = []
    for item in value:
        if isinstance(item, str):
            pieces.append(item)
        elif isinstance(item, dict):
            pieces.append(str(item.get("name") or "") + str(item.get("joinphrase") or ""))
    return clean_text("".join(pieces))

def medium_details(medium):
    count = medium.get("track-count")
    if count is None and isinstance(medium.get("tracks"), list):
        count = len(medium["tracks"])
    track_count_matches = count == expected_tracks
    disc_id_matches = any(
        isinstance(disc, dict) and disc.get("id") == disc_id
        for disc in (medium.get("discs") or [])
    )
    score = 100 if track_count_matches else 0
    if disc_id_matches:
        score += 1000
    raw_position = medium.get("position")
    position = (
        raw_position
        if isinstance(raw_position, int) and not isinstance(raw_position, bool) and 1 <= raw_position <= 100
        else None
    )
    return {
        "score": score,
        "track_count_matches": track_count_matches,
        "disc_id_matches": disc_id_matches,
        "position": position,
        "format": clean_text(medium.get("format")),
        "track_count": count,
    }

def safe_folder(artist, title, date):
    year_match = re.match(r"^(\d{4})", date)
    year = year_match.group(1) if year_match else ""
    folder = f"{artist} - {title}" if artist else title
    if year:
        folder += f" ({year})"
    folder += " [BIN-TOC]"
    folder = re.sub(r'[\x00-\x1f<>:"/\\|?*]+', "_", folder)
    folder = re.sub(r"\s+", " ", folder).strip(" .")
    while len(folder.encode("utf-8")) > 220:
        folder = folder[:-1].rstrip()
    return folder

candidates = []
for source_index, release in enumerate(payload.get("releases") or []):
    if not isinstance(release, dict):
        continue
    release_group = release.get("release-group") if isinstance(release.get("release-group"), dict) else {}
    title = clean_text(release.get("title") or release_group.get("title"))
    if not title:
        continue
    artist = artist_credit_text(release.get("artist-credit")) or artist_credit_text(release_group.get("artist-credit"))
    date = clean_text(release.get("date") or release_group.get("first-release-date"))
    media = [medium for medium in (release.get("media") or []) if isinstance(medium, dict)]
    medium_candidates = [medium_details(medium) for medium in media]
    matching_media = [medium for medium in medium_candidates if medium["track_count_matches"]]
    if not matching_media:
        continue
    best_medium = max(
        enumerate(matching_media),
        key=lambda item: (item[1]["score"], -item[0]),
    )[1]
    score = best_medium["score"]
    status = clean_text(release.get("status"))
    if status.lower() == "official":
        score += 20
    if date:
        score += 5
    folder = safe_folder(artist, title, date)
    if not folder or folder in {".", ".."}:
        continue
    candidates.append({
        "score": score,
        "source_index": source_index,
        "release_id": clean_text(release.get("id")),
        "title": title,
        "artist": artist,
        "date": date,
        "country": clean_text(release.get("country")),
        "status": status,
        "barcode": clean_text(release.get("barcode")),
        "medium_position": best_medium["position"],
        "medium_format": best_medium["format"],
        "track_count": best_medium["track_count"],
        "disc_id_matches": best_medium["disc_id_matches"],
        "folder": folder,
    })

if any(candidate["disc_id_matches"] for candidate in candidates):
    candidates = [candidate for candidate in candidates if candidate["disc_id_matches"]]
candidates.sort(key=lambda candidate: (
    -candidate["score"],
    candidate["release_id"] or "~",
    candidate["artist"].casefold(),
    candidate["title"].casefold(),
    candidate["date"],
    candidate["country"],
    str(candidate["medium_position"] or ""),
    candidate["source_index"],
))
unique_candidates = []
seen_candidates = set()
for candidate in candidates:
    identity = candidate["release_id"] or (
        candidate["artist"],
        candidate["title"],
        candidate["date"],
        candidate["country"],
        candidate["medium_position"],
    )
    if identity in seen_candidates:
        continue
    seen_candidates.add(identity)
    unique_candidates.append(candidate)
candidates = unique_candidates
if not candidates:
    raise SystemExit(1)
if len(candidates) > 1000:
    print(
        f"Warning: MusicBrainz returned {len(candidates)} candidates; only the first 1000 will be selectable.",
        file=sys.stderr,
    )
    candidates = candidates[:1000]

temporary_path = candidate_path + ".tmp"
with open(temporary_path, "w", encoding="utf-8", newline="\n") as handle:
    json.dump(candidates, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
os.replace(temporary_path, candidate_path)
print(len(candidates))
PY
}

render_musicbrainz_release_candidates() {
  local candidate_path="$1"

  python3 - "$candidate_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    candidates = json.load(handle)

print("Multiple MusicBrainz releases match this disc:")
for index, candidate in enumerate(candidates, start=1):
    artist = candidate.get("artist") or "Unknown artist"
    title = candidate.get("title") or "Untitled"
    date = candidate.get("date") or "unknown date"
    country = candidate.get("country") or "unknown region"
    position = candidate.get("medium_position")
    disc = f"disc {position}" if position not in (None, "") else "disc ?"
    medium_format = candidate.get("medium_format") or "unknown medium"
    status = candidate.get("status") or "unknown status"
    release_id = candidate.get("release_id") or "no MBID"
    print(f"  [{index}] {artist} - {title} | {date} | {country} | {disc}, {medium_format} | {status} | {release_id}")
PY
}

choose_musicbrainz_release_index() {
  local candidate_path="$1"
  local candidate_count="$2"
  local requested_index="$3"
  local tty_input="${4:-/dev/tty}"
  local tty_output="${5:-/dev/tty}"
  local selection_input_fd selection_output_fd answer selected

  MUSICBRAINZ_SELECTED_INDEX=""

  [[ "$candidate_count" =~ ^([1-9][0-9]{0,2}|1000)$ ]] || {
    warn 'MusicBrainz returned no selectable releases'
    return 1
  }
  [[ "$requested_index" =~ ^(0|[1-9][0-9]{0,2}|1000)$ ]] || {
    warn "release index must be an integer from 0 through 1000: $requested_index"
    return 2
  }

  if ((10#$requested_index > 0)); then
    if ((10#$requested_index > 10#$candidate_count)); then
      warn "release index $requested_index is outside the available range 1..$candidate_count; keeping the timestamp folder"
      return 2
    fi
    if ((10#$candidate_count > 1)); then
      render_musicbrainz_release_candidates "$candidate_path" >&2
    fi
    printf 'MusicBrainz release %d/%d selected by --release-index.\n' \
      "$((10#$requested_index))" "$((10#$candidate_count))" >&2
    MUSICBRAINZ_SELECTED_INDEX="$((10#$requested_index))"
    return 0
  fi

  if ((10#$candidate_count == 1)); then
    MUSICBRAINZ_SELECTED_INDEX=1
    return 0
  fi

  if [[ ! -r "$tty_input" || ! -w "$tty_output" ]] ||
     ! { exec {selection_input_fd}<"$tty_input"; } 2>/dev/null; then
    render_musicbrainz_release_candidates "$candidate_path" >&2
    warn "multiple MusicBrainz releases match this disc, but no interactive terminal is available; keeping the timestamp folder. Use --release-index 1..$candidate_count or CDROM_RELEASE_INDEX for unattended runs"
    return 1
  fi
  if ! { exec {selection_output_fd}>>"$tty_output"; } 2>/dev/null; then
    exec {selection_input_fd}<&-
    render_musicbrainz_release_candidates "$candidate_path" >&2
    warn "multiple MusicBrainz releases match this disc, but no interactive terminal is available; keeping the timestamp folder. Use --release-index 1..$candidate_count or CDROM_RELEASE_INDEX for unattended runs"
    return 1
  fi
  render_musicbrainz_release_candidates "$candidate_path" >&"$selection_output_fd"
  while true; do
    printf 'Select MusicBrainz release [1-%d], or q to keep the timestamp folder: ' \
      "$((10#$candidate_count))" >&"$selection_output_fd"
    if ! IFS= read -r answer <&"$selection_input_fd"; then
      exec {selection_input_fd}<&-
      exec {selection_output_fd}>&-
      warn 'MusicBrainz release selection ended without a choice; keeping the timestamp folder'
      return 1
    fi
    if [[ "$answer" =~ ^[[:space:]]*[qQ][[:space:]]*$ ]]; then
      exec {selection_input_fd}<&-
      exec {selection_output_fd}>&-
      warn 'MusicBrainz release selection skipped; keeping the timestamp folder'
      return 1
    fi
    if [[ "$answer" =~ ^[[:space:]]*([1-9][0-9]{0,2}|1000)[[:space:]]*$ ]]; then
      selected="$((10#${BASH_REMATCH[1]}))"
      if ((selected >= 1 && selected <= 10#$candidate_count)); then
        exec {selection_input_fd}<&-
        exec {selection_output_fd}>&-
        MUSICBRAINZ_SELECTED_INDEX="$selected"
        return 0
      fi
    fi
    printf 'Invalid selection. Enter a number from 1 to %d, or q.\n' \
      "$((10#$candidate_count))" >&"$selection_output_fd"
  done
}

resolve_musicbrainz_album_folder() {
  local candidate_path="$1"
  local selected_index="$2"

  python3 - "$candidate_path" "$selected_index" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    candidates = json.load(handle)
selected_index = int(sys.argv[2])
if selected_index < 1 or selected_index > len(candidates):
    raise SystemExit(1)
folder = candidates[selected_index - 1].get("folder")
if not folder:
    raise SystemExit(1)
print(folder)
PY
}

write_musicbrainz_release_selection() {
  local candidate_path="$1"
  local selected_index="$2"

  python3 - "$candidate_path" "$selected_index" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    candidates = json.load(handle)
selected_index = int(sys.argv[2])
candidate = candidates[selected_index - 1]
print(f"MusicBrainz release candidates: {len(candidates)}")
print(f"Selected release index: {selected_index}")
print(f"Selected MusicBrainz Release ID: {candidate.get('release_id') or ''}")
print(f"Selected release: {candidate.get('artist') or ''} - {candidate.get('title') or ''}")
print(f"Selected release date/country: {candidate.get('date') or ''} / {candidate.get('country') or ''}")
PY
}

move_directory_to_unique_path() {
  local source_path="$1"
  local base_destination="$2"
  local candidate_destination suffix

  [[ -d "$source_path" ]] || return 1
  suffix=1
  while true; do
    if ((suffix == 1)); then
      candidate_destination="$base_destination"
    else
      candidate_destination="$base_destination-$suffix"
    fi
    if [[ -e "$candidate_destination" ]]; then
      ((suffix += 1))
      continue
    fi
    if mv -T -- "$source_path" "$candidate_destination"; then
      MOVED_DIRECTORY="$candidate_destination"
      return 0
    fi
    # A concurrent process may have claimed the path between the existence
    # check and rename. Retry only for that case; other failures are fatal.
    if [[ -e "$candidate_destination" && -d "$source_path" ]]; then
      ((suffix += 1))
      continue
    fi
    return 1
  done
}

cleanup() {
  local work_parent work_base

  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    work_parent="$(dirname -- "$WORK_DIR")"
    work_base="$(basename -- "$WORK_DIR")"
    if [[ "$work_parent" == "$OUTPUT_DIR" && "$work_base" == ".${IMAGE_NAME}.partial."* ]]; then
      if ((KEEP_WORK_DIR == 0)); then
        rm -rf --one-file-system -- "$WORK_DIR"
      else
        warn "read data was preserved for recovery at $WORK_DIR"
      fi
    fi
  fi
}

enable_work_dir_preservation() {
  KEEP_WORK_DIR=1
  trap 'warn "interrupted after a successful read; data remains at $WORK_DIR"; exit 130' INT
  trap 'warn "terminated after a successful read; data remains at $WORK_DIR"; exit 143' TERM
  trap 'warn "session ended after a successful read; data remains at $WORK_DIR"; exit 129' HUP
}

run_logged_read_command() {
  local working_directory="$1"
  local log_path="$2"
  local preserve_on_success="$3"
  local command_status tee_status
  local -a pipeline_status
  shift 3

  if (
      cd "$working_directory"
      "$@"
    ) 2>&1 | tee "$log_path"; then
    pipeline_status=("${PIPESTATUS[@]}")
  else
    pipeline_status=("${PIPESTATUS[@]}")
  fi
  command_status="${pipeline_status[0]:-125}"
  tee_status="${pipeline_status[1]:-125}"

  if ((preserve_on_success && command_status == 0 && KEEP_WORK_DIR == 0)); then
    enable_work_dir_preservation
  fi
  if ((command_status != 0)); then
    return "$command_status"
  fi
  if ((tee_status != 0)); then
    return "$tee_status"
  fi
  return 0
}

main() {

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
    --verify-passes)
      need_value "$@"
      VERIFY_PASSES="$2"
      shift 2
      ;;
    --verify-speed)
      need_value "$@"
      VERIFY_SPEED="$2"
      shift 2
      ;;
    --release-index)
      need_value "$@"
      RELEASE_INDEX="$2"
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

if [[ -z "$IMAGE_NAME" ]]; then
  IMAGE_NAME="cdrom-$(date +%Y%m%d-%H%M%S)"
fi
[[ "$IMAGE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die "name may contain only letters, numbers, dot, underscore, and hyphen"
[[ "$READ_SPEED" =~ ^$|^[1-9][0-9]*$ ]] || die "speed must be a positive integer"
[[ "$VERIFY_PASSES" =~ ^[12]$ ]] || die "verify passes must be 1 or 2"
[[ "$VERIFY_SPEED" =~ ^[1-9][0-9]*$ ]] || die "verify speed must be a positive integer"
[[ "$RELEASE_INDEX" =~ ^(0|[1-9][0-9]{0,2}|1000)$ ]] ||
  die "release index must be an integer from 0 through 1000"
if ((10#$RELEASE_INDEX > 0)) && ((!METADATA_LOOKUP || CUSTOM_NAME)); then
  die "--release-index requires metadata lookup and cannot be combined with --no-metadata or --name"
fi

for command_name in cdrdao sha256sum lsblk df mktemp realpath awk blockdev tee mv; do
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

FIRST_PASS_SPEED="$READ_SPEED"
SECOND_PASS_SPEED=""
if ((VERIFY_PASSES == 2)); then
  if [[ -z "$FIRST_PASS_SPEED" ]]; then
    FIRST_PASS_SPEED="$VERIFY_SPEED"
  fi
  SECOND_PASS_SPEED="$VERIFY_SPEED"
  if [[ -n "$READ_SPEED" ]] && ((10#$READ_SPEED < 10#$VERIFY_SPEED)); then
    SECOND_PASS_SPEED="$READ_SPEED"
  fi
fi

if ((DRY_RUN)); then
  printf 'Device:      %s\n' "$DEVICE"
  printf 'Destination: %s/%s\n' "$OUTPUT_DIR" "$IMAGE_NAME"
  if ((METADATA_LOOKUP && !CUSTOM_NAME)); then
    printf 'Folder name: album metadata when available; timestamp fallback\n'
    if ((10#$RELEASE_INDEX > 0)); then
      printf 'Release:    MusicBrainz candidate %d\n' "$((10#$RELEASE_INDEX))"
    else
      printf 'Release:    prompt if multiple MusicBrainz candidates match\n'
    fi
  fi
  printf 'Format:      BIN/TOC (raw sectors, paranoia mode 3)\n'
  if ((VERIFY_PASSES == 2)); then
    printf 'Verification: 2 independent reads; compare BIN and TOC SHA-256\n'
    printf 'Pass 1 speed: %sx\n' "$FIRST_PASS_SPEED"
    printf 'Pass 2 speed: %sx\n' "$SECOND_PASS_SPEED"
  else
    printf 'Verification: single read\n'
    [[ -z "$FIRST_PASS_SPEED" ]] || printf 'Read speed:   %sx\n' "$FIRST_PASS_SPEED"
  fi
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
required_bytes=0
if [[ "$disc_bytes" =~ ^[0-9]+$ ]] && ((disc_bytes > 0)); then
  required_bytes=$((disc_bytes * VERIFY_PASSES + 67108864))
fi
if [[ "$disc_bytes" =~ ^[0-9]+$ && "$available_bytes" =~ ^[0-9]+$ ]] &&
   ((required_bytes > 0 && available_bytes < required_bytes)); then
  die "not enough free space in $OUTPUT_DIR"
fi

WORK_DIR="$(mktemp -d --tmpdir="$OUTPUT_DIR" ".${IMAGE_NAME}.partial.XXXXXX")"

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

declare -a PASS_BIN_HASH=()
declare -a PASS_TOC_HASH=()
declare -a PASS_Q_CRC=()
declare -a PASS_SPEED=()

read_pass() {
  local pass_number="$1"
  local pass_speed="$2"
  local pass_dir="$WORK_DIR/.read-pass-$pass_number"
  local -a read_options=(
    read-cd
    --device "$DEVICE"
    --read-raw
    --paranoia-mode 3
  )

  if [[ -n "$pass_speed" ]]; then
    read_options+=(--rspeed "$pass_speed")
    PASS_SPEED[pass_number]="${pass_speed}x"
  else
    PASS_SPEED[pass_number]="drive default"
  fi

  mkdir -- "$pass_dir"
  printf 'Reading pass %d/%d from %s at %s ...\n' \
    "$pass_number" "$VERIFY_PASSES" "$DEVICE" "${PASS_SPEED[$pass_number]}"
  run_logged_read_command \
    "$pass_dir" \
    "$pass_dir/cdrdao.log" \
    "$((pass_number == 1))" \
    cdrdao "${read_options[@]}" \
      --datafile "$IMAGE_NAME.bin" \
      "$IMAGE_NAME.toc"

  PASS_BIN_HASH[pass_number]="$(sha256sum -- "$pass_dir/$IMAGE_NAME.bin" | awk '{ print $1 }')"
  PASS_TOC_HASH[pass_number]="$(sha256sum -- "$pass_dir/$IMAGE_NAME.toc" | awk '{ print $1 }')"
  PASS_Q_CRC[pass_number]="$(awk '
    /Q sub-channels with CRC errors/ {
      for (field = 1; field <= NF; field += 1) {
        if ($field == "Found" && $(field + 1) ~ /^[0-9]+$/) {
          total += $(field + 1)
        }
      }
    }
    END { print total + 0 }
  ' "$pass_dir/cdrdao.log")"

  printf 'Pass %d BIN SHA-256: %s\n' "$pass_number" "${PASS_BIN_HASH[$pass_number]}"
  printf 'Pass %d TOC SHA-256: %s\n' "$pass_number" "${PASS_TOC_HASH[$pass_number]}"
  printf 'Pass %d reported Q CRC frames: %s\n' "$pass_number" "${PASS_Q_CRC[$pass_number]}"
}

read_pass 1 "$FIRST_PASS_SPEED"
if ((VERIFY_PASSES == 2)); then
  read_pass 2 "$SECOND_PASS_SPEED"
fi

pass_one_dir="$WORK_DIR/.read-pass-1"
mv -- "$pass_one_dir/$IMAGE_NAME.bin" "$WORK_DIR/$IMAGE_NAME.bin"
mv -- "$pass_one_dir/$IMAGE_NAME.toc" "$WORK_DIR/$IMAGE_NAME.toc"
mv -- "$pass_one_dir/cdrdao.log" "$WORK_DIR/cdrdao-pass-1.log"
rmdir -- "$pass_one_dir"

if ((VERIFY_PASSES == 2)); then
  pass_two_dir="$WORK_DIR/.read-pass-2"
  mv -- "$pass_two_dir/cdrdao.log" "$WORK_DIR/cdrdao-pass-2.log"
  if [[ "${PASS_BIN_HASH[1]}" == "${PASS_BIN_HASH[2]}" &&
        "${PASS_TOC_HASH[1]}" == "${PASS_TOC_HASH[2]}" ]]; then
    VERIFY_RESULT="MATCH"
    rm -f -- "$pass_two_dir/$IMAGE_NAME.bin" "$pass_two_dir/$IMAGE_NAME.toc"
    rmdir -- "$pass_two_dir"
    printf 'Verification passed: both BIN and TOC hashes match.\n'
  else
    VERIFY_RESULT="MISMATCH"
    VERIFY_MISMATCH=1
    mv -- "$pass_two_dir" "$WORK_DIR/verification-pass-2"
    warn 'verification failed: the two reads do not have identical BIN/TOC hashes'
    warn 'both read results will be preserved; the disc will not be auto-ejected'
  fi
fi

{
  printf 'Created (UTC): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Requested passes: %s\n' "$VERIFY_PASSES"
  printf 'Result: %s\n' "$VERIFY_RESULT"
  for ((pass_number = 1; pass_number <= VERIFY_PASSES; pass_number += 1)); do
    printf 'Pass %d speed: %s\n' "$pass_number" "${PASS_SPEED[$pass_number]}"
    printf 'Pass %d BIN SHA-256: %s\n' "$pass_number" "${PASS_BIN_HASH[$pass_number]}"
    printf 'Pass %d TOC SHA-256: %s\n' "$pass_number" "${PASS_TOC_HASH[$pass_number]}"
    printf 'Pass %d reported Q CRC frames: %s\n' "$pass_number" "${PASS_Q_CRC[$pass_number]}"
  done
} > "$WORK_DIR/verification-report.txt"

cdrdao disk-info --device "$DEVICE" > "$WORK_DIR/disc-info.txt" 2>&1 || true
{
  printf 'Created (UTC): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Host: %s\n' "$(hostname)"
  printf 'Source device: %s\n' "$DEVICE"
  printf 'Verification passes: %s\n' "$VERIFY_PASSES"
  printf 'Verification result: %s\n' "$VERIFY_RESULT"
  for ((pass_number = 1; pass_number <= VERIFY_PASSES; pass_number += 1)); do
    printf 'Pass %d reported Q CRC frames: %s\n' "$pass_number" "${PASS_Q_CRC[$pass_number]}"
  done
  lsblk -dn -o NAME,VENDOR,MODEL,REV,SIZE,TYPE "$DEVICE" || true
} > "$WORK_DIR/dump-metadata.txt"

(
  cd "$WORK_DIR"
  checksum_paths=("$IMAGE_NAME.bin" "$IMAGE_NAME.toc")
  if ((VERIFY_MISMATCH)); then
    checksum_paths+=(
      "verification-pass-2/$IMAGE_NAME.bin"
      "verification-pass-2/$IMAGE_NAME.toc"
    )
  fi
  sha256sum -- "${checksum_paths[@]}" > SHA256SUMS
)

# The raw image and verification artifacts are complete at this point. Persist
# them before any optional network lookup or interactive release selection so
# Ctrl+C, SSH disconnects, and metadata failures cannot delete a finished read.
KEEP_WORK_DIR=1
base_persisted_dir="$OUTPUT_DIR/$IMAGE_NAME"
move_directory_to_unique_path "$WORK_DIR" "$base_persisted_dir" ||
  die "could not rename the completed image; it remains at $WORK_DIR"
PERSISTED_DIR="$MOVED_DIRECTORY"
if ((CUSTOM_NAME)) && [[ "$PERSISTED_DIR" != "$base_persisted_dir" ]]; then
  warn "the requested destination appeared while the disc was being read; preserving this dump as $PERSISTED_DIR"
fi
WORK_DIR="$PERSISTED_DIR"
trap 'warn "interrupted after the completed image was preserved at $WORK_DIR"; exit 130' INT
trap 'warn "terminated after the completed image was preserved at $WORK_DIR"; exit 143' TERM
trap 'warn "session ended after the completed image was preserved at $WORK_DIR"; exit 129' HUP

lookup_album_folder() {
  local toc_path="$1"
  local bin_path="$2"
  local cache_dir cache_file cache_age disc_info disc_id toc_encoded track_count
  local metadata_json metadata_tmp metadata_source base_url lookup_url album_folder
  local candidate_json candidate_count selected_release_index selection_metadata selection_status

  RESOLVED_ALBUM_FOLDER=""

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
          --user-agent 'dump-cdrom/2.3 (https://github.com/Gavin-LHX/cdrom-dump-tools)' \
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

  candidate_json="$WORK_DIR/musicbrainz-release-candidates.json"
  candidate_count="$(prepare_musicbrainz_release_candidates \
    "$metadata_json" "$disc_id" "$track_count" "$candidate_json")" || {
    warn 'metadata was returned but no release has a medium with the expected track count; keeping the timestamp folder'
    return 1
  }
  [[ "$candidate_count" =~ ^[1-9][0-9]*$ ]] || {
    warn 'metadata was returned but no selectable MusicBrainz release was resolved; keeping the timestamp folder'
    return 1
  }

  if choose_musicbrainz_release_index \
      "$candidate_json" "$candidate_count" "$RELEASE_INDEX"; then
    selected_release_index="$MUSICBRAINZ_SELECTED_INDEX"
  else
    selection_status=$?
    {
      printf 'MusicBrainz Disc ID: %s\n' "$disc_id"
      printf 'Metadata source: %s\n' "$metadata_source"
      printf 'MusicBrainz release candidates: %s\n' "$candidate_count"
      printf 'Release selection: unresolved; timestamp folder retained\n'
    } >> "$WORK_DIR/dump-metadata.txt"
    return "$selection_status"
  fi

  album_folder="$(resolve_musicbrainz_album_folder \
    "$candidate_json" "$selected_release_index")" || {
    warn 'the selected MusicBrainz release could not produce a safe folder name; keeping the timestamp folder'
    return 1
  }
  selection_metadata="$(write_musicbrainz_release_selection \
    "$candidate_json" "$selected_release_index")" || {
    warn 'the selected MusicBrainz release could not be recorded; keeping the timestamp folder'
    return 1
  }

  [[ -n "$album_folder" ]] || return 1
  {
    printf 'MusicBrainz Disc ID: %s\n' "$disc_id"
    printf 'Metadata source: %s\n' "$metadata_source"
    printf '%s\n' "$selection_metadata"
    printf 'Resolved folder: %s\n' "$album_folder"
  } >> "$WORK_DIR/dump-metadata.txt"
  printf 'Album metadata: %s\n' "$metadata_source" >&2
  RESOLVED_ALBUM_FOLDER="$album_folder"
}

FINAL_NAME="$IMAGE_NAME"
if ((METADATA_LOOKUP && !CUSTOM_NAME)); then
  if lookup_album_folder "$WORK_DIR/$IMAGE_NAME.toc" "$WORK_DIR/$IMAGE_NAME.bin"; then
    FINAL_NAME="$RESOLVED_ALBUM_FOLDER"
  elif ((10#$RELEASE_INDEX > 0)); then
    METADATA_SELECTION_FAILED=1
  fi
fi

FINAL_DIR="$WORK_DIR"
if [[ "$FINAL_NAME" != "$IMAGE_NAME" ]]; then
  base_final_dir="$OUTPUT_DIR/$FINAL_NAME"
  if move_directory_to_unique_path "$WORK_DIR" "$base_final_dir"; then
    FINAL_DIR="$MOVED_DIRECTORY"
    WORK_DIR="$FINAL_DIR"
  else
    FINAL_DIR="$WORK_DIR"
    warn "album metadata was resolved, but the completed image could not be renamed; keeping $FINAL_DIR"
  fi
fi

if ((EUID == 0)) && [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  owner_group="$(id -gn "$SUDO_USER")"
  chown -R -- "$SUDO_USER:$owner_group" "$FINAL_DIR"
fi

if ((EJECT_AFTER && !VERIFY_MISMATCH)); then
  eject "$DEVICE"
fi

printf 'Done. Image: %s/%s.bin\n' "$FINAL_DIR" "$IMAGE_NAME"
printf 'TOC:        %s/%s.toc\n' "$FINAL_DIR" "$IMAGE_NAME"
printf 'Checksums:  %s/SHA256SUMS\n' "$FINAL_DIR"
printf 'Verify log: %s/verification-report.txt\n' "$FINAL_DIR"

trap - INT TERM HUP
WORK_DIR=""

if ((VERIFY_MISMATCH)); then
  warn "verification mismatch: pass 1 is the canonical image in $FINAL_DIR"
  warn "pass 2 is preserved in $FINAL_DIR/verification-pass-2"
  warn 'inspect verification-report.txt and both cdrdao logs; exit status is 2'
  exit 2
fi
if ((METADATA_SELECTION_FAILED)); then
  warn "the requested MusicBrainz release index was not applied; the completed image remains at $FINAL_DIR"
  exit 3
fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
