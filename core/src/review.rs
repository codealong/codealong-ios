//! A PR's review box, at the foot of its page, as the Mac's has it (the main repo's `PrBox.tsx`,
//! with `prStatus.ts` and `prDraft.ts`): what's written goes with a verdict, Request changes,
//! Comment or Approve. Any open PR but your own takes all three; your own, or one that's closed,
//! takes a comment. A comment or a request for changes needs something to say, which your draft
//! review on GitHub can hold, and any verdict on a PR you have a draft of submits it, comments and
//! all. It has no Ask side, as the Mac's has: no device can ask a Mac's agent about a PR.

use crate::prs::{PrDraft, PrVerdict};
use crate::PrRow;

/// What the box offers for a PR.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ReviewBox {
    /// It takes Approve and Request changes (`mayApprove`): it's open and not yours, which GitHub
    /// doesn't let you approve. Anything takes a comment.
    pub reviewable: bool,
    /// What the field says before you write.
    pub hint: String,
    /// What sending does that the buttons don't say: only a comment goes, or your draft review
    /// goes with it.
    pub note: Option<String>,
}

fn is_open(state: &str) -> bool {
    !matches!(state, "merged" | "closed")
}

/// "4 comments".
fn comments(n: u64) -> String {
    format!("{n} {}", if n == 1 { "comment" } else { "comments" })
}

/// The box for `pr`, with your draft review of it as its page read it.
#[uniffi::export]
pub fn review_box(pr: PrRow, draft: Option<PrDraft>) -> ReviewBox {
    let open = is_open(&pr.state);
    let reviewable = open && !pr.mine;
    let hint = if draft.is_some() {
        "Your words, before your draft review’s (optional)".to_string()
    } else if reviewable {
        "Your review, if it says anything".to_string()
    } else {
        format!("Comment on #{}", pr.number)
    };
    let why = if !open {
        Some("It’s closed: a comment still goes to the PR.")
    } else if pr.mine {
        Some("GitHub doesn’t let you approve your own PR: you can comment.")
    } else {
        None
    };
    let with = draft.map(|d| match d.count {
        0 => "Sending submits your draft review too.".to_string(),
        n => format!("Sending submits your draft review too, with its {}.", comments(n)),
    });
    let note = match (why, with) {
        (Some(why), Some(with)) => Some(format!("{why} {with}")),
        (why, with) => why.map(str::to_string).or(with),
    };
    ReviewBox { reviewable, hint, note }
}

/// Whether `verdict` has something to say (`saysSomething`): what's written, or a draft with text
/// or comments. An approval needs nothing.
#[uniffi::export]
pub fn review_says_something(verdict: PrVerdict, written: String, draft: Option<PrDraft>) -> bool {
    verdict == PrVerdict::Approve || !written.trim().is_empty() || draft.is_some_and(|d| !d.body.trim().is_empty() || d.count > 0)
}

/// What the page says once a review went (`reviewedWords`): what was done, and the draft
/// submitted with it, by how many comments went (none when there was no draft).
#[uniffi::export]
pub fn reviewed_words(verdict: PrVerdict, number: u64, draft: Option<u64>) -> String {
    let did = match verdict {
        PrVerdict::Approve => "Approved",
        PrVerdict::Comment => "Commented on",
        PrVerdict::RequestChanges => "Requested changes on",
    };
    match draft {
        None => format!("{did} #{number}."),
        Some(0) => format!("{did} #{number}, submitting your draft review."),
        Some(n) => format!("{did} #{number}, submitting your draft review and its {}.", comments(n)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::quick::tests::pr_row;

    fn pr(state: &str, mine: bool) -> PrRow {
        let mut p = pr_row("o/r#7", "T", false);
        p.number = 7;
        p.state = state.into();
        p.mine = mine;
        p
    }

    fn draft(body: &str, count: u64) -> PrDraft {
        PrDraft { body: body.into(), url: None, comments: vec![], count, stamp: "s".into() }
    }

    #[test]
    fn an_open_pr_not_yours_takes_every_verdict() {
        for state in ["open", "draft", "approved", "changes"] {
            let b = review_box(pr(state, false), None);
            assert!(b.reviewable, "{state}");
            assert_eq!(b.hint, "Your review, if it says anything");
            assert_eq!(b.note, None);
        }
    }

    #[test]
    fn your_own_or_a_closed_one_takes_a_comment() {
        let mine = review_box(pr("open", true), None);
        assert!(!mine.reviewable);
        assert_eq!(mine.hint, "Comment on #7");
        assert_eq!(mine.note.as_deref(), Some("GitHub doesn’t let you approve your own PR: you can comment."));
        for state in ["merged", "closed"] {
            let b = review_box(pr(state, false), None);
            assert!(!b.reviewable);
            assert_eq!(b.note.as_deref(), Some("It’s closed: a comment still goes to the PR."));
        }
    }

    #[test]
    fn a_draft_goes_with_whatever_is_sent() {
        let b = review_box(pr("open", false), Some(draft("Hold it.", 3)));
        assert_eq!(b.hint, "Your words, before your draft review’s (optional)");
        assert_eq!(b.note.as_deref(), Some("Sending submits your draft review too, with its 3 comments."));
        assert_eq!(review_box(pr("open", false), Some(draft("x", 0))).note.as_deref(), Some("Sending submits your draft review too."));
        let mine = review_box(pr("open", true), Some(draft("", 1)));
        assert_eq!(mine.note.as_deref(), Some("GitHub doesn’t let you approve your own PR: you can comment. Sending submits your draft review too, with its 1 comment."));
    }

    #[test]
    fn a_comment_or_changes_needs_something_said() {
        assert!(review_says_something(PrVerdict::Approve, "  ".into(), None));
        assert!(!review_says_something(PrVerdict::Comment, " \n ".into(), None));
        assert!(!review_says_something(PrVerdict::RequestChanges, String::new(), Some(draft(" ", 0))));
        assert!(review_says_something(PrVerdict::RequestChanges, "Rename it".into(), None));
        assert!(review_says_something(PrVerdict::Comment, String::new(), Some(draft("Looks off", 0))));
        assert!(review_says_something(PrVerdict::Comment, String::new(), Some(draft("", 2))));
    }

    #[test]
    fn what_went_is_said() {
        assert_eq!(reviewed_words(PrVerdict::Approve, 7, None), "Approved #7.");
        assert_eq!(reviewed_words(PrVerdict::Comment, 7, Some(0)), "Commented on #7, submitting your draft review.");
        assert_eq!(reviewed_words(PrVerdict::RequestChanges, 7, Some(1)), "Requested changes on #7, submitting your draft review and its 1 comment.");
    }
}
