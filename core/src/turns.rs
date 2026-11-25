//! A session's conversation as rows, laid out as the Mac's thread lays it out since 2026-11-23
//! (the main repo's `src/turnFolds.ts`, under `[appearance] tools = "folded"`, its default): runs
//! of tool calls each one line that says in plain words what they did ("Edited 2 files and ran 3
//! commands"), and each finished turn's work, its calls and the agent's updates along the way,
//! folded into one "Worked for 2m · Ran 19 commands" line above the reply that ended it. What you
//! need to see stays out of a fold: a turn still going, one with a call that failed, a call that
//! made a page, handed you files or asked you questions. The phone has no setting for it: a Mac's
//! `[appearance] tools` is that Mac's own, and the phone reads as the Mac does by default.

use crate::{Item, ItemKind, Status};

/// What a row of the conversation is.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowKind {
    /// Something said: a prompt of yours, the agent's reply, a note, a card (`ThreadRow::items`
    /// holds it).
    Said,
    /// A tool call on a line of its own: one alone between what was said, one that failed, made a
    /// page, handed you files or asked you questions.
    Tool,
    /// Two or more calls in a row, as one line saying what they did (`label`), which opens to them.
    Tools,
    /// A finished turn's work, folded into one line (`label`) above the reply that ended it: the
    /// rows that follow with this one's id as their `turn` are what it holds.
    Turn,
}

/// What a run of calls mostly did, for its line's icon (turnFolds.ts `summaryIcon`): the one of
/// most weight among them, edits first.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunIcon {
    Edit,
    Command,
    Agent,
    Search,
    Read,
    Other,
}

/// A row of the conversation, as `thread_rows` lays it out.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ThreadRow {
    /// Unique in the conversation, and the same as it goes on, older pages read in included: what's
    /// open stays open by it.
    pub id: String,
    pub kind: RowKind,
    /// Where in the items given what it shows is: what's said, the one call, or a run's calls; none
    /// for a turn. Places, not the items, so a long conversation isn't copied back each time.
    pub items: Vec<u32>,
    /// A run's words ("Ran 3 commands · 1 failed"), or a turn's ("Worked for 2m · Ran 19
    /// commands"); empty otherwise.
    pub label: String,
    pub icon: RunIcon,
    /// A run's last call shows on its own line under the run's: one the session is running, or
    /// waits on you for. The run's words are of the calls before it then.
    pub last_shown: bool,
    /// The turn this row is folded into (its `Turn` row's id): it shows only while that's open.
    pub turn: Option<String>,
}

/// Calls in a row before they're one line (turnFolds.ts `FOLD_AT_COMPACT`).
const FOLD_AT: usize = 2;

/// The conversation `items` as rows, as the Mac's thread lays them out (`rowsOf`, `foldTurns`).
/// `status` is the session's: its last turn is still going while it works or waits on you, and
/// isn't folded. `in_card`: the call the card at the end of the page shows, which has no line here
/// (the Mac's `inBox`), as it waits on you.
#[uniffi::export]
pub fn thread_rows(items: Vec<Item>, status: Status, in_card: Option<String>) -> Vec<ThreadRow> {
    let active = matches!(status, Status::Working | Status::Needs);
    // The last call with no answer yet is what's running, or what the session waits on you for.
    let pending = items.last().filter(|i| i.kind == ItemKind::Tool && !i.done).map(|i| i.id.as_str()).filter(|_| active);
    let listened = items.iter().any(|i| i.kind == ItemKind::Codealong && told(&i.text));
    let rows = rows_of(&items, pending, in_card.as_deref(), listened);
    fold_turns(rows, active)
}

/// What Codealong tells a session it has asked to listen in on a meeting, as listening.ts
/// `toldIn` reads it: that it began; what was heard ("Heard, lines 3 to 5 of <file>:" and the
/// lines, or ", too much to put here: read it there."); that it ended ("Your user ended the
/// listening." or "The listening has ended: …", then "Finish up as you were asked to."). A
/// conversation with any is a listening one.
fn told(text: &str) -> bool {
    let t = text.trim();
    if t.starts_with("Your user asked you to listen in on a meeting through Codealong.") {
        return true;
    }
    let ends = (t.starts_with("Your user ended the listening. ") || t.starts_with("The listening has ended: ")) && t.ends_with(" Finish up as you were asked to.");
    ends || heard(t)
}

