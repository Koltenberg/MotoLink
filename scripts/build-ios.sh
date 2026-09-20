#!/usr/bin/env bash
# Build on macOS; validate-ipa.py can inspect the resulting IPA on any OS.
# Never supplies an Apple account, signing certificate, or provisioning profile.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-ios.sh [--skip-simulator] [--output DIRECTORY]

Requires macOS, full Xcode with an iOS SDK, and Python 3.
Default: Swift protocol tests, simulator compile check, unsigned Release iPhone IPA.
No app/device is installed and no Apple account is contacted for signing.
EOF
}

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_root="$project_root/build-artifacts/ios"
check_simulator=1
while (($#)); do
  case "$1" in
    --skip-simulator) check_simulator=0; shift ;;
    --output)
      if (($# < 2)); then usage >&2; exit 2; fi
      output_root="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Xcode iOS compilation requires macOS. Use the supplied GitHub Actions workflow; this Linux/Windows shell cannot build an iPhone binary.' >&2
  exit 2
fi
for tool in xcodebuild xcrun python3 ditto shasum; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 2; }
done
xcrun --sdk iphoneos --show-sdk-path >/dev/null
if ((check_simulator)); then xcrun --sdk iphonesimulator --show-sdk-path >/dev/null; fi

mkdir -p "$output_root"
output_root="$(cd "$output_root" && pwd)"
run_dir="$(mktemp -d "$output_root/run-XXXXXXXX")"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/motolink-ios.XXXXXXXX")"
trap 'rm -rf "$build_root"' EXIT

xcodebuild -version >"$run_dir/xcode-version.log"
xcrun --sdk iphoneos --show-sdk-version >"$run_dir/iphoneos-sdk.log"
printf 'Build output: %s\n' "$run_dir"

python3 -m unittest discover -s "$project_root/tests" -p test_ipa_validation.py -v \
  2>&1 | tee "$run_dir/package-validator-tests.log"
python3 "$project_root/research-v03/test_protocol_profile.py" \
  2>&1 | tee "$run_dir/protocol-profile-tests.log"
xcrun swift test --package-path "$project_root/core" \
  --scratch-path "$build_root/swift-tests" \
  2>&1 | tee "$run_dir/protocol-tests.log"

common=(
  -project "$project_root/ios/MotoLink.xcodeproj"
  -scheme MotoLink
  -configuration Release
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
  DEVELOPMENT_TEAM=
)

if ((check_simulator)); then
  # There is currently no XCTest target. This is a compile/link check, not tests.
  xcodebuild "${common[@]}" \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$build_root/simulator" build \
    2>&1 | tee "$run_dir/simulator-build.log"
fi

xcodebuild "${common[@]}" \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_root/device" ARCHS=arm64 build \
  2>&1 | tee "$run_dir/device-build.log"

# The isolated directory contains only this target's products; never package
# a previous run's .app or a simulator product.
shopt -s nullglob
apps=("$build_root/device/Build/Products/Release-iphoneos/"*.app)
if ((${#apps[@]} != 1)); then
  echo "Expected exactly one device .app, found ${#apps[@]}. See device-build.log." >&2
  exit 1
fi
app_path="${apps[0]}"
mkdir "$build_root/package"
mkdir "$build_root/package/Payload"
ditto "$app_path" "$build_root/package/Payload/$(basename "$app_path")"
(
  cd "$build_root/package"
  COPYFILE_DISABLE=1 ditto -c -k --keepParent Payload "$run_dir/MotoLink-unsigned.ipa"
)

python3 "$project_root/scripts/validate-ipa.py" \
  "$run_dir/MotoLink-unsigned.ipa" --manifest "$run_dir/package-validation.json"
(
  cd "$run_dir"
  shasum -a 256 MotoLink-unsigned.ipa >MotoLink-unsigned.ipa.sha256
)
printf '\nValidated unsigned package: %s\n' "$run_dir/MotoLink-unsigned.ipa"
printf 'This IPA still needs personal signing before installation. No Bluetooth hardware test was performed.\n'
