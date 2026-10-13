#!/bin/bash
# Installs the last build on the booted simulator and launches it. LINK_CODE=<code> hands it a
# link code, as if entered, so a test can link it with a Mac (`codealong devices code` there),
# QUERY=<text> types it into the quick search, and OPEN=<key> opens that session
# (`@<Mac short id>:<key there>`) once its Mac lists it, as a `codealong://session/` link does
# without the system asking first; OPEN=pr:<owner/name#number> opens a PR's page, and OPEN=new: New session. LOOK_ONLY=1 marks nothing it opens seen, for a check that goes
# through your real sessions and must leave them as they were, QUEUE=<key>,<key> is what it
# goes through in place of what waits on you, and IMPROVE=1 presses Improve Codealong a few
# seconds in, once the Macs have answered.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=DerivedData/Build/Products/Debug-iphonesimulator/Codealong.app
xcrun simctl install booted "$APP"
SIMCTL_CHILD_CODEALONG_LINK_CODE="${LINK_CODE:-}" SIMCTL_CHILD_CODEALONG_QUERY="${QUERY:-}" SIMCTL_CHILD_CODEALONG_OPEN="${OPEN:-}" SIMCTL_CHILD_CODEALONG_LOOK_ONLY="${LOOK_ONLY:-}" SIMCTL_CHILD_CODEALONG_QUEUE="${QUEUE:-}" SIMCTL_CHILD_CODEALONG_IMPROVE="${IMPROVE:-}" xcrun simctl launch --terminate-running-process booted dev.codealong.app
