//! The list's other pages and orders. The PRs page lists every PR the Macs know in groups, under
//! tabs for all of them, yours and others', as the Mac's PRs view leads with its pins and then what
//! needs you, by what it needs. Sessions by project go
//! worktree by worktree, as Codex's phone app groups its chats by folder, so a new session can
//! start in one. Recent is every session in the list, the last active first.

use std::collections::HashMap;

use codealong_peer::feed::remote_key;

use crate::{all_rows, all_worktrees, in_inbox, inbox_order, now_ms, project_list, Core, Feeds, PrRow, SessionRow, Status, Worktree};

/// Merged and closed PRs stay on the page this long after their last change.
const DONE_MS: i64 = 7 * 24 * 60 * 60 * 1000;

/// The PRs page's groups, as the Mac's PRs view heads them (PrsView.tsx `prSections`): the pinned
/// ones; then what needs you, under what it needs; then what Codealong's agent is still reviewing
/// for you; then the rest under headings of the tab's own (`PrTab`); then the ones you snoozed,
/// and the merged and closed ones last.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PrGroup {
    /// Pinned on their Macs, whatever their state, in every tab.
    Pinned,
    /// Waiting on your review: asked of you, open, not snoozed, and Codealong's agent isn't still
    /// reviewing it. The longest wait first.
    Requested,
    /// Yours, and GitHub would merge it now (`pr_ready`).
    Ready,
    /// Yours, and needing work: failing checks, changes asked for (unless their reviewer was asked
    /// to look again since), conflicts or a branch behind its base.
    Work,
    /// Asked of you, but Codealong's agent's review of it comes first: it waits on you once
    /// that's done.
    Agent,
    /// Out for review, with an agent of yours at work on what came of that (`PrAgentWork`): a
    /// merge or work of yours on it waits on that.
    Fixing,
    /// A draft an agent of yours is at work on.
    Working,
    /// Under All: the rest of your open PRs.
    Yours,
    /// Under All: the rest of everyone else's open PRs.
    Others,
    /// Under Yours: your open PRs that wait on someone else.
    Waiting,
    /// Under Yours: your drafts.
    Drafts,
    /// Under Others: everyone else's open PRs that don't ask for you.
    Unasked,
    /// Reviews you put off, the soonest back first.
    Snoozed,
    /// Merged or closed in the last week.
    Done,
}

/// Whose PRs the PRs page lists, as the Mac's PRs view's tabs (PrsView.tsx `PR_TABS`): every one,
/// the ones you opened, or everyone else's.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PrTab {
    All,
    Mine,
    Others,
}

/// The PRs page under a tab, with how many PRs under each tab need you, as the Mac's tabs count
/// them (`PrMoves`).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PrPage {
    pub sections: Vec<PrSection>,
    pub moves: PrMoves,
}

/// How many PRs under each tab are your move (`your_move`): a review asked of you, or one of yours
/// to merge or to work on.
#[derive(uniffi::Record, Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PrMoves {
    pub all: u32,
    pub mine: u32,
    pub others: u32,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PrSection {
    pub group: PrGroup,
    pub rows: Vec<PrRow>,
}

/// A worktree's sessions in the list, with the worktree to start a new one in.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct WorktreeGroup {
    /// `@<device short id>:<worktree id>`: unique across Macs.
    pub id: String,
    pub name: String,
    pub branch: Option<String>,
    pub device: String,
    pub device_name: String,
    /// Where a session starts in it, when its Mac lists it as a place to start (a worktree in no
    /// project doesn't).
    pub worktree: Option<Worktree>,
    pub sessions: Vec<SessionRow>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ProjectGroup {
    pub project: String,
    pub worktrees: Vec<WorktreeGroup>,
}

fn is_open(p: &PrRow) -> bool {
    !matches!(p.state.as_str(), "merged" | "closed")
}

/// GitHub would merge it now: open, not a draft, no conflicts, its checks passed and none running
/// (prStatus.ts `prReady`). Only GitHub can say so: approved with passing checks can still
/// conflict with its base.
fn pr_ready(p: &PrRow) -> bool {
    is_open(p) && p.state != "draft" && p.merge == "clean" && p.failing == 0 && p.pending == 0
}

/// What a PR needs of you, if it's your move (PrsView.tsx `prMove`): your review, asked for and
/// not put off or held for the agent's, whatever else is going on; or, for one of yours, a merge,
/// or work, but not while an agent of yours is at work on it (`PrRow::agent_work`), which that
/// waits on.
fn your_move(p: &PrRow) -> Option<PrGroup> {
    if !is_open(p) {
        return None;
    }
    if p.waits {
        return Some(PrGroup::Requested);
    }
    if !p.mine || (p.agent_work.is_some() && !p.review_requested) {
        return None;
    }
    if pr_ready(p) {
        return Some(PrGroup::Ready);
    }
    // Changes asked for are yours to make, unless their reviewer was asked to look again since,
    // which GitHub's request for changes doesn't say.
    let changes = p.state == "changes" && p.turn.as_ref().is_none_or(|t| t.kind != "rereview-asked");
    (p.failing > 0 || changes || matches!(p.merge.as_str(), "conflicts" | "behind")).then_some(PrGroup::Work)
}

/// Your review is asked for and put off until a time still to come.
fn review_snoozed(p: &PrRow) -> bool {
    p.review_requested && p.snoozed_until.is_some() && is_open(p)
}

