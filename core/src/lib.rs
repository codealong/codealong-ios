//! The phone app's core, over codealong-peer's client: it links with Macs by their link codes,
//! keeps each one's feed, and hands the Swift side what it shows as plain records, already sorted,
//! so Swift never parses JSON or re-derives a rule. What a session says (its headline, its detail)
//! was worked out by the Mac it's on and comes in its feed as is.

use std::fmt;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use codealong_peer::api::{self, params};
use codealong_peer::client::Client;
use codealong_peer::feed::{remote_key, split_remote};
use codealong_peer::model::{Harness, Lane, OriginHow, Reuse, Session, SessionLimit, Status as PeerStatus, Surface, ELSEWHERE};
use codealong_peer::{net, proto};

uniffi::setup_scaffolding!();

mod github;
mod kept;
mod md;
mod merge;
mod prs;
mod lists;
mod queue;
mod quick;
mod review;
mod sounds;
pub use lists::*;
pub use md::*;
pub use quick::*;
pub use sounds::Sound;

/// Changes reach Swift at most this often: a busy Mac sends a feed a second, and each can come
/// with several connections' worth of changes.
const COALESCE: Duration = Duration::from_millis(150);
/// Sessions that are idle or stopped show for this long after their last prompt.
const RECENT_MS: i64 = 3 * 24 * 60 * 60 * 1000;
/// Pages read back past the oldest shown, looking for the prompt behind it, before giving up, as
/// the Mac's panel does.
const LOOK_BACK: usize = 16;
/// How long a request that acts on a session waits for its Mac, as the client's own do.
const ACT_WAIT: Duration = Duration::from_secs(40);

/// What Swift implements to hear that `Core::snapshot` has something new.
#[uniffi::export(callback_interface)]
pub trait Listener: Send + Sync {
    fn changed(&self);
}

#[derive(Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum CoreError {
    Failed(String),
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CoreError::Failed(s) => f.write_str(s),
        }
    }
}

impl From<String> for CoreError {
    fn from(s: String) -> Self {
        CoreError::Failed(s)
    }
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Needs,
    Error,
    Working,
    Unread,
    Idle,
    Stopped,
}

impl From<PeerStatus> for Status {
    fn from(s: PeerStatus) -> Self {
        match s {
            PeerStatus::Needs => Status::Needs,
            PeerStatus::Error => Status::Error,
            PeerStatus::Working => Status::Working,
            PeerStatus::Unread => Status::Unread,
            PeerStatus::Idle => Status::Idle,
            PeerStatus::Stopped => Status::Stopped,
        }
    }
}

/// A Mac this phone is linked with.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct DeviceRow {
    pub key: String,
    pub short: String,
    pub name: String,
    pub online: bool,
    pub remote_control: bool,
    pub last_seen: Option<i64>,
    /// It still has this phone on its list.
    pub linked_back: bool,
    /// Its first scan hasn't finished.
    pub loading: bool,
    pub sessions: u32,
}

/// The inbox's sections, in order, as the Mac's Sessions view has them. What waits on you is the
/// first two, which send and next works through.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum InboxSection {
    NeedsYou,
    YourTurn,
    Working,
    /// Snoozed from its Mac and not running: it waits apart until its time.
    Snoozed,
    Recent,
}

/// A session, as the inbox lists it.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SessionRow {
    /// `@<device short id>:<session key>`: unique across Macs.
    pub key: String,
    pub device: String,
    pub device_name: String,
    pub device_online: bool,
    pub title: String,
    /// The Mac's own sentence for it; backtick spans are code, `{ago:<ms>}` and `{for:<ms>}` live times.
    pub headline: String,
    pub detail: Option<String>,
    pub status: Status,
    /// It says it's working but nothing has happened for a long while.
    pub stalled: bool,
    /// Working only in that it waits on a command its turn left running in the background (a
    /// CI watch, a build), which wakes it when it ends: drawn waiting, not running.
    pub waits_in_background: bool,
    pub harness: String,
    pub account: String,
    pub project: String,
    pub repo: String,
    pub worktree: String,
    /// Its worktree's id on its Mac (the worktree's path there).
    pub worktree_id: String,
    /// Its place among its Mac's pinned sessions, the first 0; none when it isn't pinned, or its
    /// Mac is from before 2026-10-13 and doesn't say.
    pub pinned: Option<u32>,
    pub branch: Option<String>,
    pub last_prompt_at: i64,
    pub last_activity: i64,
    pub status_since: Option<i64>,
    /// Codealong runs it on its Mac (over ACP): its reply streams, and a turn can be stopped.
    pub hosted: bool,
    pub section: InboxSection,
    /// When it's back, while it's snoozed and not running.
    pub snoozed_until: Option<i64>,
    pub started_at: Option<i64>,
    /// Its process is running: a prompt reaches it as its next message.
    pub live: bool,
    /// It's in an app (the Claude or Codex app), not a terminal.
    pub in_app: bool,
    /// Its reply asks you something, so what's typed next is its answer.
    pub asks: bool,
    /// Its worktree's PR, as "#12 Title", for the quick search to find it by.
    pub pr: Option<String>,
    /// Its worktree's PR, for its menu's Open PR.
    pub worktree_pr: Option<WorktreePr>,
    /// A finished turn waiting on you to read it, or a reply that asks you something: marking it
    /// seen settles it (the Mac's lanes.ts `seenable`).
    pub seenable: bool,
    /// Its turn is over and seen, and it isn't archived: it can be marked unread, Your turn again
    /// until it's seen or prompted (lanes.ts `unreadable`).
    pub unreadable: bool,
    /// Its turn is running and its Mac can stop it: what the harness's own Stop sends, or Escape
    /// in its terminal.
    pub stoppable: bool,
    /// Its turn is running and a message can reach the agent in that turn at once (Send now).
    pub steerable: bool,
    /// The model it's on, as its harness names it, where its Mac says.
    pub model: Option<String>,
    /// The reasoning effort it's on, as its harness names the level (`high`, `xhigh`), where its
    /// Mac says.
    pub effort: Option<String>,
    /// How it goes about what would need your say (Claude Code's manual, plan or bypass
    /// permissions), as its harness last wrote it, where its Mac says.
    pub mode: Option<ModeChoice>,
    /// The modes it can be switched to from here, in its agent's order: for a session Codealong
    /// runs, whose agent takes a switch; none for one that runs elsewhere.
    pub modes: Vec<ModeChoice>,
    /// The messages its harness holds until the turn it's taking ends, in the order they'll go,
    /// where its harness says what they are (the Codex app's queue), whoever sent them.
    pub queued: Vec<HeldMessage>,
    /// When the latest message its harness holds came, where its harness says only that
    /// (Antigravity's terminal UI); none when it holds none.
    pub queued_at: Option<i64>,
    /// Its provider refused a message in it, or flagged it under its content policy: its Mac
    /// sends it nothing by itself by default (Settings › Automation there).
    pub flagged: bool,
    /// Its last turn was cut off partway (its terminal closed, Codealong or the Mac restarted)
    /// and nothing has been said since: what that comes to, as the Mac says it.
    pub cut_off: Option<String>,
    /// While it runs, the page that opens it in the Claude app, through its Remote Control: what
    /// you type there goes to it where it runs.
    pub remote_control: Option<String>,
    /// Its harness can go on from before a prompt of yours, as a copy (Edit from here): Claude
    /// Code, Codex and OpenCode can, as the Mac's harness.ts `EDITS` has it.
    pub edits: bool,
    /// It can be asked on the side, by a throwaway copy of its conversation on its Mac (`Conversation::ask_side`):
    /// Claude Code and Codex can, as the Mac's slash.ts `side` has it.
    pub sides: bool,
    /// The name you gave it, where its harness keeps one.
    pub name: Option<String>,
    /// The session it came from, when its harness or Codealong wrote that down.
    pub origin: Option<SessionOrigin>,
    /// Its last turn ended on its account's usage limit and nothing has been said since: what that
    /// comes to, in a sentence or two, with `{in:<ms>}` for when it lifts.
    pub limit: Option<String>,
    /// Its last turn ended on an error from its API, a lost connection included, and nothing has
    /// gone on since: what that comes to, and Try again (`api_error_note`).
    pub api_error: Option<ApiErrorNote>,
    /// Quiet, from its Mac: a turn it ends doesn't wait on you, and it comes to you only when it
    /// needs you (its Mac has already left its turns out of Your turn).
    pub quiet: bool,
    /// A helper or a headless run that doesn't need you: started by another session's agent to
    /// help it, an automatic review of a PR, or a `claude -p` or `codex exec` run a script or an
    /// agent reads itself. It stays out of the inbox's lists and what waits on you, as it stays off
    /// the Mac's bar (`Session::unattended`), and is found by searching. A headless run whose
    /// session isn't on a linked Mac's board isn't: it's listed as a session of its own, as the
    /// Mac's Sessions view lists it.
    pub unattended: bool,
    /// A run of its harness that nobody is at (`claude -p`, `codex exec`): the Mac counts it on the
    /// row of the session that ran it (its `origin`) rather than listing it.
    pub headless: bool,
    /// The headless runs this session's commands started that are on its Mac's board, and how
    /// many of them are at work, which the Mac's row shows as a chip: its `runs` there.
    pub runs: u32,
    pub runs_working: u32,
    /// Replies another session suggested for it, to send with a tap, until something is sent to
    /// it or a turn of its starts.
    pub suggestions: Option<SuggestedReplies>,
    /// The emoji or small picture beside its title, as its Mac gave it. None until its Mac has
    /// given it one, and from Macs that don't give them.
    pub emblem: Option<Emblem>,
    /// The id its harness gives it (Claude Code's session id, Codex's thread id), which its menu's
    /// Copy session ID copies, as the Mac's does. Its resume command, which the Mac's menu copies
    /// too, isn't sent to other devices: it works only on its Mac (peerfeed.rs `shareable`).
    pub id: String,
    /// It's archived on its Mac: only a search that asks for archived sessions lists it, and only
    /// a page opened from there shows it (`Core::sessions`).
    pub archived: bool,
    /// Moved to the top of what waits on you, here or from a Mac, by you or by an agent: every
    /// queue goes to it first until you take it up. None from Macs before 2026-10-29.
    pub raised: Option<Raised>,
    /// The labels you put on it, in the order they were put on, as its Mac has them
    /// (`Session::labels`). Unlike `agent_seen` or a Mac's read of a turn, they stay until you take
    /// them off. None from Macs before 2026-11-09.
    pub labels: Vec<SessionLabel>,
    /// What's said of a turn its own agent marked seen, which needs nothing from you and so is
    /// idle rather than Your turn (`Session::agent_seen`, LaneRow.tsx `AgentSeenChip`). None from
    /// Macs before 2026-10-30, which show such a turn as Your turn.
    pub agent_seen: Option<String>,
    /// The side conversation that answered last since you saw it, which its page brings up as you
    /// come to it. None from Macs before 2026-10-30.
    pub side_answer: Option<SideAnswer>,
    /// What it waits on while it works only in that it waits on a command, said at the end of its
    /// conversation where a turn's progress would be (`waits_on`).
    pub waits_on: Option<WaitsOn>,
    /// Set aside until its side conversation answers (`Session::aside`, lanes.ts `setAside`): it
    /// still needs you, but is listed with what's working, out of what waits on you, until the
    /// side conversation is done. False from Macs before 2026-11-10, which show it as needing you.
    pub aside: bool,
    /// That its work is done with nothing left for you, and why, while its turn is over
    /// (`Session::finished`, insights.ts `finishedLabel`). None from Macs before 2026-11-10.
    pub finished: Option<FinishedWords>,
    /// Your turn only to be read: a finished turn you haven't seen (`Session::waits_finished`).
    /// It comes after the turns that want something of you, in Your turn and in the queue.
    pub waits_finished: bool,
    /// Hearing a meeting now, on its Mac (`Session::listening`). False from Macs before 2026-11-10.
    pub listening: bool,
    /// It waits on you at a prompt, where what's typed would answer it: a call to allow, a
    /// question through its harness, a held message (`Session::waits_at_a_prompt`). Not one whose
    /// reply only asks you something, nor a stuck one.
    pub at_a_prompt: bool,
    /// What its status mark draws (`mark_of`), as the Mac's SessionGlyph does.
    pub mark: Mark,
    /// A snooze to offer it, until the time its last reply says the work goes on (`suggested_snooze`).
    /// None from Macs before 2026-11-11.
    pub suggested_snooze: Option<SuggestedSnooze>,
}

/// A snooze offered for a session whose last reply says its work goes on at a later time, with
/// nothing for you or it to do before then (snooze.ts `suggestedSnooze`): first in its Snooze menu
/// and on a line above its box. Only offered: nothing snoozes by itself.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct SuggestedSnooze {
    /// When the work goes on, which the snooze runs to: 9 that morning where Jev read a day, any
    /// time an agent that tagged it said.
    pub until: i64,
    /// It's offered only before this, a little ahead of `until`: a snooze any shorter isn't worth
    /// it.
    pub offered_till: i64,
    /// Who read the reply that way: "Jev’s read", or "Tagged by" the agent's session, with what it
    /// noted (insights.ts `readBy`).
    pub by: String,
}

/// A suggested snooze less than this far off isn't worth one (snooze.ts `WORTH`).
const SNOOZE_WORTH_MS: i64 = 5 * 60 * 1000;

/// The snooze to offer a session (`SuggestedSnooze`): until its read's `waits_until`, while that's
/// worth a snooze, and for none that's snoozed already or archived (snooze.ts `suggestedSnooze`).
fn suggested_snooze(s: &Session, snoozed: bool, now: i64) -> Option<SuggestedSnooze> {
    let insight = s.insight.as_ref()?;
    let until = insight.waits_until?;
    let offered_till = until - SNOOZE_WORTH_MS;
    if offered_till <= now || snoozed || s.archived {
        return None;
    }
    let read = match &insight.by {
        None => "Jev\u{2019}s read".to_string(),
        Some(_) => format!("Tagged by {}", insight.by_title.as_deref().filter(|t| !t.is_empty()).unwrap_or("an agent")),
    };
    let note = insight.note.as_deref().filter(|n| insight.by.is_some() && !n.is_empty()).map(|n| format!(": {n}")).unwrap_or_default();
    Some(SuggestedSnooze { until, offered_till, by: format!("{read}{note}") })
}

/// What a session's status mark draws, as the Mac's SessionGlyph (ui/primitives.tsx) does,
/// wherever the session shows: its status, a clock while it waits on what its turn left running
/// or on its side conversation, a recording light while it hears a meeting, and a box once it's
/// archived.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mark {
    Needs,
    Error,
    Working,
    /// Working only in that it waits: on a command or agents its turn left running, or, set
    /// aside, on its side conversation.
    Waiting,
    Unread,
    /// It says it's busy, but nothing has happened for a long while.
    Stuck,
    /// Hearing a meeting (listening.ts `hearingShows`): not while it needs you or failed.
    Hearing,
    /// Archived, and not at work, waiting on you or failing (lanes.ts `archivedShows`).
    Archived,
    /// Idle, stopped, or snoozed apart: no mark.
    Quiet,
}

/// What a session's status mark draws (`Mark`). A snoozed one waits apart, unmarked, as on the
/// Mac's list, and one set aside is drawn as it's listed: waiting, with what's working.
fn mark_of(s: &Session, status: Status, snoozed: bool, aside: bool) -> Mark {
    let hears = s.listening && !matches!(status, Status::Needs | Status::Error);
    let archived = s.archived && matches!(status, Status::Idle | Status::Stopped | Status::Unread);
    match status {
        _ if hears => Mark::Hearing,
        _ if archived => Mark::Archived,
        _ if snoozed => Mark::Quiet,
        _ if s.stalled_since.is_some() => Mark::Stuck,
        _ if aside || s.waits_in_background() => Mark::Waiting,
        Status::Needs => Mark::Needs,
        Status::Error => Mark::Error,
        Status::Working => Mark::Working,
        Status::Unread => Mark::Unread,
        Status::Idle | Status::Stopped => Mark::Quiet,
    }
}

/// That a session's work is done and nothing is left for you, as the Mac's chip says it
/// (insights.ts `finishedLabel`): Finished when something besides its last reply says so (a PR
/// of its merged, a todo of its done, its own status line), Looks finished when only the read of
/// that reply does.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FinishedWords {
    pub sure: bool,
    /// "Finished" or "Looks finished".
    pub label: String,
    /// Why, and what to do, in a sentence or two, as the Mac's chip's tooltip says it.
    pub says: String,
}

/// That a session is finished, while its turn is over (insights.ts `finishedLabel`): one sent a
/// prompt is working, and no longer finished.
fn finished_words(s: &Session, status: Status) -> Option<FinishedWords> {
    let f = s.finished.as_ref()?;
    if !matches!(status, Status::Unread | Status::Idle | Status::Stopped) {
        return None;
    }
    let why = f.why.join(", ");
    Some(if f.sure {
        FinishedWords { sure: true, label: "Finished".into(), says: format!("Its work is done and nothing is left for you: {why}. Mark it as done once you\u{2019}ve read it.") }
    } else {
        FinishedWords { sure: false, label: "Looks finished".into(), says: format!("Nothing seems left for you: {why}. Nothing else says so, so read its reply before you mark it as done.") }
    })
}

/// A command a working session waits on, as the Mac says it at the end of its conversation in the
/// working line's place (Working.tsx `Waiting`): one in a terminal (`Session::running`, from Macs
/// since 2026-11-04), which you allowed and its agent waits on, or which you ran for it yourself
/// and whose output goes to it when it ends (`RunningIn::yours`, from Macs since 2026-11-11); or one
/// its turn left running in the background (`Session::background`).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct WaitsOn {
    /// What it says first: "Running in Ghostty", "Your command in Ghostty", "Waiting on", or
    /// "Waiting on a command in the background" when its Mac couldn't read the command.
    pub lead: String,
    /// The command, on one line, to show; none when its Mac couldn't read it.
    pub command: Option<String>,
    /// The command as its Mac sent it, its lines and spacing as written, to copy: one line of it
    /// would be another command.
    pub written: Option<String>,
    /// It runs in a terminal of yours, not in the background of the session's turn.
    pub in_terminal: bool,
    /// What each of the agents its turn left running in the background is for, oldest first,
    /// where it waits on several (`Session::agents`), which the Mac's line counts and its hover
    /// names; "" left out. None for one, which its Mac's line names itself.
    pub agents: Vec<String>,
    /// Where a command you ran for it goes once it ends ("What it prints goes to claude when it
    /// ends"), said after it; none for any other.
    pub then: Option<String>,
}

/// Whether a session is taking a turn, as its Mac's feed says: working on it, not only waiting on
/// what an ended turn left running (`left_running`); stuck in one; or holding one for your answer
/// at a prompt (`waits_at_a_prompt`), not one whose ended turn's reply asks you something. A reply
/// kept as it was written goes with the turn (`Conversation::live`).
fn turn_running(s: &Session) -> bool {
    match s.status {
        // What an ended turn left running can sit still too: that's no turn (harness.rs
        // `turn_running`, lanes.ts `stuckMidTurn`).
        _ if s.stalled_since.is_some() => !s.left_running(),
        PeerStatus::Working => !s.left_running(),
        PeerStatus::Needs => s.waits_at_a_prompt(),
        _ => false,
    }
}

/// What a working session waits on (`WaitsOn`), as the Mac's SessionThread.tsx shows its
/// `Waiting` line: working and not stalled, waiting on a run in your terminal before a command in
/// the background: the agents it left running there, which the Mac's excerpt counts ("Waiting on
/// 3 background agents"), then a command. None while its turn runs.
fn waits_on(s: &Session) -> Option<WaitsOn> {
    if s.status != PeerStatus::Working || s.stalled_since.is_some() {
        return None;
    }
    let one_line = |c: &str| Some(c.split_whitespace().collect::<Vec<_>>().join(" ")).filter(|c| !c.is_empty());
    let written = |c: &str| Some(c.trim().to_string()).filter(|c| !c.is_empty());
    if let Some(run) = &s.running {
        let (lead, then) = if run.yours { (format!("Your command in {}", run.terminal), Some(format!("What it prints goes to {} when it ends", s.account))) } else { (format!("Running in {}", run.terminal), None) };
        return Some(WaitsOn { lead, command: one_line(&run.command), written: written(&run.command), in_terminal: true, agents: Vec::new(), then });
    }
    if !s.agents.is_empty() {
        let lead = s.excerpt.clone().filter(|e| !e.trim().is_empty()).unwrap_or_else(|| "Waiting on its background agents".into());
        let agents = if s.agents.len() < 2 { Vec::new() } else { s.agents.iter().map(|a| a.trim().to_string()).filter(|a| !a.is_empty()).collect() };
        return Some(WaitsOn { lead, command: None, written: None, in_terminal: false, agents, then: None });
    }
    let background = s.background.as_deref()?;
    let command = one_line(background);
    let lead = if command.is_some() { "Waiting on" } else { "Waiting on a command in the background" };
    Some(WaitsOn { lead: lead.into(), command, written: written(background), in_terminal: false, agents: Vec::new(), then: None })
}

/// A session moved to the top of what waits on you (`Session::raised`).
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct Raised {
    /// When it was moved, by the clock of its Mac.
    pub at: i64,
    /// An agent moved it, not you: it goes after every one you moved.
    pub agent: bool,
    /// Who moved it there, why and until when, as the Mac's Top chip says it (LaneRow.tsx
    /// `RaisedChip`).
    pub says: String,
}

impl From<&codealong_peer::model::Raised> for Raised {
    fn from(r: &codealong_peer::model::Raised) -> Raised {
        let by = if r.agent { format!(" by {}", r.by_title.as_deref().filter(|t| !t.is_empty()).unwrap_or("an agent")) } else { String::new() };
        let says = format!("Moved to the top{by}{}. It\u{2019}s first in every queue until you send it something or see its finished turn.", because(r.note.as_deref()));
        Raised { at: r.at, agent: r.agent, says }
    }
}

/// A label you put on a session, from the ones todos wear on its Mac (todos.json there).
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct SessionLabel {
    pub id: String,
    pub name: String,
    /// One of the Mac's eight label colors (todos.rs `LABEL_COLORS`): gray, red, pink, purple,
    /// indigo, blue, teal or green. Any other a Mac sends is gray, as it draws it.
    pub color: String,
}

/// The colors a label can have on a Mac (todos.rs `LABEL_COLORS`).
const LABEL_COLORS: [&str; 8] = ["gray", "red", "pink", "purple", "indigo", "blue", "teal", "green"];

impl From<&codealong_peer::model::Label> for SessionLabel {
    fn from(l: &codealong_peer::model::Label) -> SessionLabel {
        let color = if LABEL_COLORS.contains(&l.color.as_str()) { l.color.clone() } else { "gray".into() };
        SessionLabel { id: l.id.clone(), name: l.name.clone(), color }
    }
}

/// A label a session's menu offers, as the Mac's Labels › does (menus.ts `labelsMenu`): checked
/// where the session wears it, which takes it off; else it puts it on.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct LabelChoice {
    pub label: SessionLabel,
    pub worn: bool,
    /// What to send for it, to put it on or take it off (`Core::label`): its id on the Mac.
    pub by: String,
}

/// What a session's menu offers to put on or take off (`LabelChoice`): the labels its Mac's
/// sessions wear, since that's all of its Mac's labels its feed says, each once, in order of name.
/// Each goes by its id there (`LabelChoice::by`), which the Mac matches before any name: by name it
/// matches case only in ASCII (todos.rs `named_ids`), so two of its labels can differ only in an
/// accent's case, and one would be taken for the other. A label the Mac has that no session wears
/// is put on by its name (`Core::label`), which the Mac takes as that label rather than a new one.
pub(crate) fn label_choices(on_mac: &[&Session], key: &str) -> Vec<LabelChoice> {
    let by = |l: &codealong_peer::model::Label| if l.id.is_empty() { l.name.clone() } else { l.id.clone() };
    let worn: Vec<String> = on_mac.iter().find(|s| s.key == key).map(|s| s.labels.iter().map(by).collect()).unwrap_or_default();
    let mut seen = std::collections::HashSet::new();
    let mut choices: Vec<LabelChoice> = on_mac
        .iter()
        .flat_map(|s| s.labels.iter())
        .filter(|l| !l.name.trim().is_empty() && seen.insert(by(l)))
        .map(|l| LabelChoice { label: SessionLabel::from(l), worn: worn.contains(&by(l)), by: by(l) })
        .collect();
    choices.sort_by(|a, b| a.label.name.to_lowercase().cmp(&b.label.name.to_lowercase()).then_with(|| a.label.name.cmp(&b.label.name)));
    choices
}

/// A note ending what's said of a session, after a colon: `: the deploy waits on it`.
fn because(note: Option<&str>) -> String {
    note.map(|n| n.trim().trim_end_matches('.')).filter(|n| !n.is_empty()).map(|n| format!(": {n}")).unwrap_or_default()
}

/// What a turn its own agent marked seen says (LaneRow.tsx `AgentSeenChip`).
fn agent_seen_words(seen: &codealong_peer::model::AgentSeen) -> String {
    format!("Seen by its agent, which said this turn needs nothing from you{}. Mark as unread makes it Your turn again.", because(seen.note.as_deref()))
}

