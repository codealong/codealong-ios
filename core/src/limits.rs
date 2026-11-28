//! A session's account already at a usage limit, though its own last turn didn't stop at one: the
//! warning the Mac's session header gives before you send it something that would only stop there
//! (the main repo's accountLimit.ts `accountLimitFor`, which mirrors its engine's exhausted.rs
//! `check_with_model`). Another session of the account was refused at a limit this one's model
//! spends, and nothing since says it has lifted; or the account's usage reads such a limit full,
//! with no extra usage to carry a turn past it.

use codealong_peer::model::{Lane, Meter, Session, Status as PeerStatus, Usage};

use crate::{SnoozeWhy, Status, SuggestedSnooze, SNOOZE_WORTH_MS};

/// How old a refusal may be and still count (accountLimit.ts and exhausted.rs `REFUSED_FOR`).
const REFUSED_FOR_MS: i64 = 31 * 24 * 60 * 60 * 1000;

/// Below this percent on a usage read since, a refusal at that limit has cleared (a reset was
/// used, say: accountLimit.ts `CLEARED_UNDER`).
const CLEARED_UNDER: f64 = 90.0;

/// Model families with weekly limits of their own on Claude's plans (start.ts `FAMILIES`).
const FAMILIES: [&str; 4] = ["fable", "opus", "sonnet", "haiku"];

/// That a session's account is at a usage limit a new turn on it would stop at, while its own last
/// turn didn't, as the Mac's session header warns of it (SessionHeader.tsx, an amber line with
/// Snooze until it lifts; its Move… is the Mac's, since a phone moves nothing).
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct AccountLimitNote {
    /// What it comes to, `{in:<ms>}` for when it lifts, as the Mac's line says it under the
    /// pointer (accountLimit.ts `accountLimitWords`; the line itself is short, "work at weekly
    /// limit · lifts in 9h", where the phone has room for the sentence): "work is at its weekly
    /// limit, with no extra usage to carry it. It lifts {in:…}. Starting a new turn will hit it."
    pub says: String,
    /// When it lifts, while it hasn't: its page reads its row again then, and the line goes.
    pub lifts_at: Option<i64>,
    /// Snooze until it lifts, beside the line while that's five minutes off or more
    /// (`accountLimitSnoozeable`), for one that isn't snoozed, archived or an orchestrator's (the
    /// Mac's `snoozeUntil`): the plain snooze, never until room.
    pub snooze: Option<SuggestedSnooze>,
}

/// The limit itself (accountLimit.ts `AccountLimit`).
#[derive(Debug, PartialEq)]
struct AccountLimit {
    /// As a meter keys it (`session`, `week`, `model:Opus`), or none for a limit that wasn't named.
    meter: Option<String>,
    resets_at: Option<i64>,
    /// Its extra usage is off or was refused too.
    spend_capped: bool,
}

/// The note for `s`, whose Mac's board has `lanes` and its accounts' `usage`, as its Mac's header
/// would show it now; `snoozed` while it's snoozed.
pub(crate) fn account_limit_note(s: &Session, status: Status, snoozed: bool, lanes: &[Lane], usage: &[Usage], now: i64) -> Option<AccountLimitNote> {
    let limit = account_limit(s, status, lanes, usage, now)?;
    let name = crate::limit_name(limit.meter.as_deref());
    let lifts = limit.resets_at.filter(|&t| t > now);
    let spent = if limit.spend_capped { ", with no extra usage to carry it" } else { "" };
    let when = lifts.map(|t| format!(" It lifts {{in:{t}}}.")).unwrap_or_default();
    // The Mac adds "unless you move to another account" where it can move it: a phone can't.
    let says = format!("{} is at its {name}{spent}.{when} Starting a new turn will hit it.", s.account);
    let snooze = lifts.filter(|&t| t - now >= SNOOZE_WORTH_MS && !snoozed && !s.archived && s.orchestrator.is_none()).map(|until| {
        let because = "when its limit lifts".to_string();
        let at = format!("{{at:{until}}}");
        SuggestedSnooze {
            until,
            offered_till: until - SNOOZE_WORTH_MS,
            why: SnoozeWhy::Limit,
            label: format!("Until {at}, {because}"),
            because,
            by: None,
            button: Some("Snooze until it lifts".into()),
            does: Some(format!("It leaves what waits on you until {at}, when the limit lifts")),
        }
    });
    Some(AccountLimitNote { says, lifts_at: lifts, snooze })
}

