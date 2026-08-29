#!/usr/bin/env bash

set -Eeuo pipefail

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[[ "${CI:-}" == 'true' ]] || die 'this destructive install/purge test may run only with CI=true'
[[ $# -eq 1 ]] || die 'usage: test_installed_package.sh PACKAGE.deb'

for command_name in \
    appstreamcli dbus-run-session desktop-file-validate dpkg dpkg-deb find grep \
    python3 readlink sha256sum sudo xvfb-run; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

package_path="$(readlink -f -- "$1")"
[[ -s "$package_path" ]] || die "package is missing or empty: $package_path"

work_directory="$(mktemp -d "${RUNNER_TEMP:-/tmp}/cdrom-dump-tools-installed-test.XXXXXX")"
installed=0
cleanup() {
    if ((installed)); then
        sudo apt-get purge -y cdrom-dump-tools >/dev/null || true
    fi
    rm -rf -- "$work_directory"
}
trap cleanup EXIT

expected_architecture="$(dpkg --print-architecture)"
[[ "$(dpkg-deb -f "$package_path" Package)" == 'cdrom-dump-tools' ]] || die 'unexpected Debian package name'
[[ "$(dpkg-deb -f "$package_path" Architecture)" == "$expected_architecture" ]] || \
    die "package architecture does not match this runner: $expected_architecture"
[[ "$(dpkg-deb -f "$package_path" Version)" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die 'invalid Debian version'

extracted="$work_directory/extracted"
mkdir -p -- "$extracted"
dpkg-deb -x "$package_path" "$extracted"
desktop-file-validate "$extracted/usr/share/applications/io.github.gavinlhx.CdromDumpTools.desktop"
appstreamcli validate --no-net "$extracted/usr/share/metainfo/io.github.gavinlhx.CdromDumpTools.metainfo.xml"
if command -v lintian >/dev/null 2>&1; then
    lintian \
        --fail-on error \
        --suppress-tags embedded-library,unstripped-binary-or-object \
        "$package_path"
fi

[[ -x "$extracted/usr/bin/cdrom-dump-tools" ]] || die 'launcher is missing or not executable'
[[ -x "$extracted/usr/lib/cdrom-dump-tools/runtime/powershell/pwsh" ]] || die 'bundled PowerShell is missing or not executable'
[[ -f "$extracted/usr/lib/cdrom-dump-tools/converter/bin_to_audio_windows.ps1" ]] || die 'enhanced converter is missing'
[[ -f "$extracted/usr/share/doc/cdrom-dump-tools/env.example" ]] || die 'blank environment template is missing'

if find "$extracted" -type f \( -name '.env' -o -name '*.pfx' -o -name '*.p12' \) -print -quit | grep -q .; then
    die 'package contains a real environment or signing-secret file'
fi
if grep -aERIl --exclude='env.example' \
    '^(OPENAI_API_KEY|ANTHROPIC_API_KEY|GOOGLE_TRANSLATE_API_KEY|MICROSOFT_TRANSLATOR_API_KEY)=.+' \
    "$extracted/usr" | grep -q .; then
    die 'package contains a populated API key assignment'
fi

sudo apt-get install -y "$package_path"
installed=1
command -v cdrom-dump-tools >/dev/null 2>&1 || die 'installed launcher is not on PATH'
cdrom-dump-tools --self-test
dbus-run-session -- xvfb-run -a cdrom-dump-tools --smoke-test

fixture="$work_directory/fixture"
output="$fixture/output"
mkdir -p -- "$fixture"
truncate -s 352800 "$fixture/test-disc.bin"
cat >"$fixture/test-disc.toc" <<'TOC'
CD_DA

TRACK AUDIO
NO COPY
NO PRE_EMPHASIS
TWO_CHANNEL_AUDIO
FILE "test-disc.bin" 0 00:02:00
TOC

/usr/lib/cdrom-dump-tools/runtime/powershell/pwsh \
    -NoLogo \
    -NoProfile \
    -NonInteractive \
    -File /usr/lib/cdrom-dump-tools/converter/bin_to_audio_windows.ps1 \
    -BinPath "$fixture/test-disc.bin" \
    -TocPath "$fixture/test-disc.toc" \
    -OutputDirectory "$output" \
    -FfmpegPath /usr/bin/ffmpeg \
    -Format flac \
    -NoMetadata \
    -NoCover \
    -NoLyrics \
    -NoNetEase \
    -NoQQMusic \
    -VerifyAudio \
    -NoPause

[[ -s "$output/track-01.flac" ]] || die 'installed converter did not create track-01.flac'
[[ -s "$output/audio-verification.json" ]] || die 'audio verification JSON is missing'
[[ -s "$output/audio-verification.txt" ]] || die 'audio verification text report is missing'
[[ -s "$output/SHA256SUMS.txt" ]] || die 'output checksum manifest is missing'

python3 - "$fixture/test-disc.bin" "$output/audio-verification.json" <<'PYTHON'
import hashlib
import json
import pathlib
import sys

source_path = pathlib.Path(sys.argv[1])
report_path = pathlib.Path(sys.argv[2])
expected_hash = hashlib.sha256(source_path.read_bytes()).hexdigest()
report = json.loads(report_path.read_text(encoding="utf-8-sig"))
assert report["schema"] == "cdrom-audio-verification-v1"
assert report["status"] == "passed"
assert report["track_count"] == 1
assert len(report["tracks"]) == 1
track = report["tracks"][0]
assert track["file"] == "track-01.flac"
assert track["sample_count"] == 88200
assert track["source_segment_sha256"] == expected_hash
assert track["decoded_output_pcm_sha256"] == expected_hash
assert track["match"] is True
PYTHON

(
    cd "$output"
    sha256sum --check SHA256SUMS.txt
)

sudo apt-get purge -y cdrom-dump-tools
installed=0
for removed_path in \
    /usr/bin/cdrom-dump-tools \
    /usr/lib/cdrom-dump-tools \
    /usr/lib/python3/dist-packages/cdrom_dump_tools \
    /usr/share/applications/io.github.gavinlhx.CdromDumpTools.desktop \
    /usr/share/metainfo/io.github.gavinlhx.CdromDumpTools.metainfo.xml \
    /usr/share/icons/hicolor/scalable/apps/io.github.gavinlhx.CdromDumpTools.svg; do
    [[ ! -e "$removed_path" ]] || die "package purge left installed path behind: $removed_path"
done

printf 'Installed-package validation passed: %s\n' "$package_path"
