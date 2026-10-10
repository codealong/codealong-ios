<p align="center">
  <img src="design/app-icon.svg" alt="" width="112" height="112" />
</p>

<h1 align="center">Codealong for iPhone</h1>

<p align="center"><strong>Your coding agents, in your pocket.</strong></p>

<p align="center">
  Every agent session on all your Macs, most urgent first, on your iPhone.<br />
  Read what they're doing, answer what they ask, and start new work, from anywhere.
</p>

<p align="center">
  <a href="#what-you-can-do">What you can do</a>
  &nbsp;·&nbsp; <a href="#get-it-on-your-iphone">Get it on your iPhone</a>
  &nbsp;·&nbsp; <a href="#privacy-and-security">Privacy</a>
  &nbsp;·&nbsp; <a href="#faq">FAQ</a>
  &nbsp;·&nbsp; <a href="https://github.com/codealong/codealong">The Mac app</a>
</p>

> **Early days.** The app works day to day, but it isn't on the App Store or TestFlight yet: for
> now you build it with Xcode and install it on your own iPhone. Notifications aren't in yet.

## What it is

[Codealong](https://github.com/codealong/codealong) is a Mac app that keeps track of every coding
agent you run (Claude Code, Codex, OpenCode, Antigravity and Cursor, on every account) and shows
what each one is doing and which ones need you. Codealong for iPhone takes that with you.

Link your phone with your Macs once, and it shows every session on all of them in one list: the
agents that need you first, then the ones that just finished, then the rest. Open one to read its
conversation and reply to it, allow what it wants to run, answer its questions, or start a new
session on any Mac, without walking back to your desk.

The phone is another of your devices to your Macs, so it talks to them the way they talk to each
other: directly, encrypted end to end, with no Codealong server in between.

## What you can do

**See what needs you.** The home screen is the Mac's quick panel: a search box, and under it the
sessions that need you, then the ones whose turn just ended (the working ones when nothing is
waiting), then the rest from the last day. Narrow it to one project if you like. A project that
lives on two Macs is one project here.

**Read any conversation.** Each session's conversation shows as it does on the Mac: replies as
formatted text with tables, nested lists and code you can copy, your prompts, the commands that ran and
what they printed, and the questions an agent asked with what you picked. Scroll up to read
further back, with the prompt you're reading the answer to pinned at the top. A session running
inside Codealong on your Mac streams its reply as it's written.

**Work through what's waiting.** Once you've replied, the next session waiting on you is a tap
away (*Next*), and holding *Send* sends and goes straight on. Swipe left for the next waiting
session and right to go back to the one you came from; one you swipe on from counts as seen.
The next one is read ahead, so it shows at once. Replies an agent suggested for a session (a
supervisor going over what waits on you, with `codealong session suggest`) show above its box:
tap one to send it, or hold it to change it first. Helper sessions (ones an agent started to help
it, and automatic PR reviews) stay out of your lists unless they need you, as on the Mac.

**Act on a session**, on any Mac that has remote control turned on:

- reply to it, or slip a message into the turn it's taking right now;
- allow or deny what it wants to run (or deny it and say what to do instead), and answer its
  questions;
- stop its turn;
- switch a running session's model;
- resume one that isn't running, where and on what model you pick;
- fork it, or mark it done (closing it where its Mac can).

Renaming, archiving, marking seen, *Mark as unread*, *Snooze* (off what waits on you until the time
you pick, on every device) and *Quiet* (its turns stop waiting on you; it comes to you only when it
needs you) work with any Mac, remote control or not.

**Review and merge PRs.** The PRs that wait on your review are listed after the sessions whose
turn ended (*Review requested*), longest waiting first, and a search finds any PR your Macs know.
Open one to see where it stands (checks, whether it can merge, its size, who asked you), your
draft review of it if you began one, its description, reviews, comments and changed files with
their diffs. *Review* approves it, comments or asks for changes, submitting your draft with it as
GitHub's *Finish your review* does; *Merge…* is its merge box as on the Mac: the way to merge and
the commit's words, auto-merge, the merge queue, updating the branch, ready for review and the
branch's deletion. Your Mac's `gh` does it as you, so reviewing and merging need remote control on
that Mac; reading and snoozing a review don't.

**Start new work.** Type a prompt and start it on the Mac, worktree, account, model, effort and
place the chips under it say: an existing worktree, a new one, or a chat in no project. As you
type, it finds sessions by what was said in them, and the Mac you pick suggests where the prompt
belongs when it has Jev's suggestions on.

**Write ahead.** A message shows in the conversation the moment you send it, marked sending, then
sent, so you can write the next one or move on. One that doesn't go comes back to its box.

## How it works with your Macs

You need the [Codealong Mac app](https://github.com/codealong/codealong) on each Mac you want to
see, with **Settings › Devices** turned on. That's all it takes to see sessions and read their
conversations.

To reply, approve, start or stop from your phone, turn on **remote control** in Settings › Devices
on the Mac you want to act on. It's off by default, it's per Mac, and every request a Mac takes
from another device is written to its `~/Library/Logs/Codealong/devices.log`.

The phone doesn't keep a board of its own. Each Mac works out its sessions' status and what
they're waiting on, and sends the phone a feed of them; the phone asks the Mac for what it shows
and keeps what it last saw, so it opens straight onto your sessions while it reconnects.

## Get it on your iPhone

Until it's on TestFlight, you build it on a Mac and install it on an iPhone paired with that Mac.

**You'll need:**

- A Mac with [Xcode](https://developer.apple.com/xcode/) 26 and its iOS SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Rust (`rustup`) with the iOS targets: `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`
- An iPhone on iOS 26, and an Apple ID added in Xcode › Settings › Accounts (a free Personal
  Team works)

**Install it:**

1. Connect your iPhone to the Mac with a cable once, and tap *Trust* on the phone.
2. On the phone, turn on Developer Mode (Settings › Privacy & Security › Developer Mode) and
   restart when it asks.
3. Clone and install, with the phone unlocked:

   ```bash
   git clone https://github.com/codealong/codealong-ios.git
   cd codealong-ios
   scripts/install-device.sh
   ```

   It builds the app for iPhone, signs it with your team from Xcode's settings
   (`CODEALONG_TEAM_ID` picks another), installs it and opens it.
4. The first time, iOS asks you to trust the developer: Settings › General › VPN & Device
   Management, then your Apple ID.

With a free Personal Team, Apple lets the app run for 7 days before it needs installing again:
run `scripts/install-device.sh` again. A paid developer account signs it for a year.

**Link it with your Macs.** On each Mac, open Codealong's Settings › Devices and scan its QR code
with the iPhone's camera; the app opens and asks to link. Or, on the Mac, run `codealong devices code`
and enter the code in the app, under *Macs*. You do this once per Mac.

## Privacy and security

- **No server.** The phone talks straight to your Macs over [iroh](https://iroh.computer),
  encrypted end to end, wherever you are. Nothing goes through a Codealong server, because there
  isn't one.
- **Linking is deliberate.** A link code is one-time, and each side proves who it is with a device
  key; the phone's stays in its Keychain, on that phone only.
- **The phone only watches.** It never sends a feed of its own and refuses anything a Mac asks of
  it. It reads conversations by asking the Mac they're on; transcripts stay on that Mac.
- **Your Macs decide.** Acting on a session needs remote control turned on at that Mac, and each
  request is logged there.
- **Connected only while it's open.** The app connects when you open it and disconnects when you
  leave it.

## FAQ

**Do I need Tailscale or to be on the same Wi-Fi?**
No. The phone reaches your Macs anywhere through iroh. Your Macs need to be awake and running
Codealong to answer.

**Does it work with any coding agent?**
It shows every session your Macs' Codealong sees: Claude Code, Codex, OpenCode, Antigravity and
Cursor. What you can do to one is what its Mac can do: replies and approvals work where Codealong
on the Mac can send and answer for that agent (see the Mac app's
[support table](https://github.com/codealong/codealong#what-works-with-each-agent)).

**Will it notify me when an agent needs me?**
Not yet. Notifications are planned, with widgets and an iPad layout.

**What if my Mac runs an older version of Codealong?**
The phone works with Macs on older and newer builds. A Mac that doesn't know a request yet says
so, and the phone tells you why it didn't go.

**Can I use it on an iPad?**
It installs and runs on an iPad too, laid out as on the iPhone; a layout of its own for the iPad
is planned.

## Developing

The app is SwiftUI over a small Rust core. Everything the phone and the Macs say to each other
comes from one crate, `codealong-peer`, in the Mac app's repo (`src-tauri/peer/`): the protocol and
each side's proof of its device key, link codes, the feed and the worktrees and sessions it
carries, and reaching a Mac through iroh. The Mac's engine builds on it, and so does `core/` here,
so the two can't drift apart.

```
Codealong/          SwiftUI: the quick search, a session, the Macs sheet, the store
core/               Rust: a thin layer over codealong-peer's client, exported with UniFFI
scripts/            build-core.sh (core → XCFramework + Swift bindings), build.sh, run.sh, install-device.sh
project.yml         XcodeGen's spec; Codealong.xcodeproj is generated from it
```

To run it in the simulator:

```bash
scripts/build.sh                    # the core for the simulator if it's missing, then the app
CORE=1 scripts/build.sh             # rebuild the core too
scripts/run.sh                      # install and launch on the booted simulator
LINK_CODE=cal1… scripts/run.sh      # launch with a Mac's link code, as if entered
LOOK_ONLY=1 QUEUE=<key>,<key> OPEN=<key> scripts/run.sh  # go through real sessions, marking none seen
(cd core && cargo test)             # the core's tests
```

On the Mac, `codealong devices code` makes a link code (the app running, with Devices and iroh
on). [CLAUDE.md](CLAUDE.md) has the working notes every change follows, and the plan is in the
Mac app's repo, `design/plans/ios.md`.
