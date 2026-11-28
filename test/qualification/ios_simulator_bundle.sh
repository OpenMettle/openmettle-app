#!/usr/bin/env bash
# Check the packaged registration and entitlement for CI's synthetic iOS client.
set -euo pipefail
app=${1:?Pass the path to the configured simulator Runner.app}
plutil -convert json -o - "$app/Info.plist" | jq -e '
  .OpenMettleNativeIssuer == "https://app.relying.test:18443" and
  .OpenMettleNativeClientID == "synthetic.ios" and
  .OpenMettleNativeRedirectURI == "https://return.relying.test/native/complete" and
  .CFBundleIdentifier == "org.openmettle.app.debug" and
  .FlutterDeepLinkingEnabled == false' >/dev/null

# Simulator entitlements are linked into the main executable's Mach-O section.
scratch=$(mktemp -d)
trap 'rm -f "$scratch/Runner" "$scratch/entitlements.plist"; rmdir "$scratch"' EXIT
binary="$app/Runner"
if [[ $(xcrun lipo -archs "$binary") != arm64 ]]; then
  xcrun lipo -thin arm64 "$binary" -output "$scratch/Runner"
  binary="$scratch/Runner"
fi
xcrun segedit "$binary" -extract __TEXT __entitlements "$scratch/entitlements.plist"
plutil -convert json -o - "$scratch/entitlements.plist" | jq -e '
  .["com.apple.developer.associated-domains"] == ["webcredentials:return.relying.test"]' >/dev/null