/// It's listed under `tab`.
fn in_tab(p: &PrRow, tab: PrTab) -> bool {
    match tab {
        PrTab::All => true,
        PrTab::Mine => p.mine,
        PrTab::Others => !p.mine,
    }
}

/// How many PRs in `project` (empty for all) under each tab are your move.
pub(crate) fn pr_moves(prs: &[PrRow], project: &str) -> PrMoves {
    let mut out = PrMoves::default();
    for p in prs.iter().filter(|p| (project.is_empty() || p.project == project) && your_move(p).is_some()) {
        out.all += 1;
        if p.mine {
            out.mine += 1;
        } else {
            out.others += 1;
        }
    }
    out
}

/// The PRs page for `project` (empty for all) under `tab`, each PR in the first group it fits, as
/// the Mac's PRs view sorted by status has them (PrsView.tsx `prSections`): the pinned ones (in
/// every tab, as they lead every tab there); Review requested, Ready to merge, Needs work; Agent
/// reviewing; Fixing and Working, the ones an agent of yours is at work on; then All's Yours and
/// Others, Yours' Waiting on others and Drafts, or Others' Not asking you, with Snoozed after them
/// (before Not asking you, under Others); and the ones merged or closed in the last week last.
pub(crate) fn pr_sections(prs: &[PrRow], project: &str, tab: PrTab, now: i64) -> Vec<PrSection> {
    use PrGroup as G;
    let order: &[PrGroup] = match tab {
        PrTab::All => &[G::Pinned, G::Requested, G::Ready, G::Work, G::Agent, G::Fixing, G::Working, G::Yours, G::Others, G::Snoozed, G::Done],
        PrTab::Mine => &[G::Pinned, G::Requested, G::Ready, G::Work, G::Agent, G::Fixing, G::Working, G::Waiting, G::Drafts, G::Snoozed, G::Done],
        PrTab::Others => &[G::Pinned, G::Requested, G::Ready, G::Work, G::Agent, G::Fixing, G::Working, G::Snoozed, G::Unasked, G::Done],
    };
    let mut groups: Vec<(PrGroup, Vec<&PrRow>)> = order.iter().map(|g| (*g, Vec::new())).collect();
    for p in prs.iter().filter(|p| project.is_empty() || p.project == project) {
        let group = if p.pinned {
            G::Pinned
        } else if !in_tab(p, tab) {
            continue;
        } else if !is_open(p) {
            if now - p.updated_at > DONE_MS {
                continue;
            }
            G::Done
        } else if review_snoozed(p) {
            G::Snoozed
        } else if let Some(g) = your_move(p) {
            g
        } else if p.review_requested {
            // Asked of you, not snoozed, and not waiting on you: Codealong's agent holds it.
            G::Agent
        } else if let Some(work) = p.agent_work {
            match work {
                crate::quick::PrAgentWork::Fixing => G::Fixing,
                crate::quick::PrAgentWork::Working => G::Working,
            }
        } else {
            match tab {
                PrTab::All if p.mine => G::Yours,
                PrTab::All => G::Others,
                PrTab::Mine if p.state == "draft" => G::Drafts,
                PrTab::Mine => G::Waiting,
                PrTab::Others => G::Unasked,
            }
        };
        if let Some((_, rows)) = groups.iter_mut().find(|(g, _)| *g == group) {
            rows.push(p);
        }
    }
    groups
        .into_iter()
        .filter(|(_, rows)| !rows.is_empty())
        .map(|(group, mut rows)| {
            match group {
                PrGroup::Requested => rows.sort_by(|a, b| by_wait(a, b)),
                PrGroup::Snoozed => rows.sort_by_key(|p| (p.snoozed_until, p.key.clone())),
                _ => rows.sort_by(|a, b| b.updated_at.cmp(&a.updated_at).then_with(|| a.key.cmp(&b.key))),
            }
            PrSection { group, rows: rows.into_iter().cloned().collect() }
        })
        .collect()
}

/// The order PRs waiting on your review are gone through in, the longest wait first, as the Mac's
/// queue takes them: by when your review was asked for, else when the PR last changed.
pub(crate) fn by_wait(a: &PrRow, b: &PrRow) -> std::cmp::Ordering {
    (a.requested_at.unwrap_or(a.updated_at), &a.key).cmp(&(b.requested_at.unwrap_or(b.updated_at), &b.key))
}

/// The PRs waiting on your review, pinned or not, the longest wait first (`by_wait`).
pub(crate) fn waiting_reviews(prs: &[PrRow]) -> Vec<PrRow> {
    let mut out: Vec<PrRow> = prs.iter().filter(|p| p.waits).cloned().collect();
    out.sort_by(by_wait);
    out
}

/// The projects of the PRs the PRs page lists, for its pills: a project with only PRs in it,
/// none waiting on you, is on that page though the Sessions page has no pill for it.
pub(crate) fn pr_projects(prs: &[PrRow], now: i64) -> Vec<String> {
    let page = pr_sections(prs, "", PrTab::All, now);
    project_list(page.iter().flat_map(|s| s.rows.iter()).map(|p| p.project.as_str()).filter(|p| !p.is_empty()))
}

