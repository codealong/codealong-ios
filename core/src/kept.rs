//! Conversations kept between opens. Reading a session's conversation from its Mac takes a
//! round trip or more (a page, and pages before it for the prompt behind a long turn), and a
//! busy Mac answers slowly. So the core keeps the conversations read lately, in memory and saved
//! next to the feeds: a session opened again shows what was read at once and asks its Mac only
//! for what came since (`session-newer`), and one prefetched (the next that waits on you) is
//! ready before it's opened. A session that goes on in another record on its Mac (`continues`)
//! is read afresh, as the Mac's panel reads it again: what was kept is another record's.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use codealong_peer::{api, proto};
use serde::{Deserialize, Serialize};

/// Conversations kept in memory, the latest used.
const IN_MEMORY: usize = 30;
/// Conversations saved, the latest read.
const SAVED: usize = 40;
/// A saved conversation keeps its newest items, up to about this many.
const SAVED_ITEMS: usize = 300;
/// A conversation read this lately isn't read again to prefetch it.
pub(crate) const FRESH: Duration = Duration::from_secs(15);

/// A conversation as it's saved: what was read of it, and where reading goes on from.
#[derive(Serialize, Deserialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Saved {
    pub key: String,
    /// The record the session went on in when it was read (`Session::continues`).
    pub continues: Option<String>,
    pub items: Vec<api::Item>,
    pub before: Option<u64>,
    pub after: u64,
    /// What this phone said it knows when it was read (`proto::KNOWS`). A Mac sends a
    /// conversation as the phone says it can show it (another session's message whole once it
    /// knows `peer-items`, a note of its first line before), and only what came since is read
    /// again, so one saved under other words is read afresh. Missing from builds before.
    #[serde(default)]
    pub knows: Vec<String>,
    /// What of a conversation this build reads (`READS`) when it was saved: one saved by a build
    /// that read less is read afresh, so what it left out comes. Missing from builds before.
    #[serde(default)]
    pub reads: u32,
    /// The build of the Mac it was read from (`client::Device::app`), where known. A Mac on
    /// another build since may write its items otherwise (Codealong's messages came with the line
    /// for their cards in 0.26), and only what came since is read again, so one read from another
    /// build is read afresh. Missing from builds before.
    #[serde(default)]
    pub mac: String,
}

/// What of a conversation's items this build reads, as a number that goes up with what it adds:
/// 1, the line a Codealong message's card shows and the key of the session another session's
/// message came from (`api::Item::glance`, `from_key`).
const READS: u32 = 1;

impl Saved {
    /// What's saved of a conversation: its newest items, from where a record's line starts, so
    /// reading back from the first goes on from there with nothing missed.
    pub fn of(key: &str, continues: Option<&str>, mac: &str, items: &[api::Item], before: Option<u64>, after: u64) -> Saved {
        let mut from = items.len().saturating_sub(SAVED_ITEMS);
        while from > 0 && from < items.len() && items[from].cursor == items[from - 1].cursor {
            from += 1;
        }
        let kept = items[from.min(items.len())..].to_vec();
        // Cut short, the page before is the one before the first item kept.
        let before = if from > 0 { kept.first().map(|i| i.cursor).or(before) } else { before };
        Saved { key: key.to_string(), continues: continues.map(String::from), items: kept, before, after, knows: knows(), reads: READS, mac: mac.to_string() }
    }
}

/// Where a session's conversation is saved, in `dir`.
pub(crate) fn file_for(dir: &Path, key: &str) -> PathBuf {
    // FNV-1a: a name that's the same from one build to the next.
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in key.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    dir.join(format!("{h:016x}.json"))
}

/// What this phone tells its Macs it knows.
fn knows() -> Vec<String> {
    proto::KNOWS.map(String::from).to_vec()
}

/// What was saved of a session's conversation, when it's this session's in the record it goes
/// on in now, read as the phone reads one now, from its Mac on the build it's on now (`mac`).
pub(crate) fn load(path: &Path, key: &str, continues: Option<&str>, mac: &str) -> Option<Saved> {
    let saved: Saved = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    (saved.key == key && saved.continues.as_deref() == continues && saved.knows == knows() && saved.reads == READS && same_build(&saved.mac, mac)).then_some(saved)
}

