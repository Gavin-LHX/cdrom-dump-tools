#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly POWERSHELL_VERSION='7.6.5'
readonly POWERSHELL_ARCHIVE="powershell-${POWERSHELL_VERSION}-osx-arm64.tar.gz"
readonly POWERSHELL_URL="https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/${POWERSHELL_ARCHIVE}"
readonly POWERSHELL_SHA256='8196d4b4e7c21b7f6df9d45687bb4e42dc8335f330b580d9eb15f3ef5042a8c3'

readonly FFMPEG_VERSION='8.1.2'
readonly FFMPEG_ARCHIVE="ffmpeg-n${FFMPEG_VERSION}.tar.gz"
readonly FFMPEG_URL="https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${FFMPEG_VERSION}.tar.gz"
readonly FFMPEG_SHA256='9fd092511605bbebafe095ea6d38d9e40f34d12f7386e1258372df8be0576eb7'

readonly MINIMUM_MACOS_VERSION='14.0'
readonly APP_BUNDLE_NAME='CdromDumpTools.app'
readonly EXECUTABLE_NAME='CdromDumpTools'
readonly DEFAULT_BUNDLE_IDENTIFIER='com.gavinlhx.cdrom-dump-tools'

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command was not found: $1"
}

sha256_file() {
    shasum -a 256 "$1" | awk '{ print tolower($1) }'
}

download_and_verify() {
    local url="$1"
    local expected_sha256="$2"
    local destination="$3"
    local partial="${destination}.partial"
    local actual_sha256=''

    if [[ -f "$destination" ]]; then
        actual_sha256="$(sha256_file "$destination")"
        if [[ "$actual_sha256" == "$expected_sha256" ]]; then
            printf 'Using verified download cache: %s\n' "$destination"
            return
        fi
        rm -f -- "$destination"
    fi

    rm -f -- "$partial"
    curl \
        --proto '=https' \
        --tlsv1.2 \
        --fail \
        --location \
        --show-error \
        --silent \
        --retry 3 \
        --output "$partial" \
        "$url"

    actual_sha256="$(sha256_file "$partial")"
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        rm -f -- "$partial"
        die "SHA-256 mismatch for $url: expected $expected_sha256, got $actual_sha256"
    fi
    mv -- "$partial" "$destination"
}

assert_arm64_macho() {
    local path="$1"
    local architecture=''
    file "$path" | grep -Fq 'Mach-O' || die "expected a Mach-O file: $path"
    architecture="$(lipo -archs "$path")"
    [[ "$architecture" == 'arm64' ]] || die "expected arm64-only Mach-O, got '$architecture': $path"
}

assert_macho_contains_arm64() {
    local path="$1"
    local architectures=''
    file "$path" | grep -Fq 'Mach-O' || die "expected a Mach-O file: $path"
    architectures="$(lipo -archs "$path")"
    case " $architectures " in
        *' arm64 '*) ;;
        *) die "Mach-O does not contain an arm64 slice ('$architectures'): $path" ;;
    esac
}

assert_macho_tree_supports_arm64() {
    local root="$1"
    local candidate=''
    local found=0

    while IFS= read -r -d '' candidate; do
        if file "$candidate" | grep -Fq 'Mach-O'; then
            found=1
            assert_macho_contains_arm64 "$candidate"
        fi
    done < <(find "$root" -type f -print0)

    ((found == 1)) || die "no Mach-O files were found under $root"
}