/// The order of sessions moved to the top, ahead of the rest (the Mac's board.rs `raised_order`):
/// the ones you moved, then the ones agents did, so an agent's never goes over yours, each the
/// latest first. Two that weren't moved are equal, and go by their status and wait.
pub(crate) fn raised_order(a: Option<&Raised>, b: Option<&Raised>) -> std::cmp::Ordering {
    let rank = |r: &Raised| (r.agent, std::cmp::Reverse(r.at));
    match (a, b) {
        (Some(a), Some(b)) => rank(a).cmp(&rank(b)),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    }
}

/// What a side conversation answered that you haven't seen (`Session::side_answer`).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SideAnswer {
    /// Its id, among those `Conversation::earlier_sides` lists.
    pub id: String,
    /// It's the session's open one; closed, it's read where the kept ones are.
    pub open: bool,
    /// When it finished answering, by the clock of the session's Mac.
    pub at: i64,
}

/// Whether what a side conversation answered comes up as you come to its session, as the Mac's
/// side.ts `broughtBefore` has it, and if so, when the answers put away go up to from then. Not
/// when one as late was put away on this phone before (`put_away`, kept across launches), nor when
/// it came up already since the app opened (`last`). One open when it came up and closed since
/// with nothing more asked comes up again, closed: its Mac's restart closes every open one, and it
/// no longer shows by itself. Only a closed one is kept as put away: an open one shows by itself,
/// and closing it says you've read it. A session waiting on a question it asked can't be marked
/// seen, so it keeps its answer, and one closed brought up anew at each launch kept coming back.
#[uniffi::export]
pub fn side_answer_due(answer: SideAnswer, last: Option<SideAnswer>, put_away: i64) -> Option<i64> {
    if put_away >= answer.at {
        return None;
    }
    if let Some(l) = last {
        if l.at > answer.at || (l.at == answer.at && (answer.open || !l.open)) {
            return None;
        }
    }
    Some(if answer.open { put_away } else { answer.at })
}

/// A session's worktree's PR: where its menu's Open PR goes.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct WorktreePr {
    /// Its key among the PRs listed (`PrRow::key`), whose page opens here.
    pub key: String,
    pub number: u64,
    pub url: String,
}

/// A session's emblem, as its Mac gives it (the Mac's emblems.rs, drawn by its primitives.tsx
/// `SessionEmblem`): something you can name that stands for what it works on, an emoji Jev picked
/// or a small picture an account drew, so sessions side by side read apart and one is remembered
/// as "the dinosaur".
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Emblem {
    /// The emoji, when it's one, or when it has one beside its picture: shown while the picture
    /// is on its way and when its Mac can't send it.
    pub emoji: Option<String>,
    /// The picture, where its Mac keeps it (`images/<hash>.png`), which `Core::read_image`
    /// reads from there.
    pub picture: Option<String>,
    /// What it shows, in a word or two.
    pub name: String,
}

impl From<&codealong_peer::model::Emblem> for Emblem {
    fn from(e: &codealong_peer::model::Emblem) -> Emblem {
        // The Mac names a kept picture by itself; an image is read by its path.
        Emblem { emoji: e.emoji.clone(), picture: e.picture.as_ref().map(|p| format!("images/{p}")), name: e.name.clone() }
    }
}

/// Replies suggested for a session by another session that read it (a supervisor going over what
/// waits on you), as its Mac keeps them.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SuggestedReplies {
    /// Best first.
    pub replies: Vec<String>,
    /// Why, or what to weigh, when the suggester said.
    pub note: Option<String>,
    /// The suggesting session's title, to name it by.
    pub by: Option<String>,
}

/// The session one came from: forked from it, or started by its agent.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SessionOrigin {
    /// Its key here (`@<device>:<key>`).
    pub key: String,
    /// Its title, while its Mac still lists it.
    pub title: Option<String>,
    /// A copy of its conversation going on by itself; otherwise its agent started this one.
    pub fork: bool,
}

/// A message a session's harness holds until the turn it's taking ends (`Session::queued`).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct HeldMessage {
    /// Its id in its harness's queue, which Send now names (`steer`); for one sent from here, the
    /// one its send said (`SendOutcome::queued`).
    pub id: String,
    pub at: i64,
    /// What it says, each image in it as `[Image #n]`.
    pub text: String,
    /// Its words to write again (Edit), where they can be had: none where what its harness lists
    /// only names part of it, a long paste or an image, which would be lost as it came out.
    pub words: Option<String>,
}

/// A held message's words as its harness lists it, unless that only names part of it (the Mac's
/// ahead.ts `heldWords`).
fn held_words(text: &str) -> Option<String> {
    const NAMES_WHAT_IT_HOLDS: [&str; 3] = ["[Pasted text #", "[Image #", "[...Truncated text #"];
    (!NAMES_WHAT_IT_HOLDS.iter().any(|n| text.contains(n))).then(|| text.to_string())
}

/// What taking a message out of what a session's harness holds did (`Conversation::unqueue`).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Unqueued {
    /// One sentence: what was taken out, and what went back in.
    pub message: String,
    /// The others it held that went back in after it, where its harness gives back everything it
    /// holds at once (Claude Code): each under the id it has now.
    pub requeued: Vec<Requeued>,
}

/// A held message that went back in after another was taken out.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Requeued {
    pub was: String,
    pub now: String,
}

impl From<api::Unqueued> for Unqueued {
    fn from(u: api::Unqueued) -> Unqueued {
        Unqueued { message: u.message, requeued: u.requeued.into_iter().map(|r| Requeued { was: r.was, now: r.now }).collect() }
    }
}

/// A mode a session's agent offers, or the one it's in (`SessionMode`).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ModeChoice {
    /// Its harness's id for it (`acceptEdits`), which a switch names; empty where it can't be
    /// switched to from here.
    pub id: String,
    pub label: String,
    /// What it means, in a sentence.
    pub detail: String,
    /// How much it lets the session do without asking you, as the Mac's `ModeKind` names it:
    /// `plan`, `read-only`, `asks`, `edits`, `auto`, `skips`, or `other`.
    pub kind: String,
}

impl From<&codealong_peer::model::SessionMode> for ModeChoice {
    fn from(m: &codealong_peer::model::SessionMode) -> ModeChoice {
        use codealong_peer::model::ModeKind;
        let kind = match m.kind {
            ModeKind::Plan => "plan",
            ModeKind::ReadOnly => "read-only",
            ModeKind::Asks => "asks",
            ModeKind::Edits => "edits",
            ModeKind::Auto => "auto",
            ModeKind::Skips => "skips",
            ModeKind::Other => "other",
        };
        ModeChoice { id: m.id.clone(), label: m.label.clone(), detail: m.detail.clone(), kind: kind.into() }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub devices: Vec<DeviceRow>,
    /// In the inbox's order (`inbox_order`).
    pub sessions: Vec<SessionRow>,
    /// Every PR the Macs list, once each (`quick::all_prs`).
    pub prs: Vec<quick::PrRow>,
    /// The projects those sessions are in, lined up across Macs (`Projects`): by name, with
    /// worktrees in no project last, as the Mac lists them.
    pub projects: Vec<String>,
    /// The projects of the PRs the PRs page lists (`lists::pr_sections`), for its pills.
    pub pr_projects: Vec<String>,
    /// The GitHub accounts the Macs are signed in as, and which are yours (`github::accounts`).
    pub github: Vec<github::GithubAccount>,
}

#[derive(uniffi::Object)]
pub struct Core {
    client: Client,
    /// Where conversations read lately are saved (`kept`).
    conversations: PathBuf,
    kept: kept::Kept<Conversation>,
    chimer: Mutex<sounds::Chimer>,
    /// The Macs' GitHub accounts and the ones you picked as yours (`github`).
    github: Mutex<github::Github>,
    watched: Watched,
}

/// The sessions each Mac is asked to send the replies of as they're written, by the Mac as a
/// conversation names it: each page that follows one holds a lease on it (its session's key and
/// the page's own number), so one page letting go, late or not, leaves another's, of the same
/// session too. A Mac takes the whole list each time, so a page going away asks for the rest
/// rather than none, and the lock is held while it's asked, so the last list asked for is the one
/// it has, whichever page came or went first.
type Watched = Arc<Mutex<std::collections::HashMap<String, Vec<(String, u64)>>>>;

/// Takes (`on`) or lets go of a page's lease on `key`, and says what its Mac is to send now: the
/// sessions some page still follows, each once, in the order of the leases held.
fn leased(leases: &mut Vec<(String, u64)>, key: &str, lease: u64, on: bool) -> Vec<String> {
    let held = leases.iter().any(|(k, l)| k == key && *l == lease);
    if on && !held {
        leases.push((key.to_string(), lease));
    } else if !on {
        leases.retain(|(k, l)| !(k == key && *l == lease));
    }
    let mut keys: Vec<String> = Vec::new();
    for (k, _) in leases.iter() {
        if !keys.contains(k) {
            keys.push(k.clone());
        }
    }
    keys
}

#[uniffi::export]
impl Core {
    /// `dir` is where the core keeps its links and the last feeds, `key` this phone's 32-byte
    /// device key, `name` what the Macs call it, and `tablet` whether it's an iPad.
    #[uniffi::constructor]
    pub fn new(dir: String, key: Vec<u8>, name: String, tablet: bool, listener: Box<dyn Listener>) -> Result<Arc<Core>, CoreError> {
        let bytes: [u8; 32] = key.try_into().map_err(|_| CoreError::Failed("The device key is the wrong length.".into()))?;
        let secret = iroh::SecretKey::from_bytes(&bytes);
        let wake = Arc::new((Mutex::new(false), Condvar::new()));
        let signal = wake.clone();
        let conversations = PathBuf::from(&dir).join("conversations");
        let github = Mutex::new(github::Github::load(PathBuf::from(&dir).join("github.json")));
        let client = Client::new(
            PathBuf::from(dir),
            secret,
            name,
            env!("CARGO_PKG_VERSION").to_string(),
            if tablet { proto::TABLET } else { proto::PHONE },
            Box::new(move || {
                let (lock, cv) = &*signal;
                *lock.lock().unwrap_or_else(|e| e.into_inner()) = true;
                cv.notify_one();
            }),
        );
        // Tells Swift about changes on a thread of its own, a batch at a time.
        std::thread::Builder::new()
            .name("core-changes".into())
            .spawn(move || loop {
                let (lock, cv) = &*wake;
                let mut changed = lock.lock().unwrap_or_else(|e| e.into_inner());
                while !*changed {
                    changed = cv.wait(changed).unwrap_or_else(|e| e.into_inner());
                }
                *changed = false;
                drop(changed);
                listener.changed();
                std::thread::sleep(COALESCE);
            })
            .map_err(|e| CoreError::Failed(e.to_string()))?;
        Ok(Arc::new(Core { client, conversations, kept: kept::Kept::default(), chimer: Mutex::default(), github, watched: Watched::default() }))
    }

    /// This phone's device key, as hex.
    pub fn key(&self) -> String {
        self.client.key()
    }

    /// Connects to the linked Macs and stays connected until `stop`: for while the app is open.
    pub fn start(&self) -> Result<(), CoreError> {
        self.client.start().map_err(|e| CoreError::Failed(format!("{e:#}")))
    }

    /// Disconnects, for when the app goes to the background, and saves the last feeds.
    pub fn stop(&self) {
        self.client.stop();
    }

    /// Links with the Mac whose link code this is (Settings › Devices on the Mac, or `codealong
    /// devices code`), given as the code or the link its QR code holds. Returns the Mac's name.
    pub fn link(&self, code: String) -> Result<String, CoreError> {
        Ok(self.client.link(net::code_in(&code))?)
    }

    /// A session's conversation, to page through and follow (`Conversation`): the one read
    /// lately, in memory or saved, when there is one (`kept`), so it shows at once and its Mac is
    /// asked only for what came since.
    pub fn conversation(&self, key: String) -> Result<Arc<Conversation>, CoreError> {
        let (device, own) = split_remote(&key).ok_or_else(|| CoreError::Failed("That isn't a session on one of your Macs.".into()))?;
        let continues = self.client.with_feeds(|feeds| {
            feeds
                .iter()
                .filter(|(d, _)| d.short == device || d.key == device)
                .flat_map(|(_, r)| r.lanes.iter().flat_map(|l| l.sessions.iter()))
                .find(|s| s.key == own)
                .and_then(|s| s.continues.clone())
        });
        Ok(self.kept.get(&key, continues.as_deref(), || {
            let saved = kept::file_for(&self.conversations, &key);
            let mut thread = Thread::default();
            if let Some(s) = kept::load(&saved, &key, continues.as_deref()) {
                thread = Thread { loaded: true, items: s.items, before: s.before, after: s.after, ..Thread::default() };
            }
            Arc::new(Conversation { client: self.client.clone(), device: device.to_string(), key: own.to_string(), st: Mutex::new(thread), saved, remote: key.clone(), continues: continues.clone(), watched: self.watched.clone() })
        }))
    }

    /// Reads a session's conversation ahead of its being opened (the next that waits on you), so
    /// it shows at once: what came since, when it was read before, else its newest page. Not
    /// again when it was read moments ago. Says nothing when its Mac doesn't answer: opening it
    /// reads it anyway.
    pub fn prefetch(&self, key: String) {
        let Ok(conv) = self.conversation(key) else { return };
        if !conv.fresh() {
            let _ = conv.refresh();
        }
    }

    /// Marks sessions seen on the Macs they're on, so Your turn clears everywhere.
    pub fn mark_seen(&self, keys: Vec<String>) {
        let mut by_device: std::collections::HashMap<String, Vec<String>> = std::collections::HashMap::new();
        for k in &keys {
            if let Some((device, own)) = split_remote(k) {
                by_device.entry(device.to_string()).or_default().push(own.to_string());
            }
        }
        for (device, keys) in by_device {
            let _ = self.client.mark_seen(&device, &keys);
        }
    }

    /// Marks sessions unread on the Macs they're on: each is Your turn again, everywhere, until
    /// it's seen or prompted. Macs before 2026-10-08 refuse it; the first refusal is said.
    pub fn mark_unread(&self, keys: Vec<String>) -> Result<(), CoreError> {
        self.sorted(&keys);
        each_mac(&keys, |device, keys| self.client.mark_unread(device, keys))
    }

    /// Snoozes sessions until `until` (ms), or wakes them with none, on the Macs they're on: off
    /// Needs you and Your turn everywhere until then. Macs before 2026-10-09 refuse it.
    pub fn snooze(&self, keys: Vec<String>, until: Option<i64>) -> Result<(), CoreError> {
        self.sorted(&keys);
        each_mac(&keys, |device, keys| self.client.snooze(device, keys, until))
    }

    /// Quiets sessions, or makes them heard again, on the Macs they're on: a quiet one's turns
    /// don't wait on you, and it comes to you only when it needs you. Macs before 2026-10-09
    /// refuse it.
    pub fn quiet(&self, keys: Vec<String>, quiet: bool) -> Result<(), CoreError> {
        self.sorted(&keys);
        each_mac(&keys, |device, keys| self.client.quiet(device, keys, quiet))
    }

    /// Moves sessions to the top of what waits on you, or back in line with `raised` false, on the
    /// Macs they're on: every queue there and here goes to them first until you take them up. One
    /// whose turn was over and seen waits on you again. Macs before 2026-10-29 refuse it.
    pub fn raise(&self, keys: Vec<String>, raised: bool) -> Result<(), CoreError> {
        self.sorted(&keys);
        each_mac(&keys, |device, keys| self.client.raise(device, keys, raised).map_err(|e| older_mac(e, &self.client, device, "move a session to the top from here")))
    }

    /// Pins sessions at the top of their Macs' pins, or unpins them.
    pub fn pin(&self, keys: Vec<String>, pinned: bool) -> Result<(), CoreError> {
        each_mac(&keys, |device, keys| self.client.pin(device, keys, pinned))
    }

    /// Puts labels on sessions and takes others off, on the Macs they're on, each by its id there
    /// (a menu's `LabelChoice::by`) or its name: a name a Mac's labels don't have is made one
    /// there, in its next color, as its own picker makes one. Macs before 2026-11-09 refuse it,
    /// and say so.
    pub fn label(&self, keys: Vec<String>, add: Vec<String>, remove: Vec<String>) -> Result<(), CoreError> {
        let add: Vec<String> = add.iter().map(|n| n.trim().to_string()).filter(|n| !n.is_empty()).collect();
        each_mac(&keys, |device, keys| {
            let params = serde_json::to_value(params::Label { keys: keys.to_vec(), add: add.clone(), remove: remove.clone() }).unwrap_or_default();
            self.client.ask(device, api::SESSION_LABEL, params, ACT_WAIT).map(|_| ()).map_err(|e| older_mac(e, &self.client, device, "label sessions from here"))
        })
    }

    /// The labels a session's menu offers (`label_choices`), checked where it wears them.
    pub fn label_choices(&self, key: String) -> Vec<LabelChoice> {
        let Some((device, own)) = split_remote(&key) else { return vec![] };
        self.client.with_feeds(|feeds| {
            let on_mac: Vec<&Session> = feeds.iter().filter(|(d, _)| d.short == device || d.key == device).flat_map(|(_, r)| r.lanes.iter().flat_map(|l| l.sessions.iter())).collect();
            label_choices(&on_mac, own)
        })
    }

    /// Takes away the replies suggested for a session, on its Mac, as the Mac's Dismiss does.
    pub fn dismiss_suggestions(&self, key: String) -> Result<(), CoreError> {
        let (device, own) = split_remote(&key).ok_or_else(|| CoreError::Failed("That isn't a session on one of your Macs.".into()))?;
        let params = serde_json::json!({ "key": own, "replies": [] });
        self.client.ask(device, codealong_peer::api::SESSION_SUGGEST, params, std::time::Duration::from_secs(20)).map(|_| ()).map_err(CoreError::Failed)
    }

    /// Keeps an image on `device` for a prompt to one of its sessions or a session started
    /// there, as a paste into its reply box does: how the prompt refers to it,
    /// `![name](images/<hash>.<ext>)`, which the Mac turns into the agent's way to the image as
    /// the prompt goes. Macs before 2026-10-10 can't.
    pub fn keep_image(&self, device: String, name: String, bytes: Vec<u8>) -> Result<String, CoreError> {
        self.client.keep_image(&device, &name, &bytes).map(|k| k.reference).map_err(|e| CoreError::Failed(older_mac(e, &self.client, &device, "send images from here")))
    }

    /// An image a prompt on `device` refers to (`images/<hash>.<ext>`, `PromptPart::url`): its
    /// bytes, to show.
    pub fn read_image(&self, device: String, path: String) -> Result<Vec<u8>, CoreError> {
        self.client.read_image(&device, &path).map_err(|e| CoreError::Failed(older_mac(e, &self.client, &device, "show images here")))
    }

    /// Archives a session, or brings it back, on the Mac it's on.
    pub fn archive(&self, key: String, archived: bool) -> Result<(), CoreError> {
        self.sorted(std::slice::from_ref(&key));
        let (device, own) = split_remote(&key).ok_or_else(|| CoreError::Failed("That isn't a session on one of your Macs.".into()))?;
        Ok(self.client.archive(device, own, archived)?)
    }

    pub fn unlink(&self, device: String) -> Result<(), CoreError> {
        Ok(self.client.unlink(&device)?)
    }

    /// The GitHub accounts whose PRs are listed as yours, kept here: none leaves it to the rule.
    pub fn set_github_yours(&self, picked: Vec<String>) {
        self.github.lock().unwrap_or_else(|e| e.into_inner()).pick(picked);
    }

    pub fn snapshot(&self) -> Snapshot {
        self.client.with_feeds(|feeds| {
            let now = now_ms();
            let all = all_rows(feeds);
            let mut devices = Vec::new();
            for (d, _) in feeds {
                devices.push(DeviceRow {
                    key: d.key.clone(),
                    short: d.short.clone(),
                    name: d.name.clone(),
                    online: d.online,
                    remote_control: d.remote_control,
                    last_seen: d.last_seen,
                    linked_back: d.linked_back,
                    loading: d.loading,
                    sessions: all.iter().filter(|s| s.device == d.key && in_inbox(s, now) && !s.unattended).count() as u32,
                });
            }
            let mut sessions: Vec<SessionRow> = all.into_iter().filter(|s| in_inbox(s, now)).collect();
            sessions.sort_by(inbox_order);
            let you = self.you(feeds);
            let prs = quick::all_prs(feeds, &you);
            // A project whose reviews wait on you can be narrowed to, though no session of it is
            // in the list.
            let projects = project_list(sessions.iter().map(|s| s.project.as_str()).chain(prs.iter().filter(|p| p.waits && !p.project.is_empty()).map(|p| p.project.as_str())));
            let pr_projects = lists::pr_projects(&prs, now);
            Snapshot { devices, sessions, prs, projects, pr_projects, github: you.accounts }
        })
    }

    /// The rows of the sessions `keys` that the Macs have, archived ones too: a search finds
    /// sessions the snapshot's list leaves out (older ones, ones in worktrees in no project, and
    /// archived ones when it's asked to), and a page opened from there shows one of them.
    pub fn sessions(&self, keys: Vec<String>) -> Vec<SessionRow> {
        if keys.is_empty() {
            return Vec::new();
        }
        self.client.with_feeds(|feeds| session_rows(feeds, true).into_iter().filter(|r| keys.contains(&r.key)).collect())
    }

    /// The session a link to one names (`codealong://session/<name>`, as an agent writes one), by
    /// its key here; None for any other link, and when it names none or more than one. `on` is
    /// the Mac (`DeviceRow::key`) whose conversation has the link: a key there is that Mac's own,
    /// written without the `@<short>:` it has here, so only its sessions are named, unless it's
    /// written with one. Without `on` (a link opened from elsewhere), any Mac's.
    pub fn session_named(&self, url: String, on: Option<String>) -> Option<String> {
        let name = md::session_link_name(&url)?;
        self.client.with_feeds(|feeds| {
            let short = on.and_then(|key| feeds.iter().find(|(d, _)| d.key == key).map(|(d, _)| d.short.clone()));
            session_named_in(&session_rows(feeds, true), &name, short.as_deref())
        })
    }

    /// The sound due for what came to wait on you since the last time this was asked, if any,
    /// of the kinds `on` (`sounds`): asked each time `Listener::changed` says something's new,
    /// sounds on or not, so what came while they were off isn't news later. With none on, as
    /// while the app is behind another, nothing comes due, so nothing holds back the next sound.
    pub fn sound(&self, on: Vec<Sound>) -> Option<Sound> {
        let now = now_ms();
        self.client.with_feeds(|feeds| {
            let devices: Vec<(codealong_peer::client::Device, i64)> = feeds.iter().map(|(d, r)| (d.clone(), r.generated_at)).collect();
            let rows = all_rows(feeds);
            self.chimer.lock().unwrap_or_else(|e| e.into_inner()).due(&devices, &rows, now, &on)
        })
    }
}

impl Core {
    /// Sessions sorted here just now, which coming to wait on you then is no news (`sounds`).
    fn sorted(&self, keys: &[String]) {
        self.chimer.lock().unwrap_or_else(|e| e.into_inner()).sorted(keys, now_ms());
    }

    /// Who's who on GitHub in `feeds` (`github`).
    fn you(&self, feeds: &Feeds) -> github::You {
        self.github.lock().unwrap_or_else(|e| e.into_inner()).read(feeds)
    }
}

/// Does `act` once for each Mac the sessions `keys` are on, with their keys there; says the first
/// thing that went wrong, if anything did.
fn each_mac(keys: &[String], act: impl Fn(&str, &[String]) -> std::result::Result<(), String>) -> Result<(), CoreError> {
    let mut by_device: std::collections::HashMap<String, Vec<String>> = std::collections::HashMap::new();
    for k in keys {
        if let Some((device, own)) = split_remote(k) {
            by_device.entry(device.to_string()).or_default().push(own.to_string());
        }
    }
    let mut failed = None;
    for (device, keys) in by_device {
        if let Err(why) = act(&device, &keys) {
            failed.get_or_insert(why);
        }
    }
    failed.map_or(Ok(()), |why| Err(CoreError::Failed(why)))
}

pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

type Feeds<'a> = [(codealong_peer::client::Device, &'a codealong_peer::feed::Replica)];

/// The session `name` names among `rows`, as the Mac's command names one (codealongLinks.ts
/// `sessionNamed`, cli.rs `named`): the one whose key or id it is, else the only one whose key or
/// id starts with it. One written with its Mac (`@<short>:…`) is named among every Mac's; else,
/// with `on` (a Mac's short id), among that Mac's alone, and without it among every Mac's, each
/// key as its own Mac writes it.
pub(crate) fn session_named_in(rows: &[SessionRow], name: &str, on: Option<&str>) -> Option<String> {
    if name.is_empty() {
        return None;
    }
    // A key as its own Mac writes it: without the `@<short>:` it has here.
    let own = |key: &str| -> String {
        match key.strip_prefix('@').and_then(|k| k.split_once(':')) {
            Some((_, rest)) if !name.starts_with('@') => rest.to_string(),
            _ => key.to_string(),
        }
    };
    let mine: Vec<&SessionRow> = match on {
        Some(short) if !name.starts_with('@') => rows.iter().filter(|r| r.key.starts_with(&format!("@{short}:"))).collect(),
        _ => rows.iter().collect(),
    };
    if let Some(r) = mine.iter().find(|r| own(&r.key) == name || r.id == name) {
        return Some(r.key.clone());
    }
    let mut hits = mine.iter().filter(|r| r.id.starts_with(name) || own(&r.key).starts_with(name));
    let hit = hits.next()?;
    hits.next().is_none().then(|| hit.key.clone())
}

