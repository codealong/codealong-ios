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

use crate::{all_rows, all_worktrees, inbox_order, new_work_in, now_ms, Core, CoreError, Feeds, InboxSection, SessionRow, Status, Worktree};

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
    /// Pinned on their Macs, in each Mac's order, as the Mac's Sessions view leads with them.
    Pinned,
    NeedsYou,
    YourTurn,
    /// PRs that wait on your review, as the Mac's Review requested lists them.
    Reviews,
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
    /// How well that line matched: higher is better. Macs of earlier builds don't say.
    pub score: u8,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SaidFound {
    pub hits: Vec<SaidHit>,
    /// A Mac is still reading sessions for the first time, so more may match soon.
    pub building: bool,
}

/// A PR on one of the Macs: from its PR list (Macs from 2026-10-10 send one), else the PR of one
/// of its worktrees.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PrRow {
    /// `owner/name#number` (`name#number` for a worktree's PR whose repo has no GitHub name).
    pub key: String,
    /// The Mac to ask about it: one that's online, where several list it.
    pub device: String,
    pub device_name: String,
    /// `owner/name`, which the requests about it name it by; empty for a worktree's PR whose repo
    /// has no GitHub name.
    pub slug: String,
    pub number: u64,
    pub title: String,
    pub url: String,
    /// `draft`, `open`, `approved`, `changes`, `merged` or `closed`.
    pub state: String,
    pub failing: u32,
    /// Checks still running.
    pub pending: u32,
    pub passed: u32,
    /// `clean`, `conflicts`, `behind`, `blocked`, `unstable` or `unknown`.
    pub merge: String,
    /// Its repo's name.
    pub repo: String,
    pub branch: Option<String>,
    pub base: Option<String>,
    pub project: String,
    pub updated_at: i64,
    pub author: Option<String>,
    /// An account of yours opened it (`github::You`).
    pub mine: bool,
    /// Its Mac (`device`) is signed in to GitHub as the account that opened it, so an approval of
    /// it can't go from there.
    pub opened_by_its_mac: bool,
    /// It waits on your review: asked for, open, not snoozed, not held by Codealong's own review.
    pub waits: bool,
    /// Your review is asked for, whether it waits on you now or is snoozed.
    pub review_requested: bool,
    pub requested_by: Option<String>,
    pub requested_at: Option<i64>,
    pub snoozed_until: Option<i64>,
    pub pinned: bool,
    pub additions: u64,
    pub deletions: u64,
    pub changed_files: u64,
    /// The sessions that worked on it, by their keys here (`@<device>:<key>`).
    pub sessions: Vec<String>,
    /// Its labels on GitHub, in the order of their names; none from Macs before 2026-10-17.
    pub labels: Vec<PrLabelRow>,
    /// It's approved, but only by approvals of an earlier commit than the one it's at, which
    /// GitHub still counts: who approved which, in a sentence (prStatus.ts `staleWords`).
    pub stale: Option<String>,
    /// Where Codealong's own review of it stands on its Mac, once it's had one.
    pub agent_review: Option<AgentReviewLine>,
    /// Whose move it is, where its review state doesn't say; none from Macs before 2026-10-23.
    pub turn: Option<PrTurn>,
}

/// A label on a PR, as its repo on GitHub defines it.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PrLabelRow {
    pub name: String,
    /// Its color, as GitHub keeps it; none when GitHub gave none that reads as one.
    pub color: Option<LabelColor>,
    pub description: Option<String>,
}

/// A label's color, each part from 0 to 1.
#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq)]
pub struct LabelColor {
    pub red: f32,
    pub green: f32,
    pub blue: f32,
}

impl PrLabelRow {
    fn of(l: &codealong_peer::model::PrLabel) -> PrLabelRow {
        // Six hex digits, as the Mac sends them.
        let part = |i: usize| l.color.get(i..i + 2).and_then(|h| u8::from_str_radix(h, 16).ok()).map(|v| f32::from(v) / 255.0);
        let color = match (l.color.len(), part(0), part(2), part(4)) {
            (6, Some(red), Some(green), Some(blue)) => Some(LabelColor { red, green, blue }),
            _ => None,
        };
        PrLabelRow { name: l.name.clone(), color, description: l.description.clone() }
    }
}

/// The latest round of Codealong's automatic review of a PR, as the line over the Mac's review box
/// says it (review.ts `autoReviewWords`).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct AgentReviewLine {
    /// `queued`, `reviewing`, `posted`, `drafted`, `kept`, `skipped`, `failed`, or `submitted`
    /// once it went as your review, for its icon.
    pub stage: String,
    /// "Agent reviewed 1a2b3c4 and commented".
    pub says: String,
    /// What its agent would do with the PR, while its review hasn't gone as yours: "Suggests
    /// approving".
    pub suggests: Option<String>,
}

/// What a PR's card says of Codealong's own review of it, from the round a Mac sends.
fn agent_review_line(r: &codealong_peer::pr::AutoReview) -> AgentReviewLine {
    use codealong_peer::pr::{ReviewStage, Verdict};
    let at = r.head.get(..7).unwrap_or(&r.head);
    if let Some(v) = r.submitted {
        let says = match v {
            Verdict::Approve => format!("Agent approved {at} for you"),
            Verdict::RequestChanges => format!("Agent requested changes on {at} for you"),
            Verdict::Comment => format!("Agent commented on {at} for you"),
        };
        return AgentReviewLine { stage: "submitted".into(), says, suggests: None };
    }
    let (stage, says) = match r.stage {
        ReviewStage::Queued => ("queued", format!("Agent review of {at} to come")),
        ReviewStage::Reviewing => ("reviewing", format!("Agent reviewing {at}")),
        ReviewStage::Posted => ("posted", format!("Agent reviewed {at} and commented")),
        ReviewStage::Drafted => ("drafted", format!("Agent drafted a review of {at}")),
        ReviewStage::Kept => ("kept", format!("Agent reviewed {at}")),
        ReviewStage::Skipped => ("skipped", format!("Agent passed on {at}")),
        ReviewStage::Failed | ReviewStage::Other => ("failed", format!("Agent\u{2019}s review of {at} didn\u{2019}t get done")),
    };
    let suggests = r.suggests.filter(|_| matches!(r.stage, ReviewStage::Posted | ReviewStage::Drafted | ReviewStage::Kept)).map(|v| {
        match v {
            Verdict::Approve => "Suggests approving",
            Verdict::RequestChanges => "Suggests changes",
            Verdict::Comment => "Suggests a comment",
        }
        .to_string()
    });
    AgentReviewLine { stage: stage.into(), says, suggests }
}

/// Whose move an open PR is, where its review state doesn't say, as the Mac's pill says it in place
/// of that state (prStatus.ts `turnPill`): GitHub keeps a request for changes until its reviewer
/// approves, so a PR whose fixes are in, or whose author answered your review, would still read as
/// Changes requested.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PrTurn {
    /// `reply-needed`, `rereview-asked`, `reviewer-replied` or `author-replied`, for its icon.
    pub kind: String,
    /// The pill's words: "Author replied".
    pub words: String,
    /// It's your move, which the Mac draws in amber, not theirs.
    pub yours: bool,
    /// What it means, in a sentence, its time as `{ago:<ms>}`.
    pub says: String,
}

