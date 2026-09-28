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
use codealong_peer::model::{Session, Status as PeerStatus};
use codealong_peer::{net, proto};

uniffi::setup_scaffolding!();

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
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub devices: Vec<DeviceRow>,
    /// Most urgent first, then the one you last sent a prompt, as the Mac's board sorts them.
    pub sessions: Vec<SessionRow>,
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
            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0);
            let mut devices = Vec::new();
            let mut sessions: Vec<(SessionRow, u8)> = Vec::new();
            for (d, replica) in feeds {
                let mut count = 0;
                let mut seen = std::collections::HashSet::new();
                // A session shows under every lane it worked in; its own lane lists it without a
                // visitor note, so that one goes first.
                let mut all: Vec<(&codealong_peer::model::Lane, &Session)> = replica.lanes.iter().flat_map(|l| l.sessions.iter().map(move |s| (l, s))).collect();
                all.sort_by_key(|(_, s)| s.visitor.is_some());
                for (lane, s) in all {
                    if s.archived || !seen.insert(s.key.as_str()) {
                        continue;
                    }
                    let urgent = matches!(s.status, PeerStatus::Needs | PeerStatus::Error | PeerStatus::Working | PeerStatus::Unread);
                    // Worktrees in no project stay off the Mac's board unless they need you.
                    if lane.hidden && !matches!(s.status, PeerStatus::Needs | PeerStatus::Error) {
                        continue;
                    }
                    if !urgent && now - s.last_prompt_at > RECENT_MS {
                        continue;
                    }
                    count += 1;
                    sessions.push((
                        SessionRow {
                            key: remote_key(&d.short, &s.key),
                            device: d.key.clone(),
                            device_name: d.name.clone(),
                            device_online: d.online,
                            title: s.title.clone(),
                            headline: s.headline.clone(),
                            detail: s.detail.clone(),
                            status: s.status.into(),
                            stalled: s.stalled_since.is_some(),
                            harness: s.harness.word().to_string(),
                            account: s.account.clone(),
                            project: lane.project.clone(),
                            repo: lane.repo.clone(),
                            worktree: lane.callsign.clone(),
                            branch: s.branch.clone().or_else(|| lane.branch.clone()),
                            last_prompt_at: s.last_prompt_at,
                            last_activity: s.last_activity,
                            status_since: s.status_since,
                        },
                        urgency(s.status),
                    ));
                }
                devices.push(DeviceRow {
                    key: d.key.clone(),
                    short: d.short.clone(),
                    name: d.name.clone(),
                    online: d.online,
                    remote_control: d.remote_control,
                    last_seen: d.last_seen,
                    linked_back: d.linked_back,
                    loading: d.loading,
                    sessions: count,
                });
            }
            sessions.sort_by(|(a, ua), (b, ub)| ua.cmp(ub).then(b.last_prompt_at.cmp(&a.last_prompt_at)).then(b.last_activity.cmp(&a.last_activity)));
            Snapshot { devices, sessions: sessions.into_iter().map(|(s, _)| s).collect() }
        })
    }
}

/// How urgent a status is, as the Mac's board ranks it (board.rs `urgency`): idle and stopped
/// rank the same, since a Codex thread is never stopped.
fn urgency(s: PeerStatus) -> u8 {
    match s {
        PeerStatus::Needs => 0,
        PeerStatus::Error => 1,
        PeerStatus::Working => 2,
        PeerStatus::Unread => 3,
        PeerStatus::Idle | PeerStatus::Stopped => 4,
    }
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
        Ok(self.client.pending(&self.device, &self.key)?.map(|p| Pending { id: p.id, label: p.label, input: p.input, cannot: p.cannot }))
    }

    /// Allows or denies the tool call `id`, if it's still the one the session waits on.
    pub fn answer(&self, id: String, allow: bool) -> Result<String, CoreError> {
        Ok(self.client.answer(&self.device, &self.key, &id, if allow { api::Answer::Allow } else { api::Answer::Deny })?)
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
