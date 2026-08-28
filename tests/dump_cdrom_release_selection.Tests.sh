#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../dump_cdrom.sh
source "$REPO_ROOT/dump_cdrom.sh"

fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

if bash "$REPO_ROOT/dump_cdrom.sh" --release-index 1001 \
    >"$fixture/invalid-index.txt" 2>&1; then
  printf 'An invalid release index reached device validation.\n' >&2
  exit 1
fi
grep -F 'release index must be an integer from 0 through 1000' \
  "$fixture/invalid-index.txt" >/dev/null
if bash "$REPO_ROOT/dump_cdrom.sh" --release-index 2 --no-metadata \
    >"$fixture/conflicting-options.txt" 2>&1; then
  printf 'Conflicting release-selection options reached device validation.\n' >&2
  exit 1
fi
grep -F -- '--release-index requires metadata lookup' \
  "$fixture/conflicting-options.txt" >/dev/null

metadata="$fixture/musicbrainz.json"
candidates="$fixture/candidates.json"
reversed_metadata="$fixture/musicbrainz-reversed.json"
reversed_candidates="$fixture/candidates-reversed.json"
nonmatching_metadata="$fixture/musicbrainz-nonmatching.json"
malicious_metadata="$fixture/musicbrainz-malicious.json"
malicious_candidates="$fixture/candidates-malicious.json"

cat >"$metadata" <<'JSON'
{
  "releases": [
    {
      "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      "title": "通常盤",
      "date": "2016-12-30",
      "country": "JP",
      "status": "Official",
      "artist-credit": [{"name": "compllege", "joinphrase": ""}],
      "media": [{
        "position": 1,
        "format": "CD",
        "track-count": 2,
        "discs": [{"id": "test-disc-id"}]
      }]
    },
    {
      "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "title": "初回盤",
      "date": "2016-10-27",
      "country": "JP",
      "status": "Official",
      "artist-credit": [{"name": "compllege", "joinphrase": ""}],
      "media": [{
        "position": 2,
        "format": "CD",
        "track-count": 2,
        "discs": [{"id": "test-disc-id"}]
      }]
    },
    {
      "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "title": "初回盤",
      "date": "2016-10-27",
      "country": "JP",
      "status": "Official",
      "artist-credit": [{"name": "compllege", "joinphrase": ""}],
      "media": [{
        "position": 2,
        "format": "CD",
        "track-count": 2,
        "discs": [{"id": "test-disc-id"}]
      }]
    },
    {
      "id": "00000000-0000-0000-0000-000000000000",
      "title": "wrong track count",
      "date": "2026-01-01",
      "country": "US",
      "status": "Official",
      "artist-credit": [{"name": "Wrong Artist", "joinphrase": ""}],
      "media": [{
        "position": 1,
        "format": "CD",
        "track-count": 3,
        "discs": [{"id": "test-disc-id"}]
      }]
    }
  ]
}
JSON

candidate_count="$(prepare_musicbrainz_release_candidates \
  "$metadata" test-disc-id 2 "$candidates")"
[[ "$candidate_count" == 2 ]] || {
  printf 'Expected two unique, track-count-matched candidates; got %s.\n' "$candidate_count" >&2
  exit 1
}

python3 - "$candidates" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    candidates = json.load(handle)
assert [item["release_id"] for item in candidates] == [
    "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
]
assert candidates[0]["title"] == "初回盤"
assert candidates[0]["folder"] == "compllege - 初回盤 (2016) [BIN-TOC]"
assert all(item["track_count"] == 2 for item in candidates)
PY

python3 - "$metadata" "$reversed_metadata" "$nonmatching_metadata" <<'PY'
import json
import sys

