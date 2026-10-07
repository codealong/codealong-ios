#!/bin/bash
# Installs the last build on the booted simulator and launches it. LINK_CODE=<code> hands it a
# link code, as if entered, so a test can link it with a Mac (`codealong devices code` there),
# QUERY=<text> types it into the quick search, and OPEN=<key> opens that session
# (`@<Mac short id>:<key there>`) once its Mac lists it, as a `codealong://session/` link does
# without the system asking first.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=DerivedData/Build/Products/Debug-iphonesimulator/Codealong.app
xcrun simctl install booted "$APP"
SIMCTL_CHILD_CODEALONG_LINK_CODE="${LINK_CODE:-}" SIMCTL_CHILD_CODEALONG_QUERY="${QUERY:-}" SIMCTL_CHILD_CODEALONG_OPEN="${OPEN:-}" xcrun simctl launch --terminate-running-process booted dev.codealong.app
