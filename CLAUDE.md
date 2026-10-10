# Codealong for iPhone

A native iOS app (SwiftUI over a Rust core) for the sessions on all of a person's Macs running
Codealong ([codealong/codealong](https://github.com/codealong/codealong), the main repo). README.md
says what it is and how it fits; the plan is the main repo's `design/plans/ios.md`.

Like the Mac app, it's meant for other people too: nothing may assume the user's own Macs,
projects or naming.

## Commands

```bash
scripts/build-core.sh          # Rust core → build/CodealongCore.xcframework + Codealong/Generated (SIM_ONLY=1: simulator only)
scripts/build.sh               # core if missing (CORE=1 forces it), xcodegen, then the app for the simulator
scripts/run.sh                 # install and launch on the booted simulator; LINK_CODE=<code> links it at launch
scripts/install-device.sh      # a release build on a paired iPhone, signed by your team (README, Get it on your iPhone)
(cd core && cargo test)        # the core's tests
```

Rust builds go to `../codealong-ios-target` (`.cargo/config.toml`), shared by every worktree.
`Codealong.xcodeproj` and `Codealong/Info.plist` are generated from `project.yml` by XcodeGen:
change the spec, never a pbxproj.

## The main repo is the source of the protocol

Everything the phone and the Macs say to each other is in the main repo's crate `codealong-peer`
(`src-tauri/peer/`): the messages and key proofs (`proto`), link codes and iroh (`net`), feeds
(`feed`), the worktree and session model (`model`), and the watching client (`client`). `core/`
here is only a UniFFI layer over that client plus what the phone shows (rows, sorted as the
Mac's board sorts them). So:

- A change to what goes between devices is made in the main repo first, landed there (its
  CLAUDE.md), then picked up here by moving the pin.
- `core/Cargo.toml` depends on `codealong-peer` by git, pinned to a commit in `origin/main`:
  never a path into the main checkout, where other sessions' uncommitted edits sit. To work on
  both at once, point it at a worktree of your own with a cargo `[patch]` and don't commit that.
- The phone has to work with Macs on older and newer builds: a message a peer doesn't know ends
  the connection there, so only send new messages to Macs that say they know them.

To take a newer one: set `rev` in `core/Cargo.toml` to a commit in the main repo's `origin/main`,
then `scripts/build-core.sh` (cargo fetches it with your git login).

## How the phone is a device

- It has an Ed25519 device key in the Keychain (this device only) and links with a Mac's link
  code (`cal1…`: the Mac's key and a one-time secret) over iroh, typed or pasted, or as the
  `codealong://link/<code>` its QR code holds, which the camera opens here (the app asks first).
  Its hello says it's a phone (or a tablet), so the Mac lists it apart in Settings › Devices,
  sends it its feed, answers its requests, and never dials it or asks it to search.
- It never sends a feed and answers every request with a refusal.
- It reads with `session-page`, `session-newer`, `session-pending`, `session-way`,
  `start-options`, `route` and `search`, and organizes (`mark-seen`, `session-archive`,
  `session-rename`) with any Mac. It can only act (`session-send`, `session-answer`,
  `session-cancel`, `session-resume`, `session-model`, `session-fork`, `session-done`, `start`)
  where the Mac has remote control on (Settings › Devices there), and each of those is written
  to that Mac's `devices.log`. Who may ask for what is the main repo's `api::REQUESTS`; a Mac of an older
  build refuses a request it doesn't know, and the phone says why.
- A Mac takes what the phone sends as yours, as it takes what you type in its windows (a phone
  runs no agents): a message to a session that skips permission prompts claims that, so Claude
  Code doesn't hold it for you to allow (the main repo's actions.rs `From::Phone`).
- It's connected only while the app is open (`Core::start`/`stop` follow the scene phase), and
  shows the last feeds it saved until the Macs answer.

## Checking changes

- `scripts/build.sh && scripts/run.sh`, then look at it in the simulator: the iOS Simulator
  tool's `screenshot` does it without the panel. Check light and dark.
- Real sessions are fine to test with, actions included: sending prompts, answering approvals,
  archiving. Linking the simulator with this Mac is fine too (unlink it after with `codealong
  devices unlink`).

## Conventions

- SwiftUI and Observation, Swift 6; no third-party Swift packages.
- Swift never parses JSON or re-derives a rule: the core hands it records, and what a session
  says was written by its Mac.
- UI copy is sentence case and plain words. Comments explain why, in plain sentences.

## Landing work

Commit with a descriptive message, `git fetch`, rebase onto `origin/main`, and `git push origin
HEAD:main`. No AI attribution in commits or PRs (no `Co-Authored-By: Claude` trailer). Ask
before anything destructive: force-push, reset, rebasing pushed commits, deleting branches.

Open the last message of every turn that changed something with the work's status on one short
line (`Pushed: …`, `Committed: …`, `Not committed: …`), as the main repo's CLAUDE.md describes.
