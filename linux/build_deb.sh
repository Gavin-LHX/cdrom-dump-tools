#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C
export TZ=UTC

readonly POWERSHELL_VERSION='7.6.5'
readonly POWERSHELL_AMD64_SHA256='b34ab3b19acac1d3d4d0d3cfdb02acf62f457b0b6a962ff008132033f7566844'
readonly POWERSHELL_ARM64_SHA256='ed4084f215d8bce2edd23aa7cb1f1e7b0818e41363a635a22065d2701b6141df'

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd -P)"
GUI_PROJECT="$REPOSITORY_ROOT/gui/CdromDumpToolsGui/CdromDumpToolsGui.csproj"
CONVERTER_SCRIPT="$REPOSITORY_ROOT/bin_to_audio_windows.ps1"
APP_SOURCE="$SCRIPT_DIRECTORY/app/cdrom_dump_tools"
PACKAGING_DIRECTORY="$SCRIPT_DIRECTORY/packaging"

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

for command_name in awk curl date dpkg dpkg-deb du find git gzip install md5sum python3 sed sha256sum sort tar uname xargs; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

[[ -f "$GUI_PROJECT" ]] || die "GUI project was not found: $GUI_PROJECT"
[[ -f "$CONVERTER_SCRIPT" ]] || die "converter script was not found: $CONVERTER_SCRIPT"
[[ -d "$APP_SOURCE" ]] || die "Linux application source was not found: $APP_SOURCE"

project_version="$(awk -F '[<>]' '/<Version>/{ print $3; exit }' "$GUI_PROJECT")"
[[ -n "$project_version" ]] || die 'could not read the project version'
release_version="${VERSION:-$project_version}"
[[ "$release_version" == "$project_version" ]] || die "VERSION '$release_version' differs from project version '$project_version'"
[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "VERSION is not SemVer-like: $release_version"

python_version="$(sed -nE 's/^VERSION = "([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$APP_SOURCE/models.py")"
[[ "$python_version" == "${release_version%%-*}" ]] || die "Linux frontend version '$python_version' differs from '$release_version'"
converter_versions="$({ grep -Eo 'BinToAudioWindows/[0-9]+\.[0-9]+\.[0-9]+' "$CONVERTER_SCRIPT" || true; } | sed 's:BinToAudioWindows/::' | sort -u)"
[[ "$converter_versions" == "${release_version%%-*}" ]] || die "converter version '$converter_versions' differs from '$release_version'"

target_arch="${TARGET_ARCH:-$(dpkg --print-architecture)}"
case "$target_arch" in
    amd64)
        expected_machine='x86_64'
        powershell_arch='x64'
        powershell_sha256="$POWERSHELL_AMD64_SHA256"
        ;;
    arm64)
        expected_machine='aarch64'
        powershell_arch='arm64'
        powershell_sha256="$POWERSHELL_ARM64_SHA256"
        ;;
    *) die "unsupported TARGET_ARCH: $target_arch" ;;
esac
[[ "$(uname -m)" == "$expected_machine" ]] || die "native $target_arch build requires $expected_machine, found $(uname -m)"

debian_version="$(printf '%s' "$release_version" | sed -E 's/-/~/' )"
output_directory="${OUTPUT_DIR:-$REPOSITORY_ROOT/dist/linux-deb}"
mkdir -p -- "$output_directory"
output_directory="$(cd -- "$output_directory" && pwd -P)"
source_date_epoch="${SOURCE_DATE_EPOCH:-$(git -C "$REPOSITORY_ROOT" show -s --format=%ct HEAD)}"
[[ "$source_date_epoch" =~ ^[0-9]+$ ]] || die "SOURCE_DATE_EPOCH is not an integer: $source_date_epoch"
export SOURCE_DATE_EPOCH="$source_date_epoch"
release_date="$(date -u -d "@$source_date_epoch" '+%Y-%m-%d')"

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/cdrom-dump-tools-deb.XXXXXX")"
cleanup() {
    rm -rf -- "$work_directory"
}
trap cleanup EXIT

download_cache="${DOWNLOAD_CACHE_DIR:-$work_directory/downloads}"
mkdir -p -- "$download_cache"
powershell_archive="powershell-${POWERSHELL_VERSION}-linux-${powershell_arch}.tar.gz"
powershell_path="$download_cache/$powershell_archive"
if [[ ! -f "$powershell_path" ]] || ! printf '%s  %s\n' "$powershell_sha256" "$powershell_path" | sha256sum --check --status -; then
    temporary_download="$powershell_path.partial.$$"
    rm -f -- "$temporary_download"
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        --output "$temporary_download" \
        "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/${powershell_archive}"
    printf '%s  %s\n' "$powershell_sha256" "$temporary_download" | sha256sum --check -
    mv -- "$temporary_download" "$powershell_path"
fi

package_root="$work_directory/package"
install -d -m 0755 \
    "$package_root/DEBIAN" \
    "$package_root/usr/bin" \
    "$package_root/usr/lib/cdrom-dump-tools/converter" \
    "$package_root/usr/lib/cdrom-dump-tools/runtime/powershell" \
    "$package_root/usr/lib/python3/dist-packages/cdrom_dump_tools" \
    "$package_root/usr/share/applications" \
    "$package_root/usr/share/icons/hicolor/scalable/apps" \
    "$package_root/usr/share/metainfo" \
    "$package_root/usr/share/doc/cdrom-dump-tools"

