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

use codealong_peer::api;
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
}

impl Saved {
    /// What's saved of a conversation: its newest items, from where a record's line starts, so
    /// reading back from the first goes on from there with nothing missed.
    pub fn of(key: &str, continues: Option<&str>, items: &[api::Item], before: Option<u64>, after: u64) -> Saved {
        let mut from = items.len().saturating_sub(SAVED_ITEMS);
        while from > 0 && from < items.len() && items[from].cursor == items[from - 1].cursor {
            from += 1;
        }
        let kept = items[from.min(items.len())..].to_vec();
        // Cut short, the page before is the one before the first item kept.
        let before = if from > 0 { kept.first().map(|i| i.cursor).or(before) } else { before };
        Saved { key: key.to_string(), continues: continues.map(String::from), items: kept, before, after }
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

/// What was saved of a session's conversation, when it's this session's in the record it goes
/// on in now.
pub(crate) fn load(path: &Path, key: &str, continues: Option<&str>) -> Option<Saved> {
    let saved: Saved = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    (saved.key == key && saved.continues.as_deref() == continues).then_some(saved)
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

/// The conversations in memory, the latest used last.
pub(crate) struct Kept<T> {
    open: Mutex<Vec<(String, Option<String>, Arc<T>)>>,
}

impl<T> Default for Kept<T> {
    fn default() -> Self {
        Kept { open: Mutex::new(Vec::new()) }
    }
}

impl<T> Kept<T> {
    /// The session's conversation in memory, when it's of the record the session goes on in
    /// now (`continues`); otherwise one `make` makes, in its place. The latest used stay.
    pub fn get(&self, key: &str, continues: Option<&str>, make: impl FnOnce() -> Arc<T>) -> Arc<T> {
        let mut open = self.open.lock().unwrap_or_else(|e| e.into_inner());
        let found = open.iter().position(|(k, c, _)| k == key && c.as_deref() == continues);
        let conv = match found {
            Some(i) => open.remove(i).2,
            None => {
                open.retain(|(k, _, _)| k != key);
                make()
            }
        };
        open.push((key.to_string(), continues.map(String::from), conv.clone()));
        let over = open.len().saturating_sub(IN_MEMORY);
        open.drain(..over);
        conv
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(cursor: u64, n: u32) -> api::Item {
        api::Item { at: cursor as i64, kind: "agent".into(), text: format!("{cursor}.{n}"), id: None, input: None, output: None, failed: false, withdrawn: false, questions: vec![], answers: Default::default(), link: None, cursor, n }
    }

    #[test]
    fn a_long_conversation_saves_its_newest_items_from_where_a_line_starts() {
        // Two items to each line of the record.
        let items: Vec<api::Item> = (0..400u64).flat_map(|c| [item(c * 10, 0), item(c * 10, 1)]).collect();
        let s = Saved::of("k", None, &items, Some(0), 4_000);
        assert!(s.items.len() <= SAVED_ITEMS + 1 && s.items.len() >= SAVED_ITEMS - 1, "{}", s.items.len());
        assert_eq!(s.items[0].n, 0, "it starts where a line does");
        // Reading back goes on from the first item kept.
        assert_eq!(s.before, Some(s.items[0].cursor));
        assert_eq!(s.after, 4_000);
        // A short one is kept whole, with where it was read back to.
        let short = Saved::of("k", None, &items[..10], Some(7), 50);
        assert_eq!((short.items.len(), short.before), (10, Some(7)));
    }

    #[test]
    fn a_saved_conversation_is_read_back_only_for_its_session_and_record() {
        let dir = std::env::temp_dir().join(format!("codealong-kept-{}", std::process::id()));
        let path = file_for(&dir, "@abc:claude:claude:1");
        assert_eq!(path, file_for(&dir, "@abc:claude:claude:1"));
        assert_ne!(path, file_for(&dir, "@abc:claude:claude:2"));
        save(&path, &Saved::of("@abc:claude:claude:1", Some("r1"), &[item(1, 0)], None, 2));
        assert_eq!(load(&path, "@abc:claude:claude:1", Some("r1")).map(|s| s.items.len()), Some(1));
        // Gone on in another record, or another session's, it's read afresh.
        assert!(load(&path, "@abc:claude:claude:1", Some("r2")).is_none());
        assert!(load(&path, "@abc:claude:claude:2", Some("r1")).is_none());
        // The oldest go past the limit.
        for i in 0..5 {
            save(&file_for(&dir, &i.to_string()), &Saved::of(&i.to_string(), None, &[], None, 0));
            std::thread::sleep(Duration::from_millis(15));
        }
        prune(&dir, 3);
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 3);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_latest_conversations_stay_in_memory() {
        let kept: Kept<String> = Kept::default();
        let a = kept.get("a", None, || Arc::new("a1".to_string()));
        // The same session's again, until it goes on in another record.
        assert!(Arc::ptr_eq(&a, &kept.get("a", None, || Arc::new("a2".to_string()))));
        assert_eq!(*kept.get("a", Some("r2"), || Arc::new("a3".to_string())), "a3");
        for i in 0..IN_MEMORY {
            kept.get(&i.to_string(), None, || Arc::new(i.to_string()));
        }
        // The least lately used went.
        assert_eq!(*kept.get("a", Some("r2"), || Arc::new("a4".to_string())), "a4");
    }
}