/// "Heard, line 3 of <file>:" then a new line, or "Heard, lines 3 to 5 of <file>, too much to put
/// here: read it there." (listening.ts `HEARD`).
fn heard(t: &str) -> bool {
    let Some(rest) = t.strip_prefix("Heard, lines ").or_else(|| t.strip_prefix("Heard, line ")) else { return false };
    let number = |s: &str| -> Option<usize> {
        let n = s.chars().take_while(char::is_ascii_digit).count();
        (n > 0).then_some(n)
    };
    let Some(n) = number(rest) else { return false };
    let mut rest = &rest[n..];
    if let Some(to) = rest.strip_prefix(" to ") {
        let Some(n) = number(to) else { return false };
        rest = &to[n..];
    }
    let Some(file) = rest.strip_prefix(" of ") else { return false };
    let first = file.split('\n').next().unwrap_or("");
    (first.len() > 1 && first.ends_with(':') && file.contains('\n')) || file.find(", too much to put here: read it there.").is_some_and(|at| at > 0)
}

/// An item, and where it is in the items given.
#[derive(Clone, Copy, Debug)]
struct At<'a> {
    n: u32,
    item: &'a Item,
}

impl std::ops::Deref for At<'_> {
    type Target = Item;
    fn deref(&self) -> &Item {
        self.item
    }
}

/// A row before turns fold.
#[derive(Clone, Debug)]
enum Base<'a> {
    Said(At<'a>),
    Tool(At<'a>),
    Tools { calls: Vec<At<'a>>, last_shown: bool },
    /// Where you answered the questions a call asked, which starts a turn there, as the Mac's
    /// answers row does where the call's result is: calls made beside the question before you
    /// answered are the turn before it. Drawn as nothing: the call shows the answers.
    Answered(i64),
}

/// The items as rows: runs of two or more calls one line each, calls you need to see on their own
/// (`stays_out`), and the rest as they are (turnFolds.ts `rowsOf`, folded). A run's last call shows
/// under it while it's `pending`; the one `in_card` shows nowhere, nor, in a conversation that
/// `listened`, a reply that says nothing (`undrawn`), which still ends a run as it did. Where you
/// answered a call's questions is a row of its own (`Base::Answered`), where the answer comes in
/// the conversation: before the first item that came at or after it, which ends a run too.
fn rows_of<'a>(items: &'a [Item], pending: Option<&str>, in_card: Option<&str>, listened: bool) -> Vec<Base<'a>> {
    let mut rows = Vec::new();
    let mut run: Vec<At> = Vec::new();
    let flush = |run: &mut Vec<At<'a>>, rows: &mut Vec<Base<'a>>| {
        let calls = std::mem::take(run);
        if calls.len() >= FOLD_AT {
            let last_shown = calls.last().is_some_and(|c| Some(c.id.as_str()) == pending);
            rows.push(Base::Tools { calls, last_shown });
        } else {
            rows.extend(calls.into_iter().map(Base::Tool));
        }
    };
    // Answers given to calls read so far and not yet placed: when, earliest first.
    let mut answers: Vec<i64> = Vec::new();
    for (n, item) in items.iter().enumerate() {
        let it = At { n: n as u32, item };
        if it.at > 0 {
            while answers.first().is_some_and(|&t| t <= it.at) {
                flush(&mut run, &mut rows);
                rows.push(Base::Answered(answers.remove(0)));
            }
        }
        if listened && undrawn(&it) {
            flush(&mut run, &mut rows);
            continue;
        }
        if it.kind == ItemKind::Tool && it.questions.iter().any(|q| q.answered) {
            flush(&mut run, &mut rows);
            rows.push(Base::Tool(it));
            // Where its Mac didn't say when, right after the call.
            if it.result_at > 0 {
                answers.push(it.result_at);
                answers.sort_unstable();
            } else {
                rows.push(Base::Answered(it.at));
            }
            continue;
        }
        if it.kind != ItemKind::Tool {
            flush(&mut run, &mut rows);
            rows.push(Base::Said(it));
        } else if stays_out(&it) {
            flush(&mut run, &mut rows);
            rows.push(Base::Tool(it));
        } else {
            run.push(it);
        }
    }
    flush(&mut run, &mut rows);
    rows.extend(answers.into_iter().map(Base::Answered));
    // The call the card shows stands in its place at the end, as the last of a run or on its own:
    // a run keeps its line for the calls before it.
    let in_card = |c: &At| Some(c.id.as_str()) == in_card;
    rows.into_iter()
        .filter_map(|r| match r {
            Base::Tool(c) if in_card(&c) => None,
            Base::Tools { mut calls, .. } if calls.last().is_some_and(in_card) => {
                calls.pop();
                Some(Base::Tools { calls, last_shown: false })
            }
            r => Some(r),
        })
        .collect()
}

/// A call that stays on its own line, out of runs and folds: one that made a page, handed you
/// files or asked you questions (`isPinnedCall`), or failed, so what went wrong is never hidden.
fn stays_out(c: &Item) -> bool {
    c.link.is_some() || !c.files.is_empty() || !c.questions.is_empty() || c.failed
}