/// Whether the inbox lists a session: what wants you or is running, what's pinned on its Mac, and
/// the rest for three days after you last prompted them. A pin keeps one however old, as the
/// Mac's Sessions view does.
pub(crate) fn in_inbox(s: &SessionRow, now: i64) -> bool {
    matches!(s.status, Status::Needs | Status::Error | Status::Working | Status::Unread) || s.pinned.is_some() || now - s.last_prompt_at <= RECENT_MS
}

/// Every session on the linked Macs once, archived ones left out, in the projects the Macs line
/// up; unsorted.
pub(crate) fn all_rows(feeds: &Feeds) -> Vec<SessionRow> {
    session_rows(feeds, false)
}

/// Every session on the linked Macs once, as `all_rows` has them, then with `every` the ones it
/// leaves out too (archived ones, and those in worktrees in no project), as the Mac's search finds
/// them: for a search, and a page opened from one. Those come after, as they are, counting no runs.
pub(crate) fn session_rows(feeds: &Feeds, every: bool) -> Vec<SessionRow> {
    let now = now_ms();
    let projects = Projects::of_feeds(feeds);
    let mut sessions = Vec::new();
    let mut unlisted = Vec::new();
    for (d, replica) in feeds {
        let titles: std::collections::HashMap<&str, &str> = replica.lanes.iter().flat_map(|l| l.sessions.iter()).map(|s| (s.key.as_str(), s.title.as_str())).collect();
        let mut seen = std::collections::HashSet::new();
        // A session shows under every lane it worked in; its own lane lists it without a
        // visitor note, so that one goes first.
        let mut all: Vec<(&Lane, &Session)> = replica.lanes.iter().flat_map(|l| l.sessions.iter().map(move |s| (l, s))).collect();
        all.sort_by_key(|(_, s)| s.visitor.is_some());
        for (lane, s) in all {
            if !seen.insert(s.key.as_str()) {
                continue;
            }
            // Worktrees in no project stay off the Mac's board unless they need you, and
            // off here unless another Mac has their repo in a project. One pinned there stays.
            let project = projects.lane(lane);
            let listed = !s.archived && !(lane.hidden && project.is_none() && !matches!(s.status, PeerStatus::Needs | PeerStatus::Error) && s.pin.is_none());
            if !listed && !every {
                continue;
            }
            let status: Status = s.status.into();
            let snoozed_until = s.snoozed_until.filter(|&t| t > now && status != Status::Working);
            let aside = s.aside.is_some() && status == Status::Needs;
            let row = SessionRow {
                key: remote_key(&d.short, &s.key),
                device: d.key.clone(),
                device_name: d.name.clone(),
                device_online: d.online,
                title: s.title.clone(),
                headline: s.headline.clone(),
                detail: s.detail.clone(),
                status,
                stalled: s.stalled_since.is_some(),
                waits_in_background: s.waits_in_background(),
                harness: s.harness.word().to_string(),
                account: s.account.clone(),
                project: project.unwrap_or_else(|| lane.project.clone()),
                repo: lane.repo.clone(),
                worktree: lane.callsign.clone(),
                worktree_id: lane.id.clone(),
                pinned: s.pin,
                branch: s.branch.clone().or_else(|| lane.branch.clone()),
                last_prompt_at: s.last_prompt_at,
                last_activity: s.last_activity,
                status_since: s.status_since,
                hosted: s.hosted,
                section: section(status, snoozed_until, aside),
                snoozed_until,
                started_at: s.started_at,
                live: s.live,
                in_app: s.surface == codealong_peer::model::Surface::App,
                asks: s.asks,
                pr: lane.pr.as_ref().map(|p| format!("#{} {}", p.number, p.title)),
                // Keyed as the PRs listed key a worktree's (quick.rs `all_prs`), so its page is found.
                worktree_pr: lane.pr.as_ref().map(|p| WorktreePr { key: quick::pr_key(&p.url, &format!("{}#{}", lane.repo_slug.as_deref().unwrap_or(&lane.repo), p.number)), number: p.number, url: p.url.clone() }),
                seenable: status == Status::Unread || s.asks,
                unreadable: !s.asks && !s.archived && matches!(status, Status::Idle | Status::Stopped),
                // Macs before 2026-09-29 don't say, and stop only the sessions Codealong runs.
                stoppable: s.stoppable || (s.hosted && status == Status::Working),
                steerable: s.steerable,
                model: s.model.clone(),
                effort: s.effort.clone(),
                mode: s.mode.as_ref().map(ModeChoice::from),
                modes: s.modes.iter().map(ModeChoice::from).collect(),
                queued: s.queued.iter().map(|m| HeldMessage { id: m.id.clone(), at: m.at, text: m.text.clone(), words: held_words(&m.text) }).collect(),
                queued_at: s.queued_at,
                flagged: s.flagged,
                cut_off: s.cut_off.filter(|_| status != Status::Working).map(|_| CUT_OFF.to_string()),
                remote_control: s.remote_control.as_deref().filter(|_| s.live).map(remote_control_url),
                edits: matches!(s.harness, Harness::Claude | Harness::Codex | Harness::Opencode),
                sides: matches!(s.harness, Harness::Claude | Harness::Codex),
                name: s.name.clone(),
                origin: s.origin.as_ref().map(|o| SessionOrigin { key: remote_key(&d.short, &o.key), title: titles.get(o.key.as_str()).map(|t| t.to_string()), fork: o.how == OriginHow::Fork }),
                limit: s.limit.as_ref().filter(|_| status != Status::Working).map(|l| limit_words(&s.account, l, now)),
                api_error: api_error_note(s, status),
                quiet: s.quiet,
                unattended: s.unattended(),
                headless: s.headless,
                runs: 0,
                runs_working: 0,
                suggestions: s.suggestions.as_ref().filter(|g| !g.replies.is_empty()).map(|g| SuggestedReplies { replies: g.replies.clone(), note: g.note.clone(), by: g.by_title.clone() }),
                emblem: s.emblem.as_ref().map(Emblem::from),
                id: s.id.clone(),
                archived: s.archived,
                raised: s.raised.as_ref().map(Raised::from),
                labels: s.labels.iter().map(SessionLabel::from).collect(),
                agent_seen: s.agent_seen.as_ref().map(agent_seen_words),
                side_answer: s.side_answer.as_ref().map(|a| SideAnswer { id: a.id.clone(), open: a.open, at: a.at }),
                waits_on: waits_on(s),
                aside,
                finished: finished_words(s, status),
                waits_finished: s.waits_finished(),
                listening: s.listening,
                at_a_prompt: s.waits_at_a_prompt(),
                mark: mark_of(s, status, snoozed_until.is_some(), aside),
                // Snoozed, working or not, as its Mac has it.
                suggested_snooze: suggested_snooze(s, s.snoozed_until.is_some_and(|t| t > now), now),
            };
            if listed { sessions.push(row) } else { unlisted.push(row) }
        }
    }
    count_runs(&mut sessions);
    sessions.extend(unlisted);
    sessions
}

/// Each headless run counted on the row of the session it came from, as the Mac's Sessions view
/// counts them (its boardLists.ts `runCounts`), and the ones whose session isn't on a linked
/// Mac's board listed as sessions of their own (its `placeHelpers`): a script in a terminal ran
/// it, its session was archived, or it ended before its Mac saw it running.
fn count_runs(rows: &mut [SessionRow]) {
    let keys: std::collections::HashSet<String> = rows.iter().map(|r| r.key.clone()).collect();
    let mut runs: std::collections::HashMap<String, (u32, u32)> = std::collections::HashMap::new();
    for r in rows.iter_mut().filter(|r| r.headless) {
        match r.origin.as_ref().map(|o| o.key.clone()).filter(|k| keys.contains(k)) {
            Some(parent) => {
                let c = runs.entry(parent).or_default();
                c.0 += 1;
                c.1 += u32::from(r.status == Status::Working);
            }
            None => r.unattended = false,
        }
    }
    for r in rows.iter_mut() {
        if let Some(&(count, working)) = runs.get(&r.key) {
            r.runs = count;
            r.runs_working = working;
        }
    }
}

/// What a cut-off turn comes to, as the Mac's session header says it (lanes.ts `cutOffWords`).
const CUT_OFF: &str = "Its last turn was cut off partway: what ran it ended (its terminal closed, Codealong or the Mac restarted, or it was killed). Resume it, or send it something, to carry on.";

/// The page that opens a session in the Claude app by its Remote Control session (`session_…`),
/// as the Mac's Open in Claude app does with `claude://code/<id>`: on the phone, the web's address
/// for it, which opens the Claude app where it's installed, and claude.ai where it isn't.
fn remote_control_url(id: &str) -> String {
    let safe: String = id.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-').collect();
    format!("https://claude.ai/code/{safe}")
}

/// That an API error ended a session's last turn and nothing has gone on since, as the Mac's
/// session header says it, with Try again beside it (lanes.ts `apiErrorWords`, menus.ts
/// `tryAgain`).
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct ApiErrorNote {
    /// What ended it, in its harness's words where it said them, and that Codealong carries it on
    /// where it does: for beside the button.
    pub says: String,
    /// The same where there's no button (this device can't act on it there), which ends telling
    /// you to send it something.
    pub says_alone: String,
    /// It couldn't reach its API (the Mac slept, the network dropped, the connection was refused),
    /// rather than the API answering with an error.
    pub lost: bool,
    /// The button: "Try again", or "Try now" where its Mac carries it on by itself once the API can
    /// be reached. None for an archived one, which the Mac offers none for.
    pub button: Option<String>,
    /// What the button sends it, as yours, as the Mac's does (menus.ts `TRY_AGAIN`).
    pub message: String,
}

/// What Try again sends a session whose turn an API error ended, as yours (menus.ts `TRY_AGAIN`):
/// it says why, whether or not the harness hands its agent the error.
const TRY_AGAIN: &str = "Your last turn ended on an API error. Try again, carrying on where you left off.";

/// What an API error that ended a session's turn comes to (`ApiErrorNote`), while it isn't
/// working (lanes.ts `endedOnApiError`): `Session::api_error` from Macs since 2026-11-11, which
/// says what went wrong, else `connection_lost`, the only one older Macs send.
fn api_error_note(s: &Session, status: Status) -> Option<ApiErrorNote> {
    if status == Status::Working || (s.api_error.is_none() && s.connection_lost.is_none()) {
        return None;
    }
    let said = s.api_error.as_ref().map(|e| e.said.trim().trim_end_matches(|c: char| c.is_whitespace() || c == '.')).filter(|w| !w.is_empty());
    let what = match said {
        Some(said) => format!("Its last turn ended on an API error: {said}."),
        None => "Its last turn ended because it couldn\u{2019}t reach its API: the Mac slept, or the network dropped.".to_string(),
    };
    let continues = s.connection_lost.as_ref().is_some_and(|l| l.continues);
    let (says, says_alone) = if continues {
        let words = format!("{what} Codealong tells it to carry on once the API can be reached again.");
        (words.clone(), words)
    } else {
        (what.clone(), format!("{what} Send it something to try again."))
    };
    Some(ApiErrorNote {
        says,
        says_alone,
        lost: s.connection_lost.is_some(),
        button: (!s.archived).then(|| if continues { "Try now" } else { "Try again" }.to_string()),
        message: TRY_AGAIN.to_string(),
    })
}

/// What a usage limit that stopped a session comes to, as the Mac's session header says it
/// (lanes.ts `limitWords`): which limit, when it lifts, and whether another account has room. A
/// move to that account is made on the Mac, which opens a terminal there.
fn limit_words(account: &str, limit: &SessionLimit, now: i64) -> String {
    let lifted = limit.resets_at.is_some_and(|t| t <= now);
    let name = match limit.meter.as_deref() {
        Some("session") => "5-hour limit".to_string(),
        Some("week") => "weekly limit".to_string(),
        Some(m) if m.starts_with("model:") => format!("weekly {} limit", &m["model:".len()..]),
        _ => "usage limit".to_string(),
    };
    let spent = if limit.spend_capped { ", with no extra usage to carry it" } else { "" };
    let then = if limit.continues { ", and Codealong tells it to carry on then" } else { "" };
    let when = match limit.resets_at {
        _ if lifted && limit.continues => " It has lifted since: Codealong tells it to carry on.".to_string(),
        _ if lifted => " It has lifted since: send it something to go on.".to_string(),
        Some(t) => format!(" It lifts {{in:{t}}}{then}."),
        None => String::new(),
    };
    let room = match &limit.move_to {
        _ if lifted => String::new(),
        Some(to) => format!(" {to} has room: move it there on its Mac to go on now."),
        None => " No other account has room.".to_string(),
    };
    format!("It stopped at {account}\u{2019}s {name}{spent}.{when}{room}")
}

/// Projects lined up across Macs, as a Mac lines another device's worktrees up with its own
/// (peers.rs, `project_here`): by repo, since a repo is the same everywhere while what each Mac
/// calls its project is its own. A worktree goes into the project a Mac has its repo in (the
/// first Mac that does, in the order they're listed); failing that, into a project of the same
/// name on any Mac, spelled as the first one spells it; failing that, it's in no project. So a
/// worktree its own Mac has in no project shows in another Mac's project of its repo.
struct Projects {
    /// Lowercase `owner/name` to project.
    by_repo: std::collections::HashMap<String, String>,
    names: Vec<String>,
}

impl Projects {
    fn new<'a>(lanes: impl IntoIterator<Item = (&'a str, Vec<String>)>) -> Projects {
        let mut by_repo = std::collections::HashMap::new();
        let mut names: Vec<String> = Vec::new();
        for (project, slugs) in lanes.into_iter().filter(|(p, _)| *p != ELSEWHERE) {
            for slug in slugs {
                by_repo.entry(slug).or_insert_with(|| project.to_string());
            }
            if !names.iter().any(|n| n.eq_ignore_ascii_case(project)) {
                names.push(project.to_string());
            }
        }
        Projects { by_repo, names }
    }

    fn of_feeds(feeds: &[(codealong_peer::client::Device, &codealong_peer::feed::Replica)]) -> Projects {
        Projects::new(feeds.iter().flat_map(|(_, r)| r.lanes.iter()).map(|l| (l.project.as_str(), slugs(l))))
    }

    /// The project a worktree shows in, or none when it's in none on any Mac.
    fn of(&self, project: &str, slugs: &[String]) -> Option<String> {
        slugs.iter().find_map(|s| self.by_repo.get(s)).or_else(|| self.names.iter().find(|n| n.eq_ignore_ascii_case(project))).cloned()
    }

    fn lane(&self, lane: &Lane) -> Option<String> {
        self.of(&lane.project, &slugs(lane))
    }
}

/// Projects by name, each once, with worktrees in no project last.
pub(crate) fn project_list<'a>(names: impl Iterator<Item = &'a str>) -> Vec<String> {
    let mut out: Vec<String> = names.map(String::from).collect();
    out.sort_by_key(|n| (n == ELSEWHERE, n.to_lowercase()));
    out.dedup();
    out
}

/// Every name a worktree's repo goes by: its remote's, and the one GitHub gives it now.
fn slugs(lane: &Lane) -> Vec<String> {
    [&lane.repo_slug, &lane.repo_slug_now].into_iter().flatten().map(|s| s.to_lowercase()).collect()
}

/// The inbox section a session goes in: a snoozed one waits apart unless it's running, as on the
/// Mac (SessionsView.tsx `snoozedApart`), and one set aside for its side conversation is listed
/// with what's working until that's done (lanes.ts `listedStatus`).
fn section(status: Status, snoozed_until: Option<i64>, aside: bool) -> InboxSection {
    match (status, snoozed_until) {
        (Status::Working, _) => InboxSection::Working,
        (_, Some(_)) => InboxSection::Snoozed,
        (Status::Needs, None) if aside => InboxSection::Working,
        (Status::Needs | Status::Error, None) => InboxSection::NeedsYou,
        (Status::Unread, None) => InboxSection::YourTurn,
        (Status::Idle | Status::Stopped, None) => InboxSection::Recent,
    }
}

/// The inbox's order, the Mac's Sessions view's (SessionsView.tsx `timeSections`): section by
/// section, the ones moved to the top first in theirs (`raised_order`), then the finished turns
/// that are only yours to read after the rest (lanes.ts `finishedLast`), then Needs you the
/// longest wait first, so a new one can't keep pushing an old one down; Your turn and Working,
/// which read as a feed, the newest status first; snoozed ones the soonest back first; the rest by
/// the one you last sent a prompt. A status's time doesn't move while it lasts, so rows hold their places,
/// and send and next goes down the list as it reads.
fn inbox_order(a: &SessionRow, b: &SessionRow) -> std::cmp::Ordering {
    let since = |s: &SessionRow| s.status_since.unwrap_or(s.last_activity);
    let rank = |s: &SessionRow| s.section as u8;
    rank(a)
        .cmp(&rank(b))
        .then_with(|| raised_order(a.raised.as_ref(), b.raised.as_ref()))
        .then_with(|| a.waits_finished.cmp(&b.waits_finished))
        .then_with(|| match a.section {
            InboxSection::NeedsYou => since(a).cmp(&since(b)),
            InboxSection::YourTurn | InboxSection::Working => since(b).cmp(&since(a)),
            InboxSection::Snoozed => a.snoozed_until.cmp(&b.snoozed_until),
            InboxSection::Recent => b.last_prompt_at.cmp(&a.last_prompt_at).then(b.last_activity.cmp(&a.last_activity)),
        })
        .then_with(|| a.key.cmp(&b.key))
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum ItemKind {
    You,
    Agent,
    Tool,
    Note,
    /// Another session's message, whole, with who sent it (`Item::from`).
    Peer,
    /// What Codealong sent the session by itself: a review handed back, a PR's news.
    Codealong,
}

/// One thing said or done in a session. A tool call carries its output once it's in: the Mac
/// records a result as a line of its own, and the conversation puts the two together.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Item {
    /// Unique in the session.
    pub id: String,
    pub at: i64,
    pub kind: ItemKind,
    /// Prose for you, the agent, notes and messages (Markdown); a one-line label for a tool call.
    pub text: String,
    /// Who sent another session's message: that session's name, where its record says.
    pub from: Option<String>,
    /// A tool call's whole input; on a prompt of yours, a command you ran in the session's shell
    /// (Claude Code's `!`), whose `output` is what it printed.
    pub input: Option<String>,
    pub output: Option<String>,
    pub failed: bool,
    /// A prompt of yours the session took back before its agent answered, so the agent never saw
    /// it.
    pub withdrawn: bool,
    /// The questions a call asks you, in place of its input, with what you answered once it's in.
    pub questions: Vec<Question>,
    /// A page on the web the call made or opened: an artifact Claude Code published.
    pub link: Option<WebLink>,
    /// The files the call handed you to look at (Claude Code's `SendUserFile`), on its Mac.
    pub files: Vec<SentFile>,
    /// What the agent said with them.
    pub caption: Option<String>,
    /// A prompt of yours that Edit from here can go back to (`Conversation::edit`), as the Mac's
    /// thread has them (SessionThread.tsx `editablePrompts`): one you wrote, not a command you
    /// ran nor one the session took back, with something of the agent's before it, which there
    /// may be above a page that doesn't begin at the session's start.
    pub editable: bool,
}

/// A question an agent asks you (Claude Code's `AskUserQuestion`), with its choices, and, once
/// answered, what you picked.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Question {
    /// Its text, which its answer is keyed by.
    pub question: String,
    /// A word or two naming it.
    pub header: Option<String>,
    pub options: Vec<QuestionChoice>,
    /// More than one choice can be picked.
    pub multi_select: bool,
    /// It was answered (in the conversation; never for one that waits on you).
    pub answered: bool,
    /// The choices picked.
    pub picked: Vec<String>,
    /// Words of your own, in place of a choice or beside them.
    pub own: Vec<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct QuestionChoice {
    pub label: String,
    pub description: Option<String>,
}

/// Your answer to one of the questions a session waits on you for: the choices picked, or your
/// own words.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct QuestionAnswer {
    pub question: String,
    pub multi_select: bool,
    pub picks: Vec<String>,
}

/// A file an agent handed you, on its session's Mac, as its line in the Mac's conversation lists it:
/// by its name and the folder it's in.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SentFile {
    pub name: String,
    /// Its folder on its Mac, `~` for the home folder there.
    pub folder: String,
}

impl SentFile {
    fn of(path: &str) -> SentFile {
        let (folder, name) = path.rsplit_once('/').unwrap_or(("", path));
        // `/Users/<you>` as `~`, as the Mac writes a home folder.
        let mut parts = folder.splitn(4, '/');
        let folder = match (parts.next(), parts.next(), parts.next(), parts.next()) {
            (Some(""), Some("Users"), Some(_), rest) => format!("~{}", rest.map(|r| format!("/{r}")).unwrap_or_default()),
            _ => folder.to_string(),
        };
        SentFile { name: name.to_string(), folder }
    }
}

/// A page on the web that a tool call made or opened.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct WebLink {
    pub url: String,
    pub title: String,
    /// What the call did with it, in a word or two: "Published · version 3".
    pub note: Option<String>,
}

/// What a session waits on you for: a tool call to allow, a plan to approve, or questions.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Pending {
    pub id: String,
    pub label: String,
    pub input: Option<String>,
    /// Why it can't be answered from here, when it can't.
    pub cannot: Option<String>,
    /// It can be allowed from now on too (`Choice::Always`).
    pub always: bool,
    /// It can't be allowed just this once: its agent offers no answer that does, so there's no
    /// Allow, only Always where `always` says so.
    pub no_once: bool,
    /// It's a plan to approve: `input` is the plan, in Markdown, to read as prose.
    pub plan: bool,
    /// Questions it asks you: answered with your picks (`answer_questions`), or declined.
    pub questions: Vec<Question>,
    /// What the session wrote with this isn't in its conversation yet, only where it runs: its
    /// harness writes it once it's answered.
    pub unwritten: bool,
    /// It's its harness asking, as the session exits, whether to keep the worktree it made for it
    /// (`Pending::exiting`): its choices are all it takes, words of your own are refused, and
    /// declining calls the exit off, leaving it at its prompt. False from Macs before 2026-11-10,
    /// which don't offer it.
    pub exiting: bool,
}

/// A question as the session asks it, with what was answered (`answers`, from the call's result)
/// sorted into the choices picked and your own words, as the Mac's QuestionList.tsx `picksOf`
/// does. Claude Code records several picks as a list, or, in older versions, as one string joined
/// with commas.
fn question_of(q: &api::Question, answers: Option<&std::collections::BTreeMap<String, Vec<String>>>) -> Question {
    let labels: std::collections::HashSet<&str> = q.options.iter().map(|o| o.label.as_str()).collect();
    let given = answers.and_then(|a| a.get(&q.question));
    let (mut picked, mut own) = (Vec::<String>::new(), Vec::<String>::new());
    for a in given.into_iter().flatten() {
        if labels.contains(a.as_str()) {
            picked.push(a.clone());
            continue;
        }
        let parts: Vec<&str> = if q.multi_select { a.split(", ").collect() } else { Vec::new() };
        let known: Vec<&str> = parts.iter().copied().filter(|p| labels.contains(p)).collect();
        if known.is_empty() {
            own.push(a.clone());
            continue;
        }
        picked.extend(known.iter().map(|p| p.to_string()));
        let rest: Vec<&str> = parts.iter().copied().filter(|p| !labels.contains(p)).collect();
        if !rest.is_empty() {
            own.push(rest.join(", "));
        }
    }
    Question {
        question: q.question.clone(),
        header: q.header.clone(),
        options: q.options.iter().map(|o| QuestionChoice { label: o.label.clone(), description: o.description.clone() }).collect(),
        multi_select: q.multi_select,
        answered: given.is_some(),
        picked,
        own,
    }
}

/// Whether the conversation's last item is the line of the call whose questions the card below
/// shows (`pending`), as the Mac's questionsBox.ts tells it: a call with no answer yet, asking the
/// same questions with the same choices. Its line then opens no copy of them, which couldn't be
/// answered, and shows the card instead. Known by what it asks, not by its id: a session can wait
/// on two calls at once (a subagent's and its own), and the card shows the one asked first where
/// the conversation's last is the latest; another's line opens its own copy as before. Not by
/// headers nor by whether a question takes several, which a background job's record doesn't say
/// (the engine's claude/registry.rs `job_questions`).
#[uniffi::export]
pub fn questions_below(last: Item, pending: Pending) -> bool {
    fn asked(questions: &[Question]) -> Vec<(&str, Vec<&str>)> {
        questions.iter().map(|q| (q.question.trim(), q.options.iter().map(|o| o.label.trim()).collect())).collect()
    }
    let waiting = last.kind == ItemKind::Tool && last.output.is_none() && !last.failed && !last.questions.iter().any(|q| q.answered);
    waiting && !pending.questions.is_empty() && asked(&last.questions) == asked(&pending.questions)
}