source_path, reversed_path, nonmatching_path = sys.argv[1:4]
with open(source_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
with open(reversed_path, "w", encoding="utf-8") as handle:
    json.dump({"releases": list(reversed(payload["releases"]))}, handle, ensure_ascii=False)
with open(nonmatching_path, "w", encoding="utf-8") as handle:
    json.dump({"releases": [payload["releases"][-1]]}, handle, ensure_ascii=False)
PY

reversed_count="$(prepare_musicbrainz_release_candidates \
  "$reversed_metadata" test-disc-id 2 "$reversed_candidates")"
[[ "$reversed_count" == 2 ]] || exit 1
python3 - "$candidates" "$reversed_candidates" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    first = json.load(handle)
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    second = json.load(handle)
assert [item["release_id"] for item in first] == [item["release_id"] for item in second]
assert [item["title"] for item in first] == [item["title"] for item in second]
PY

if prepare_musicbrainz_release_candidates \
    "$nonmatching_metadata" test-disc-id 2 "$fixture/nonmatching-candidates.json" >/dev/null 2>&1; then
  printf 'A release whose medium has the wrong track count was accepted.\n' >&2
  exit 1
fi

cat >"$malicious_metadata" <<'JSON'
{
  "releases": [{
    "title": "\u001b[31mUnsafe\u001b[0m",
    "date": "2020-01-01",
    "country": "JP",
    "status": "Official",
    "artist-credit": [{"name": "Artist", "joinphrase": ""}],
    "media": [{
      "position": {"unexpected": "\u001b[2J"},
      "format": "CD",
      "track-count": 2,
      "discs": [{"id": "test-disc-id"}]
    }]
  }]
}
JSON
malicious_count="$(prepare_musicbrainz_release_candidates \
  "$malicious_metadata" test-disc-id 2 "$malicious_candidates")"
[[ "$malicious_count" == 1 ]] || exit 1
render_musicbrainz_release_candidates "$malicious_candidates" \
  >"$fixture/malicious-render.txt"
python3 - "$malicious_candidates" "$fixture/malicious-render.txt" <<'PY'
import json
import sys
import unicodedata

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    candidate = json.load(handle)[0]
assert candidate["medium_position"] is None
assert not any(unicodedata.category(character).startswith("C") for character in candidate["title"])
with open(sys.argv[2], "rb") as handle:
    assert b"\x1b" not in handle.read()
PY

choose_musicbrainz_release_index "$candidates" 2 2
[[ "$MUSICBRAINZ_SELECTED_INDEX" == 2 ]] || {
  printf 'Explicit release selection returned %q instead of 2.\n' \
    "$MUSICBRAINZ_SELECTED_INDEX" >&2
  exit 1
}

if choose_musicbrainz_release_index "$candidates" 2 3 >/dev/null 2>&1; then
  printf 'An out-of-range release index was accepted.\n' >&2
  exit 1
fi
if choose_musicbrainz_release_index "$candidates" 2 invalid >/dev/null 2>&1; then
  printf 'A nonnumeric release index was accepted.\n' >&2
  exit 1
fi

noninteractive_error="$fixture/noninteractive-error.txt"
if choose_musicbrainz_release_index \
    "$candidates" 2 0 "$fixture/missing-input" "$fixture/missing-output" \
    2>"$noninteractive_error"; then
  printf 'Multiple releases were silently selected without a terminal.\n' >&2
  exit 1
fi
[[ -z "$MUSICBRAINZ_SELECTED_INDEX" ]] || {
  printf 'Noninteractive fallback returned a selection: %q\n' \
    "$MUSICBRAINZ_SELECTED_INDEX" >&2
  exit 1
}
grep -F -- '--release-index 1..2' "$noninteractive_error" >/dev/null

unopenable_error="$fixture/unopenable-error.txt"
if choose_musicbrainz_release_index \
    "$candidates" 2 0 "$fixture" "$fixture" \
    >/dev/null 2>"$unopenable_error"; then
  printf 'A terminal path that could not be opened triggered a selection.\n' >&2
  exit 1
fi
grep -F 'no interactive terminal is available' "$unopenable_error" >/dev/null

selection_input="$fixture/selection-input.txt"
selection_output="$fixture/selection-output.txt"
printf 'not-a-number\n18446744073709551617\n2\n' >"$selection_input"
: >"$selection_output"
choose_musicbrainz_release_index \
  "$candidates" 2 0 "$selection_input" "$selection_output"
[[ "$MUSICBRAINZ_SELECTED_INDEX" == 2 ]] || {
  printf 'Interactive release selection returned %q instead of 2.\n' \
    "$MUSICBRAINZ_SELECTED_INDEX" >&2
  exit 1
}
grep -F '初回盤' "$selection_output" >/dev/null
grep -F '通常盤' "$selection_output" >/dev/null
grep -F 'Invalid selection.' "$selection_output" >/dev/null

cancel_input="$fixture/cancel-input.txt"
cancel_output="$fixture/cancel-output.txt"
printf 'q\n' >"$cancel_input"
: >"$cancel_output"
if choose_musicbrainz_release_index \
    "$candidates" 2 0 "$cancel_input" "$cancel_output" >/dev/null 2>&1; then
  printf 'The q selection did not keep the timestamp fallback.\n' >&2
  exit 1
fi

single_candidate="$fixture/single-candidate.json"
python3 - "$candidates" "$single_candidate" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    candidates = json.load(handle)
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(candidates[:1], handle, ensure_ascii=False)
PY
choose_musicbrainz_release_index \
  "$single_candidate" 1 0 "$fixture/missing-input" "$fixture/missing-output"
[[ "$MUSICBRAINZ_SELECTED_INDEX" == 1 ]] || exit 1

resolved_folder="$(resolve_musicbrainz_album_folder "$candidates" 2)"
[[ "$resolved_folder" == 'compllege - 通常盤 (2016) [BIN-TOC]' ]] || exit 1
selection_metadata="$(write_musicbrainz_release_selection "$candidates" 2)"
grep -F 'Selected release index: 2' <<<"$selection_metadata" >/dev/null
grep -F 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' <<<"$selection_metadata" >/dev/null

move_source="$fixture/move-source"
move_destination="$fixture/move-destination"
mkdir -- "$move_source" "$move_destination"
printf 'preserve me\n' >"$move_source/payload.txt"
move_directory_to_unique_path "$move_source" "$move_destination"
[[ "$MOVED_DIRECTORY" == "$move_destination-2" ]] || exit 1
[[ -f "$move_destination-2/payload.txt" ]] || exit 1

pipeline_root="$fixture/pipeline-root"
fake_bin="$fixture/fake-bin"
mkdir -- "$pipeline_root" "$fake_bin"
printf '#!/usr/bin/env bash\nexit 9\n' >"$fake_bin/tee"
chmod 0755 "$fake_bin/tee"
WORK_DIR="$pipeline_root/.pipeline-disc.partial.test"
mkdir -- "$WORK_DIR"
KEEP_WORK_DIR=0
if PATH="$fake_bin:$PATH" run_logged_read_command \
    "$WORK_DIR" "$WORK_DIR/read.log" 1 \
    bash -c 'printf "completed read\n"'; then
  printf 'A failed tee was reported as a successful logged read.\n' >&2
  exit 1
else
  pipeline_status=$?
fi
[[ "$pipeline_status" == 9 ]] || {
  printf 'The failed tee returned %s instead of 9.\n' "$pipeline_status" >&2
  exit 1
}
[[ "$KEEP_WORK_DIR" == 1 ]] || {
  printf 'A successful read was not preserved when tee failed.\n' >&2
  exit 1
}
trap - INT TERM HUP

OUTPUT_DIR="$fixture/cleanup-root"
IMAGE_NAME="cleanup-disc"
mkdir -- "$OUTPUT_DIR"
WORK_DIR="$OUTPUT_DIR/.${IMAGE_NAME}.partial.remove"
mkdir -- "$WORK_DIR"
# shellcheck disable=SC2034 # Read by cleanup() from the sourced script.
KEEP_WORK_DIR=0
cleanup
[[ ! -e "$WORK_DIR" ]] || {
  printf 'An incomplete partial directory was not cleaned up.\n' >&2
  exit 1
}
WORK_DIR="$OUTPUT_DIR/.${IMAGE_NAME}.partial.preserve"
mkdir -- "$WORK_DIR"
enable_work_dir_preservation
cleanup
[[ -d "$WORK_DIR" ]] || {
  printf 'A completed image marked for preservation was deleted.\n' >&2
  exit 1
}
trap - INT TERM HUP

signal_target="$fixture/signal-target"
if bash -c '
    set -Eeuo pipefail
    source "$1"
    WORK_DIR="$2"
    enable_work_dir_preservation
    kill -TERM "$$"
  ' _ "$REPO_ROOT/dump_cdrom.sh" "$signal_target" \
    >"$fixture/signal-output.txt" 2>"$fixture/signal-error.txt"; then
  printf 'The preservation TERM handler returned success.\n' >&2
  exit 1
else
  signal_status=$?
fi
[[ "$signal_status" == 143 ]] || {
  printf 'The preservation TERM handler returned %s instead of 143.\n' "$signal_status" >&2
  exit 1
}
grep -F "$signal_target" "$fixture/signal-error.txt" >/dev/null
WORK_DIR=""

# A task runner may signal only the main Bash PID, not the whole process group.
# Release selection must therefore wait in that shell rather than a command
# substitution child, or TERM/HUP can remain deferred forever at the prompt.
selection_fifo="$fixture/signal-selection-input"
selection_signal_target="$fixture/signal-selection-target"
mkfifo -- "$selection_fifo"
: >"$fixture/signal-selection-output.txt"
exec {selection_fifo_hold_fd}<>"$selection_fifo"
bash -c '
    set -Eeuo pipefail
    source "$1"
    WORK_DIR="$2"
    enable_work_dir_preservation
    choose_musicbrainz_release_index "$3" 2 0 "$4" "$5"
  ' _ "$REPO_ROOT/dump_cdrom.sh" "$selection_signal_target" "$candidates" \
  "$selection_fifo" "$fixture/signal-selection-output.txt" \
  >"$fixture/signal-selection-stdout.txt" 2>"$fixture/signal-selection-error.txt" &
selection_pid=$!
for _ in {1..100}; do
  if grep -F 'Select MusicBrainz release' \
      "$fixture/signal-selection-output.txt" >/dev/null; then
    break
  fi
  kill -0 "$selection_pid" 2>/dev/null || break
  sleep 0.02
done
kill -TERM "$selection_pid"
(
  sleep 5
  kill -KILL "$selection_pid" 2>/dev/null || true
) &
selection_watchdog_pid=$!
if wait "$selection_pid"; then
  selection_signal_status=0
else
  selection_signal_status=$?
fi
kill "$selection_watchdog_pid" 2>/dev/null || true
wait "$selection_watchdog_pid" 2>/dev/null || true
exec {selection_fifo_hold_fd}>&-
[[ "$selection_signal_status" == 143 ]] || {
  printf 'TERM while waiting for release selection returned %s instead of 143.\n' \
    "$selection_signal_status" >&2
  exit 1
}
grep -F "$selection_signal_target" \
  "$fixture/signal-selection-error.txt" >/dev/null

printf 'dump_cdrom MusicBrainz release-selection tests passed.\n'