/// A reply that says there's nothing to say, a dash, as a session hearing a meeting answers most
/// of the time: the Mac draws none in a conversation that listened (SessionThread.tsx `undrawn`),
/// and neither does this.
fn undrawn(i: &Item) -> bool {
    i.kind == ItemKind::Agent && crate::says_nothing(&i.text)
}

/// What starts a turn: a prompt of yours, Codealong's or another session's message, a note, or
/// your answers to questions it asked (turnFolds.ts `isBoundary`), and when it did.
fn starts_turn(r: &Base) -> Option<i64> {
    match r {
        Base::Said(i) if matches!(i.kind, ItemKind::You | ItemKind::Codealong | ItemKind::Peer | ItemKind::Note) => Some(i.at),
        Base::Answered(at) => Some(*at),
        _ => None,
    }
}

fn calls_in<'a>(rows: &[Base<'a>]) -> Vec<At<'a>> {
    rows.iter()
        .flat_map(|r| match r {
            Base::Tool(c) => vec![*c],
            Base::Tools { calls, .. } => calls.clone(),
            Base::Said(_) | Base::Answered(_) => vec![],
        })
        .collect()
}

/// Each finished turn's work before the reply that ended it folded into a line (`foldTurns`,
/// folded): a turn still going (the last, while `active`), one with a call that failed, and one
/// with nothing before its reply stay as they are; a call that stays out of runs stays out of the
/// fold too, the work either side of it folding apart.
fn fold_turns(rows: Vec<Base>, active: bool) -> Vec<ThreadRow> {
    let mut out = Vec::new();
    let mut seg: Vec<Base> = Vec::new();
    let mut start_at = 0;
    for r in rows {
        match starts_turn(&r) {
            Some(at) => {
                emit(std::mem::take(&mut seg), start_at, false, &mut out);
                start_at = at;
                out.extend(row(r, None));
            }
            None => seg.push(r),
        }
    }
    emit(seg, start_at, active, &mut out);
    out
}

/// A turn's rows into `out`, its work folded where it's finished (`going` false).
fn emit(seg: Vec<Base>, start_at: i64, going: bool, out: &mut Vec<ThreadRow>) {
    let failed = seg.iter().any(|r| match r {
        Base::Tool(c) => c.failed,
        Base::Tools { calls, .. } => calls.iter().any(|c| c.failed),
        Base::Said(_) | Base::Answered(_) => false,
    });
    let reply = seg.iter().rposition(|r| matches!(r, Base::Said(i) if i.kind == ItemKind::Agent));
    let reply = match reply {
        Some(at) if at > 0 && !going && !failed => at,
        _ => {
            out.extend(seg.into_iter().flat_map(|r| row(r, None)));
            return;
        }
    };
    let reply_at = match &seg[reply] {
        Base::Said(i) => i.at,
        _ => 0,
    };
    let mut rest = seg;
    let after = rest.split_off(reply + 1);
    let ended = rest.pop().expect("the reply");
    let mut chunk: Vec<Base> = Vec::new();
    // Only the first fold of a turn goes from the turn's start.
    let mut from = start_at;
    for r in rest {
        if matches!(&r, Base::Tool(c) if stays_out(c)) {
            if fold(std::mem::take(&mut chunk), from, 0, out) {
                from = 0;
            }
            out.extend(row(r, None));
        } else {
            chunk.push(r);
        }
    }
    fold(chunk, from, reply_at, out);
    out.extend(row(ended, None));
    out.extend(after.into_iter().flat_map(|r| row(r, None)));
}

/// Work done between `from` and `to` (where they're known, else its own first and last times, a
/// call's result's included) as a turn's line, then its rows inside it (`makeTurnFold`); whether
/// it made one. Its id goes by its last item, which an older page read in above doesn't change.
fn fold(chunk: Vec<Base>, from: i64, to: i64, out: &mut Vec<ThreadRow>) -> bool {
    if chunk.is_empty() {
        return false;
    }
    let Some(last) = chunk.last().and_then(|r| ids(r).last().copied()) else { return false };
    let id = format!("turn:{}", last.id);
    let times: Vec<i64> = chunk.iter().flat_map(ids).flat_map(|i| [i.at, i.result_at]).filter(|&t| t > 0).collect();
    let from = if from > 0 { from } else { times.iter().copied().min().unwrap_or(0) };
    let to = if to > 0 { to } else { times.iter().copied().max().unwrap_or(0) };
    let took = (from > 0 && to > from).then(|| worked(to - from)).flatten();
    let calls = calls_in(&chunk);
    let summary = if calls.is_empty() {
        let updates = chunk.iter().filter(|r| matches!(r, Base::Said(i) if i.kind == ItemKind::Agent)).count();
        if updates == 1 { "1 earlier update".to_string() } else { format!("{updates} earlier updates") }
    } else {
        summarize(&calls)
    };
    let head = took.map_or_else(|| "Worked".to_string(), |t| format!("Worked for {t}"));
    out.push(ThreadRow { id: id.clone(), kind: RowKind::Turn, items: vec![], label: format!("{head} · {summary}"), icon: RunIcon::Other, last_shown: false, turn: None });
    out.extend(chunk.into_iter().flat_map(|r| row(r, Some(id.clone()))));
    true
}