/// Where a status puts a session in its worktree: what needs you first, then the turns that
/// ended, then what's working, then the rest.
fn status_rank(s: Status) -> u8 {
    match s {
        Status::Needs | Status::Error => 0,
        Status::Unread => 1,
        Status::Working => 2,
        Status::Idle | Status::Stopped => 3,
    }
}

/// The list's sessions in `project` (empty for all): what the inbox lists, without the helpers
/// and headless runs that don't need you (`SessionRow::unattended`), as the quick search leaves
/// them out.
fn listed<'a>(rows: &'a [SessionRow], project: &'a str, now: i64) -> impl Iterator<Item = &'a SessionRow> {
    rows.iter().filter(move |r| in_inbox(r, now) && !r.unattended && (project.is_empty() || r.project == project))
}

/// The ones among `rows` hearing a meeting now, which lead every order, above the pinned ones,
/// in the list's order, as the Mac's Sessions view leads with them under Listening while they hear
/// (boardLists.ts `sessionTops`): a pinned one is there rather than among the pinned, and back in
/// its place once it stops.
pub(crate) fn listening_of<'a>(rows: &[&'a SessionRow]) -> Vec<&'a SessionRow> {
    let mut out: Vec<&SessionRow> = rows.iter().copied().filter(|r| r.listening).collect();
    out.sort_by(|a, b| inbox_order(a, b));
    out
}

/// It leads the list apart from the rest: an orchestrator's (`orchestrator_sessions`), hearing a
/// meeting (`listening_of`) or pinned (`pinned_of`).
pub(crate) fn leads(r: &SessionRow) -> bool {
    r.orchestrator.is_some() || r.listening || r.pinned.is_some()
}

/// The orchestrators' sessions By project and Recent lead with in `project` (empty for all),
/// above everything, as the Mac's Sessions view leads with them under Orchestrator
/// (orchestrators.ts `orchestratorsIn`): under a project, its orchestrator's, its name in any
/// case; under all, every one, All projects' first, then by project. From any worktree, however
/// long since it was prompted, since an orchestrator's session lives among Codealong's chats, in
/// no project, and keeps watch for as long as it's on. Never among the rest, the pinned or the
/// ones hearing a meeting.
pub(crate) fn orchestrator_sessions(rows: &[SessionRow], project: &str) -> Vec<SessionRow> {
    let scope = |r: &SessionRow| r.orchestrator.as_ref().map(|o| o.project.clone().unwrap_or_default());
    let mut out: Vec<SessionRow> = rows.iter().filter(|r| !r.archived && scope(r).is_some_and(|p| project.is_empty() || p.eq_ignore_ascii_case(project))).cloned().collect();
    let by = |r: &SessionRow| scope(r).map(|p| p.to_lowercase());
    out.sort_by(|a, b| by(a).cmp(&by(b)).then_with(|| a.device_name.cmp(&b.device_name)).then_with(|| a.key.cmp(&b.key)));
    out
}

/// The pinned ones among `rows`, in their Macs' order: by place, two Macs' firsts by Mac. One
/// hearing a meeting leads above them instead (`listening_of`).
pub(crate) fn pinned_of<'a>(rows: &[&'a SessionRow]) -> Vec<&'a SessionRow> {
    let mut out: Vec<&SessionRow> = rows.iter().copied().filter(|r| r.pinned.is_some() && !r.listening).collect();
    out.sort_by(|a, b| a.pinned.cmp(&b.pinned).then_with(|| a.device_name.cmp(&b.device_name)).then_with(|| a.key.cmp(&b.key)));
    out
}

/// The list's sessions in `project` (empty for all) hearing a meeting now, which lead every order
/// above the pinned ones (`listening_of`): helpers too, as the pinned ones.
pub(crate) fn listening_sessions(rows: &[SessionRow], project: &str, now: i64) -> Vec<SessionRow> {
    let these: Vec<&SessionRow> = rows.iter().filter(|r| in_inbox(r, now) && r.orchestrator.is_none() && (project.is_empty() || r.project == project)).collect();
    listening_of(&these).into_iter().cloned().collect()
}

/// The list's pinned sessions in `project` (empty for all), which lead every order: helpers too,
/// whom the rest of the list leaves out, since a pin is yours to make.
pub(crate) fn pinned_sessions(rows: &[SessionRow], project: &str, now: i64) -> Vec<SessionRow> {
    let these: Vec<&SessionRow> = rows.iter().filter(|r| in_inbox(r, now) && r.orchestrator.is_none() && (project.is_empty() || r.project == project)).collect();
    pinned_of(&these).into_iter().cloned().collect()
}

