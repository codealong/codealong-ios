//! A short sound while the app is open when something starts to wait on you, as the Mac makes
//! one (the main repo's sounds.rs): a pop when a session needs you (it asks you something, waits
//! on a call to allow, or stops with an error), and a lighter tink when a session's turn ends.
//! The phone sounds for the sessions of every Mac it's linked with, as it lists them all; each
//! Mac sounds for its own as well.
//!
//! What came is read from what the inbox has waiting on you, Needs you and Your turn, from one
//! look to the next, as `Store.queue` reads it: so not a snoozed session, the end of a quieted
//! one's turn (its Mac has left it out of Your turn), or a helper that doesn't need you. And to
//! stay out of the way:
//!
//! - nothing sounds for what a Mac's first feed brings once the phone connects to it: what came
//!   while the app was away is on the list you're opening, and it would all come at once;
//! - a session that comes to wait on you within `WATCHED_MS` of going back to work makes none:
//!   you just sent it something or answered it, so you're likely still looking at it; nor does
//!   one you just marked unread, woke from a snooze or otherwise sorted here;
//! - one sound at most every `REST_MS`: a few at once make one sound, the most urgent's.

use std::collections::{HashMap, HashSet};

use codealong_peer::client::Device;

use crate::{InboxSection, SessionRow, Status};

/// A session that comes to wait on you this soon after it went back to work, or after you sorted
/// it here, is one you're likely still looking at.
const WATCHED_MS: i64 = 15_000;
/// The least time between two sounds.
const REST_MS: i64 = 10_000;

/// What starts to wait on you, the most urgent first.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Sound {
    NeedsYou,
    YourTurn,
}

/// What waited on you on one Mac at a look, and what was running there.
#[derive(Debug, Default)]
struct Waiting {
    needs: HashSet<String>,
    turn: HashSet<String>,
    working: HashSet<String>,
}

impl Waiting {
    fn of(rows: &[&SessionRow]) -> Waiting {
        let mut w = Waiting::default();
        for r in rows {
            match r.section {
                InboxSection::NeedsYou => w.needs.insert(r.key.clone()),
                InboxSection::YourTurn => w.turn.insert(r.key.clone()),
                _ if r.status == Status::Working => w.working.insert(r.key.clone()),
                _ => false,
            };
        }
        w
    }
}

/// When a row's status began, as the inbox sorts by it.
fn since(r: &SessionRow) -> i64 {
    r.status_since.unwrap_or(r.last_activity)
}

/// Whether a Mac's feed on this connection has come: it's connected, has sent a feed since it
/// connected, and has finished its first scan. Until then the phone shows what it saved.
fn heard(d: &Device) -> bool {
    d.online && !d.loading && d.since.is_some_and(|since| d.last_seen.is_some_and(|seen| seen >= since))
}

/// Which sound is due at each look at the feeds (`Core::sound`).
#[derive(Default)]
pub(crate) struct Chimer {
    /// What waited on you on each Mac at the last look it had been heard on (`heard`), by its
    /// key, with when that connection opened: a Mac that reconnects starts afresh.
    was: HashMap<String, (i64, Waiting)>,
    /// When each session went back to work, as far as the looks show: the later of when its turn
    /// says it began and the first look that had it running again. Codex keeps a turn's start
    /// through a call you allow in it, which would have it working since long before your answer.
    working_since: HashMap<String, i64>,
    /// Sessions sorted here lately (marked unread, woken, and so on), and when.
    sorted: HashMap<String, i64>,
    /// When the last sound was due.
    last_at: Option<i64>,
}

impl Chimer {
    /// The sound due at `now`, if any: the most urgent kind that came and is in `on`. A kind
    /// that's off leaves the way clear for the rest.
    pub fn due(&mut self, devices: &[Device], rows: &[SessionRow], now: i64, on: &[Sound]) -> Option<Sound> {
        let mut came = Vec::new();
        let mut was = HashMap::new();
        for d in devices.iter().filter(|d| heard(d)) {
            let mine: Vec<&SessionRow> = rows.iter().filter(|r| r.device == d.key && !r.unattended).collect();
            let opened = d.since.unwrap_or_default();
            let before = self.was.remove(&d.key).filter(|(at, _)| *at == opened).map(|(_, w)| w);
            if let Some(before) = &before {
                came.extend(self.came(before, &mine, now));
            }
            self.remember_work(before.as_ref(), &mine, now);
            was.insert(d.key.clone(), (opened, Waiting::of(&mine)));
        }
        self.was = was;
        let known: HashSet<&str> = rows.iter().map(|r| r.key.as_str()).collect();
        self.working_since.retain(|k, _| known.contains(k.as_str()));
        self.sorted.retain(|_, at| now - *at < WATCHED_MS);
        let kind = came.into_iter().filter(|k| on.contains(k)).min()?;
        if self.last_at.is_some_and(|at| now - at < REST_MS) {
            return None;
        }
        self.last_at = Some(now);
        Some(kind)
    }

