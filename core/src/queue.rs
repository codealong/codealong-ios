//! Going through what waits on you, one page after another, as every Mac window does (the main
//! repo's `queue.ts`): the order they go through it in (`by_place`), and what's left after the
//! page shown (`left_after`). Which sessions and PRs wait on you, and what's been dealt with here,
//! are the store's; where it goes next from is the Mac's rule, kept here so it has tests.

use std::cmp::Ordering;
use std::collections::HashMap;

/// What something waits on you as, the most urgent first (queue.ts `WAITS`): a session that needs
/// you, a PR waiting on your review, a turn that ended.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Waits {
    Needs,
    Reviews,
    Unread,
}

/// Where something that waits on you stands in the queue (queue.ts `Place`): what it waits as,
/// since when, and its key, for a tie.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct QueuePlace {
    pub key: String,
    pub waits: Waits,
    /// When it began waiting as it does: a session's status, the latest request for a review.
    pub since: i64,
}

/// The order what waits on you is gone through in (queue.ts `byPlace`): the most urgent kind
/// first, each the longest wait first, so one that comes to wait, or comes back after you answered
/// it, joins the end of its kind and never goes ahead of the ones that have waited longer. The
/// lists show it in their own orders (Your turn, the newest first), which this doesn't follow.
fn by_place(a: &QueuePlace, b: &QueuePlace) -> Ordering {
    (a.waits, a.since, &a.key).cmp(&(b.waits, b.since, &b.key))
}

/// The keys of what's left after `key`, the next first (queue.ts `leftAfter`): those after it in
/// the queue's order, then those before it (the ones gone on from, and any that came to wait ahead
/// of where you are), without it and the ones dealt with (`handled`, by when the wait each was
/// dealt with began) until they wait on you anew. One `places` no longer has goes on from where it
/// stood (`was`, while that's its own: answered, its Mac can show it working before the answer's
/// in); one that never waited goes from the top.
#[uniffi::export]
pub fn left_after(places: Vec<QueuePlace>, key: String, handled: HashMap<String, i64>, was: Option<QueuePlace>) -> Vec<String> {
    let mut places = places;
    places.sort_by(by_place);
    let from = places.iter().find(|p| p.key == key).cloned().or(was.filter(|w| w.key == key));
    let i = from.and_then(|f| places.iter().position(|p| by_place(p, &f) == Ordering::Greater)).unwrap_or(0);
    places.rotate_left(i);
    places.into_iter().filter(|p| p.key != key && handled.get(&p.key).is_none_or(|dealt| p.since > *dealt)).map(|p| p.key).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn place(key: &str, waits: Waits, since: i64) -> QueuePlace {
        QueuePlace { key: key.into(), waits, since }
    }

    // As the Mac's tests have them: A and B need you, C and D are finished turns.
    fn waiting() -> Vec<QueuePlace> {
        vec![place("A", Waits::Needs, 10), place("B", Waits::Needs, 20), place("C", Waits::Unread, 30), place("D", Waits::Unread, 40)]
    }

    fn none() -> HashMap<String, i64> {
        HashMap::new()
    }

    fn after(places: Vec<QueuePlace>, key: &str) -> Vec<String> {
        left_after(places, key.into(), none(), None)
    }

    #[test]
    fn goes_through_the_most_urgent_kind_first_each_the_longest_wait_first_whatever_the_lists_order() {
        let review = place("R", Waits::Reviews, 5);
        let mut shuffled = waiting();
        shuffled.reverse();
        shuffled.insert(1, review);
        assert_eq!(after(shuffled, ""), ["A", "B", "R", "C", "D"]);
        // A key settles a tie.
        assert_eq!(after(vec![place("C2", Waits::Unread, 30), place("C", Waits::Unread, 30)], ""), ["C", "C2"]);
    }

    #[test]
    fn goes_on_from_the_one_shown_then_back_round_to_the_ones_before_it() {
        assert_eq!(after(waiting(), "A"), ["B", "C", "D"]);
        assert_eq!(after(waiting(), "C"), ["D", "A", "B"]);
        // Not in the queue, and never was (it runs): from the top.
        assert_eq!(after(waiting(), "W"), ["A", "B", "C", "D"]);
        assert_eq!(after(waiting(), ""), ["A", "B", "C", "D"]);
        // The last one goes round to the top.
        assert_eq!(after(waiting(), "D"), ["A", "B", "C"]);
    }

    #[test]
    fn goes_on_from_where_an_answered_one_stood_once_it_no_longer_waits() {
        // B was answered and its Mac shows it working before the answer's in: on to C, and A,
        // gone on from to get to B, still comes after the rest.
        let rest: Vec<QueuePlace> = waiting().into_iter().filter(|p| p.key != "B").collect();
        let b = place("B", Waits::Needs, 20);
        assert_eq!(left_after(rest.clone(), "B".into(), none(), Some(b.clone())), ["C", "D", "A"]);
        // Where another stood says nothing of this one's.
        assert_eq!(left_after(rest, "W".into(), none(), Some(b)), ["A", "C", "D"]);
    }

    #[test]
    fn takes_one_that_comes_to_wait_ahead_of_where_you_are_round_after_the_rest() {
        // On C, a turn that ended: N comes to need you. It's after D, before going round to A and B.
        let mut places = waiting();
        places.push(place("N", Waits::Needs, 50));
        assert_eq!(after(places, "C"), ["D", "A", "B", "N"]);
    }

    #[test]
    fn leaves_out_what_was_dealt_with_until_it_waits_anew() {
        let handled = HashMap::from([("B".to_string(), 20)]);
        assert_eq!(left_after(waiting(), "A".into(), handled.clone(), None), ["C", "D"]);
        let again: Vec<QueuePlace> = waiting().into_iter().map(|p| if p.key == "B" { place("B", Waits::Needs, 50) } else { p }).collect();
        assert_eq!(left_after(again, "A".into(), handled, None), ["B", "C", "D"]);
    }

    #[test]
    fn puts_one_that_waits_again_after_you_answered_it_behind_the_ones_that_waited_longer() {
        // C's turn ended again after you answered it: D has waited longer now.
        let again: Vec<QueuePlace> = waiting().into_iter().map(|p| if p.key == "C" { place("C", Waits::Unread, 50) } else { p }).collect();
        assert_eq!(left_after(again, "B".into(), HashMap::from([("C".to_string(), 30)]), None), ["D", "C", "A"]);
    }

    #[test]
    fn has_reviews_after_what_needs_you_and_before_the_turns_that_ended_however_long_they_waited() {
        let places = vec![place("old turn", Waits::Unread, 1), place("review", Waits::Reviews, 100), place("needs", Waits::Needs, 200)];
        assert_eq!(after(places.clone(), ""), ["needs", "review", "old turn"]);
        assert_eq!(after(places, "review"), ["old turn", "needs"]);
    }
}
