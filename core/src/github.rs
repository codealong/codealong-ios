//! Who you are on GitHub. Each Mac calls a PR yours when the account its `gh` is signed in as
//! opened it, and one Mac can be signed in as another account than the rest: a bot its agents
//! open PRs as, for you to review, or a work account. The phone lists every Mac's PRs together,
//! so it judges them all by the same accounts: the one most of the Macs are signed in as (of
//! those, the one that opened most of the PRs they list), unless you picked others on the PRs
//! page.

use std::collections::{HashMap, HashSet};

use codealong_peer::feed::Replica;

use crate::Feeds;

/// A GitHub account a linked Mac is signed in as.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct GithubAccount {
    pub login: String,
    /// The Macs signed in as it, by name.
    pub macs: Vec<String>,
    /// The PRs it opened are listed as yours.
    pub yours: bool,
}

/// The account `replica`'s Mac is signed in as, as its PR list says: the author of a PR it calls
/// its own. None when its list has none of its own.
pub(crate) fn signed_in_as(replica: &Replica) -> Option<&str> {
    replica.prs.iter().find(|p| p.mine).and_then(|p| p.author.as_deref())
}

/// The accounts the Macs are signed in as, the one that's yours unless you pick first, then the
/// rest as they rank for it. `picked` are the ones you picked as yours; none, or none a Mac is
/// signed in as now, leaves it to the first.
pub(crate) fn accounts(feeds: &Feeds, picked: &[String]) -> Vec<GithubAccount> {
    let mut macs: Vec<(String, Vec<String>)> = Vec::new();
    for (d, replica) in feeds {
        let Some(login) = signed_in_as(replica) else { continue };
        match macs.iter_mut().find(|(l, _)| l.eq_ignore_ascii_case(login)) {
            Some((_, names)) => names.push(d.name.clone()),
            None => macs.push((login.to_string(), vec![d.name.clone()])),
        }
    }
    // The PRs each account opened, each PR once however many Macs list it.
    let mut seen = HashSet::new();
    let mut opened: HashMap<String, usize> = HashMap::new();
    for (_, replica) in feeds {
        for p in &replica.prs {
            if let Some(author) = p.author.as_deref().filter(|_| crate::quick::first_seen(&mut seen, &p.key, &p.url)) {
                *opened.entry(author.to_lowercase()).or_default() += 1;
            }
        }
    }
    let count = |login: &str| opened.get(&login.to_lowercase()).copied().unwrap_or(0);
    macs.sort_by(|a, b| b.1.len().cmp(&a.1.len()).then(count(&b.0).cmp(&count(&a.0))).then_with(|| a.0.cmp(&b.0)));
    let is_picked = |login: &str| picked.iter().any(|p| p.eq_ignore_ascii_case(login));
    let any_picked = macs.iter().any(|(l, _)| is_picked(l));
    macs.into_iter().enumerate().map(|(i, (login, names))| GithubAccount { yours: if any_picked { is_picked(&login) } else { i == 0 }, login, macs: names }).collect()
}

/// The accounts that are yours, lowercased, for `opened_by_you`.
pub(crate) fn yours(feeds: &Feeds, picked: &[String]) -> HashSet<String> {
    accounts(feeds, picked).into_iter().filter(|a| a.yours).map(|a| a.login.to_lowercase()).collect()
}

/// Whether a PR `author` opened is yours.
pub(crate) fn opened_by_you(author: Option<&str>, yours: &HashSet<String>) -> bool {
    author.is_some_and(|a| yours.contains(&a.to_lowercase()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use codealong_peer::client::Device;
    use codealong_peer::pr::PrCard;

    fn mac(name: &str) -> Device {
        Device { key: name.into(), short: name.into(), name: name.into(), online: true, since: None, last_seen: None, remote_control: true, app: String::new(), loading: false, linked_back: true }
    }

    fn card(number: u64, author: &str, mine: bool) -> PrCard {
        serde_json::from_value(serde_json::json!({"key": format!("o/app#{number}"), "repo": "o/app", "project": "App", "number": number, "title": "T", "url": format!("https://github.com/o/app/pull/{number}"), "state": "open", "author": author, "mine": mine, "head": "b"})).unwrap()
    }

    fn list(prs: Vec<PrCard>) -> Replica {
        Replica { prs, ..Replica::default() }
    }

    fn logins(accounts: &[GithubAccount]) -> Vec<(&str, bool)> {
        accounts.iter().map(|a| (a.login.as_str(), a.yours)).collect()
    }

    #[test]
    fn a_mac_signed_in_as_a_bot_doesnt_make_the_bots_prs_yours() {
        // The laptop is signed in as ann and lists her PRs; the mini is signed in as the bot its
        // agents open PRs as, and lists those and hers.
        let laptop = list(vec![card(1, "ann", true), card(2, "ann", true)]);
        let mini = list(vec![card(1, "ann", false), card(3, "ann-bot", true), card(4, "ken", false)]);
        let feeds = [(mac("Laptop"), &laptop), (mac("Mini"), &mini)];
        let all = accounts(&feeds, &[]);
        assert_eq!(logins(&all), [("ann", true), ("ann-bot", false)]);
        assert_eq!(all[1].macs, ["Mini"]);
        let yours = yours(&feeds, &[]);
        assert!(opened_by_you(Some("Ann"), &yours));
        assert!(!opened_by_you(Some("ann-bot"), &yours));
        assert!(!opened_by_you(None, &yours));
    }

    #[test]
    fn the_account_most_macs_are_signed_in_as_is_yours_and_you_can_pick_others() {
        let a = list(vec![card(1, "bot", true)]);
        let b = list(vec![card(2, "ann", true)]);
        let c = list(vec![card(3, "ann", true)]);
        let feeds = [(mac("A"), &a), (mac("B"), &b), (mac("C"), &c)];
        assert_eq!(logins(&accounts(&feeds, &[])), [("ann", true), ("bot", false)]);
        assert_eq!(accounts(&feeds, &[])[0].macs, ["B", "C"]);
        // Picked, a work account and all.
        assert_eq!(logins(&accounts(&feeds, &["ann".into(), "Bot".into()])), [("ann", true), ("bot", true)]);
        assert_eq!(logins(&accounts(&feeds, &["bot".into()])), [("ann", false), ("bot", true)]);
        // A pick no Mac is signed in as any longer leaves it to the rule.
        assert_eq!(logins(&accounts(&feeds, &["gone".into()])), [("ann", true), ("bot", false)]);
    }

    #[test]
    fn a_mac_whose_list_has_none_of_its_own_says_nothing_of_its_account() {
        let quiet = list(vec![card(1, "ken", false)]);
        let feeds = [(mac("Quiet"), &quiet)];
        assert!(accounts(&feeds, &[]).is_empty());
        assert!(yours(&feeds, &[]).is_empty());
    }
}
