#!/bin/bash
# Builds the app for an iPhone or iPad paired with this Mac and installs it there: one connected
# now before one that's only paired, or DEVICE=<its name, identifier or UDID>. It's signed by your
# Apple developer team: CODEALONG_TEAM_ID, else the first team Xcode has (Xcode › Settings ›
# Accounts). The build is for that device, so Xcode registers it with the team and makes the
# provisioning profile as it builds (-allowProvisioningUpdates, -allowProvisioningDeviceRegistration):
# a free Personal Team gets a device registered only by building for it.
#
# An App ID belongs to one team, and dev.codealong.app to Codealong's own (N3347S68VA), so a
# build signed by any other team is dev.codealong.app.<team ID>, or CODEALONG_BUNDLE_ID. Keep a
# phone's ID once it's linked: the device key is in the Keychain of the app with that ID, and an
# app with another is another app to iOS, with a key of its own, to link again.
#
# DRY_RUN=1 says which team, ID and device it would use, and builds nothing. CORE=1 rebuilds the
# Rust core even when core/ hasn't changed since it was built.
#
# With a free Personal Team the app runs for 7 days before it needs installing again, and the
# first time the phone asks you to trust the developer: Settings › General › VPN & Device
# Management. The phone needs Developer Mode on (Settings › Privacy & Security).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! said="$(xcodebuild -version 2>&1)"; then
  echo "$said"
  echo "Xcode has to be the selected developer directory: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi
if ! command -v xcodegen >/dev/null; then
  echo "No XcodeGen: brew install xcodegen"
  exit 1
fi

# Codealong's own team, which dev.codealong.app is registered to.
own_team=N3347S68VA

# The teams Xcode has, a line each, "ID<tab>name", Codealong's own first where it's one of them.
teams="$({ defaults export com.apple.dt.Xcode - 2>/dev/null || true; } | python3 -c '
import plistlib, sys
try:
    accounts = plistlib.loads(sys.stdin.buffer.read()).get("IDEProvisioningTeamByIdentifier", {})
except Exception:
    accounts = {}
teams = {}
for account in accounts.values():
    for t in account:
        if t.get("teamID"):
            teams.setdefault(t["teamID"], t.get("teamName") or t["teamID"])
for id in sorted(teams, key=lambda id: id != sys.argv[1]):
    print(f"{id}\t{teams[id]}")
' "$own_team")"
team="${CODEALONG_TEAM_ID:-$(head -n1 <<<"$teams" | cut -f1)}"
if [ -z "$team" ]; then
  echo "No Apple developer team: add your Apple ID in Xcode › Settings › Accounts (a free Personal Team works), or set CODEALONG_TEAM_ID."
  exit 1
fi
team_name="$(awk -F'\t' -v t="$team" '$1 == t { print $2 }' <<<"$teams")"
other_teams="$(awk -F'\t' -v t="$team" '$1 != "" && $1 != t { printf "%s%s \"%s\"", (n++ ? ", " : ""), $1, $2 }' <<<"$teams")"

if [ -n "${CODEALONG_BUNDLE_ID:-}" ]; then
  bundle_id="$CODEALONG_BUNDLE_ID"
elif [ "$team" = "$own_team" ]; then
  bundle_id=dev.codealong.app
else
  bundle_id="dev.codealong.app.$team"
fi

# The device: a line for the one picked, "identifier<tab>UDID<tab>name<tab>model<tab>state<tab>
# developer mode", then a line each for the others. devicectl knows it by its identifier and
# xcodebuild by its UDID.
devices="$(mktemp)"
trap 'rm -f "$devices"' EXIT
xcrun devicectl list devices --json-output "$devices" >/dev/null
picked="$(python3 - "$devices" "${DEVICE:-}" <<'EOF'
import json, sys

path, wanted = sys.argv[1], sys.argv[2]

