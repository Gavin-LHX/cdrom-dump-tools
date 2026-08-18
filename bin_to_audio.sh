#!/usr/bin/env bash

set -Eeuo pipefail

PROGRAM="$(basename "$0")"
FORMAT="flac"
TOC_FILE=""
OUTPUT_DIR=""
DRY_RUN=0
INPUT_BIN=""
WORK_DIR=""

usage() {
  cat <<EOF
Usage: $PROGRAM [options] DISC.bin

Split a raw CD-DA BIN image into individual lossless audio tracks by using
the matching cdrdao TOC file. FLAC is the default output format.

Options:
  -f, --format flac|wav    Output format (default: flac)
  -t, --toc FILE          TOC file (default: same path/name as DISC.bin)
  -o, --output-dir DIR    Destination directory
      --dry-run           Parse and validate without writing audio files
  -h, --help              Show this help

Examples:
  $PROGRAM /path/to/disc.bin
  $PROGRAM --format wav /path/to/disc.bin
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
    -f|--format)
      need_value "$@"
      FORMAT="${2,,}"
      shift 2
      ;;
    -t|--toc)
      need_value "$@"
      TOC_FILE="$2"
      shift 2
      ;;
    -o|--output-dir)
      need_value "$@"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$INPUT_BIN" ]] || die "only one BIN file may be supplied"
      INPUT_BIN="$1"
      shift
      ;;
  esac
done

[[ "$FORMAT" == flac || "$FORMAT" == wav ]] ||
  die "format must be 'flac' or 'wav'"
[[ -n "$INPUT_BIN" ]] || die "a BIN file is required"

for command_name in dd sox sha256sum stat realpath mktemp; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "required command not found: $command_name"
done
if [[ "$FORMAT" == flac ]]; then
  command -v flac >/dev/null 2>&1 || die "required command not found: flac"
  command -v metaflac >/dev/null 2>&1 || die "required command not found: metaflac"
else
  command -v soxi >/dev/null 2>&1 || die "required command not found: soxi"
fi

INPUT_BIN="$(realpath -e -- "$INPUT_BIN")"
[[ -f "$INPUT_BIN" && -r "$INPUT_BIN" ]] || die "cannot read BIN file: $INPUT_BIN"
[[ "${INPUT_BIN,,}" == *.bin ]] || die "input file must have a .bin extension"

if [[ -z "$TOC_FILE" ]]; then
  TOC_FILE="${INPUT_BIN%.*}.toc"
fi
TOC_FILE="$(realpath -e -- "$TOC_FILE")"
[[ -f "$TOC_FILE" && -r "$TOC_FILE" ]] || die "cannot read TOC file: $TOC_FILE"

bin_dir="$(dirname -- "$INPUT_BIN")"
bin_name="$(basename -- "$INPUT_BIN")"
disc_name="${bin_name%.*}"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$bin_dir/${disc_name}-${FORMAT}"
fi

declare -a start_specs=()
declare -a length_specs=()
declare -a isrc_values=()
declare -a toc_file_refs=()
track_count=0
current_track=0

track_pattern='^[[:space:]]*TRACK[[:space:]]+([^[:space:]]+)'
isrc_pattern='^[[:space:]]*ISRC[[:space:]]+"([^"]+)"'
file_pattern='^[[:space:]]*(FILE|AUDIOFILE)[[:space:]]+"([^"]+)"[[:space:]]+([^[:space:]]+)([[:space:]]+([^[:space:]]+))?'

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  if [[ "$line" =~ $track_pattern ]]; then
    track_type="${BASH_REMATCH[1]}"
    [[ "$track_type" == AUDIO ]] ||
      die "TOC contains a non-audio track ($track_type); this converter is for CD-DA audio"
    ((++track_count))
    current_track="$track_count"
    continue
  fi

  if [[ "$line" =~ $isrc_pattern && $current_track -gt 0 ]]; then
    isrc_values[$current_track]="${BASH_REMATCH[1]}"
    continue
  fi

  if [[ "$line" =~ $file_pattern ]]; then
    ((current_track > 0)) || die "TOC has FILE data before the first TRACK"
    [[ -z "${start_specs[$current_track]+x}" ]] ||
      die "track $current_track uses multiple source segments, which is not supported"
    toc_file_refs[$current_track]="${BASH_REMATCH[2]}"
    start_specs[$current_track]="${BASH_REMATCH[3]}"
    length_specs[$current_track]="${BASH_REMATCH[5]:-}"
  fi
done < "$TOC_FILE"

((track_count > 0)) || die "no audio tracks were found in $TOC_FILE"
for ((track = 1; track <= track_count; track++)); do
  [[ -n "${start_specs[$track]:-}" ]] || die "track $track has no FILE entry"
done

