# Codealong for iPhone

A native app for the sessions on all your Macs: every agent Codealong tracks on each of them in
one list, most urgent first, and, where a Mac has remote control on, a way to act on them. It's
another of your devices to the Macs, so it links and talks to them as they talk to each other,
peer to peer, with no server of Codealong's in between.

Status: early. It links with your Macs, lists their sessions in the sections and order of the
Mac's Sessions view (snoozed ones apart), narrowed to a project if you like, and shows each one's
conversation, reading back as you scroll up with what you asked pinned over its reply, and a
hosted session's reply as it's written, drawn as the Mac draws it: replies as Markdown with tables,
quotes, lists and code to copy, web links (a PR's as `name#123`) that open, your prompts as you
wrote them, commands you ran with what they printed, a prompt the session took back, the
questions a call asked with what you picked, and a link to the page a call published. Where a Mac has remote
control on, it replies (into the running turn at once where the session can take it), answers
approvals and questions (or denies a call, saying what to do instead), stops a turn, switches a
running session's model, goes on with one that isn't running where and on what you pick, forks
one, marks one done (closing it where its Mac can, as Mark as done does there), and starts
sessions, in a worktree, a new one, or a chat in no project, on the account,
model, effort and place the chips say. It renames sessions with remote control off too. The
reply box says how a message gets there, as the Mac says. The plan is in the main repo's
`design/plans/ios.md`.

Its one screen is the Mac's quick panel: an input at the top, and under it the sessions that need
you, then the ones whose turn ended (the ones working when nothing waits), then the rest started in
the last day. Typing finds sessions, by what was said in them too (each Mac's text search), and
PRs; the Mac chosen at the bottom suggests where the text goes (its Jev, through the `route`
request); and the row at the bottom starts a session with it on the Mac, worktree, account and
place the chips under it say.

It works through what waits on you as the Mac's session panel does: once you've replied or
answered, the most urgent session still waiting on you is a tap away above the reply box (Next),
and holding Send sends and goes straight on (⌘⏎ on a keyboard). The chevron at the top skips to
it; one skipped comes round again after the rest. Swiping across a conversation goes along the
same queue: to the left the next, as the Mac's ⌘] does, and to the right back to the session you
came from. Mark as unread, in a session's menu or by holding its row, makes a turn you've seen
Your turn again, on every device, until it's seen or prompted. A
message shows in the conversation the moment you send it, as sending, then sent, until the
session's record has it, so you can write the next or go straight on; one that doesn't go is back
in its box. Dragging or tapping the conversation puts the keyboard away.

Projects are the Macs' own: each session comes in its Mac's project, and the phone lines them up
across Macs as a Mac lines up another's worktrees, by repo. A worktree goes into the project any
of your Macs has its repo in, else into a project of the same name, so one project on two Macs is
one project here, even where one of them has that repo in no project.

## How it fits with the Mac app

The Mac app ([codealong/codealong](https://github.com/codealong/codealong)) keeps a connection to
each of your other devices and trades feeds of worktrees and sessions with the ones you've
linked (Settings › Devices). This app is a device that only watches: it links with a Mac's link
code, keeps the feed each Mac sends, and asks Macs for what it shows; it has no board of its own
and answers nothing.

Everything the two sides say to each other comes from one Rust crate, `codealong-peer`, in the
main repo at `src-tauri/peer/`: the protocol and each side's proof of its device key, link codes,
the feed and the worktrees and sessions it carries, reaching a Mac anywhere through iroh, and the
watching client. The Mac's engine builds on it, and so does `core/` here, so the two can't drift.

```
Codealong/          SwiftUI: the quick search, a session, the Macs sheet, the store
core/               Rust: a thin layer over codealong-peer's client, exported with UniFFI
scripts/            build-core.sh (core → XCFramework + Swift bindings), build.sh, run.sh
project.yml         XcodeGen's spec; Codealong.xcodeproj is generated from it
```

## Building

Needs Xcode 26 with the iOS SDK, XcodeGen (`brew install xcodegen`), and Rust with the iOS
targets (`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`).

```bash
scripts/build.sh                    # the core for the simulator if it's missing, then the app
CORE=1 scripts/build.sh             # rebuild the core too
scripts/run.sh                      # install and launch on the booted simulator
LINK_CODE=cal1… scripts/run.sh      # launch with a Mac's link code, as if entered
```

On the Mac, `codealong devices code` makes a link code (the app running, Devices and iroh on).

## On your iPhone

```bash
scripts/install-device.sh           # build for iPhone, sign, install and launch on a paired phone
```

It installs on an iPhone paired with this Mac (connect it once with a cable and trust the Mac),
signed by your Apple developer team from Xcode › Settings › Accounts (`CODEALONG_TEAM_ID` picks
another). With a free Personal Team the app runs for 7 days before it needs installing again. The
phone has to be unlocked while it installs, needs Developer Mode on (Settings › Privacy &
Security), and the first time asks you to trust the developer (Settings › General › VPN & Device
Management).

Then link it with each Mac: scan the QR code in the Mac's Settings › Devices with the phone's
camera, or enter a code from `codealong devices code` under Macs.