tar -xzf "$powershell_path" -C "$package_root/usr/lib/cdrom-dump-tools/runtime/powershell"
powershell_root="$package_root/usr/lib/cdrom-dump-tools/runtime/powershell"
find "$powershell_root" -type d -exec chmod 0755 {} +
find "$powershell_root" -type f -exec chmod 0644 {} +
find "$powershell_root" -type f \( -name 'pwsh' -o -name 'createdump' \) -exec chmod 0755 {} +
# The single-quoted command is intentionally passed literally to PowerShell.
# shellcheck disable=SC2016
powershell_reported_version="$("$package_root/usr/lib/cdrom-dump-tools/runtime/powershell/pwsh" -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
[[ "$powershell_reported_version" == "$POWERSHELL_VERSION" ]] || die "bundled PowerShell reported '$powershell_reported_version'"

install -m 0755 "$PACKAGING_DIRECTORY/cdrom-dump-tools" "$package_root/usr/bin/cdrom-dump-tools"
install -m 0644 "$CONVERTER_SCRIPT" "$package_root/usr/lib/cdrom-dump-tools/converter/bin_to_audio_windows.ps1"
find "$APP_SOURCE" -maxdepth 1 -type f -name '*.py' -print0 | while IFS= read -r -d '' source_file; do
    install -m 0644 "$source_file" "$package_root/usr/lib/python3/dist-packages/cdrom_dump_tools/$(basename -- "$source_file")"
done
install -m 0644 "$PACKAGING_DIRECTORY/io.github.gavinlhx.CdromDumpTools.desktop" "$package_root/usr/share/applications/"
install -m 0644 "$PACKAGING_DIRECTORY/io.github.gavinlhx.CdromDumpTools.svg" "$package_root/usr/share/icons/hicolor/scalable/apps/"
sed -e "s/@VERSION@/$release_version/g" -e "s/@RELEASE_DATE@/$release_date/g" \
    "$PACKAGING_DIRECTORY/io.github.gavinlhx.CdromDumpTools.metainfo.xml.in" \
    >"$package_root/usr/share/metainfo/io.github.gavinlhx.CdromDumpTools.metainfo.xml"
install -m 0644 "$REPOSITORY_ROOT/README.md" "$package_root/usr/share/doc/cdrom-dump-tools/README.md"
install -m 0644 "$SCRIPT_DIRECTORY/README.md" "$package_root/usr/share/doc/cdrom-dump-tools/README.Linux.md"
install -m 0644 "$REPOSITORY_ROOT/.env.example" "$package_root/usr/share/doc/cdrom-dump-tools/env.example"
install -m 0644 "$package_root/usr/lib/cdrom-dump-tools/runtime/powershell/LICENSE.txt" "$package_root/usr/share/doc/cdrom-dump-tools/PowerShell.LICENSE.txt"
install -m 0644 "$package_root/usr/lib/cdrom-dump-tools/runtime/powershell/ThirdPartyNotices.txt" "$package_root/usr/share/doc/cdrom-dump-tools/PowerShell.ThirdPartyNotices.txt"

cat >"$package_root/usr/share/doc/cdrom-dump-tools/copyright" <<'COPYRIGHT'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: cdrom-dump-tools
Source: https://github.com/Gavin-LHX/cdrom-dump-tools

Files: *
Copyright: 2026 Gavin-LHX
License: LicenseRef-Proprietary
 No project-wide license file was present in the upstream source at package
 build time. No additional redistribution permission is asserted here.

Files: usr/share/metainfo/io.github.gavinlhx.CdromDumpTools.metainfo.xml
Copyright: 2026 Gavin-LHX
License: CC0-1.0
 On Debian systems the complete CC0 1.0 text is available at
 /usr/share/common-licenses/CC0-1.0.

Files: usr/lib/cdrom-dump-tools/runtime/powershell/*
Copyright: .NET Foundation and Contributors
License: MIT
 See /usr/share/doc/cdrom-dump-tools/PowerShell.LICENSE.txt.
COPYRIGHT

cat >"$work_directory/changelog" <<EOF
cdrom-dump-tools ($debian_version) unstable; urgency=medium

  * Add the native GNOME interface with complete metadata and lyrics support.
  * Include translation fallbacks and verified lossless audio conversion.

 -- Gavin-LHX <noreply@github.com>  $(date -u -d "@$source_date_epoch" -R)
EOF
gzip -n -9 <"$work_directory/changelog" >"$package_root/usr/share/doc/cdrom-dump-tools/changelog.gz"

installed_size="$(du -sk "$package_root/usr" | awk '{print $1}')"
sed \
    -e "s/@DEBIAN_VERSION@/$debian_version/g" \
    -e "s/@ARCHITECTURE@/$target_arch/g" \
    -e "s/@INSTALLED_SIZE@/$installed_size/g" \
    "$PACKAGING_DIRECTORY/control.in" >"$package_root/DEBIAN/control"

(
    cd "$package_root"
    find usr -type f -print0 | sort -z | xargs -0 md5sum >DEBIAN/md5sums
)
find "$package_root" -print0 | xargs -0 touch --no-dereference -d "@$source_date_epoch"

asset_name="cdrom-dump-tools-${release_version}-ubuntu-debian-${target_arch}.deb"
dpkg-deb --root-owner-group -Zxz -z9 --build "$package_root" "$output_directory/$asset_name"
dpkg-deb --info "$output_directory/$asset_name" >/dev/null
dpkg-deb --contents "$output_directory/$asset_name" >/dev/null
printf 'Built %s\n' "$output_directory/$asset_name"