/// Sessions by project and worktree, the pinned ones left to lead apart (`pinned_sessions`): the
/// project and the worktree with the last activity first,
/// and in a worktree, what needs you first, the ones moved to the top first among their kind, then
/// the newest, as the Mac's lanes sort them. `worktrees` are the places to start,
/// keyed by `@<device short id>:<id>`, and `shorts` each Mac's short id by its key.
pub(crate) fn project_groups(rows: &[SessionRow], worktrees: &HashMap<String, Worktree>, shorts: &HashMap<&str, &str>, project: &str, now: i64) -> Vec<ProjectGroup> {
    let mut by_worktree: HashMap<String, (String, WorktreeGroup)> = HashMap::new();
    for r in listed(rows, project, now).filter(|r| !leads(r)) {
        let id = remote_key(shorts.get(r.device.as_str()).copied().unwrap_or(&r.device), &r.worktree_id);
        let (_, group) = by_worktree.entry(id.clone()).or_insert_with(|| {
            let group = WorktreeGroup { id: id.clone(), name: r.worktree.clone(), branch: r.branch.clone(), device: r.device.clone(), device_name: r.device_name.clone(), worktree: worktrees.get(&id).cloned(), sessions: Vec::new() };
            (r.project.clone(), group)
        });
        group.sessions.push(r.clone());
    }
    let latest = |g: &WorktreeGroup| g.sessions.iter().map(|s| s.last_activity).max().unwrap_or(0);
    let mut projects: Vec<ProjectGroup> = Vec::new();
    for (project, mut group) in by_worktree.into_values() {
        group.sessions.sort_by(|a, b| status_rank(a.status).cmp(&status_rank(b.status)).then_with(|| crate::raised_order(a.raised.as_ref(), b.raised.as_ref())).then(b.last_activity.cmp(&a.last_activity)).then_with(|| a.key.cmp(&b.key)));
        match projects.iter_mut().find(|p| p.project == project) {
            Some(p) => p.worktrees.push(group),
            None => projects.push(ProjectGroup { project, worktrees: vec![group] }),
        }
    }
    for p in &mut projects {
        p.worktrees.sort_by(|a, b| latest(b).cmp(&latest(a)).then_with(|| a.id.cmp(&b.id)));
    }
    let project_latest = |p: &ProjectGroup| p.worktrees.first().map(latest).unwrap_or(0);
    projects.sort_by(|a, b| project_latest(b).cmp(&project_latest(a)).then_with(|| a.project.cmp(&b.project)));
    projects
}

/// The list's sessions in `project` (empty for all), the last active first, the pinned ones left
/// to lead apart.
pub(crate) fn recent_sessions(rows: &[SessionRow], project: &str, now: i64) -> Vec<SessionRow> {
    let mut out: Vec<SessionRow> = listed(rows, project, now).filter(|r| !leads(r)).cloned().collect();
    out.sort_by(|a, b| b.last_activity.cmp(&a.last_activity).then_with(|| a.key.cmp(&b.key)));
    out
}

fn shorts<'a>(feeds: &'a Feeds) -> HashMap<&'a str, &'a str> {
    feeds.iter().map(|(d, _)| (d.key.as_str(), d.short.as_str())).collect()
}

#[uniffi::export]
impl Core {
    /// The PRs page for `project` (empty for all) under `tab`, with how many are your move under
    /// each tab.
    pub fn pr_list(&self, project: String, tab: PrTab) -> PrPage {
        self.client.with_feeds(|feeds| {
            let prs = crate::quick::all_prs(feeds, &self.you(feeds));
            PrPage { sections: pr_sections(&prs, &project, tab, now_ms()), moves: pr_moves(&prs, &project) }
        })
    }

    /// The PRs waiting on your review in every project, pinned or not, the longest wait first: as
    /// the Mac's queue goes through them, between the sessions that need you and Your turn.
    pub fn review_queue(&self) -> Vec<PrRow> {
        self.client.with_feeds(|feeds| waiting_reviews(&crate::quick::all_prs(feeds, &self.you(feeds))))
    }

    /// The list's sessions by project and worktree, in `project` (empty for all).
    pub fn by_project(&self, project: String) -> Vec<ProjectGroup> {
        self.client.with_feeds(|feeds| {
            let shorts = shorts(feeds);
            let worktrees: HashMap<String, Worktree> = all_worktrees(feeds).into_iter().filter_map(|w| Some((remote_key(shorts.get(w.device.as_str())?, &w.id), w))).collect();
            project_groups(&all_rows(feeds), &worktrees, &shorts, &project, now_ms())
        })
    }

    /// The list's sessions in `project` (empty for all), the last active first.
    pub fn recent(&self, project: String) -> Vec<SessionRow> {
        self.client.with_feeds(|feeds| recent_sessions(&all_rows(feeds), &project, now_ms()))
    }

    /// The list's pinned sessions in `project` (empty for all), in their Macs' order: they lead
    /// By project and Recent, as `quick` puts them first.
    pub fn pinned(&self, project: String) -> Vec<SessionRow> {
        self.client.with_feeds(|feeds| pinned_sessions(&all_rows(feeds), &project, now_ms()))
    }

    /// The list's sessions in `project` (empty for all) hearing a meeting now: they lead By project
    /// and Recent above the pinned ones, as `quick` puts them first.
    pub fn listening(&self, project: String) -> Vec<SessionRow> {
        self.client.with_feeds(|feeds| listening_sessions(&all_rows(feeds), &project, now_ms()))
    }

