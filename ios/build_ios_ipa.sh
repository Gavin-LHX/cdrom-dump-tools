#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"

app_name="CdromDumpToolsIOS"
bundle_identifier="com.gavinlhx.cdromdumptools.ios"
deployment_target="26.0"
version="${VERSION:-}"
build_number="${BUILD_NUMBER:-1}"
output_dir="${OUTPUT_DIR:-$repo_root/dist}"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is unavailable: $1"
}

if [[ -z "$version" ]]; then
    version="$({
        sed -nE 's@.*<Version>([^<]+)</Version>.*@\1@p' \
            "$repo_root/gui/CdromDumpToolsGui/CdromDumpToolsGui.csproj"
    } | head -n 1)"
fi

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] ||
    fail "VERSION must be a SemVer-like value without a leading v: $version"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] ||
    fail "BUILD_NUMBER must be a positive integer: $build_number"

[[ "$(uname -s)" == Darwin ]] || fail 'The iOS IPA can only be built on macOS.'
[[ "$(uname -m)" == arm64 ]] || fail 'The pinned iOS build requires an arm64 macOS runner.'

for command_name in awk codesign find grep lipo plutil sed shasum unzip xcodebuild xcrun zip zipinfo; do
    require_command "$command_name"
done

xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
[[ "$xcode_version" == 26.6 ]] || fail "Xcode 26.6 is required; found $xcode_version."

device_sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
simulator_sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
[[ "$device_sdk_version" == 26.* ]] ||
    fail "An iOS 26.x device SDK is required; found $device_sdk_version."
[[ "$simulator_sdk_version" == 26.* ]] ||
    fail "An iOS 26.x simulator SDK is required; found $simulator_sdk_version."

core_source_dir="$script_dir/Sources/CdromDumpCore"
app_source_dir="$script_dir/Sources/CdromDumpToolsIOS"
test_source="$script_dir/Tests/CoreSelfTest.swift"
test_source_dir="$script_dir/Tests"
info_template="$script_dir/Info.plist.in"

[[ -d "$core_source_dir" ]] || fail "Core source directory is missing: $core_source_dir"
[[ -d "$app_source_dir" ]] || fail "App source directory is missing: $app_source_dir"
[[ -f "$test_source" ]] || fail "Core self-test source is missing: $test_source"
[[ -f "$info_template" ]] || fail "Info.plist template is missing: $info_template"

