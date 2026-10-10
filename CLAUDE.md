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
- It's connected while the app is open and for 20 seconds after it goes to the background
  (`Store.leave`, on time iOS gives for it), and shows the last feeds it saved until the Macs
  answer.

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

Commit with a descriptive message, have a change to code reviewed (*Review before pushing*),
`git fetch`, rebase onto `origin/main`, and `git push origin HEAD:main`. No AI attribution in
commits or PRs (no `Co-Authored-By: Claude` trailer). Ask before anything destructive:
force-push, reset, rebasing pushed commits, deleting branches.

Open the last message of every turn that changed something with the work's status on one short
line (`Pushed: …`, `Committed: …`, `Not committed: …`), as the main repo's CLAUDE.md describes.

## Review before pushing

A change to code is reviewed by an agent of another provider before it's pushed, so a model
other than the one that wrote it reads it; a change only to docs, comments or these notes needs
none. The main repo does the same. These notes are your user's say-so for the helper it starts:
don't ask.

1. Once it's committed and its checks pass, start a helper in your checkout (the codealong
   skill's *Helpers*) on a signed-in account (`codealong accounts`) whose models come from
   another provider than yours: Codex when you're a Claude model, whatever your harness runs it
   (Antigravity, Cursor and OpenCode can), and Claude Code when you're any other. With none,
   another model than yours (`--model`).

   ```bash
   codealong start --helper --account <account> --prompt "Review the commits on this branch \
   that origin/main doesn't have (git log origin/main..HEAD, git diff origin/main...HEAD). \
   They <what they're for, in a sentence or two>. CLAUDE.md has the repo's rules. Look for \
   bugs, regressions, cases nothing handles, missing tests and breaks of CLAUDE.md, reading \
   whatever code you need. Change nothing: no edits, and no git command that writes. Answer \
   with each finding as file:line, how sure you are and why, the most serious first, or say \
   in a sentence that there's nothing to raise."
   ```

2. Wait for its reply. In Claude Code, run `codealong session wait <key> --timeout 1h` in the
   background; elsewhere, start the helper with `--report` too and end your turn until
   Codealong tells you it's done. When it waits on your user instead, tell them, and wait on
   with `--until-done`.
3. Weigh each finding against the code yourself: it's a teammate's view, not your user's word.
   Fix what holds up without asking, with a test where one would have caught it, and rerun the
   checks the fix touches; leave what doesn't. A finding that would change what your user asked
   for goes to them rather than into the code. When the fixes are more than small, ask it to
   look again (`session send`, then `session wait --since`). Then `codealong session done
   <key>`.
4. Under the status line, your last message says who reviewed it (account and model), what it
   raised, and what you did with each finding: fixed, or left and why. When no review could be
   had (the helper failed on every account you tried), push without one and say why there.