# Names match whatever their case, and a curly apostrophe matches a straight one. No odd quote
# in this Python, nor in its comments: the /bin/bash of macOS reads it for one, being inside a
# command substitution.
def plain(s):
    return s.replace("\u2019", "\u0027").casefold()

found = []
for d in json.load(open(path))["result"]["devices"]:
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    props = d.get("deviceProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") != "physical" or hw.get("deviceType") not in ("iPhone", "iPad"):
        continue
    if conn.get("pairingState") != "paired" or not hw.get("udid"):
        continue
    found.append({
        "identifier": d["identifier"],
        "udid": hw["udid"],
        "name": props.get("name") or hw.get("marketingName") or hw["deviceType"],
        "model": hw.get("marketingName") or hw["deviceType"],
        "connected": conn.get("tunnelState") == "connected",
        "reachable": conn.get("tunnelState") in ("connected", "disconnected"),
        "devmode": props.get("developerModeStatus") or "unknown",
    })

if not found:
    sys.exit("No iPhone or iPad is paired with this Mac: connect it with a cable once, unlocked, and tap Trust on it.")
if wanted:
    match = [f for f in found if plain(wanted) in (plain(f["identifier"]), plain(f["udid"]), plain(f["name"]))]
    if not match:
        sys.exit(f"No iPhone or iPad called {wanted} is paired with this Mac. These are: {', '.join(f['name'] for f in found)}.")
    found = match + [f for f in found if f not in match]
else:
    # Connected now first, then one that can be reached, in the order devicectl lists them otherwise.
    found.sort(key=lambda f: (not f["connected"], not f["reachable"]))

pick = found[0]
state = "connected" if pick["connected"] else "not connected now"
print("\t".join([pick["identifier"], pick["udid"], pick["name"], pick["model"], state, pick["devmode"]]))
for f in found[1:]:
    print(f["name"])
EOF
)"
IFS=$'\t' read -r device_id udid device_name model state devmode <<<"$(head -n1 <<<"$picked")"
other_devices="$(tail -n +2 <<<"$picked" | awk '{ printf "%s%s", (n++ ? ", " : ""), $0 }')"

echo "Team: $team${team_name:+ \"$team_name\"}, so the app is $bundle_id. CODEALONG_TEAM_ID=<team ID> signs with another${other_teams:+ (Xcode also has $other_teams)}."
echo "Device: $device_name ($model, $state). DEVICE=<name> picks another${other_devices:+ (also paired: $other_devices)}."
if [ "$state" != connected ]; then
  echo "  Unlock it, and connect it with a cable or keep it on this Mac's network."
fi
if [ "$devmode" = disabled ]; then
  echo "  Developer Mode is off on it: turn it on in Settings › Privacy & Security › Developer Mode, and restart it when it asks."
fi

build=(xcodebuild -project Codealong.xcodeproj -scheme Codealong -configuration Release
  -destination "platform=iOS,id=$udid" -derivedDataPath DerivedData
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration
  DEVELOPMENT_TEAM="$team" PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" build -quiet)
if [ "${DRY_RUN:-}" = 1 ]; then
  echo "Would build with: ${build[*]}"
  exit 0
fi

# The core for the phone itself, not only the simulator, when core/ changed since it was built.
if [ "${CORE:-}" != 1 ]; then export IF_CHANGED=1; fi
SIM_ONLY='' scripts/build-core.sh
xcodegen generate --quiet
"${build[@]}"
app=DerivedData/Build/Products/Release-iphoneos/Codealong.app
built_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"

xcrun devicectl device install app --device "$device_id" "$app"
# iOS won't open the first install from a Personal Team until you trust its developer there, so a
# launch that fails says so rather than failing the install.
if xcrun devicectl device process launch --device "$device_id" "$built_id"; then
  echo "Installed and opened Codealong on $device_name (team $team, $built_id)."
else
  echo "Installed. Trust the developer in Settings › General › VPN & Device Management, then open Codealong."
fi
