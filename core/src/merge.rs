//! A PR's merge box, as the Mac's has it (the main repo's `src/merge.ts`, which says it as GitHub's
//! box does): what it says of where the PR stands, what it offers you, the words for each way of
//! merging, and what each act asks of the Mac.
//!
//! It merges now when GitHub would: the PR is open and out of draft, you can write to the repo, and
//! GitHub says it's clean, or unstable (checks failed or still running that the repo doesn't
//! require). Otherwise it offers what GitHub offers then: auto-merge, which merges it once its
//! requirements are met; the merge queue, where the base branch merges through one; merging past
//! the rules, for one who may. A branch behind its base can be brought up to date, a draft made
//! ready, and a merged or closed PR's branch deleted.

use crate::prs::{MergeAct, MergeBox, MergeCommit, MergeMethod};

/// How the box reads at a glance: ready, waiting on something, held back by something to fix, or
/// over (merged or closed).
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum MergeTone {
    Ok,
    Wait,
    Bad,
    Done,
}

/// Where the PR stands for merging, as the box says it above what it offers.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Standing {
    pub tone: MergeTone,
    pub says: String,
    /// What's behind it, on a line of its own.
    pub more: Option<String>,
}

/// What the box offers you now.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Default)]
pub struct Offers {
    /// Merge it now.
    pub merge: bool,
    /// Merge it now, past the rules.
    pub bypass: bool,
    pub auto: bool,
    pub stop_auto: bool,
    pub queue: bool,
    pub dequeue: bool,
    /// Bring its branch up to date with its base.
    pub update: bool,
    pub ready: bool,
    /// Its branch, once it's merged or closed.
    pub delete_branch: bool,
    /// Its conflicts, to resolve on GitHub.
    pub conflicts: bool,
}

/// What the box's main button does: merge now (past the rules, with that chosen), add it to the
/// queue, or turn on auto-merge.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum MergeMode {
    Merge,
    Bypass,
    Queue,
    Auto,
}

/// What's filled in before the confirm button.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct MergeForm {
    pub method: MergeMethod,
    pub title: String,
    pub body: String,
    pub email: Option<String>,
    pub delete_branch: bool,
}

struct Words {
    label: &'static str,
    button: &'static str,
    confirm: &'static str,
    verb: &'static str,
    done: &'static str,
    what: &'static str,
}

fn words(m: MergeMethod) -> Words {
    match m {
        MergeMethod::Merge => Words { label: "Create a merge commit", button: "Merge", confirm: "Confirm merge", verb: "merge", done: "Merged", what: "Every commit on the branch goes onto the base, joined by a merge commit." },
        MergeMethod::Squash => Words { label: "Squash and merge", button: "Squash and merge", confirm: "Confirm squash and merge", verb: "squash and merge", done: "Squashed and merged", what: "The branch\u{2019}s commits go onto the base as one commit." },
        MergeMethod::Rebase => Words { label: "Rebase and merge", button: "Rebase and merge", confirm: "Confirm rebase and merge", verb: "rebase and merge", done: "Rebased and merged", what: "The branch\u{2019}s commits go onto the base one by one, with no merge commit." },
    }
}

/// How a method is named in the box's picker, and what it does, as GitHub says them.
#[uniffi::export]
pub fn method_label(method: MergeMethod) -> String {
    words(method).label.into()
}

#[uniffi::export]
pub fn method_what(method: MergeMethod) -> String {
    words(method).what.into()
}

fn queue_words(state: &str) -> Option<&'static str> {
    Some(match state {
        "QUEUED" => "Waiting its turn.",
        "AWAITING_CHECKS" => "Waiting for the queue\u{2019}s checks.",
        "MERGEABLE" => "The queue\u{2019}s checks passed: it merges next.",
        "UNMERGEABLE" => "It can\u{2019}t merge, and will leave the queue.",
        "LOCKED" => "Merging now.",
        _ => return None,
    })
}

/// What was said, as one clause with its first letter a capital.
fn clause(parts: &[String]) -> String {
    let s = parts.join(", ");
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => s,
    }
}