/// The limit a new turn on `s` would stop at (accountLimit.ts `accountLimitFor`): none for one its
/// own limit stopped (its note says that), one that's working or one archived.
fn account_limit(s: &Session, status: Status, lanes: &[Lane], usage: &[Usage], now: i64) -> Option<AccountLimit> {
    if s.limit.is_some() || status == Status::Working || s.archived {
        return None;
    }
    let read = usage.iter().find(|u| u.account == s.account);
    let meters: &[Meter] = read.map_or(&[], |u| &u.meters);
    let same: Vec<&Session> = lanes.iter().flat_map(|l| l.sessions.iter()).filter(|o| o.account == s.account).collect();

    // Another session of the account refused at a limit this one's model spends, which nothing
    // since has cleared: a later turn that ended without one on a model that spends it, or a usage
    // read since that has its extra usage back (for a spend cap) or the limit's meter below near
    // full. The latest to lift, then the latest refused.
    let mut best: Option<(i64, AccountLimit)> = None;
    for other in &same {
        let Some(lim) = other.limit.as_ref() else { continue };
        let Some(resets) = lim.resets_at.filter(|&t| t > now) else { continue };
        if now - lim.at >= REFUSED_FOR_MS {
            continue;
        }
        let family = limit_model(lim.meter.as_deref());
        if !spends(s.model.as_deref(), family, meters) {
            continue;
        }
        let cleared_by_turn = same.iter().any(|o| o.limit.is_none() && o.status != PeerStatus::Working && o.last_activity > lim.at && (family.is_none() || o.model.as_deref().is_some_and(|m| spends(Some(m), family, meters))));
        if cleared_by_turn {
            continue;
        }
        if let Some(u) = read.filter(|u| u.as_of.is_some_and(|t| t > lim.at) && !u.needs_sign_in) {
            if lim.spend_capped && u.extra_usable == Some(true) {
                continue;
            }
            if let Some(meter) = lim.meter.as_deref() {
                if u.meters.iter().find(|m| m.key == meter).is_some_and(|m| m.percent < CLEARED_UNDER) {
                    continue;
                }
            }
        }
        let out = AccountLimit { meter: lim.meter.clone(), resets_at: Some(resets), spend_capped: lim.spend_capped };
        let replace = match &best {
            None => true,
            Some((at, b)) => resets > b.resets_at.unwrap_or(0) || (Some(resets) == b.resets_at && lim.at > *at),
        };
        if replace {
            best = Some((lim.at, out));
        }
    }
    if let Some((_, limit)) = best {
        return Some(limit);
    }

    // Else a limit it spends reads full on its plan, unless extra usage carries a turn past it.
    let u = read?;
    if u.needs_sign_in || u.loading || u.no_limits || u.extra_usable == Some(true) {
        return None;
    }
    let full: Vec<&Meter> = meters_for(u, s.model.as_deref()).into_iter().filter(|m| m.percent >= 100.0 && m.resets_at.is_none_or(|t| t > now)).collect();
    let mut binding = *full.first()?;
    // The one that binds: one that says when it lifts, the latest of those.
    for m in &full[1..] {
        if let Some(t) = m.resets_at {
            if binding.resets_at.is_none_or(|b| t > b) {
                binding = m;
            }
        }
    }
    Some(AccountLimit {
        meter: Some(binding.model.as_ref().map_or_else(|| binding.key.clone(), |f| format!("model:{f}"))),
        resets_at: binding.resets_at,
        spend_capped: u.extra_usable == Some(false),
    })
}