/// How to answer what a session waits on.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Choice {
    Allow,
    /// Allow this, and calls like it from now on.
    Always,
    Deny,
}

/// The reply a session Codealong runs is writing: what it said since its last tool call, and the
/// tool it's running.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Live {
    pub text: String,
    pub tool: Option<String>,
}

/// A session's side conversation: a throwaway copy of its conversation on its Mac, answering
/// what's asked on the side while the session carries on and never hears of it (the Mac's
/// side.rs). A session has one open at a time; closed, it's kept on its Mac to read.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SideConversation {
    /// Which of the session's it is: a question goes on in it by this (`ask_side`'s `from`).
    pub id: String,
    pub turns: Vec<SideTurn>,
    /// Its copy is answering.
    pub running: bool,
    /// Its copy is gone (it sat idle, or stopped): the next question goes to a new one, told what
    /// was said.
    pub ended: bool,
    /// Closed while its copy answered: it answers what it was asked, and is only read after.
    pub closed: bool,
}

impl From<api::Side> for SideConversation {
    fn from(s: api::Side) -> SideConversation {
        SideConversation { id: s.id, turns: s.turns.into_iter().map(SideTurn::from).collect(), running: s.running, ended: s.ended, closed: s.closed }
    }
}

/// One question on the side, and its answer.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SideTurn {
    pub question: String,
    /// The answer so far, in Markdown.
    pub answer: String,
    /// What the copy did to answer: its tool calls, a line each, in order.
    pub tools: Vec<String>,
    /// The tool it's running now, as a line.
    pub tool: Option<String>,
    pub done: bool,
    /// Why it ended without an answer, or with half of one.
    pub error: Option<String>,
    /// When it was asked.
    pub at: i64,
}

impl From<api::SideTurn> for SideTurn {
    fn from(t: api::SideTurn) -> SideTurn {
        SideTurn { question: t.question, answer: t.answer, tools: t.tools, tool: t.tool, done: t.done, error: t.error, at: t.at }
    }
}

/// The line under a side conversation's turn that hasn't its answer yet, as the Mac's side.ts
/// `turnState` says it: the turn the copy is on works, under the tool it runs and the answer as it
/// comes, with how long since it was asked, until it's answered, so a copy minutes into a slow
/// command reads as working rather than stalled; one asked after it waits its turn.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SideTurnLine {
    /// It waits for the turn before it: said plainly, with no mark or clock.
    pub waits: bool,
    pub words: String,
    /// When it was asked, for the clock beside a turn at work: none for one kept from before its
    /// Mac noted the time.
    pub since: Option<i64>,
}

/// What the line under `turn` says while its side conversation's copy answers. `current` is the
/// turn the copy is on, the first not answered. The Mac's line says it reads the conversation until
/// the copy has done or said anything, then words of its own; the phone, which has no working
/// words, says what it's at: working while it runs a tool (which has its own line above) or thinks
/// after one, writing while the answer comes.
#[uniffi::export]
pub fn side_turn_line(turn: SideTurn, current: bool) -> Option<SideTurnLine> {
    if turn.done {
        return None;
    }
    if !current {
        return Some(SideTurnLine { waits: true, words: "Waits for the answer above".into(), since: None });
    }
    let words = if turn.tool.is_some() {
        "Working…"
    } else if !turn.answer.is_empty() {
        "Writing…"
    } else if !turn.tools.is_empty() {
        "Working…"
    } else {
        "Reading the conversation…"
    };
    Some(SideTurnLine { waits: false, words: words.into(), since: (turn.at > 0).then_some(turn.at) })
}

/// A side conversation as its Mac keeps it, to read once it's closed: the latest first in the list
/// of a session's earlier ones.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SideKept {
    pub id: String,
    pub started_at: i64,
    /// When it was last asked or answered.
    pub last_at: i64,
    pub turns: Vec<SideTurn>,
    /// Closed while its copy answered, and answering still (`Conversation::side_closing`).
    pub answering: bool,
}

/// A session's conversation as far as it's been read: a page back from the newest, older pages
/// as you scroll up, and what came after as the session goes on. Each call returns the whole of
/// it, oldest first, for the list to show as is.
#[derive(uniffi::Object)]
pub struct Conversation {
    client: Client,
    device: String,
    key: String,
    st: Mutex<Thread>,
    /// Where it's saved as it's read (`kept`), and the session's key here and record then.
    saved: PathBuf,
    remote: String,
    continues: Option<String>,
    watched: Watched,
}

#[derive(Default)]
struct Thread {
    loaded: bool,
    items: Vec<api::Item>,
    before: Option<u64>,
    after: u64,
    /// Pages read back looking for the prompt behind the oldest shown, by the place each was asked
    /// for: scrolling up takes them from here instead of asking the Mac again.
    read_back: std::collections::HashMap<u64, api::Page>,
    /// The prompt found behind the oldest read, for the place it was looked for from.
    behind: Option<(Option<u64>, Option<Item>)>,
    /// When its Mac was last read.
    read_at: Option<std::time::Instant>,
}

impl Thread {
    /// Takes a page in: older pages go in front, newer ones after, and anything already here
    /// (a page can overlap the last) isn't taken twice.
    fn take(&mut self, page: api::Page, older: bool) {
        let have: std::collections::HashSet<(u64, u32)> = self.items.iter().map(|i| (i.cursor, i.n)).collect();
        let fresh: Vec<api::Item> = page.items.into_iter().filter(|i| !have.contains(&(i.cursor, i.n))).collect();
        if older {
            self.items.splice(0..0, fresh);
            self.before = page.before;
        } else {
            self.items.extend(fresh);
            self.after = page.after.max(self.after);
            if !self.loaded {
                self.before = page.before;
            }
        }
        self.loaded = true;
    }

    /// The items as the list shows them: each result folded into the call it answers, when that
    /// call has been read; a result whose call is further back waits for it.
    fn shown(&self) -> Vec<Item> {
        let mut results: std::collections::HashMap<&str, &api::Item> = std::collections::HashMap::new();
        for i in self.items.iter().filter(|i| i.kind == "result") {
            if let Some(id) = &i.id {
                results.insert(id.as_str(), i);
            }
        }
        // Anything above what's been read may be the agent's.
        let mut answered = self.before.is_some();
        self.items
            .iter()
            .filter_map(|i| {
                if matches!(i.kind.as_str(), "agent" | "tool") {
                    answered = true;
                }
                let editable = i.kind == "you" && answered && !i.withdrawn && i.input.is_none() && !i.text.trim().is_empty();
                let kind = match i.kind.as_str() {
                    "you" => ItemKind::You,
                    "agent" => ItemKind::Agent,
                    "tool" => ItemKind::Tool,
                    "note" => ItemKind::Note,
                    "peer" => ItemKind::Peer,
                    "codealong" => ItemKind::Codealong,
                    // A result shows with its call, and one whose call is further back waits for it.
                    "result" => return None,
                    _ => ItemKind::Note,
                };
                // A call's output is its result's; so is what a command you ran in the session's
                // shell (`!`) printed, which comes as a result of your prompt.
                let result = matches!(kind, ItemKind::Tool | ItemKind::You).then(|| i.id.as_deref().and_then(|id| results.get(id))).flatten();
                // Your answers to its questions are on the call's result.
                let answers = result.map(|r| &r.answers).filter(|a| !a.is_empty()).or(Some(&i.answers).filter(|a| !a.is_empty()));
                Some(Item {
                    id: item_id(i),
                    at: i.at,
                    kind,
                    text: i.text.clone(),
                    from: i.from.clone(),
                    input: i.input.clone(),
                    output: result.and_then(|r| r.output.clone()).or_else(|| i.output.clone()),
                    failed: i.failed || result.is_some_and(|r| r.failed),
                    withdrawn: i.withdrawn,
                    questions: i.questions.iter().map(|q| question_of(q, answers)).collect(),
                    link: i.link.as_ref().or(result.and_then(|r| r.link.as_ref())).map(|l| WebLink { url: l.url.clone(), title: l.title.clone(), note: l.note.clone() }),
                    files: i.sent.as_ref().map(|s| s.files.iter().map(|f| SentFile::of(f)).collect()).unwrap_or_default(),
                    caption: i.sent.as_ref().and_then(|s| s.caption.clone()),
                    editable,
                })
            })
            .collect()
    }
}

/// How a message sent from here went, as its Mac said.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SendOutcome {
    /// What happened, in a sentence; empty when there's nothing to say.
    pub message: String,
    /// The id its harness holds it under until the session's turn ends (the Codex app's queue):
    /// it's queued while the session's `queued` has that id.
    pub queued: Option<String>,
    /// The way in failed after it may have put it in the session (its terminal didn't confirm
    /// the typing), so it counts as sent without being sure, and `message` says where to look:
    /// sent again, the session could have it twice.
    pub uncertain: bool,
}

impl From<api::Sent> for SendOutcome {
    fn from(s: api::Sent) -> SendOutcome {
        SendOutcome { message: s.message, queued: s.queued, uncertain: s.uncertain }
    }
}

/// How a switch of a session's mode went: what happened, in a sentence, and the mode it's in now,
/// by its id, which isn't always the one asked for (an agent puts a session whose model doesn't
/// take Auto in Accept edits instead).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ModeSwitch {
    pub message: String,
    pub mode: String,
}

/// A message sent from here, by when it went (this phone's clock).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SentAt {
    pub id: String,
    pub at: i64,
}

/// A prompt a little before the send still counts as it: the Mac's clock may be behind this one's.
const SENT_SLACK_MS: i64 = 3_000;

/// Which messages sent from here the conversation shows now, as the Mac's ahead.ts `inRecord`
/// tells: oldest first, each takes the first prompt of yours (or message from another session,
/// whole or as the note Macs before 2026-10-14 sent) at or after it went that an earlier one
/// didn't take. The text isn't compared: a harness can record a message otherwise than it was
/// sent (a message from Codealong comes as one from another session).
#[uniffi::export]
pub fn sends_in_record(sends: Vec<SentAt>, items: Vec<Item>) -> Vec<String> {
    let said: Vec<&Item> = items.iter().filter(|i| matches!(i.kind, ItemKind::You | ItemKind::Peer) || (i.kind == ItemKind::Note && i.text.starts_with("From another session"))).collect();
    let mut used = vec![false; said.len()];
    let mut sends = sends;
    sends.sort_by_key(|s| s.at);
    let mut found = Vec::new();
    for s in sends {
        if let Some(j) = (0..said.len()).find(|&j| !used[j] && said[j].at >= s.at - SENT_SLACK_MS) {
            used[j] = true;
            found.push(s.id);
        }
    }
    found
}

/// An item's id, the same whichever page it was read in.
fn item_id(i: &api::Item) -> String {
    format!("{}:{}", i.cursor, i.n)
}

/// Reads back from `at` a page at a time, through `read`, for your latest prompt there.
fn look_back(mut at: Option<u64>, mut read: impl FnMut(u64) -> Result<api::Page, CoreError>) -> Result<Option<Item>, CoreError> {
    for _ in 0..LOOK_BACK {
        let Some(cursor) = at else { return Ok(None) };
        let page = read(cursor)?;
        if let Some(found) = prompt_in(&page) {
            return Ok(Some(found));
        }
        at = page.before;
    }
    Ok(None)
}

/// The latest of your prompts in a page.
fn prompt_in(page: &api::Page) -> Option<Item> {
    page.items.iter().rev().find(|i| i.kind == "you").map(|i| Item {
        id: item_id(i),
        at: i.at,
        kind: ItemKind::You,
        text: i.text.clone(),
        from: None,
        input: None,
        output: None,
        failed: false,
        withdrawn: i.withdrawn,
        questions: Vec::new(),
        link: None,
        files: Vec::new(),
        caption: None,
        editable: false,
    })
}

#[uniffi::export]
impl Conversation {
    /// The newest page, the first time; afterwards what came since.
    pub fn refresh(&self) -> Result<Vec<Item>, CoreError> {
        let (loaded, after) = {
            let st = self.st.lock().unwrap_or_else(|e| e.into_inner());
            (st.loaded, st.after)
        };
        let page = if loaded { self.client.newer(&self.device, &self.key, after)? } else { self.client.page(&self.device, &self.key, None)? };
        let mut st = self.st.lock().unwrap_or_else(|e| e.into_inner());
        let grew = !page.items.is_empty() || !loaded;
        st.take(page, false);
        st.read_at = Some(std::time::Instant::now());
        if grew {
            self.save(&st);
        }
        Ok(st.shown())
    }

    /// What's been read so far, without asking its Mac: what was kept from before shows at once.
    pub fn kept(&self) -> Vec<Item> {
        let st = self.st.lock().unwrap_or_else(|e| e.into_inner());
        if st.loaded { st.shown() } else { Vec::new() }
    }

    /// The page before the oldest read so far.
    pub fn older(&self) -> Result<Vec<Item>, CoreError> {
        let before = self.st.lock().unwrap_or_else(|e| e.into_inner()).before;
        let Some(before) = before else { return Ok(self.st.lock().unwrap_or_else(|e| e.into_inner()).shown()) };
        let kept = self.st.lock().unwrap_or_else(|e| e.into_inner()).read_back.remove(&before);
        let page = match kept {
            Some(page) => page,
            None => self.client.page(&self.device, &self.key, Some(before))?,
        };
        let mut st = self.st.lock().unwrap_or_else(|e| e.into_inner());
        st.take(page, true);
        self.save(&st);
        Ok(st.shown())
    }

    /// Your prompt behind the oldest item read so far, when what's read doesn't start with one: a
    /// long turn can write more than a page, and what you asked stays pinned over its reply. Reads
    /// back a page at a time, keeping the pages for scrolling up, and gives up after `LOOK_BACK`.
    pub fn prompt_before(&self) -> Result<Option<Item>, CoreError> {
        let before = self.st.lock().unwrap_or_else(|e| e.into_inner()).before;
        // Looked for from here before: what was found then.
        if let Some((from, found)) = &self.st.lock().unwrap_or_else(|e| e.into_inner()).behind {
            if *from == before {
                return Ok(found.clone());
            }
        }
        let found = look_back(before, |at| {
            let kept = self.st.lock().unwrap_or_else(|e| e.into_inner()).read_back.get(&at).cloned();
            let page = match kept {
                Some(page) => page,
                None => self.client.page(&self.device, &self.key, Some(at))?,
            };
            self.st.lock().unwrap_or_else(|e| e.into_inner()).read_back.insert(at, page.clone());
            Ok(page)
        })?;
        self.st.lock().unwrap_or_else(|e| e.into_inner()).behind = Some((before, found.clone()));
        Ok(found)
    }

    /// There's more before the oldest read so far.
    pub fn has_older(&self) -> bool {
        self.st.lock().unwrap_or_else(|e| e.into_inner()).before.is_some()
    }

    pub fn pending(&self) -> Result<Option<Pending>, CoreError> {
        Ok(self.client.pending(&self.device, &self.key)?.map(|p| Pending {
            questions: p.questions.iter().map(|q| question_of(q, None)).collect(),
            id: p.id,
            label: p.label,
            input: p.input,
            cannot: p.cannot,
            always: p.always,
            no_once: p.no_once,
            plan: p.plan,
            unwritten: p.unwritten,
            exiting: p.exiting,
        }))
    }

    /// Answers the tool call `id`, if it's still the one the session waits on.
    pub fn answer(&self, id: String, choice: Choice) -> Result<String, CoreError> {
        let answer = match choice {
            Choice::Allow => api::Answer::Allow,
            Choice::Always => api::Answer::Always,
            Choice::Deny => api::Answer::Deny,
        };
        Ok(self.client.answer(&self.device, &self.key, params::Answer { id, answer: Some(answer), ..Default::default() })?)
    }

    /// Answers the questions call `id` asks with your picks, if it's still the one the session
    /// waits on.
    pub fn answer_questions(&self, id: String, answers: Vec<QuestionAnswer>) -> Result<String, CoreError> {
        let answers = answers_json(&answers).ok_or_else(|| CoreError::Failed("Pick an answer first.".into()))?;
        Ok(self.client.answer(&self.device, &self.key, params::Answer { id, answer: Some(api::Answer::Allow), answers: Some(answers), ..Default::default() })?)
    }

    /// Denies call `id` and tells the agent what to do instead, as Claude Code's own "No, and
    /// tell Claude what to do differently" does. Macs before 2026-10-05 deny it and drop the
    /// words.
    pub fn deny_saying(&self, id: String, message: String) -> Result<String, CoreError> {
        Ok(self.client.answer(&self.device, &self.key, params::Answer { id, answer: Some(api::Answer::Deny), message: Some(message), ..Default::default() })?)
    }

    /// Asks the Mac to send this session's reply as it's written, while it's shown. Says false
    /// when the Mac doesn't know how (an older build), and the conversation then only moves as
    /// the feed says.
    /// `lease` is the page's own number: asked again (its Mac connected again), it's the same
    /// lease.
    pub fn watch(&self, lease: u64) -> bool {
        let mut watched = self.watched.lock().unwrap_or_else(|e| e.into_inner());
        let keys = leased(watched.entry(self.device.clone()).or_default(), &self.key, lease, true);
        let on = self.client.watch(&self.device, &keys);
        // Not followed after all (its Mac is away, or doesn't know how): it's asked for again as
        // its Mac connects, and isn't in what's asked for meanwhile.
        if !on {
            leased(watched.entry(self.device.clone()).or_default(), &self.key, lease, false);
        }
        on
    }

    /// No more of its reply as it's written for the page with `lease`: it's not shown there any
    /// more. The Mac goes on sending those other pages follow, of this session too.
    pub fn unwatch(&self, lease: u64) {
        let mut watched = self.watched.lock().unwrap_or_else(|e| e.into_inner());
        let keys = leased(watched.entry(self.device.clone()).or_default(), &self.key, lease, false);
        self.client.watch(&self.device, &keys);
    }

    /// The reply it's writing now, if it's taking a turn and the Mac sends it. None once its turn
    /// is over, as its Mac's feed says: a reply kept from while this page followed it ends with
    /// its turn only on the devices following it then, so one followed again after its turn
    /// ended would show it still being written.
    pub fn live(&self) -> Option<Live> {
        let s = self.client.stream(&self.device, &self.key)?;
        let busy = self.client.with_feeds(|feeds| {
            feeds.iter().filter(|(d, _)| d.key == self.device || d.short == self.device).flat_map(|(_, r)| r.lanes.iter().flat_map(|l| l.sessions.iter())).find(|x| x.key == self.key).map(turn_running)
        });
        if busy == Some(false) {
            return None;
        }
        Some(Live { text: s.text, tool: s.tool })
    }

    /// Stops the turn it's taking (one whose row says `stoppable`; needs remote control there).
    /// Says what happened.
    pub fn stop(&self) -> Result<String, CoreError> {
        Ok(self.client.cancel(&self.device, &self.key)?.unwrap_or_else(|| "Stopped.".into()))
    }

    /// Sends the session a prompt, where it runs on its Mac; with `now`, into the turn it's taking
    /// at once (one whose row says `steerable`). Says how it went.
    pub fn send(&self, text: String, now: bool) -> Result<SendOutcome, CoreError> {
        Ok(self.client.send(&self.device, &self.key, &text, now)?.into())
    }

    /// Sends a message its harness holds until the turn ends (`id`, one of its row's `queued`)
    /// into the turn it's taking now, as Steer beside a queued message in the Codex app does.
    /// Says what happened. Macs before 2026-10-20 refuse it.
    pub fn steer(&self, id: String) -> Result<String, CoreError> {
        let params = serde_json::to_value(api::params::Steer { key: self.key.clone(), id }).map_err(|e| CoreError::Failed(e.to_string()))?;
        let said = self.client.ask(&self.device, api::SESSION_STEER, params, ACT_WAIT).map_err(|e| older_mac(e, &self.client, &self.device, "send a queued message now from here"))?;
        Ok(said.as_str().map(str::to_string).unwrap_or_else(|| "Sent into the turn.".into()))
    }

    /// Takes a message its harness holds until the turn ends (`id`, one of its row's `queued`) out
    /// of what it holds, so it never goes, as the trash beside a queued message in the Codex app
    /// does. Macs before 2026-10-29 refuse it.
    pub fn unqueue(&self, id: String) -> Result<Unqueued, CoreError> {
        let params = serde_json::to_value(api::params::Steer { key: self.key.clone(), id }).map_err(|e| CoreError::Failed(e.to_string()))?;
        let said = self.client.ask(&self.device, api::SESSION_UNQUEUE, params, ACT_WAIT).map_err(|e| older_mac(e, &self.client, &self.device, "take a queued message out from here"))?;
        let done: api::Unqueued = serde_json::from_value(said).map_err(|e| CoreError::Failed(e.to_string()))?;
        Ok(done.into())
    }

    /// How a message sent to it would reach it, as its Mac says; None for one Codealong runs, and
    /// from Macs before 2026-09-30, which don't say.
    pub fn way(&self) -> Option<Way> {
        self.client.way(&self.device, &self.key).ok().flatten().map(Way::from)
    }

    /// Goes on with it where `place` says (one of its account's `resumes`), on `model` and
    /// `effort` where that place takes them, on `prompt`. Says how it went, as a send does.
    pub fn resume(&self, place: String, model: Option<String>, effort: Option<String>, prompt: String) -> Result<SendOutcome, CoreError> {
        let place = api::Place::from_word(&place).ok_or_else(|| CoreError::Failed(format!("{place} isn't a place a session can go on in.")))?;
        let takes = place_takes_model(place);
        let resume = api::ResumeIn { place, model: model.filter(|_| takes), effort: effort.filter(|_| takes) };
        Ok(self.client.resume(&self.device, &self.key, resume, &prompt)?.into())
    }

    /// Switches it to another of its account's models, for it alone: while it runs, or, in the
    /// Codex app, from its next turn. Says what happened.
    pub fn switch_model(&self, model: String) -> Result<String, CoreError> {
        Ok(self.client.switch_model(&self.device, &self.key, &model)?)
    }

    /// Switches it to another of its account's effort levels, for it alone, as `switch_model`
    /// does. Says what happened. Macs before 2026-10-14 refuse it.
    pub fn switch_effort(&self, effort: String) -> Result<String, CoreError> {
        self.client.switch_effort(&self.device, &self.key, &effort).map_err(|e| CoreError::Failed(older_mac(e, &self.client, &self.device, "switch effort from here")))
    }

    /// Switches one its Mac runs itself to another of the modes its agent offers (`id`, one of
    /// its row's `modes`), for it alone. Macs before 2026-10-14 refuse it.
    pub fn switch_mode(&self, id: String) -> Result<ModeSwitch, CoreError> {
        let switched = self.client.switch_mode(&self.device, &self.key, &id).map_err(|e| CoreError::Failed(older_mac(e, &self.client, &self.device, "switch modes from here")))?;
        Ok(ModeSwitch { message: switched.message, mode: switched.mode })
    }

    /// Its open side conversation, read from its Mac now; none when it has none. From then on its
    /// Mac tells the phone of each change to its side conversations while it's connected (`side`,
    /// `side_closing`), so it's read again after the two were apart. Macs before 2026-10-23
    /// refuse it.
    pub fn read_side(&self) -> Result<Option<SideConversation>, CoreError> {
        let side = self.client.side_get(&self.device, &self.key).map_err(|e| older_mac(e, &self.client, &self.device, "ask on the side from here"))?;
        Ok(side.filter(|s| !s.turns.is_empty()).map(SideConversation::from))
    }

    /// Its open side conversation as its Mac last said, once it's been read or asked here.
    pub fn side(&self) -> Option<SideConversation> {
        self.client.side(&self.device, &self.key).map(SideConversation::from)
    }

    /// One of its side conversations closed while its copy answered, as its Mac last said, by id.
    pub fn side_closing(&self, id: String) -> Option<SideConversation> {
        self.client.side_closing(&self.device, &id).map(SideConversation::from)
    }

    /// Asks it `text` on the side: a throwaway copy of its conversation answers on its Mac, which
    /// may do what the session may without asking, so it needs remote control there. It goes in
    /// the open side conversation, or a new one, or with `from`, in that one from before, which is
    /// the open one then. The answer comes as it's written (`side`).
    pub fn ask_side(&self, text: String, from: Option<String>) -> Result<SideConversation, CoreError> {
        let side = self.client.side_ask(&self.device, &self.key, &text, from.as_deref()).map_err(|e| older_mac(e, &self.client, &self.device, "ask on the side from here"))?;
        Ok(side.into())
    }

    /// Closes its open side conversation: a copy that's answering answers what it was asked
    /// before it ends (`side_closing`), and what was said is kept on its Mac to read.
    pub fn close_side(&self) -> Result<(), CoreError> {
        Ok(self.client.side_close(&self.device, &self.key)?)
    }