fn plural(n: u32, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

/// Where the PR stands for merging. `failed`, `pending` and `passed` are its checks as the Mac's
/// board reads them.
#[uniffi::export]
pub fn merge_standing(merge_box: MergeBox, base: Option<String>, slug: String, failed: u32, pending: u32, passed: u32) -> Standing {
    let b = merge_box;
    let base = base.unwrap_or_else(|| "its base".into());
    let st = |tone, says: String, more: Option<String>| Standing { tone, says, more };
    if b.state == "MERGED" {
        return st(MergeTone::Done, b.merged_by.map_or_else(|| "Merged".into(), |by| format!("Merged by {by}")), None);
    }
    if b.state == "CLOSED" {
        return st(MergeTone::Done, "Closed without merging".into(), None);
    }
    let cant = (!b.can_merge).then(|| format!("Only people who can write to {slug} can merge it."));
    if b.draft {
        return st(MergeTone::Wait, "Still a draft".into(), Some("GitHub doesn\u{2019}t merge a draft: mark it ready for review first.".into()));
    }
    if let Some(q) = &b.queued {
        return st(MergeTone::Wait, "In the merge queue".into(), q.state.as_deref().and_then(queue_words).map(String::from));
    }
    if let Some(a) = &b.auto {
        let how = a.method.map_or("merge", |m| words(m).verb);
        let by = a.by.as_ref().map_or(String::new(), |by| format!(". Turned on by {by}"));
        return st(MergeTone::Wait, "Auto-merge is on".into(), Some(format!("GitHub will {how} it once its requirements are met{by}.")));
    }
    if b.mergeable == "CONFLICTING" || b.merge_state == "DIRTY" {
        return st(MergeTone::Bad, format!("Conflicts with {base}"), Some("They need resolving before it can merge.".into()));
    }
    match b.merge_state.as_str() {
        "BEHIND" => st(MergeTone::Wait, format!("Behind {base}"), Some(cant.unwrap_or_else(|| "The repo wants the branch brought up to date before it merges.".into()))),
        "BLOCKED" => {
            let decision = b.review_decision.as_deref();
            let mut why = Vec::new();
            if decision == Some("CHANGES_REQUESTED") {
                why.push("changes were asked for".to_string());
            }
            if decision == Some("REVIEW_REQUIRED") {
                why.push("it needs an approving review".into());
            }
            if failed > 0 {
                why.push("checks failed".into());
            }
            if failed == 0 && pending > 0 {
                why.push("checks are still running".into());
            }
            let tone = if failed > 0 || decision == Some("CHANGES_REQUESTED") { MergeTone::Bad } else { MergeTone::Wait };
            let more = cant.unwrap_or_else(|| if why.is_empty() { "The repo\u{2019}s rules hold it back.".into() } else { format!("{}.", clause(&why)) });
            st(tone, "Merging is blocked".into(), Some(more))
        }
        "UNSTABLE" => {
            let mut checks = Vec::new();
            if failed > 0 {
                checks.push(format!("{} failed", plural(failed, "check", "checks")));
            }
            if pending > 0 {
                checks.push(format!("{pending} running"));
            }
            let said = if checks.is_empty() { "Some checks haven\u{2019}t passed".into() } else { clause(&checks) };
            st(MergeTone::Ok, "Ready to merge".into(), Some(cant.unwrap_or_else(|| format!("{said}, which the repo doesn\u{2019}t require."))))
        }
        "CLEAN" | "HAS_HOOKS" => {
            let mut good = Vec::new();
            if b.review_decision.as_deref() == Some("APPROVED") {
                good.push("approved".to_string());
            }
            if passed > 0 {
                good.push(format!("{} passed", plural(passed, "check", "checks")));
            }
            st(MergeTone::Ok, "Ready to merge".into(), cant.or_else(|| (!good.is_empty()).then(|| format!("{}.", clause(&good)))))
        }
        _ => st(MergeTone::Wait, "Checking whether it can merge\u{2026}".into(), cant),
    }
}

/// What the box offers you now.
#[uniffi::export]
pub fn merge_offers(merge_box: MergeBox) -> Offers {
    let b = merge_box;
    let open = b.state == "OPEN";
    let conflicts = open && (b.mergeable == "CONFLICTING" || b.merge_state == "DIRTY");
    let settled = open && !b.draft && b.queued.is_none() && b.auto.is_none();
    let methods = !b.methods.is_empty();
    let merge = settled && b.can_merge && !b.queue && methods && matches!(b.merge_state.as_str(), "CLEAN" | "HAS_HOOKS" | "UNSTABLE");
    Offers {
        merge,
        bypass: settled && b.can_bypass && !merge && !conflicts && methods,
        auto: settled && b.can_auto && !b.queue && methods,
        stop_auto: open && b.auto.is_some() && b.can_stop_auto,
        queue: settled && b.can_merge && b.queue && !conflicts,
        dequeue: open && b.queued.is_some() && b.can_merge,
        update: open && b.can_update_branch,
        ready: open && b.draft && b.can_ready,
        delete_branch: !open && b.branch_ref.is_some(),
        conflicts,
    }
}

/// What the main button does, or None when the box offers none of its acts.
#[uniffi::export]
pub fn merge_main_mode(offers: Offers, bypassing: bool) -> Option<MergeMode> {
    if offers.merge {
        Some(MergeMode::Merge)
    } else if offers.bypass && bypassing {
        Some(MergeMode::Bypass)
    } else if offers.queue {
        Some(MergeMode::Queue)
    } else if offers.auto {
        Some(MergeMode::Auto)
    } else {
        None
    }
}

/// What the main button says.
#[uniffi::export]
pub fn merge_mode_label(mode: MergeMode, method: MergeMethod) -> String {
    match mode {
        MergeMode::Queue => "Add to merge queue".into(),
        MergeMode::Auto => "Enable auto-merge".into(),
        MergeMode::Bypass => "Bypass rules and merge".into(),
        MergeMode::Merge => words(method).button.into(),
    }
}

/// What the confirm button says, once the commit is written.
#[uniffi::export]
pub fn merge_confirm_label(mode: MergeMode, method: MergeMethod) -> String {
    if mode == MergeMode::Auto { "Confirm auto-merge".into() } else { words(method).confirm.into() }
}

/// The method the box starts on: the one picked before, else GitHub's pick for you, either only
/// while the repo allows it.
#[uniffi::export]
pub fn merge_pick_method(merge_box: MergeBox, picked: Option<MergeMethod>) -> Option<MergeMethod> {
    if let Some(p) = picked.filter(|p| merge_box.methods.contains(p)) {
        return Some(p);
    }
    merge_box.default_method.or_else(|| merge_box.methods.first().copied())
}

/// The commit's title and message as GitHub would write them for a method, as (title, body); a
/// rebase writes none.
#[uniffi::export]
pub fn merge_commit_text(merge_box: MergeBox, method: MergeMethod) -> Option<Vec<String>> {
    match method {
        MergeMethod::Merge => Some(vec![merge_box.merge_title, merge_box.merge_body]),
        MergeMethod::Squash => Some(vec![merge_box.squash_title, merge_box.squash_body]),
        MergeMethod::Rebase => None,
    }
}

/// The branch can go with the merge: GitHub doesn't delete it itself, and you can push to it.
#[uniffi::export]
pub fn merge_deletes_with(merge_box: MergeBox, mode: MergeMode) -> bool {
    matches!(mode, MergeMode::Merge | MergeMode::Bypass) && !merge_box.deletes_branch && merge_box.branch_ref.is_some()
}

/// What the main button, confirmed, asks of the Mac.
#[uniffi::export]
pub fn merge_act_for(merge_box: MergeBox, mode: MergeMode, form: MergeForm) -> MergeAct {
    if mode == MergeMode::Queue {
        return MergeAct::Enqueue { head: merge_box.head };
    }
    let writes = form.method != MergeMethod::Rebase;
    let commit = MergeCommit {
        method: form.method,
        title: writes.then(|| form.title.clone()),
        body: writes.then(|| form.body.clone()),
        email: if writes && !merge_box.emails.is_empty() { form.email.clone() } else { None },
    };
    if mode == MergeMode::Auto {
        return MergeAct::Auto { commit, head: merge_box.head };
    }
    let delete = form.delete_branch && merge_deletes_with(merge_box.clone(), mode);
    MergeAct::Merge { commit, head: merge_box.head, delete_branch: if delete { merge_box.branch_ref } else { None } }
}

/// Whether a box just read is worth reading again in a moment (merge.ts `rereads`): GitHub hasn't
/// worked out yet whether the PR can merge, or doesn't yet say what the board read (`merge`, the
/// PR row's word), that it's ready.
#[uniffi::export]
pub fn merge_rereads(merge_box: MergeBox, merge: String) -> bool {
    if merge_box.state != "OPEN" {
        return false;
    }
    merge_box.merge_state == "UNKNOWN" || (merge == "clean" && merge_box.merge_state != "CLEAN" && merge_box.merge_state != "HAS_HOOKS")
}

/// What the box says once GitHub has done it.
#[uniffi::export]
pub fn merge_done_words(act: MergeAct, number: u64, branch: String) -> String {
    match act {
        MergeAct::Merge { commit, delete_branch, .. } => format!("{} #{number}{}.", words(commit.method).done, if delete_branch.is_some() { format!(" and deleted {branch}") } else { String::new() }),
        MergeAct::Auto { .. } => format!("Auto-merge is on for #{number}."),
        MergeAct::StopAuto => format!("Auto-merge is off for #{number}."),
        MergeAct::Enqueue { .. } => format!("#{number} is in the merge queue."),
        MergeAct::Dequeue => format!("#{number} is out of the merge queue."),
        MergeAct::UpdateBranch { rebase, .. } => format!("Brought {branch} up to date{}.", if rebase { " by a rebase" } else { "" }),
        MergeAct::Ready => format!("#{number} is ready for review."),
        MergeAct::DeleteBranch { .. } => format!("Deleted {branch}."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prs::{AutoMerge, Queued};

    #[test]
    fn a_box_github_hasnt_settled_is_read_again() {
        let unknown = MergeBox { merge_state: "UNKNOWN".into(), ..open_box() };
        assert!(merge_rereads(unknown.clone(), "unknown".into()));
        assert!(!merge_rereads(MergeBox { state: "MERGED".into(), ..unknown }, "unknown".into()));
        // The board says it's ready and GitHub doesn't yet.
        let blocked = MergeBox { merge_state: "BLOCKED".into(), ..open_box() };
        assert!(merge_rereads(blocked.clone(), "clean".into()));
        assert!(!merge_rereads(blocked, "blocked".into()));
        assert!(!merge_rereads(MergeBox { merge_state: "CLEAN".into(), ..open_box() }, "clean".into()));
    }

    fn open_box() -> MergeBox {
        MergeBox {
            id: "PR_1".into(),
            head: "abc".into(),
            branch: "teams".into(),
            state: "OPEN".into(),
            draft: false,
            mergeable: "MERGEABLE".into(),
            merge_state: "CLEAN".into(),
            review_decision: Some("APPROVED".into()),
            can_merge: true,
            methods: vec![MergeMethod::Merge, MergeMethod::Squash],
            default_method: Some(MergeMethod::Squash),
            merge_title: "Merge pull request #7".into(),
            merge_body: "Add teams".into(),
            squash_title: "Add teams (#7)".into(),
            squash_body: "* one\n* two".into(),
            emails: vec!["me@example.com".into()],
            default_email: Some("me@example.com".into()),
            can_ready: true,
            can_bypass: false,
            can_auto: true,
            can_stop_auto: false,
            auto: None,
            can_update_branch: false,
            queue: false,
            queued: None,
            deletes_branch: false,
            branch_ref: Some("REF_1".into()),
            merged_by: None,
        }
    }

    #[test]
    fn says_where_it_stands_as_the_mac_does() {
        let s = merge_standing(open_box(), Some("main".into()), "o/r".into(), 0, 0, 3);
        assert_eq!((s.tone, s.says.as_str(), s.more.as_deref()), (MergeTone::Ok, "Ready to merge", Some("Approved, 3 checks passed.")));
        let blocked = MergeBox { merge_state: "BLOCKED".into(), review_decision: Some("REVIEW_REQUIRED".into()), ..open_box() };
        let s = merge_standing(blocked, Some("main".into()), "o/r".into(), 0, 2, 0);
        assert_eq!((s.tone, s.more.as_deref()), (MergeTone::Wait, Some("It needs an approving review, checks are still running.")));
        let conflicts = MergeBox { mergeable: "CONFLICTING".into(), ..open_box() };
        assert_eq!(merge_standing(conflicts, Some("main".into()), "o/r".into(), 0, 0, 0).says, "Conflicts with main");
        let auto = MergeBox { auto: Some(AutoMerge { method: Some(MergeMethod::Squash), by: Some("ana".into()), at: None }), ..open_box() };
        assert_eq!(merge_standing(auto, None, "o/r".into(), 0, 0, 0).more.as_deref(), Some("GitHub will squash and merge it once its requirements are met. Turned on by ana."));
        let merged = MergeBox { state: "MERGED".into(), merged_by: Some("ana".into()), ..open_box() };
        assert_eq!(merge_standing(merged, None, "o/r".into(), 0, 0, 0).says, "Merged by ana");
    }

    #[test]
    fn offers_what_github_would_and_the_main_button_follows() {
        let o = merge_offers(open_box());
        assert!(o.merge && o.auto && !o.bypass && !o.queue);
        assert_eq!(merge_main_mode(o, false), Some(MergeMode::Merge));
        // Blocked, for one who may: past the rules only when that's chosen, auto-merge otherwise.
        let blocked = MergeBox { merge_state: "BLOCKED".into(), can_bypass: true, ..open_box() };
        let o = merge_offers(blocked);
        assert!(!o.merge && o.bypass && o.auto);
        assert_eq!(merge_main_mode(o.clone(), true), Some(MergeMode::Bypass));
        assert_eq!(merge_main_mode(o, false), Some(MergeMode::Auto));
        // A base branch with a queue takes it in.
        let queue = MergeBox { queue: true, ..open_box() };
        assert_eq!(merge_main_mode(merge_offers(queue), false), Some(MergeMode::Queue));
        // In the queue, it can come out.
        let queued = MergeBox { queued: Some(Queued { position: Some(1), state: Some("QUEUED".into()) }), ..open_box() };
        let o = merge_offers(queued);
        assert!(o.dequeue && !o.merge && merge_main_mode(o, false).is_none());
        // A draft can be made ready; a merged PR's branch deleted.
        assert!(merge_offers(MergeBox { draft: true, ..open_box() }).ready);
        assert!(merge_offers(MergeBox { state: "MERGED".into(), ..open_box() }).delete_branch);
    }

    #[test]
    fn writes_the_act_as_the_mac_sends_it() {
        let form = MergeForm { method: MergeMethod::Squash, title: "Add teams (#7)".into(), body: String::new(), email: Some("me@example.com".into()), delete_branch: true };
        assert_eq!(
            merge_act_for(open_box(), MergeMode::Merge, form.clone()),
            MergeAct::Merge { commit: MergeCommit { method: MergeMethod::Squash, title: Some("Add teams (#7)".into()), body: Some(String::new()), email: Some("me@example.com".into()) }, head: "abc".into(), delete_branch: Some("REF_1".into()) }
        );
        // A rebase writes no commit of its own; GitHub deleting the branch itself leaves it be.
        let rebase = MergeForm { method: MergeMethod::Rebase, ..form.clone() };
        assert_eq!(
            merge_act_for(MergeBox { deletes_branch: true, ..open_box() }, MergeMode::Merge, rebase),
            MergeAct::Merge { commit: MergeCommit { method: MergeMethod::Rebase, title: None, body: None, email: None }, head: "abc".into(), delete_branch: None }
        );
        assert_eq!(merge_act_for(open_box(), MergeMode::Queue, form.clone()), MergeAct::Enqueue { head: "abc".into() });
        assert_eq!(merge_done_words(merge_act_for(open_box(), MergeMode::Merge, form), 7, "teams".into()), "Squashed and merged #7 and deleted teams.");
        assert_eq!(merge_pick_method(open_box(), Some(MergeMethod::Rebase)), Some(MergeMethod::Squash));
        assert_eq!(merge_mode_label(MergeMode::Merge, MergeMethod::Squash), "Squash and merge");
    }
}