shopt -s nullglob
core_sources=("$core_source_dir"/*.swift)
app_sources=("$app_source_dir"/*.swift)
test_sources=("$test_source_dir"/*.swift)
shopt -u nullglob

(( ${#core_sources[@]} > 0 )) || fail "No Swift sources were found in $core_source_dir"
(( ${#app_sources[@]} > 0 )) || fail "No Swift sources were found in $app_source_dir"
(( ${#test_sources[@]} > 0 )) || fail "No Swift test sources were found in $test_source_dir"

ios_source_version="$(sed -nE 's/^[[:space:]]*static let fallback = "([^"]+)".*/\1/p' \
    "$core_source_dir/Models.swift")"
[[ "$ios_source_version" == "$version" ]] ||
    fail "The iOS source version '$ios_source_version' differs from VERSION '$version'."

build_root="$(mktemp -d "${TMPDIR:-/tmp}/cdrom-dump-tools-ios.XXXXXX")"
cleanup() {
    rm -rf -- "$build_root"
}
trap cleanup EXIT

macos_sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
simulator_sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
device_sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"

printf 'Running native core self-test...\n'
core_test_binary="$build_root/CoreSelfTest"
xcrun --sdk macosx swiftc \
    -sdk "$macos_sdk_path" \
    -target arm64-apple-macosx14.0 \
    -swift-version 6 \
    -parse-as-library \
    -module-name CdromDumpCoreSelfTest \
    "${core_sources[@]}" \
    "${test_sources[@]}" \
    -o "$core_test_binary"
"$core_test_binary"

printf 'Compiling the app for the generic iOS 26 simulator target...\n'
simulator_binary="$build_root/${app_name}-simulator"
xcrun --sdk iphonesimulator swiftc \
    -sdk "$simulator_sdk_path" \
    -target arm64-apple-ios${deployment_target}-simulator \
    -swift-version 6 \
    -parse-as-library \
    -module-name "$app_name" \
    "${core_sources[@]}" \
    "${app_sources[@]}" \
    -o "$simulator_binary"
[[ -x "$simulator_binary" ]] || fail 'The generic iOS simulator binary was not produced.'
[[ "$(lipo -archs "$simulator_binary")" == arm64 ]] ||
    fail "The simulator binary has unexpected architectures: $(lipo -archs "$simulator_binary")"

printf 'Compiling the unsigned arm64 device app...\n'
package_root="$build_root/package"
payload_dir="$package_root/Payload"
app_bundle="$payload_dir/${app_name}.app"
mkdir -p "$app_bundle"

device_binary="$app_bundle/$app_name"
xcrun --sdk iphoneos swiftc \
    -sdk "$device_sdk_path" \
    -target arm64-apple-ios${deployment_target} \
    -swift-version 6 \
    -parse-as-library \
    -O \
    -whole-module-optimization \
    -Xlinker -no_adhoc_codesign \
    -module-name "$app_name" \
    "${core_sources[@]}" \
    "${app_sources[@]}" \
    -o "$device_binary"
chmod 0755 "$device_binary"

sed \
    -e "s|@EXECUTABLE_NAME@|$app_name|g" \
    -e "s|@BUNDLE_IDENTIFIER@|$bundle_identifier|g" \
    -e "s|@MARKETING_VERSION@|$version|g" \
    -e "s|@BUILD_NUMBER@|$build_number|g" \
    "$info_template" >"$app_bundle/Info.plist"
if grep -Eq '@[A-Z0-9_]+@' "$app_bundle/Info.plist"; then
    fail 'Info.plist still contains an unresolved template placeholder.'
fi

cat >"$app_bundle/UNSIGNED-NOTICE.txt" <<'NOTICE'
This iOS application bundle is intentionally unsigned.
It must be signed with an Apple Developer identity and a matching provisioning
profile before it can be installed on an iPhone or iPad.
NOTICE

plutil -lint "$app_bundle/Info.plist" >/dev/null
[[ "$(plutil -extract CFBundleExecutable raw -o - "$app_bundle/Info.plist")" == "$app_name" ]] ||
    fail 'CFBundleExecutable does not match the packaged executable.'
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$app_bundle/Info.plist")" == "$bundle_identifier" ]] ||
    fail 'CFBundleIdentifier does not match the expected application identifier.'
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$app_bundle/Info.plist")" == "$version" ]] ||
    fail 'CFBundleShortVersionString does not match VERSION.'
[[ "$(plutil -extract CFBundleVersion raw -o - "$app_bundle/Info.plist")" == "$build_number" ]] ||
    fail 'CFBundleVersion does not match BUILD_NUMBER.'
[[ "$(plutil -extract MinimumOSVersion raw -o - "$app_bundle/Info.plist")" == "$deployment_target" ]] ||
    fail 'MinimumOSVersion must be 26.0.'
[[ "$(plutil -extract CFBundlePackageType raw -o - "$app_bundle/Info.plist")" == APPL ]] ||
    fail 'CFBundlePackageType must be APPL.'
[[ "$(plutil -extract CFBundleSupportedPlatforms.0 raw -o - "$app_bundle/Info.plist")" == iPhoneOS ]] ||
    fail 'CFBundleSupportedPlatforms must declare iPhoneOS.'
[[ "$(plutil -extract UIRequiredDeviceCapabilities.0 raw -o - "$app_bundle/Info.plist")" == arm64 ]] ||
    fail 'UIRequiredDeviceCapabilities must require arm64.'

device_architectures="$(lipo -archs "$device_binary")"
[[ "$device_architectures" == arm64 ]] ||
    fail "The device executable has unexpected architectures: $device_architectures"

device_build_info="$build_root/device-build-info.txt"
xcrun vtool -show-build "$device_binary" >"$device_build_info"
device_platform="$(awk '$1 == "platform" { print $2; exit }' "$device_build_info")"
device_minos="$(awk '$1 == "minos" { print $2; exit }' "$device_build_info")"
device_link_sdk="$(awk '$1 == "sdk" { print $2; exit }' "$device_build_info")"
[[ "$device_platform" == IOS ]] || fail "Unexpected Mach-O platform: $device_platform"
[[ "$device_minos" == "$deployment_target" ]] ||
    fail "Unexpected Mach-O minimum iOS version: $device_minos"
