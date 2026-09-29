//! The phone app's core, over codealong-peer's client: it links with Macs by their link codes,
//! keeps each one's feed, and hands the Swift side what it shows as plain records, already sorted,
//! so Swift never parses JSON or re-derives a rule. What a session says (its headline, its detail)
//! was worked out by the Mac it's on and comes in its feed as is.

use std::fmt;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use codealong_peer::api;
use codealong_peer::client::Client;
use codealong_peer::feed::{remote_key, split_remote};
use codealong_peer::model::{Lane, Session, Status as PeerStatus, ELSEWHERE};
use codealong_peer::{net, proto};

uniffi::setup_scaffolding!();

mod quick;
pub use quick::*;

/// Changes reach Swift at most this often: a busy Mac sends a feed a second, and each can come
/// with several connections' worth of changes.
const COALESCE: Duration = Duration::from_millis(150);
/// Sessions that are idle or stopped show for this long after their last prompt.
const RECENT_MS: i64 = 3 * 24 * 60 * 60 * 1000;

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
            });
        }
    }
    sessions
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
    pub input: Option<String>,
    pub output: Option<String>,
    pub failed: bool,
}

/// A tool call the session waits on you to allow.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Pending {
    pub id: String,
    pub label: String,
    pub input: Option<String>,
    /// Why it can't be answered from here, when it can't.
    pub cannot: Option<String>,
    /// It can be allowed from now on too (`Choice::Always`).
    pub always: bool,
    /// It's a plan to approve: `input` is the plan, in Markdown, to read as prose.
    pub plan: bool,
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
                let result = (kind == ItemKind::Tool).then(|| i.id.as_deref().and_then(|id| results.get(id))).flatten();
                Some(Item {
                    id: format!("{}:{}", i.cursor, i.n),
                    at: i.at,
                    kind,
                    text: i.text.clone(),
                    input: i.input.clone(),
                    output: result.and_then(|r| r.output.clone()).or_else(|| i.output.clone()),
                    failed: i.failed || result.is_some_and(|r| r.failed),
                })
            })
            .collect()
    }
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
        let page = self.client.page(&self.device, &self.key, Some(before))?;
        let mut st = self.st.lock().unwrap_or_else(|e| e.into_inner());
        st.take(page, true);
        Ok(st.shown())
    }

    /// There's more before the oldest read so far.
    pub fn has_older(&self) -> bool {
        self.st.lock().unwrap_or_else(|e| e.into_inner()).before.is_some()
    }

    pub fn pending(&self) -> Result<Option<Pending>, CoreError> {
        Ok(self.client.pending(&self.device, &self.key)?.map(|p| Pending { id: p.id, label: p.label, input: p.input, cannot: p.cannot, always: p.always, plan: p.plan }))
    }

    /// Answers the tool call `id`, if it's still the one the session waits on.
    pub fn answer(&self, id: String, choice: Choice) -> Result<String, CoreError> {
        let answer = match choice {
            Choice::Allow => api::Answer::Allow,
            Choice::Always => api::Answer::Always,
            Choice::Deny => api::Answer::Deny,
        };
        Ok(self.client.answer(&self.device, &self.key, &id, answer)?)
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

    /// Stops the turn it's taking (a session Codealong runs; needs remote control there).
    pub fn stop(&self) -> Result<(), CoreError> {
        Ok(self.client.cancel(&self.device, &self.key)?)
    }

    /// Sends the session a prompt, where it runs on its Mac. Says how it went.
    pub fn send(&self, text: String) -> Result<String, CoreError> {
        let sent = self.client.send(&self.device, &self.key, &text)?;
        Ok(sent.message)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(kind: &str, cursor: u64, id: Option<&str>, output: Option<&str>) -> api::Item {
        api::Item { at: cursor as i64, kind: kind.into(), text: format!("{kind} {cursor}"), id: id.map(String::from), input: None, output: output.map(String::from), failed: false, cursor, n: 0 }
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
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct StartPlace {
    /// As the Mac names it: `terminal`, `background`, `claude-app`, `codex-app`, `codealong`.
    pub id: String,
    pub label: String,
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
            if l.hidden && project.is_none() {
                return None;
            }
            Some(Worktree {
                id: l.id.clone(),
                project: project.unwrap_or_else(|| l.project.clone()),
                repo: l.repo.clone(),
                name: l.callsign.clone(),
                branch: l.branch.clone(),
                last_activity: l.last_activity,
                device: d.key.clone(),
                main: l.origin == codealong_peer::model::Origin::Main,
            })
        })
        .collect();
    out.sort_by(|a, b| b.last_activity.cmp(&a.last_activity));
    out
}

/// Where a start from the phone goes unless you pick another: somewhere that needs nobody at the
/// Mac, since a locked Mac opens no terminal. Codealong itself (over ACP) first, then Claude Code's
/// background service, then where the account usually starts.
fn start_place(a: &api::StartAccount) -> Option<String> {
    let has = |p: api::Place| a.places.iter().any(|o| o.place == p);
    [api::Place::Codealong, api::Place::Background].into_iter().find(|p| has(*p)).or(a.chosen.filter(|p| has(*p))).or_else(|| a.places.first().map(|o| o.place)).map(|p| p.word().to_string())
}

#[uniffi::export]
impl Core {
    /// A Mac's worktrees from its feed, most recently active first, in their projects as the
    /// inbox lines them up; worktrees in no project stay off, as on its board.
    pub fn worktrees(&self, device: String) -> Vec<Worktree> {
        self.client.with_feeds(|feeds| all_worktrees(feeds).into_iter().filter(|w| w.device == device).collect())
    }

    /// What `device` can start, asked of it.
    pub fn start_choices(&self, device: String) -> Result<StartChoices, CoreError> {
        let o = self.client.start_options(&device)?;
        Ok(StartChoices {
            accounts: o
                .accounts
                .iter()
                .map(|a| StartAccount {
                    name: a.name.clone(),
                    harness: a.harness.word().to_string(),
                    places: a.places.iter().map(|p| StartPlace { id: p.place.word().to_string(), label: p.label.clone() }).collect(),
                    place: start_place(a),
                    unavailable: a.unavailable.clone(),
                    default_model: a.default_model.clone(),
                    preferred: a.preferred,
                })
                .collect(),
            models: o.claude_models.into_iter().map(|m| StartModel { id: m.id, label: m.label }).collect(),
        })
    }

    /// Starts a session on `device` in `worktree` (its id there), on `account`, at `place`; with
    /// `new_worktree`, Claude Code makes a worktree of its own for it from that one's repo.
    pub fn start_session(&self, device: String, worktree: String, account: String, place: String, prompt: String, model: Option<String>, new_worktree: bool) -> Result<StartedSession, CoreError> {
        let place = api::Place::from_word(&place).ok_or_else(|| CoreError::Failed(format!("{place} isn't a place a session can start.")))?;
        let spec = api::StartSpec { lane_id: worktree, account, place, prompt, model, effort: None, worktree: new_worktree, todos: Vec::new() };
        let started = self.client.start_session(&device, &spec)?;
        let short = device.get(..10).unwrap_or(&device);
        Ok(StartedSession { key: started.key.map(|k| remote_key(short, &k)), message: started.message })
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
            places: places.iter().map(|p| api::PlaceOption { place: *p, label: p.word().into() }).collect(),
            chosen,
            unavailable: None,
            default_model: None,
            preferred: false,
        }
    }

    #[test]
    fn a_start_from_the_phone_goes_where_nobody_needs_to_be_at_the_mac() {
        use api::Place::*;
        assert_eq!(start_place(&account(&[Terminal, Background, ClaudeApp, Codealong], Some(Terminal))).as_deref(), Some("codealong"));
        assert_eq!(start_place(&account(&[Terminal, Background], None)).as_deref(), Some("background"));
        assert_eq!(start_place(&account(&[CodexApp, Terminal], Some(Terminal))).as_deref(), Some("terminal"));
        assert_eq!(start_place(&account(&[CodexApp, Terminal], None)).as_deref(), Some("codex-app"));
        assert_eq!(start_place(&account(&[], None)), None);
    }
}