/// Whether two builds of a Mac are the same, as far as anyone knows: one not known (a Mac not
/// heard from yet) takes the other's word.
fn same_build(a: &str, b: &str) -> bool {
    a.is_empty() || b.is_empty() || a == b
}

/// Saves a conversation, and lets go of the oldest saved past `SAVED`. A save that fails costs
/// only a read from the Mac next time.
pub(crate) fn save(path: &Path, saved: &Saved) {
    let Some(dir) = path.parent() else { return };
    let _ = std::fs::create_dir_all(dir);
    let Ok(bytes) = serde_json::to_vec(saved) else { return };
    let tmp = path.with_extension("tmp");
    if std::fs::write(&tmp, bytes).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
    prune(dir, SAVED);
}

fn prune(dir: &Path, keep: usize) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = entries
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .collect();
    if files.len() <= keep {
        return;
    }
    files.sort();
    for (_, p) in &files[..files.len() - keep] {
        let _ = std::fs::remove_file(p);
    }
}

struct Entry<T> {
    key: String,
    continues: Option<String>,
    mac: String,
    conv: Arc<T>,
}

/// The conversations in memory, the latest used last.
pub(crate) struct Kept<T> {
    /// Each with its session's key, the record it went on in and its Mac's build.
    open: Mutex<Vec<Entry<T>>>,
}

impl<T> Default for Kept<T> {
    fn default() -> Self {
        Kept { open: Mutex::new(Vec::new()) }
    }
}

