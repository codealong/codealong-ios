//! Pull requests, read and acted on through a Mac (codealong-peer's `pr`): the phone has no GitHub
//! of its own, so a Mac's `gh`, signed in as you, reads a PR's detail and merge box and does what
//! you ask. Reviewing and merging act as you on GitHub, so that Mac needs remote control on, as it
//! does to answer an approval. A PR is asked about by its Mac (`PrRow::device`), its repo
//! (`owner/name`) and its number.

use codealong_peer::pr;

use crate::{Core, CoreError};

/// A PR's description, reviews, comments and changed files, as the Mac's PR panel shows them.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PrDetail {
    /// The description as written, in Markdown.
    pub body: String,
    /// `MERGEABLE`, `CONFLICTING` or `UNKNOWN`.
    pub mergeable: Option<String>,
    pub commits: u64,
    /// Each reviewer's standing review.
    pub reviews: Vec<PrReview>,
    /// Who's asked to review it and hasn't yet.
    pub requested: Vec<String>,
    /// Comments with something written in them, newest first.
    pub comments: Vec<PrComment>,
    pub files: Vec<PrFile>,
    /// More files than GitHub's first page holds.
    pub more_files: bool,
    /// Your review of it that you began and haven't submitted (an agent's, or one you started on
    /// GitHub): a review submits it, its comments and all, so it's shown first.
    pub draft: Option<PrDraft>,
}

/// Your review of a PR that you began and haven't submitted.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PrDraft {
    /// Its text.
    pub body: String,
    pub url: Option<String>,
    /// Its comments on lines, the first hundred.
    pub comments: Vec<PrDraftComment>,
    /// How many comments it has in all.
    pub count: u64,
    /// The draft as it was read, in a word: a review sends it back, so the Mac submits only this
    /// draft, unchanged.
    pub stamp: String,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PrDraftComment {
    pub path: String,
    pub line: Option<u64>,
    /// The PR's changes since have moved or changed its line.
    pub outdated: bool,
    pub body: String,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PrReview {
    pub author: String,
    /// `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED` or `DISMISSED`.
    pub state: String,
    pub at: Option<i64>,
    /// Given by you, as the Mac's `gh` is signed in. A Mac before 2026-10-12 doesn't say, so none
    /// is yours there.
    pub mine: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PrComment {
    pub id: String,
    pub author: String,
    /// As written, in Markdown.
    pub body: String,
    pub at: Option<i64>,
    pub url: Option<String>,
    /// The file a thread on the code is about.
    pub path: Option<String>,
    pub resolved: bool,
    /// Written by you, as the Mac's `gh` is signed in.
    pub mine: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PrFile {
    pub path: String,
    /// `added`, `modified`, `removed`, `renamed`…
    pub status: String,
    pub additions: u64,
    pub deletions: u64,
    /// The unified diff; GitHub leaves it out for very large files.
    pub patch: Option<String>,
}

/// What a review says.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PrVerdict {
    Approve,
    Comment,
    RequestChanges,
}

/// How a PR's commits go onto its base.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum MergeMethod {
    /// A merge commit.
    Merge,
    Squash,
    Rebase,
}

/// What a PR's merge box offers you, and where the PR stands for it, as GitHub's has it.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct MergeBox {
    /// The PR's node id, which every act names it by.
    pub id: String,
    /// The head commit the box was read at, which a merge or an update names: GitHub refuses one
    /// whose branch moved since, so you merge what you saw.
    pub head: String,
    pub branch: String,
    /// `OPEN`, `MERGED` or `CLOSED`.
    pub state: String,
    pub draft: bool,
    /// `MERGEABLE`, `CONFLICTING`, or `UNKNOWN` while GitHub works it out.
    pub mergeable: String,
    /// `CLEAN`, `HAS_HOOKS`, `UNSTABLE`, `BLOCKED`, `BEHIND`, `DIRTY` or `UNKNOWN`.
    pub merge_state: String,
    /// `APPROVED`, `CHANGES_REQUESTED` or `REVIEW_REQUIRED`; None where the repo needs no review.
    pub review_decision: Option<String>,
    /// You can write to the repo, which merging needs.
    pub can_merge: bool,
    /// The methods the repo allows, in GitHub's order.
    pub methods: Vec<MergeMethod>,
    pub default_method: Option<MergeMethod>,
    /// The title and message GitHub would write for a merge commit, and for a squash.
    pub merge_title: String,
    pub merge_body: String,
    pub squash_title: String,
    pub squash_body: String,
    /// The emails a commit you make can be under, and the one GitHub picks.
    pub emails: Vec<String>,
    pub default_email: Option<String>,
    /// You can take it out of draft.
    pub can_ready: bool,
    /// You can merge it before its requirements are met, past the rules.
    pub can_bypass: bool,
    pub can_auto: bool,
    pub can_stop_auto: bool,
    /// Auto-merge, while it's on.
    pub auto: Option<AutoMerge>,
    /// Its branch is behind its base and you can bring it up to date.
    pub can_update_branch: bool,
    /// Its base branch merges through a queue.
    pub queue: bool,
    pub queued: Option<Queued>,
    /// GitHub deletes the branch itself once it's merged.
    pub deletes_branch: bool,
    /// The branch's ref, while it's there and you can push to its repo: what deleting it names.
    pub branch_ref: Option<String>,
    pub merged_by: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct AutoMerge {
    pub method: Option<MergeMethod>,
    pub by: Option<String>,
    pub at: Option<i64>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Queued {
    pub position: Option<u64>,
    /// `QUEUED`, `AWAITING_CHECKS`, `MERGEABLE`, `UNMERGEABLE` or `LOCKED`.
    pub state: Option<String>,
}

/// What a merge or auto-merge writes: for a merge commit or a squash, the commit's title, message
/// and email (None leaves each to GitHub).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct MergeCommit {
    pub method: MergeMethod,
    pub title: Option<String>,
    pub body: Option<String>,
    pub email: Option<String>,
}

/// One thing the merge box does.
#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum MergeAct {
    /// Merges it now (past the rules too, for one who may), deleting its branch after with one.
    Merge { commit: MergeCommit, head: String, delete_branch: Option<String> },
    /// Merges it once its requirements are met.
    Auto { commit: MergeCommit, head: String },
    StopAuto,
    /// Into the queue its base branch merges through.
    Enqueue { head: String },
    Dequeue,
    /// Brings its branch up to date with its base, by a merge commit or a rebase.
    UpdateBranch { rebase: bool, head: String },
    /// Takes it out of draft.
    Ready,
    DeleteBranch { branch_ref: String },
}