    /// Its side conversations kept on its Mac, the latest first: the open one too, as far as it's
    /// been answered.
    pub fn earlier_sides(&self) -> Result<Vec<SideKept>, CoreError> {
        let kept = self.client.side_past(&self.device, &self.key).map_err(|e| older_mac(e, &self.client, &self.device, "ask on the side from here"))?;
        Ok(kept.into_iter().map(|k| SideKept { id: k.id, started_at: k.started_at, last_at: k.last_at, turns: k.turns.into_iter().map(SideTurn::from).collect(), answering: k.answering }).collect())
    }

    /// Deletes one of its side conversations kept on its Mac, stopping it if it was closed and is
    /// still answering.
    pub fn forget_side(&self, id: String) -> Result<(), CoreError> {
        Ok(self.client.side_forget(&self.device, &self.key, &id)?)
    }

    /// Forks it from just before a prompt of yours (`item`, an item's id here), your edit of it
    /// (`prompt`) in its place: a copy of its conversation up to there goes on without a window
    /// on its Mac, and the session itself is left as it is. Macs before 2026-10-20 refuse it.
    pub fn edit(&self, item: String, prompt: String) -> Result<StartedSession, CoreError> {
        let cursor = item.split(':').next().and_then(|c| c.parse::<u64>().ok()).ok_or_else(|| CoreError::Failed("That isn't a prompt in this session.".into()))?;
        let params = serde_json::to_value(api::params::Edit { key: self.key.clone(), cursor, prompt }).map_err(|e| CoreError::Failed(e.to_string()))?;
        let said = self.client.ask(&self.device, api::SESSION_EDIT, params, ACT_WAIT).map_err(|e| older_mac(e, &self.client, &self.device, "edit a prompt from here"))?;
        let started: api::Started = serde_json::from_value(said).map_err(|e| CoreError::Failed(e.to_string()))?;
        let short = self.device.get(..10).unwrap_or(&self.device);
        Ok(StartedSession { key: started.key.map(|k| remote_key(short, &k)), message: started.message })
    }
}

impl Conversation {
    /// Saves what's been read (`kept`).
    fn save(&self, st: &Thread) {
        kept::save(&self.saved, &kept::Saved::of(&self.remote, self.continues.as_deref(), &st.items, st.before, st.after));
    }

    /// Its Mac was read moments ago: a prefetch needn't read it again.
    fn fresh(&self) -> bool {
        self.st.lock().unwrap_or_else(|e| e.into_inner()).read_at.is_some_and(|t| t.elapsed() < kept::FRESH)
    }
}

/// The questions' answers as a session takes them: each question's text to the choice picked or
/// the words written, or, where it takes several, to all of them. None when nothing's answered.
fn answers_json(answers: &[QuestionAnswer]) -> Option<serde_json::Value> {
    let mut out = serde_json::Map::new();
    for a in answers {
        let picks: Vec<&str> = a.picks.iter().map(|p| p.trim()).filter(|p| !p.is_empty()).collect();
        if picks.is_empty() {
            continue;
        }
        let v = if a.multi_select { serde_json::json!(picks) } else { serde_json::json!(picks[0]) };
        out.insert(a.question.clone(), v);
    }
    (!out.is_empty()).then_some(serde_json::Value::Object(out))
}

/// Whether a session started or going on there can be asked for a model and effort: on the
/// command line, or of Codealong's adapter. The apps choose their own.
fn place_takes_model(place: api::Place) -> bool {
    matches!(place, api::Place::Terminal | api::Place::Background | api::Place::Codealong)
}

/// How a message sent to a session would reach it, as its Mac says (the engine's send.rs
/// `way_in`).
#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum Way {
    /// Typed into its tab or pane in this terminal app.
    Typed { app: String },
    /// Pasted into its background job by Claude Code's background service.
    Background,
    /// A message from Codealong on Claude Code's socket for messages between sessions.
    Message,
    /// It isn't running: it goes on with the prompt, in a new tab of this terminal app unless
    /// you pick another place.
    Resume { app: String },
    /// A Claude app session that isn't running: the app opens it with the prompt on the clipboard.
    ClaudeApp,
    /// The Codex app starts a turn, or the thread opens with the prompt filled in.
    CodexApp,
    /// Posted to OpenCode's service.
    Opencode,
    /// Nothing takes a prompt from outside: the app comes forward with it on the clipboard.
    Antigravity,
    /// Nothing takes a prompt from outside the Cursor app: it comes forward on the chat's folder
    /// with it on the clipboard.
    Cursor,
}

impl From<api::Way> for Way {
    fn from(w: api::Way) -> Way {
        match w {
            api::Way::Typed { app } => Way::Typed { app },
            api::Way::Background => Way::Background,
            api::Way::Message => Way::Message,
            api::Way::Resume { app } => Way::Resume { app },
            api::Way::ClaudeApp => Way::ClaudeApp,
            api::Way::CodexApp => Way::CodexApp,
            api::Way::Opencode => Way::Opencode,
            api::Way::Antigravity => Way::Antigravity,
            api::Way::Cursor => Way::Cursor,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_session_pinned_in_a_worktree_in_no_project_stays_listed() {
        use codealong_peer::client::Device;
        use codealong_peer::feed::Replica;
        let mac = Device { key: "m".into(), short: "m".into(), name: "Mac".into(), online: true, since: None, last_seen: None, remote_control: true, app: String::new(), loading: false, linked_back: true };
        // A worktree in no project on any Mac is off the list unless what's in it needs you, or
        // is pinned.
        let mut lane = codealong_peer::model::Lane::new("/scratch", "Elsewhere", "scratch");
        lane.hidden = true;
        let pinned = Session { pin: Some(0), ..Session::new(Harness::Claude, "claude", "a") };
        lane.sessions = vec![pinned, Session::new(Harness::Claude, "claude", "b")];
        let replica = Replica { lanes: vec![lane], ..Replica::default() };
        let keys: Vec<String> = all_rows(&[(mac, &replica)]).into_iter().map(|r| r.key).collect();
        assert_eq!(keys, ["@m:claude:claude:a"]);
    }

    #[test]
    fn a_sessions_row_has_its_id_and_its_worktrees_pr_as_the_prs_listed_have_it() {
        use codealong_peer::client::Device;
        use codealong_peer::feed::Replica;
        let mac = Device { key: "m".into(), short: "m".into(), name: "Mac".into(), online: true, since: None, last_seen: None, remote_control: true, app: String::new(), loading: false, linked_back: true };
        let mut lane = codealong_peer::model::Lane::new("/src/app", "App", "app");
        lane.repo_slug = Some("o/app".into());
        lane.pr = Some(serde_json::from_value(serde_json::json!({"number": 7, "title": "Fix it", "url": "https://github.com/O/App/pull/7", "state": "open", "checks": {"passed": 0, "failed": 0, "pending": 0, "skipped": 0, "failing": []}, "merge": "clean", "updatedAt": 0, "mergedAt": null, "closedAt": null})).unwrap());
        lane.sessions = vec![Session::new(Harness::Claude, "claude", "6e07c149")];
        let replica = Replica { lanes: vec![lane], ..Replica::default() };
        let feeds = [(mac, &replica)];
        let rows = all_rows(&feeds);
        assert_eq!((rows[0].key.as_str(), rows[0].id.as_str()), ("@m:claude:claude:6e07c149", "6e07c149"));
        let pr = rows[0].worktree_pr.clone().unwrap();
        assert_eq!((pr.number, pr.url.as_str()), (7, "https://github.com/O/App/pull/7"));
        // Its key is the PR's among the PRs listed, so Open PR finds its page here.
        let listed = all_prs(&feeds, &crate::github::You::default());
        assert_eq!(listed.iter().map(|p| p.key.as_str()).collect::<Vec<_>>(), [pr.key.as_str()]);
    }

    /// An emoji as its Mac sent it; a picture by the path its Mac reads it from, with the emoji
    /// it has beside it.
    #[test]
    fn an_emblem_is_an_emoji_or_a_picture_read_from_its_mac() {
        let sent = |emoji: Option<&str>, picture: Option<&str>| codealong_peer::model::Emblem { emoji: emoji.map(String::from), picture: picture.map(String::from), name: "t rex".into() };
        assert_eq!(Emblem::from(&sent(Some("🦖"), None)), Emblem { emoji: Some("🦖".into()), picture: None, name: "t rex".into() });
        let drawn = Emblem::from(&sent(Some("🦖"), Some("0123456789abcdef.png")));
        assert_eq!((drawn.emoji.as_deref(), drawn.picture.as_deref()), (Some("🦖"), Some("images/0123456789abcdef.png")));
        assert_eq!(Emblem::from(&sent(None, Some("0123456789abcdef.png"))).emoji, None);
    }

    fn item(kind: &str, cursor: u64, id: Option<&str>, output: Option<&str>) -> api::Item {
        api::Item { at: cursor as i64, kind: kind.into(), text: format!("{kind} {cursor}"), from: None, id: id.map(String::from), input: None, output: output.map(String::from), failed: false, withdrawn: false, stop: false, questions: vec![], answers: Default::default(), link: None, sent: None, cursor, n: 0 }
    }

    #[test]
    fn files_an_agent_sent_are_named_with_their_folder() {
        assert_eq!(SentFile::of("/Users/me/app/shots/before.png"), SentFile { name: "before.png".into(), folder: "~/app/shots".into() });
        assert_eq!(SentFile::of("/Users/me/notes.md"), SentFile { name: "notes.md".into(), folder: "~".into() });
        assert_eq!(SentFile::of("/tmp/out.txt"), SentFile { name: "out.txt".into(), folder: "/tmp".into() });
    }

    #[test]
    fn edit_from_here_goes_back_to_your_prompts_after_the_agents_words() {
        let mut t = Thread::default();
        let mut ran = item("you", 30, None, None);
        ran.input = Some("ls".into());
        let mut taken = item("you", 50, None, None);
        taken.withdrawn = true;
        t.take(api::Page { items: vec![item("you", 10, None, None), item("agent", 20, None, None), ran, item("you", 40, None, None), taken], before: None, after: 60 }, false);
        // The first comes before anything of the agent's, one is a command you ran, and the last
        // was taken back.
        let editable: Vec<String> = t.shown().into_iter().filter(|i| i.editable).map(|i| i.id).collect();
        assert_eq!(editable, ["40:0"]);
        // A page that doesn't begin at the session's start may have the agent's words above it.
        let mut later = Thread::default();
        later.take(api::Page { items: vec![item("you", 10, None, None)], before: Some(5), after: 20 }, false);
        assert!(later.shown()[0].editable);
    }

    #[test]
    fn results_fold_into_their_calls_whichever_page_they_came_in() {
        let mut t = Thread::default();
        // The newest page has a result whose call is further back.
        t.take(api::Page { items: vec![item("result", 30, Some("c1"), Some("ok")), item("agent", 40, None, None)], before: Some(20), after: 50 }, false);
        assert_eq!(t.shown().iter().map(|i| i.kind).collect::<Vec<_>>(), [ItemKind::Agent]);
        // The page before brings the call, which then shows with its output.
        t.take(api::Page { items: vec![item("you", 10, None, None), item("tool", 20, Some("c1"), None)], before: None, after: 30 }, true);
        let shown = t.shown();
        assert_eq!(shown.iter().map(|i| i.kind).collect::<Vec<_>>(), [ItemKind::You, ItemKind::Tool, ItemKind::Agent]);
        assert_eq!(shown[1].output.as_deref(), Some("ok"));
        assert!(t.before.is_none());
        // What came since goes after, and an item read twice shows once.
        t.take(api::Page { items: vec![item("agent", 40, None, None), item("you", 60, None, None)], before: Some(40), after: 70 }, false);
        assert_eq!(t.shown().len(), 4);
        assert_eq!(t.after, 70);
    }

    #[test]
    fn questions_show_what_was_picked_and_answers_go_as_a_session_takes_them() {
        let q = api::Question {
            question: "Which?".into(),
            header: Some("Pick".into()),
            options: vec![api::Choice { label: "Red".into(), description: None }, api::Choice { label: "Blue".into(), description: Some("Calm".into()) }],
            multi_select: true,
        };
        let mut call = item("tool", 20, Some("q1"), None);
        call.questions = vec![q.clone()];
        let mut result = item("result", 30, Some("q1"), Some("ok"));
        // An older Claude Code joins several picks with commas; words of your own go beside them.
        result.answers = [("Which?".to_string(), vec!["Red, Blue, green-ish".to_string()])].into();
        result.link = Some(api::Link { url: "https://claude.ai/artifact/x".into(), title: "Dashboard".into(), note: None });
        let mut t = Thread::default();
        t.take(api::Page { items: vec![call, result], before: None, after: 40 }, false);
        let shown = t.shown();
        let asked = &shown[0].questions[0];
        assert_eq!((asked.answered, asked.picked.clone(), asked.own.clone()), (true, vec!["Red".to_string(), "Blue".into()], vec!["green-ish".to_string()]));
        assert_eq!(shown[0].link.as_ref().map(|l| l.title.as_str()), Some("Dashboard"));
        // Still waiting, nothing is answered.
        assert!(!question_of(&q, None).answered);

        let answers = |a: &[(&str, bool, &[&str])]| answers_json(&a.iter().map(|(q, m, p)| QuestionAnswer { question: q.to_string(), multi_select: *m, picks: p.iter().map(|s| s.to_string()).collect() }).collect::<Vec<_>>());
        assert_eq!(answers(&[("Which?", true, &["Red", "Blue"]), ("Why?", false, &["Because", "ignored"]), ("Skipped", false, &[" "])]), Some(serde_json::json!({ "Which?": ["Red", "Blue"], "Why?": "Because" })));
        assert_eq!(answers(&[("Which?", false, &[])]), None);
    }

    #[test]
    fn the_line_of_the_call_the_questions_card_shows_points_at_the_card() {
        let ask = |question: &str, labels: &[&str], header: Option<&str>, multi: bool| api::Question {
            question: question.into(),
            header: header.map(String::from),
            options: labels.iter().map(|l| api::Choice { label: l.to_string(), description: None }).collect(),
            multi_select: multi,
        };
        let card = |qs: &[api::Question]| Pending {
            id: "call-1".into(),
            label: "AskUserQuestion".into(),
            input: None,
            cannot: None,
            always: false,
            no_once: false,
            plan: false,
            questions: qs.iter().map(|q| question_of(q, None)).collect(),
            unwritten: false,
            exiting: false,
        };
        let line = |qs: &[api::Question], result: Option<api::Item>| {
            let mut call = item("tool", 20, Some("call-2"), None);
            call.questions = qs.to_vec();
            let mut t = Thread::default();
            t.take(api::Page { items: [Some(call), result].into_iter().flatten().collect(), before: None, after: 40 }, false);
            t.shown().pop().unwrap()
        };
        let which = ask("Which color?", &["Red", "Blue"], Some("Color"), false);
        // The same questions and choices, though the call's id isn't the card's, and its record
        // says no header nor whether it takes several, as a background job's doesn't.
        assert!(questions_below(line(&[which.clone()], None), card(&[ask(" Which color? ", &["Red ", "Blue"], None, true)])));
        // Other choices, or other questions, are another call's: its line opens its own.
        assert!(!questions_below(line(&[which.clone()], None), card(&[ask("Which color?", &["Red", "Green"], Some("Color"), false)])));
        assert!(!questions_below(line(&[which.clone()], None), card(&[which.clone(), ask("Why?", &["Because"], None, false)])));
        // Answered, or with no questions on the card, it opens to what was asked as before.
        let mut answered = item("result", 30, Some("call-2"), Some("ok"));
        answered.answers = [("Which color?".to_string(), vec!["Red".to_string()])].into();
        assert!(!questions_below(line(&[which.clone()], Some(answered)), card(&[which.clone()])));
        assert!(!questions_below(line(&[which.clone()], None), card(&[])));
        assert!(!questions_below(line(&[], None), card(&[])));
    }

    #[test]
    fn the_reply_box_says_how_a_message_gets_there() {
        let mut s = Session::new(Harness::Claude, "claude2", "abc");
        s.live = true;
        assert_eq!(placeholder(&s, Some(&Way::Typed { app: "Ghostty".into() }), None), "Send to claude2 via Ghostty");
        s.status = PeerStatus::Working;
        assert_eq!(placeholder(&s, Some(&Way::Background), None), "Send to claude2 via its background job: it takes this in as it works");
        s.asks = true;
        s.status = PeerStatus::Needs;
        assert_eq!(placeholder(&s, Some(&Way::Message), None), "Answer claude2 as a message from Codealong");
        // Folded to a line, the box says only who it goes to.
        assert_eq!(reply_to(&s), "Answer claude2");
        // Not running, it goes on where it's picked to, else in the terminal its Mac said.
        let (mut off, ghostty) = (Session::new(Harness::Claude, "claude", "def"), Way::Resume { app: "Ghostty".into() });
        assert_eq!(placeholder(&off, Some(&ghostty), None), "Send to claude: it isn\u{2019}t running, so this resumes it in Ghostty");
        assert_eq!(placeholder(&off, Some(&ghostty), Some((api::Place::Background, false))), "Send to claude: it isn\u{2019}t running, so this resumes it in the background");
        assert_eq!(placeholder(&off, Some(&ghostty), Some((api::Place::Codealong, false))), "Send to claude: it isn\u{2019}t running, so Codealong runs it from now on");
        // A Mac that doesn't say: as its state suggests.
        assert_eq!(placeholder(&off, None, None), "Send to claude: it isn\u{2019}t running, so this resumes it in a terminal");
        assert_eq!(reply_to(&off), "Send to claude");
        off.hosted = true;
        off.status = PeerStatus::Working;
        assert_eq!(placeholder(&off, None, None), "Send to claude: it takes this after its current turn");
    }

    #[test]
    fn done_with_a_session_a_mac_wont_close_says_why_its_still_open() {
        let old = done_anyway("Fix it", true, "Mini", "Codealong on this device doesn't know how to session-done yet; update it here.");
        assert_eq!((old.done, old.noted), (true, true));
        assert_eq!(old.message, "Done with \u{201c}Fix it\u{201d}: it\u{2019}s archived, but still open on Mini. Codealong there is from before it could be asked to close it: update it on Mini.");
        let off = done_anyway("Fix it", true, "Mini", "Remote control is off on Mini; turn it on there in Settings \u{203a} Devices.");
        assert!(off.message.ends_with("still open on Mini. Remote control is off on Mini; turn it on there in Settings \u{203a} Devices."), "{}", off.message);
        // One that isn't running has nothing more to close.
        assert_eq!(done_anyway("Fix it", false, "Mini", "anything"), DoneOutcome { done: true, message: "Done with \u{201c}Fix it\u{201d}: it\u{2019}s archived.".into(), noted: false });
    }

    fn sent_at(id: &str, at: i64) -> SentAt {
        SentAt { id: id.into(), at }
    }

    #[test]
    fn a_message_sent_shows_once_the_record_has_a_prompt_after_it() {
        let said = |kind: ItemKind, at: i64, text: &str| Item { id: at.to_string(), at, kind, text: text.into(), from: None, input: None, output: None, failed: false, withdrawn: false, questions: vec![], link: None, files: vec![], caption: None, editable: false };
        let items = vec![said(ItemKind::You, 1_000, "old"), said(ItemKind::Agent, 9_000, "reply"), said(ItemKind::You, 10_000, "first"), said(ItemKind::Note, 12_000, "From another session: second")];
        // A message from Codealong comes as another session's: whole from Macs since 2026-10-14,
        // as a note of its first line from those before.
        let whole = vec![said(ItemKind::Agent, 9_000, "reply"), said(ItemKind::Peer, 10_000, "Carry on.\n\nThe limit lifted."), said(ItemKind::Codealong, 11_000, "Review handed back")];
        assert_eq!(sends_in_record(vec![sent_at("a", 9_500)], whole.clone()), ["a"]);
        // What Codealong sent by itself isn't a message from here.
        assert!(sends_in_record(vec![sent_at("a", 14_000)], whole).is_empty());
        let sent = sent_at;
        // Each takes the first prompt at or after it went; the old one before them takes none.
        assert_eq!(sends_in_record(vec![sent("b", 11_000), sent("a", 10_500)], items.clone()), ["a", "b"]);
        // A third has nothing left to take.
        assert_eq!(sends_in_record(vec![sent("a", 10_000), sent("b", 10_000), sent("c", 10_000)], items.clone()), ["a", "b"]);
        // The Mac's clock a little behind this one's still counts.
        assert_eq!(sends_in_record(vec![sent("a", 12_500)], items.clone()), ["a"]);
        assert!(sends_in_record(vec![sent("a", 20_000)], items).is_empty());
    }

    #[test]
    fn a_command_you_ran_shows_what_it_printed() {
        let mut ran = item("you", 10, Some("b1"), None);
        ran.input = Some("ls".into());
        let mut t = Thread::default();
        t.take(api::Page { items: vec![ran, item("result", 20, Some("b1"), Some("a.txt"))], before: None, after: 30 }, false);
        let shown = t.shown();
        assert_eq!(shown.len(), 1);
        assert_eq!((shown[0].input.as_deref(), shown[0].output.as_deref()), (Some("ls"), Some("a.txt")));
    }

    #[test]
    fn models_are_named_as_people_say_them() {
        let listed = vec![StartModel { id: "opus".into(), label: "Opus 5.5 (1M context)".into() }];
        assert_eq!(model_name("opus".into(), listed), "Opus 5.5 1M");
        assert_eq!(model_name("claude-opus-5-5".into(), vec![]), "Opus 5.5");
        assert_eq!(model_name("claude-fable-5-1[1m]".into(), vec![]), "Fable 5.1 1M");
        assert_eq!(model_name("claude-haiku-4-5-20251001".into(), vec![]), "Haiku 4.5");
        assert_eq!(model_name("claude-sonnet-4-20250514".into(), vec![]), "Sonnet 4");
        assert_eq!(model_name("gpt-5.5".into(), vec![]), "gpt-5.5");
    }

    #[test]
    fn a_usage_limit_says_when_it_lifts_and_who_has_room() {
        let limit = SessionLimit { meter: Some("session".into()), resets_at: Some(5_000), spend_capped: false, at: 1, move_to: Some("claude2".into()), continues: false, model: None };
        assert_eq!(limit_words("claude", &limit, 1_000), "It stopped at claude\u{2019}s 5-hour limit. It lifts {in:5000}. claude2 has room: move it there on its Mac to go on now.");
        assert_eq!(limit_words("claude", &limit, 9_000), "It stopped at claude\u{2019}s 5-hour limit. It has lifted since: send it something to go on.");
        let week = SessionLimit { meter: Some("model:Opus".into()), resets_at: None, spend_capped: true, move_to: None, ..limit.clone() };
        assert_eq!(limit_words("claude", &week, 1_000), "It stopped at claude\u{2019}s weekly Opus limit, with no extra usage to carry it. No other account has room.");
        // Its Mac tells it to carry on once the limit lifts.
        let carries = SessionLimit { continues: true, ..limit };
        assert_eq!(limit_words("claude", &carries, 1_000), "It stopped at claude\u{2019}s 5-hour limit. It lifts {in:5000}, and Codealong tells it to carry on then. claude2 has room: move it there on its Mac to go on now.");
        assert_eq!(limit_words("claude", &carries, 9_000), "It stopped at claude\u{2019}s 5-hour limit. It has lifted since: Codealong tells it to carry on.");
    }

    #[test]
    fn the_prompt_behind_a_long_turn_is_read_back_for() {
        // Pages of a turn longer than one, each ending where the one before it was asked for.
        let pages: std::collections::HashMap<u64, api::Page> = [
            (40, api::Page { items: vec![item("agent", 30, None, None), item("tool", 35, None, None)], before: Some(30), after: 40 }),
            (30, api::Page { items: vec![item("you", 10, None, None), item("you", 20, None, None), item("agent", 25, None, None)], before: Some(10), after: 30 }),
            (10, api::Page { items: vec![item("you", 5, None, None)], before: None, after: 10 }),
        ]
        .into();
        let mut asked = vec![];
        let found = look_back(Some(40), |at| {
            asked.push(at);
            Ok(pages[&at].clone())
        })
        .unwrap()
        .unwrap();
        // The latest prompt in the first page that has one, and no page past it.
        assert_eq!((found.id.as_str(), found.kind), ("20:0", ItemKind::You));
        assert_eq!(asked, [40, 30]);
        // At the session's start there's nothing to read back.
        assert!(look_back(None, |_| unreachable!()).unwrap().is_none());
        // It gives up rather than read a whole long session back.
        let mut reads = 0;
        let none = look_back(Some(1000), |at| {
            reads += 1;
            Ok(api::Page { items: vec![item("agent", at, None, None)], before: Some(at - 1), after: at })
        });
        assert!(none.unwrap().is_none());
        assert_eq!(reads, LOOK_BACK);
    }
}

// ---- starting a session ----

/// A worktree on a Mac, to start a session in.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Worktree {
    /// Its id on its Mac (the worktree's path there).
    pub id: String,
    pub project: String,
    pub repo: String,
    /// Its short name: the folder's, or the branch's.
    pub name: String,
    pub branch: Option<String>,
    pub last_activity: i64,
    /// The Mac it's on (its key).
    pub device: String,
    /// It's its repo's main checkout.
    pub main: bool,
    /// A plain folder, not a git checkout: no worktree can be made from it.
    pub folder: bool,
    /// Codealong's own chats: a session started here gets a folder of its own, in no project.
    pub chat: bool,
    /// What it holds, for a worktree that takes one piece of work after another; none for one
    /// kept for a single piece of work.
    pub reuse: Option<WorktreeReuse>,
    /// Codealong's own source (the Mac's improve.rs): Improve Codealong starts its sessions here.
    /// Macs before 2026-10-12 mark none.
    pub codealong: bool,
    /// This app's own source, Codealong for iPhone (`is_ios_source`): Improve Codealong on the
    /// phone starts its sessions here before the Mac app's.
    pub codealong_ios: bool,
}

/// What a reusable worktree holds (the Mac's board.rs `reuse_of`).
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorktreeReuse {
    /// No work: new work can start here.
    Free,
    /// Work under way.
    Open,
    /// Its PR is open.
    Review,
    /// Its PR merged: new work can start once it's back on the default branch.
    Landed,
}

impl Worktree {
    /// New work can start here without joining other work: reusable, and holding none.
    pub(crate) fn takes_new_work(&self) -> bool {
        matches!(self.reuse, Some(WorktreeReuse::Free | WorktreeReuse::Landed))
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct StartPlace {
    /// As the Mac names it: `terminal`, `background`, `claude-app`, `codex-app`, `codealong`.
    pub id: String,
    pub label: String,
    /// For `background`: its harness has no background service of its own, so it runs in a
    /// terminal opened behind the Mac's windows.
    pub behind: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct StartAccount {
    pub name: String,
    pub harness: String,
    pub places: Vec<StartPlace>,
    /// Where a start from the phone goes unless you pick another (`start_place`).
    pub place: Option<String>,
    /// Why it can't start anything, when it can't.
    pub unavailable: Option<String>,
    /// The model it starts on unless you pick one.
    pub default_model: Option<String>,
    pub preferred: bool,
    /// The models a start on its command line can ask for; none when it takes none.
    pub models: Vec<StartModel>,
    /// The effort levels a start on its command line can ask for, lowest first.
    pub efforts: Vec<StartModel>,
    /// Its command line makes a new worktree for a session when asked.
    pub worktree: bool,
    /// Of `places`, where one of its sessions that isn't running can go on; empty from Macs
    /// before 2026-10-06, which resume one only in a terminal.
    pub resumes: Vec<StartPlace>,
    /// Where one of its sessions goes on from the phone unless you pick another (`start_place`).
    pub resume: Option<String>,
    /// Its running sessions that its Mac types into can be switched to another of `models`.
    pub switches_model: bool,
    /// Its running sessions that its Mac types into can be switched to another of `efforts`.
    pub switches_effort: bool,
    /// Its harness takes those switches while a turn runs, for the turn's next step (Claude
    /// Code's), where others wait for the turn to end. False from Macs before 2026-11-10.
    pub switches_mid_turn: bool,
    /// Its sessions that go on in its app (the Codex app) can be switched to another of `models`
    /// and `efforts` there, running or not, from their next turn.
    pub switches_in_app: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct StartModel {
    pub id: String,
    pub label: String,
}

/// What a Mac can start: its accounts, where each can start, and the models Claude Code can ask for.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct StartChoices {
    pub accounts: Vec<StartAccount>,
    pub models: Vec<StartModel>,
}

/// How a start went: the new session's key when the Mac chose its id, so the app can open it once
/// it's listed, and a sentence when there's something to know.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct StartedSession {
    pub key: Option<String>,
    pub message: Option<String>,
}

/// Every Mac's worktrees from its feed, most recently active first, in their projects as the
/// inbox lines them up; worktrees in no project stay off, as on the Mac's board.
pub(crate) fn all_worktrees(feeds: &Feeds) -> Vec<Worktree> {
    let projects = Projects::of_feeds(feeds);
    let mut out: Vec<Worktree> = feeds
        .iter()
        .flat_map(|(d, r)| r.lanes.iter().map(move |l| (d, l)))
        .filter_map(|(d, l)| {
            let project = projects.lane(l);
            // Codealong's chats are on the board hidden, so there's always one to start in.
            if l.hidden && project.is_none() && !l.starts_chats {
                return None;
            }
            Some(Worktree {
                id: l.id.clone(),
                project: if l.starts_chats { ELSEWHERE.to_string() } else { project.unwrap_or_else(|| l.project.clone()) },
                repo: l.repo.clone(),
                name: l.callsign.clone(),
                branch: l.branch.clone(),
                last_activity: l.last_activity,
                device: d.key.clone(),
                main: l.origin == codealong_peer::model::Origin::Main,
                folder: l.origin == codealong_peer::model::Origin::Folder,
                chat: l.starts_chats,
                reuse: l.reuse.map(|r| match r {
                    Reuse::Free => WorktreeReuse::Free,
                    Reuse::Open => WorktreeReuse::Open,
                    Reuse::Review => WorktreeReuse::Review,
                    Reuse::Landed => WorktreeReuse::Landed,
                }),
                codealong: l.codealong,
                codealong_ios: is_ios_source(l),
            })
        })
        .collect();
    out.sort_by(|a, b| b.last_activity.cmp(&a.last_activity));
    out
}

// ---- improving Codealong ----

/// Where a session that improves Codealong itself starts: Codealong's own source on one of your
/// Macs, as the Mac's Improve Codealong button starts one (its improve.rs).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ImproveTarget {
    /// The Mac (its key).
    pub device: String,
    /// The worktree's id there.
    pub worktree: String,
    /// Its project, as the list lines projects up.
    pub project: String,
}

/// A picture of the phone's screen kept on the Mac for the prompt: what it's called in the prompt
/// and how the Mac refers to it (`keep_image`'s answer, `![name](images/<hash>.<ext>)`).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ImproveShot {
    pub name: String,
    pub reference: String,
}

/// Whether a worktree is of this app's own source: its GitHub repo is named `codealong-ios`, under
/// any owner, so a fork counts. The Mac marks only its own app's source, by what's in it; this one
/// is told by its remote, which every Mac sends.
fn is_ios_source(lane: &Lane) -> bool {
    [&lane.repo_slug, &lane.repo_slug_now].into_iter().flatten().any(|slug| slug.rsplit('/').next().is_some_and(|name| name.eq_ignore_ascii_case("codealong-ios")))
}

/// A source on a connected Mac, else one on a Mac that isn't (the start says so); on either, this
/// app's own source before the Mac app's, since it's the phone being improved, and the main
/// checkout before another worktree. You can pick another worktree before it starts. None when no
/// Mac has either: none has the source, or none has this app's and they run Codealong from before
/// the Mac's mark.
pub(crate) fn improve_target_of(worktrees: &[Worktree], online: &[String]) -> Option<ImproveTarget> {
    let up = |w: &Worktree| online.iter().any(|d| *d == w.device);
    // A checkout in none of the Mac's projects lists as Elsewhere there: no place to start. The
    // first of those that rank alike is the most recently active.
    let picked = worktrees
        .iter()
        .filter(|w| (w.codealong || w.codealong_ios) && !w.chat && w.project != ELSEWHERE)
        .min_by_key(|w| (!up(w), !w.codealong_ios, !w.main))?;
    Some(ImproveTarget { device: picked.device.clone(), worktree: picked.id.clone(), project: picked.project.clone() })
}

/// The prompt a session that improves Codealong starts on, as the Mac's panel writes it
/// (improve.ts `improvePrompt`): what you wrote, then the pictures, each named for what it shows.
#[uniffi::export]
pub fn improve_prompt(text: String, shots: Vec<ImproveShot>) -> String {
    let words = text.trim();
    if shots.is_empty() {
        return words.to_string();
    }
    let lead = "Codealong’s windows as they were when this was asked:";
    let lines: Vec<String> = shots
        .iter()
        .map(|s| {
            let path = s.reference.rsplit_once("](").and_then(|(_, p)| p.strip_suffix(')')).unwrap_or(&s.reference);
            format!("![{}]({path})", s.name.replace(['[', ']', '\n'], ""))
        })
        .collect();
    if words.is_empty() {
        format!("{lead}\n{}", lines.join("\n"))
    } else {
        format!("{words}\n\n{lead}\n{}", lines.join("\n"))
    }
}

#[cfg(test)]
mod improve_tests {
    use super::*;

