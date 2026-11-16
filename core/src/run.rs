//! Running a command for a session on its Mac, as the Mac's Run beside a shell block and `!` in a
//! session's box do (the main repo's RunButton.tsx and Markdown.tsx, actions.rs `run_command`):
//! which code blocks in a reply run, and which of what's typed in the box is a command. What runs
//! goes to a terminal there, as you, and the session is told what it printed once it ends.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// How a code block runs, as the Mac's Markdown.tsx reads its fence (`shell`, `session`, `bare`).
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodeRun {
    /// It doesn't: it's in another language, or still being written.
    No,
    /// Shell commands (a fence of `bash`, `sh`…), which run without their comments.
    Block,
    /// A command led by `!` for the session's own shell, as Claude Code's agents write one, which
    /// runs as `!` in the session's box does, as typed.
    Typed,
    /// A block with no language, which runs when each of its lines starts with a command its Mac
    /// has (`is_command_block`): otherwise it's output, a path or a config file.
    IfCommands,
}

/// A fence's languages for shell commands (Markdown.tsx `SHELLS`). A console session isn't one:
/// it holds prompts and output.
const SHELLS: [&str; 6] = ["bash", "sh", "zsh", "fish", "ksh", "shell"];

/// How a fenced block runs: `lang` its fence's first word, `closed` whether its closing fence has
/// come (a reply as it streams has none yet).
pub(crate) fn code_run(lang: &str, text: &str, closed: bool) -> CodeRun {
    let shell = SHELLS.contains(&lang);
    if !closed {
        CodeRun::No
    } else if (lang.is_empty() || shell) && text.trim_start().starts_with('!') {
        CodeRun::Typed
    } else if shell {
        CodeRun::Block
    } else if lang.is_empty() {
        CodeRun::IfCommands
    } else {
        CodeRun::No
    }
}

/// A fence's language, as the first word after its backticks says, in lower case: "" for none.
pub(crate) fn fence_lang(line: &str) -> String {
    line.trim().get(3..).unwrap_or_default().split_whitespace().next().unwrap_or_default().to_lowercase()
}

/// Whether what's in a session's box is a command led by `!`, which runs on its Mac for the
/// session to be told what it printed (RunButton.tsx `bangCommand`), rather than a message. Not
/// text that opens with an image, whose `!` is the image's (`![shot](images/…)`).
#[uniffi::export]
pub fn bang_command(text: String) -> bool {
    let t = text.trim_start();
    t.starts_with('!') && !t.starts_with("![") && !t[1..].trim().is_empty()
}

/// Whether a block that doesn't say it's shell is commands all the same (RunButton.tsx
/// `isCommandBlock`): each of its lines, past comments and blank ones and those a line before
/// carries on into, starts with a command in `known` (its Mac's `shell-commands`) or a script
/// given arguments. Output, a path or a config file doesn't, nor a command shown with what it
/// printed.
pub(crate) fn is_command_block(text: &str, known: &HashSet<String>) -> bool {
    let mut commands = 0;
    let mut carried = false;
    for line in text.split('\n') {
        let t = line.trim();
        if carried {
            carried = carries_on(t);
            continue;
        }
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        let mut rest = t;
        while let Some(after) = past_assignment(rest) {
            rest = after;
        }
        let named = command_name(rest).is_some_and(|n| known.contains(n));
        if !named && !is_script(rest) && !is_folder_script(rest) {
            return false;
        }
        commands += 1;
        carried = carries_on(t);
    }
    commands > 0
}