/// What a PR's card says of whose move it is, from the `turn` its Mac sends: none for a kind a later
/// Mac names, where its state says what it can.
fn turn_line(t: &codealong_peer::pr::Turn) -> Option<PrTurn> {
    use codealong_peer::pr::TurnKind;
    let who = listed(&[std::slice::from_ref(&t.who), t.also.as_slice()].concat());
    // " 4m ago", where the Mac says since when.
    let ago = t.since.map(|at| format!(" {{ago:{at}}}")).unwrap_or_default();
    let stands = "GitHub keeps a request for changes until its reviewer approves.";
    let (kind, words, yours, says) = match t.kind {
        TurnKind::ReplyNeeded => ("reply-needed", "Reply needed", true, format!("Commits came{ago} after {who} asked for changes, and nobody has said so on it. GitHub tells a reviewer of a comment or a review request, not of a push: say what changed, or ask for a review again.")),
        TurnKind::RereviewAsked => ("rereview-asked", "Re-review asked", false, format!("Waiting on {who}, who asked for changes: asked to review it again or written to{ago}. {stands}")),
        TurnKind::ReviewerReplied => ("reviewer-replied", "Reviewer replied", true, format!("{who} asked for changes, then wrote again{ago}: your move. {stands}")),
        TurnKind::AuthorReplied => ("author-replied", "Author replied", true, format!("{who} wrote{ago} after your last review or comment: your move.")),
        TurnKind::Other => return None,
    };
    Some(PrTurn { kind: kind.into(), words: words.into(), yours, says })
}

/// Names as a sentence lists them: `ana`, `ana and ken`, `ana, ken and sam`.
fn listed(names: &[String]) -> String {
    match names {
        [rest @ .., last] if !rest.is_empty() => format!("{} and {last}", rest.join(", ")),
        _ => names.join(""),
    }
}

/// A PR approved only before its latest commits, in a sentence (prStatus.ts `staleWords`): who
/// approved which commit, and that GitHub still counts it, which is why it can read as ready to
/// merge. None for one that isn't approved, or is approved as it is.
fn stale_words(state: PrState, stale: Option<&codealong_peer::model::StaleApproval>) -> Option<String> {
    let s = stale.filter(|_| state == PrState::Approved)?;
    let at = s.commit.get(..7).unwrap_or(&s.commit);
    let who = if s.by.is_empty() { "A reviewer".to_string() } else { listed(&s.by) };
    Some(if s.by.len() > 1 {
        format!("Approved before its latest commits: {who} approved earlier ones, the latest {at}. GitHub still counts the approvals, as the repo doesn\u{2019}t dismiss them when commits come.")
    } else {
        format!("Approved before its latest commits: {who} approved {at}. GitHub still counts the approval, as the repo doesn\u{2019}t dismiss it when commits come.")
    })
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

/// Whether `word` is in `text` (lowercased). Among other words, a word of one or two letters
/// counts only whole: "class c" shouldn't find every session with a c in it. Alone it's a search
/// as you type and matches anywhere. The Mac's quick.ts `wordAt` and its text search have the
/// same rule.
fn has_word(text: &str, word: &str, of: usize) -> bool {
    if of < 2 || word.chars().count() > 2 {
        return text.contains(word);
    }
    let edge = |c: Option<char>| c.is_none_or(|c| !c.is_alphanumeric());
    text.match_indices(word).any(|(i, w)| edge(text[..i].chars().next_back()) && edge(text[i + w.len()..].chars().next()))
}

fn has_words(text: &str, words: &[String]) -> bool {
    words.iter().all(|w| has_word(text, w, words.len()))
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
    hits.into_iter().filter(|h| has_words(&h.snippet.to_lowercase(), &words)).collect()
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
        // What's pinned leads, whatever its state, helpers too: a pin is yours to make.
        let pinned = crate::lists::pinned_of(&rows);
        // A helper or a headless run that doesn't need you is out of the rest, as it's off the
        // Mac's bar: its agent or script reads what it writes. Searching finds it.
        let rows: Vec<&SessionRow> = rows.iter().copied().filter(|r| !r.unattended).collect();
        let mut attention: Vec<&SessionRow> = rows.iter().copied().filter(|r| matches!(r.section, InboxSection::NeedsYou | InboxSection::YourTurn | InboxSection::Working)).collect();
        attention.sort_by(|a, b| inbox_order(a, b));
        let working = attention.iter().filter(|r| r.section == InboxSection::Working).count() as u32;
        let waiting = attention.iter().any(|r| r.section != InboxSection::Working);
        // PRs that wait on your review, the longest wait first, as the Mac's queue takes them.
        let mut reviews: Vec<&PrRow> = prs.iter().filter(|p| p.waits && inp(&p.project)).collect();
        reviews.sort_by(|a, b| crate::lists::by_wait(a, b));
        let waiting = waiting || !reviews.is_empty();
        let mut shown = std::collections::HashSet::new();
        // The pinned ones aren't listed again below.
        if !pinned.is_empty() {
            shown.extend(pinned.iter().map(|r| r.key.clone()));
            sections.push(QuickSection { group: QuickGroup::Pinned, count: pinned.len() as u32, rows: pinned.into_iter().map(session).collect() });
        }
        for (group, section) in [(QuickGroup::NeedsYou, InboxSection::NeedsYou), (QuickGroup::YourTurn, InboxSection::YourTurn), (QuickGroup::Working, InboxSection::Working)] {
            // With something waiting on you, what's working stays out of the way, as on the Mac.
            if waiting && section == InboxSection::Working {
                continue;
            }
            let these: Vec<&SessionRow> = attention.iter().copied().filter(|r| r.section == section && !shown.contains(&r.key)).collect();
            if !these.is_empty() {
                shown.extend(these.iter().map(|r| r.key.clone()));
                sections.push(QuickSection { group, count: these.len() as u32, rows: these.into_iter().map(session).collect() });
            }
            // Reviews go after the turns that ended, before what's working.
            if section == InboxSection::YourTurn && !reviews.is_empty() {
                sections.push(QuickSection { group: QuickGroup::Reviews, count: reviews.len() as u32, rows: reviews.iter().map(|p| QuickRow::Pr { pr: (*p).clone() }).collect() });
            }
        }
        let mut recent: Vec<&SessionRow> = rows.iter().copied().filter(|r| !shown.contains(&r.key) && now - r.started_at.unwrap_or(r.last_activity) <= RECENT_MS).collect();
        recent.sort_by(|a, b| status_time(b).cmp(&status_time(a)).then_with(|| a.key.cmp(&b.key)));
        if !recent.is_empty() {
            sections.push(QuickSection { group: QuickGroup::Recent, count: recent.len() as u32, rows: recent.into_iter().take(RECENT_SESSIONS).map(session).collect() });
        }
        return QuickList { sections, nothing_waits: !waiting, working };
    }

    let has_all = |hay: &str| has_words(hay, &words);
    let said: HashMap<&str, &SaidHit> = said.iter().map(|h| (h.key.as_str(), h)).collect();
    // Found by the title, by what else describes it, or by what was said, how well the line said
    // matched breaking ties among those, as on the Mac.
    let mut found: Vec<(u8, u8, QuickRow, &SessionRow)> = rows
        .iter()
        .filter_map(|r| {
            let title = r.title.to_lowercase();
            let hay = [r.title.as_str(), &r.account, &r.worktree, &r.repo, r.branch.as_deref().unwrap_or(""), &r.project, r.pr.as_deref().unwrap_or(""), &r.device_name].join("\n").to_lowercase();
            if has_all(&title) {
                Some((0, 0, session(r), *r))
            } else if has_all(&hay) {
                Some((1, 0, session(r), *r))
            } else {
                said.get(r.key.as_str()).map(|h| (2, h.score, QuickRow::Session { row: (*r).clone(), said: Some((*h).clone()) }, *r))
            }
        })
        .collect();
    found.sort_by(|a, b| a.0.cmp(&b.0).then(b.1.cmp(&a.1)).then(status_rank(a.3.status).cmp(&status_rank(b.3.status))).then(b.3.last_activity.cmp(&a.3.last_activity)).then_with(|| a.3.key.cmp(&b.3.key)));
    let count = found.len() as u32;
    let mut found: Vec<(QuickRow, &SessionRow)> = found.into_iter().take(FOUND_SESSIONS).map(|(_, _, q, r)| (q, r)).collect();
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
        // By its labels too, as the Mac's search finds a PR.
        .filter(|p| has_all(&[format!("#{}", p.number).as_str(), &p.title, &p.repo, p.branch.as_deref().unwrap_or(""), &p.project, &p.labels.iter().map(|l| l.name.as_str()).collect::<Vec<_>>().join("\n")].join("\n").to_lowercase()))
        .map(|p| (has_all(&p.title.to_lowercase()), p))
        .collect();
    prs.sort_by(|a, b| b.0.cmp(&a.0).then(state_rank(a.1).cmp(&state_rank(b.1))).then(b.1.updated_at.cmp(&a.1.updated_at)).then_with(|| a.1.key.cmp(&b.1.key)));
    if !prs.is_empty() {
        sections.push(QuickSection { group: QuickGroup::Prs, count: prs.len() as u32, rows: prs.into_iter().take(FOUND_PRS).map(|(_, p)| QuickRow::Pr { pr: p.clone() }).collect() });
    }
    QuickList { sections, nothing_waits: false, working: 0 }
}