    /// The orchestrators' sessions for `project` (empty for all), which lead By project and Recent
    /// above everything (`orchestrator_sessions`).
    pub fn orchestrators(&self, project: String) -> Vec<SessionRow> {
        self.client.with_feeds(|feeds| orchestrator_sessions(&all_rows(feeds), &project))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::quick::tests::{pr_row, row};

    const NOW: i64 = 100 * 24 * 60 * 60 * 1000;
    const HOUR: i64 = 60 * 60 * 1000;

    fn pr(number: u64, state: &str, updated_at: i64) -> PrRow {
        let mut p = pr_row(&format!("O/app#{number}"), "T", false);
        p.number = number;
        p.state = state.into();
        p.updated_at = updated_at;
        p
    }

    fn session(key: &str, status: Status, at: i64) -> SessionRow {
        row(key, key, status, at)
    }

    fn groups(sections: &[PrSection]) -> Vec<(PrGroup, Vec<u64>)> {
        sections.iter().map(|s| (s.group, s.rows.iter().map(|p| p.number).collect())).collect()
    }

    #[test]
    fn reviews_waiting_go_by_how_long_they_have_waited_pinned_or_not() {
        let mut pinned = pr(1, "open", NOW - HOUR);
        pinned.pinned = true;
        pinned.waits = true;
        pinned.requested_at = Some(NOW - 10 * HOUR);
        let mut asked_long_ago = pr(2, "open", NOW - HOUR);
        asked_long_ago.waits = true;
        asked_long_ago.requested_at = Some(NOW - 48 * HOUR);
        let mut asked_lately = pr(3, "open", NOW - 30 * HOUR);
        asked_lately.waits = true;
        asked_lately.requested_at = Some(NOW - 2 * HOUR);
        // With no time it was asked for, it goes by when it last changed.
        let mut unasked = pr(4, "open", NOW - 5 * HOUR);
        unasked.waits = true;
        let not_waiting = pr(5, "open", NOW - 72 * HOUR);
        let order: Vec<u64> = waiting_reviews(&[asked_lately, not_waiting, pinned, unasked, asked_long_ago]).iter().map(|p| p.number).collect();
        assert_eq!(order, vec![2, 1, 4, 3]);
    }

    #[test]
    fn prs_go_in_the_first_group_they_fit() {
        let mut pinned = pr(1, "open", NOW - HOUR);
        pinned.pinned = true;
        pinned.waits = true;
        let mut asked_long_ago = pr(2, "open", NOW - HOUR);
        asked_long_ago.waits = true;
        asked_long_ago.review_requested = true;
        asked_long_ago.requested_at = Some(NOW - 48 * HOUR);
        let mut asked_lately = pr(3, "open", NOW - 30 * HOUR);
        asked_lately.waits = true;
        asked_lately.review_requested = true;
        asked_lately.requested_at = Some(NOW - 2 * HOUR);
        let mut mine = pr(4, "approved", NOW - 3 * HOUR);
        mine.mine = true;
        let theirs = pr(5, "draft", NOW - 4 * HOUR);
        let mut snoozed = pr(6, "open", NOW - HOUR);
        snoozed.review_requested = true;
        snoozed.snoozed_until = Some(NOW + HOUR);
        let merged = pr(7, "merged", NOW - 24 * HOUR);
        let long_closed = pr(8, "closed", NOW - 8 * 24 * HOUR);
        let mut mine_merged = pr(9, "merged", NOW - 2 * HOUR);
        mine_merged.mine = true;
        let all = [theirs, merged, mine, long_closed, asked_lately, snoozed, pinned, asked_long_ago, mine_merged];
        assert_eq!(
            groups(&pr_sections(&all, "", PrTab::All, NOW)),
            vec![(PrGroup::Pinned, vec![1]), (PrGroup::Requested, vec![2, 3]), (PrGroup::Ready, vec![4]), (PrGroup::Others, vec![5]), (PrGroup::Snoozed, vec![6]), (PrGroup::Done, vec![9, 7])]
        );
    }

    #[test]
    fn what_needs_you_leads_each_tab_by_what_it_needs() {
        use PrGroup as G;
        let open = |number: u64, mine: bool| {
            let mut p = pr(number, "open", NOW - number as i64 * HOUR);
            p.mine = mine;
            p.merge = "blocked".into();
            p
        };
        let mut asked = open(1, false);
        (asked.waits, asked.review_requested) = (true, true);
        // Asked of you, but Codealong's agent holds it until its review is done.
        let mut held = open(2, false);
        held.review_requested = true;
        let mut ready = open(3, true);
        (ready.state, ready.merge) = ("approved".into(), "clean".into());
        // Clean but its checks still run: not ready, nor anything to do.
        let mut running = open(4, true);
        (running.merge, running.pending) = ("clean".into(), 2);
        let mut failing = open(5, true);
        failing.failing = 1;
        let mut changes = open(6, true);
        changes.state = "changes".into();
        // Changes asked for, but their reviewer was asked to look again since: theirs to do.
        let mut rereview = open(7, true);
        rereview.state = "changes".into();
        rereview.turn = Some(crate::quick::PrTurn { kind: "rereview-asked".into(), words: String::new(), yours: false, says: String::new() });
        let mut behind = open(8, true);
        behind.merge = "behind".into();
        let mut draft = open(9, true);
        draft.state = "draft".into();
        // Someone else's failing PR isn't yours to fix.
        let mut theirs_failing = open(10, false);
        theirs_failing.failing = 3;
        let mut snoozed = open(11, false);
        (snoozed.review_requested, snoozed.snoozed_until) = (true, Some(NOW + HOUR));
        let mut merged = pr(12, "merged", NOW - HOUR);
        merged.mine = true;
        let all = [asked, held, ready, running, failing, changes, rereview, behind, draft, theirs_failing, snoozed, merged];
        assert_eq!(
            groups(&pr_sections(&all, "", PrTab::All, NOW)),
            vec![(G::Requested, vec![1]), (G::Ready, vec![3]), (G::Work, vec![5, 6, 8]), (G::Agent, vec![2]), (G::Yours, vec![4, 7, 9]), (G::Others, vec![10]), (G::Snoozed, vec![11]), (G::Done, vec![12])]
        );
        assert_eq!(groups(&pr_sections(&all, "", PrTab::Mine, NOW)), vec![(G::Ready, vec![3]), (G::Work, vec![5, 6, 8]), (G::Waiting, vec![4, 7]), (G::Drafts, vec![9]), (G::Done, vec![12])]);
        assert_eq!(groups(&pr_sections(&all, "", PrTab::Others, NOW)), vec![(G::Requested, vec![1]), (G::Agent, vec![2]), (G::Snoozed, vec![11]), (G::Unasked, vec![10])]);
        assert_eq!(pr_moves(&all, ""), PrMoves { all: 5, mine: 4, others: 1 });
        assert_eq!(pr_moves(&all, "Other"), PrMoves::default());
    }

    #[test]
    fn prs_an_agent_of_yours_is_at_work_on_go_under_fixing_and_working() {
        use crate::quick::PrAgentWork;
        use PrGroup as G;
        let open = |number: u64, mine: bool, work: Option<PrAgentWork>| {
            let mut p = pr(number, "open", NOW - number as i64 * HOUR);
            (p.mine, p.merge, p.agent_work) = (mine, "blocked".into(), work);
            p
        };
        // Your own failing PR an agent is fixing isn't your work while it does.
        let mut fixing = open(1, true, Some(PrAgentWork::Fixing));
        fixing.failing = 2;
        // Nor is a merge of one it's at work on.
        let mut ready = open(2, true, Some(PrAgentWork::Fixing));
        (ready.state, ready.merge) = ("approved".into(), "clean".into());
        let mut draft = open(3, true, Some(PrAgentWork::Working));
        draft.state = "draft".into();
        // A review asked of you is yours whatever an agent does.
        let mut asked = open(4, false, Some(PrAgentWork::Fixing));
        (asked.waits, asked.review_requested) = (true, true);
        // Someone else's that an agent of yours works on.
        let theirs = open(5, false, Some(PrAgentWork::Fixing));
        let mut failing = open(6, true, None);
        failing.failing = 1;
        let all = [fixing, ready, draft, asked, theirs, failing];
        assert_eq!(
            groups(&pr_sections(&all, "", PrTab::All, NOW)),
            vec![(G::Requested, vec![4]), (G::Work, vec![6]), (G::Fixing, vec![1, 2, 5]), (G::Working, vec![3])]
        );
        assert_eq!(groups(&pr_sections(&all, "", PrTab::Mine, NOW)), vec![(G::Work, vec![6]), (G::Fixing, vec![1, 2]), (G::Working, vec![3])]);
        assert_eq!(groups(&pr_sections(&all, "", PrTab::Others, NOW)), vec![(G::Requested, vec![4]), (G::Fixing, vec![5])]);
        // The tabs count only what's your move.
        assert_eq!(pr_moves(&all, ""), PrMoves { all: 2, mine: 1, others: 1 });
    }

    #[test]
    fn pinned_prs_lead_every_tab() {
        let mut theirs = pr(1, "open", NOW);
        theirs.pinned = true;
        let mut mine = pr(2, "open", NOW);
        (mine.pinned, mine.mine) = (true, true);
        let rows = [theirs, mine];
        for tab in [PrTab::All, PrTab::Mine, PrTab::Others] {
            assert_eq!(groups(&pr_sections(&rows, "", tab, NOW)), vec![(PrGroup::Pinned, vec![1, 2])]);
        }
    }

    #[test]
    fn the_prs_page_narrows_to_a_project() {
        let mut other = pr(2, "open", NOW);
        other.project = "Other".into();
        assert_eq!(groups(&pr_sections(&[pr(1, "open", NOW), other], "App", PrTab::All, NOW)), vec![(PrGroup::Others, vec![1])]);
    }

    #[test]
    fn pinned_sessions_lead_apart_in_their_macs_order() {
        let mut first_here = in_worktree("a", "App", "app-1", Status::Idle, NOW - HOUR);
        first_here.pinned = Some(0);
        first_here.device_name = "Studio".into();
        let mut first_there = in_worktree("b", "App", "app-2", Status::Needs, NOW - 2 * HOUR);
        first_there.pinned = Some(0);
        first_there.device_name = "Air".into();
        // A pin keeps a session listed however long ago it was last prompted.
        let mut second_old = in_worktree("c", "App", "app-1", Status::Idle, NOW - 9 * 24 * HOUR);
        second_old.pinned = Some(1);
        second_old.last_prompt_at = NOW - 9 * 24 * HOUR;
        let plain = in_worktree("d", "App", "app-1", Status::Idle, NOW - 3 * HOUR);
        // A helper pinned, from a search, leads with them.
        let mut helper = in_worktree("h", "App", "app-1", Status::Idle, NOW - HOUR);
        helper.unattended = true;
        helper.pinned = Some(2);
        let rows = [plain, second_old, first_here, first_there, helper];
        let keys = |rows: Vec<SessionRow>| rows.into_iter().map(|r| r.key).collect::<Vec<_>>();
        assert_eq!(keys(pinned_sessions(&rows, "", NOW)), vec!["b", "a", "c", "h"]);
        assert_eq!(keys(pinned_sessions(&rows, "Other", NOW)), Vec::<String>::new());
        // By project and Recent leave them to lead apart.
        assert_eq!(keys(recent_sessions(&rows, "", NOW)), vec!["d"]);
        let by = project_groups(&rows, &HashMap::new(), &HashMap::new(), "", NOW);
        assert_eq!(by.iter().flat_map(|p| p.worktrees.iter().flat_map(|w| w.sessions.iter().map(|s| s.key.clone()))).collect::<Vec<_>>(), vec!["d"]);
    }

    #[test]
    fn sessions_hearing_a_meeting_lead_apart_above_the_pinned() {
        let mut hearing = in_worktree("l", "App", "app-1", Status::Working, NOW - HOUR);
        hearing.listening = true;
        // Pinned, it leads with the ones hearing while it hears, not with the pinned.
        let mut pinned_hearing = in_worktree("p", "App", "app-1", Status::Working, NOW - 2 * HOUR);
        (pinned_hearing.listening, pinned_hearing.pinned) = (true, Some(0));
        let mut pinned = in_worktree("q", "App", "app-1", Status::Idle, NOW - HOUR);
        pinned.pinned = Some(1);
        let plain = in_worktree("d", "App", "app-1", Status::Idle, NOW - 3 * HOUR);
        let rows = [plain, pinned, pinned_hearing, hearing];
        let keys = |rows: Vec<SessionRow>| rows.into_iter().map(|r| r.key).collect::<Vec<_>>();
        assert_eq!(keys(listening_sessions(&rows, "", NOW)), vec!["l", "p"]);
        assert_eq!(keys(pinned_sessions(&rows, "", NOW)), vec!["q"]);
        assert_eq!(keys(recent_sessions(&rows, "", NOW)), vec!["d"]);
        let by = project_groups(&rows, &HashMap::new(), &HashMap::new(), "", NOW);
        assert_eq!(by.iter().flat_map(|p| p.worktrees.iter().flat_map(|w| w.sessions.iter().map(|s| s.key.clone()))).collect::<Vec<_>>(), vec!["d"]);
    }

    #[test]
    fn orchestrators_lead_what_they_keep_watch_over_and_go_among_nothing() {
        let watching = |key: &str, project: Option<&str>| {
            let mut s = in_worktree(key, crate::ELSEWHERE, "chats", Status::Idle, NOW - HOUR);
            s.orchestrator = Some(crate::OrchestratorOf { project: project.map(str::to_string), words: String::new(), paused: false, looked_at: None, header: String::new() });
            s
        };
        let all = watching("all", None);
        // Not prompted for a week, and pinned too: it still leads, and only there.
        let mut app = watching("app", Some("app"));
        (app.last_prompt_at, app.last_activity, app.pinned) = (NOW - 7 * 24 * HOUR, NOW - 7 * 24 * HOUR, Some(0));
        let site = watching("site", Some("Site"));
        let mut gone = watching("gone", Some("App"));
        gone.archived = true;
        let plain = in_worktree("d", "App", "app-1", Status::Idle, NOW - 3 * HOUR);
        let chat = in_worktree("c", crate::ELSEWHERE, "chats", Status::Idle, NOW - 2 * HOUR);
        let rows = [plain, site, app, chat, gone, all];
        let keys = |rows: Vec<SessionRow>| rows.into_iter().map(|r| r.key).collect::<Vec<_>>();
        // Under all, every one, All projects' first, then by project; under a project, its own,
        // its name in any case.
        assert_eq!(keys(orchestrator_sessions(&rows, "")), vec!["all", "app", "site"]);
        assert_eq!(keys(orchestrator_sessions(&rows, "App")), vec!["app"]);
        assert_eq!(keys(orchestrator_sessions(&rows, crate::ELSEWHERE)), Vec::<String>::new());
        // Never among the rest, the pinned or the chats they're kept in.
        assert_eq!(keys(pinned_sessions(&rows, "", NOW)), Vec::<String>::new());
        assert_eq!(keys(recent_sessions(&rows, "", NOW)), vec!["c", "d"]);
        let by = project_groups(&rows, &HashMap::new(), &HashMap::new(), "", NOW);
        assert_eq!(by.iter().flat_map(|p| p.worktrees.iter().flat_map(|w| w.sessions.iter().map(|s| s.key.clone()))).collect::<Vec<_>>(), vec!["c", "d"]);
    }

    #[test]
    fn an_orchestrator_says_what_it_keeps_watch_over() {
        use codealong_peer::model::Orchestrator;
        let looked = |project: Option<&str>, paused, looked_at| crate::orchestrator_of(&Orchestrator { schedule: "s-1".into(), project: project.map(str::to_string), paused, looked_at }, str::to_string);
        let of = |project: Option<&str>, paused| looked(project, paused, None);
        assert_eq!(of(Some("Northwind"), false).words, "Keeps watch over Northwind");
        assert_eq!(of(None, false).words, "Keeps watch over All projects");
        assert_eq!(of(Some(" "), false).project, None);
        assert!(of(None, true).paused);
        assert_eq!(of(None, true).words, "Paused: keeps watch over nothing in All projects");
        // Its page's line says when it last looked, as a live time, or that it's off; before its
        // first look, and from Macs that don't say, only what it keeps watch over.
        assert_eq!(looked(Some("Northwind"), false, Some(5_000)).header, "Looked {ago:5000} \u{b7} Orchestrator for Northwind");
        assert_eq!(looked(None, true, Some(5_000)).header, "Off \u{b7} Orchestrator for All projects");
        assert_eq!(of(None, false).header, "Orchestrator for All projects");
    }

    #[test]
    fn the_prs_pages_pills_are_its_prs_projects() {
        let mut theirs = pr(1, "open", NOW);
        theirs.project = "Site".into();
        let mut long_merged = pr(2, "merged", NOW - 8 * 24 * HOUR);
        long_merged.project = "Old".into();
        let mut no_project = pr(3, "open", NOW);
        no_project.project = String::new();
        let app = pr(4, "draft", NOW);
        assert_eq!(pr_projects(&[theirs, long_merged, no_project, app], NOW), vec!["App".to_string(), "Site".to_string()]);
    }

    fn in_worktree(key: &str, project: &str, worktree: &str, status: Status, at: i64) -> SessionRow {
        let mut s = session(key, status, at);
        s.project = project.into();
        s.worktree = worktree.into();
        s.worktree_id = format!("/src/{worktree}");
        s
    }

    #[test]
    fn in_a_worktree_the_ones_moved_to_the_top_lead_their_kind() {
        let up = SessionRow { raised: Some(crate::Raised { at: NOW, agent: false, says: String::new(), phrase: String::new() }), ..in_worktree("up", "App", "app", Status::Unread, NOW - 5 * HOUR) };
        let rows = [in_worktree("new", "App", "app", Status::Unread, NOW - HOUR), up, in_worktree("needs", "App", "app", Status::Needs, NOW - 9 * HOUR)];
        let out = project_groups(&rows, &HashMap::new(), &HashMap::new(), "", NOW);
        // What needs you still comes first, as a lane sorts them on the Mac.
        assert_eq!(out[0].worktrees[0].sessions.iter().map(|s| s.key.as_str()).collect::<Vec<_>>(), ["needs", "up", "new"]);
    }

    #[test]
    fn sessions_by_project_go_worktree_by_worktree() {
        let rows = [
            in_worktree("a", "App", "app-1", Status::Idle, NOW - HOUR),
            in_worktree("b", "App", "app-1", Status::Needs, NOW - 5 * HOUR),
            in_worktree("c", "App", "app-2", Status::Unread, NOW - 2 * HOUR),
            in_worktree("d", "Site", "site", Status::Working, NOW - 10 * 60 * 1000),
        ];
        let start = Worktree { id: "/src/app-2".into(), project: "App".into(), repo: "app".into(), name: "app-2".into(), branch: None, last_activity: NOW, device: "d".into(), main: false, folder: false, chat: false, reuse: None, codealong: false, codealong_ios: false };
        let worktrees = HashMap::from([("@dshort:/src/app-2".to_string(), start.clone())]);
        let shorts = HashMap::from([("d", "dshort")]);
        let out = project_groups(&rows, &worktrees, &shorts, "", NOW);
        let shape: Vec<(String, Vec<(String, Vec<String>)>)> = out.iter().map(|p| (p.project.clone(), p.worktrees.iter().map(|w| (w.name.clone(), w.sessions.iter().map(|s| s.key.clone()).collect())).collect())).collect();
        // The project and worktree active last lead; in a worktree what needs you comes first.
        assert_eq!(
            shape,
            vec![
                ("Site".to_string(), vec![("site".to_string(), vec!["d".to_string()])]),
                ("App".to_string(), vec![("app-1".to_string(), vec!["b".to_string(), "a".to_string()]), ("app-2".to_string(), vec!["c".to_string()])]),
            ]
        );
        assert_eq!(out[1].worktrees[1].worktree, Some(start));
        assert_eq!(out[1].worktrees[0].worktree, None);
        assert_eq!(out[1].worktrees[1].id, "@dshort:/src/app-2");
    }

    #[test]
    fn by_project_and_recent_leave_out_what_the_list_does() {
        let mut helper = in_worktree("h", "App", "app-1", Status::Unread, NOW - HOUR);
        helper.unattended = true;
        // A helper that needs you isn't unattended (`Session::unattended`): it's listed.
        let asking_helper = in_worktree("k", "App", "app-1", Status::Needs, NOW - HOUR);
        let mut old = in_worktree("o", "App", "app-1", Status::Idle, NOW - 5 * 24 * HOUR);
        old.last_prompt_at = NOW - 5 * 24 * HOUR;
        let other = in_worktree("x", "Site", "site", Status::Idle, NOW - 3 * HOUR);
        let kept = in_worktree("a", "App", "app-1", Status::Idle, NOW - 2 * HOUR);
        let rows = [helper, asking_helper, old, other, kept];
        let keys = |rows: Vec<SessionRow>| rows.into_iter().map(|r| r.key).collect::<Vec<_>>();
        assert_eq!(keys(recent_sessions(&rows, "App", NOW)), vec!["k", "a"]);
        assert_eq!(keys(recent_sessions(&rows, "", NOW)), vec!["k", "a", "x"]);
        let by = project_groups(&rows, &HashMap::new(), &HashMap::new(), "App", NOW);
        assert_eq!(by.len(), 1);
        assert_eq!(keys(by[0].worktrees[0].sessions.clone()), vec!["k", "a"]);
    }
}