/// The family a limit is for, from its meter's key (`model:Opus`), or none for one of every model.
fn limit_model(meter: Option<&str>) -> Option<&str> {
    meter?.strip_prefix("model:").filter(|f| !f.is_empty())
}

/// The families a limit's name has, several joined by ` & ` (`Claude & GPT`), in lowercase.
fn families_of(limit: &str) -> Vec<String> {
    limit.split(" & ").map(|f| f.trim().to_lowercase()).filter(|f| !f.is_empty()).collect()
}

/// A turn on `model` spends the limit for `family` (start.rs `spends`): it's for every model, or
/// for a family the model's name has; or the name has none of Claude's families nor any the
/// account's limits are for, so it could be any of them.
fn spends(model: Option<&str>, family: Option<&str>, meters: &[Meter]) -> bool {
    let Some(family) = family else { return true };
    let m = model.unwrap_or_default().to_lowercase();
    if families_of(family).iter().any(|f| m.contains(f.as_str())) {
        return true;
    }
    let named = FAMILIES.iter().any(|f| m.contains(f)) || meters.iter().any(|x| x.model.as_deref().is_some_and(|xm| families_of(xm).iter().any(|f| m.contains(f.as_str()))));
    !named
}

/// The limits a turn on `model` spends (start.ts `metersFor`): those for every model and those for
/// a family its name has; every one where its name has none that any limit or Claude names.
fn meters_for<'a>(u: &'a Usage, model: Option<&str>) -> Vec<&'a Meter> {
    let m = model.unwrap_or_default().to_lowercase();
    let named = |limit: &str| families_of(limit).iter().any(|f| m.contains(f.as_str()));
    if !FAMILIES.iter().any(|f| m.contains(f)) && !u.meters.iter().any(|x| x.model.as_deref().is_some_and(named)) {
        return u.meters.iter().collect();
    }
    u.meters.iter().filter(|x| x.model.as_deref().is_none_or(named)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use codealong_peer::model::{Harness, SessionLimit, Severity};

    const NOW: i64 = 1_000_000_000_000;
    const HOUR: i64 = 3_600_000;

    fn session(id: &str, account: &str, model: Option<&str>) -> Session {
        Session { model: model.map(str::to_string), last_activity: NOW - 10 * HOUR, status: PeerStatus::Idle, ..Session::new(Harness::Claude, account, id) }
    }

    fn refused(id: &str, account: &str, meter: Option<&str>, at: i64, resets_at: i64) -> Session {
        Session { limit: Some(SessionLimit { meter: meter.map(str::to_string), resets_at: Some(resets_at), at, ..SessionLimit::default() }), last_activity: at, ..session(id, account, Some("claude-opus-5-5")) }
    }

    fn meter(key: &str, model: Option<&str>, percent: f64, resets_at: Option<i64>) -> Meter {
        Meter { key: key.into(), label: String::new(), window: String::new(), percent, resets_at, severity: Severity::Critical, model: model.map(str::to_string) }
    }

    fn usage(account: &str, meters: Vec<Meter>, as_of: Option<i64>, extra: Option<bool>) -> Usage {
        Usage { account: account.into(), harness: Harness::Claude, plan: None, meters, as_of, error: None, needs_sign_in: false, loading: false, no_limits: false, preferred: false, rate_limited: false, extra_usable: extra }
    }

    fn lanes(sessions: Vec<Session>) -> Vec<Lane> {
        let mut lane = Lane::new("/src/app", "App", "app");
        lane.sessions = sessions;
        vec![lane]
    }

    fn note(s: &Session, all: Vec<Session>, usage: &[Usage]) -> Option<AccountLimitNote> {
        account_limit_note(s, s.status.into(), false, &lanes(all), usage, NOW)
    }

    #[test]
    fn another_sessions_refusal_warns_one_that_would_spend_the_same_limit() {
        let me = session("me", "work", Some("claude-opus-5-5"));
        let other = refused("other", "work", Some("week"), NOW - HOUR, NOW + 9 * HOUR);
        let n = note(&me, vec![me.clone(), other.clone()], &[]).unwrap();
        assert_eq!(n.says, format!("work is at its weekly limit. It lifts {{in:{}}}. Starting a new turn will hit it.", NOW + 9 * HOUR));
        assert_eq!(n.lifts_at, Some(NOW + 9 * HOUR));
        let snooze = n.snooze.unwrap();
        assert_eq!((snooze.until, snooze.why, snooze.button.as_deref()), (NOW + 9 * HOUR, SnoozeWhy::Limit, Some("Snooze until it lifts")));
        assert_eq!(snooze.does.unwrap(), format!("It leaves what waits on you until {{at:{}}}, when the limit lifts", NOW + 9 * HOUR));

        // Not another account's, one whose own limit stopped it (its note says so), one at work,
        // or one archived.
        let elsewhere = session("me", "home", Some("claude-opus-5-5"));
        assert_eq!(note(&elsewhere, vec![elsewhere.clone(), other.clone()], &[]), None);
        assert_eq!(note(&other, vec![me.clone(), other.clone()], &[]), None);
        let working = Session { status: PeerStatus::Working, ..me.clone() };
        assert_eq!(note(&working, vec![working.clone(), other.clone()], &[]), None);
        let archived = Session { archived: true, ..me.clone() };
        assert_eq!(note(&archived, vec![archived.clone(), other.clone()], &[]), None);

        // Nor a refusal that has lifted, or that's older than a month.
        let lifted = refused("other", "work", Some("week"), NOW - 2 * HOUR, NOW - HOUR);
        assert_eq!(note(&me, vec![me.clone(), lifted], &[]), None);
        let old = refused("other", "work", Some("week"), NOW - 32 * 24 * HOUR, NOW + HOUR);
        assert_eq!(note(&me, vec![me.clone(), old], &[]), None);

        // No snooze while one's on, or for a lift under five minutes off.
        let snoozed = account_limit_note(&me, Status::Idle, true, &lanes(vec![me.clone(), other.clone()]), &[], NOW).unwrap();
        assert_eq!(snoozed.snooze, None);
        let soon = refused("other", "work", Some("session"), NOW - HOUR, NOW + 4 * 60_000);
        let n = note(&me, vec![me.clone(), soon], &[]).unwrap();
        assert!(n.says.starts_with("work is at its 5-hour limit. It lifts"), "{}", n.says);
        assert_eq!(n.snooze, None);
    }

    #[test]
    fn a_refusal_clears_with_a_later_turn_or_a_usage_read_that_says_so() {
        let me = session("me", "work", Some("claude-opus-5-5"));
        let other = refused("other", "work", Some("week"), NOW - 2 * HOUR, NOW + 9 * HOUR);
        // A turn since that ended without a limit.
        let since = Session { last_activity: NOW - HOUR, ..session("since", "work", Some("claude-sonnet-5-5")) };
        assert_eq!(note(&me, vec![me.clone(), other.clone(), since], &[]), None);
        // A usage read since with the week below near full.
        let below = usage("work", vec![meter("week", None, 60.0, Some(NOW + 9 * HOUR))], Some(NOW - HOUR), None);
        assert_eq!(note(&me, vec![me.clone(), other.clone()], &[below]), None);
        // One before the refusal says nothing of it.
        let before = usage("work", vec![meter("week", None, 60.0, Some(NOW + 9 * HOUR))], Some(NOW - 3 * HOUR), None);
        assert!(note(&me, vec![me.clone(), other.clone()], &[before]).is_some());
        // A spend cap clears once the read has extra usage on again.
        let capped = Session { limit: Some(SessionLimit { spend_capped: true, ..other.limit.clone().unwrap() }), ..other.clone() };
        let n = note(&me, vec![me.clone(), capped.clone()], &[]).unwrap();
        assert!(n.says.starts_with("work is at its weekly limit, with no extra usage to carry it."), "{}", n.says);
        let back = usage("work", vec![meter("week", None, 100.0, Some(NOW + 9 * HOUR))], Some(NOW - HOUR), Some(true));
        assert_eq!(note(&me, vec![me.clone(), capped], &[back]), None);
    }

    #[test]
    fn a_models_own_limit_counts_only_for_a_turn_on_that_model() {
        let opus = refused("other", "work", Some("model:Opus"), NOW - HOUR, NOW + 30 * HOUR);
        let on_sonnet = session("me", "work", Some("claude-sonnet-5-5"));
        assert_eq!(note(&on_sonnet, vec![on_sonnet.clone(), opus.clone()], &[]), None);
        let on_opus = session("me", "work", Some("claude-opus-5-5"));
        let n = note(&on_opus, vec![on_opus.clone(), opus.clone()], &[]).unwrap();
        assert!(n.says.starts_with("work is at its weekly Opus limit. It lifts"), "{}", n.says);
        // A model that names no family could be any.
        let unnamed = session("me", "work", None);
        assert!(note(&unnamed, vec![unnamed.clone(), opus.clone()], &[]).is_some());
        // A Sonnet turn since doesn't clear Opus's limit; an Opus one does.
        let sonnet_since = Session { last_activity: NOW - 1, ..session("since", "work", Some("claude-sonnet-5-5")) };
        assert!(note(&on_opus, vec![on_opus.clone(), opus.clone(), sonnet_since], &[]).is_some());
        let opus_since = Session { last_activity: NOW - 1, ..session("since", "work", Some("claude-opus-5-5")) };
        assert_eq!(note(&on_opus, vec![on_opus.clone(), opus, opus_since], &[]), None);
    }

    #[test]
    fn a_full_meter_warns_unless_extra_usage_carries_it() {
        let me = session("me", "work", Some("claude-opus-5-5"));
        let full = |extra| usage("work", vec![meter("session", None, 40.0, Some(NOW + HOUR)), meter("week", None, 100.0, Some(NOW + 50 * HOUR)), meter("model:Sonnet", Some("Sonnet"), 100.0, Some(NOW + 60 * HOUR))], Some(NOW - HOUR), extra);
        let n = note(&me, vec![me.clone()], &[full(None)]).unwrap();
        // Sonnet's own week isn't Opus's to spend.
        assert_eq!(n.says, format!("work is at its weekly limit. It lifts {{in:{}}}. Starting a new turn will hit it.", NOW + 50 * HOUR));
        let n = note(&me, vec![me.clone()], &[full(Some(false))]).unwrap();
        assert!(n.says.contains(", with no extra usage to carry it."), "{}", n.says);
        assert_eq!(note(&me, vec![me.clone()], &[full(Some(true))]), None);
        // On Sonnet the later of the two binds, as its own week's.
        let sonnet = session("me", "work", Some("claude-sonnet-5-5"));
        let n = note(&sonnet, vec![sonnet.clone()], &[full(None)]).unwrap();
        assert!(n.says.starts_with(&format!("work is at its weekly Sonnet limit. It lifts {{in:{}}}.", NOW + 60 * HOUR)), "{}", n.says);
        // Nothing to go by while it signs in, loads or keeps no limits.
        let signing = Usage { needs_sign_in: true, ..full(None) };
        assert_eq!(note(&me, vec![me.clone()], &[signing]), None);
        let none = Usage { no_limits: true, ..full(None) };
        assert_eq!(note(&me, vec![me.clone()], &[none]), None);
        // A meter whose time has passed has reset.
        let reset = usage("work", vec![meter("week", None, 100.0, Some(NOW - 1))], Some(NOW - HOUR), None);
        assert_eq!(note(&me, vec![me.clone()], &[reset]), None);
        // One that says no time warns without one, and offers no snooze.
        let timeless = usage("work", vec![meter("week", None, 100.0, None)], Some(NOW - HOUR), None);
        let n = note(&me, vec![me.clone()], &[timeless]).unwrap();
        assert_eq!((n.says.as_str(), n.lifts_at, n.snooze), ("work is at its weekly limit. Starting a new turn will hit it.", None, None));
    }
}