/// The items a row shows.
fn ids<'a>(r: &Base<'a>) -> Vec<At<'a>> {
    match r {
        Base::Said(i) | Base::Tool(i) => vec![*i],
        Base::Tools { calls, .. } => calls.clone(),
        Base::Answered(_) => vec![],
    }
}

fn row_id(r: &Base) -> String {
    match r {
        Base::Said(i) | Base::Tool(i) => i.id.clone(),
        Base::Tools { calls, .. } => format!("run:{}", calls.first().map_or("", |c| c.id.as_str())),
        Base::Answered(at) => format!("answered:{at}"),
    }
}

/// The row `r` draws as, inside the turn `turn`; none for where you answered.
fn row(r: Base, turn: Option<String>) -> Option<ThreadRow> {
    let id = row_id(&r);
    Some(match r {
        Base::Said(i) => ThreadRow { id, kind: RowKind::Said, items: vec![i.n], label: String::new(), icon: RunIcon::Other, last_shown: false, turn },
        Base::Tool(c) => ThreadRow { id, kind: RowKind::Tool, items: vec![c.n], label: String::new(), icon: RunIcon::Other, last_shown: false, turn },
        Base::Tools { calls, last_shown } => {
            let said = &calls[..if last_shown { calls.len() - 1 } else { calls.len() }];
            ThreadRow { id, kind: RowKind::Tools, label: summarize(said), icon: icon_of(said), items: calls.iter().map(|c| c.n).collect(), last_shown, turn }
        }
        Base::Answered(_) => return None,
    })
}

/// What a call does, by the tool that leads its label ("Bash · `ls`"), as turnFolds.ts
/// `classifyTool` reads it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
enum Action {
    Edit,
    Command,
    Agent,
    Skill,
    Search,
    Read,
    Other,
}

fn action_of(label: &str) -> Action {
    let name = label.split(" · ").next().unwrap_or("").trim().to_lowercase();
    let has = |words: &[&str]| words.iter().any(|w| name.contains(w));
    // "run" as a word of its own at the start: Run, run_shell_command, not "runner".
    let runs = name.strip_prefix("run").is_some_and(|rest| !rest.starts_with(|c: char| c.is_alphanumeric() || c == '_'));
    if has(&["edit", "write", "patch", "notebook", "replace", "create_file"]) {
        Action::Edit
    } else if has(&["bash", "shell", "exec", "command", "terminal"]) || runs {
        Action::Command
    } else if has(&["agent", "task", "subagent"]) {
        Action::Agent
    } else if has(&["skill"]) {
        Action::Skill
    } else if has(&["grep", "glob", "search", "find"]) {
        Action::Search
    } else if has(&["read", "view"]) {
        Action::Read
    } else {
        Action::Other
    }
}

fn icon_of<C: std::ops::Deref<Target = Item>>(calls: &[C]) -> RunIcon {
    match calls.iter().map(|c| action_of(&c.text)).min().unwrap_or(Action::Other) {
        Action::Edit => RunIcon::Edit,
        Action::Command => RunIcon::Command,
        Action::Agent => RunIcon::Agent,
        Action::Search => RunIcon::Search,
        Action::Read => RunIcon::Read,
        Action::Skill | Action::Other => RunIcon::Other,
    }
}

/// What a kind of call did, `count` times (`actionPhrase`).
fn phrase(a: Action, count: usize) -> String {
    let (one, many): (&str, &str) = match a {
        Action::Edit => ("Edited 1 file", "Edited {} files"),
        Action::Command => ("Ran 1 command", "Ran {} commands"),
        Action::Agent => ("Ran a subagent", "Ran {} subagents"),
        Action::Skill => ("Used a skill", "Used {} skills"),
        Action::Search => ("Searched once", "Searched {} times"),
        Action::Read => ("Read 1 file", "Read {} files"),
        Action::Other => ("1 tool call", "{} tool calls"),
    };
    if count == 1 { one.to_string() } else { many.replace("{}", &count.to_string()) }
}