/// A PR's key, `owner/name#number`, as GitHub names it now (its URL), so a PR is one PR however
/// its Macs name its repo: a Mac whose checkout still names a renamed or moved repo by its old
/// name lists its PRs under that one. `theirs`, its Mac's key, when its URL isn't a PR's.
pub(crate) fn pr_key(url: &str, theirs: &str) -> String {
    let named = || {
        let mut parts = url.split_once("://")?.1.split('/').skip(1);
        let (owner, name) = (parts.next()?, parts.next()?);
        let number: u64 = parts.next().filter(|p| *p == "pull").and(parts.next())?.split(['#', '?']).next()?.parse().ok()?;
        Some(format!("{owner}/{name}#{number}"))
    };
    named().unwrap_or_else(|| theirs.to_string())
}

/// Whether a PR, by its `key` and its Mac's own for it (`theirs`), is new to `seen`, which keeps
/// both from now on: a Mac whose feed is from before its repo was renamed has the old URL, where
/// another Mac may still name the repo the old way.
pub(crate) fn first_seen(seen: &mut std::collections::HashSet<String>, key: &str, theirs: &str) -> bool {
    let (key, theirs) = (key.to_lowercase(), theirs.to_lowercase());
    let new_theirs = theirs == key || seen.insert(theirs);
    seen.insert(key) && new_theirs
}

/// Every worktree's PR on the linked Macs, once each, those `you` opened as yours, with the
/// sessions that worked on it on any of them.
pub(crate) fn all_prs(feeds: &Feeds, you: &crate::github::You) -> Vec<PrRow> {
    let worktrees = all_worktrees(feeds);
    let projects = crate::Projects::of_feeds(feeds);
    let mut seen = std::collections::HashSet::new();
    let mut out: Vec<PrRow> = Vec::new();
    // Each PR's place in `out`, by its key and its Macs' own for it, in lower case.
    let mut at: HashMap<String, usize> = HashMap::new();
    // Each Mac's PR list, the ones online first, of those the ones that take remote control, then
    // the ones signed in to GitHub as you: a PR two Macs list is asked about where it can be read,
    // and reviewed and merged as you.
    let mut macs: Vec<&(codealong_peer::client::Device, &codealong_peer::feed::Replica)> = feeds.iter().collect();
    macs.sort_by_key(|(d, _)| (!d.online, !d.remote_control, !you.signs_in(&d.key)));
    // The PRs, by their place in `out`, that a Mac of your account has said whose move they are,
    // or that it's no one's: a Mac after it, which can be behind, has no say.
    let mut told = std::collections::HashSet::new();
    for (d, replica) in macs {
        // Whose move a PR is, as this Mac works it out for the account it's signed in as (a Mac
        // signed in as another, a bot your agents open PRs as, has no say): none while Codealong's
        // agent reviews it, which holds it out of what waits on you though your review is asked
        // for, where the Mac's pill says Agent reviewing ahead of it (prStatus.ts `agentPill`): it
        // isn't your move until that's done. A review you snoozed doesn't wait either way, so then
        // the Mac's own round under way says it.
        let ours = !you.signs_in_as_another(&d.key);
        let turn = |p: &codealong_peer::pr::PrCard| {
            use codealong_peer::pr::ReviewStage;
            let held = p.review_requested
                && match p.snoozed_until {
                    None => !p.waits,
                    Some(_) => p.auto_review.as_ref().is_some_and(|a| matches!(a.stage, ReviewStage::Queued | ReviewStage::Reviewing)),
                };
            p.turn.as_ref().filter(|_| !held).and_then(turn_line)
        };
        for p in &replica.prs {
            let key = pr_key(&p.url, &p.key);
            let sessions: Vec<String> = p.sessions.iter().map(|k| remote_key(&d.short, k)).collect();
            if !first_seen(&mut seen, &key, &p.key) {
                // Another Mac lists it too: the sessions there worked on it as well, and where no Mac
                // of your account has said whose move it is, it can, while the Mac it's asked of
                // has it open.
                if let Some(i) = place(&mut at, &key, &p.key, None) {
                    add_sessions(&mut out[i].sessions, sessions);
                    let open = !matches!(out[i].state.as_str(), "draft" | "merged" | "closed");
                    if ours && open && told.insert(i) {
                        out[i].turn = turn(p);
                    }
                }
                continue;
            }
            place(&mut at, &key, &p.key, Some(out.len()));
            if ours {
                told.insert(out.len());
            }
            out.push(PrRow {
                key,
                device: d.key.clone(),
                device_name: d.name.clone(),
                slug: p.repo.clone(),
                number: p.number,
                title: p.title.clone(),
                url: p.url.clone(),
                state: state_word(p.state).into(),
                failing: p.checks.failed,
                pending: p.checks.pending,
                passed: p.checks.passed,
                merge: merge_word(p.merge).into(),
                repo: p.repo.rsplit('/').next().unwrap_or(&p.repo).to_string(),
                branch: Some(p.head.clone()),
                base: p.base.clone(),
                // In the project the Macs line its repo up in, as a session's is.
                project: projects.of(&p.project, &[p.repo.to_lowercase()]).unwrap_or_else(|| p.project.clone()),
                updated_at: p.updated_at,
                author: p.author.clone(),
                mine: you.opened(p.author.as_deref()),
                opened_by_its_mac: p.mine,
                waits: p.waits,
                review_requested: p.review_requested,
                requested_by: p.requested_by.clone(),
                requested_at: p.requested_at,
                snoozed_until: p.snoozed_until,
                pinned: p.pinned,
                additions: p.additions,
                deletions: p.deletions,
                changed_files: p.changed_files,
                sessions,
                labels: p.labels.iter().map(PrLabelRow::of).collect(),
                // A PR card doesn't carry it: its worktree's PR on the same Mac does.
                stale: stale_words(p.state, replica.lanes.iter().filter_map(|l| l.pr.as_ref()).find(|w| !w.url.is_empty() && w.url == p.url).and_then(|w| w.stale_approval.as_ref())),
                agent_review: p.auto_review.as_ref().map(agent_review_line),
                turn: if ours { turn(p) } else { None },
            });
        }
    }
    // Worktrees' PRs, from Macs that send no PR list.
    for (d, replica) in feeds {
        for l in &replica.lanes {
            let Some(pr) = &l.pr else { continue };
            // Two worktrees of one repo can be on the same PR's branch.
            let theirs = format!("{}#{}", l.repo_slug.as_deref().unwrap_or(&l.repo), pr.number);
            let key = pr_key(&pr.url, &theirs);
            let sessions: Vec<String> = l.sessions.iter().map(|s| remote_key(&d.short, &s.key)).collect();
            if !first_seen(&mut seen, &key, &theirs) {
                // Its sessions worked on it too, unless this Mac's PR list has it and says there
                // which did. A Mac leaves a PR merged or closed a day ago out of its list, though
                // its worktree still has it.
                let listed = replica.prs.iter().any(|p| pr_key(&p.url, &p.key).eq_ignore_ascii_case(&key) || p.key.eq_ignore_ascii_case(&theirs));
                if let (false, Some(i)) = (listed, place(&mut at, &key, &theirs, None)) {
                    add_sessions(&mut out[i].sessions, sessions);
                }
                continue;
            }
            let Some(w) = worktrees.iter().find(|w| w.device == d.key && w.id == l.id) else { continue };
            place(&mut at, &key, &theirs, Some(out.len()));
            out.push(PrRow {
                key,
                device: d.key.clone(),
                device_name: d.name.clone(),
                slug: l.repo_slug.clone().unwrap_or_default(),
                number: pr.number,
                title: pr.title.clone(),
                url: pr.url.clone(),
                state: state_word(pr.state).into(),
                failing: pr.checks.failed,
                pending: pr.checks.pending,
                passed: pr.checks.passed,
                merge: merge_word(pr.merge).into(),
                repo: l.repo.clone(),
                branch: l.branch.clone(),
                base: None,
                project: w.project.clone(),
                updated_at: pr.updated_at,
                author: None,
                mine: false,
                opened_by_its_mac: false,
                waits: false,
                review_requested: false,
                requested_by: None,
                requested_at: None,
                snoozed_until: None,
                pinned: false,
                additions: 0,
                deletions: 0,
                changed_files: 0,
                sessions,
                labels: Vec::new(),
                stale: stale_words(pr.state, pr.stale_approval.as_ref()),
                agent_review: None,
                turn: None,
            });
        }
    }
    out
}