/// What a merge box's act did.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct MergeDone {
    /// It merged the PR, rather than queueing it, turning on auto-merge or the rest.
    pub merged: bool,
    /// What it couldn't do after (a branch that stayed).
    pub note: Option<String>,
}

#[uniffi::export]
impl Core {
    /// A PR's description, reviews, comments and changed files, as `device`'s `gh` reads them.
    pub fn pr_detail(&self, device: String, repo: String, number: u64) -> Result<PrDetail, CoreError> {
        let d = self.client.pr_detail(&device, &repo, number).map_err(CoreError::Failed)?;
        Ok(PrDetail {
            body: readable(&d.body),
            mergeable: d.mergeable,
            commits: d.commits,
            reviews: d.reviews.into_iter().map(|r| PrReview { author: r.author, state: r.state, at: r.at, mine: r.mine }).collect(),
            requested: d.requested,
            comments: d.comments.into_iter().map(|c| PrComment { id: c.id, author: c.author, body: readable(&c.body), at: c.at, url: c.url, path: c.path, resolved: c.resolved, mine: c.mine }).collect(),
            files: d.files.into_iter().map(|f| PrFile { path: f.path, status: f.status, additions: f.additions, deletions: f.deletions, patch: f.patch }).collect(),
            more_files: d.more_files,
            draft: d.draft.map(|d| PrDraft {
                body: readable(&d.body),
                url: d.url,
                comments: d.comments.into_iter().map(|c| PrDraftComment { path: c.path, line: c.line, outdated: c.outdated, body: readable(&c.body) }).collect(),
                count: d.count,
                stamp: d.stamp,
            }),
        })
    }

    /// What a PR's merge box offers you, as `device`'s `gh` reads it.
    pub fn pr_merge_box(&self, device: String, repo: String, number: u64) -> Result<MergeBox, CoreError> {
        let b = self.client.pr_merge_box(&device, &repo, number).map_err(CoreError::Failed)?;
        Ok(MergeBox {
            id: b.id,
            head: b.head,
            branch: b.branch,
            state: b.state,
            draft: b.draft,
            mergeable: b.mergeable,
            merge_state: b.merge_state,
            review_decision: b.review_decision,
            can_merge: b.can_merge,
            methods: b.methods.into_iter().map(method).collect(),
            default_method: b.default_method.map(method),
            merge_title: b.merge_text.title,
            merge_body: b.merge_text.body,
            squash_title: b.squash_text.title,
            squash_body: b.squash_text.body,
            emails: b.emails,
            default_email: b.default_email,
            can_ready: b.can_ready,
            can_bypass: b.can_bypass,
            can_auto: b.can_auto,
            can_stop_auto: b.can_stop_auto,
            auto: b.auto.map(|a| AutoMerge { method: a.method.map(method), by: a.by, at: a.at }),
            can_update_branch: b.can_update_branch,
            queue: b.queue,
            queued: b.queued.map(|q| Queued { position: q.position, state: q.state }),
            deletes_branch: b.deletes_branch,
            branch_ref: b.branch_ref,
            merged_by: b.merged_by,
        })
    }

