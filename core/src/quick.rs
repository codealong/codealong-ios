//! The quick search, as the Mac's quick panel has it (the main repo's `src/quick.ts` and
//! `src/route.ts`). With nothing typed it lists the sessions that need you, then the ones whose
//! turn ended; with nothing waiting, the ones working. Under them go the rest of the sessions
//! started in the last day. Typed words find sessions, then PRs: every word has to be in what
//! describes them, or, for a session, in what was said in it (each Mac's text search). A Mac
//! asked where the typed text goes (Jev, through it) adds suggestions above them.

use std::collections::HashMap;

use codealong_peer::api;
use codealong_peer::feed::{remote_key, split_remote};
use codealong_peer::model::PrState;

use crate::{all_rows, all_worktrees, inbox_order, now_ms, Core, CoreError, Feeds, InboxSection, SessionRow, Status, Worktree};

/// How far back the empty list's recent sessions go, and how many it lists at most.
const RECENT_MS: i64 = 24 * 60 * 60 * 1000;
const RECENT_SESSIONS: usize = 20;
/// A search lists this many sessions and PRs at most.
const FOUND_SESSIONS: usize = 9;
const FOUND_PRS: usize = 4;
/// Suggestions at most.
const SUGGESTIONS: usize = 3;
/// A runner-up gets a row when it's at least this likely.
const RUNNER_UP: f64 = 0.15;
/// New work gets its own worktree when Jev is at least this sure it wants one.
const OWN_WORKTREE: f64 = 0.6;
/// Typed text shorter than this is a search, not worth asking about.
const MIN_ROUTE_CHARS: usize = 8;
/// The shortest search that's sent to the Macs' text search: fewer letters match nearly everything.
const TEXT_SEARCH_MIN: usize = 3;

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuickGroup {
    NeedsYou,
    YourTurn,
    Working,
    Sessions,
    Prs,
    Recent,
}

/// A line of what was said in a session that has every typed word, from its Mac's text search.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SaidHit {
    /// The session's key here (`@<device>:<key>`).
    pub key: String,
    pub snippet: String,
    /// You wrote it; otherwise the agent did.
    pub you: bool,
    pub at: i64,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SaidFound {
    pub hits: Vec<SaidHit>,
    /// A Mac is still reading sessions for the first time, so more may match soon.
    pub building: bool,
}

