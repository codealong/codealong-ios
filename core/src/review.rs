//! A PR's review box, at the foot of its page, as the Mac's has it (the main repo's `PrBox.tsx`,
//! with `prStatus.ts` and `prDraft.ts`): what's written goes with a verdict, Request changes,
//! Comment or Approve. Any open PR but your own takes all three; your own, or one that's closed,
//! takes a comment. A comment or a request for changes needs something to say, which your draft
//! review on GitHub can hold, and any verdict on a PR you have a draft of submits it, comments and
//! all. It has no Ask side, as the Mac's has: no device can ask a Mac's agent about a PR. Over it,
//! with the PR's state, it says how you last reviewed it, so a verdict isn't given twice.

use crate::prs::{PrDraft, PrReview, PrVerdict};
use crate::PrRow;

/// What the box offers for a PR.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ReviewBox {
    /// It takes Approve and Request changes (`mayApprove`): it's open, and not opened by the
    /// account its Mac is signed in to GitHub as, which GitHub doesn't let approve it. Anything
    /// takes a comment.
    pub reviewable: bool,
    /// What the field says before you write.
    pub hint: String,
    /// What sending does that the buttons don't say: only a comment goes, or your draft review
    /// goes with it.
    pub note: Option<String>,
    /// Your standing review of it, and when: "You approved it {ago:<ms>}", after your sign-off,
    /// asked for where Codealong's agent approves it. None when you haven't reviewed it and no
    /// sign-off is asked, or its Mac doesn't say which review is yours.
    pub yours: Option<String>,
    /// Your approval stands and nothing asks for your review again: Approve reads Approved and
    /// steps back, another press another approval, as the Mac's does where you approved the commit
    /// it's at (PrBox.tsx `approvedNow`). The phone isn't told which commit yours was of, so a
    /// review asked for again, or the agent asking your sign-off, is what says it no longer stands.
    pub approved: bool,
}

fn is_open(state: &str) -> bool {
    !matches!(state, "merged" | "closed")
}

/// "4 comments".
fn comments(n: u64) -> String {
    format!("{n} {}", if n == 1 { "comment" } else { "comments" })
}

/// Your standing review among `reviews`: each reviewer's last approval or change request, else
/// comment.
fn mine(reviews: &[PrReview]) -> Option<&PrReview> {
    reviews.iter().find(|r| r.mine)
}

/// Your review was given after your review was last asked for, so it's the one asked: GitHub drops
/// the ask as you review, but the PR's Mac lists it until it next reads the PR, as it does for a
/// while after you review it here. Where either time isn't known, the ask stands.
fn answers(pr: &PrRow, review: Option<&PrReview>) -> bool {
    let Some(r) = review.filter(|r| r.state != "DISMISSED") else { return false };
    matches!((r.at, pr.requested_at), (Some(at), Some(asked)) if at > asked)
}

/// What asks for your review of `pr` again, unless yours answers it: Codealong's agent asking your
/// sign-off on the commit it approves (that commit), or your review asked for again on an open PR
/// that isn't a draft (no commit).
enum Asked<'a> {
    SignOff(&'a str),
    Again,
}

fn asked<'a>(pr: &'a PrRow, reviews: &[PrReview]) -> Option<Asked<'a>> {
    if answers(pr, mine(reviews)) {
        return None;
    }
    if let Some(approves) = pr.agent.as_ref().filter(|a| a.kind == "approves").and_then(|a| a.approves.as_deref()) {
        return Some(Asked::SignOff(approves));
    }
    (pr.review_requested && is_open(&pr.state) && pr.state != "draft").then_some(Asked::Again)
}