    /// Reviews a PR as you on GitHub, through `device`'s `gh`: approves it, comments, or asks for
    /// changes. A comment or a request for changes needs `body`. It submits your draft review of
    /// it, so `draft` is the stamp of the draft shown (`PrDraft::stamp`, none for none shown), and
    /// the Mac refuses to submit another, or one changed since. Answers how many draft comments
    /// went with it.
    pub fn pr_review(&self, device: String, repo: String, number: u64, verdict: PrVerdict, body: String, draft: Option<String>) -> Result<Option<u64>, CoreError> {
        let verdict = match verdict {
            PrVerdict::Approve => pr::Verdict::Approve,
            PrVerdict::Comment => pr::Verdict::Comment,
            PrVerdict::RequestChanges => pr::Verdict::RequestChanges,
        };
        Ok(self.client.pr_review(&device, &repo, number, verdict, &body, draft.as_deref()).map_err(CoreError::Failed)?.draft)
    }

    /// Does one thing a PR's merge box does, as you on GitHub, through `device`'s `gh`. `id` is
    /// the PR's node id from its merge box.
    pub fn pr_merge(&self, device: String, repo: String, number: u64, id: String, act: MergeAct) -> Result<MergeDone, CoreError> {
        let commit = |c: MergeCommit| pr::Commit { method: peer_method(c.method), title: c.title, body: c.body, email: c.email };
        let op = match act {
            MergeAct::Merge { commit: c, head, delete_branch } => pr::Op::Merge { commit: commit(c), head, delete_branch },
            MergeAct::Auto { commit: c, head } => pr::Op::Auto { commit: commit(c), head },
            MergeAct::StopAuto => pr::Op::StopAuto,
            MergeAct::Enqueue { head } => pr::Op::Enqueue { head },
            MergeAct::Dequeue => pr::Op::Dequeue,
            MergeAct::UpdateBranch { rebase, head } => pr::Op::UpdateBranch { rebase, head },
            MergeAct::Ready => pr::Op::Ready,
            MergeAct::DeleteBranch { branch_ref } => pr::Op::DeleteBranch { branch_ref },
        };
        let done = self.client.pr_merge(&device, &repo, number, &id, op).map_err(CoreError::Failed)?;
        Ok(MergeDone { merged: done.merged, note: done.note })
    }

    /// Snoozes your review of PRs (`owner/name#number`) on `device` until `until` (ms), or wakes
    /// it with none: out of what waits on you there and everywhere until then.
    pub fn pr_snooze(&self, device: String, keys: Vec<String>, until: Option<i64>) -> Result<(), CoreError> {
        self.client.pr_snooze(&device, &keys, until).map_err(CoreError::Failed)
    }
}

fn method(m: pr::Method) -> MergeMethod {
    match m {
        pr::Method::Merge => MergeMethod::Merge,
        pr::Method::Squash => MergeMethod::Squash,
        pr::Method::Rebase => MergeMethod::Rebase,
    }
}

fn peer_method(m: MergeMethod) -> pr::Method {
    match m {
        MergeMethod::Merge => pr::Method::Merge,
        MergeMethod::Squash => pr::Method::Squash,
        MergeMethod::Rebase => pr::Method::Rebase,
    }
}