/// Where a PR is in `all_prs`'s list, by its key or its Mac's own for it, `to` putting it there;
/// both are kept for it, so a Mac that names it either way finds it.
fn place(at: &mut HashMap<String, usize>, key: &str, theirs: &str, to: Option<usize>) -> Option<usize> {
    let (key, theirs) = (key.to_lowercase(), theirs.to_lowercase());
    let found = to.or_else(|| at.get(&key).or_else(|| at.get(&theirs)).copied())?;
    at.entry(key).or_insert(found);
    at.entry(theirs).or_insert(found);
    Some(found)
}

/// Adds the sessions a PR's list doesn't have yet, after the ones it has.
fn add_sessions(to: &mut Vec<String>, sessions: Vec<String>) {
    for s in sessions {
        if !to.contains(&s) {
            to.push(s);
        }
    }
}

fn state_word(s: PrState) -> &'static str {
    match s {
        PrState::Draft => "draft",
        PrState::Open => "open",
        PrState::Approved => "approved",
        PrState::Changes => "changes",
        PrState::Merged => "merged",
        PrState::Closed => "closed",
    }
}

fn merge_word(m: codealong_peer::model::Merge) -> &'static str {
    use codealong_peer::model::Merge;
    match m {
        Merge::Clean => "clean",
        Merge::Conflicts => "conflicts",
        Merge::Behind => "behind",
        Merge::Blocked => "blocked",
        Merge::Unstable => "unstable",
        Merge::Unknown => "unknown",
    }
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
/// New work goes where the Mac's panel would start it (`new_work_in`), and work that belongs in
/// none of the worktrees, a question about nothing in them, to a chat in no project.
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
    // The answering Mac's worktrees, for where new work goes in a repo; ids as it has them.
    let theirs: Vec<Worktree> = worktrees.iter().filter(|(k, _)| split_remote(k).is_some_and(|(d, _)| d == short)).map(|(_, w)| w.clone()).collect();
    let ranked: Vec<String> = route.lanes.iter().map(|l| l.id.clone()).collect();
    let start_in = |pick: Option<&api::Pick>, action_p: f64| -> Option<Suggestion> {
        let pick = pick?;
        let picked = theirs.iter().find(|w| here(short, &w.id) == here(short, &pick.id))?;
        let reusable = new_work_in(picked, pick.p, &theirs, &ranked);
        let new_worktree = route.own_worktree >= OWN_WORKTREE || reusable.is_none();
        // A new worktree is made from the repo's main checkout, so two of its worktrees make the
        // same row.
        let w = if new_worktree { theirs.iter().find(|w| w.main && w.project == picked.project && w.repo == picked.repo).unwrap_or(picked) } else { reusable.unwrap_or(picked) };
        // In the very worktree picked it's as likely as that worktree; anywhere else in the repo,
        // as likely as the repo.
        let repo_p = route.repos.iter().find(|r| r.id.ends_with(&format!("/{}", picked.repo))).map(|r| r.p);
        let p = action_p * if !new_worktree && w.id == picked.id { pick.p } else { repo_p.unwrap_or(pick.p) };
        let key = if new_worktree { format!("start:new:{}:{}/{}", w.device, w.project, w.repo) } else { format!("start:{}:{}", w.device, w.id) };
        Some(Suggestion { kind: SuggestKind::Start, key, p, sureness: sureness(p), session: None, worktree: Some(w.clone()), new_worktree })
    };
    // New work that needs none of the worktrees goes to a chat of its own, in no project, when the
    // Mac thinks so more than it thinks of any one worktree.
    let chats = theirs.iter().find(|w| w.chat);
    let start_chat = |action_p: f64| -> Option<Suggestion> {
        let w = chats.filter(|_| route.no_repo > 0.0)?;
        let p = action_p * route.no_repo;
        Some(Suggestion { kind: SuggestKind::Start, key: format!("start:chat:{}", w.device), p, sureness: sureness(p), session: None, worktree: Some(w.clone()), new_worktree: false })
    };
    let (s1, s2) = (route.sessions.first(), route.sessions.get(1));
    let (l1, l2) = (route.lanes.first(), route.lanes.get(1));
    let in_chat = chats.is_some() && route.no_repo > pp(l1);
    let start_new = |action_p: f64| if in_chat { start_chat(action_p) } else { start_in(l1, action_p) };
    match route.action {
        Action::Send | Action::Find => {
            let find = route.action == Action::Find;
            let p = prob(route.action);
            add(to_session(s1, p * pp(s1), find));
            if pp(s2) >= RUNNER_UP {
                add(to_session(s2, p * pp(s2), find));
            }
            if prob(Action::Start) >= RUNNER_UP || route.no_session >= RUNNER_UP {
                add(start_new(prob(Action::Start).max(route.no_session)));
            }
        }
        Action::Start => {
            let p = prob(Action::Start);
            add(start_new(p));
            // The session that may already be doing it comes next: sending there may be what's meant.
            if let Some(d) = &route.duplicate {
                add(to_session(Some(d), prob(Action::Send) * d.p, false));
            }
            // The worktree the Mac liked best after a chat, or a chat after it, when either is likely.
            if in_chat && pp(l1) >= RUNNER_UP {
                add(start_in(l1, p));
            }
            if !in_chat && route.no_repo >= RUNNER_UP {
                add(start_chat(p));
            }
            if pp(l2) >= RUNNER_UP {
                add(start_in(l2, p));
            }
            if prob(Action::Send) >= RUNNER_UP && pp(s1) >= RUNNER_UP {
                add(to_session(s1, prob(Action::Send) * pp(s1), false));
            }
        }
        // Todos are each Mac's own, and the phone doesn't keep them: new work starts instead.
        Action::Todo => add(start_in(l1, prob(Action::Start).max(prob(Action::Todo)))),
    }
    out
}

