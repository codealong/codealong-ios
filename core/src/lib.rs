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

mod md;
mod quick;
pub use md::*;
pub use quick::*;

/// Changes reach Swift at most this often: a busy Mac sends a feed a second, and each can come
/// with several connections' worth of changes.
const COALESCE: Duration = Duration::from_millis(150);
/// Sessions that are idle or stopped show for this long after their last prompt.
const RECENT_MS: i64 = 3 * 24 * 60 * 60 * 1000;
/// Pages read back past the oldest shown, looking for the prompt behind it, before giving up, as
/// the Mac's panel does.
const LOOK_BACK: usize = 16;

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
    /// Its turn is running and its Mac can stop it: what the harness's own Stop sends, or Escape
    /// in its terminal.
    pub stoppable: bool,
    /// Its turn is running and a message can reach the agent in that turn at once (Send now).
    pub steerable: bool,
    /// The model it's on, as its harness names it, where its Mac says.
    pub model: Option<String>,
    /// The name you gave it, where its harness keeps one.
    pub name: Option<String>,
    /// The session it came from, when its harness or Codealong wrote that down.
    pub origin: Option<SessionOrigin>,
    /// Its last turn ended on its account's usage limit and nothing has been said since: what that
    /// comes to, in a sentence or two, with `{in:<ms>}` for when it lifts.
    pub limit: Option<String>,
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

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub devices: Vec<DeviceRow>,
    /// In the inbox's order (`inbox_order`).
    pub sessions: Vec<SessionRow>,
    /// The projects those sessions are in, lined up across Macs (`Projects`): by name, with
    /// worktrees in no project last, as the Mac lists them.
    pub projects: Vec<String>,
}

#[derive(uniffi::Object)]
pub struct Core {
    client: Client,
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
        Ok(Arc::new(Core { client }))
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

    /// A session's conversation, to page through and follow (`Conversation`).
    pub fn conversation(&self, key: String) -> Result<Arc<Conversation>, CoreError> {
        let (device, own) = split_remote(&key).ok_or_else(|| CoreError::Failed("That isn't a session on one of your Macs.".into()))?;
        Ok(Arc::new(Conversation { client: self.client.clone(), device: device.to_string(), key: own.to_string(), st: Mutex::new(Thread::default()) }))
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

    /// Archives a session, or brings it back, on the Mac it's on.
    pub fn archive(&self, key: String, archived: bool) -> Result<(), CoreError> {
        let (device, own) = split_remote(&key).ok_or_else(|| CoreError::Failed("That isn't a session on one of your Macs.".into()))?;
        Ok(self.client.archive(device, own, archived)?)
    }

    pub fn unlink(&self, device: String) -> Result<(), CoreError> {
        Ok(self.client.unlink(&device)?)
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
                    sessions: all.iter().filter(|s| s.device == d.key && in_inbox(s, now)).count() as u32,
                });
            }
            let mut sessions: Vec<SessionRow> = all.into_iter().filter(|s| in_inbox(s, now)).collect();
            sessions.sort_by(inbox_order);
            let projects = project_list(sessions.iter().map(|s| s.project.as_str()));
            Snapshot { devices, sessions, projects }
        })
    }
}

pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

type Feeds<'a> = [(codealong_peer::client::Device, &'a codealong_peer::feed::Replica)];

/// Whether the inbox lists a session: what wants you or is running, and the rest for three days
/// after you last prompted them.
fn in_inbox(s: &SessionRow, now: i64) -> bool {
    matches!(s.status, Status::Needs | Status::Error | Status::Working | Status::Unread) || now - s.last_prompt_at <= RECENT_MS
}