/// Your standing review among `reviews`, in words. Where `pr` asks for your review again, that
/// comes first, as the Mac's Re-review says (prStatus.ts `reReviewPill`): it's why a PR you
/// reviewed waits on you. GitHub takes a review as the one asked of you, so one asked for while
/// yours stands came after it. Where Codealong's agent approves the commit it's at, what's asked is
/// your sign-off, as the Mac's mark says it (prStatus.ts `reviewMark`), whether or not you reviewed
/// it before. A review of yours since the ask answers it (`answers`).
fn yours(pr: &PrRow, reviews: &[PrReview]) -> Option<String> {
    // What your review did ("approved it {ago:<ms>}"): none without one, and no words for one
    // that was dismissed.
    let did = mine(reviews).and_then(|r| {
        let did = match r.state.as_str() {
            "APPROVED" => "approved it",
            "CHANGES_REQUESTED" => "asked for changes",
            "COMMENTED" => "commented",
            // When it was dismissed isn't known, only when it was given.
            "DISMISSED" => return Some(None),
            _ => return None,
        };
        Some(Some(match r.at {
            Some(at) => format!("{did} {{ago:{at}}}"),
            None => did.to_string(),
        }))
    });
    let asked = asked(pr, reviews);
    if let Some(Asked::SignOff(approves)) = asked {
        let asked = format!("Your sign-off is asked for{}: Codealong\u{2019}s agent approves {approves}", if did.is_some() { " again" } else { "" });
        return Some(match did {
            Some(Some(did)) => format!("{asked}. You {did}"),
            Some(None) => format!("{asked}. Your last review was dismissed"),
            None => asked,
        });
    }
    let again = matches!(asked, Some(Asked::Again));
    Some(match (did?, again) {
        (Some(did), true) => format!("Your review is asked for again: you {did}"),
        (Some(did), false) => format!("You {did}"),
        (None, true) => "Your review is asked for again: the last was dismissed".to_string(),
        (None, false) => "Your review was dismissed".to_string(),
    })
}