#[uniffi::export]
impl Core {
    /// What the quick search lists for `query` in `project` (empty for all), with the Macs' text
    /// search hits for it (`said`) and the sessions a Mac's suggestion ranked first (`ranked`).
    pub fn quick(&self, project: String, query: String, said: Vec<SaidHit>, ranked: Vec<String>) -> QuickList {
        self.client.with_feeds(|feeds| quick_list(&all_rows(feeds), &all_prs(feeds, &self.you(feeds)), &project, &query, &said, &ranked, now_ms()))
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
                out.hits.extend(found.hits.into_iter().map(|h| SaidHit { key: remote_key(&short, &h.key), snippet: h.snippet, you: h.you, at: h.at, score: h.score }));
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
pub(crate) mod tests {
    use super::*;

    const NOW: i64 = 100 * 24 * 60 * 60 * 1000;

    pub(crate) fn row(key: &str, title: &str, status: Status, at: i64) -> SessionRow {
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
            waits_in_background: false,
            harness: "Claude Code".into(),
            account: "claude".into(),
            project: "App".into(),
            repo: "app".into(),
            worktree: "app".into(),
            worktree_id: "/src/app".into(),
            pinned: None,
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
            name: None,
            origin: None,
            limit: None,
            connection_lost: None,
            quiet: false,
            unattended: false,
            headless: false,
            runs: 0,
            runs_working: 0,
            suggestions: None,
            emblem: None,
            id: key.into(),
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
    fn pinned_sessions_lead_and_arent_listed_again() {
        let hour = 3600 * 1000;
        let mut needs = row("needs", "a", Status::Needs, NOW - hour);
        needs.pinned = Some(1);
        let mut idle = row("idle", "b", Status::Idle, NOW - 30 * hour);
        idle.pinned = Some(0);
        let rows = vec![needs, idle, row("turn", "c", Status::Unread, NOW - 2 * hour)];
        let l = quick_list(&rows, &[], "", "", &[], &[], NOW);
        assert_eq!(keys(&l), [(QuickGroup::Pinned, vec!["idle".to_string(), "needs".into()]), (QuickGroup::YourTurn, vec!["turn".into()])]);
        assert!(!l.nothing_waits);
        // A pinned one that needs you counts as waiting when it's the only one; a pinned helper
        // leads with the rest; a pinned one working counts as working.
        let mut helper = row("helper", "d", Status::Idle, NOW - hour);
        helper.unattended = true;
        helper.pinned = Some(2);
        let mut working = row("working", "e", Status::Working, NOW - hour);
        working.pinned = Some(3);
        let rows = vec![rows[0].clone(), helper, working];
        let l = quick_list(&rows, &[], "", "", &[], &[], NOW);
        assert_eq!(keys(&l), [(QuickGroup::Pinned, vec!["needs".to_string(), "helper".into(), "working".into()])]);
        assert!(!l.nothing_waits);
        assert_eq!(l.working, 1);
    }

    pub(crate) fn pr_row(key: &str, title: &str, waits: bool) -> PrRow {
        PrRow {
            key: key.into(),
            device: "d".into(),
            device_name: "Mac".into(),
            slug: String::new(),
            number: 3,
            title: title.into(),
            url: String::new(),
            state: "open".into(),
            failing: 0,
            pending: 0,
            passed: 0,
            merge: "clean".into(),
            repo: "app".into(),
            branch: None,
            base: None,
            project: "App".into(),
            updated_at: NOW,
            author: None,
            mine: false,
            opened_by_its_mac: false,
            waits,
            review_requested: waits,
            requested_by: None,
            requested_at: None,
            snoozed_until: None,
            pinned: false,
            additions: 0,
            deletions: 0,
            changed_files: 0,
            sessions: Vec::new(),
            labels: Vec::new(),
            stale: None,
            agent_review: None,
            turn: None,
        }
    }

    #[test]
    fn a_labels_color_is_read_from_githubs_hex() {
        use codealong_peer::model::PrLabel;
        let label = |color: &str| PrLabelRow::of(&PrLabel { name: "bug".into(), color: color.into(), description: None }).color;
        assert_eq!(label("ff8000"), Some(LabelColor { red: 1.0, green: 128.0 / 255.0, blue: 0.0 }));
        assert_eq!(label(""), None);
        assert_eq!(label("zz0000"), None);
    }

    #[test]
    fn a_pr_approved_before_its_latest_commits_says_who_approved_which() {
        use codealong_peer::model::StaleApproval;
        let one = StaleApproval { by: vec!["ana".into()], commit: "1a2b3c4d5e".into() };
        assert_eq!(stale_words(PrState::Approved, Some(&one)).as_deref(), Some("Approved before its latest commits: ana approved 1a2b3c4. GitHub still counts the approval, as the repo doesn\u{2019}t dismiss it when commits come."));
        let three = StaleApproval { by: vec!["ana".into(), "ken".into(), "sam".into()], commit: "1a2b3c4d5e".into() };
        assert!(stale_words(PrState::Approved, Some(&three)).unwrap().starts_with("Approved before its latest commits: ana, ken and sam approved earlier ones, the latest 1a2b3c4."));
        // Only an approved PR is approved stale.
        assert_eq!(stale_words(PrState::Changes, Some(&one)), None);
        assert_eq!(stale_words(PrState::Approved, None), None);
    }

    #[test]
    fn whose_move_a_pr_is_says_what_its_macs_pill_does() {
        use codealong_peer::pr::{Turn, TurnKind};
        let turn = |kind: TurnKind, also: &[&str], since: Option<i64>| turn_line(&Turn { kind, who: "ana".into(), also: also.iter().map(|s| s.to_string()).collect(), since });
        let replied = turn(TurnKind::AuthorReplied, &[], Some(9)).unwrap();
        assert_eq!((replied.kind.as_str(), replied.words.as_str(), replied.yours), ("author-replied", "Author replied", true));
        assert_eq!(replied.says, "ana wrote {ago:9} after your last review or comment: your move.");
        // Theirs to do, each reviewer it holds for named.
        let asked = turn(TurnKind::RereviewAsked, &["ken", "sam"], None).unwrap();
        assert_eq!((asked.words.as_str(), asked.yours), ("Re-review asked", false));
        assert!(asked.says.starts_with("Waiting on ana, ken and sam, who asked for changes: asked to review it again or written to. "), "{}", asked.says);
        assert!(turn(TurnKind::ReplyNeeded, &[], Some(9)).unwrap().says.starts_with("Commits came {ago:9} after ana asked for changes,"));
        assert_eq!(turn(TurnKind::ReviewerReplied, &["ken"], None).unwrap().words, "Reviewer replied");
        // A kind a later Mac names leaves the PR's state to say it.
        assert_eq!(turn(TurnKind::Other, &[], None), None);
    }

    #[test]
    fn an_agent_review_says_where_its_round_stands_and_what_went_as_yours() {
        use codealong_peer::pr::{AutoReview, ReviewStage, Verdict};
        let round = |stage: ReviewStage| AutoReview { stage, head: "9f8e7d6c5b".into(), suggests: Some(Verdict::Approve), submitted: None, at: 0 };
        let posted = agent_review_line(&round(ReviewStage::Posted));
        assert_eq!((posted.stage.as_str(), posted.says.as_str(), posted.suggests.as_deref()), ("posted", "Agent reviewed 9f8e7d6 and commented", Some("Suggests approving")));
        // Under way, it suggests nothing yet.
        assert_eq!(agent_review_line(&round(ReviewStage::Reviewing)).suggests, None);
        // One submitted as yours says so, and suggests nothing more.
        let submitted = agent_review_line(&AutoReview { submitted: Some(Verdict::RequestChanges), ..round(ReviewStage::Posted) });
        assert_eq!((submitted.stage.as_str(), submitted.says.as_str(), submitted.suggests), ("submitted", "Agent requested changes on 9f8e7d6 for you", None));
    }

    #[test]
    fn a_pr_two_macs_list_is_asked_of_one_that_takes_remote_control_in_the_project_they_line_up() {
        use codealong_peer::client::Device;
        use codealong_peer::feed::Replica;
        let mac = |key: &str, remote_control: bool| Device { key: key.into(), short: key.into(), name: key.into(), online: true, since: None, last_seen: None, remote_control, app: String::new(), loading: false, linked_back: true };
        let card = |project: &str| serde_json::from_value::<codealong_peer::pr::PrCard>(serde_json::json!({"key": "O/App#5", "repo": "O/App", "project": project, "number": 5, "title": "T", "url": "u", "state": "open", "author": null, "head": "b"})).unwrap();
        // The first Mac lists its worktree of the repo in its project "Apps"; the second calls
        // its own project "app".
        let mut lane = codealong_peer::model::Lane::new("l1", "Apps", "App");
        lane.repo_slug = Some("O/App".into());
        let first = Replica { lanes: vec![lane], prs: vec![card("Apps")], ..Replica::default() };
        let second = Replica { prs: vec![card("app")], ..Replica::default() };
        let feeds = vec![(mac("watching", false), &first), (mac("driving", true), &second)];
        let prs = all_prs(&feeds, &crate::github::You::default());
        assert_eq!(prs.len(), 1);
        assert_eq!((prs[0].device.as_str(), prs[0].project.as_str()), ("driving", "Apps"));
    }

    #[test]
    fn whose_move_a_pr_is_is_your_accounts_and_waits_for_the_agent() {
        use codealong_peer::client::Device;
        use codealong_peer::feed::Replica;
        let mac = |key: &str, remote_control: bool| Device { key: key.into(), short: key.into(), name: key.into(), online: true, since: None, last_seen: None, remote_control, app: String::new(), loading: false, linked_back: true };
        let card = |number: u64, author: &str, mine: bool, extra: serde_json::Value| {
            let mut v = serde_json::json!({"key": format!("o/app#{number}"), "repo": "o/app", "project": "App", "number": number, "title": "T", "url": format!("https://github.com/o/app/pull/{number}"), "state": "changes", "author": author, "mine": mine, "head": "b"});
            v.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
            serde_json::from_value::<codealong_peer::pr::PrCard>(v).unwrap()
        };
        let replied = |kind: &str| serde_json::json!({"turn": {"kind": kind, "who": "ken", "since": 9}});
        // The mini, asked first as it takes remote control, is signed in as the bot its agents open
        // PRs as, and works out whose move #7 is for the bot; the laptop is signed in as you.
        let held = serde_json::json!({"turn": {"kind": "authorReplied", "who": "ken"}, "reviewRequested": true, "waits": false});
        let mini = Replica {
            prs: vec![
                card(1, "ann-bot", true, serde_json::json!({})),
                card(7, "ken", false, replied("reviewerReplied")),
                card(8, "ken", false, replied("authorReplied")),
                card(12, "ken", false, serde_json::json!({"state": "merged"})),
                card(13, "ken", false, serde_json::json!({})),
                card(16, "ken", false, serde_json::json!({})),
            ],
            ..Replica::default()
        };
        let laptop = Replica {
            prs: vec![
                card(2, "ann", true, serde_json::json!({})),
                card(7, "ken", false, replied("authorReplied")),
                // Held out of what waits on you while the agent reviews it.
                card(9, "ken", false, held.clone()),
                // A round under way that holds nothing (a PR of yours, or a hold that ran out).
                card(10, "ken", false, serde_json::json!({"turn": {"kind": "authorReplied", "who": "ken"}, "reviewRequested": true, "waits": true, "autoReview": {"stage": "reviewing", "head": "abc1234"}})),
                // Merged on the mini since the laptop last said.
                card(12, "ken", false, replied("authorReplied")),
                card(13, "ken", false, held),
                // Snoozed: held only while its round is under way.
                card(14, "ken", false, serde_json::json!({"turn": {"kind": "authorReplied", "who": "ken"}, "reviewRequested": true, "snoozedUntil": 99, "autoReview": {"stage": "queued", "head": "abc1234"}})),
                card(15, "ken", false, serde_json::json!({"turn": {"kind": "authorReplied", "who": "ken"}, "reviewRequested": true, "snoozedUntil": 99})),
                // Said to be no one's move here, which a Mac behind it doesn't undo.
                card(16, "ken", false, serde_json::json!({})),
            ],
            ..Replica::default()
        };
        let studio = Replica { prs: vec![card(16, "ken", false, replied("authorReplied"))], ..Replica::default() };
        let mut asleep = mac("studio", false);
        asleep.online = false;
        let feeds = vec![(mac("mini", true), &mini), (mac("laptop", false), &laptop), (asleep, &studio)];
        let signed_in: HashMap<String, String> = [("mini".to_string(), "ann-bot".to_string()), ("laptop".to_string(), "ann".to_string()), ("studio".to_string(), "ann".to_string())].into_iter().collect();
        let you = crate::github::You::of(&feeds, &signed_in, &["ann".to_string()]);
        let prs = all_prs(&feeds, &you);
        let turn = |n: u64| prs.iter().find(|p| p.number == n).and_then(|p| p.turn.as_ref()).map(|t| t.words.clone());
        // Asked of the mini, whose move it is as the laptop has it.
        assert_eq!(prs.iter().find(|p| p.number == 7).map(|p| p.device.as_str()), Some("mini"));
        assert_eq!(turn(7).as_deref(), Some("Author replied"));
        // Only the bot's Mac lists it: its state says what it can.
        assert_eq!(turn(8), None);
        // Not your move while the agent's review holds it, by the Mac that says so; a round that
        // holds nothing doesn't stand in its way.
        assert_eq!((turn(9), turn(13), turn(10).as_deref()), (None, None, Some("Author replied")));
        assert_eq!((turn(14), turn(15).as_deref()), (None, Some("Author replied")));
        // Nor does an older word from another Mac outlast the PR, or what a Mac ahead of it said.
        assert_eq!((turn(12), turn(16)), (None, None));
    }

    #[test]
    fn prs_are_yours_by_your_account_whichever_mac_lists_them() {
        use codealong_peer::client::Device;
        use codealong_peer::feed::Replica;
        let mac = |key: &str| Device { key: key.into(), short: key.into(), name: key.into(), online: true, since: None, last_seen: None, remote_control: true, app: String::new(), loading: false, linked_back: true };
        let card = |repo: &str, number: u64, author: &str, mine: bool| serde_json::from_value::<codealong_peer::pr::PrCard>(serde_json::json!({"key": format!("{repo}#{number}"), "repo": repo, "project": "App", "number": number, "title": "T", "url": format!("https://github.com/o/app/pull/{number}"), "state": "open", "author": author, "mine": mine, "head": "b"})).unwrap();
        // The mini, listed first, is signed in as the bot its agents open PRs as, and its checkout
        // still names the repo by its old name; the laptop is signed in as ann, who opened more of
        // what they list.
        let mini = Replica { prs: vec![card("old/app", 1, "ann", false), card("old/app", 3, "ann-bot", true)], ..Replica::default() };
        let laptop = Replica { prs: vec![card("o/app", 1, "ann", true), card("o/app", 2, "ann", true)], ..Replica::default() };
        let feeds = vec![(mac("mini"), &mini), (mac("laptop"), &laptop)];
        let signed_in: HashMap<String, String> = [("mini".to_string(), "ann-bot".to_string()), ("laptop".into(), "ann".into())].into();
        let seen = |picked: &[String]| -> Vec<(String, bool, bool, String, String)> {
            let mut prs: Vec<(String, bool, bool, String, String)> = all_prs(&feeds, &crate::github::You::of(&feeds, &signed_in, picked)).into_iter().map(|p| (p.key, p.mine, p.opened_by_its_mac, p.device, p.slug)).collect();
            prs.sort();
            prs
        };
        // Ann's are hers whichever Mac lists them, once each by their name on GitHub, and asked
        // of the Mac signed in as her; the bot's aren't, and its Mac can't approve them.
        let row = |n: u64, mine: bool, its: bool, mac: &str, slug: &str| (format!("o/app#{n}"), mine, its, mac.to_string(), slug.to_string());
        assert_eq!(seen(&[]), [row(1, true, true, "laptop", "o/app"), row(2, true, true, "laptop", "o/app"), row(3, false, true, "mini", "old/app")]);
        // Picked as yours too, the one both list is asked of the mini, under its own name for
        // the repo, and keeps its key.
        assert_eq!(seen(&["ann-bot".into()])[0], row(1, false, false, "mini", "old/app"));
        assert_eq!(seen(&["ann-bot".into(), "ann".into()])[2], row(3, true, true, "mini", "old/app"));
    }

    #[test]
    fn a_pr_from_before_its_repo_was_renamed_is_listed_once() {
        use codealong_peer::client::Device;
        use codealong_peer::feed::Replica;
        let mac = |key: &str, online: bool| Device { key: key.into(), short: key.into(), name: key.into(), online, since: None, last_seen: None, remote_control: true, app: String::new(), loading: false, linked_back: true };
        let card = |url: &str| serde_json::from_value::<codealong_peer::pr::PrCard>(serde_json::json!({"key": "old/app#1", "repo": "old/app", "project": "App", "number": 1, "title": "T", "url": url, "state": "open", "author": "ann", "head": "b"})).unwrap();
        // Both Macs' checkouts name the repo the old way; the one asleep was last heard before
        // the rename, with the old URL.
        let awake = Replica { prs: vec![card("https://github.com/new/app/pull/1")], ..Replica::default() };
        let asleep = Replica { prs: vec![card("https://github.com/old/app/pull/1")], ..Replica::default() };
        let feeds = vec![(mac("asleep", false), &asleep), (mac("awake", true), &awake)];
        let prs = all_prs(&feeds, &crate::github::You::default());
        assert_eq!(prs.iter().map(|p| (p.key.as_str(), p.device.as_str())).collect::<Vec<_>>(), [("new/app#1", "awake")]);
    }

    #[test]
    fn a_pr_has_the_sessions_that_worked_on_it_on_every_mac() {
        use codealong_peer::client::Device;
        use codealong_peer::feed::Replica;
        use codealong_peer::model::{Harness, Lane, Session};
        let mac = |key: &str, remote_control: bool| Device { key: key.into(), short: key.into(), name: key.into(), online: true, since: None, last_seen: None, remote_control, app: String::new(), loading: false, linked_back: true };
        let card = |url: &str, sessions: &[&str]| serde_json::from_value::<codealong_peer::pr::PrCard>(serde_json::json!({"key": "O/App#5", "repo": "O/App", "project": "Apps", "number": 5, "title": "T", "url": url, "state": "open", "author": null, "head": "b", "sessions": sessions})).unwrap();
        // Both Macs list it, each with the session there that worked on it, the second under the
        // repo's new name; the one asked about it is the one that takes remote control, and the
        // other's session is still its own.
        let watching = Replica { prs: vec![card("https://github.com/O/App/pull/5", &["claude:a:1"])], ..Replica::default() };
        let driving = Replica { prs: vec![card("https://github.com/N/App/pull/5", &["claude:b:2", "claude:b:3"])], ..Replica::default() };
        let feeds = vec![(mac("watching", false), &watching), (mac("driving", true), &driving)];
        let prs = all_prs(&feeds, &crate::github::You::default());
        assert_eq!(prs.len(), 1);
        assert_eq!(prs[0].device, "driving");
        assert_eq!(prs[0].sessions, vec!["@driving:claude:b:2", "@driving:claude:b:3", "@watching:claude:a:1"]);

        // A Mac whose PR list doesn't have it (an older build sends none; a PR merged a day ago
        // is left out) has only its worktrees to go by: two of one repo on the PR's branch each
        // add theirs.
        let pr = codealong_peer::model::Pr { number: 5, title: "T".into(), url: String::new(), state: PrState::Open, checks: Default::default(), merge: Default::default(), updated_at: 0, merged_at: None, closed_at: None, stale_approval: None };
        let lane = |id: &str, session: &str| {
            let mut l = Lane::new(id, "Apps", "App");
            l.repo_slug = Some("O/App".into());
            l.pr = Some(pr.clone());
            l.sessions = vec![Session::new(Harness::Claude, "c", session)];
            l
        };
        let other = serde_json::from_value::<codealong_peer::pr::PrCard>(serde_json::json!({"key": "O/App#9", "repo": "O/App", "project": "Apps", "number": 9, "title": "U", "url": "", "state": "open", "author": null, "head": "c", "sessions": ["claude:c:9"]})).unwrap();
        let old = Replica { lanes: vec![lane("l1", "4"), lane("l2", "5")], prs: vec![other], ..Replica::default() };
        let feeds = vec![(mac("driving", true), &driving), (mac("old", false), &old)];
        let prs = all_prs(&feeds, &crate::github::You::default());
        assert_eq!(prs.iter().map(|p| p.key.as_str()).collect::<Vec<_>>(), vec!["N/App#5", "O/App#9"]);
        assert_eq!(prs[0].sessions, vec!["@driving:claude:b:2", "@driving:claude:b:3", "@old:claude:c:4", "@old:claude:c:5"]);
    }

    #[test]
    fn a_prs_key_is_its_name_on_github() {
        assert_eq!(pr_key("https://github.com/new/app/pull/12", "old/app#12"), "new/app#12");
        assert_eq!(pr_key("https://ghe.example.com/o/app/pull/3#discussion", "o/app#3"), "o/app#3");
        assert_eq!(pr_key("", "app#4"), "app#4");
        assert_eq!(pr_key("https://github.com/o/app/issues/5", "o/app#5"), "o/app#5");
    }

    #[test]
    fn reviews_that_wait_on_you_follow_your_turn_the_longest_wait_first() {
        let rows = vec![row("turn", "Done", Status::Unread, NOW)];
        let mut late = pr_row("o/app#4", "Later", true);
        late.requested_at = Some(NOW - 5);
        let mut early = pr_row("o/app#5", "Earlier", true);
        early.requested_at = Some(NOW - 50);
        let prs = [late, early, pr_row("o/app#6", "Not asked", false)];
        let l = quick_list(&rows, &prs, "", "", &[], &[], NOW);
        assert_eq!(keys(&l)[..2], [(QuickGroup::YourTurn, vec!["turn".to_string()]), (QuickGroup::Reviews, vec!["o/app#5".to_string(), "o/app#4".into()])]);
        assert!(!l.nothing_waits);
        // A review alone is something waiting on you.
        assert!(!quick_list(&[], &prs, "", "", &[], &[], NOW).nothing_waits);
    }

    #[test]
    fn typed_words_find_titles_first_then_what_was_said() {
        let mut other = row("branch", "Fix login", Status::Idle, NOW);
        other.branch = Some("quick-search".into());
        let rows = vec![row("said", "Other work", Status::Needs, NOW), other, row("title", "Quick search on the phone", Status::Idle, NOW - 5)];
        let said = [SaidHit { key: "said".into(), snippet: "make the quick search".into(), you: true, at: NOW, score: 0 }];
        let prs = [pr_row("app#3", "Quick search", false)];
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
        let w = Worktree { id: "/r".into(), project: "App".into(), repo: "app".into(), name: "app".into(), branch: None, last_activity: NOW, device: "abcdef0123ffff".into(), main: true, chat: false, reuse: None, codealong: false, codealong_ios: false };
        let worktrees: HashMap<String, Worktree> = [(remote_key(short, "/r"), w)].into_iter().collect();
        let route = api::Route {
            action: api::Action::Send,
            actions: vec![(api::Action::Send, 0.8), (api::Action::Start, 0.2)],
            sessions: vec![api::Pick { id: "s1".into(), p: 0.9 }],
            no_session: 0.1,
            lanes: vec![api::Pick { id: "/r".into(), p: 1.0 }],
            repos: vec![],
            own_worktree: 0.7,
            own_worktree_asked: 0.7,
            no_repo: 0.0,
            habit: Default::default(),
            duplicate: None,
            agents: vec![],
            needs: None,
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
        assert_eq!(still_said(vec![SaidHit { key: "k".into(), snippet: "Quick search".into(), you: false, at: 0, score: 0 }], "quick sea".into()).len(), 1);
        assert!(still_said(vec![SaidHit { key: "k".into(), snippet: "Quick".into(), you: false, at: 0, score: 0 }], "quick sea".into()).is_empty());
    }

    #[test]
    fn short_words_count_whole_among_others_and_better_matches_lead() {
        let rows = vec![row("a", "Fix class names", Status::Idle, NOW), row("b", "Fix the c compiler", Status::Idle, NOW - 5)];
        // Alone, a short word is a search as you type; among others, only a whole word.
        assert_eq!(keys(&quick_list(&rows, &[], "", "c", &[], &[], NOW))[0].1, ["a", "b"]);
        assert_eq!(keys(&quick_list(&rows, &[], "", "fix c", &[], &[], NOW))[0].1, ["b"]);
        // Found by what was said, the better match leads.
        let said = [SaidHit { key: "a".into(), snippet: "webhook".into(), you: true, at: NOW, score: 1 }, SaidHit { key: "b".into(), snippet: "the webhook".into(), you: true, at: NOW, score: 9 }];
        assert_eq!(keys(&quick_list(&rows, &[], "", "webhook", &said, &[], NOW))[0].1, ["b", "a"]);
    }

    fn worktree(id: &str, main: bool, reuse: Option<crate::WorktreeReuse>, at: i64) -> Worktree {
        Worktree { id: id.into(), project: "App".into(), repo: "app".into(), name: id.trim_start_matches('/').into(), branch: None, last_activity: at, device: "abcdef0123ffff".into(), main, chat: false, reuse, codealong: false, codealong_ios: false }
    }

    fn route(lanes: &[(&str, f64)], own_worktree: f64, no_repo: f64) -> api::Route {
        api::Route {
            action: api::Action::Start,
            actions: vec![(api::Action::Start, 1.0)],
            sessions: vec![],
            no_session: 1.0,
            lanes: lanes.iter().map(|(id, p)| api::Pick { id: id.to_string(), p: *p }).collect(),
            no_repo,
            repos: vec![api::Pick { id: "App/app".into(), p: 1.0 }],
            own_worktree,
            own_worktree_asked: own_worktree,
            habit: Default::default(),
            duplicate: None,
            agents: vec![],
            needs: None,
            model: "jev".into(),
            ms: 1,
            input_tokens: 0,
        }
    }

    #[test]
    fn new_work_starts_in_a_free_reusable_worktree_or_a_chat() {
        use crate::WorktreeReuse::*;
        let short = "abcdef0123";
        let mut chats = worktree("/chats", false, None, 0);
        chats.chat = true;
        chats.project = crate::ELSEWHERE.into();
        let all = [worktree("/app", true, Some(Open), NOW), worktree("/app-2", false, Some(Landed), NOW - 10), worktree("/app-3", false, Some(Free), NOW - 20), worktree("/app-old", false, None, NOW - 30), chats];
        let worktrees: HashMap<String, Worktree> = all.iter().map(|w| (remote_key(short, &w.id), w.clone())).collect();
        let rows = HashMap::new();
        let start = |r: &api::Route| suggestions(r, short, &rows, &worktrees).into_iter().map(|s| (s.worktree.unwrap().id, s.new_worktree)).collect::<Vec<_>>();
        // Picked, the main checkout with work under way: new work goes to the free one, not the
        // landed one, though that was active since.
        assert_eq!(start(&route(&[("/app", 0.9)], 0.1, 0.0)), [("/app-3".to_string(), false)]);
        // Sure it wants a worktree of its own: a new one, made from the main checkout.
        assert_eq!(start(&route(&[("/app-3", 0.9)], 0.9, 0.0)), [("/app".to_string(), true)]);
        // A question about none of them goes to a chat, with the worktree after it.
        assert_eq!(start(&route(&[("/app-3", 0.4)], 0.1, 0.6)), [("/chats".to_string(), false), ("/app-3".to_string(), false)]);
        // Unsure of a chat, it comes after the worktree.
        assert_eq!(start(&route(&[("/app-3", 0.7)], 0.1, 0.3)), [("/app-3".to_string(), false), ("/chats".to_string(), false)]);

        // With nothing typed, a start goes to the latest repo's free worktree, else its main
        // checkout; never to a chat.
        assert_eq!(crate::start_worktree(&all, "").unwrap().id, "/app-3");
        let plain = [worktree("/app-old", false, None, NOW), worktree("/app", true, None, NOW - 10)];
        assert_eq!(crate::start_worktree(&plain, "").unwrap().id, "/app");
        assert!(crate::start_worktree(&all[4..], "").is_none());
    }
}
