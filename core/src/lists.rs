//! The list's other pages and orders. The PRs page lists every PR the Macs know in groups, as the
//! Mac's PRs view leads with its pins and the reviews asked of you. Sessions by project go
//! worktree by worktree, as Codex's phone app groups its chats by folder, so a new session can
//! start in one. Recent is every session in the list, the last active first.

use std::collections::HashMap;

use codealong_peer::feed::remote_key;

use crate::{all_rows, all_worktrees, in_inbox, now_ms, Core, Feeds, PrRow, SessionRow, Status, Worktree};

/// Merged and closed PRs stay on the page this long after their last change.
const DONE_MS: i64 = 7 * 24 * 60 * 60 * 1000;

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PrGroup {
    /// Pinned on their Mac, whatever their state.
    Pinned,
    /// Waiting on your review, the longest wait first.
    Reviews,
    /// Open PRs you opened.
    Yours,
    /// Every other open PR.
    Others,
    /// Reviews you put off, the soonest back first.
    Snoozed,
    /// Merged or closed in the last week.
    Done,
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

/// The PRs page for `project` (empty for all), each PR in the first group it fits.
pub(crate) fn pr_sections(prs: &[PrRow], project: &str, now: i64) -> Vec<PrSection> {
    let mut groups: Vec<(PrGroup, Vec<&PrRow>)> = [PrGroup::Pinned, PrGroup::Reviews, PrGroup::Yours, PrGroup::Others, PrGroup::Snoozed, PrGroup::Done].into_iter().map(|g| (g, Vec::new())).collect();
    for p in prs.iter().filter(|p| project.is_empty() || p.project == project) {
        let group = if p.pinned {
            PrGroup::Pinned
        } else if p.waits {
            PrGroup::Reviews
        } else if !is_open(p) {
            if now - p.updated_at > DONE_MS {
                continue;
            }
            PrGroup::Done
        } else if p.review_requested && p.snoozed_until.is_some() {
            PrGroup::Snoozed
        } else if p.mine {
            PrGroup::Yours
        } else {
            PrGroup::Others
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
                PrGroup::Reviews => rows.sort_by_key(|p| (p.requested_at.unwrap_or(p.updated_at), p.key.clone())),
                PrGroup::Snoozed => rows.sort_by_key(|p| (p.snoozed_until, p.key.clone())),
                _ => rows.sort_by(|a, b| b.updated_at.cmp(&a.updated_at).then_with(|| a.key.cmp(&b.key))),
            }
            PrSection { group, rows: rows.into_iter().cloned().collect() }
        })
        .collect()
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
/// that don't need you, as the quick search leaves them out.
fn listed<'a>(rows: &'a [SessionRow], project: &'a str, now: i64) -> impl Iterator<Item = &'a SessionRow> {
    rows.iter().filter(move |r| in_inbox(r, now) && !(r.helping && !matches!(r.status, Status::Needs | Status::Error)) && (project.is_empty() || r.project == project))
}

/// Sessions by project and worktree: the project and the worktree with the last activity first,
/// and in a worktree, what needs you first, then the newest. `worktrees` are the places to start,
/// keyed by `@<device short id>:<id>`, and `shorts` each Mac's short id by its key.
pub(crate) fn project_groups(rows: &[SessionRow], worktrees: &HashMap<String, Worktree>, shorts: &HashMap<&str, &str>, project: &str, now: i64) -> Vec<ProjectGroup> {
    let mut by_worktree: HashMap<String, (String, WorktreeGroup)> = HashMap::new();
    for r in listed(rows, project, now) {
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
        group.sessions.sort_by(|a, b| status_rank(a.status).cmp(&status_rank(b.status)).then(b.last_activity.cmp(&a.last_activity)).then_with(|| a.key.cmp(&b.key)));
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

/// The list's sessions in `project` (empty for all), the last active first.
pub(crate) fn recent_sessions(rows: &[SessionRow], project: &str, now: i64) -> Vec<SessionRow> {
    let mut out: Vec<SessionRow> = listed(rows, project, now).cloned().collect();
    out.sort_by(|a, b| b.last_activity.cmp(&a.last_activity).then_with(|| a.key.cmp(&b.key)));
    out
}

fn shorts<'a>(feeds: &'a Feeds) -> HashMap<&'a str, &'a str> {
    feeds.iter().map(|(d, _)| (d.key.as_str(), d.short.as_str())).collect()
}

#[uniffi::export]
impl Core {
    /// The PRs page for `project` (empty for all).
    pub fn pr_list(&self, project: String) -> Vec<PrSection> {
        self.client.with_feeds(|feeds| pr_sections(&crate::quick::all_prs(feeds), &project, now_ms()))
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
            groups(&pr_sections(&all, "", NOW)),
            vec![(PrGroup::Pinned, vec![1]), (PrGroup::Reviews, vec![2, 3]), (PrGroup::Yours, vec![4]), (PrGroup::Others, vec![5]), (PrGroup::Snoozed, vec![6]), (PrGroup::Done, vec![9, 7])]
        );
    }

    #[test]
    fn the_prs_page_narrows_to_a_project() {
        let mut other = pr(2, "open", NOW);
        other.project = "Other".into();
        assert_eq!(groups(&pr_sections(&[pr(1, "open", NOW), other], "App", NOW)), vec![(PrGroup::Others, vec![1])]);
    }

    fn in_worktree(key: &str, project: &str, worktree: &str, status: Status, at: i64) -> SessionRow {
        let mut s = session(key, status, at);
        s.project = project.into();
        s.worktree = worktree.into();
        s.worktree_id = format!("/src/{worktree}");
        s
    }

    #[test]
    fn sessions_by_project_go_worktree_by_worktree() {
        let rows = [
            in_worktree("a", "App", "app-1", Status::Idle, NOW - HOUR),
            in_worktree("b", "App", "app-1", Status::Needs, NOW - 5 * HOUR),
            in_worktree("c", "App", "app-2", Status::Unread, NOW - 2 * HOUR),
            in_worktree("d", "Site", "site", Status::Working, NOW - 10 * 60 * 1000),
        ];
        let start = Worktree { id: "/src/app-2".into(), project: "App".into(), repo: "app".into(), name: "app-2".into(), branch: None, last_activity: NOW, device: "d".into(), main: false, chat: false, reuse: None, codealong: false };
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
        helper.helping = true;
        let mut asking_helper = in_worktree("k", "App", "app-1", Status::Needs, NOW - HOUR);
        asking_helper.helping = true;
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