/// What GitHub's Markdown takes as HTML and the phone's doesn't, out of a PR's text: hidden
/// comments (Codealong's review marks, templates' notes) go, and the tags GitHub writes small or
/// folds text with (`<sub>`, `<details>`, `<br>` and the like) leave their text. Code, in blocks or
/// in a line, is left as written.
fn readable(text: &str) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut fenced = false;
    let mut hidden = false;
    for line in text.lines() {
        if !hidden && line.trim_start().starts_with("```") {
            fenced = !fenced;
            out.push(line.to_string());
            continue;
        }
        if fenced {
            out.push(line.to_string());
            continue;
        }
        let mut kept = String::new();
        for (code, part) in code_spans(line) {
            if code && !hidden {
                kept.push_str(part);
                continue;
            }
            let mut rest = part;
            loop {
                if hidden {
                    match rest.find("-->") {
                        Some(end) => {
                            hidden = false;
                            rest = &rest[end + 3..];
                        }
                        None => break,
                    }
                } else {
                    match rest.find("<!--") {
                        Some(start) => {
                            kept.push_str(&untagged(&rest[..start]));
                            hidden = true;
                            rest = &rest[start + 4..];
                        }
                        None => {
                            kept.push_str(&untagged(rest));
                            break;
                        }
                    }
                }
            }
        }
        // A line that was only a hidden comment goes with it.
        if kept.trim().is_empty() && !line.trim().is_empty() {
            continue;
        }
        out.push(kept);
    }
    out.join("\n").trim_end().to_string()
}

/// A line's pieces, each said to be code (a span between runs of as many backticks, with them)
/// or not.
fn code_spans(line: &str) -> Vec<(bool, &str)> {
    let mut out = Vec::new();
    let mut from = 0;
    let mut at = 0;
    let bytes = line.as_bytes();
    while at < bytes.len() {
        if bytes[at] != b'`' {
            at += 1;
            continue;
        }
        let run = bytes[at..].iter().take_while(|&&b| b == b'`').count();
        let ticks = &line[at..at + run];
        // Its close: the next run of exactly as many.
        let mut look = at + run;
        let close = loop {
            match line[look..].find(ticks) {
                Some(i) => {
                    let start = look + i;
                    let len = bytes[start..].iter().take_while(|&&b| b == b'`').count();
                    if len == run {
                        break Some(start);
                    }
                    look = start + len;
                }
                None => break None,
            }
        };
        match close {
            Some(end) => {
                if from < at {
                    out.push((false, &line[from..at]));
                }
                out.push((true, &line[at..end + run]));
                from = end + run;
                at = from;
            }
            None => at += run,
        }
    }
    if from < line.len() {
        out.push((false, &line[from..]));
    }
    out
}

/// Text with the tags GitHub writes small or folds text with taken out, a line break as one.
fn untagged(text: &str) -> String {
    const DROPPED: [&str; 16] = ["<sub>", "</sub>", "<sup>", "</sup>", "<details>", "</details>", "<summary>", "</summary>", "<p>", "</p>", "<b>", "</b>", "<i>", "</i>", "<em>", "</em>"];
    let mut kept = text.to_string();
    for tag in ["<br>", "<br/>", "<br />"] {
        kept = replace_ignoring_case(&kept, tag, "\n");
    }
    for tag in DROPPED {
        kept = replace_ignoring_case(&kept, tag, "");
    }
    kept
}

fn replace_ignoring_case(text: &str, tag: &str, with: &str) -> String {
    let lower = text.to_ascii_lowercase();
    if !lower.contains(tag) {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    let mut at = 0;
    while let Some(i) = lower[at..].find(tag) {
        out.push_str(&text[at..at + i]);
        out.push_str(with);
        at += i + tag.len();
    }
    out.push_str(&text[at..]);
    out
}

#[cfg(test)]
mod tests {
    use super::readable;

    #[test]
    fn a_prs_text_loses_the_html_the_phone_would_show_as_written() {
        // An agent's review as Codealong drafts it: its note small, its mark hidden.
        let review = "Hold it.\n\n<sub>An agent's review (Claude Code) of 322941c, drafted by Codealong.</sub>\n<!-- codealong-review o/r#7 322941c -->";
        assert_eq!(readable(review), "Hold it.\n\nAn agent's review (Claude Code) of 322941c, drafted by Codealong.");
        // A template's note over several lines, and one inside a line.
        assert_eq!(readable("## Summary\n<!-- What does\nit change? -->\nFaster.\nA <!-- x --> B<br>C"), "## Summary\nFaster.\nA  B\nC");
        assert_eq!(readable("<details><SUMMARY>Logs</SUMMARY>\n\nlong\n</details>"), "Logs\n\nlong");
        // Code is as written, in a block or in a line.
        let code = "```html\n<sub>x</sub> <!-- y -->\n```";
        assert_eq!(readable(code), code);
        assert_eq!(readable("Handle `<!--` here.\n\nThen `<sub>` and ``a ` <br> b``.<sub>x</sub>"), "Handle `<!--` here.\n\nThen `<sub>` and ``a ` <br> b``.x");
        assert_eq!(readable("An unclosed ` <sub>tick</sub>"), "An unclosed ` tick");
    }
}