position_to_bytes() {
  local value="$1"
  local minutes seconds frames samples

  if [[ "$value" =~ ^([0-9]+):([0-9]{2}):([0-9]{2})$ ]]; then
    minutes=$((10#${BASH_REMATCH[1]}))
    seconds=$((10#${BASH_REMATCH[2]}))
    frames=$((10#${BASH_REMATCH[3]}))
    ((seconds < 60 && frames < 75)) || die "invalid MSF position: $value"
    printf '%s\n' "$(((minutes * 60 * 75 + seconds * 75 + frames) * 2352))"
  elif [[ "$value" =~ ^[0-9]+$ ]]; then
    samples=$((10#$value))
    printf '%s\n' "$((samples * 4))"
  else
    die "unsupported TOC position: $value"
  fi
}

bin_bytes="$(stat -c '%s' -- "$INPUT_BIN")"
declare -a offset_bytes=()
declare -a track_bytes=()

for ((track = 1; track <= track_count; track++)); do
  offset_bytes[$track]="$(position_to_bytes "${start_specs[$track]}")"
  if [[ -n "${length_specs[$track]:-}" ]]; then
    track_bytes[$track]="$(position_to_bytes "${length_specs[$track]}")"
  else
    track_bytes[$track]="$((bin_bytes - offset_bytes[$track]))"
  fi

  ((offset_bytes[$track] >= 0 && track_bytes[$track] > 0)) ||
    die "invalid byte range for track $track"
  ((offset_bytes[$track] + track_bytes[$track] <= bin_bytes)) ||
    die "track $track extends beyond the end of the BIN file"
  ((offset_bytes[$track] % 4 == 0 && track_bytes[$track] % 4 == 0)) ||
    die "track $track is not aligned to 16-bit stereo samples"
done

printf 'BIN:         %s\n' "$INPUT_BIN"
printf 'TOC:         %s\n' "$TOC_FILE"
printf 'Format:      %s\n' "$FORMAT"
printf 'Destination: %s\n' "$OUTPUT_DIR"
printf 'Tracks:      %d\n' "$track_count"

if ((DRY_RUN)); then
  for ((track = 1; track <= track_count; track++)); do
    printf '  track-%02d.%s  offset=%d bytes  length=%d bytes\n' \
      "$track" "$FORMAT" "${offset_bytes[$track]}" "${track_bytes[$track]}"
  done
  exit 0
fi

[[ ! -e "$OUTPUT_DIR" ]] || die "destination already exists: $OUTPUT_DIR"
output_parent="$(dirname -- "$OUTPUT_DIR")"
output_base="$(basename -- "$OUTPUT_DIR")"
mkdir -p -- "$output_parent"
output_parent="$(realpath -e -- "$output_parent")"
[[ -d "$output_parent" && -w "$output_parent" ]] ||
  die "destination parent is not writable: $output_parent"
OUTPUT_DIR="$output_parent/$output_base"

WORK_DIR="$(mktemp -d --tmpdir="$output_parent" ".${output_base}.partial.XXXXXX")"
current_temp=""

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    work_parent="$(dirname -- "$WORK_DIR")"
    work_base="$(basename -- "$WORK_DIR")"
    if [[ "$work_parent" == "$output_parent" && "$work_base" == ".${output_base}.partial."* ]]; then
      rm -rf --one-file-system -- "$WORK_DIR"
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for ((track = 1; track <= track_count; track++)); do
  printf -v output_name 'track-%02d.%s' "$track" "$FORMAT"
  output_path="$WORK_DIR/$output_name"

  printf 'Converting track %d/%d -> %s\n' "$track" "$track_count" "$output_name"
  dd if="$INPUT_BIN" \
    iflag=fullblock,skip_bytes,count_bytes \
    bs=4M \
    skip="${offset_bytes[$track]}" \
    count="${track_bytes[$track]}" \
    status=none |
    sox \
      -t raw -r 44100 -e signed-integer -b 16 -c 2 -B - \
      -t "$FORMAT" "$output_path"

  if [[ "$FORMAT" == flac ]]; then
    flac --test --silent -- "$output_path"
    metaflac --set-tag="TRACKNUMBER=$track" -- "$output_path"
    if [[ -n "${isrc_values[$track]:-}" ]]; then
      metaflac --set-tag="ISRC=${isrc_values[$track]}" -- "$output_path"
    fi
  else
    soxi "$output_path" >/dev/null
  fi
done

(
  cd "$WORK_DIR"
  sha256sum -- track-*."$FORMAT" > SHA256SUMS
  {
    printf '#EXTM3U\n'
    for ((track = 1; track <= track_count; track++)); do
      printf 'track-%02d.%s\n' "$track" "$FORMAT"
    done
  } > tracks.m3u8
)

mv -- "$WORK_DIR" "$OUTPUT_DIR"
WORK_DIR=""

if ((EUID == 0)) && [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  owner_group="$(id -gn "$SUDO_USER")"
  chown -R -- "$SUDO_USER:$owner_group" "$OUTPUT_DIR"
fi

printf 'Done. Converted tracks are in: %s\n' "$OUTPUT_DIR"