/// Every session on the linked Macs once, archived ones left out, in the projects the Macs line
/// up; unsorted.
pub(crate) fn all_rows(feeds: &Feeds) -> Vec<SessionRow> {
    let now = now_ms();
    let projects = Projects::of_feeds(feeds);
    let mut sessions = Vec::new();
    for (d, replica) in feeds {
        let titles: std::collections::HashMap<&str, &str> = replica.lanes.iter().flat_map(|l| l.sessions.iter()).map(|s| (s.key.as_str(), s.title.as_str())).collect();
        let mut seen = std::collections::HashSet::new();
        // A session shows under every lane it worked in; its own lane lists it without a
        // visitor note, so that one goes first.
        let mut all: Vec<(&Lane, &Session)> = replica.lanes.iter().flat_map(|l| l.sessions.iter().map(move |s| (l, s))).collect();
        all.sort_by_key(|(_, s)| s.visitor.is_some());
        for (lane, s) in all {
            if s.archived || !seen.insert(s.key.as_str()) {
                continue;
            }
            // Worktrees in no project stay off the Mac's board unless they need you, and
            // off here unless another Mac has their repo in a project.
            let project = projects.lane(lane);
            if lane.hidden && project.is_none() && !matches!(s.status, PeerStatus::Needs | PeerStatus::Error) {
                continue;
            }
            let status: Status = s.status.into();
            let snoozed_until = s.snoozed_until.filter(|&t| t > now && status != Status::Working);
            sessions.push(SessionRow {
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
                branch: s.branch.clone().or_else(|| lane.branch.clone()),
                last_prompt_at: s.last_prompt_at,
                last_activity: s.last_activity,
                status_since: s.status_since,
                hosted: s.hosted,
                section: section(status, snoozed_until),
                snoozed_until,
                started_at: s.started_at,
                live: s.live,
                in_app: s.surface == codealong_peer::model::Surface::App,
                asks: s.asks,
                pr: lane.pr.as_ref().map(|p| format!("#{} {}", p.number, p.title)),
                // Macs before 2026-09-29 don't say, and stop only the sessions Codealong runs.
                stoppable: s.stoppable || (s.hosted && status == Status::Working),
                steerable: s.steerable,
                model: s.model.clone(),
                name: s.name.clone(),
                origin: s.origin.as_ref().map(|o| SessionOrigin { key: remote_key(&d.short, &o.key), title: titles.get(o.key.as_str()).map(|t| t.to_string()), fork: o.how == OriginHow::Fork }),
                limit: s.limit.as_ref().filter(|_| status != Status::Working).map(|l| limit_words(&s.account, l, now)),
            });
        }
    }
    sessions
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
    let when = match limit.resets_at {
        _ if lifted => " It has lifted since: send it something to go on.".to_string(),
        Some(t) => format!(" It lifts {{in:{t}}}."),
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
fn project_list<'a>(names: impl Iterator<Item = &'a str>) -> Vec<String> {
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
/// Mac (SessionsView.tsx `snoozedApart`).
fn section(status: Status, snoozed_until: Option<i64>) -> InboxSection {
    match (status, snoozed_until) {
        (Status::Working, _) => InboxSection::Working,
        (_, Some(_)) => InboxSection::Snoozed,
        (Status::Needs | Status::Error, None) => InboxSection::NeedsYou,
        (Status::Unread, None) => InboxSection::YourTurn,
        (Status::Idle | Status::Stopped, None) => InboxSection::Recent,
    }
}

/// The inbox's order, the Mac's Sessions view's (SessionsView.tsx `timeSections`): section by
/// section, Needs you the longest wait first, so a new one can't keep pushing an old one down;
/// Your turn and Working, which read as a feed, the newest status first; snoozed ones the soonest
/// back first; the rest by the one you last sent a prompt. A status's time doesn't move while it
/// lasts, so rows hold their places, and send and next goes down the list as it reads.
fn inbox_order(a: &SessionRow, b: &SessionRow) -> std::cmp::Ordering {
    let since = |s: &SessionRow| s.status_since.unwrap_or(s.last_activity);
    let rank = |s: &SessionRow| s.section as u8;
    rank(a)
        .cmp(&rank(b))
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
}

/// One thing said or done in a session. A tool call carries its output once it's in: the Mac
/// records a result as a line of its own, and the conversation puts the two together.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Item {
    /// Unique in the session.
    pub id: String,
    pub at: i64,
    pub kind: ItemKind,
    /// Prose for you, the agent and notes (Markdown); a one-line label for a tool call.
    pub text: String,
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

/// A session's conversation as far as it's been read: a page back from the newest, older pages
/// as you scroll up, and what came after as the session goes on. Each call returns the whole of
/// it, oldest first, for the list to show as is.
#[derive(uniffi::Object)]
pub struct Conversation {
    client: Client,
    device: String,
    key: String,
    st: Mutex<Thread>,
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
        self.items
            .iter()
            .filter_map(|i| {
                let kind = match i.kind.as_str() {
                    "you" => ItemKind::You,
                    "agent" => ItemKind::Agent,
                    "tool" => ItemKind::Tool,
                    "note" => ItemKind::Note,
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
                    input: i.input.clone(),
                    output: result.and_then(|r| r.output.clone()).or_else(|| i.output.clone()),
                    failed: i.failed || result.is_some_and(|r| r.failed),
                    withdrawn: i.withdrawn,
                    questions: i.questions.iter().map(|q| question_of(q, answers)).collect(),
                    link: i.link.as_ref().or(result.and_then(|r| r.link.as_ref())).map(|l| WebLink { url: l.url.clone(), title: l.title.clone(), note: l.note.clone() }),
                })
            })
            .collect()
    }
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
        input: None,
        output: None,
        failed: false,
        withdrawn: i.withdrawn,
        questions: Vec::new(),
        link: None,
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
        st.take(page, false);
        Ok(st.shown())
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
        Ok(st.shown())
    }

    /// Your prompt behind the oldest item read so far, when what's read doesn't start with one: a
    /// long turn can write more than a page, and what you asked stays pinned over its reply. Reads
    /// back a page at a time, keeping the pages for scrolling up, and gives up after `LOOK_BACK`.
    pub fn prompt_before(&self) -> Result<Option<Item>, CoreError> {
        let before = self.st.lock().unwrap_or_else(|e| e.into_inner()).before;
        look_back(before, |at| {
            let kept = self.st.lock().unwrap_or_else(|e| e.into_inner()).read_back.get(&at).cloned();
            let page = match kept {
                Some(page) => page,
                None => self.client.page(&self.device, &self.key, Some(at))?,
            };
            self.st.lock().unwrap_or_else(|e| e.into_inner()).read_back.insert(at, page.clone());
            Ok(page)
        })
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
    pub fn watch(&self) -> bool {
        self.client.watch(&self.device, std::slice::from_ref(&self.key))
    }

    /// No more of its reply as it's written: it's not shown any more.
    pub fn unwatch(&self) {
        self.client.watch(&self.device, &[]);
    }

    /// The reply it's writing now, if it's taking a turn and the Mac sends it.
    pub fn live(&self) -> Option<Live> {
        self.client.stream(&self.device, &self.key).map(|s| Live { text: s.text, tool: s.tool })
    }

    /// Stops the turn it's taking (one whose row says `stoppable`; needs remote control there).
    /// Says what happened.
    pub fn stop(&self) -> Result<String, CoreError> {
        Ok(self.client.cancel(&self.device, &self.key)?.unwrap_or_else(|| "Stopped.".into()))
    }

    /// Sends the session a prompt, where it runs on its Mac; with `now`, into the turn it's taking
    /// at once (one whose row says `steerable`). Says how it went.
    pub fn send(&self, text: String, now: bool) -> Result<String, CoreError> {
        let sent = self.client.send(&self.device, &self.key, &text, now)?;
        Ok(sent.message)
    }

    /// How a message sent to it would reach it, as its Mac says; None for one Codealong runs, and
    /// from Macs before 2026-09-30, which don't say.
    pub fn way(&self) -> Option<Way> {
        self.client.way(&self.device, &self.key).ok().flatten().map(Way::from)
    }

    /// Goes on with it where `place` says (one of its account's `resumes`), on `model` and
    /// `effort` where that place takes them, on `prompt`. Says how it went, as a send does.
    pub fn resume(&self, place: String, model: Option<String>, effort: Option<String>, prompt: String) -> Result<String, CoreError> {
        let place = api::Place::from_word(&place).ok_or_else(|| CoreError::Failed(format!("{place} isn't a place a session can go on in.")))?;
        let takes = place_takes_model(place);
        let resume = api::ResumeIn { place, model: model.filter(|_| takes), effort: effort.filter(|_| takes) };
        Ok(self.client.resume(&self.device, &self.key, resume, &prompt)?.message)
    }

    /// Switches it, while it runs, to another of its account's models, for it alone. Says what
    /// happened.
    pub fn switch_model(&self, model: String) -> Result<String, CoreError> {
        Ok(self.client.switch_model(&self.device, &self.key, &model)?)
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
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(kind: &str, cursor: u64, id: Option<&str>, output: Option<&str>) -> api::Item {
        api::Item { at: cursor as i64, kind: kind.into(), text: format!("{kind} {cursor}"), id: id.map(String::from), input: None, output: output.map(String::from), failed: false, withdrawn: false, questions: vec![], answers: Default::default(), link: None, cursor, n: 0 }
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
    fn the_reply_box_says_how_a_message_gets_there() {
        let mut s = Session::new(Harness::Claude, "claude2", "abc");
        s.live = true;
        assert_eq!(placeholder(&s, Some(&Way::Typed { app: "Ghostty".into() }), None), "Send to claude2 via Ghostty");
        s.status = PeerStatus::Working;
        assert_eq!(placeholder(&s, Some(&Way::Background), None), "Send to claude2 via its background job: it takes this in as it works");
        s.asks = true;
        s.status = PeerStatus::Needs;
        assert_eq!(placeholder(&s, Some(&Way::Message), None), "Answer claude2 as a message from Codealong");
        // Not running, it goes on where it's picked to, else in the terminal its Mac said.
        let (mut off, ghostty) = (Session::new(Harness::Claude, "claude", "def"), Way::Resume { app: "Ghostty".into() });
        assert_eq!(placeholder(&off, Some(&ghostty), None), "Send to claude: it isn\u{2019}t running, so this resumes it in Ghostty");
        assert_eq!(placeholder(&off, Some(&ghostty), Some((api::Place::Background, false))), "Send to claude: it isn\u{2019}t running, so this resumes it in the background");
        assert_eq!(placeholder(&off, Some(&ghostty), Some((api::Place::Codealong, false))), "Send to claude: it isn\u{2019}t running, so Codealong runs it from now on");
        // A Mac that doesn't say: as its state suggests.
        assert_eq!(placeholder(&off, None, None), "Send to claude: it isn\u{2019}t running, so this resumes it in a terminal");
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
        let limit = SessionLimit { meter: Some("session".into()), resets_at: Some(5_000), spend_capped: false, at: 1, move_to: Some("claude2".into()), model: None };
        assert_eq!(limit_words("claude", &limit, 1_000), "It stopped at claude\u{2019}s 5-hour limit. It lifts {in:5000}. claude2 has room: move it there on its Mac to go on now.");
        assert_eq!(limit_words("claude", &limit, 9_000), "It stopped at claude\u{2019}s 5-hour limit. It has lifted since: send it something to go on.");
        let week = SessionLimit { meter: Some("model:Opus".into()), resets_at: None, spend_capped: true, move_to: None, ..limit };
        assert_eq!(limit_words("claude", &week, 1_000), "It stopped at claude\u{2019}s weekly Opus limit, with no extra usage to carry it. No other account has room.");
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
    /// Codealong's own chats: a session started here gets a folder of its own, in no project.
    pub chat: bool,
    /// What it holds, for a worktree that takes one piece of work after another; none for one
    /// kept for a single piece of work.
    pub reuse: Option<WorktreeReuse>,
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
                chat: l.starts_chats,
                reuse: l.reuse.map(|r| match r {
                    Reuse::Free => WorktreeReuse::Free,
                    Reuse::Open => WorktreeReuse::Open,
                    Reuse::Review => WorktreeReuse::Review,
                    Reuse::Landed => WorktreeReuse::Landed,
                }),
            })
        })
        .collect();
    out.sort_by(|a, b| b.last_activity.cmp(&a.last_activity));
    out
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