    fn wt(id: &str, device: &str, main: bool, codealong: bool) -> Worktree {
        Worktree { id: id.into(), project: "Codealong".into(), repo: "codealong".into(), name: id.into(), branch: None, last_activity: 0, device: device.into(), main, folder: false, chat: false, reuse: None, codealong, codealong_ios: false }
    }

    fn ios(id: &str, device: &str, main: bool) -> Worktree {
        Worktree { repo: "codealong-ios".into(), codealong_ios: true, ..wt(id, device, main, false) }
    }

    #[test]
    fn the_target_is_the_sources_main_checkout_on_a_connected_mac() {
        let all = [wt("/mini/codealong", "mini", true, true), wt("/mac/other", "mac", true, false), wt("/mac/codealong/wt", "mac", false, true), wt("/mac/codealong", "mac", true, true)];
        let on = |d: &[&str]| d.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(improve_target_of(&all, &on(&["mac"])).map(|t| t.worktree), Some("/mac/codealong".into()));
        // Without the main checkout connected, a worktree there; with no Mac connected, a main checkout anywhere.
        assert_eq!(improve_target_of(&all[..3], &on(&["mac"])).map(|t| t.worktree), Some("/mac/codealong/wt".into()));
        assert_eq!(improve_target_of(&all, &on(&[])).map(|t| (t.device, t.project)), Some(("mini".into(), "Codealong".into())));
        assert_eq!(improve_target_of(&all[1..2], &on(&["mac"])), None);
    }

    #[test]
    fn the_phones_own_source_comes_before_the_mac_apps() {
        let on = |d: &[&str]| d.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let all = [wt("/mac/codealong", "mac", true, true), ios("/mac/codealong-ios/wt", "mac", false), ios("/mini/codealong-ios", "mini", true), ios("/mac/codealong-ios", "mac", true)];
        assert_eq!(improve_target_of(&all, &on(&["mac"])).map(|t| t.worktree), Some("/mac/codealong-ios".into()));
        // Another of its worktrees before the Mac app's main checkout; a main checkout before that.
        assert_eq!(improve_target_of(&all[..3], &on(&["mac"])).map(|t| t.worktree), Some("/mac/codealong-ios/wt".into()));
        assert_eq!(improve_target_of(&all[..3], &on(&["mac", "mini"])).map(|t| t.worktree), Some("/mini/codealong-ios".into()));
        // A connected Mac's source before this app's on one that isn't.
        assert_eq!(improve_target_of(&[all[0].clone(), all[2].clone()], &on(&["mac"])).map(|t| t.worktree), Some("/mac/codealong".into()));
        assert_eq!(improve_target_of(&all[2..3], &on(&[])).map(|t| t.device), Some("mini".into()));
    }

    #[test]
    fn the_phones_source_is_told_by_its_github_name() {
        let lane = |slug: Option<&str>, now: Option<&str>| {
            let mut l = Lane::new("/src/app", "App", "app");
            l.repo_slug = slug.map(Into::into);
            l.repo_slug_now = now.map(Into::into);
            l
        };
        assert!(is_ios_source(&lane(Some("codealong/codealong-ios"), None)));
        assert!(is_ios_source(&lane(Some("someone/Codealong-iOS"), None)));
        assert!(is_ios_source(&lane(Some("old/name"), Some("codealong/codealong-ios"))));
        assert!(!is_ios_source(&lane(Some("codealong/codealong"), None)));
        assert!(!is_ios_source(&lane(Some("codealong/codealong-ios-fork"), None)));
        assert!(!is_ios_source(&lane(None, None)));
    }

    #[test]
    fn the_prompt_is_what_you_wrote_then_the_pictures() {
        let shots = vec![ImproveShot { name: "iPhone screen".into(), reference: "![image.jpg](images/abc.jpg)".into() }];
        assert_eq!(improve_prompt("  Make the list denser.  ".into(), shots.clone()), "Make the list denser.\n\nCodealong’s windows as they were when this was asked:\n![iPhone screen](images/abc.jpg)");
        assert_eq!(improve_prompt("Fix it".into(), vec![]), "Fix it");
        assert_eq!(improve_prompt("".into(), shots), "Codealong’s windows as they were when this was asked:\n![iPhone screen](images/abc.jpg)");
    }
}

/// Where a start from the phone goes unless you pick another: somewhere that needs nobody at the
/// Mac, since a locked Mac opens no terminal. Codealong itself (over ACP) first, then a background
/// service (not a terminal behind the Mac's windows, which is a terminal all the same), then
/// where the account usually starts. `among` is the places to choose from.
fn start_place(a: &api::StartAccount, among: &[api::Place]) -> Option<String> {
    first_place(a, among, [api::Place::Codealong, api::Place::Background])
}

/// Where one of its sessions goes on from the phone unless you pick another: its harness's own
/// background service first, where it stays the harness's session, to attach a terminal to later;
/// then Codealong; then as a start goes.
fn resume_place(a: &api::StartAccount) -> Option<String> {
    first_place(a, &a.resumes, [api::Place::Background, api::Place::Codealong])
}

/// The first of `order` among `among` that needs nobody at the Mac, else the account's usual
/// place, else the first.
fn first_place(a: &api::StartAccount, among: &[api::Place], order: [api::Place; 2]) -> Option<String> {
    let has = |p: api::Place| among.contains(&p);
    let behind = a.places.iter().any(|o| o.place == api::Place::Background && o.behind);
    order
        .into_iter()
        .find(|p| has(*p) && !(*p == api::Place::Background && behind))
        .or(a.chosen.filter(|p| has(*p)))
        .or_else(|| among.first().copied())
        .map(|p| p.word().to_string())
}

/// How sure a Mac's suggestion must be of a reusable worktree with work under way for new work
/// to join that work: less sure, it matched the repo more than the work (reusable.ts `JOIN_AT`).
pub(crate) const JOIN_AT: f64 = 0.5;

/// Where new work goes from the worktree `picked` (at likelihood `p`, by the ids `ranked` most
/// likely first), as the Mac's reusable.ts `newWorkIn` has it: a reusable worktree that holds no
/// work, as picked; one with work under way when the pick is sure of it and it isn't the main
/// checkout; otherwise the repo's reusable worktree that holds no work, the one ranked highest,
/// then free before landed, then the latest active; with none free, the main checkout if it's
/// reusable, then the repo's reusable one ranked highest. None when the repo has none reusable.
pub(crate) fn new_work_in<'a>(picked: &'a Worktree, p: f64, all: &'a [Worktree], ranked: &[String]) -> Option<&'a Worktree> {
    if picked.takes_new_work() || (picked.reuse.is_some() && !picked.main && p >= JOIN_AT) {
        return Some(picked);
    }
    let rank = |w: &Worktree| ranked.iter().position(|id| *id == w.id).unwrap_or(usize::MAX);
    let repo: Vec<&Worktree> = all.iter().filter(|w| w.reuse.is_some() && w.device == picked.device && w.project == picked.project && w.repo == picked.repo).collect();
    let free = repo.iter().filter(|w| w.takes_new_work()).min_by_key(|w| (rank(w), w.reuse != Some(WorktreeReuse::Free), std::cmp::Reverse(w.last_activity)));
    free.or_else(|| repo.iter().find(|w| w.main)).or_else(|| repo.iter().min_by_key(|w| (rank(w), std::cmp::Reverse(w.last_activity)))).copied()
}

/// A repo a new session can start in on a Mac, for the start bar's repo list (the Mac's quick.ts
/// `repoChoices`): a new session is new work in a repo far more often than it joins a worktree's,
/// and most worktrees are kept for the one piece of work they were made for, so the repo is
/// picked first and the worktree in it follows: `starts_in`, unless you pick another.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct StartRepo {
    pub project: String,
    pub repo: String,
    pub starts_in: Worktree,
}

/// A repo's worktrees as the start bar's worktree menu lists them (the Mac's quick.ts
/// `repoWorktrees`): first where a session starts on new work, a new worktree made from `from`,
/// the reusable ones ready for it (free before landed) and the main checkout; then the ones a new
/// session would join other work in, reusable ones with work under way and the rest, each kept
/// for one piece of work. Each list the most recently active first.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct RepoWorktrees {
    /// The checkout a new worktree is made from, as the harness makes it under the checkout it
    /// starts in: the main checkout, else the latest; none for a repo of plain folders.
    pub from: Option<Worktree>,
    pub ready: Vec<Worktree>,
    pub main: Option<Worktree>,
    pub under_way: Vec<Worktree>,
    pub others: Vec<Worktree>,
}

/// One repo's worktrees among one Mac's, most recently active first as those are.
fn repo_of<'a>(worktrees: &'a [Worktree], project: &str, repo: &str) -> Vec<&'a Worktree> {
    worktrees.iter().filter(|w| !w.chat && w.project == project && w.repo == repo).collect()
}

/// The checkout a new worktree is made from among a repo's (`RepoWorktrees::from`).
fn made_from<'a>(of: &[&'a Worktree]) -> Option<&'a Worktree> {
    of.iter().find(|w| w.main).or_else(|| of.iter().find(|w| !w.folder)).copied()
}

fn repo_worktrees(of: &[&Worktree]) -> RepoWorktrees {
    let mut ready: Vec<Worktree> = of.iter().filter(|w| !w.main && w.takes_new_work()).map(|w| (*w).clone()).collect();
    ready.sort_by_key(|w| w.reuse != Some(WorktreeReuse::Free));
    let (under_way, others) = of.iter().filter(|w| !w.main && !w.takes_new_work()).map(|w| (*w).clone()).partition(|w| w.reuse.is_some());
    RepoWorktrees { from: made_from(of).cloned(), ready, main: of.iter().find(|w| w.main).map(|w| (*w).clone()), under_way, others }
}

/// Where a session starts in a repo unless you pick its worktree (the Mac's quick.ts
/// `startLaneIn`): with a new worktree, the checkout it's made from; else where new work goes from
/// the main checkout (`new_work_in`, as the Mac's suggestions go), never joining work under way;
/// else the main checkout, else the latest worktree. `of` is the repo's, among `all`.
fn start_worktree_in<'a>(of: &[&'a Worktree], all: &'a [Worktree], new_worktree: bool) -> Option<&'a Worktree> {
    if new_worktree {
        if let Some(from) = made_from(of) {
            return Some(from);
        }
    }
    let first = of.iter().find(|w| w.main).or_else(|| of.first()).copied()?;
    Some(new_work_in(first, 0.0, all, &[]).filter(|to| to.takes_new_work() || to.main).unwrap_or(first))
}

/// The repos a new session can start in on a Mac, in `project` (empty for any), the most recently
/// active first, with where a session starts in each. The Mac's menu puts the repos of the
/// worktrees you pinned first; the phone has no pins. `worktrees` are one Mac's, most recently
/// active first.
fn start_repos(worktrees: &[Worktree], project: &str) -> Vec<StartRepo> {
    let mut out: Vec<StartRepo> = Vec::new();
    for w in worktrees.iter().filter(|w| !w.chat && (project.is_empty() || w.project == project)) {
        if out.iter().any(|r| r.project == w.project && r.repo == w.repo) {
            continue;
        }
        if let Some(at) = start_worktree_in(&repo_of(worktrees, &w.project, &w.repo), worktrees, false) {
            out.push(StartRepo { project: w.project.clone(), repo: w.repo.clone(), starts_in: at.clone() });
        }
    }
    out
}

/// The worktree new work starts in on a Mac, in `project` (empty for any), unless you pick one:
/// where it starts in the most recently active repo, as the Mac's panel picks one.
fn start_worktree(worktrees: &[Worktree], project: &str) -> Option<Worktree> {
    start_repos(worktrees, project).into_iter().next().map(|r| r.starts_in)
}

#[uniffi::export]
impl Core {
    /// A Mac's worktrees from its feed, most recently active first, in their projects as the
    /// inbox lines them up; worktrees in no project stay off, as on its board.
    pub fn worktrees(&self, device: String) -> Vec<Worktree> {
        self.client.with_feeds(|feeds| all_worktrees(feeds).into_iter().filter(|w| w.device == device).collect())
    }

    /// The worktree new work starts in on `device`, in `project` (empty for any), unless you
    /// pick another (`start_worktree`).
    pub fn start_worktree(&self, device: String, project: String) -> Option<Worktree> {
        start_worktree(&self.worktrees(device), &project)
    }

    /// The repos a new session can start in on `device`, in `project` (empty for any), with
    /// where it starts in each (`start_repos`).
    pub fn start_repos(&self, device: String, project: String) -> Vec<StartRepo> {
        start_repos(&self.worktrees(device), &project)
    }

    /// A repo's worktrees on `device` as the worktree menu lists them (`repo_worktrees`).
    pub fn repo_worktrees(&self, device: String, project: String, repo: String) -> RepoWorktrees {
        let all = self.worktrees(device);
        repo_worktrees(&repo_of(&all, &project, &repo))
    }

    /// Where a session starts in a repo on `device` unless you pick its worktree; with
    /// `new_worktree`, the checkout a new one is made from (`start_worktree_in`).
    pub fn start_worktree_in(&self, device: String, project: String, repo: String, new_worktree: bool) -> Option<Worktree> {
        let all = self.worktrees(device);
        start_worktree_in(&repo_of(&all, &project, &repo), &all, new_worktree).cloned()
    }

    /// Where a session that improves Codealong itself starts (`improve_target_of`): Codealong's
    /// own source on a connected Mac first. None when no Mac marks one.
    pub fn improve_target(&self) -> Option<ImproveTarget> {
        let online: Vec<String> = self.snapshot().devices.into_iter().filter(|d| d.online).map(|d| d.key).collect();
        self.client.with_feeds(|feeds| improve_target_of(&all_worktrees(feeds), &online))
    }

    /// What `device` can start, asked of it.
    pub fn start_choices(&self, device: String) -> Result<StartChoices, CoreError> {
        let o = self.client.start_options(&device)?;
        Ok(start_choices(o))
    }

    /// Starts a session on `device` in `worktree` (its id there), on `account`, at `place`; with
    /// `new_worktree`, its harness makes a worktree of its own for it from that one's repo.
    pub fn start_session(&self, device: String, worktree: String, account: String, place: String, prompt: String, model: Option<String>, effort: Option<String>, new_worktree: bool) -> Result<StartedSession, CoreError> {
        let place = api::Place::from_word(&place).ok_or_else(|| CoreError::Failed(format!("{place} isn't a place a session can start.")))?;
        let takes = place_takes_model(place);
        let spec = api::StartSpec { lane_id: worktree, account, place, prompt, model: model.filter(|_| takes), effort: effort.filter(|_| takes), worktree: new_worktree, todos: Vec::new(), from: None, helper: false, report: false };
        let started = self.client.start_session(&device, &spec)?;
        let short = device.get(..10).unwrap_or(&device);
        Ok(StartedSession { key: started.key.map(|k| remote_key(short, &k)), message: started.message })
    }

    /// Forks a session into a copy that goes on without a window on its Mac, on `prompt` when
    /// there's one. Macs before 2026-09-30 refuse it.
    pub fn fork(&self, key: String, prompt: String) -> Result<StartedSession, CoreError> {
        let (device, own) = split_remote(&key).ok_or_else(|| CoreError::Failed("That isn't a session on one of your Macs.".into()))?;
        let started = self.client.fork(device, own, &prompt)?;
        Ok(StartedSession { key: started.key.map(|k| remote_key(device, &k)), message: started.message })
    }

    /// Done with a session (Mark as done): it ends as far as its Mac can end it (its terminal tab
    /// closes, its background job stops) and is marked seen and archived there. Work under way
    /// holds it (`done` false) unless `stop` ends that too. A Mac that won't do it (remote control
    /// off, or a Codealong from before it) still has it marked seen and archived, as the Mac's own
    /// windows do (actions.rs `done_anyway`), and the message says why it's still open there.
    pub fn done(&self, key: String, stop: bool) -> Result<DoneOutcome, CoreError> {
        let (device, own) = split_remote(&key).ok_or_else(|| CoreError::Failed("That isn't a session on one of your Macs.".into()))?;
        let why = match self.client.done(device, own, stop) {
            Ok(d) => return Ok(DoneOutcome { done: d.done, message: d.message, noted: d.noted }),
            Err(why) => why,
        };
        self.client.mark_seen(device, &[own.to_string()]).map_err(|_| CoreError::Failed(why.clone()))?;
        self.client.archive(device, own, true).map_err(|_| CoreError::Failed(why.clone()))?;
        let (title, live, mac) = self.client.with_feeds(|feeds| {
            feeds
                .iter()
                .find(|(d, _)| d.short == device || d.key == device)
                .and_then(|(d, r)| r.lanes.iter().flat_map(|l| l.sessions.iter()).find(|s| s.key == own).map(|s| (s.title.clone(), s.live, d.name.clone())))
                .unwrap_or_else(|| (String::new(), true, "its Mac".into()))
        });
        Ok(done_anyway(&title, live, &mac, &why))
    }

