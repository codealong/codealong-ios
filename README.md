<p align="center">
  <img src="design/app-icon.png" alt="" width="112" height="112" />
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
  &nbsp;·&nbsp; <a href="https://www.codealong.com">codealong.com</a>
</p>

> **Early days.** The app works day to day, but it isn't on the App Store or TestFlight yet: for
> now you build it with Xcode and install it on your own iPhone. Notifications aren't in yet.

## What it is

[Codealong](https://www.codealong.com) is a Mac app that keeps track of every coding
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
sessions hearing a meeting first (*Listening*), then those pinned on your Macs, in each Mac's order
(pin or unpin one from its long-press menu), then the ones that need you, then the ones whose turn just ended (the working ones when
nothing is waiting), then the rest from the last day. Typing in the box finds sessions, by what
was said in them too, and PRs; *Archived* on the sessions' heading lists archived ones as well,
after the others that match as closely, and stays on until you turn it off. The menu at the top left orders the sessions *By project* instead,
worktree by worktree (tap a worktree to fold it away, or its ✎ to start a session in it), or
*Recent*, the last active first. Both lead with your orchestrators' sessions (*Orchestrator*), as
the Mac's Sessions does: the one that keeps watch over the project picked, or under All every one,
each saying what it keeps watch over where another session says its worktree, and never among the
sessions it watches. Its page says under its title when it last looked, or that it's off, and folds
each look that found nothing into a line (*Looked 3 times: nothing new*); it isn't marked done,
archived, pinned or snoozed, since its next look would only start another, and it's turned off on
its Mac. The pills under the box narrow the list to one project; a
project that lives on two Macs is one project here. Each session has the emblem its Mac gave it
beside its title, an emoji or a small drawn picture for what it works on, so you know it at a
glance as you do there. Under its title a row says what it's doing and where it is, as the Mac's
rows do: its account and its worktree, by its repo where the worktree was made for one piece of
work (its own name says little) and by its name where it's reused for one after another, after the
project under All. Its time is how long its state has lasted, or, while it works, how long it has
worked on what you last asked, which the line of what it's doing doesn't say again; the headless
runs its commands started are counted there while one is at work or waits on you. While the app is open, a short sound says when a session on any of your Macs starts
to wait on you, as the Mac's do: a pop when it needs you, a lighter tink when its turn ends (turn
either off in the Macs sheet; neither plays with the phone silenced, nor while a session on one of
your Macs is listening to a meeting).

