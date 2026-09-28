#!/bin/bash
# Builds the app for the simulator: the Rust core if it's missing or CORE=1, the Xcode project
# from project.yml, then the app. The .app lands in DerivedData/Build/Products.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${CORE:-}" = 1 ] || [ ! -d build/CodealongCore.xcframework ]; then
  SIM_ONLY=${SIM_ONLY:-1} scripts/build-core.sh
fi
xcodegen generate --quiet
xcodebuild -project Codealong.xcodeproj -scheme Codealong -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData \
  build -quiet
echo "Built DerivedData/Build/Products/Debug-iphonesimulator/Codealong.app"