    /// Names a session on the Mac it's on, where its harness keeps its name. Macs before
    /// 2026-09-30 refuse it.
    pub fn rename(&self, key: String, name: String) -> Result<(), CoreError> {
        let (device, own) = split_remote(&key).ok_or_else(|| CoreError::Failed("That isn't a session on one of your Macs.".into()))?;
        Ok(self.client.rename(device, own, name.trim())?)
    }

    /// What a session's reply box says before you write: who it goes to and how it gets there
    /// (`way`, as its Mac said); for one that isn't running, where it goes on (`resume_place`,
    /// with `behind` for a terminal behind the Mac's windows).
    pub fn reply_placeholder(&self, key: String, way: Option<Way>, resume_place: Option<String>, behind: bool) -> ReplyPlaceholder {
        let unknown = || ReplyPlaceholder { short: "Reply".into(), full: "Reply".into() };
        let Some((device, own)) = split_remote(&key) else { return unknown() };
        let resuming = resume_place.as_deref().and_then(api::Place::from_word).map(|p| (p, behind));
        self.client.with_feeds(|feeds| {
            let session = feeds.iter().filter(|(d, _)| d.short == device || d.key == device).flat_map(|(_, r)| r.lanes.iter().flat_map(|l| l.sessions.iter())).find(|s| s.key == own);
            session.map_or_else(unknown, |s| ReplyPlaceholder { short: reply_to(s), full: placeholder(s, way.as_ref(), resuming) })
        })
    }
}

/// A model as people say it (start.ts `modelName`): its account's label for it where it lists
/// it, else Claude's own ids spelled out (`claude-opus-5-5` is Opus 5.5), else as its harness
/// names it.
#[uniffi::export]
pub fn model_name(model: String, models: Vec<StartModel>) -> String {
    if let Some(known) = models.iter().find(|m| m.id == model) {
        let label = known.label.split(':').next().unwrap_or(&known.label);
        return label.strip_suffix(" (1M context)").map_or_else(|| label.to_string(), |l| format!("{l} 1M"));
    }
    let lower = model.to_lowercase();
    let (base, long) = match lower.strip_suffix("[1m]") {
        Some(b) => (&model[..b.len()], true),
        None => (model.as_str(), false),
    };
    let parts: Vec<&str> = base.split('-').collect();
    let digits = |s: &str, max: usize| !s.is_empty() && s.len() <= max && s.chars().all(|c| c.is_ascii_digit());
    let name = match parts.as_slice() {
        // claude-<family>-<major>[-<minor>][-<date>]
        ["claude", family, major, rest @ ..] if !family.is_empty() && family.chars().all(|c| c.is_ascii_alphabetic()) && digits(major, 3) => {
            // A date after the version names a snapshot of it, which reads as the version.
            let date = |d: &str| d.len() == 8 && digits(d, 8);
            let minor = match rest {
                [] => None,
                [d] if date(d) => None,
                [m] if digits(m, 2) => Some(*m),
                [m, d] if digits(m, 2) && date(d) => Some(*m),
                _ => return format!("{base}{}", if long { " 1M" } else { "" }),
            };
            let mut f = family.chars();
            let family: String = f.next().map(|c| c.to_ascii_uppercase()).into_iter().chain(f).collect();
            format!("{family} {major}{}", minor.map(|m| format!(".{m}")).unwrap_or_default())
        }
        _ => base.to_string(),
    };
    if long { format!("{name} 1M") } else { name }
}

/// What being done with a session came to.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct DoneOutcome {
    /// It was marked seen and archived. False when work under way held it, which `message` says:
    /// asked again with `stop`, that ends too.
    pub done: bool,
    /// One sentence: what ended, or what's under way.
    pub message: String,
    /// Something didn't go as asked (its terminal left open, say), worth saying though it left
    /// the list.
    pub noted: bool,
}

/// Done with a session on a Mac that won't end it (`why`): it's been marked seen and archived
/// there, and the rest is left as it is. For one that isn't running, that's all Done would do.
fn done_anyway(title: &str, live: bool, mac: &str, why: &str) -> DoneOutcome {
    if !live {
        return DoneOutcome { done: true, message: format!("Done with \u{201c}{title}\u{201d}: it\u{2019}s archived."), noted: false };
    }
    let why = if why.contains("doesn't know how to") { format!("Codealong there is from before it could be asked to close it: update it on {mac}.") } else { why.to_string() };
    DoneOutcome { done: true, message: format!("Done with \u{201c}{title}\u{201d}: it\u{2019}s archived, but still open on {mac}. {why}"), noted: true }
}

/// What a Mac can start, as the phone offers it.
fn start_choices(o: api::StartOptions) -> StartChoices {
    let listed = |m: &[api::ModelOption]| -> Vec<StartModel> { m.iter().map(|m| StartModel { id: m.id.clone(), label: m.label.clone() }).collect() };
    let (claude, claude_efforts) = (listed(&o.claude_models), listed(&o.claude_efforts));
    let accounts = o
        .accounts
        .iter()
        .map(|a| {
            // Macs before the models were listed for each account list Claude Code's alone, and
            // make a new worktree only for it.
            let older = a.models.is_empty() && a.harness == Harness::Claude;
            let place = |p: api::Place| a.places.iter().find(|o| o.place == p).map(|o| StartPlace { id: p.word().to_string(), label: o.label.clone(), behind: o.behind });
            StartAccount {
                name: a.name.clone(),
                harness: a.harness.word().to_string(),
                places: a.places.iter().filter_map(|o| place(o.place)).collect(),
                place: start_place(a, &a.places.iter().map(|o| o.place).collect::<Vec<_>>()),
                unavailable: a.unavailable.clone(),
                default_model: a.default_model.clone(),
                preferred: a.preferred,
                models: if older { claude.clone() } else { listed(&a.models) },
                efforts: if a.efforts.is_empty() && a.harness == Harness::Claude { claude_efforts.clone() } else { listed(&a.efforts) },
                worktree: a.worktree || older,
                resumes: a.resumes.iter().filter_map(|p| place(*p)).collect(),
                resume: resume_place(a),
                switches_model: a.switches_model,
                switches_effort: a.switches_effort,
                switches_mid_turn: a.switches_mid_turn,
                switches_in_app: a.switches_in_app,
            }
        })
        .collect();
    StartChoices { accounts, models: claude }
}

/// What sending to a session that isn't running does, after "it isn't running, so" (start.ts
/// `resumeWords`). `app` is the terminal its Mac resumes it in.
fn resume_words(place: api::Place, app: &str, behind: bool) -> String {
    match place {
        api::Place::Background if behind => format!("this resumes it in {app}, behind its Mac\u{2019}s windows"),
        api::Place::Background => "this resumes it in the background".into(),
        api::Place::ClaudeApp => "the Claude app on its Mac opens it with this on the clipboard".into(),
        api::Place::CodexApp => "this goes on in the Codex app".into(),
        api::Place::Codealong => "Codealong runs it from now on".into(),
        api::Place::Terminal => format!("this resumes it in {app}"),
    }
}

/// What a session's reply box says before you write: the whole of it while the box is open, and
/// while it's folded to a line, only who a message goes to.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ReplyPlaceholder {
    /// "Send to claude", or "Answer claude" when its last reply asks you something.
    pub short: String,
    /// That, and how a message gets there (`placeholder`).
    pub full: String,
}

/// Who a reply goes to, as the reply box's words start.
fn reply_to(s: &Session) -> String {
    if s.asks { format!("Answer {}", s.account) } else { format!("Send to {}", s.account) }
}

/// What a session's reply box says before you write, as the Mac's does (SessionReply.tsx
/// `replyPlaceholder`): who it goes to, and how it gets there, as its Mac said (`way`), or, from
/// a Mac that doesn't say, as its state suggests. A session that isn't running goes on where
/// `resuming` says, else in a terminal.
fn placeholder(s: &Session, way: Option<&Way>, resuming: Option<(api::Place, bool)>) -> String {
    let to = reply_to(s);
    let busy = matches!(s.status, PeerStatus::Working | PeerStatus::Needs);
    if s.hosted {
        return if busy { format!("{to}: it takes this after its current turn") } else { to };
    }
    // One working only on what its turn left in the background sits at its prompt: this starts a turn.
    let working = if s.status == PeerStatus::Working && !s.left_running() { ": it takes this in as it works" } else { "" };
    let off = "it isn\u{2019}t running, so";
    match way {
        Some(Way::Typed { app }) => format!("{to} via {app}{working}"),
        Some(Way::Background) => format!("{to} via its background job{working}"),
        Some(Way::Message) => format!("{to} as a message from Codealong{working}"),
        Some(Way::CodexApp) => format!("{to} via the Codex app{working}"),
        Some(Way::Opencode) => format!("{to} via OpenCode{working}"),
        Some(Way::Resume { app }) => {
            let (place, behind) = resuming.unwrap_or((api::Place::Terminal, false));
            format!("{to}: {off} {}", resume_words(place, app, behind))
        }
        Some(Way::ClaudeApp) => format!("{to}: {off} {}", resume_words(api::Place::ClaudeApp, "", false)),
        Some(Way::Antigravity) => format!("{to}: Antigravity on its Mac comes forward with this on the clipboard"),
        Some(Way::Cursor) => format!("{to}: Cursor on its Mac opens with this on the clipboard"),
        None if s.harness == Harness::Antigravity && s.surface == Surface::App => format!("{to}: Antigravity on its Mac comes forward with this on the clipboard"),
        None if s.harness == Harness::Cursor && s.surface == Surface::App => format!("{to}: Cursor on its Mac opens with this on the clipboard"),
        None if !s.live && s.harness == Harness::Claude && s.surface == Surface::App => format!("{to}: {off} {}", resume_words(api::Place::ClaudeApp, "", false)),
        None if !s.live && s.surface == Surface::Cli && matches!(s.harness, Harness::Claude | Harness::Codex | Harness::Antigravity) => format!("{to}: {off} this resumes it in a terminal"),
        None => format!("{to}{working}"),
    }
}

#[cfg(test)]
mod order_tests {
    use super::*;

    pub(crate) fn row(key: &str, status: Status, since: i64, snoozed_until: Option<i64>, last_prompt_at: i64) -> SessionRow {
        SessionRow {
            key: key.into(),
            device: String::new(),
            device_name: String::new(),
            device_online: true,
            title: key.into(),
            headline: String::new(),
            detail: None,
            status,
            stalled: false,
            waits_in_background: false,
            harness: String::new(),
            account: String::new(),
            project: String::new(),
            repo: String::new(),
            worktree: String::new(),
            worktree_id: String::new(),
            pinned: None,
            branch: None,
            last_prompt_at,
            last_activity: since,
            status_since: Some(since),
            hosted: false,
            section: section(status, snoozed_until, false),
            snoozed_until,
            started_at: None,
            live: true,
            in_app: false,
            asks: false,
            pr: None,
            worktree_pr: None,
            seenable: false,
            unreadable: false,
            stoppable: false,
            steerable: false,
            model: None,
            effort: None,
            mode: None,
            modes: vec![],
            queued: vec![],
            queued_at: None,
            flagged: false,
            cut_off: None,
            remote_control: None,
            edits: false,
            sides: false,
            name: None,
            origin: None,
            limit: None,
            api_error: None,
            quiet: false,
            unattended: false,
            headless: false,
            runs: 0,
            runs_working: 0,
            suggestions: None,
            emblem: None,
            id: key.into(),
            archived: false,
            raised: None,
            labels: vec![],
            agent_seen: None,
            side_answer: None,
            waits_on: None,
            aside: false,
            finished: None,
            waits_finished: false,
            listening: false,
            at_a_prompt: false,
            mark: Mark::Quiet,
            suggested_snooze: None,
        }
    }

    #[test]
    fn headless_runs_count_on_their_sessions_row_and_ones_without_one_are_listed() {
        let run = |key: &str, status: Status, from: Option<&str>| SessionRow {
            headless: true,
            unattended: status != Status::Needs,
            origin: from.map(|k| SessionOrigin { key: k.into(), title: None, fork: false }),
            ..row(key, status, 0, None, 0)
        };
        let mut rows = vec![
            row("boss", Status::Working, 0, None, 0),
            run("a", Status::Working, Some("boss")),
            run("b", Status::Working, Some("boss")),
            run("c", Status::Idle, Some("boss")),
            run("asks", Status::Needs, Some("boss")),
            // A script in a terminal ran it, or its session isn't on any linked Mac's board.
            run("lone", Status::Working, None),
            run("gone", Status::Idle, Some("closed")),
        ];
        count_runs(&mut rows);
        let by = |k: &str| rows.iter().find(|r| r.key == k).unwrap().clone();
        assert_eq!((by("boss").runs, by("boss").runs_working), (4, 2));
        assert!(by("a").unattended && by("c").unattended);
        assert!(!by("asks").unattended, "one that needs you waits on you");
        assert!(!by("lone").unattended && !by("gone").unattended, "listed as sessions of their own");
        assert_eq!(by("lone").runs, 0);
    }

    #[test]
    fn a_row_says_who_moved_it_to_the_top_what_its_agent_saw_and_what_answered_on_the_side() {
        use codealong_peer::client::Device;
        use codealong_peer::feed::Replica;
        use codealong_peer::model::{AgentSeen, Raised as Sent, SideAnswer as Answer};
        let mac = Device { key: "m".into(), short: "m".into(), name: "Mac".into(), online: true, since: None, last_seen: None, remote_control: true, app: String::new(), loading: false, linked_back: true };
        let mut lane = codealong_peer::model::Lane::new("/src/app", "App", "app");
        let mine = Session { raised: Some(Sent { at: 5, ..Sent::default() }), ..Session::new(Harness::Claude, "claude", "mine") };
        let agents = Session { raised: Some(Sent { at: 6, agent: true, by_title: Some("Orchestrator".into()), note: Some("The deploy waits on it.".into()), ..Sent::default() }), ..Session::new(Harness::Claude, "claude", "agents") };
        let seen = Session { agent_seen: Some(AgentSeen { at: 7, note: Some("Nothing new".into()) }), ..Session::new(Harness::Claude, "claude", "seen") };
        let side = Session { side_answer: Some(Answer { id: "1793-4".into(), open: true, at: 8 }), ..Session::new(Harness::Claude, "claude", "side") };
        lane.sessions = vec![mine, agents, seen, side];
        let replica = Replica { lanes: vec![lane], ..Replica::default() };
        let rows = all_rows(&[(mac, &replica)]);
        let row = |id: &str| rows.iter().find(|r| r.id == id).unwrap();
        assert_eq!(row("mine").raised.as_ref().map(|r| r.says.as_str()), Some("Moved to the top. It\u{2019}s first in every queue until you send it something or see its finished turn."));
        let up = row("agents").raised.clone().unwrap();
        assert_eq!((up.at, up.agent), (6, true));
        assert!(up.says.starts_with("Moved to the top by Orchestrator: The deploy waits on it. It\u{2019}s"), "{}", up.says);
        assert_eq!(row("seen").agent_seen.as_deref(), Some("Seen by its agent, which said this turn needs nothing from you: Nothing new. Mark as unread makes it Your turn again."));
        assert_eq!(row("side").side_answer, Some(SideAnswer { id: "1793-4".into(), open: true, at: 8 }));
        // From a Mac before these, a row says none of it.
        assert_eq!((row("side").raised.clone(), row("side").agent_seen.clone(), row("seen").side_answer.clone()), (None, None, None));
    }

    #[test]
    fn a_row_wears_its_labels_and_its_menu_offers_its_macs() {
        use codealong_peer::client::Device;
        use codealong_peer::feed::Replica;
        use codealong_peer::model::Label;
        let label = |id: &str, name: &str, color: &str| Label { id: id.into(), name: name.into(), color: color.into() };
        let mac = Device { key: "m".into(), short: "m".into(), name: "Mac".into(), online: true, since: None, last_seen: None, remote_control: true, app: String::new(), loading: false, linked_back: true };
        let mut lane = codealong_peer::model::Lane::new("/src/app", "App", "app");
        let both = Session { labels: vec![label("l-2", "Ready", "green"), label("l-1", "bug", "plaid"), label("l-5", "Équipe", "teal")], ..Session::new(Harness::Claude, "claude", "both") };
        // Two labels the Mac keeps apart, since it matches names' case only in ASCII.
        let other = Session { labels: vec![label("l-1", "bug", "plaid"), label("l-3", "Atlas", "indigo"), label("l-4", " ", "red"), label("l-6", "équipe", "blue")], ..Session::new(Harness::Claude, "claude", "other") };
        let none = Session::new(Harness::Claude, "claude", "none");
        lane.sessions = vec![both, other, none];
        let replica = Replica { lanes: vec![lane], ..Replica::default() };
        let rows = all_rows(&[(mac, &replica)]);
        let row = |id: &str| rows.iter().find(|r| r.id == id).unwrap();
        // In the order they were put on, and a color the Mac doesn't know is gray, as it draws it.
        assert_eq!(row("both").labels[..2], [SessionLabel { id: "l-2".into(), name: "Ready".into(), color: "green".into() }, SessionLabel { id: "l-1".into(), name: "bug".into(), color: "gray".into() }]);
        // From a Mac before labels, none.
        assert!(row("none").labels.is_empty());
        // The menu offers every label its Mac's sessions wear, once each, in order of name, checked
        // where it wears it, each sent by its id; one with no name isn't offered.
        let sessions: Vec<&Session> = replica.lanes.iter().flat_map(|l| l.sessions.iter()).collect();
        let offered = |id: &str| label_choices(&sessions, &sessions.iter().find(|s| s.id == id).unwrap().key).into_iter().map(|c| (c.label.name, c.worn, c.by)).collect::<Vec<_>>();
        let choice = |name: &str, worn: bool, by: &str| (name.to_string(), worn, by.to_string());
        assert_eq!(offered("both"), [choice("Atlas", false, "l-3"), choice("bug", true, "l-1"), choice("Ready", true, "l-2"), choice("Équipe", true, "l-5"), choice("équipe", false, "l-6")]);
        assert_eq!(offered("none"), [choice("Atlas", false, "l-3"), choice("bug", false, "l-1"), choice("Ready", false, "l-2"), choice("Équipe", false, "l-5"), choice("équipe", false, "l-6")]);
        // A label without an id goes by its name.
        let unnamed = Session { key: "k".into(), labels: vec![label("", "Later", "red")], ..Session::new(Harness::Claude, "claude", "k") };
        assert_eq!(label_choices(&[&unnamed], "k").into_iter().map(|c| (c.label.name, c.worn, c.by)).collect::<Vec<_>>(), [choice("Later", true, "Later")]);
    }

    #[test]
    fn a_side_answer_comes_up_once_and_a_closed_one_put_away_stays_away() {
        let answer = |at: i64, open: bool| SideAnswer { id: format!("s{at}"), open, at };
        // The first time, a closed one is kept as put away; an open one isn't.
        assert_eq!(side_answer_due(answer(8, false), None, 0), Some(8));
        assert_eq!(side_answer_due(answer(8, true), None, 3), Some(3));
        // Put away before, here or before the app last opened.
        assert_eq!(side_answer_due(answer(8, false), None, 8), None);
        assert_eq!(side_answer_due(answer(8, true), None, 9), None);
        // Up already since it opened.
        assert_eq!(side_answer_due(answer(8, true), Some(answer(8, true)), 0), None);
        assert_eq!(side_answer_due(answer(7, true), Some(answer(8, false)), 0), None);
        // Open as it came up, closed since with nothing more asked: up again, closed, and kept.
        assert_eq!(side_answer_due(answer(8, false), Some(answer(8, true)), 0), Some(8));
        // A later answer comes up.
        assert_eq!(side_answer_due(answer(9, true), Some(answer(8, false)), 8), Some(8));
    }

    #[test]
    fn a_side_turn_at_work_says_so_with_its_clock_until_its_answered() {
        let turn = |answer: &str, tools: &[&str], tool: Option<&str>, done: bool, at: i64| SideTurn {
            question: "why?".into(),
            answer: answer.into(),
            tools: tools.iter().map(|t| t.to_string()).collect(),
            tool: tool.map(String::from),
            done,
            error: None,
            at,
        };
        let working = |words: &str, since: Option<i64>| Some(SideTurnLine { waits: false, words: words.into(), since });
        // Before the copy has done or said anything.
        assert_eq!(side_turn_line(turn("", &[], None, false, 5), true), working("Reading the conversation…", Some(5)));
        // A tool it runs, and thought after one, are still work: the line stays under them.
        assert_eq!(side_turn_line(turn("", &[], Some("Bash · `gcloud logging read`"), false, 5), true), working("Working…", Some(5)));
        assert_eq!(side_turn_line(turn("", &["Bash · `gcloud logging read`"], None, false, 5), true), working("Working…", Some(5)));
        assert_eq!(side_turn_line(turn("Because", &["Read"], None, false, 5), true), working("Writing…", Some(5)));
        // A tool it runs after saying something is work, not writing.
        assert_eq!(side_turn_line(turn("I'll wait on it.", &["Bash · `sleep 150`"], Some("Bash · `sleep 150`"), false, 5), true), working("Working…", Some(5)));
        // A turn kept from before its Mac noted when it was asked has no clock.
        assert_eq!(side_turn_line(turn("", &[], None, false, 0), true), working("Reading the conversation…", None));
        // One asked after the turn the copy is on waits for it.
        assert_eq!(side_turn_line(turn("", &[], None, false, 9), false), Some(SideTurnLine { waits: true, words: "Waits for the answer above".into(), since: None }));
        // Answered, or ended without one: nothing.
        assert_eq!(side_turn_line(turn("Because.", &[], None, true, 5), true), None);
        assert_eq!(side_turn_line(turn("", &[], None, true, 5), false), None);
    }

    #[test]
    fn a_working_session_says_what_it_waits_on_a_run_in_your_terminal_first() {
        use codealong_peer::model::RunningIn;
        let working = |id: &str| Session { status: PeerStatus::Working, ..Session::new(Harness::Claude, "claude", id) };
        // Shown on one line, and copied as it was written: its lines, and the spaces it quotes.
        let run = RunningIn { terminal: "Ghostty".into(), command: "echo first\n  echo 'a  b'\n".into(), yours: false };
        let both = Session { running: Some(run), background: Some("make watch".into()), ..working("both") };
        assert_eq!(
            waits_on(&both),
            Some(WaitsOn { lead: "Running in Ghostty".into(), command: Some("echo first echo 'a b'".into()), written: Some("echo first\n  echo 'a  b'".into()), in_terminal: true, agents: vec![], then: None })
        );
        // A command you ran for it says it's yours, and where what it prints goes.
        let yours = Session { running: Some(RunningIn { terminal: "Codealong".into(), command: "npm test".into(), yours: true }), ..working("yours") };
        assert_eq!(
            waits_on(&yours),
            Some(WaitsOn { lead: "Your command in Codealong".into(), command: Some("npm test".into()), written: Some("npm test".into()), in_terminal: true, agents: vec![], then: Some("What it prints goes to claude when it ends".into()) })
        );
        let background = Session { background: Some("make watch".into()), ..working("bg") };
        assert_eq!(waits_on(&background), Some(WaitsOn { lead: "Waiting on".into(), command: Some("make watch".into()), written: Some("make watch".into()), in_terminal: false, agents: vec![], then: None }));
        // Agents it left running in the background, in its Mac's words for them, what each is
        // for listed where there are several; ahead of a command, as the Mac's thread has them.
        let agents = Session { agents: vec!["Review the diff".into(), " ".into(), "Run the tests".into()], excerpt: Some("Waiting on 3 background agents".into()), ..background.clone() };
        assert_eq!(waits_on(&agents), Some(WaitsOn { lead: "Waiting on 3 background agents".into(), command: None, written: None, in_terminal: false, agents: vec!["Review the diff".into(), "Run the tests".into()], then: None }));
        assert_eq!(waits_on(&Session { excerpt: None, ..agents.clone() }).map(|w| w.lead), Some("Waiting on its background agents".into()));
        // One, its Mac's line names.
        let one = Session { agents: vec!["Review the diff".into()], excerpt: Some("Waiting on a background agent · Review the diff".into()), ..agents };
        assert_eq!(waits_on(&one).map(|w| (w.lead, w.agents)), Some(("Waiting on a background agent · Review the diff".into(), vec![])));
        // Its Mac couldn't read the command.
        let unread = Session { background: Some("  ".into()), ..working("unread") };
        assert_eq!(waits_on(&unread).map(|w| (w.lead, w.command, w.written)), Some(("Waiting on a command in the background".into(), None, None)));
        // A turn that runs, one stalled, and one no longer working wait on nothing.
        assert_eq!(waits_on(&working("turn")), None);
        assert_eq!(waits_on(&Session { stalled_since: Some(5), ..both.clone() }), None);
        assert_eq!(waits_on(&Session { status: PeerStatus::Needs, ..both }), None);
    }