[[ "$device_link_sdk" == 26.* ]] || fail "Unexpected Mach-O SDK version: $device_link_sdk"

if codesign --display --verbose=2 "$app_bundle" >/dev/null 2>&1; then
    fail 'The iOS application is signed; this workflow must publish an unsigned IPA.'
fi
if codesign --display --verbose=2 "$device_binary" >/dev/null 2>&1; then
    fail 'The iOS executable is signed; this workflow must publish an unsigned IPA.'
fi
sensitive_bundle_path="$(find "$app_bundle" \
    \( -name '_CodeSignature' -o -name '*.mobileprovision' -o -name '*.provisionprofile' \
       -o -name '.env' -o -name '.env.*' -o -name '*.p8' -o -name '*.p12' \
       -o -name '*.cer' -o -name '*.key' -o -name '*.pem' \) \
    -print -quit)"
if [[ -n "$sensitive_bundle_path" ]]; then
    fail 'The app bundle contains signing material, a provisioning profile, or a real .env file.'
fi

mkdir -p "$output_dir"
asset_name="cdrom-dump-tools-${version}-ios26-arm64-unsigned.ipa"
temporary_ipa="$build_root/$asset_name"
(
    cd "$package_root"
    /usr/bin/zip -X -q -r "$temporary_ipa" Payload
)
[[ -s "$temporary_ipa" ]] || fail 'The IPA archive was not produced.'
unzip -t "$temporary_ipa" >/dev/null

archive_entries="$build_root/archive-entries.txt"
zipinfo -1 "$temporary_ipa" >"$archive_entries"
if grep -Eq '(^|/)\.\.(/|$)|^/' "$archive_entries"; then
    fail 'The IPA contains an unsafe archive path.'
fi

verification_root="$build_root/verify"
mkdir -p "$verification_root"
unzip -q "$temporary_ipa" -d "$verification_root"
shopt -s nullglob
top_level_entries=("$verification_root"/*)
packaged_apps=("$verification_root"/Payload/*.app)
shopt -u nullglob
(( ${#top_level_entries[@]} == 1 )) || fail 'The IPA must contain only the Payload directory.'
[[ "$(basename -- "${top_level_entries[0]}")" == Payload ]] ||
    fail 'The IPA top-level directory must be Payload.'
(( ${#packaged_apps[@]} == 1 )) || fail 'The IPA must contain exactly one application bundle.'

verified_app="${packaged_apps[0]}"
verified_executable="$verified_app/$app_name"
[[ -x "$verified_executable" ]] || fail 'The extracted IPA executable is missing.'
[[ "$(lipo -archs "$verified_executable")" == arm64 ]] ||
    fail 'The extracted IPA executable is not arm64-only.'
[[ "$(plutil -extract MinimumOSVersion raw -o - "$verified_app/Info.plist")" == "$deployment_target" ]] ||
    fail 'The extracted IPA does not target iOS 26.0.'
if codesign --display --verbose=2 "$verified_app" >/dev/null 2>&1; then
    fail 'The extracted IPA unexpectedly contains a signed app.'
fi
if codesign --display --verbose=2 "$verified_executable" >/dev/null 2>&1; then
    fail 'The extracted IPA unexpectedly contains a signed executable.'
fi
sensitive_archive_path="$(find "$verification_root" \
    \( -name '_CodeSignature' -o -name '*.mobileprovision' -o -name '*.provisionprofile' \
       -o -name '.env' -o -name '.env.*' -o -name '*.p8' -o -name '*.p12' \
       -o -name '*.cer' -o -name '*.key' -o -name '*.pem' \) \
    -print -quit)"
if [[ -n "$sensitive_archive_path" ]]; then
    fail 'The IPA contains signing material, a provisioning profile, or a real .env file.'
fi

final_ipa="$output_dir/$asset_name"
install -m 0644 "$temporary_ipa" "$final_ipa"
printf 'Unsigned iOS 26 IPA: %s\n' "$final_ipa"
printf 'SHA-256: %s\n' "$(shasum -a 256 "$final_ipa" | awk '{ print $1 }')"