/// The file a call reads or changes, as far as what its Mac wrote of it says: the Mac goes by
/// each call's file (`TranscriptItem::file`, a full path), which the feed doesn't carry, so here
/// the path its input gives, as the arguments' path where its input is them as JSON (OpenCode's
/// `filePath`), or as the line it starts with (Claude Code's Read, Write and Edit: a full one, or
/// one ending in the name its label gives), with any `./` off its folders; else that name.
fn file_of(c: &Item) -> String {
    let input = c.input.as_deref().unwrap_or("").trim();
    let name = c.text.split_once(" · ").map(|(_, named)| named.trim().trim_matches('`')).filter(|n| !n.is_empty());
    let argued = serde_json::from_str::<serde_json::Value>(input).ok().and_then(|v| {
        ["filePath", "file_path", "path", "notebook_path", "TargetFile", "AbsolutePath"].iter().find_map(|k| v.get(k).and_then(|p| p.as_str()).map(str::to_string))
    });
    let first = input.lines().next().unwrap_or("").trim();
    let path = argued.or_else(|| (first.starts_with('/') || first.starts_with("~/") || name.is_some_and(|n| first.ends_with(n))).then(|| first.to_string()));
    match path {
        Some(p) => p.split('/').filter(|part| *part != ".").collect::<Vec<_>>().join("/"),
        None => name.unwrap_or(c.text.as_str()).to_string(),
    }
}

/// What calls did, in words (`summarizeTools`): the two kinds of most weight among them, in the
/// order they first came, then how many others, and how many failed. Edits and reads count files,
/// not calls (`file_of`).
fn summarize<C: std::ops::Deref<Target = Item>>(calls: &[C]) -> String {
    if calls.is_empty() {
        return String::new();
    }
    // Each kind, with when it first came and its calls.
    let mut kinds: Vec<(Action, Vec<&Item>)> = Vec::new();
    let calls: Vec<&Item> = calls.iter().map(|c| &**c).collect();
    for &c in &calls {
        let a = action_of(&c.text);
        match kinds.iter_mut().find(|(k, _)| *k == a) {
            Some((_, of)) => of.push(c),
            None => kinds.push((a, vec![c])),
        }
    }
    let mut picked: Vec<(usize, Action, &Vec<&Item>)> = kinds.iter().enumerate().map(|(at, (a, of))| (at, *a, of)).collect();
    picked.sort_by_key(|(at, a, _)| (*a, *at));
    picked.truncate(2);
    picked.sort_by_key(|(at, _, _)| *at);
    let mut labels: Vec<String> = picked
        .iter()
        .map(|(_, a, of)| {
            let count = match a {
                Action::Edit | Action::Read => of.iter().map(|c| file_of(c)).collect::<std::collections::HashSet<_>>().len(),
                _ => of.len(),
            };
            phrase(*a, count)
        })
        .collect();
    let covered: usize = picked.iter().map(|(_, _, of)| of.len()).sum();
    let rest = calls.len() - covered;
    if rest > 0 {
        labels.push(if rest == 1 { "1 other action".to_string() } else { format!("{rest} other actions") });
    }
    let failed = calls.iter().filter(|c| c.failed).count();
    let said = joined(&labels);
    if failed > 0 { format!("{said} · {failed} failed") } else { said }
}

/// Clauses as one sentence, each after the first lower-cased at its start: "a and b", "a, b and c".
fn joined(clauses: &[String]) -> String {
    let lowered: Vec<String> = clauses
        .iter()
        .enumerate()
        .map(|(i, c)| {
            if i == 0 {
                return c.clone();
            }
            let mut ch = c.chars();
            ch.next().map(|f| f.to_lowercase().collect::<String>() + ch.as_str()).unwrap_or_default()
        })
        .collect();
    match lowered.as_slice() {
        [] => String::new(),
        [one] => one.clone(),
        [a, b] => format!("{a} and {b}"),
        [init @ .., last] => format!("{} and {last}", init.join(", ")),
    }
}