impl<T> Kept<T> {
    /// The session's conversation in memory, when it's of the record the session goes on in
    /// now (`continues`), read from its Mac on the build it's on now (`mac`); otherwise one `make`
    /// makes, in its place. The latest used stay.
    pub fn get(&self, key: &str, continues: Option<&str>, mac: &str, make: impl FnOnce() -> Arc<T>) -> Arc<T> {
        let mut open = self.open.lock().unwrap_or_else(|e| e.into_inner());
        let found = open.iter().position(|e| e.key == key && e.continues.as_deref() == continues && same_build(&e.mac, mac));
        let conv = match found {
            Some(i) => open.remove(i).conv,
            None => {
                open.retain(|e| e.key != key);
                make()
            }
        };
        open.push(Entry { key: key.to_string(), continues: continues.map(String::from), mac: mac.to_string(), conv: conv.clone() });
        let over = open.len().saturating_sub(IN_MEMORY);
        open.drain(..over);
        conv
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(cursor: u64, n: u32) -> api::Item {
        api::Item { at: cursor as i64, kind: "agent".into(), text: format!("{cursor}.{n}"), from: None, from_key: None, from_side: None, glance: None, id: None, input: None, output: None, failed: false, withdrawn: false, stop: false, questions: vec![], answers: Default::default(), link: None, sent: None, cursor, n }
    }

    #[test]
    fn a_long_conversation_saves_its_newest_items_from_where_a_line_starts() {
        // Two items to each line of the record.
        let items: Vec<api::Item> = (0..400u64).flat_map(|c| [item(c * 10, 0), item(c * 10, 1)]).collect();
        let s = Saved::of("k", None, "0.26.0", &items, Some(0), 4_000);
        assert!(s.items.len() <= SAVED_ITEMS + 1 && s.items.len() >= SAVED_ITEMS - 1, "{}", s.items.len());
        assert_eq!(s.items[0].n, 0, "it starts where a line does");
        // Reading back goes on from the first item kept.
        assert_eq!(s.before, Some(s.items[0].cursor));
        assert_eq!(s.after, 4_000);
        // A short one is kept whole, with where it was read back to.
        let short = Saved::of("k", None, "0.26.0", &items[..10], Some(7), 50);
        assert_eq!((short.items.len(), short.before), (10, Some(7)));
    }

    #[test]
    fn a_saved_conversation_is_read_back_only_for_its_session_and_record() {
        let dir = std::env::temp_dir().join(format!("codealong-kept-{}", std::process::id()));
        let path = file_for(&dir, "@abc:claude:claude:1");
        assert_eq!(path, file_for(&dir, "@abc:claude:claude:1"));
        assert_ne!(path, file_for(&dir, "@abc:claude:claude:2"));
        save(&path, &Saved::of("@abc:claude:claude:1", Some("r1"), "0.26.0", &[item(1, 0)], None, 2));
        assert_eq!(load(&path, "@abc:claude:claude:1", Some("r1"), "0.26.0").map(|s| s.items.len()), Some(1));
        // Gone on in another record, or another session's, it's read afresh.
        assert!(load(&path, "@abc:claude:claude:1", Some("r2"), "0.26.0").is_none());
        assert!(load(&path, "@abc:claude:claude:2", Some("r1"), "0.26.0").is_none());
        // So is one read when the phone said it knew less: a build before whole messages from
        // other sessions has them as notes of their first line.
        let older = Saved { knows: vec!["have".into()], ..Saved::of("@abc:claude:claude:1", Some("r1"), "0.26.0", &[item(1, 0)], None, 2) };
        std::fs::write(&path, serde_json::to_vec(&older).unwrap()).unwrap();
        assert!(load(&path, "@abc:claude:claude:1", Some("r1"), "0.26.0").is_none());
        let mut unsaid = serde_json::to_value(&older).unwrap();
        unsaid.as_object_mut().unwrap().remove("knows");
        std::fs::write(&path, serde_json::to_vec(&unsaid).unwrap()).unwrap();
        assert!(load(&path, "@abc:claude:claude:1", Some("r1"), "0.26.0").is_none());
        // And one a build saved that read less of each item: its Codealong messages have no line
        // for their cards.
        let mut before_cards = serde_json::to_value(Saved::of("@abc:claude:claude:1", Some("r1"), "0.26.0", &[item(1, 0)], None, 2)).unwrap();
        before_cards.as_object_mut().unwrap().remove("reads");
        std::fs::write(&path, serde_json::to_vec(&before_cards).unwrap()).unwrap();
        assert!(load(&path, "@abc:claude:claude:1", Some("r1"), "0.26.0").is_none());
        // And one read from its Mac on another build, which may write its items otherwise; a Mac
        // not heard from yet takes the saved one's word.
        save(&path, &Saved::of("@abc:claude:claude:1", Some("r1"), "0.25.0", &[item(1, 0)], None, 2));
        assert!(load(&path, "@abc:claude:claude:1", Some("r1"), "0.26.0").is_none());
        assert!(load(&path, "@abc:claude:claude:1", Some("r1"), "0.25.0").is_some());
        assert!(load(&path, "@abc:claude:claude:1", Some("r1"), "").is_some());
        // The oldest go past the limit.
        for i in 0..5 {
            save(&file_for(&dir, &i.to_string()), &Saved::of(&i.to_string(), None, "0.26.0", &[], None, 0));
            std::thread::sleep(Duration::from_millis(15));
        }
        prune(&dir, 3);
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 3);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_latest_conversations_stay_in_memory() {
        let kept: Kept<String> = Kept::default();
        let a = kept.get("a", None, "0.26.0", || Arc::new("a1".to_string()));
        // The same session's again, until it goes on in another record.
        assert!(Arc::ptr_eq(&a, &kept.get("a", None, "0.26.0", || Arc::new("a2".to_string()))));
        assert_eq!(*kept.get("a", Some("r2"), "0.26.0", || Arc::new("a3".to_string())), "a3");
        // Its Mac on another build since: read afresh. A Mac not heard from yet takes its word.
        assert_eq!(*kept.get("a", Some("r2"), "0.27.0", || Arc::new("a5".to_string())), "a5");
        assert_eq!(*kept.get("a", Some("r2"), "0.27.0", || Arc::new("a6".to_string())), "a5");
        assert_eq!(*kept.get("a", Some("r2"), "", || Arc::new("a7".to_string())), "a5");
        for i in 0..IN_MEMORY {
            kept.get(&i.to_string(), None, "0.26.0", || Arc::new(i.to_string()));
        }
        // The least lately used went.
        assert_eq!(*kept.get("a", Some("r2"), "0.26.0", || Arc::new("a4".to_string())), "a4");
    }
}