    #[test]
    fn a_session_whose_command_of_yours_runs_waits_on_it_with_no_turn_to_stop() {
        use codealong_peer::model::RunningIn;
        let yours = Session {
            status: PeerStatus::Working,
            running: Some(RunningIn { terminal: "Ghostty".into(), command: "npm test".into(), yours: true }),
            ..Session::new(Harness::Claude, "claude", "yours")
        };
        // Drawn waiting, as on what its turn left running: no turn runs, so nothing to stop, and a
        // prompt starts one.
        assert_eq!(mark_of(&yours, Status::Working, false, false), Mark::Waiting);
        assert!(!turn_running(&yours));
        // One you allowed for its agent is its turn's.
        let allowed = Session { running: Some(RunningIn { yours: false, ..yours.running.clone().unwrap() }), ..yours.clone() };
        assert_eq!(mark_of(&allowed, Status::Working, false, false), Mark::Working);
        assert!(turn_running(&allowed));
    }

    #[test]
    fn an_api_error_that_ended_a_turn_says_what_went_wrong_and_offers_try_again() {
        use codealong_peer::model::{ApiError, ConnectionLost};
        let base = Session::new(Harness::Claude, "claude", "err");
        let error = Some(ApiError { at: 5, said: "529 Overloaded. This is a server-side issue, usually temporary. \n".into() });
        let overloaded = Session { api_error: error.clone(), ..base.clone() };
        assert_eq!(
            api_error_note(&overloaded, Status::Unread),
            Some(ApiErrorNote {
                says: "Its last turn ended on an API error: 529 Overloaded. This is a server-side issue, usually temporary.".into(),
                says_alone: "Its last turn ended on an API error: 529 Overloaded. This is a server-side issue, usually temporary. Send it something to try again.".into(),
                lost: false,
                button: Some("Try again".into()),
                message: TRY_AGAIN.into(),
            })
        );
        // A lost connection its Mac carries on by itself: Try now, and it says so either way.
        let lost = Session { api_error: Some(ApiError { at: 5, said: "No response from API".into() }), connection_lost: Some(ConnectionLost { at: 5, continues: true }), ..base.clone() };
        let note = api_error_note(&lost, Status::Unread).unwrap();
        assert_eq!(note.says, "Its last turn ended on an API error: No response from API. Codealong tells it to carry on once the API can be reached again.");
        assert_eq!(note.says_alone, note.says);
        assert_eq!((note.lost, note.button.as_deref()), (true, Some("Try now")));
        // A Mac from before 2026-11-11 sends only the lost connection, without its words.
        let older = Session { connection_lost: Some(ConnectionLost { at: 5, continues: false }), ..base.clone() };
        let note = api_error_note(&older, Status::Idle).unwrap();
        assert_eq!(note.says, "Its last turn ended because it couldn\u{2019}t reach its API: the Mac slept, or the network dropped.");
        assert_eq!(note.says_alone, "Its last turn ended because it couldn\u{2019}t reach its API: the Mac slept, or the network dropped. Send it something to try again.");
        // Words that are only spaces are none.
        let blank = Session { api_error: Some(ApiError { at: 5, said: " . ".into() }), ..older.clone() };
        assert_eq!(api_error_note(&blank, Status::Idle).map(|n| n.says), api_error_note(&older, Status::Idle).map(|n| n.says));
        // Archived, there's no button; working again, or with no error, there's no note.
        assert_eq!(api_error_note(&Session { archived: true, ..overloaded.clone() }, Status::Unread).and_then(|n| n.button), None);
        assert_eq!(api_error_note(&overloaded, Status::Working), None);
        assert_eq!(api_error_note(&base, Status::Unread), None);
    }

    #[test]
    fn a_reply_whose_work_goes_on_later_is_offered_a_snooze_until_then() {
        use codealong_peer::model::SessionInsight;
        const NOW: i64 = 1_000_000_000;
        const DAY: i64 = 24 * 60 * 60 * 1000;
        let read = |insight: SessionInsight| Session { insight: Some(insight), ..Session::new(Harness::Claude, "claude", "later") };
        let jev = read(SessionInsight { waits_until: Some(NOW + DAY), ..Default::default() });
        assert_eq!(suggested_snooze(&jev, false, NOW), Some(SuggestedSnooze { until: NOW + DAY, offered_till: NOW + DAY - SNOOZE_WORTH_MS, by: "Jev\u{2019}s read".into() }));
        // An agent's tag says who, and what it noted.
        let tagged = read(SessionInsight { waits_until: Some(NOW + DAY), by: Some("k".into()), by_title: Some("Orchestrator".into()), note: Some("The freeze lifts Monday.".into()), ..Default::default() });
        assert_eq!(suggested_snooze(&tagged, false, NOW).map(|s| s.by), Some("Tagged by Orchestrator: The freeze lifts Monday.".into()));
        let unnamed = read(SessionInsight { waits_until: Some(NOW + DAY), by: Some("k".into()), ..Default::default() });
        assert_eq!(suggested_snooze(&unnamed, false, NOW).map(|s| s.by), Some("Tagged by an agent".into()));
        // None once it's all but here or gone by, while it's snoozed or archived, and for a
        // reply that names no time.
        assert_eq!(suggested_snooze(&read(SessionInsight { waits_until: Some(NOW + SNOOZE_WORTH_MS), ..Default::default() }), false, NOW), None);
        assert_eq!(suggested_snooze(&read(SessionInsight { waits_until: Some(NOW - DAY), ..Default::default() }), false, NOW), None);
        assert_eq!(suggested_snooze(&jev, true, NOW), None);
        assert_eq!(suggested_snooze(&Session { archived: true, ..jev.clone() }, false, NOW), None);
        assert_eq!(suggested_snooze(&read(SessionInsight::default()), false, NOW), None);
    }

    #[test]
    fn a_held_message_can_be_written_again_unless_it_only_names_part_of_itself() {
        assert_eq!(held_words("Run the tests").as_deref(), Some("Run the tests"));
        // Square brackets of its own are words like any.
        assert_eq!(held_words("See [Image] and [#3]").as_deref(), Some("See [Image] and [#3]"));
        assert_eq!(held_words("Look at [Image #1]"), None);
        assert_eq!(held_words("[Pasted text #2 +40 lines]"), None);
        assert_eq!(held_words("Before [...Truncated text #3 +9 lines] after"), None);
    }

    #[test]
    fn moved_to_the_top_goes_first_in_its_section_and_stays_in_it() {
        let raised = |row: SessionRow, at: i64, agent: bool| SessionRow { raised: Some(Raised { at, agent, says: String::new() }), ..row };
        let mut rows = vec![
            row("older", Status::Needs, 10, None, 0),
            row("newer", Status::Needs, 20, None, 0),
            raised(row("agents", Status::Needs, 30, None, 0), 900, true),
            raised(row("yours", Status::Needs, 40, None, 0), 100, false),
            // Your turn reads newest first, and a move to the top leads it too; but it's still Your turn.
            row("ended", Status::Unread, 50, None, 0),
            raised(row("read", Status::Unread, 5, None, 0), 100, false),
        ];
        rows.sort_by(inbox_order);
        assert_eq!(rows.iter().map(|r| r.key.as_str()).collect::<Vec<_>>(), ["yours", "agents", "older", "newer", "read", "ended"]);
    }

    #[test]
    fn a_finished_turn_comes_after_the_rest_of_your_turn_but_not_ahead_of_one_moved_up() {
        let finished = |row: SessionRow| SessionRow { waits_finished: true, ..row };
        let mut rows = vec![
            finished(row("done-new", Status::Unread, 90, None, 0)),
            row("ended", Status::Unread, 50, None, 0),
            finished(SessionRow { raised: Some(Raised { at: 1, agent: false, says: String::new() }), ..row("done-up", Status::Unread, 10, None, 0) }),
            row("older", Status::Unread, 20, None, 0),
        ];
        rows.sort_by(inbox_order);
        assert_eq!(rows.iter().map(|r| r.key.as_str()).collect::<Vec<_>>(), ["done-up", "ended", "older", "done-new"]);
    }

    #[test]
    fn a_session_says_what_the_mac_says_of_it_set_aside_finished_or_hearing() {
        use codealong_peer::client::Device;
        use codealong_peer::feed::Replica;
        use codealong_peer::model::Finished;
        let mac = Device { key: "m".into(), short: "m".into(), name: "Mac".into(), online: true, since: None, last_seen: None, remote_control: true, app: String::new(), loading: false, linked_back: true };
        let s = |id: &str, status: PeerStatus| Session { status, last_prompt_at: now_ms(), ..Session::new(Harness::Claude, "claude", id) };
        let mut lane = codealong_peer::model::Lane::new("/src/app", "App", "app");
        lane.sessions = vec![
            // Set aside while it needs you: listed with what's working, drawn waiting.
            Session { aside: Some(5), excerpt: Some("Bash · `make`".into()), ..s("aside", PeerStatus::Needs) },
            // Set aside once, but its side conversation's done and it's Your turn: as it is.
            Session { aside: Some(5), ..s("over", PeerStatus::Unread) },
            Session { finished: Some(Finished { sure: true, why: vec!["#12 merged".into(), "todo done".into()] }), ..s("done", PeerStatus::Unread) },
            Session { finished: Some(Finished { sure: false, why: vec!["its reply reads as done".into()] }), ..s("looks", PeerStatus::Idle) },
            // Sent a prompt since: working, and no longer finished.
            Session { finished: Some(Finished { sure: true, why: vec!["#12 merged".into()] }), ..s("again", PeerStatus::Working) },
            Session { listening: true, ..s("hears", PeerStatus::Working) },
            // Hearing, but it needs you: that shows.
            Session { listening: true, excerpt: Some("Bash · `make`".into()), ..s("hears-needs", PeerStatus::Needs) },
            Session { agents: vec!["Review".into()], ..s("agents", PeerStatus::Working) },
            Session { stalled_since: Some(1), ..s("stuck", PeerStatus::Working) },
            Session { asks: true, excerpt: Some("Asks you · Want the PR?".into()), ..s("asks", PeerStatus::Needs) },
        ];
        let mut put_away = codealong_peer::model::Lane::new("/src/old", "App", "old");
        put_away.sessions = vec![Session { archived: true, ..s("archived", PeerStatus::Idle) }, Session { archived: true, ..s("archived-working", PeerStatus::Working) }];
        let replica = Replica { lanes: vec![lane, put_away], ..Replica::default() };
        let rows = session_rows(&[(mac, &replica)], true);
        let by = |id: &str| rows.iter().find(|r| r.key == format!("@m:claude:claude:{id}")).unwrap().clone();

        let aside = by("aside");
        assert!(aside.aside);
        assert_eq!((aside.section, aside.mark), (InboxSection::Working, Mark::Waiting));
        assert!(aside.at_a_prompt, "it still waits at its prompt, for when it's back");
        let over = by("over");
        assert!(!over.aside);
        assert_eq!((over.section, over.mark), (InboxSection::YourTurn, Mark::Unread));

        let done = by("done");
        assert!(done.waits_finished);
        assert_eq!(done.finished.as_ref().map(|f| (f.sure, f.label.as_str())), Some((true, "Finished")));
        assert!(done.finished.unwrap().says.contains("#12 merged, todo done"));
        let looks = by("looks");
        assert!(!looks.waits_finished, "seen already, it's not yours to read");
        assert_eq!(looks.finished.map(|f| (f.sure, f.label)), Some((false, "Looks finished".to_string())));
        assert_eq!(by("again").finished, None);

        assert_eq!(by("hears").mark, Mark::Hearing);
        assert!(by("hears").listening);
        assert_eq!(by("hears-needs").mark, Mark::Needs);
        assert_eq!(by("agents").mark, Mark::Waiting);
        assert!(by("agents").waits_in_background);
        assert_eq!(by("stuck").mark, Mark::Stuck);
        assert!(!by("asks").at_a_prompt, "a reply that asks you something sits at no prompt");
        assert_eq!(by("asks").mark, Mark::Needs);
        assert_eq!(by("archived").mark, Mark::Archived);
        assert_eq!(by("archived-working").mark, Mark::Working, "archiving ends nothing: one at work shows that");
    }

    #[test]
    fn a_mac_sends_what_some_page_follows_and_a_page_lets_go_of_its_own_alone() {
        let mut leases = Vec::new();
        assert_eq!(leased(&mut leases, "a", 1, true), ["a"]);
        assert_eq!(leased(&mut leases, "b", 2, true), ["a", "b"]);
        // The same session's page again, over the other: and asked again, the same lease.
        assert_eq!(leased(&mut leases, "a", 3, true), ["a", "b"]);
        assert_eq!(leased(&mut leases, "a", 3, true), ["a", "b"]);
        // The first page's late letting go leaves the newer one's.
        assert_eq!(leased(&mut leases, "a", 1, false), ["b", "a"]);
        assert_eq!(leased(&mut leases, "a", 3, false), ["b"]);
        assert_eq!(leased(&mut leases, "b", 2, false), Vec::<String>::new());
        // Letting go of what was never held changes nothing.
        assert_eq!(leased(&mut leases, "c", 9, false), Vec::<String>::new());
    }

    #[test]
    fn a_turn_runs_while_it_works_is_stuck_or_holds_for_your_answer_at_a_prompt() {
        let s = |status| Session { status, ..Session::new(Harness::Claude, "claude", "a") };
        assert!(turn_running(&s(PeerStatus::Working)));
        assert!(turn_running(&Session { excerpt: Some("Bash · `make`".into()), ..s(PeerStatus::Needs) }));
        assert!(turn_running(&Session { stalled_since: Some(1), ..s(PeerStatus::Working) }));
        // Its turn ended: on a reply that asks you, or leaving work in the background.
        assert!(!turn_running(&Session { asks: true, excerpt: Some("Asks you · Want the PR?".into()), ..s(PeerStatus::Needs) }));
        assert!(!turn_running(&Session { background: Some("make watch".into()), ..s(PeerStatus::Working) }));
        assert!(!turn_running(&Session { agents: vec!["Review".into()], ..s(PeerStatus::Working) }));
        // A command left in the background that sits still is stuck, its turn still over.
        assert!(!turn_running(&Session { stalled_since: Some(1), background: Some("acme login".into()), ..s(PeerStatus::Needs) }));
        for over in [PeerStatus::Unread, PeerStatus::Idle, PeerStatus::Stopped, PeerStatus::Error] {
            assert!(!turn_running(&s(over)));
        }
    }

    #[test]
    fn a_box_says_a_session_that_waits_on_its_background_takes_a_prompt_as_a_new_turn() {
        let s = Session { status: PeerStatus::Working, live: true, agents: vec!["Review".into()], ..Session::new(Harness::Claude, "claude", "a") };
        assert_eq!(placeholder(&s, Some(&Way::Background), None), "Send to claude via its background job");
        let turn = Session { agents: vec![], ..s };
        assert_eq!(placeholder(&turn, Some(&Way::Background), None), "Send to claude via its background job: it takes this in as it works");
    }

    #[test]
    fn a_link_names_a_session_on_the_mac_it_was_written_on() {
        let on = |key: &str, id: &str| SessionRow { id: id.into(), ..row(key, Status::Idle, 0, None, 0) };
        let rows = vec![on("@aaa:claude:claude:abc-1", "abc-1"), on("@aaa:codex:work:7f3a", "7f3a"), on("@bbb:claude:claude:abc-2", "abc-2"), on("@bbb:claude:claude:xyz", "xyz")];
        let named = |name: &str, mac: Option<&str>| session_named_in(&rows, name, mac);
        // By its key on its Mac, by its id, or the start of only one's.
        assert_eq!(named("claude:claude:abc-1", Some("aaa")).as_deref(), Some("@aaa:claude:claude:abc-1"));
        assert_eq!(named("7f3a", Some("aaa")).as_deref(), Some("@aaa:codex:work:7f3a"));
        assert_eq!(named("codex:work", Some("aaa")).as_deref(), Some("@aaa:codex:work:7f3a"));
        // Only that Mac's: another's of the same start isn't, and one on another Mac is named
        // with it.
        assert_eq!(named("claude:claude:abc", Some("aaa")).as_deref(), Some("@aaa:claude:claude:abc-1"));
        assert_eq!(named("xyz", Some("aaa")), None);
        assert_eq!(named("@bbb:claude:claude:xyz", Some("aaa")).as_deref(), Some("@bbb:claude:claude:xyz"));
        // From elsewhere, any Mac's, as long as only one's.
        assert_eq!(named("xyz", None).as_deref(), Some("@bbb:claude:claude:xyz"));
        assert_eq!(named("claude:claude:abc", None), None);
        assert_eq!(named("", Some("aaa")), None);
    }

    #[test]
    fn every_session_has_a_row_when_asked_for_and_the_lists_rows_stay_as_they_were() {
        use codealong_peer::client::Device;
        use codealong_peer::feed::Replica;
        use codealong_peer::model::SessionOrigin as Origin;
        let mac = Device { key: "m".into(), short: "m".into(), name: "Mac".into(), online: true, since: None, last_seen: None, remote_control: true, app: String::new(), loading: false, linked_back: true };
        let mut lane = codealong_peer::model::Lane::new("/src/app", "App", "app");
        // A headless run of an archived session.
        let run = Session { headless: true, origin: Some(Origin { key: "claude:claude:old".into(), how: OriginHow::Started }), ..Session::new(Harness::Claude, "claude", "run") };
        lane.sessions = vec![Session { archived: true, ..Session::new(Harness::Claude, "claude", "old") }, Session::new(Harness::Claude, "claude", "new"), run];
        // A worktree in no project, which the list leaves out while nothing in it needs you.
        let mut scratch = codealong_peer::model::Lane::new("/scratch", "Elsewhere", "scratch");
        scratch.hidden = true;
        scratch.sessions = vec![Session::new(Harness::Claude, "claude", "aside")];
        let replica = Replica { lanes: vec![lane, scratch], ..Replica::default() };
        let feeds = [(mac, &replica)];
        let keys = |rows: &[SessionRow]| rows.iter().map(|r| (r.key.trim_start_matches("@m:claude:claude:").to_string(), r.archived)).collect::<Vec<_>>();
        let listed = all_rows(&feeds);
        assert_eq!(keys(&listed), [("new".to_string(), false), ("run".into(), false)]);
        let every = session_rows(&feeds, true);
        assert_eq!(keys(&every), [("new".to_string(), false), ("run".into(), false), ("old".into(), true), ("aside".into(), false)]);
        // The run is listed as a session of its own either way, and the archived one counts none.
        assert_eq!(every[..2], listed[..]);
        assert!(!every[1].unattended);
        assert_eq!(every[2].runs, 0);
    }

    #[test]
    fn the_inbox_reads_as_the_macs_sessions_view() {
        let mut rows = vec![
            row("idle-old", Status::Idle, 10, None, 100),
            row("turn-old", Status::Unread, 20, None, 0),
            row("needs-new", Status::Needs, 50, None, 0),
            row("snoozed-later", Status::Needs, 5, Some(900), 0),
            row("working", Status::Working, 40, Some(800), 0),
            row("error-old", Status::Error, 30, None, 0),
            row("turn-new", Status::Unread, 60, None, 0),
            row("snoozed-sooner", Status::Unread, 5, Some(700), 0),
            row("idle-new", Status::Stopped, 10, None, 300),
        ];
        rows.sort_by(inbox_order);
        let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
        // Needs you the longest wait first, errors with them; Your turn the newest first; a
        // running session stays in Working though snoozed; snoozed ones the soonest back first.
        assert_eq!(keys, ["error-old", "needs-new", "turn-new", "turn-old", "working", "snoozed-sooner", "snoozed-later", "idle-new", "idle-old"]);
        assert_eq!(rows[4].section, InboxSection::Working);
    }
}

#[cfg(test)]
mod project_tests {
    use super::*;

    fn slugs(s: &[&str]) -> Vec<String> {
        s.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn projects_line_up_by_repo_then_by_name() {
        // What the Macs send, the first Mac's lanes first.
        let lanes = [
            ("Codealong", slugs(&["codealong/codealong"])),
            ("Garden", slugs(&[])),
            ("Elsewhere", slugs(&["someone/scratch"])),
            ("Work", slugs(&["acme/app"])),
            ("App", slugs(&["acme/app"])),
            ("garden", slugs(&[])),
        ];
        let p = Projects::new(lanes.iter().map(|(n, s)| (*n, s.clone())));
        // The second Mac's worktree of a repo goes where the first Mac has it, even from no project.
        assert_eq!(p.of("Elsewhere", &slugs(&["codealong/codealong"])).as_deref(), Some("Codealong"));
        assert_eq!(p.of("App", &slugs(&["acme/app"])).as_deref(), Some("Work"));
        // A repo by the name GitHub gives it now lines up too.
        assert_eq!(p.of("Elsewhere", &slugs(&["old/name", "acme/app"])).as_deref(), Some("Work"));
        // No repo in common: a project of the same name, spelled as the first Mac spells it.
        assert_eq!(p.of("garden", &[]).as_deref(), Some("Garden"));
        // In no project on any Mac.
        assert_eq!(p.of("Elsewhere", &slugs(&["someone/scratch"])), None);
        assert_eq!(p.of("Elsewhere", &[]), None);
    }

    #[test]
    fn projects_list_by_name_with_elsewhere_last() {
        let names = ["garden", "Elsewhere", "Codealong", "Garden", "Codealong", "api"];
        assert_eq!(project_list(names.into_iter()), ["api", "Codealong", "garden", "Garden", "Elsewhere"]);
    }
}

#[cfg(test)]
mod start_tests {
    use super::*;

    fn account(places: &[api::Place], chosen: Option<api::Place>) -> api::StartAccount {
        api::StartAccount {
            name: "claude".into(),
            harness: codealong_peer::model::Harness::Claude,
            places: places.iter().map(|p| api::PlaceOption { place: *p, label: p.word().into(), behind: false, service: false }).collect(),
            chosen,
            unavailable: None,
            default_model: None,
            preferred: false,
            models: vec![],
            efforts: vec![],
            worktree: false,
            resumes: vec![],
            switches_model: false,
            switches_effort: false,
            switches_mid_turn: false,
            switches_in_app: false,
            usage_cap: None,
            buffer: None,
        }
    }

    #[test]
    fn a_start_from_the_phone_goes_where_nobody_needs_to_be_at_the_mac() {
        use api::Place::*;
        let at = |places: &[api::Place], chosen| start_place(&account(places, chosen), places);
        assert_eq!(at(&[Terminal, Background, ClaudeApp, Codealong], Some(Terminal)).as_deref(), Some("codealong"));
        assert_eq!(at(&[Terminal, Background], None).as_deref(), Some("background"));
        assert_eq!(at(&[CodexApp, Terminal], Some(Terminal)).as_deref(), Some("terminal"));
        assert_eq!(at(&[CodexApp, Terminal], None).as_deref(), Some("codex-app"));
        assert_eq!(at(&[], None), None);
        // A background that's a terminal behind the Mac's windows is a terminal all the same.
        let mut behind = account(&[Terminal, Background], Some(Terminal));
        behind.places[1].behind = true;
        assert_eq!(start_place(&behind, &[Terminal, Background]).as_deref(), Some("terminal"));
    }

    #[test]
    fn older_macs_list_claude_codes_models_alone() {
        let mut claude = account(&[api::Place::Terminal, api::Place::Background, api::Place::Codealong], None);
        claude.resumes = vec![api::Place::Terminal, api::Place::Background, api::Place::Codealong];
        let mut codex = account(&[api::Place::Terminal], None);
        codex.name = "codex".into();
        codex.harness = Harness::Codex;
        codex.models = vec![api::ModelOption { id: "gpt-5.5".into(), label: "GPT-5.5".into() }];
        let o = api::StartOptions { accounts: vec![claude, codex], codex_projects: vec![], claude_models: vec![api::ModelOption { id: "opus".into(), label: "Opus".into() }], claude_efforts: vec![], groups: vec![], auto_group: String::new() };
        let c = start_choices(o);
        // A Mac that lists no models for Claude Code's account lists them for all of Claude Code.
        assert_eq!((c.accounts[0].models[0].id.as_str(), c.accounts[0].worktree), ("opus", true));
        assert_eq!((c.accounts[1].models[0].id.as_str(), c.accounts[1].worktree), ("gpt-5.5", false));
        assert_eq!(c.accounts[0].resumes.iter().map(|p| p.id.as_str()).collect::<Vec<_>>(), ["terminal", "background", "codealong"]);
        // A start from the phone goes to Codealong; a session going on stays its harness's.
        assert_eq!((c.accounts[0].place.as_deref(), c.accounts[0].resume.as_deref()), (Some("codealong"), Some("background")));
        assert!(c.accounts[1].resumes.is_empty() && c.accounts[1].resume.is_none());
    }
}

/// What a Mac's refusal of a request it doesn't know (`doesn't know how to …`, as every Mac since
/// 2026-09-29 says it) means here: its Codealong is older than the phone's.
fn older_mac(e: String, client: &Client, device: &str, to: &str) -> String {
    if !e.contains("doesn't know how to") {
        return e;
    }
    let name = client.devices().into_iter().find(|d| d.key == device || d.short == device).map(|d| d.name).unwrap_or_else(|| "that Mac".into());
    format!("Update Codealong on {name} to {to}.")
}