**Read any conversation.** Each session's conversation shows as it does on the Mac: replies as
formatted text with tables, nested lists, code you can copy and slides to go through (an
Antigravity artifact's carousel), your prompts with their images
and their Markdown drawn too (kept as you typed them), the commands that ran and
what they printed, and the questions an agent asked with what you picked. Calls in a row are one
line that says what they did ("Edited 2 files and ran 3 commands"), and each finished turn's work
folds into one "Worked for 2m · Ran 19 commands" line above the reply that ended it, as the Mac
draws them by default: a tap opens either, and a turn still going, one where a call failed, and a
call that made a page, handed you files or asked you questions stay in view. What Codealong sent a
session by itself (a PR's news, a helper's, a schedule's run, a review handed back) is a card that
says it in a line ("ana asked for changes on #397", the PR and each helper it names a link), and a
tap opens it to the whole message;
another session's message is a card that names who sent it, as a link to that session, over its
first lines (one its own side conversation sent links to that side conversation). A session moved
to another account on its Mac says *Moved to* and the account on its row, and at the end of its
conversation a tap goes to the copy that carries it on, which says what it was moved from. Scroll up to read
further back, with the prompt you're reading the answer to pinned at the top and a button at the
foot that goes back down to the newest. A session running
inside Codealong on your Mac streams its reply as it's written, and one that only waits on a command
says which at the end of its conversation: one you allowed in your terminal (*Running in Ghostty*)
or one its turn left running in the background. A line above its box counts the commands its agent
left running in the background (a Claude Code session's shells and Monitors, a Codex thread's
background terminals), and a tap lists them with where each stands and the last of what it printed,
read again as it runs. One whose command waits at a question in a terminal on its Mac says so, with
the question, to answer there, and one whose helper waits in its terminal there before it starts
(Codex's review of a repo's hooks) says what that shows, to answer from the helper's line on the
Mac. One whose last turn ended on an API error says so under its
conversation, in its harness's words, with *Try again* beside it; one stopped at its account's
usage limit says which, when it lifts and whether another account has room, and once it has lifted,
*Carry on* beside it tells it to carry on in one tap, without waiting for its Mac to (where it
does) or typing it; one its
account's sign-in was turned down for says so too, and whether Codealong carries it on once the
account is signed in again on its Mac (`/login` in its box signs in nothing from the phone, and
says so).

**Work through what's waiting.** Sessions that need you, PRs waiting on your review and finished
turns come one after another, in the Mac's order: the ones moved to the top first, then each kind
the longest waiting first, and the ones you go on from come round again after the rest. While something else waits on you, a bar over the
reply box says how many more do, which comes next, and what swiping left does to the session you're reading: marks it
seen and goes on, or marks it done where its Mac says its work is finished (a PR of its merged, a
todo of its done, its own status line) and it only waits for you to read it. Opening one doesn't
mark it seen, so one you read and go back from is still waiting. Tap the bar to do something else
instead, and go on as you pick it: leave it as it is (to come round again after the rest), mark it
seen or done, archive it, or snooze it for a while. The next one says in a line how the one you
left went (done, archived, snoozed, sent) for a few seconds, or until you write or scroll; a tap on
it shows all its Mac said, such as what Mark as done stopped and cleaned up, and one that didn't
go as asked stays until you dismiss it. Mark as done from a menu (a session's, a row's or the bar's) first asks about its
helpers whose work isn't over, as the Mac does: make them sessions of your own, or end them too
(a swipe makes them yours). Swipe
right to go back to the one you came from, leaving this one as it is. One you replied to, one
still working, and one waiting on you to allow something are left as they are, and holding *Send* sends and goes straight
on. A PR's page has the same bar over its review box: swiping on from a review you haven't given
brings it round again later, a tap on the bar snoozes it instead, and a review you give goes on by
itself once GitHub has it. The next one is read ahead,
so it shows at once. On the last one the bar says nothing else waits, and going on goes to a page that says so,
with how many sessions are working; whatever comes to wait on you while it's open shows up there,
a swipe away. Replies an
agent suggested for a session (a supervisor going over what waits on you, with `codealong session
suggest`) show above its box, in a card of suggestions' color whose sparkle says who suggested
them: tap one to send it, or hold it to change it first. What's said of a session over its box
(cut off, signed out, a usage limit, seen by its agent) is said in a whole sentence. Helper sessions
(ones an agent started to help it, and automatic PR reviews) stay out of your lists unless they
need you, as on the Mac.

**Act on a session**, on any Mac that has remote control turned on:

- reply to it, or slip a message into the turn it's taking right now, with photos or a pasted
  image (screenshots and the like) attached, which the agent gets as the Mac's paste does; a
  message its harness holds until the turn ends shows at the end of the conversation, with *Send
  now* to put it in the turn at once, *Edit* to take it out into the box, and *Remove* so it's never
  sent;
- allow or deny what it wants to run (or deny it and say what to do instead), deliver or drop
  another session's message it holds for you, and answer its
  questions (what its Mac can't answer for you says where to go: "Answer in Ghostty on MacBook
  Pro", and why), folded to a line over the box while you read and brought up from that line: the card
  over the box stands in for the call's line in the conversation until it's answered. A dialog of
  Claude Code's own (its offer to make auto mode the default, a command's list of choices), which
  a Mac of 0.26 or later reads off a session's terminal where it can read it (Rex, tmux or
  Codealong's own terminal; in another terminal app it's answered there), is a card of its choices
  alone, picked there as you'd pick one, with *Cancel* pressing Escape;
- stop its turn, with the square that takes send's place while it runs, or a command its agent
  left running in the background, from the list above its box;
- switch a running session's model, effort or mode (a Claude Code background job's too, from a Mac
  of 0.18 or later, and a Codex app thread's from its next turn): the mode of one in a terminal by
  Shift+Tab pressed there, a background job's from a Mac of 0.21 or later, said in italics until its
  next prompt shows it took;
- run a command its agent wrote for you to run: *Run* beside a shell block in its reply (asked
  first) runs it in a terminal on its Mac, as you, in the folder it works in, and the session is
  told what it printed once it ends, as Run on the Mac does; a message that starts with `!` runs
  the same way. A block with no language gets Run when each of its lines starts with a command
  that Mac has. Needs a Mac newer than 0.22;
- resume one that isn't running, where and on what model you pick: in Codealong where its account
  offers that, as its Mac does, unless you pick another place;
- fork it, go on from before one of your prompts with an edit of it (hold the prompt, *Edit from
  here*), or mark it done (closing it where its Mac can);
- ask a Claude Code, Codex or Antigravity session something on the side (*Ask on the side* in its menu, or
  `/side` and a question in its box, as on the Mac): a throwaway copy of its conversation answers
  on its Mac as you watch, saying how long it has been at it, and the session carries on and never
  hears of it. Follow-ups go to the
  same copy until you close it, and the earlier ones are there to read, go on with or delete. One
  that finishes brings its session back to what waits on you, and comes up as you open it.

A running Claude Code session with Remote Control on opens in the Claude app from its menu.

Renaming, archiving, marking seen, *Mark as unread*, *Move to top* (first in every queue, on every
device, and listed under *Moved to top*, until you send it something or see its finished turn;
*Back in line* undoes it), *Snooze*
(off what waits on you until the time you pick, on every device; a session whose last reply says its
work goes on later is offered a snooze until then, above its box and first in its menu, saying
who read the reply so (Jev, or the agent that tagged it) and never beside a question it asks you, and one
stopped at its usage limit a snooze until the limit lifts, beside the limit's note) and *Quiet* (its turns stop waiting
on you; it comes to you only when it needs you) work with any Mac, remote control or not, and so
do *Labels*: the labels you put on a session there, as todos wear them, shown on its row and under
its title, put on or taken off from its menu (*New label…* names one its Mac doesn't have yet), and
found by name in the search. A turn its own agent marked seen says so rather than waiting on you.

**Review and merge PRs.** The PRs that wait on your review are listed after the sessions whose
turn ended (*Review requested*), longest waiting first, and the *Sessions* menu at the top counts
them. A session whose worktree has a PR ends the line that says where it is with its number, its
icon and a mark for where it stands (checks passed or failing, approved, your move), and so does
the line under its title, a tap on which opens the PR. The menu's *PRs* page lists every PR your
Macs know, under tabs for all of them, yours and others', each counting the PRs in it that are
your move, as the Mac's PRs view does: pinned ones first, then what needs you by what it needs
(*Review requested*, your own *Ready to merge*, which leaves out one approved only before its
latest commits, and *Needs work*: failing checks, changes asked for,
conflicts or a branch behind), then the reviews Codealong's agent is still on (*Agent reviewing*),
then the ones an agent of yours is at work on (*Fixing* what came of their review, or *Working* on a
draft), whose merge or work waits on it, then the rest under the tab's own headings (yours and others' under All, *Waiting on others* and
*Drafts* under Yours, *Not asking you* under Others), snoozed reviews, and the last week's merged
and closed ones folded away. Yours are the ones opened by the GitHub account
most of your Macs are signed in as; when one is signed in as another (a bot your agents open PRs
as, or a work account), the menu's *Your GitHub accounts* picks which count as you. Open one to see where it stands (checks, whether it can merge, its size, who asked you, its labels, an approval of earlier commits, whose move it is where its review state doesn't say, as the Mac's *Author replied* or *Re-review asked* does, and Codealong's own review of it), the
sessions that worked on it on every Mac (tap one to open it), the one its Mac tells of what happens on it first, tagged Primary (the session that started a helper that made it, once that helper is done), your draft review of it if you began one, its description, reviews, comments and changed files with
their diffs. The box at its foot reviews it, as the Mac's does: write what to say, then *Request
changes*, *Comment* or *Approve* (only *Comment* on your own PR or a closed one), submitting your
draft with it as GitHub's *Finish your review* does. Once your approval stands, *Approve* reads
*Approved*. *Merge…*, beside its state, is its merge box
as on the Mac: the way to merge and the commit's words, auto-merge, the merge queue, updating the
branch, ready for review and the branch's deletion. Your Mac's `gh` does it as you, so reviewing and merging need remote control on
that Mac; reading and snoozing a review don't.

**Start new work.** Type a prompt in the same box and start it with the capsule at the bottom,
which says where it starts: its menu picks the Mac (each saying how busy it is, *Calm*, *Busy* or
*Strained*, as its machine menu and the Macs sheet say it), the repo (a sheet of the Mac's repos under
their projects, each saying where a session would start in it) and the worktree in it (the main
checkout first, then *New worktree* and the ones ready for new work), or *General chat*, in a folder of its own and
no repo, and the account, model, effort and place. A new worktree is made by the harness on its
command line where it can (Claude Code's and Cursor's `--worktree`), and by Codealong otherwise, in the repo's
`.codealong/worktrees` from its default branch: for Codex, OpenCode and Antigravity from a
terminal or the background, and for any session Codealong runs itself (from Macs since 0.28). A repo picked starts where new work goes in it,
which follows the place picked: where the account's place moves a session out of the main checkout
into a worktree of its own before it changes anything (a Claude Code background job, from Macs
since 0.24), it starts in the main checkout whatever work is under way there. The + beside the box attaches
photos, and an image pasted into it attaches too; they go with the prompt as they go with a reply. As you type, it finds sessions by what was said in them, and the Mac you pick suggests
where the prompt belongs when it has Jev's suggestions on, over the capsule so the keyboard never
covers them (send it to a session, open one, or start it in another worktree), and says when a
session may already be doing it.

**Improve Codealong.** The lightbulb on every screen (the list, a conversation, a PR, the Macs
sheet) takes a picture of that screen, brings the list back onto this app's own source on one of
your Macs (a checkout of [codealong-ios](https://github.com/codealong/codealong-ios) or a fork of
it, its main checkout on a connected Mac first), and asks how to improve Codealong: describe it
and start, and the session gets your words with the picture after them, as the Mac's own Improve
Codealong button sends its windows. With no Mac holding this app's source it goes to the Mac
app's, which a Codealong from October 12 or later marks.

**Write ahead.** A message shows in the conversation the moment you send it, marked sending, then
sent, so you can write the next one or move on. One that doesn't go comes back to its box.

## How it works with your Macs

You need the [Codealong Mac app](https://github.com/codealong/codealong) on each Mac you want to
see, with *Show my other devices* turned on in its Settings › Devices. That's all it takes to see
sessions and read their conversations.

To reply, approve, start or stop from your phone, turn on remote control (*Let my linked devices
act on sessions here*, in Settings › Devices) on the Mac you want to act on. It's off by default,
it's per Mac, and every request a Mac takes from another device is written to its
`~/Library/Logs/Codealong/devices.log`.

The phone doesn't keep a board of its own. Each Mac works out its sessions' status and what
they're waiting on, and sends the phone a feed of them; the phone asks the Mac for what it shows
and keeps what it last saw, so it opens straight onto your sessions while it reconnects.

## Get it on your iPhone

Until it's on TestFlight, you build it on a Mac and install it on an iPhone (or an iPad) paired
with that Mac.

**You'll need:**

- A Mac with [Xcode](https://developer.apple.com/xcode/) 26 and its iOS SDK, as the selected
  developer directory: if `xcode-select -p` names the Command Line Tools rather than Xcode,
  `sudo xcode-select -s /Applications/Xcode.app`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Rust (`rustup`) with the iOS targets: `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`
- An iPhone or iPad on iOS 26, and an Apple ID added in Xcode › Settings › Accounts (a free
  Personal Team works)

**Install it:**

1. Connect your iPhone to the Mac with a cable once, and tap *Trust* on the phone.
2. On the phone, turn on Developer Mode (Settings › Privacy & Security › Developer Mode) and
   restart when it asks.
3. Clone and install, with the phone unlocked and connected:

   ```bash
   git clone https://github.com/codealong/codealong-ios.git
   cd codealong-ios
   scripts/install-device.sh
   ```

   It says which team signs the app and which phone it goes on: your team from Xcode's settings,
   and the phone connected now (`CODEALONG_TEAM_ID` and `DEVICE` pick others, and `DRY_RUN=1`
   says which without building). Then it builds the app for that phone, which registers the
   phone with your team, installs it and opens it.

   The first build takes a while, about 10 to 20 minutes on a busy Mac: cargo downloads and
   compiles the Rust core and the crate it shares with the Mac app, `codealong-peer`, from the
   Mac app's public repo ([codealong/codealong](https://github.com/codealong/codealong)). Later
   builds rebuild the core only when it changed.
4. The first time, iOS won't open the app until you trust its developer: Settings › General ›
   VPN & Device Management, then your Apple ID. Then open Codealong.

An app's ID belongs to one Apple developer team, and `dev.codealong.app` is Codealong's own, so
the app you build is `dev.codealong.app.<your team ID>` (`CODEALONG_BUNDLE_ID` sets another).
Install it with the same team each time: the phone keeps its device key for that ID, and an app
with another ID is a second app to iOS, to link with your Macs again. The simulator's build is
`dev.codealong.app`.

With a free Personal Team, Apple lets the app run for 7 days before it needs installing again:
run `scripts/install-device.sh` again. A paid developer account signs it for a year.

**Link it with your Macs.** On each Mac, open Codealong's Settings › Devices, turn on *Show my
other devices* (*Reach linked devices anywhere*, under it, stays on), and click *Make a link
code*. Scan the QR code it shows with the iPhone's camera: the app opens and asks to link. Or
enter the code in the app, under *Macs*. With Codealong running, `codealong devices code` makes
one in a terminal too, once Settings › Agents has installed the `codealong` command. You do this
once per Mac. To reply, approve or start from the phone, turn on *Let my linked devices act on
sessions here* on that Mac as well.

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
While the app is open, with a sound: a pop when a session needs you, a tink when its turn ends.
With it closed, not yet: notifications are planned, with widgets and an iPad layout.

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
scripts/build.sh                    # the core for the simulator if core/ changed, then the app
CORE=1 scripts/build.sh             # rebuild the core too
scripts/run.sh                      # install and launch on the booted simulator
LINK_CODE=cal1… scripts/run.sh      # launch with a Mac's link code, as if entered
LOOK_ONLY=1 QUEUE=<key>,<key> OPEN=<key> scripts/run.sh  # go through real sessions, marking none seen or done
(cd core && cargo test)             # the core's tests
```

On the Mac, `codealong devices code` makes a link code (the app running, with Devices and iroh
on). [CLAUDE.md](CLAUDE.md) has the working notes every change follows, and the plan is in the
Mac app's repo, `design/plans/ios.md`.

## License

Copyright 2026 Gordon L. Hempton. The code is under the [Apache License 2.0](LICENSE), as the Mac
app's is; copies carry the [NOTICE](NOTICE). The crates its Rust core is built with are under
their own licenses ([THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)). The Codealong name and logo are
trademarks, and the license doesn't grant rights to them: a fork should go by its own name and
icon.