    /// Sessions you just sorted here, which coming to wait on you now is no news.
    pub fn sorted(&mut self, keys: &[String], now: i64) {
        for k in keys {
            self.sorted.insert(k.clone(), now);
        }
    }

    /// What came to wait on you on a Mac between two looks, less the sessions you're likely
    /// looking at.
    fn came(&self, was: &Waiting, rows: &[&SessionRow], now: i64) -> Vec<Sound> {
        let watched = |r: &SessionRow| {
            let at = since(r);
            self.working_since.get(&r.key).is_some_and(|&w| at >= w && at - w < WATCHED_MS) || self.sorted.get(&r.key).is_some_and(|&s| now - s < WATCHED_MS)
        };
        let mut out = Vec::new();
        for r in rows {
            let (kind, before) = match r.section {
                InboxSection::NeedsYou => (Sound::NeedsYou, &was.needs),
                InboxSection::YourTurn => (Sound::YourTurn, &was.turn),
                _ => continue,
            };
            if !before.contains(&r.key) && !watched(r) {
                out.push(kind);
            }
        }
        out
    }

    /// Notes when each of a Mac's running sessions went back to work, at `now`, given what was
    /// running at its last look (none when this look is its first).
    fn remember_work(&mut self, was: Option<&Waiting>, rows: &[&SessionRow], now: i64) {
        for r in rows.iter().filter(|r| r.status == Status::Working) {
            let start = match (was, self.working_since.get(&r.key)) {
                // Still running: since it went back, or a later turn's start a look didn't catch.
                (Some(w), Some(&at)) if w.working.contains(&r.key) => at.max(since(r)),
                // Back at work since the last look.
                (Some(_), _) => since(r).max(now),
                // Running when the Mac's feed came, as its turn says.
                (None, _) => since(r),
            };
            self.working_since.insert(r.key.clone(), start);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::order_tests::row;

    const NOW: i64 = 1_790_200_000_000;
    const BOTH: [Sound; 2] = [Sound::NeedsYou, Sound::YourTurn];

    /// A Mac connected an hour before `NOW`, whose feed has come since.
    fn mac(key: &str) -> Device {
        Device {
            key: key.into(),
            short: key.into(),
            name: key.into(),
            online: true,
            since: Some(NOW - 3_600_000),
            last_seen: Some(NOW - 3_600_000),
            remote_control: true,
            app: String::new(),
            loading: false,
            linked_back: true,
        }
    }

    fn session(key: &str, status: Status, since: i64) -> SessionRow {
        SessionRow { device: "m".into(), ..row(key, status, since, None, since) }
    }

    fn due(c: &mut Chimer, at: i64, rows: Vec<SessionRow>) -> Option<Sound> {
        c.due(&[mac("m")], &rows, at, &BOTH)
    }

    /// The chimer after a first look at `rows` an hour before `NOW`, which never sounds.
    fn after(rows: Vec<SessionRow>) -> Chimer {
        let mut c = Chimer::default();
        assert_eq!(due(&mut c, NOW - 3_600_000, rows), None);
        c
    }

    #[test]
    fn nothing_sounds_for_what_waits_when_a_mac_is_first_heard() {
        let mut c = Chimer::default();
        let waiting = vec![session("a", Status::Needs, NOW - 60_000), session("b", Status::Unread, NOW - 60_000)];
        assert_eq!(due(&mut c, NOW, waiting.clone()), None);
        // Still waiting at the next look is no news either.
        assert_eq!(due(&mut c, NOW + 1_000, waiting), None);
    }

    #[test]
    fn a_macs_saved_feed_and_its_first_feed_after_connecting_make_no_sound() {
        let rows = |status| vec![session("a", status, NOW - 60_000)];
        let mut c = Chimer::default();
        // What the phone saved, before the Mac answers: not connected, then connected and not
        // yet heard from, then heard from but still on its first scan.
        let away = Device { online: false, since: None, ..mac("m") };
        assert_eq!(c.due(&[away], &rows(Status::Working), NOW, &BOTH), None);
        let connected = Device { since: Some(NOW), last_seen: Some(NOW - 3_600_000), ..mac("m") };
        assert_eq!(c.due(&[connected], &rows(Status::Working), NOW + 100, &BOTH), None);
        let scanning = Device { since: Some(NOW), last_seen: Some(NOW + 200), loading: true, ..mac("m") };
        assert_eq!(c.due(&[scanning.clone()], &rows(Status::Needs), NOW + 200, &BOTH), None);
        // Its first feed brings what came while the app was away: no sound.
        let heard = Device { loading: false, last_seen: Some(NOW + 300), ..scanning };
        assert_eq!(c.due(&[heard.clone()], &rows(Status::Needs), NOW + 300, &BOTH), None);
        // After it, what comes sounds.
        let mut more = rows(Status::Needs);
        more.push(session("b", Status::Needs, NOW + 60_000));
        assert_eq!(c.due(&[heard.clone()], &more, NOW + 60_000, &BOTH), Some(Sound::NeedsYou));
        // A Mac that reconnects starts afresh.
        let again = Device { since: Some(NOW + 70_000), last_seen: Some(NOW + 70_000), ..heard };
        more.push(session("c", Status::Needs, NOW + 70_000));
        assert_eq!(c.due(&[again], &more, NOW + 90_000, &BOTH), None);
    }

    #[test]
    fn a_session_that_comes_to_need_you_or_ends_its_turn_sounds() {
        let mut c = after(vec![session("a", Status::Working, NOW - 3_600_000)]);
        assert_eq!(due(&mut c, NOW, vec![session("a", Status::Needs, NOW)]), Some(Sound::NeedsYou));
        let mut c = after(vec![session("a", Status::Working, NOW - 3_600_000)]);
        assert_eq!(due(&mut c, NOW, vec![session("a", Status::Unread, NOW)]), Some(Sound::YourTurn));
        let mut c = after(vec![session("a", Status::Working, NOW - 3_600_000)]);
        assert_eq!(due(&mut c, NOW, vec![session("a", Status::Error, NOW)]), Some(Sound::NeedsYou));
        // One the phone hadn't seen before, as a session just started that asks something.
        let mut c = after(vec![]);
        assert_eq!(due(&mut c, NOW, vec![session("new", Status::Needs, NOW)]), Some(Sound::NeedsYou));
    }

    #[test]
    fn a_session_you_just_answered_makes_no_sound() {
        // It went back to work 5 seconds before it asked again: you're still looking at it.
        let mut c = after(vec![session("a", Status::Needs, NOW - 3_600_000)]);
        assert_eq!(due(&mut c, NOW - 5_000, vec![session("a", Status::Working, NOW - 5_000)]), None);
        assert_eq!(due(&mut c, NOW, vec![session("a", Status::Needs, NOW)]), None);
        let mut c = after(vec![session("a", Status::Unread, NOW - 3_600_000)]);
        assert_eq!(due(&mut c, NOW - 5_000, vec![session("a", Status::Working, NOW - 5_000)]), None);
        assert_eq!(due(&mut c, NOW, vec![session("a", Status::Unread, NOW)]), None);
        // A turn as long as that sounds.
        let mut c = after(vec![session("a", Status::Unread, NOW - 3_600_000)]);
        assert_eq!(due(&mut c, NOW - WATCHED_MS, vec![session("a", Status::Working, NOW - WATCHED_MS)]), None);
        assert_eq!(due(&mut c, NOW, vec![session("a", Status::Unread, NOW)]), Some(Sound::YourTurn));
    }

    #[test]
    fn going_back_to_work_counts_from_when_a_look_saw_it_not_the_turns_start() {
        // A Codex turn keeps its start through a call you allow: back at work 5 seconds before it
        // ended, it began an hour ago.
        let turn = NOW - 3_600_000;
        let mut c = after(vec![session("a", Status::Working, turn)]);
        assert_eq!(due(&mut c, NOW - 60_000, vec![session("a", Status::Needs, NOW - 60_000)]), Some(Sound::NeedsYou));
        assert_eq!(due(&mut c, NOW - 5_000, vec![session("a", Status::Working, turn)]), None);
        assert_eq!(due(&mut c, NOW, vec![session("a", Status::Unread, NOW)]), None);
    }

    #[test]
    fn a_session_sorted_here_makes_no_sound_for_a_while() {
        // Marked unread here, it's Your turn again: you did that.
        let mut c = after(vec![session("a", Status::Idle, NOW - 3_600_000)]);
        c.sorted(&["a".into()], NOW - 1_000);
        assert_eq!(due(&mut c, NOW, vec![session("a", Status::Unread, NOW)]), None);
        // Later, it's news again.
        let mut c = after(vec![session("a", Status::Idle, NOW - 3_600_000)]);
        c.sorted(&["a".into()], NOW - 1_000);
        assert_eq!(due(&mut c, NOW + WATCHED_MS, vec![session("a", Status::Idle, NOW)]), None);
        assert_eq!(due(&mut c, NOW + WATCHED_MS + 1_000, vec![session("a", Status::Unread, NOW + WATCHED_MS)]), Some(Sound::YourTurn));
    }

    #[test]
    fn a_burst_is_one_sound_the_most_urgent() {
        let mut c = after(vec![session("a", Status::Working, NOW - 3_600_000), session("b", Status::Working, NOW - 3_600_000)]);
        let mut rows = vec![session("a", Status::Unread, NOW), session("b", Status::Needs, NOW)];
        assert_eq!(due(&mut c, NOW, rows.clone()), Some(Sound::NeedsYou));
        // Another that comes within the rest is quiet; after it, it sounds.
        rows.push(session("c", Status::Unread, NOW + 2_000));
        assert_eq!(due(&mut c, NOW + 2_000, rows.clone()), None);
        rows.push(session("d", Status::Unread, NOW + REST_MS));
        assert_eq!(due(&mut c, NOW + REST_MS, rows), Some(Sound::YourTurn));
    }

    #[test]
    fn a_kind_thats_off_leaves_the_way_clear() {
        let needs_only = [Sound::NeedsYou];
        let mut c = after(vec![session("a", Status::Working, NOW - 3_600_000), session("b", Status::Working, NOW - 3_600_000)]);
        let rows = vec![session("a", Status::Unread, NOW), session("b", Status::Working, NOW - 3_600_000)];
        assert_eq!(c.due(&[mac("m")], &rows, NOW, &needs_only), None);
        // The turn that made no sound doesn't hold back the one that comes to need you.
        let rows = vec![session("a", Status::Unread, NOW), session("b", Status::Needs, NOW + 1_000)];
        assert_eq!(c.due(&[mac("m")], &rows, NOW + 1_000, &needs_only), Some(Sound::NeedsYou));
        // With both off, nothing.
        let mut c = after(vec![session("a", Status::Working, NOW - 3_600_000)]);
        assert_eq!(c.due(&[mac("m")], &[session("a", Status::Needs, NOW)], NOW, &[]), None);
    }

    #[test]
    fn what_the_inbox_doesnt_have_waiting_makes_no_sound() {
        let mut c = after(vec![session("snoozed", Status::Working, NOW - 3_600_000), session("helper", Status::Working, NOW - 3_600_000)]);
        let snoozed = SessionRow { device: "m".into(), ..row("snoozed", Status::Needs, NOW, Some(NOW + 60_000), NOW) };
        let helper = SessionRow { unattended: true, ..session("helper", Status::Unread, NOW) };
        assert_eq!(due(&mut c, NOW, vec![snoozed, helper]), None);
        // A snoozed one that comes back, its time up, is news.
        assert_eq!(due(&mut c, NOW + 60_000, vec![session("snoozed", Status::Needs, NOW)]), Some(Sound::NeedsYou));
    }

    #[test]
    fn each_mac_is_read_on_its_own() {
        // A session on another Mac is that Mac's: its first feed is no news, here or there.
        let mut c = Chimer::default();
        let other = |r: SessionRow| SessionRow { device: "n".into(), ..r };
        assert_eq!(c.due(&[mac("m")], &[session("a", Status::Working, NOW - 3_600_000)], NOW - 60_000, &BOTH), None);
        let rows = vec![session("a", Status::Working, NOW - 3_600_000), other(session("b", Status::Needs, NOW - 60_000))];
        assert_eq!(c.due(&[mac("m"), mac("n")], &rows, NOW, &BOTH), None);
        let rows = vec![session("a", Status::Working, NOW - 3_600_000), other(session("b", Status::Needs, NOW - 60_000)), other(session("c", Status::Unread, NOW + 1_000))];
        assert_eq!(c.due(&[mac("m"), mac("n")], &rows, NOW + 1_000, &BOTH), Some(Sound::YourTurn));
    }
}
