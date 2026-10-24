//! Who you are on GitHub. Each Mac calls a PR yours when the account its `gh` is signed in as
//! opened it, and one Mac can be signed in as another account than the rest: a bot its agents
//! open PRs as, for you to review, or a work account. The phone lists every Mac's PRs together,
//! so it judges them all by the same accounts: the one most of the Macs are signed in as (of
//! those, the one that opened most of the PRs they list), unless you picked others on the PRs
//! page.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use codealong_peer::feed::Replica;
use serde::{Deserialize, Serialize};

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
fn signed_in_as(replica: &Replica) -> Option<&str> {
    replica.prs.iter().find(|p| p.mine).and_then(|p| p.author.as_deref())
}

#[derive(Serialize, Deserialize, Default, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Saved {
    /// Each Mac's account by its device key, as its list last said: a list that has none of its
    /// own PRs for now (none open, none merged lately) doesn't say.
    #[serde(default)]
    signed_in: HashMap<String, String>,
    /// The accounts you picked as yours.
    #[serde(default)]
    picked: Vec<String>,
}

/// What the phone keeps of the Macs' accounts and your pick, in a file of its own.
pub(crate) struct Github {
    path: PathBuf,
    saved: Saved,
}

impl Github {
    pub(crate) fn load(path: PathBuf) -> Github {
        let saved = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Github { path, saved }
    }

    /// A save that fails costs only what the lists don't say until they say it again.
    fn save(&self) {
        let Ok(bytes) = serde_json::to_vec(&self.saved) else { return };
        let tmp = self.path.with_extension("tmp");
        if std::fs::write(&tmp, bytes).is_ok() {
            let _ = std::fs::rename(&tmp, &self.path);
        }
    }

    /// The accounts whose PRs are listed as yours: none leaves it to the rule.
    pub(crate) fn pick(&mut self, picked: Vec<String>) {
        self.saved.picked = picked;
        self.save();
    }

    /// Who's who in `feeds`, learning the accounts their lists say.
    pub(crate) fn read(&mut self, feeds: &Feeds) -> You {
        let mut learned = false;
        for (d, replica) in feeds {
            let kept = self.saved.signed_in.get(&d.key);
            if let Some(login) = signed_in_as(replica) {
                if kept.map(String::as_str) != Some(login) {
                    self.saved.signed_in.insert(d.key.clone(), login.to_string());
                    learned = true;
                }
            } else if kept.is_some_and(|k| replica.prs.iter().any(|p| !p.mine && p.author.as_deref().is_some_and(|a| a.eq_ignore_ascii_case(k)))) {
                // A PR of the account it was signed in as that it doesn't call its own: it's
                // signed in as another now, which it hasn't opened a PR as yet.
                self.saved.signed_in.remove(&d.key);
                learned = true;
            }
        }
        if learned {
            self.save();
        }
        You::of(feeds, &self.saved.signed_in, &self.saved.picked)
    }
}

/// Who's who on GitHub for one look at the feeds.
#[derive(Default)]
pub(crate) struct You {
    /// The accounts the linked Macs are signed in as, the one that's yours unless you pick first,
    /// then the rest as they rank for it.
    pub(crate) accounts: Vec<GithubAccount>,
    /// Each linked Mac's account, by device key, lowercased.
    macs: HashMap<String, String>,
    /// The accounts that are yours, lowercased.
    yours: HashSet<String>,
}

impl You {
    /// `signed_in` has each Mac's account by its device key, and `picked` the ones you picked as
    /// yours: none, or none a linked Mac is signed in as now, leaves it to the rule.
    pub(crate) fn of(feeds: &Feeds, signed_in: &HashMap<String, String>, picked: &[String]) -> You {
        let mut by_login: Vec<(String, Vec<String>)> = Vec::new();
        let mut macs = HashMap::new();
        for (d, _) in feeds {
            let Some(login) = signed_in.get(&d.key) else { continue };
            macs.insert(d.key.clone(), login.to_lowercase());
            match by_login.iter_mut().find(|(l, _)| l.eq_ignore_ascii_case(login)) {
                Some((_, names)) => names.push(d.name.clone()),
                None => by_login.push((login.clone(), vec![d.name.clone()])),
            }
        }
        // The PRs each account opened, each PR once however many Macs list it.
        let mut seen = HashSet::new();
        let mut opened: HashMap<String, usize> = HashMap::new();
        for (_, replica) in feeds {
            for p in &replica.prs {
                if let Some(author) = p.author.as_deref().filter(|_| crate::quick::first_seen(&mut seen, &crate::quick::pr_key(&p.url, &p.key), &p.key)) {
                    *opened.entry(author.to_lowercase()).or_default() += 1;
                }
            }
        }
        let count = |login: &str| opened.get(&login.to_lowercase()).copied().unwrap_or(0);
        by_login.sort_by(|a, b| b.1.len().cmp(&a.1.len()).then(count(&b.0).cmp(&count(&a.0))).then_with(|| a.0.cmp(&b.0)));
        let is_picked = |login: &str| picked.iter().any(|p| p.eq_ignore_ascii_case(login));
        let any_picked = by_login.iter().any(|(l, _)| is_picked(l));
        let accounts: Vec<GithubAccount> = by_login.into_iter().enumerate().map(|(i, (login, names))| GithubAccount { yours: if any_picked { is_picked(&login) } else { i == 0 }, login, macs: names }).collect();
        let yours = accounts.iter().filter(|a| a.yours).map(|a| a.login.to_lowercase()).collect();
        You { accounts, macs, yours }
    }