/// The worktree new work starts in on a Mac, in `project` (empty for any), unless you pick one:
/// in the most recently active repo, where new work goes from its latest worktree
/// (`new_work_in`), else its main checkout, as the Mac's panel picks one; else the latest
/// worktree. `worktrees` are one Mac's, most recently active first.
fn start_worktree(worktrees: &[Worktree], project: &str) -> Option<Worktree> {
    let here: Vec<&Worktree> = worktrees.iter().filter(|w| !w.chat && (project.is_empty() || w.project == project)).collect();
    let latest = *here.first()?;
    let picked = new_work_in(latest, 0.0, worktrees, &[]).or_else(|| here.iter().copied().find(|w| w.repo == latest.repo && w.project == latest.project && w.main));
    Some(picked.unwrap_or(latest).clone())
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
        let spec = api::StartSpec { lane_id: worktree, account, place, prompt, model: model.filter(|_| takes), effort: effort.filter(|_| takes), worktree: new_worktree, todos: Vec::new(), from: None };
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
    pub fn reply_placeholder(&self, key: String, way: Option<Way>, resume_place: Option<String>, behind: bool) -> String {
        let Some((device, own)) = split_remote(&key) else { return "Reply".into() };
        let resuming = resume_place.as_deref().and_then(api::Place::from_word).map(|p| (p, behind));
        self.client.with_feeds(|feeds| {
            let session = feeds.iter().filter(|(d, _)| d.short == device || d.key == device).flat_map(|(_, r)| r.lanes.iter().flat_map(|l| l.sessions.iter())).find(|s| s.key == own);
            session.map_or_else(|| "Reply".into(), |s| placeholder(s, way.as_ref(), resuming))
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

/// What a session's reply box says before you write, as the Mac's does (SessionReply.tsx
/// `replyPlaceholder`): who it goes to, and how it gets there, as its Mac said (`way`), or, from
/// a Mac that doesn't say, as its state suggests. A session that isn't running goes on where
/// `resuming` says, else in a terminal.
fn placeholder(s: &Session, way: Option<&Way>, resuming: Option<(api::Place, bool)>) -> String {
    let to = if s.asks { format!("Answer {}", s.account) } else { format!("Send to {}", s.account) };
    let busy = matches!(s.status, PeerStatus::Working | PeerStatus::Needs);
    if s.hosted {
        return if busy { format!("{to}: it takes this after its current turn") } else { to };
    }
    let working = if s.status == PeerStatus::Working { ": it takes this in as it works" } else { "" };
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
        None if s.harness == Harness::Antigravity && s.surface == Surface::App => format!("{to}: Antigravity on its Mac comes forward with this on the clipboard"),
        None if !s.live && s.harness == Harness::Claude && s.surface == Surface::App => format!("{to}: {off} {}", resume_words(api::Place::ClaudeApp, "", false)),
        None if !s.live && s.surface == Surface::Cli && matches!(s.harness, Harness::Claude | Harness::Codex | Harness::Antigravity) => format!("{to}: {off} this resumes it in a terminal"),
        None => format!("{to}{working}"),
    }
}

#[cfg(test)]
mod order_tests {
    use super::*;

    fn row(key: &str, status: Status, since: i64, snoozed_until: Option<i64>, last_prompt_at: i64) -> SessionRow {
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
            branch: None,
            last_prompt_at,
            last_activity: since,
            status_since: Some(since),
            hosted: false,
            section: section(status, snoozed_until),
            snoozed_until,
            started_at: None,
            live: true,
            in_app: false,
            asks: false,
            pr: None,
            stoppable: false,
            steerable: false,
            model: None,
            name: None,
            origin: None,
            limit: None,
        }
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
            ("Kestrel", slugs(&[])),
            ("Elsewhere", slugs(&["someone/scratch"])),
            ("Work", slugs(&["acme/app"])),
            ("App", slugs(&["acme/app"])),
            ("kestrel", slugs(&[])),
        ];
        let p = Projects::new(lanes.iter().map(|(n, s)| (*n, s.clone())));
        // The second Mac's worktree of a repo goes where the first Mac has it, even from no project.
        assert_eq!(p.of("Elsewhere", &slugs(&["codealong/codealong"])).as_deref(), Some("Codealong"));
        assert_eq!(p.of("App", &slugs(&["acme/app"])).as_deref(), Some("Work"));
        // A repo by the name GitHub gives it now lines up too.
        assert_eq!(p.of("Elsewhere", &slugs(&["old/name", "acme/app"])).as_deref(), Some("Work"));
        // No repo in common: a project of the same name, spelled as the first Mac spells it.
        assert_eq!(p.of("kestrel", &[]).as_deref(), Some("Kestrel"));
        // In no project on any Mac.
        assert_eq!(p.of("Elsewhere", &slugs(&["someone/scratch"])), None);
        assert_eq!(p.of("Elsewhere", &[]), None);
    }

    #[test]
    fn projects_list_by_name_with_elsewhere_last() {
        let names = ["kestrel", "Elsewhere", "Codealong", "Kestrel", "Codealong", "api"];
        assert_eq!(project_list(names.into_iter()), ["api", "Codealong", "kestrel", "Kestrel", "Elsewhere"]);
    }
}

#[cfg(test)]
mod start_tests {
    use super::*;

    fn account(places: &[api::Place], chosen: Option<api::Place>) -> api::StartAccount {
        api::StartAccount {
            name: "claude".into(),
            harness: codealong_peer::model::Harness::Claude,
            places: places.iter().map(|p| api::PlaceOption { place: *p, label: p.word().into(), behind: false }).collect(),
            chosen,
            unavailable: None,
            default_model: None,
            preferred: false,
            models: vec![],
            efforts: vec![],
            worktree: false,
            resumes: vec![],
            switches_model: false,
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
        let o = api::StartOptions { accounts: vec![claude, codex], codex_projects: vec![], claude_models: vec![api::ModelOption { id: "opus".into(), label: "Opus".into() }], claude_efforts: vec![] };
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