assert_only_system_dynamic_dependencies() {
    local executable="$1"
    local dependency=''

    while IFS= read -r dependency; do
        [[ -z "$dependency" ]] && continue
        case "$dependency" in
            /usr/lib/* | /System/Library/Frameworks/*)
                ;;
            *)
                die "non-system dynamic dependency in $executable: $dependency"
                ;;
        esac
    done < <(otool -L "$executable" | tail -n +2 | awk '{ print $1 }')
}

sign_macho_tree_ad_hoc() {
    local root="$1"
    local candidate=''

    while IFS= read -r -d '' candidate; do
        if file "$candidate" | grep -Fq 'Mach-O'; then
            codesign --force --sign - "$candidate"
        fi
    done < <(find "$root" -type f -print0)
}

plist_value() {
    local key="$1"
    local plist="$2"
    plutil -extract "$key" raw -o - "$plist"
}

usage() {
    cat <<'USAGE'
Usage: bash macos/build_macos_app.sh

Environment variables:
  VERSION             Release version; defaults to the Windows GUI project version.
  BUILD_NUMBER        Numeric CFBundleVersion; defaults to 1.
  BUNDLE_IDENTIFIER   Reverse-DNS bundle identifier.
  OUTPUT_DIR          Directory for the final unsigned DMG.
  DOWNLOAD_CACHE_DIR  Optional persistent cache for verified source archives.
USAGE
}

if (($# != 0)); then
    if [[ "$1" == '--help' && $# -eq 1 ]]; then
        usage
        exit 0
    fi
    usage >&2
    exit 2
fi

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIRECTORY
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd -P)"
readonly REPOSITORY_ROOT
readonly GUI_PROJECT="$REPOSITORY_ROOT/gui/CdromDumpToolsGui/CdromDumpToolsGui.csproj"
readonly CONVERTER_SCRIPT="$REPOSITORY_ROOT/bin_to_audio_windows.ps1"
readonly INFO_PLIST_TEMPLATE="$SCRIPT_DIRECTORY/Info.plist.in"
readonly SWIFT_SOURCE_DIRECTORY="$SCRIPT_DIRECTORY/Sources/CdromDumpToolsMac"

[[ "$(uname -s)" == 'Darwin' ]] || die 'this build must run on macOS'
[[ "$(uname -m)" == 'arm64' ]] || die 'this build must run natively on Apple Silicon (arm64)'

for command_name in awk codesign cmp curl dd file find grep hdiutil install lipo make otool plutil sed shasum swiftc tar xcrun; do
    require_command "$command_name"
done

[[ -f "$GUI_PROJECT" ]] || die "GUI project was not found: $GUI_PROJECT"
[[ -f "$CONVERTER_SCRIPT" ]] || die "converter script was not found: $CONVERTER_SCRIPT"
[[ -f "$INFO_PLIST_TEMPLATE" ]] || die "Info.plist template was not found: $INFO_PLIST_TEMPLATE"
[[ -d "$SWIFT_SOURCE_DIRECTORY" ]] || die "Swift source directory was not found: $SWIFT_SOURCE_DIRECTORY"

project_version="$(awk -F '[<>]' '/<Version>/{ print $3; exit }' "$GUI_PROJECT")"
[[ -n "$project_version" ]] || die 'could not read <Version> from the Windows GUI project'

release_version="${VERSION:-$project_version}"
build_number="${BUILD_NUMBER:-1}"
bundle_identifier="${BUNDLE_IDENTIFIER:-$DEFAULT_BUNDLE_IDENTIFIER}"
output_directory="${OUTPUT_DIR:-$REPOSITORY_ROOT/dist/macos}"

[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] ||
    die "VERSION is not SemVer-like: $release_version"
[[ "$release_version" == "$project_version" ]] ||
    die "VERSION '$release_version' differs from GUI project version '$project_version'"
[[ "$build_number" =~ ^[0-9]+$ ]] || die "BUILD_NUMBER must contain only digits: $build_number"
[[ "$bundle_identifier" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] ||
    die "BUNDLE_IDENTIFIER is not a valid reverse-DNS identifier: $bundle_identifier"

marketing_version="$(printf '%s\n' "$release_version" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
converter_versions="$(
    grep -Eo 'BinToAudioWindows/[0-9]+\.[0-9]+\.[0-9]+' "$CONVERTER_SCRIPT" |
        sed 's:BinToAudioWindows/::' |
        sort -u
)"
[[ "$converter_versions" == "$marketing_version" ]] ||
    die "converter component version(s) '$converter_versions' differ from marketing version '$marketing_version'"

mac_fallback_versions="$(
    grep -Eho 'fallbackVersion[[:space:]]*=[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$SWIFT_SOURCE_DIRECTORY"/*.swift |
        sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)"/\1/' |
        sort -u
)"
[[ "$mac_fallback_versions" == "$marketing_version" ]] ||
    die "macOS fallback version(s) '$mac_fallback_versions' differ from marketing version '$marketing_version'"

mkdir -p -- "$output_directory"
output_directory="$(cd -- "$output_directory" && pwd -P)"

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/cdrom-dump-tools-macos.XXXXXX")"
mount_directory=''
cleanup() {
    if [[ -n "$mount_directory" && -d "$mount_directory" ]]; then
        hdiutil detach "$mount_directory" -quiet >/dev/null 2>&1 || true
    fi
    rm -rf -- "$work_directory"
}
trap cleanup EXIT

download_cache_directory="${DOWNLOAD_CACHE_DIR:-$work_directory/downloads}"
mkdir -p -- "$download_cache_directory"
download_cache_directory="$(cd -- "$download_cache_directory" && pwd -P)"

powershell_archive_path="$download_cache_directory/$POWERSHELL_ARCHIVE"
ffmpeg_archive_path="$download_cache_directory/$FFMPEG_ARCHIVE"
download_and_verify "$POWERSHELL_URL" "$POWERSHELL_SHA256" "$powershell_archive_path"
download_and_verify "$FFMPEG_URL" "$FFMPEG_SHA256" "$ffmpeg_archive_path"

printf 'Extracting PowerShell %s arm64...\n' "$POWERSHELL_VERSION"
powershell_directory="$work_directory/powershell"
mkdir -p -- "$powershell_directory"
tar -xzf "$powershell_archive_path" -C "$powershell_directory"
chmod 0755 "$powershell_directory/pwsh"
assert_arm64_macho "$powershell_directory/pwsh"
assert_macho_tree_supports_arm64 "$powershell_directory"
powershell_reported_version="$(
    "$powershell_directory/pwsh" \
        -NoLogo \
        -NoProfile \
        -NonInteractive \
        -Command '$PSVersionTable.PSVersion.ToString()'
)"
[[ "$powershell_reported_version" == "$POWERSHELL_VERSION" ]] ||
    die "bundled PowerShell reported '$powershell_reported_version', expected '$POWERSHELL_VERSION'"

printf 'Building FFmpeg %s as an LGPL arm64 binary...\n' "$FFMPEG_VERSION"
ffmpeg_source_parent="$work_directory/ffmpeg-source"
ffmpeg_prefix="$work_directory/ffmpeg-install"
mkdir -p -- "$ffmpeg_source_parent" "$ffmpeg_prefix"
tar -xzf "$ffmpeg_archive_path" -C "$ffmpeg_source_parent"
ffmpeg_source_directory="$ffmpeg_source_parent/FFmpeg-n${FFMPEG_VERSION}"
[[ -x "$ffmpeg_source_directory/configure" ]] || die 'the FFmpeg source archive did not have the expected layout'

macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
clang_path="$(xcrun --sdk macosx --find clang)"
cpu_count="$(sysctl -n hw.logicalcpu 2>/dev/null || printf '3')"
export MACOSX_DEPLOYMENT_TARGET="$MINIMUM_MACOS_VERSION"

(
    cd -- "$ffmpeg_source_directory"
    ./configure \
        --prefix="$ffmpeg_prefix" \
        --arch=arm64 \
        --target-os=darwin \
        --cc="$clang_path" \
        --host-cc="$clang_path" \
        --sysroot="$macos_sdk" \
        --extra-cflags="-arch arm64 -mmacosx-version-min=${MINIMUM_MACOS_VERSION}" \
        --extra-ldflags="-arch arm64 -mmacosx-version-min=${MINIMUM_MACOS_VERSION}" \
        --host-cflags="-isysroot $macos_sdk" \
        --host-ldflags="-isysroot $macos_sdk" \
        --enable-static \
        --disable-shared \
        --disable-autodetect \
        --disable-gpl \
        --disable-nonfree \
        --disable-version3 \
        --disable-doc \
        --disable-debug \
        --disable-programs \
        --enable-ffmpeg \
        --enable-zlib
    make -j "$cpu_count"
    make install
)

ffmpeg_executable="$ffmpeg_prefix/bin/ffmpeg"
[[ -x "$ffmpeg_executable" ]] || die 'FFmpeg build did not produce an executable'
assert_arm64_macho "$ffmpeg_executable"

ffmpeg_build_configuration="$("$ffmpeg_executable" -hide_banner -buildconf 2>&1)"
for required_flag in --disable-gpl --disable-nonfree --disable-version3 --disable-autodetect --enable-static --disable-shared --enable-zlib; do
    grep -Fq -- "$required_flag" <<<"$ffmpeg_build_configuration" ||
        die "FFmpeg build configuration is missing $required_flag"
done
if grep -Eq -- '--enable-(gpl|nonfree|version3)([[:space:]]|$)' <<<"$ffmpeg_build_configuration"; then
    die 'FFmpeg build unexpectedly enabled GPL, nonfree, or version3 components'
fi
assert_only_system_dynamic_dependencies "$ffmpeg_executable"

app_bundle="$work_directory/$APP_BUNDLE_NAME"
contents_directory="$app_bundle/Contents"
macos_directory="$contents_directory/MacOS"
resources_directory="$contents_directory/Resources"
runtime_directory="$resources_directory/runtime"
mkdir -p -- "$macos_directory" "$runtime_directory/powershell" "$resources_directory/Legal"

/usr/bin/ditto "$powershell_directory" "$runtime_directory/powershell"
install -m 0755 "$ffmpeg_executable" "$runtime_directory/ffmpeg"
install -m 0644 "$CONVERTER_SCRIPT" "$resources_directory/bin_to_audio.ps1"
install -m 0644 "$SCRIPT_DIRECTORY/README.md" "$resources_directory/README-macOS.md"
install -m 0644 "$ffmpeg_source_directory/COPYING.LGPLv2.1" "$resources_directory/Legal/FFmpeg-COPYING.LGPLv2.1.txt"
install -m 0644 "$ffmpeg_source_directory/LICENSE.md" "$resources_directory/Legal/FFmpeg-LICENSE.md"
if [[ -f "$powershell_directory/LICENSE.txt" ]]; then
    install -m 0644 "$powershell_directory/LICENSE.txt" "$resources_directory/Legal/PowerShell-LICENSE.txt"
fi
if [[ -f "$powershell_directory/ThirdPartyNotices.txt" ]]; then
    install -m 0644 "$powershell_directory/ThirdPartyNotices.txt" "$resources_directory/Legal/PowerShell-THIRD-PARTY-NOTICES.txt"
fi

cat >"$resources_directory/DISTRIBUTION-NOTICE.txt" <<NOTICE
CD-ROM Dump Tools ${release_version} for macOS arm64

This build is ad-hoc signed and has NOT been signed with an Apple Developer ID.
It has NOT been submitted to or accepted by Apple's notarization service.
Gatekeeper may block an Internet-downloaded copy.

Bundled components:
- PowerShell ${POWERSHELL_VERSION} arm64 (official release archive)
- FFmpeg ${FFMPEG_VERSION} arm64 (official source; GPL/nonfree/version3 disabled)
NOTICE

swift_sources=("$SWIFT_SOURCE_DIRECTORY"/*.swift)
[[ -f "${swift_sources[0]}" ]] || die 'no Swift source files were found'

printf 'Compiling native SwiftUI application for arm64 macOS %s+...\n' "$MINIMUM_MACOS_VERSION"
xcrun --sdk macosx swiftc \
    -parse-as-library \
    -swift-version 5 \
    -O \
    -sdk "$macos_sdk" \
    -target "arm64-apple-macos${MINIMUM_MACOS_VERSION}" \
    -module-name CdromDumpToolsMac \
    -framework AppKit \
    -framework Security \
    -framework SwiftUI \
    -framework UniformTypeIdentifiers \
    "${swift_sources[@]}" \
    -o "$macos_directory/$EXECUTABLE_NAME"

sed \
    -e "s/@EXECUTABLE_NAME@/${EXECUTABLE_NAME}/g" \
    -e "s/@BUNDLE_IDENTIFIER@/${bundle_identifier}/g" \
    -e "s/@MARKETING_VERSION@/${marketing_version}/g" \
    -e "s/@RELEASE_VERSION@/${release_version}/g" \
    -e "s/@BUILD_NUMBER@/${build_number}/g" \
    "$INFO_PLIST_TEMPLATE" >"$contents_directory/Info.plist"

plutil -lint "$contents_directory/Info.plist" >/dev/null
assert_arm64_macho "$macos_directory/$EXECUTABLE_NAME"
assert_only_system_dynamic_dependencies "$macos_directory/$EXECUTABLE_NAME"
assert_macho_tree_supports_arm64 "$runtime_directory/powershell"
assert_arm64_macho "$runtime_directory/ffmpeg"
cmp -s "$CONVERTER_SCRIPT" "$resources_directory/bin_to_audio.ps1" ||
    die 'the bundled converter differs from the repository source'

[[ "$(plist_value CFBundleExecutable "$contents_directory/Info.plist")" == "$EXECUTABLE_NAME" ]] || die 'CFBundleExecutable is incorrect'
[[ "$(plist_value CFBundleIdentifier "$contents_directory/Info.plist")" == "$bundle_identifier" ]] || die 'CFBundleIdentifier is incorrect'
[[ "$(plist_value CFBundleShortVersionString "$contents_directory/Info.plist")" == "$marketing_version" ]] || die 'CFBundleShortVersionString is incorrect'
[[ "$(plist_value CFBundleVersion "$contents_directory/Info.plist")" == "$build_number" ]] || die 'CFBundleVersion is incorrect'
[[ "$(plist_value LSMinimumSystemVersion "$contents_directory/Info.plist")" == "$MINIMUM_MACOS_VERSION" ]] || die 'LSMinimumSystemVersion is incorrect'
[[ "$(plist_value CDROMDumpToolsReleaseVersion "$contents_directory/Info.plist")" == "$release_version" ]] || die 'CDROMDumpToolsReleaseVersion is incorrect'
[[ "$(plist_value CDROMDumpToolsCodeSigning "$contents_directory/Info.plist")" == 'ad-hoc' ]] || die 'distribution signing metadata is incorrect'
[[ "$(plist_value CDROMDumpToolsNotarized "$contents_directory/Info.plist")" == 'false' ]] || die 'the unsigned build must declare that it is not notarized'

printf 'Applying ad-hoc signatures (not Developer ID, not notarized)...\n'
sign_macho_tree_ad_hoc "$runtime_directory/powershell"
codesign --force --sign - "$runtime_directory/ffmpeg"
codesign --force --sign - "$macos_directory/$EXECUTABLE_NAME"
codesign --force --sign - "$app_bundle"

verify_app_bundle() {
    local bundle="$1"
    local plist="$bundle/Contents/Info.plist"
    local executable="$bundle/Contents/MacOS/$EXECUTABLE_NAME"
    local signing_details=''

    plutil -lint "$plist" >/dev/null
    assert_arm64_macho "$executable"
    assert_arm64_macho "$bundle/Contents/Resources/runtime/powershell/pwsh"
    assert_arm64_macho "$bundle/Contents/Resources/runtime/ffmpeg"
    codesign --verify --deep --strict --verbose=4 "$bundle"
    signing_details="$(codesign --display --verbose=4 "$bundle" 2>&1)"
    grep -Fq 'Signature=adhoc' <<<"$signing_details" || die "bundle is not ad-hoc signed: $bundle"
    [[ "$(plist_value CDROMDumpToolsNotarized "$plist")" == 'false' ]] || die "bundle incorrectly claims to be notarized: $bundle"
    "$executable" --self-test
}

run_converter_smoke_test() {
    local bundle="$1"
    local fixture="$work_directory/转换 smoke test"
    local output="$fixture/output"
    local powershell="$bundle/Contents/Resources/runtime/powershell/pwsh"
    local ffmpeg="$bundle/Contents/Resources/runtime/ffmpeg"
    local converter="$bundle/Contents/Resources/bin_to_audio.ps1"

    mkdir -p -- "$fixture"
    dd if=/dev/zero of="$fixture/test-disc.bin" bs=352800 count=1 2>/dev/null
    cat >"$fixture/test-disc.toc" <<'TOC'
CD_DA

TRACK AUDIO
NO COPY
NO PRE_EMPHASIS
TWO_CHANNEL_AUDIO
FILE "test-disc.bin" 0 00:02:00
TOC

    "$powershell" \
        -NoLogo \
        -NoProfile \
        -NonInteractive \
        -File "$converter" \
        -BinPath "$fixture/test-disc.bin" \
        -TocPath "$fixture/test-disc.toc" \
        -OutputDirectory "$output" \
        -FfmpegPath "$ffmpeg" \
        -NoMetadata \
        -NoCover \
        -NoLyrics \
        -VerifyAudio \
        -NoPause

    [[ -s "$output/track-01.flac" ]] || die 'offline macOS converter smoke test did not create track-01.flac'
    [[ -s "$output/audio-verification.json" ]] || die 'offline macOS converter smoke test did not create audio-verification.json'
    [[ -s "$output/SHA256SUMS.txt" ]] || die 'offline macOS converter smoke test did not create SHA256SUMS.txt'
}

verify_app_bundle "$app_bundle"

dmg_staging_directory="$work_directory/dmg-staging"
mkdir -p -- "$dmg_staging_directory"
/usr/bin/ditto "$app_bundle" "$dmg_staging_directory/$APP_BUNDLE_NAME"
ln -s /Applications "$dmg_staging_directory/Applications"
install -m 0644 "$SCRIPT_DIRECTORY/README.md" "$dmg_staging_directory/README-macOS.md"

dmg_name="cdrom-dump-tools-${release_version}-macos-arm64-unsigned.dmg"
temporary_dmg="$work_directory/$dmg_name"
final_dmg="$output_directory/$dmg_name"
rm -f -- "$final_dmg"

hdiutil create \
    -volname 'CD-ROM Dump Tools' \
    -srcfolder "$dmg_staging_directory" \
    -format UDZO \
    -ov \
    "$temporary_dmg" >/dev/null

codesign --force --sign - "$temporary_dmg"
codesign --verify --verbose=4 "$temporary_dmg"
hdiutil verify "$temporary_dmg" >/dev/null

mount_directory="$work_directory/mounted-dmg"
mkdir -p -- "$mount_directory"
hdiutil attach "$temporary_dmg" -nobrowse -readonly -mountpoint "$mount_directory" >/dev/null
verify_app_bundle "$mount_directory/$APP_BUNDLE_NAME"
run_converter_smoke_test "$mount_directory/$APP_BUNDLE_NAME"
hdiutil detach "$mount_directory" -quiet
mount_directory=''

mv -- "$temporary_dmg" "$final_dmg"
final_sha256="$(sha256_file "$final_dmg")"
printf 'Created unsigned, unnotarized macOS arm64 DMG:\n'
printf '  %s\n' "$final_dmg"
printf '  SHA256 %s\n' "$final_sha256"
