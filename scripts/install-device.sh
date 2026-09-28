#!/bin/bash
# Builds the app for an iPhone and installs it on one paired with this Mac: the first available,
# or DEVICE=<its name or identifier>. It's signed by your Apple developer team: CODEALONG_TEAM_ID,
# else the first team Xcode has (Xcode › Settings › Accounts). Xcode makes the provisioning profile
# as it builds (-allowProvisioningUpdates).
#
# With a free Personal Team the app runs for 7 days before it needs installing again, and the
# first time the phone asks you to trust the developer: Settings › General › VPN & Device
# Management. The phone needs Developer Mode on (Settings › Privacy & Security).
set -euo pipefail
cd "$(dirname "$0")/.."

team="${CODEALONG_TEAM_ID:-}"
if [ -z "$team" ]; then
  team="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | grep -m1 -o 'teamID = [A-Z0-9]*' | awk '{print $3}' || true)"
fi
if [ -z "$team" ]; then
  echo "No Apple developer team: add your Apple ID in Xcode › Settings › Accounts, or set CODEALONG_TEAM_ID."
  exit 1
fi

# The core for the phone itself, not only the simulator.
if [ "${CORE:-}" = 1 ] || [ ! -d build/CodealongCore.xcframework/ios-arm64 ]; then
  scripts/build-core.sh
fi
xcodegen generate --quiet
xcodebuild -project Codealong.xcodeproj -scheme Codealong -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" build -quiet
app=DerivedData/Build/Products/Release-iphoneos/Codealong.app

if [ -z "${DEVICE:-}" ]; then
  list="$(mktemp)"
  xcrun devicectl list devices --json-output "$list" >/dev/null
  DEVICE="$(python3 - "$list" <<'EOF'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devices:
    props = d.get("deviceProperties", {})
    hw = d.get("hardwareProperties", {})
    if hw.get("deviceType") == "iPhone" and d.get("connectionProperties", {}).get("pairingState") == "paired":
        print(d["identifier"])
        break
EOF
)"
  rm -f "$list"
fi
if [ -z "$DEVICE" ]; then
  echo "No iPhone paired with this Mac: connect it once with a cable and trust this Mac on it."
  exit 1
fi

xcrun devicectl device install app --device "$DEVICE" "$app"
xcrun devicectl device process launch --device "$DEVICE" dev.codealong.app
echo "Installed and launched Codealong on $DEVICE (team $team)."