/// How long a turn worked, short (`formatWorked`): "12s", "2m", "1h 5m"; none under a second.
fn worked(ms: i64) -> Option<String> {
    if ms < 1000 {
        return None;
    }
    let secs = (ms as f64 / 1000.0).round() as i64;
    if secs < 60 {
        return Some(format!("{secs}s"));
    }
    let mins = secs / 60;
    if mins < 60 {
        return Some(format!("{mins}m"));
    }
    let (hours, rem) = (mins / 60, mins % 60);
    Some(if rem > 0 { format!("{hours}h {rem}m") } else { format!("{hours}h") })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Question, WebLink};

    fn item(kind: ItemKind, id: &str, at: i64, text: &str) -> Item {
        Item { id: id.into(), call: None, at, kind, text: text.into(), from: None, input: None, output: None, failed: false, withdrawn: false, questions: vec![], link: None, files: vec![], caption: None, editable: false, card: None, done: true, result_at: 0 }
    }
    fn you(id: &str, at: i64) -> Item {
        item(ItemKind::You, id, at, "Do it")
    }
    fn agent(id: &str, at: i64, text: &str) -> Item {
        item(ItemKind::Agent, id, at, text)
    }
    fn call(id: &str, at: i64, label: &str) -> Item {
        item(ItemKind::Tool, id, at, label)
    }
    /// Each row as its kind, id, label and turn, to compare at a glance.
    fn laid(rows: &[ThreadRow]) -> Vec<String> {
        rows.iter()
            .map(|r| {
                let turn = r.turn.as_deref().map(|t| format!(" in {t}")).unwrap_or_default();
                let label = if r.label.is_empty() { String::new() } else { format!(" “{}”", r.label) };
                let last = if r.last_shown { " +last" } else { "" };
                format!("{:?} {}{label}{last}{turn}", r.kind, r.id)
            })
            .collect()
    }

    #[test]
    fn calls_say_what_they_did_in_words() {
        let c = |label: &str| call("x", 0, label);
        let said = |calls: &[Item]| summarize(&calls.iter().collect::<Vec<_>>());
        assert_eq!(said(&[c("Bash · `ls`"), c("Bash · `pwd`"), c("Bash · `cargo test`")]), "Ran 3 commands");
        // The two of most weight, in the order they came, then the rest.
        assert_eq!(said(&[c("Read · `a.rs`"), c("Edit · `a.rs`"), c("Bash · `ls`"), c("Grep · `x`"), c("Grep · `y`")]), "Edited 1 file, ran 1 command and 3 other actions");
        // Edits count files: the same file twice is one.
        assert_eq!(said(&[c("Edit · `a.rs`"), c("Edit · `a.rs`"), c("Edit · `b.rs`")]), "Edited 2 files");
        assert_eq!(said(&[c("Grep · `x`"), c("Glob · `*.rs`")]), "Searched 2 times");
        assert_eq!(said(&[c("Task · review"), c("Skill · pdf")]), "Ran a subagent and used a skill");
        assert_eq!(said(&[c("WebFetch · x"), c("mcp__x · y")]), "2 tool calls");
        assert_eq!(said(&[c("run_shell_command · ls"), c("Runner · x")]), "Ran 1 command and 1 tool call");
        let failed = Item { failed: true, ..c("Bash · `false`") };
        assert_eq!(said(&[c("Bash · `ls`"), failed]), "Ran 2 commands · 1 failed");
        assert_eq!(icon_of(&[&c("Read · a"), &c("Bash · ls")]), RunIcon::Command);
        assert_eq!(icon_of(&[&c("Skill · pdf")]), RunIcon::Other);
        assert_eq!((worked(999), worked(12_400), worked(125_000), worked(3_900_000), worked(7_200_000)), (None, Some("12s".into()), Some("2m".into()), Some("1h 5m".into()), Some("2h".into())));
    }

    #[test]
    fn a_finished_turns_work_folds_above_its_reply() {
        let items = vec![you("p", 1_000), agent("a1", 2_000, "Looking."), call("c1", 3_000, "Read · `a.rs`"), call("c2", 4_000, "Edit · `a.rs`"), call("c3", 5_000, "Bash · `cargo test`"), agent("a2", 121_000, "Done.")];
        let rows = thread_rows(items.clone(), Status::Unread, None);
        assert_eq!(
            laid(&rows),
            [
                "Said p",
                "Turn turn:c3 “Worked for 2m · Edited 1 file, ran 1 command and 1 other action”",
                "Said a1 in turn:c3",
                "Tools run:c1 “Edited 1 file, ran 1 command and 1 other action” in turn:c3",
                "Said a2",
            ]
        );
        // Still going, it isn't folded; a call it's running shows under its run.
        let going = [&items[..5], &[Item { done: false, ..call("c4", 6_000, "Bash · `ls`") }]].concat();
        assert_eq!(laid(&thread_rows(going.clone(), Status::Working, None)), ["Said p", "Said a1", "Tools run:c1 “Edited 1 file, ran 1 command and 1 other action” +last"]);
        // One waiting on you shows in the card, not here.
        assert_eq!(laid(&thread_rows(going, Status::Needs, Some("c4".into()))), ["Said p", "Said a1", "Tools run:c1 “Edited 1 file, ran 1 command and 1 other action”"]);
        // Done while it was working, a run is one line.
        assert_eq!(laid(&thread_rows(items[..5].to_vec(), Status::Working, None)), ["Said p", "Said a1", "Tools run:c1 “Edited 1 file, ran 1 command and 1 other action”"]);
    }

    /// In a conversation that listened to a meeting, a reply of a dash alone is drawn nowhere and
    /// ends no turn, as on the Mac; elsewhere a reply is a reply.
    #[test]
    fn a_listening_sessions_dash_says_nothing() {
        let heard = item(ItemKind::Codealong, "h", 1_000, "Heard, lines 3 to 5 of /m/notes.md:\n> Ana: Ship it.");
        let items = vec![heard.clone(), call("c1", 2_000, "Bash · `ls`"), agent("a1", 3_000, "Something worth saying."), agent("a2", 4_000, "—")];
        assert_eq!(laid(&thread_rows(items.clone(), Status::Idle, None)), ["Said h", "Turn turn:c1 “Worked for 2s · Ran 1 command”", "Tool c1 in turn:c1", "Said a1"]);
        let elsewhere = items[1..].to_vec();
        assert_eq!(laid(&thread_rows(elsewhere, Status::Idle, None)), ["Turn turn:a1 “Worked for 2s · Ran 1 command”", "Tool c1 in turn:a1", "Said a1 in turn:a1", "Said a2"]);
        assert!(told("Your user asked you to listen in on a meeting through Codealong. …") && told("The listening has ended: the call ended. Finish up as you were asked to.") && !told("On your PR #4"));
        assert!(told("Heard, line 3 of /m/notes.md, too much to put here: read it there."));
        assert!(!told("Heard, line 12 needs a correction.") && !told("Heard, lines 3 of x") && !told("The listening has ended: soon."));
        // A dash between calls still keeps them apart, as the Mac's rows do.
        let apart = vec![heard, call("A", 2_000, "Bash · `ls`"), agent("d", 2_500, "-"), call("B", 3_000, "Bash · `pwd`"), agent("r", 4_000, "Done.")];
        assert_eq!(laid(&thread_rows(apart, Status::Idle, None)), ["Said h", "Turn turn:B “Worked for 3s · Ran 2 commands”", "Tool A in turn:B", "Tool B in turn:B", "Said r"]);
    }

    /// A fold keeps its id as older pages are read in above it, so one you opened stays open.
    #[test]
    fn a_folds_id_holds_as_older_pages_come_in() {
        let newest = vec![call("c2", 3_000, "Bash · `pwd`"), agent("a2", 4_000, "Done.")];
        let all = [vec![you("p", 1_000), call("c1", 2_000, "Bash · `ls`")], newest.clone()].concat();
        let turn = |items: Vec<Item>| thread_rows(items, Status::Idle, None).into_iter().find(|r| r.kind == RowKind::Turn).map(|r| r.id);
        assert_eq!(turn(newest), Some("turn:c2".to_string()));
        assert_eq!(turn(all), Some("turn:c2".to_string()));
    }

    /// Rows say where their items are, not the items: a run's calls in order, the turn none.
    #[test]
    fn rows_point_at_their_items() {
        let items = vec![you("p", 1_000), call("c1", 2_000, "Bash · `ls`"), call("c2", 3_000, "Bash · `pwd`"), agent("a", 4_000, "Done.")];
        let rows = thread_rows(items, Status::Idle, None);
        assert_eq!(rows.iter().map(|r| r.items.clone()).collect::<Vec<_>>(), [vec![0], vec![], vec![1, 2], vec![3]]);
    }

    /// Edits count files by the path a call's input starts with, else the name its label gives.
    #[test]
    fn edits_count_files_by_their_paths() {
        let edit = |label: &str, input: &str| Item { input: Some(input.into()), ..call("x", 0, label) };
        let said = |calls: &[Item]| summarize(&calls.iter().collect::<Vec<_>>());
        assert_eq!(said(&[edit("Edit · `index.ts`", "/app/client/index.ts\n- a\n+ b"), edit("Edit · `index.ts`", "/app/server/index.ts\n- a\n+ b")]), "Edited 2 files");
        assert_eq!(said(&[edit("Edit · `index.ts`", "client/index.ts\n- a\n+ b"), edit("Edit · `index.ts`", "server/index.ts\n- a\n+ b")]), "Edited 2 files");
        assert_eq!(said(&[edit("Write · `index.ts`", "src/index.ts"), edit("Edit · `index.ts`", "./src/index.ts\n- a\n+ b")]), "Edited 1 file");
        let json = |path: &str| edit("edit · `index.ts`", &format!("{{\n  \"filePath\": \"{path}\",\n  \"oldString\": \"a\"\n}}"));
        assert_eq!(said(&[json("client/index.ts"), json("server/index.ts")]), "Edited 2 files");
        assert_eq!(said(&[edit("Write · `a.rs`", "/app/a.rs"), edit("Edit · `a.rs`", "/app/a.rs\n- x\n+ y")]), "Edited 1 file");
        assert_eq!(said(&[edit("apply_patch · `a.rs`", "*** Begin Patch"), edit("Edit · `a.rs`", "{}")]), "Edited 1 file");
    }

    #[test]
    fn what_you_need_to_see_stays_out_of_folds() {
        // A turn with a call that failed stays open, the failed call on its own line.
        let failed = vec![you("p", 1_000), call("c1", 2_000, "Bash · `ls`"), Item { failed: true, ..call("c2", 3_000, "Bash · `false`") }, call("c3", 4_000, "Bash · `pwd`"), agent("a", 5_000, "It failed.")];
        assert_eq!(laid(&thread_rows(failed, Status::Idle, None)), ["Said p", "Tool c1", "Tool c2", "Tool c3", "Said a"]);
        // A page it made stays in view, the work either side folding apart, only the first from
        // the turn's start.
        let page = Item { link: Some(WebLink { url: "https://claude.ai/x".into(), title: "Plan".into(), note: None }), ..call("c3", 4_000, "Artifact · plan") };
        let made = vec![you("p", 1_000), call("c1", 2_000, "Bash · `ls`"), call("c2", 3_000, "Bash · `pwd`"), page, agent("a1", 5_000, "Writing."), agent("a2", 70_000, "Here.")];
        assert_eq!(
            laid(&thread_rows(made, Status::Idle, None)),
            ["Said p", "Turn turn:c2 “Worked for 2s · Ran 2 commands”", "Tools run:c1 “Ran 2 commands” in turn:c2", "Tool c3", "Turn turn:a1 “Worked for 1m · 1 earlier update”", "Said a1 in turn:a1", "Said a2"]
        );
        // Questions you answered start a turn of their own.
        let asked = Question { question: "Which?".into(), header: None, options: vec![], multi_select: false, answered: true, picked: vec!["A".into()], own: vec![], only_choices: false, required: false, hint: None, secret: false };
        let answered = vec![you("p", 1_000), agent("a1", 2_000, "Asking."), Item { questions: vec![asked.clone()], ..call("q", 3_000, "AskUserQuestion") }, call("c1", 4_000, "Bash · `ls`"), agent("a2", 9_000, "Done.")];
        assert_eq!(laid(&thread_rows(answered, Status::Idle, None)), ["Said p", "Said a1", "Tool q", "Turn turn:c1 “Worked for 6s · Ran 1 command”", "Tool c1 in turn:c1", "Said a2"]);
        // A reply with nothing before it, and a turn with no reply, stay as they are.
        assert_eq!(laid(&thread_rows(vec![you("p", 1), agent("a", 2, "Hi.")], Status::Idle, None)), ["Said p", "Said a"]);
        assert_eq!(laid(&thread_rows(vec![you("p", 1), call("c1", 2, "Bash · ls"), call("c2", 3, "Bash · ls")], Status::Idle, None)), ["Said p", "Tools run:c1 “Ran 2 commands”"]);
        // A call made beside the question before you answered is the turn before the answer, as
        // the Mac's answers row is where the call's result is.
        let beside = vec![you("p", 1_000), agent("a1", 2_000, "Asking."), Item { questions: vec![asked.clone()], result_at: 5_000, ..call("q", 3_000, "AskUserQuestion") }, call("c1", 3_500, "Bash · `ls`"), agent("a2", 9_000, "Done.")];
        assert_eq!(laid(&thread_rows(beside, Status::Idle, None)), ["Said p", "Said a1", "Tool q", "Tool c1", "Said a2"]);
        // A run doesn't cross the answer: the call before it is the turn before, the one after the
        // turn after.
        let across = vec![you("p", 1_000), agent("a1", 2_000, "Asking."), Item { questions: vec![asked.clone()], result_at: 5_000, ..call("q", 3_000, "AskUserQuestion") }, call("A", 4_000, "Bash · `ls`"), call("B", 6_000, "Bash · `pwd`"), agent("a2", 9_000, "Done.")];
        assert_eq!(laid(&thread_rows(across, Status::Idle, None)), ["Said p", "Said a1", "Tool q", "Tool A", "Turn turn:B “Worked for 4s · Ran 1 command”", "Tool B in turn:B", "Said a2"]);
        // Answered an hour on, the turn after goes from the answer, which is on the call's result.
        let later = vec![you("p", 1_000), Item { questions: vec![asked], result_at: 3_602_000, ..call("q", 2_000, "AskUserQuestion") }, call("c1", 3_603_000, "Bash · `ls`"), agent("a", 3_607_000, "Done.")];
        assert_eq!(laid(&thread_rows(later, Status::Idle, None))[2], "Turn turn:c1 “Worked for 5s · Ran 1 command”");
        // Undated, a turn just worked.
        assert_eq!(laid(&thread_rows(vec![you("p", 0), call("c1", 0, "Bash · ls"), agent("a", 0, "Done.")], Status::Idle, None)), ["Said p", "Turn turn:c1 “Worked · Ran 1 command”", "Tool c1 in turn:c1", "Said a"]);
    }
}