/// The box for `pr`, with your draft review of it and its reviews as its page read them.
#[uniffi::export]
pub fn review_box(pr: PrRow, draft: Option<PrDraft>, reviews: Vec<PrReview>) -> ReviewBox {
    let open = is_open(&pr.state);
    let reviewable = open && !pr.opened_by_its_mac;
    let hint = if draft.is_some() {
        "Your words, before your draft review’s (optional)".to_string()
    } else if reviewable {
        "Your review, if it says anything".to_string()
    } else {
        format!("Comment on #{}", pr.number)
    };
    let why = if !open {
        Some("It’s closed: a comment still goes to the PR.".to_string())
    } else if pr.opened_by_its_mac && pr.mine {
        Some("GitHub doesn’t let you approve your own PR: you can comment.".to_string())
    } else if pr.opened_by_its_mac {
        // A bot of yours, say, that the Mac acting on it is signed in as.
        let author = pr.author.as_deref().unwrap_or("its author");
        Some(format!("{} is signed in to GitHub as {author}, who opened it, and GitHub doesn’t let them approve it: you can comment.", pr.device_name))
    } else {
        None
    };
    let with = draft.map(|d| match d.count {
        0 => "Sending submits your draft review too.".to_string(),
        n => format!("Sending submits your draft review too, with its {}.", comments(n)),
    });
    let note = match (why, with) {
        (Some(why), Some(with)) => Some(format!("{why} {with}")),
        (why, with) => why.or(with),
    };
    let approved = reviewable && mine(&reviews).is_some_and(|r| r.state == "APPROVED") && asked(&pr, &reviews).is_none();
    ReviewBox { reviewable, hint, note, yours: yours(&pr, &reviews), approved }
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
        p.opened_by_its_mac = mine;
        p
    }

    fn draft(body: &str, count: u64) -> PrDraft {
        PrDraft { body: body.into(), url: None, comments: vec![], count, stamp: "s".into() }
    }

    #[test]
    fn an_open_pr_not_yours_takes_every_verdict() {
        for state in ["open", "draft", "approved", "changes"] {
            let b = review_box(pr(state, false), None, vec![]);
            assert!(b.reviewable, "{state}");
            assert_eq!(b.hint, "Your review, if it says anything");
            assert_eq!(b.note, None);
        }
    }

    #[test]
    fn your_own_or_a_closed_one_takes_a_comment() {
        let mine = review_box(pr("open", true), None, vec![]);
        assert!(!mine.reviewable);
        assert_eq!(mine.hint, "Comment on #7");
        assert_eq!(mine.note.as_deref(), Some("GitHub doesn’t let you approve your own PR: you can comment."));
        for state in ["merged", "closed"] {
            let b = review_box(pr(state, false), None, vec![]);
            assert!(!b.reviewable);
            assert_eq!(b.note.as_deref(), Some("It’s closed: a comment still goes to the PR."));
        }
    }

    #[test]
    fn the_box_goes_by_the_account_its_mac_acts_as() {
        // A bot's PR, asked of the Mac signed in as the bot: GitHub won't take its approval.
        let mut bots = pr("open", false);
        bots.opened_by_its_mac = true;
        bots.author = Some("ann-bot".into());
        bots.device_name = "Mini".into();
        let b = review_box(bots, None, vec![]);
        assert!(!b.reviewable);
        assert_eq!(b.note.as_deref(), Some("Mini is signed in to GitHub as ann-bot, who opened it, and GitHub doesn’t let them approve it: you can comment."));
        // Yours, asked of a Mac signed in as another account: that account can approve it.
        let mut yours = pr("open", true);
        yours.opened_by_its_mac = false;
        assert!(review_box(yours, None, vec![]).reviewable);
    }

    #[test]
    fn a_draft_goes_with_whatever_is_sent() {
        let b = review_box(pr("open", false), Some(draft("Hold it.", 3)), vec![]);
        assert_eq!(b.hint, "Your words, before your draft review’s (optional)");
        assert_eq!(b.note.as_deref(), Some("Sending submits your draft review too, with its 3 comments."));
        assert_eq!(review_box(pr("open", false), Some(draft("x", 0)), vec![]).note.as_deref(), Some("Sending submits your draft review too."));
        let mine = review_box(pr("open", true), Some(draft("", 1)), vec![]);
        assert_eq!(mine.note.as_deref(), Some("GitHub doesn’t let you approve your own PR: you can comment. Sending submits your draft review too, with its 1 comment."));
    }

    fn review(author: &str, state: &str, at: Option<i64>, mine: bool) -> PrReview {
        PrReview { author: author.into(), state: state.into(), at, mine }
    }

    #[test]
    fn your_own_review_is_said_with_when() {
        let yours = |reviews: Vec<PrReview>| review_box(pr("approved", false), None, reviews).yours;
        assert_eq!(yours(vec![review("ann", "APPROVED", Some(5), false), review("me", "APPROVED", Some(9), true)]).as_deref(), Some("You approved it {ago:9}"));
        assert_eq!(yours(vec![review("me", "CHANGES_REQUESTED", Some(9), true)]).as_deref(), Some("You asked for changes {ago:9}"));
        assert_eq!(yours(vec![review("me", "COMMENTED", None, true)]).as_deref(), Some("You commented"));
        assert_eq!(yours(vec![review("me", "DISMISSED", Some(9), true)]).as_deref(), Some("Your review was dismissed"));
        // Someone else's approval isn't yours, and a Mac that doesn't say whose is whose says none.
        assert_eq!(yours(vec![review("ann", "APPROVED", Some(5), false)]), None);
        assert_eq!(yours(vec![]), None);
    }

    #[test]
    fn a_review_asked_for_again_after_yours_says_so_first() {
        // Commits came after you approved it, and its author asked you again: it waits on you.
        let yours = |state: &str, requested: bool, reviews: Vec<PrReview>| {
            let mut p = pr(state, false);
            p.review_requested = requested;
            review_box(p, None, reviews).yours
        };
        let approved = || vec![review("me", "APPROVED", Some(9), true)];
        assert_eq!(yours("approved", true, approved()).as_deref(), Some("Your review is asked for again: you approved it {ago:9}"));
        assert_eq!(yours("changes", true, vec![review("me", "CHANGES_REQUESTED", Some(9), true)]).as_deref(), Some("Your review is asked for again: you asked for changes {ago:9}"));
        assert_eq!(yours("open", true, vec![review("me", "DISMISSED", Some(9), true)]).as_deref(), Some("Your review is asked for again: the last was dismissed"));
        // Not asked, or asked of no one who reviewed it, or past asking: as before.
        assert_eq!(yours("approved", false, approved()).as_deref(), Some("You approved it {ago:9}"));
        assert_eq!(yours("open", true, vec![]), None);
        assert_eq!(yours("merged", true, approved()).as_deref(), Some("You approved it {ago:9}"));
        assert_eq!(yours("draft", true, approved()).as_deref(), Some("You approved it {ago:9}"));
    }

    #[test]
    fn a_pr_the_agent_approves_asks_for_your_sign_off() {
        use crate::quick::PrAgent;
        let agent = |kind: &str, approves: Option<&str>| PrAgent { kind: kind.into(), words: String::new(), says: String::new(), approves: approves.map(str::to_string) };
        let yours = |agent: PrAgent, reviews: Vec<PrReview>| {
            let mut p = pr("changes", false);
            p.review_requested = true;
            p.agent = Some(agent);
            review_box(p, None, reviews).yours
        };
        // Its first round asked for changes as your review; its second approves the fixed commit.
        let changes = || vec![review("me", "CHANGES_REQUESTED", Some(9), true)];
        assert_eq!(yours(agent("approves", Some("309811a")), changes()).as_deref(), Some("Your sign-off is asked for again: Codealong’s agent approves 309811a. You asked for changes {ago:9}"));
        assert_eq!(yours(agent("approves", Some("309811a")), vec![]).as_deref(), Some("Your sign-off is asked for: Codealong’s agent approves 309811a"));
        assert_eq!(yours(agent("approves", Some("309811a")), vec![review("me", "DISMISSED", Some(9), true)]).as_deref(), Some("Your sign-off is asked for again: Codealong’s agent approves 309811a. Your last review was dismissed"));
        // While it re-reviews or reviews, it's your review that's asked, as before.
        assert_eq!(yours(agent("re-reviewing", Some("1a2b3c4")), changes()).as_deref(), Some("Your review is asked for again: you asked for changes {ago:9}"));
        assert_eq!(yours(agent("reviewing", None), vec![]), None);
    }

    #[test]
    fn your_approval_stands_until_your_review_is_asked_again() {
        use crate::quick::PrAgent;
        let approved = |f: &dyn Fn(&mut PrRow), reviews: Vec<PrReview>| {
            let mut p = pr("approved", false);
            f(&mut p);
            review_box(p, None, reviews).approved
        };
        let mine = || vec![review("me", "APPROVED", Some(9), true)];
        assert!(approved(&|_| {}, mine()));
        // Someone else's approval, or another verdict of yours, isn't.
        assert!(!approved(&|_| {}, vec![review("ann", "APPROVED", Some(9), false)]));
        assert!(!approved(&|_| {}, vec![review("me", "CHANGES_REQUESTED", Some(9), true)]));
        // Asked again, or the agent asking your sign-off, is a review still to give.
        assert!(!approved(&|p| p.review_requested = true, mine()));
        let signs = PrAgent { kind: "approves".into(), words: String::new(), says: String::new(), approves: Some("309811a".into()) };
        assert!(!approved(&|p| p.agent = Some(signs.clone()), mine()));
        // A PR that takes only a comment has no Approve to step back.
        assert!(!approved(&|p| p.opened_by_its_mac = true, mine()));
        assert!(!approved(&|p| p.state = "merged".into(), mine()));
    }

    #[test]
    fn a_review_since_the_ask_answers_it() {
        use crate::quick::PrAgent;
        // Approved here a moment ago: its Mac still lists the ask, and the agent's sign-off with it.
        let mut p = pr("approved", false);
        p.review_requested = true;
        p.requested_at = Some(5);
        p.agent = Some(PrAgent { kind: "approves".into(), words: String::new(), says: String::new(), approves: Some("309811a".into()) });
        let b = review_box(p.clone(), None, vec![review("me", "APPROVED", Some(9), true)]);
        assert_eq!(b.yours.as_deref(), Some("You approved it {ago:9}"));
        assert!(b.approved);
        // One given before the ask, or dismissed since, doesn't answer it; nor one whose time isn't known.
        let before = review_box(p.clone(), None, vec![review("me", "APPROVED", Some(3), true)]);
        assert!(before.yours.unwrap().starts_with("Your sign-off is asked for again"));
        assert!(!before.approved);
        assert!(review_box(p.clone(), None, vec![review("me", "DISMISSED", Some(9), true)]).yours.unwrap().starts_with("Your sign-off is asked for again"));
        assert!(!review_box(p.clone(), None, vec![review("me", "APPROVED", None, true)]).approved);
        p.agent = None;
        assert_eq!(review_box(p.clone(), None, vec![review("me", "COMMENTED", Some(9), true)]).yours.as_deref(), Some("You commented {ago:9}"));
        p.requested_at = None;
        assert!(!review_box(p, None, vec![review("me", "APPROVED", Some(9), true)]).approved);
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
