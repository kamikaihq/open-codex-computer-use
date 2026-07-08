#!/usr/bin/env bash
# Bundle the cua-driver daemon as CuaDriver.app for stable TCC identity.
# Signing/notarization is driven by the caller (see release usage below);
# unsigned/adhoc bundles are fine for local development.
#
# Usage:
#   ./scripts/build-cua-driver-app.sh [--version 1.0.0] [--out dist]
#
# Environment:
#   CUA_DRIVER_CODESIGN_IDENTITY  "Developer ID Application: ..." (default: adhoc)

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="1.0.0"
out_dir="${repo_root}/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:?}"; shift 2 ;;
    --out) out_dir="${2:?}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

identity="${CUA_DRIVER_CODESIGN_IDENTITY:--}"
app="${out_dir}/CuaDriver.app"

swift build --package-path "${repo_root}/packages/OpenComputerUseKit" \
  --configuration release --product cua-driver

binary="$(swift build --package-path "${repo_root}/packages/OpenComputerUseKit" \
  --configuration release --product cua-driver --show-bin-path)/cua-driver"

rm -rf "${app}"
mkdir -p "${app}/Contents/MacOS"
cp "${binary}" "${app}/Contents/MacOS/cua-driver"

cat > "${app}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>cua-driver</string>
	<key>CFBundleIdentifier</key>
	<string>ai.kamik.cua-driver</string>
	<key>CFBundleName</key>
	<string>CuaDriver</string>
	<key>CFBundleDisplayName</key>
	<string>Cua Driver</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${version}</string>
	<key>CFBundleVersion</key>
	<string>${version}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

codesign --force --options runtime --timestamp --sign "${identity}" "${app}"
codesign --verify --strict "${app}"
echo "Built ${app} (version ${version}, identity: ${identity})"