    /// Whether a PR `author` opened is yours.
    pub(crate) fn opened(&self, author: Option<&str>) -> bool {
        author.is_some_and(|a| self.yours.contains(&a.to_lowercase()))
    }

    /// Whether the Mac `device` is signed in as an account of yours.
    pub(crate) fn signs_in(&self, device: &str) -> bool {
        self.macs.get(device).is_some_and(|l| self.yours.contains(l))
    }

    /// Whether the Mac `device` is known to be signed in as an account that isn't yours, so what
    /// it works out for that account, whose move a PR is, isn't yours.
    pub(crate) fn signs_in_as_another(&self, device: &str) -> bool {
        self.macs.get(device).is_some_and(|l| !self.yours.contains(l))
    }
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

    fn logins(you: &You) -> Vec<(&str, bool)> {
        you.accounts.iter().map(|a| (a.login.as_str(), a.yours)).collect()
    }

    fn kept(dir: &str) -> Github {
        let dir = std::env::temp_dir().join(format!("codealong-github-{dir}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Github::load(dir.join("github.json"))
    }

    #[test]
    fn a_mac_signed_in_as_a_bot_doesnt_make_the_bots_prs_yours() {
        // The laptop is signed in as ann and lists her PRs; the mini is signed in as the bot its
        // agents open PRs as, and lists those and hers.
        let laptop = list(vec![card(1, "ann", true), card(2, "ann", true)]);
        let mini = list(vec![card(1, "ann", false), card(3, "ann-bot", true), card(4, "ken", false)]);
        let feeds = [(mac("Laptop"), &laptop), (mac("Mini"), &mini)];
        let you = kept("bot").read(&feeds);
        assert_eq!(logins(&you), [("ann", true), ("ann-bot", false)]);
        assert_eq!(you.accounts[1].macs, ["Mini"]);
        assert!(you.opened(Some("Ann")));
        assert!(!you.opened(Some("ann-bot")));
        assert!(!you.opened(None));
        assert!(you.signs_in("Laptop"));
        assert!(!you.signs_in("Mini"));
    }

    #[test]
    fn the_account_most_macs_are_signed_in_as_is_yours_and_you_can_pick_others() {
        let a = list(vec![card(1, "bot", true)]);
        let b = list(vec![card(2, "ann", true)]);
        let c = list(vec![card(3, "ann", true)]);
        let feeds = [(mac("A"), &a), (mac("B"), &b), (mac("C"), &c)];
        let mut github = kept("most");
        assert_eq!(logins(&github.read(&feeds)), [("ann", true), ("bot", false)]);
        assert_eq!(github.read(&feeds).accounts[0].macs, ["B", "C"]);
        // Picked, a work account and all.
        github.pick(vec!["ann".into(), "Bot".into()]);
        assert_eq!(logins(&github.read(&feeds)), [("ann", true), ("bot", true)]);
        github.pick(vec!["bot".into()]);
        assert_eq!(logins(&github.read(&feeds)), [("ann", false), ("bot", true)]);
        // A pick no Mac is signed in as any longer leaves it to the rule.
        github.pick(vec!["gone".into()]);
        assert_eq!(logins(&github.read(&feeds)), [("ann", true), ("bot", false)]);
    }

    #[test]
    fn a_macs_account_is_kept_while_its_list_has_none_of_its_own() {
        let mut github = kept("aged");
        let laptop = list(vec![card(1, "ann", true)]);
        let mini = list(vec![card(3, "ann-bot", true)]);
        github.pick(vec!["ann".into()]);
        assert_eq!(logins(&github.read(&[(mac("Laptop"), &laptop), (mac("Mini"), &mini)])), [("ann", true), ("ann-bot", false)]);
        // Ann's last PR ages out of the laptop's list: it's still signed in as her, and she's
        // still who you are, after the app opens again too.
        let quiet = list(vec![card(3, "ann-bot", false)]);
        let mut again = Github::load(github.path.clone());
        let you = again.read(&[(mac("Laptop"), &quiet), (mac("Mini"), &mini)]);
        assert_eq!(logins(&you), [("ann-bot", false), ("ann", true)]);
        assert!(!you.opened(Some("ann-bot")));
        // The laptop is signed in as another account now, with no PR of its own yet: Ann's PR it
        // doesn't call its own says so, and it's no longer taken for hers.
        let switched = list(vec![card(1, "ann", false)]);
        let you = again.read(&[(mac("Laptop"), &switched), (mac("Mini"), &mini)]);
        assert_eq!(logins(&you), [("ann-bot", true)]);
        assert!(!you.signs_in("Laptop"));
        // A Mac never seen with a PR of its own says nothing of its account.
        assert!(kept("never").read(&[(mac("Quiet"), &quiet)]).accounts.is_empty());
    }
}