/// A PR of a worktree on one of the Macs.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PrRow {
    pub key: String,
    pub device: String,
    pub number: u64,
    pub title: String,
    pub url: String,
    /// `draft`, `open`, `approved`, `changes`, `merged` or `closed`.
    pub state: String,
    pub failing: u32,
    pub repo: String,
    pub branch: Option<String>,
    pub project: String,
    pub updated_at: i64,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum QuickRow {
    Session { row: SessionRow, said: Option<SaidHit> },
    Pr { pr: PrRow },
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct QuickSection {
    pub group: QuickGroup,
    /// How many there are in all, for the heading; the rows can be fewer.
    pub count: u32,
    pub rows: Vec<QuickRow>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct QuickList {
    pub sections: Vec<QuickSection>,
    /// Nothing typed and nothing waits on you.
    pub nothing_waits: bool,
    pub working: u32,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SuggestKind {
    /// Send what's typed to a session.
    Send,
    /// Open a session: it's the one named, or it waits on you for something typing wouldn't answer.
    Open,
    /// Start a session with what's typed.
    Start,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sureness {
    Sure,
    Likely,
    Unsure,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Suggestion {
    pub kind: SuggestKind,
    pub key: String,
    pub p: f64,
    pub sureness: Sureness,
    /// The session to send to or open.
    pub session: Option<SessionRow>,
    /// The worktree to start in.
    pub worktree: Option<Worktree>,
    /// Claude Code makes a worktree of its own from the worktree's repo.
    pub new_worktree: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct RouteAnswer {
    pub suggestions: Vec<Suggestion>,
    /// Session keys Jev scored, most likely first, to rank the search by.
    pub ranked: Vec<String>,
    /// A session that may already be doing what's typed.
    pub duplicate: Option<SessionRow>,
    /// The versioned model that answered.
    pub model: String,
    pub ms: u64,
}

/// The words to look for, lowercased.
fn words_of(query: &str) -> Vec<String> {
    query.to_lowercase().split_whitespace().map(String::from).collect()
}

/// Whether what's typed is worth asking a Mac where it goes: a few words, not a word or two of a search.
#[uniffi::export]
pub fn worth_routing(text: String) -> bool {
    let t = text.trim();
    t.chars().count() >= MIN_ROUTE_CHARS && t.split_whitespace().count() >= 2
}

/// Whether what's typed is long enough to look for in what sessions said.
#[uniffi::export]
pub fn worth_searching_said(query: String) -> bool {
    query.trim().chars().count() >= TEXT_SEARCH_MIN
}

/// What the last text search found that is still found by its own line: hits whose line has every
/// word typed now. They stay while the search for the new words runs, so a session found by what
/// was said doesn't drop out of the list with each key and come back when the search answers.
#[uniffi::export]
pub fn still_said(hits: Vec<SaidHit>, query: String) -> Vec<SaidHit> {
    let words = words_of(&query);
    hits.into_iter()
        .filter(|h| {
            let line = h.snippet.to_lowercase();
            words.iter().all(|w| line.contains(w.as_str()))
        })
        .collect()
}

fn status_rank(s: Status) -> u8 {
    match s {
        Status::Needs | Status::Error => 0,
        Status::Unread => 1,
        Status::Working => 2,
        Status::Idle => 3,
        Status::Stopped => 4,
    }
}

fn status_time(s: &SessionRow) -> i64 {
    s.status_since.unwrap_or(s.last_activity)
}

fn session(row: &SessionRow) -> QuickRow {
    QuickRow::Session { row: row.clone(), said: None }
}

/// The list for what's typed (`query`) in `project` (empty for all). `said` has the Macs' text
/// search hits for it and `ranked` the sessions Jev scored, which lead the sessions found.
pub(crate) fn quick_list(rows: &[SessionRow], prs: &[PrRow], project: &str, query: &str, said: &[SaidHit], ranked: &[String], now: i64) -> QuickList {
    let inp = |p: &str| project.is_empty() || p == project;
    let rows: Vec<&SessionRow> = rows.iter().filter(|r| inp(&r.project)).collect();
    let words = words_of(query);
    let mut sections = Vec::new();

    if words.is_empty() {
        let mut attention: Vec<&SessionRow> = rows.iter().copied().filter(|r| matches!(r.section, InboxSection::NeedsYou | InboxSection::YourTurn | InboxSection::Working)).collect();
        attention.sort_by(|a, b| inbox_order(a, b));
        let working = attention.iter().filter(|r| r.section == InboxSection::Working).count() as u32;
        let waiting = attention.iter().any(|r| r.section != InboxSection::Working);
        let mut shown = std::collections::HashSet::new();
        for (group, section) in [(QuickGroup::NeedsYou, InboxSection::NeedsYou), (QuickGroup::YourTurn, InboxSection::YourTurn), (QuickGroup::Working, InboxSection::Working)] {
            // With something waiting on you, what's working stays out of the way, as on the Mac.
            if waiting && section == InboxSection::Working {
                continue;
            }
            let these: Vec<&SessionRow> = attention.iter().copied().filter(|r| r.section == section).collect();
            if these.is_empty() {
                continue;
            }
            shown.extend(these.iter().map(|r| r.key.clone()));
            sections.push(QuickSection { group, count: these.len() as u32, rows: these.into_iter().map(session).collect() });
        }
        let mut recent: Vec<&SessionRow> = rows.iter().copied().filter(|r| !shown.contains(&r.key) && now - r.started_at.unwrap_or(r.last_activity) <= RECENT_MS).collect();
        recent.sort_by(|a, b| status_time(b).cmp(&status_time(a)).then_with(|| a.key.cmp(&b.key)));
        if !recent.is_empty() {
            sections.push(QuickSection { group: QuickGroup::Recent, count: recent.len() as u32, rows: recent.into_iter().take(RECENT_SESSIONS).map(session).collect() });
        }
        return QuickList { sections, nothing_waits: !waiting, working };
    }

    let has_all = |hay: &str| words.iter().all(|w| hay.contains(w.as_str()));
    let said: HashMap<&str, &SaidHit> = said.iter().map(|h| (h.key.as_str(), h)).collect();
    let mut found: Vec<(u8, QuickRow, &SessionRow)> = rows
        .iter()
        .filter_map(|r| {
            let title = r.title.to_lowercase();
            let hay = [r.title.as_str(), &r.account, &r.worktree, &r.repo, r.branch.as_deref().unwrap_or(""), &r.project, r.pr.as_deref().unwrap_or(""), &r.device_name].join("\n").to_lowercase();
            if has_all(&title) {
                Some((0, session(r), *r))
            } else if has_all(&hay) {
                Some((1, session(r), *r))
            } else {
                said.get(r.key.as_str()).map(|h| (2, QuickRow::Session { row: (*r).clone(), said: Some((*h).clone()) }, *r))
            }
        })
        .collect();
    found.sort_by(|a, b| a.0.cmp(&b.0).then(status_rank(a.2.status).cmp(&status_rank(b.2.status))).then(b.2.last_activity.cmp(&a.2.last_activity)).then_with(|| a.2.key.cmp(&b.2.key)));
    let count = found.len() as u32;
    let mut found: Vec<(QuickRow, &SessionRow)> = found.into_iter().take(FOUND_SESSIONS).map(|(_, q, r)| (q, r)).collect();
    // The ones Jev scored lead, in its order; the rest keep theirs.
    let rank = |r: &SessionRow| ranked.iter().position(|k| *k == r.key).unwrap_or(usize::MAX);
    found.sort_by_key(|(_, r)| rank(r));
    if !found.is_empty() {
        sections.push(QuickSection { group: QuickGroup::Sessions, count, rows: found.into_iter().map(|(q, _)| q).collect() });
    }

    let state_rank = |p: &PrRow| match p.state.as_str() {
        "merged" => 1,
        "closed" => 2,
        _ => 0,
    };
    let mut prs: Vec<(bool, &PrRow)> = prs
        .iter()
        .filter(|p| inp(&p.project))
        .filter(|p| has_all(&[format!("#{}", p.number).as_str(), &p.title, &p.repo, p.branch.as_deref().unwrap_or(""), &p.project].join("\n").to_lowercase()))
        .map(|p| (has_all(&p.title.to_lowercase()), p))
        .collect();
    prs.sort_by(|a, b| b.0.cmp(&a.0).then(state_rank(a.1).cmp(&state_rank(b.1))).then(b.1.updated_at.cmp(&a.1.updated_at)).then_with(|| a.1.key.cmp(&b.1.key)));
    if !prs.is_empty() {
        sections.push(QuickSection { group: QuickGroup::Prs, count: prs.len() as u32, rows: prs.into_iter().take(FOUND_PRS).map(|(_, p)| QuickRow::Pr { pr: p.clone() }).collect() });
    }
    QuickList { sections, nothing_waits: false, working: 0 }
}

/// Every worktree's PR on the linked Macs, once each.
fn all_prs(feeds: &Feeds) -> Vec<PrRow> {
    let worktrees = all_worktrees(feeds);
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for (d, replica) in feeds {
        for l in &replica.lanes {
            let Some(pr) = &l.pr else { continue };
            // Two worktrees of one repo can be on the same PR's branch.
            if !seen.insert((l.repo_slug.clone().unwrap_or_else(|| l.repo.clone()), pr.number)) {
                continue;
            }
            let Some(w) = worktrees.iter().find(|w| w.device == d.key && w.id == l.id) else { continue };
            let state = match pr.state {
                PrState::Draft => "draft",
                PrState::Open => "open",
                PrState::Approved => "approved",
                PrState::Changes => "changes",
                PrState::Merged => "merged",
                PrState::Closed => "closed",
            };
            out.push(PrRow {
                key: format!("{}#{}", l.repo_slug.as_deref().unwrap_or(&l.repo), pr.number),
                device: d.key.clone(),
                number: pr.number,
                title: pr.title.clone(),
                url: pr.url.clone(),
                state: state.into(),
                failing: pr.checks.failed,
                repo: l.repo.clone(),
                branch: l.branch.clone(),
                project: w.project.clone(),
                updated_at: pr.updated_at,
            });
        }
    }
    out
}

fn sureness(p: f64) -> Sureness {
    if p >= 0.75 {
        Sureness::Sure
    } else if p >= 0.45 {
        Sureness::Likely
    } else {
        Sureness::Unsure
    }
}

/// A key or lane id from `short`'s Mac as this phone has it: its own are made remote; those it
/// has from another Mac already are.
fn here(short: &str, id: &str) -> String {
    if split_remote(id).is_some() {
        id.to_string()
    } else {
        remote_key(short, id)
    }
}

/// The rows for a Mac's answer, as the Mac's panel makes them (route.ts `suggestions`). The
/// likeliest action on its likeliest target leads; runners-up follow, so a wrong guess is one
/// row away from the right one. A session that waits on you for a prompt is opened, never sent
/// to: what's typed would answer the prompt. One whose reply asks you something is sent to.
/// `short` is the answering Mac's short id; `worktrees` are this phone's, keyed `@<short>:<id>`.
pub(crate) fn suggestions(route: &api::Route, short: &str, rows: &HashMap<String, SessionRow>, worktrees: &HashMap<String, Worktree>) -> Vec<Suggestion> {
    use api::Action;
    let prob = |a: Action| route.actions.iter().find(|(x, _)| *x == a).map_or(0.0, |x| x.1);
    let pp = |p: Option<&api::Pick>| p.map_or(0.0, |p| p.p);
    let mut out: Vec<Suggestion> = Vec::new();
    let mut add = |s: Option<Suggestion>| {
        if let Some(s) = s {
            if out.len() < SUGGESTIONS && !out.iter().any(|o| o.key == s.key) {
                out.push(s);
            }
        }
    };
    let to_session = |pick: Option<&api::Pick>, p: f64, find: bool| -> Option<Suggestion> {
        let row = rows.get(&here(short, &pick?.id))?;
        let open = find || (row.status == Status::Needs && !row.asks);
        let kind = if open { SuggestKind::Open } else { SuggestKind::Send };
        Some(Suggestion { kind, key: format!("{}:{}", if open { "open" } else { "send" }, row.key), p, sureness: sureness(p), session: Some(row.clone()), worktree: None, new_worktree: false })
    };
    let start_in = |pick: Option<&api::Pick>, p: f64| -> Option<Suggestion> {
        let w = worktrees.get(&here(short, &pick?.id))?;
        let new_worktree = route.own_worktree >= OWN_WORKTREE;
        // A new worktree is made from the repo, so two of its worktrees make the same row.
        let key = if new_worktree { format!("start:new:{}:{}/{}", w.device, w.project, w.repo) } else { format!("start:{}:{}", w.device, w.id) };
        Some(Suggestion { kind: SuggestKind::Start, key, p, sureness: sureness(p), session: None, worktree: Some(w.clone()), new_worktree })
    };
    let (s1, s2) = (route.sessions.first(), route.sessions.get(1));
    let (l1, l2) = (route.lanes.first(), route.lanes.get(1));
    match route.action {
        Action::Send | Action::Find => {
            let find = route.action == Action::Find;
            let p = prob(route.action);
            add(to_session(s1, p * pp(s1), find));
            if pp(s2) >= RUNNER_UP {
                add(to_session(s2, p * pp(s2), find));
            }
            if prob(Action::Start) >= RUNNER_UP || route.no_session >= RUNNER_UP {
                add(start_in(l1, prob(Action::Start).max(route.no_session) * pp(l1)));
            }
        }
        Action::Start => {
            let p = prob(Action::Start);
            add(start_in(l1, p * pp(l1)));
            // The session that may already be doing it comes next: sending there may be what's meant.
            if let Some(d) = &route.duplicate {
                add(to_session(Some(d), prob(Action::Send) * d.p, false));
            }
            if pp(l2) >= RUNNER_UP {
                add(start_in(l2, p * pp(l2)));
            }
            if prob(Action::Send) >= RUNNER_UP && pp(s1) >= RUNNER_UP {
                add(to_session(s1, prob(Action::Send) * pp(s1), false));
            }
        }
        // Todos are each Mac's own, and the phone doesn't keep them: new work starts instead.
        Action::Todo => add(start_in(l1, prob(Action::Start).max(prob(Action::Todo)) * pp(l1))),
    }
    out
}

#[uniffi::export]
impl Core {
    /// What the quick search lists for `query` in `project` (empty for all), with the Macs' text
    /// search hits for it (`said`) and the sessions a Mac's suggestion ranked first (`ranked`).
    pub fn quick(&self, project: String, query: String, said: Vec<SaidHit>, ranked: Vec<String>) -> QuickList {
        self.client.with_feeds(|feeds| quick_list(&all_rows(feeds), &all_prs(feeds), &project, &query, &said, &ranked, now_ms()))
    }

    /// Looks for the words in what was said in sessions on every connected Mac, at once.
    pub fn search_said(&self, query: String) -> SaidFound {
        let words = words_of(&query);
        let targets: Vec<String> = self.client.devices().into_iter().filter(|d| d.online).map(|d| d.short).collect();
        let handles: Vec<_> = targets
            .into_iter()
            .map(|short| {
                let client = self.client.clone();
                let words = words.clone();
                std::thread::spawn(move || client.search(&short, &words).map(|f| (short, f)))
            })
            .collect();
        let mut out = SaidFound { hits: Vec::new(), building: false };
        for h in handles {
            if let Ok(Ok((short, found))) = h.join() {
                out.building |= found.building;
                out.hits.extend(found.hits.into_iter().map(|h| SaidHit { key: remote_key(&short, &h.key), snippet: h.snippet, you: h.you, at: h.at }));
            }
        }
        out
    }

    /// Asks `device` where `text` goes (Jev, through that Mac), in `project` (empty for all).
    pub fn route(&self, device: String, project: String, text: String) -> Result<RouteAnswer, CoreError> {
        let short = device.get(..10).unwrap_or(&device).to_string();
        let route = self.client.route(&device, &project, &text)?;
        Ok(self.client.with_feeds(|feeds| {
            let rows: HashMap<String, SessionRow> = all_rows(feeds).into_iter().map(|r| (r.key.clone(), r)).collect();
            let shorts: HashMap<&str, &str> = feeds.iter().map(|(d, _)| (d.key.as_str(), d.short.as_str())).collect();
            let worktrees: HashMap<String, Worktree> = all_worktrees(feeds).into_iter().filter_map(|w| Some((remote_key(shorts.get(w.device.as_str())?, &w.id), w))).collect();
            RouteAnswer {
                suggestions: suggestions(&route, &short, &rows, &worktrees),
                ranked: route.sessions.iter().map(|s| here(&short, &s.id)).collect(),
                duplicate: route.duplicate.as_ref().and_then(|d| rows.get(&here(&short, &d.id)).cloned()),
                model: route.model.clone(),
                ms: route.ms,
            }
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 100 * 24 * 60 * 60 * 1000;

    fn row(key: &str, title: &str, status: Status, at: i64) -> SessionRow {
        SessionRow {
            key: key.into(),
            device: "d".into(),
            device_name: "Mac".into(),
            device_online: true,
            title: title.into(),
            headline: String::new(),
            detail: None,
            status,
            stalled: false,
            harness: "Claude Code".into(),
            account: "claude".into(),
            project: "App".into(),
            repo: "app".into(),
            worktree: "app".into(),
            branch: Some("main".into()),
            last_prompt_at: at,
            last_activity: at,
            status_since: Some(at),
            hosted: false,
            section: crate::section(status, None),
            snoozed_until: None,
            started_at: Some(at),
            live: true,
            in_app: false,
            asks: false,
            pr: None,
        }
    }

    fn keys(l: &QuickList) -> Vec<(QuickGroup, Vec<String>)> {
        l.sections
            .iter()
            .map(|s| {
                (
                    s.group,
                    s.rows
                        .iter()
                        .map(|r| match r {
                            QuickRow::Session { row, .. } => row.key.clone(),
                            QuickRow::Pr { pr } => pr.key.clone(),
                        })
                        .collect(),
                )
            })
            .collect()
    }

    #[test]
    fn nothing_typed_lists_what_waits_then_the_last_day() {
        let hour = 3600 * 1000;
        let rows = vec![
            row("needs", "a", Status::Needs, NOW - hour),
            row("turn", "b", Status::Unread, NOW - 2 * hour),
            row("working", "c", Status::Working, NOW - 3 * hour),
            row("idle", "d", Status::Idle, NOW - 4 * hour),
            row("old", "e", Status::Idle, NOW - 30 * hour),
        ];
        let l = quick_list(&rows, &[], "", "", &[], &[], NOW);
        // What's working stays out of the way while something waits, and shows in the last day.
        assert_eq!(keys(&l), [(QuickGroup::NeedsYou, vec!["needs".to_string()]), (QuickGroup::YourTurn, vec!["turn".into()]), (QuickGroup::Recent, vec!["working".into(), "idle".into()])]);
        assert!(!l.nothing_waits);
        // With nothing waiting, what's working shows.
        let l = quick_list(&rows[2..], &[], "", "", &[], &[], NOW);
        assert_eq!(keys(&l)[0], (QuickGroup::Working, vec!["working".to_string()]));
        assert!(l.nothing_waits);
        assert_eq!(l.working, 1);
    }

    #[test]
    fn typed_words_find_titles_first_then_what_was_said() {
        let mut other = row("branch", "Fix login", Status::Idle, NOW);
        other.branch = Some("quick-search".into());
        let rows = vec![row("said", "Other work", Status::Needs, NOW), other, row("title", "Quick search on the phone", Status::Idle, NOW - 5)];
        let said = [SaidHit { key: "said".into(), snippet: "make the quick search".into(), you: true, at: NOW }];
        let prs = [PrRow { key: "app#3".into(), device: "d".into(), number: 3, title: "Quick search".into(), url: String::new(), state: "open".into(), failing: 0, repo: "app".into(), branch: None, project: "App".into(), updated_at: NOW }];
        let l = quick_list(&rows, &prs, "", "quick search", &said, &[], NOW);
        assert_eq!(keys(&l), [(QuickGroup::Sessions, vec!["title".to_string(), "branch".into(), "said".into()]), (QuickGroup::Prs, vec!["app#3".into()])]);
        // Jev's ranking leads.
        let l = quick_list(&rows, &[], "", "quick search", &said, &["said".into()], NOW);
        assert_eq!(keys(&l)[0].1[0], "said");
        // Another project's are left out.
        assert!(quick_list(&rows, &prs, "Other", "quick", &said, &[], NOW).sections.is_empty());
    }

    #[test]
    fn a_suggestion_opens_a_session_that_waits_and_starts_in_a_new_worktree_when_sure() {
        let short = "abcdef0123";
        let mut waits = row(&remote_key(short, "s1"), "Waits", Status::Needs, NOW);
        waits.asks = false;
        let rows: HashMap<String, SessionRow> = [(waits.key.clone(), waits)].into_iter().collect();
        let w = Worktree { id: "/r".into(), project: "App".into(), repo: "app".into(), name: "app".into(), branch: None, last_activity: NOW, device: "abcdef0123ffff".into(), main: true };
        let worktrees: HashMap<String, Worktree> = [(remote_key(short, "/r"), w)].into_iter().collect();
        let route = api::Route {
            action: api::Action::Send,
            actions: vec![(api::Action::Send, 0.8), (api::Action::Start, 0.2)],
            sessions: vec![api::Pick { id: "s1".into(), p: 0.9 }],
            no_session: 0.1,
            lanes: vec![api::Pick { id: "/r".into(), p: 1.0 }],
            repos: vec![],
            own_worktree: 0.7,
            duplicate: None,
            model: "jev".into(),
            ms: 1,
            input_tokens: 0,
        };
        let s = suggestions(&route, short, &rows, &worktrees);
        assert_eq!(s.iter().map(|s| s.kind).collect::<Vec<_>>(), [SuggestKind::Open, SuggestKind::Start]);
        assert_eq!(s[0].sureness, Sureness::Likely);
        assert!(s[1].new_worktree);
    }

    #[test]
    fn routing_waits_for_a_few_words() {
        assert!(!worth_routing("login".into()));
        assert!(worth_routing("fix the login".into()));
        assert_eq!(still_said(vec![SaidHit { key: "k".into(), snippet: "Quick search".into(), you: false, at: 0 }], "quick sea".into()).len(), 1);
        assert!(still_said(vec![SaidHit { key: "k".into(), snippet: "Quick".into(), you: false, at: 0 }], "quick sea".into()).is_empty());
    }
}