/// `\w` as the Mac's patterns have it: ASCII letters, digits and `_`.
fn word(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// A line the next one carries on: an escaped newline, or a pipe or `&&` left open.
fn carries_on(t: &str) -> bool {
    t.ends_with('\\') || t.ends_with('|') || t.ends_with("&&")
}

/// What's after a word that sets a variable for the command after it (`NODE_ENV=test npm test`),
/// when `s` starts with one.
fn past_assignment(s: &str) -> Option<&str> {
    let name = s.find(|c: char| !word(c)).unwrap_or(s.len());
    if name == 0 || s.starts_with(|c: char| c.is_ascii_digit()) || !s[name..].starts_with('=') {
        return None;
    }
    let value = &s[name + 1..];
    let end = value.find(char::is_whitespace)?;
    Some(value[end..].trim_start())
}

/// A command's name, ended by a space, the line's end or what joins it to the next command.
fn command_name(s: &str) -> Option<&str> {
    if !s.starts_with(word) {
        return None;
    }
    let end = s.find(|c: char| !(word(c) || matches!(c, '.' | '+' | '-'))).unwrap_or(s.len());
    let next = s[end..].chars().next();
    (next.is_none() || next.is_some_and(|c| c.is_whitespace() || matches!(c, ';' | '&' | '|' | '<' | '>'))).then_some(&s[..end])
}

/// A character of a path a script is named by.
fn path_char(c: char) -> bool {
    word(c) || matches!(c, '.' | '+' | '@' | '/' | '-')
}

/// The path `s` starts with, and whether what follows gives it something to run with: words
/// after it, or what joins it to the next command.
fn path_and_args(s: &str) -> (&str, bool) {
    let end = s.find(|c: char| !path_char(c)).unwrap_or(s.len());
    let rest = &s[end..];
    let after = rest.trim_start();
    let given = !after.is_empty() && (after.len() < rest.len() || after.starts_with([';', '&', '|', '<', '>']));
    (&s[..end], given)
}

/// A script named by its path from the folder it runs in, with what it's given after it
/// (`../scripts/deploy.mjs plan --note "…"`). Alone, a path is as often a file named as a script
/// run, and one led by `/` or `~` as often output that names a file, so neither counts.
fn is_script(s: &str) -> bool {
    let Some(path) = s.strip_prefix("./").or_else(|| s.strip_prefix("../")) else { return false };
    let (path, given) = path_and_args(path);
    given && path.ends_with(|c: char| word(c) || matches!(c, '.' | '+' | '-'))
}

/// The languages a script's `#!` line runs, by the file's extension.
const SCRIPTS: [&str; 9] = ["sh", "bash", "zsh", "mjs", "cjs", "js", "py", "rb", "pl"];

/// A script named from a folder in the one it runs in without `./` (`scripts/rotate.sh check`),
/// given something to run with: only a script's name counts (a language a `#!` line runs, or a
/// program in a `bin` folder), since a path led by a folder is as often a file or a package
/// named in what something printed, with words after it.
fn is_folder_script(s: &str) -> bool {
    let (path, given) = path_and_args(s);
    let parts: Vec<&str> = path.split('/').collect();
    let Some((name, folders)) = parts.split_last() else { return false };
    let folder = |p: &&str| !p.is_empty() && p.chars().all(|c| word(c) || matches!(c, '.' | '-'));
    let named = !name.is_empty() && name.chars().all(|c| word(c) || matches!(c, '.' | '+' | '@' | '-'));
    if !given || !named || folders.is_empty() || !folders.iter().all(folder) {
        return false;
    }
    let script = name.rsplit_once('.').is_some_and(|(stem, ext)| !stem.is_empty() && SCRIPTS.contains(&ext));
    let in_bin = folders.last().is_some_and(|f| *f == "bin" || *f == ".bin");
    script || in_bin
}

/// How long a Mac's commands are taken as they were, as the Mac's own windows take them: a
/// program the agent had you install shows up for the blocks after it.
const COMMANDS_FOR: Duration = Duration::from_secs(60);

/// The commands each Mac's shell takes, by the Mac as a conversation names it, and when they were
/// last asked for, answered or not. Shared by every conversation, so going from one session to
/// the next on a Mac doesn't ask again.
pub(crate) type Commands = Arc<Mutex<HashMap<String, (Instant, Arc<HashSet<String>>)>>>;

/// The commands `device` was last said to have, if it's said, and whether that's older than
/// `COMMANDS_FOR`.
pub(crate) fn known(commands: &Commands, device: &str) -> Option<(Arc<HashSet<String>>, bool)> {
    let all = commands.lock().unwrap_or_else(|e| e.into_inner());
    all.get(device).map(|(at, names)| (names.clone(), at.elapsed() > COMMANDS_FOR))
}

/// Notes that `device` was asked just now, with what it answered: none when it didn't, from an
/// older build that doesn't know the request or a Mac that didn't answer in time. It isn't asked
/// again for `COMMANDS_FOR` either way, and what it said before stands meanwhile. Says how many
/// commands it's known to have now.
pub(crate) fn keep(commands: &Commands, device: &str, names: Option<Vec<String>>) -> usize {
    let mut all = commands.lock().unwrap_or_else(|e| e.into_inner());
    let names = match names {
        Some(names) => Arc::new(names.into_iter().collect()),
        None => all.get(device).map(|(_, before)| before.clone()).unwrap_or_default(),
    };
    let known = names.len();
    all.insert(device.to_string(), (Instant::now(), names));
    known
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fence_says_how_its_block_runs() {
        assert_eq!(code_run("bash", "npm test", true), CodeRun::Block);
        assert_eq!(code_run("sh", "! npm test", true), CodeRun::Typed);
        assert_eq!(code_run("", "!git status", true), CodeRun::Typed);
        assert_eq!(code_run("", "git status", true), CodeRun::IfCommands);
        // Another language, a console session, and a block still being written don't run.
        assert_eq!(code_run("rust", "fn main() {}", true), CodeRun::No);
        assert_eq!(code_run("console", "$ ls", true), CodeRun::No);
        assert_eq!(code_run("bash", "npm test", false), CodeRun::No);
        assert_eq!(fence_lang("```Bash title=\"x\""), "bash");
        assert_eq!(fence_lang("  ```"), "");
    }

    #[test]
    fn a_command_in_the_box_is_led_by_a_bang() {
        assert!(bang_command("!git status".into()));
        assert!(bang_command("  ! make".into()));
        assert!(!bang_command("![shot](images/0123456789abcdef.png) look".into()));
        assert!(!bang_command("!".into()));
        assert!(!bang_command("! ".into()));
        assert!(!bang_command("Run it!".into()));
    }

    #[test]
    fn a_mac_is_asked_for_its_commands_once_a_minute_answered_or_not() {
        let commands = Commands::default();
        assert!(known(&commands, "mini").is_none());
        // An older Mac that doesn't answer is noted as asked, with none.
        assert_eq!(keep(&commands, "mini", None), 0);
        assert_eq!(known(&commands, "mini").map(|(n, stale)| (n.len(), stale)), Some((0, false)));
        assert_eq!(keep(&commands, "mini", Some(vec!["git".into(), "npm".into()])), 2);
        // One that answered before and doesn't now keeps what it said.
        assert_eq!(keep(&commands, "mini", None), 2);
        assert!(known(&commands, "mini").is_some_and(|(n, _)| n.contains("git")));
    }

    // RunButton.test.ts's cases, so the phone offers Run where the Mac does.
    fn runs(text: &str) -> bool {
        let known: HashSet<String> = ["git", "npm", "cd", "export", "make", "ls", "grep", "echo", "zsh"].iter().map(|s| s.to_string()).collect();
        is_command_block(text, &known)
    }

    #[test]
    fn a_block_with_no_language_runs_when_each_line_starts_with_a_command_its_mac_has() {
        assert!(runs("git -C ~/projects/app-infra pull --ff-only"));
        assert!(runs("# first\ncd ~/app && npm ci\n\nnpm test   # a minute"));
        assert!(runs("NODE_ENV=test CI=1 npm test"));
        assert!(runs("make;"));
        assert!(runs("ls | grep x"));
        // A line carried on into the next, which needn't start with a command.
        assert!(runs("git log \\\n  --oneline -5 |\n  grep fix"));
        // A script by its path from where it runs, given arguments.
        assert!(runs("cd ~/app/infra\n\n../scripts/plan.mjs plan -target=bucket.logs"));
        assert!(runs(r#"../scripts/apply.sh -target='member["user:me@example.com"]' --note "a's grant""#));
        assert!(runs("./build.sh --release && ./scripts/check.sh"));
        assert!(runs("NODE_ENV=test ./run-tests | grep fail"));
        // One named from a folder without `./`, when its name is a script's.
        assert!(runs("cd /Users/me/projects/northwind-infra\ngit pull -q        # now 5d47dc9\nscripts/elevate.mjs ops \"Rotate the leaked keys (change c1c5)\"\nscripts/rotate.sh check"));
        assert!(runs("scripts/rotate.sh check\nscripts/rotate.sh locate"));
        assert!(runs("tools/migrate.py --dry-run && make"));
        assert!(runs("bin/rails server -p 3001"));
        assert!(runs("node_modules/.bin/vitest run src/ui"));
        assert!(runs("CI=1 .venv/bin/pytest -q"));
    }

    #[test]
    fn output_paths_settings_and_code_dont() {
        for text in [
            "git status\nOn branch main",
            "~/projects/app/src/main.ts",
            "src/ui/Markdown.tsx:153",
            "./scripts/relaunch.sh",
            "./src/ui/App.tsx\n./src/ui/Card.tsx",
            "./src/main.ts:12:5 - error TS2322: not assignable",
            "/usr/local/bin/tool  →  0.3.1",
            "~/bin/tool --help",
            "libs/web/vitest.config.ts was not found by the project service.",
            "acme-actions/get-credentials failed with: connection timeout",
            "@atlas/cli@0.3.1 -> ../../projects/atlas/apps/cli",
            "acme/web has team settings in .codealong/config.toml",
            "src/robin/notes.md and more",
            "scripts/relaunch.sh",
            "src/ui/config.json is read first",
            "[server]\nport = 8080",
            "$ git status",
            "zsh: command not found: foo",
            "echo(\"hi\")",
            "Git pull",
            "deploy --prod",
            "# just a note",
            "",
        ] {
            assert!(!runs(text), "{text}");
        }
    }
}
