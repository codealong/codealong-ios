//! The phone app's core, over codealong-peer's client: it links with Macs by their link codes,
//! keeps each one's feed, and hands the Swift side what it shows as plain records, already sorted,
//! so Swift never parses JSON or re-derives a rule. What a session says (its headline, its detail)
//! was worked out by the Mac it's on and comes in its feed as is.

use std::fmt;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use codealong_peer::client::Client;
use codealong_peer::feed::remote_key;
use codealong_peer::model::{Session, Status as PeerStatus};

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
    /// device key, and `name` what the Macs call it.
    #[uniffi::constructor]
    pub fn new(dir: String, key: Vec<u8>, name: String, listener: Box<dyn Listener>) -> Result<Arc<Core>, CoreError> {
        let bytes: [u8; 32] = key.try_into().map_err(|_| CoreError::Failed("The device key is the wrong length.".into()))?;
        let secret = iroh::SecretKey::from_bytes(&bytes);
        let wake = Arc::new((Mutex::new(false), Condvar::new()));
        let signal = wake.clone();
        let client = Client::new(
            PathBuf::from(dir),
            secret,
            name,
            env!("CARGO_PKG_VERSION").to_string(),
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
    /// devices code`). Returns the Mac's name.
    pub fn link(&self, code: String) -> Result<String, CoreError> {
        Ok(self.client.link(&code)?)
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
