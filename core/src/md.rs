//! What agents write, read as the Mac's conversation reads it (the main repo's
//! `src/ui/Markdown.tsx`): headings, lists, quotes, fenced code, tables and rules, with each
//! block's text left as inline Markdown for Swift's `AttributedString` to draw (emphasis, code
//! spans, links). Links are settled here, as the Mac settles them: a web link, written as a link or
//! bare, opens; a bare link to a GitHub PR reads `name#123`, as GitHub shortens it; a link to
//! anything else shows as its text. A tool's output isn't Markdown, but its web links open too
//! (`linked_output`). Your prompts aren't read as Markdown either: they show as you wrote them,
//! with their web links, and the files and images Codealong kept for them (`prompt_parts`).

/// A block of what an agent wrote.
#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum MdBlock {
    Heading { level: u8, text: String },
    Paragraph { text: String },
    /// `start`: an ordered list's first number, which goes on after a code block in the list.
    List { ordered: bool, start: u32, items: Vec<String> },
    Quote { text: String },
    Code { text: String },
    /// Rows have as many cells as the header, as GitHub pads or trims them.
    Table { align: Vec<MdAlign>, head: Vec<String>, rows: Vec<Vec<String>> },
    Rule,
}

/// How a table's column lines up, as its delimiter row says (`:--`, `:-:`, `--:`).
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum MdAlign {
    Plain,
    Left,
    Center,
    Right,
}

/// A piece of a tool's output: text, or a web link in it.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct TextSpan {
    pub text: String,
    pub url: Option<String>,
}

/// A block, and how deep in lists it is: 0 at the top, 1 for what's indented under an item of a
/// top-level list, and so on. The windows indent it that far, so lists nest as the Mac's do.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct MdPart {
    pub depth: u8,
    pub block: MdBlock,
}

/// Markdown's blocks, each one's text as inline Markdown with its links settled (`inline`).
#[uniffi::export]
pub fn markdown(text: String) -> Vec<MdPart> {
    parts(&text)
        .into_iter()
        .map(|(depth, b)| MdPart { depth, block: settled(b) })
        .collect()
}

fn settled(b: MdBlock) -> MdBlock {
    match b {
        MdBlock::Heading { level, text } => MdBlock::Heading { level, text: inline(&text) },
        MdBlock::Paragraph { text } => MdBlock::Paragraph { text: inline(&text) },
        MdBlock::List { ordered, start, items } => MdBlock::List { ordered, start, items: items.iter().map(|i| inline(i)).collect() },
        MdBlock::Quote { text } => MdBlock::Quote { text: inline(&text) },
        MdBlock::Table { align, head, rows } => MdBlock::Table { align, head: head.iter().map(|c| inline(c)).collect(), rows: rows.iter().map(|r| r.iter().map(|c| inline(c)).collect()).collect() },
        other => other,
    }
}

/// One line of inline Markdown with its links settled, for text that isn't read as blocks (your
/// prompts, notes).
#[uniffi::export]
pub fn inline_markdown(text: String) -> String {
    inline(&text)
}

/// A tool's output as it was written, every character of it, with its web links as links. Output
/// is as often JSON as prose, so a link ends at a quote or a backslash too, and a PR's link reads
/// as written.
#[uniffi::export]
pub fn linked_output(text: String) -> Vec<TextSpan> {
    let mut out = Vec::new();
    let mut plain = String::new();
    let mut rest = text.as_str();
    while let Some(at) = web_start(rest) {
        let Some(len) = web_len(&rest[at..], true) else {
            // Not a link after all: take the scheme as text and go on.
            let skip = at + rest[at..].find("://").map_or(1, |i| i + 3);
            plain.push_str(&rest[..skip]);
            rest = &rest[skip..];
            continue;
        };
        plain.push_str(&rest[..at]);
        if !plain.is_empty() {
            out.push(TextSpan { text: std::mem::take(&mut plain), url: None });
        }
        let url = &rest[at..at + len];
        out.push(TextSpan { text: url.to_string(), url: Some(url.to_string()) });
        rest = &rest[at + len..];
    }
    plain.push_str(rest);
    if !plain.is_empty() {
        out.push(TextSpan { text: plain, url: None });
    }
    out
}

/// A piece of a prompt of yours, as the Mac shows one (DescriptionEditor.tsx `DescriptionView`).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PromptPart {
    pub kind: PromptPartKind,
    /// The words: the text itself, a link's URL, or a file's or image's name.
    pub text: String,
    /// Where a link goes; for an image, where its Mac keeps it (`images/<hash>.<ext>`), to read
    /// it from there.
    pub url: Option<String>,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PromptPartKind {
    Text,
    Link,
    /// An image Codealong kept with the prompt, read from its Mac to show (`Core::read_image`).
    Image,
    /// A file Codealong kept with the prompt, as a chip on the Mac.
    File,
}

/// A prompt of yours as you wrote it, every character of it, with its web links as links and the
/// images and files Codealong kept for it (`![alt](images/<hash>.png)`,
/// `[name](files/<hash>/<name>)`, as the Mac's todos.ts reads them) as their names.
#[uniffi::export]
pub fn prompt_parts(text: String) -> Vec<PromptPart> {
    let mut out: Vec<PromptPart> = Vec::new();
    let mut plain = String::new();
    let mut rest = text.as_str();
    let push = |out: &mut Vec<PromptPart>, plain: &mut String| {
        if !plain.is_empty() {
            out.push(PromptPart { kind: PromptPartKind::Text, text: std::mem::take(plain), url: None });
        }
    };
    while !rest.is_empty() {
        if let Some((part, len)) = kept_at(rest) {
            push(&mut out, &mut plain);
            out.push(part);
            rest = &rest[len..];
            continue;
        }
        let at_word_start = plain.chars().next_back().is_none_or(|c| !c.is_alphanumeric());
        if at_word_start && is_web(rest) {
            if let Some(len) = prompt_link_len(rest) {
                push(&mut out, &mut plain);
                out.push(PromptPart { kind: PromptPartKind::Link, text: rest[..len].to_string(), url: Some(rest[..len].to_string()) });
                rest = &rest[len..];
                continue;
            }
        }
        let c = rest.chars().next().expect("not empty");
        plain.push(c);
        rest = &rest[c.len_utf8()..];
    }
    push(&mut out, &mut plain);
    out
}

/// An image or a file Codealong kept, written as a link at the start of `s`, and how long it is.
fn kept_at(s: &str) -> Option<(PromptPart, usize)> {
    let hex16 = |h: &str| h.len() == 16 && h.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f'));
    let image = s.starts_with("![");
    let (words, target, len) = link_at(if image { &s[1..] } else { s }, true)?;
    if words.contains('\n') {
        return None;
    }
    let len = len + usize::from(image);
    if image {
        let name = target.strip_prefix("images/")?;
        let (hash, ext) = name.split_once('.')?;
        if !hex16(hash) || !matches!(ext, "png" | "jpg" | "gif" | "webp") {
            return None;
        }
        let alt = if words.is_empty() { "image" } else { words };
        return Some((PromptPart { kind: PromptPartKind::Image, text: alt.to_string(), url: Some(target.to_string()) }, len));
    }
    let rest = target.strip_prefix("files/")?;
    let (hash, name) = rest.split_once('/')?;
    if !hex16(hash) || name.is_empty() || name.contains('/') {
        return None;
    }
    let shown = if words.is_empty() { name } else { words };
    Some((PromptPart { kind: PromptPartKind::File, text: shown.to_string(), url: None }, len))
}

/// How long the web link at the start of a prompt's text is, as the Mac's todos.ts takes one: up
/// to a space, angle bracket or parenthesis, less the punctuation that ends a sentence.
fn prompt_link_len(s: &str) -> Option<usize> {
    let scheme = if s[..s.len().min(8)].eq_ignore_ascii_case("https://") { 8 } else { 7 };
    let end = s[scheme..].find(|c: char| c.is_whitespace() || "<>()".contains(c)).map_or(s.len(), |i| scheme + i);
    let body = s[..end].trim_end_matches(|c: char| ".,;:!?'\"".contains(c));
    (body.len() > scheme).then_some(body.len())
}

// ---- blocks ----

/// A list item's marker and text: `- x`, `* x`, `+ x`, `1. x`, `1) x`; the number for an ordered
/// one.
fn item(line: &str) -> Option<(Option<u32>, &str)> {
    let s = line.trim_start();
    let (number, after) = match s.chars().next()? {
        '-' | '*' | '+' => (None, &s[1..]),
        c if c.is_ascii_digit() => {
            let digits = s.find(|c: char| !c.is_ascii_digit())?;
            let rest = &s[digits..];
            if !(rest.starts_with('.') || rest.starts_with(')')) {
                return None;
            }
            (Some(s[..digits].parse().ok()?), &rest[1..])
        }
        _ => return None,
    };
    // At least one space after the marker, and something after that.
    if !after.starts_with(char::is_whitespace) {
        return None;
    }
    let text = after.trim_start();
    if text.is_empty() { None } else { Some((number, text)) }
}

/// How far a line is indented, a tab counting as four spaces.
fn indent_of(line: &str) -> usize {
    line.chars().take_while(|c| *c == ' ' || *c == '\t').map(|c| if c == '\t' { 4 } else { 1 }).sum()
}

/// How many spaces a line starts with, to cut them off it.
fn leading_spaces(line: &str) -> usize {
    line.len() - line.trim_start_matches(' ').len()
}

/// A line that starts a block of its own, rather than going on with the text before it.
fn starts_block(line: &str) -> bool {
    item(line).is_some() || is_fence(line) || heading(line.trim_start()).is_some() || is_quote(line) || is_rule(line)
}

fn is_fence(line: &str) -> bool {
    line.trim_start().starts_with("```")
}

/// A heading's level and text: one to six hashes at the line's start, then whitespace.
fn heading(line: &str) -> Option<(u8, &str)> {
    let level = line.chars().take_while(|&c| c == '#').count();
    if !(1..=6).contains(&level) {
        return None;
    }
    let rest = &line[level..];
    if !rest.starts_with(char::is_whitespace) {
        return None;
    }
    Some((level as u8, rest.trim_start()))
}

/// Three or more of one of `-`, `*`, `_`, spaces between allowed.
fn is_rule(line: &str) -> bool {
    let marks: Vec<char> = line.chars().filter(|c| !c.is_whitespace()).collect();
    marks.len() >= 3 && matches!(marks[0], '-' | '*' | '_') && marks.iter().all(|&c| c == marks[0])
}

fn is_quote(line: &str) -> bool {
    line.trim_start().starts_with('>')
}

/// A table row's cells: split on pipes that aren't escaped or inside `code`.
fn cells(line: &str) -> Vec<String> {
    let mut s = line.trim();
    s = s.strip_prefix('|').unwrap_or(s);
    if s.ends_with('|') && !s.ends_with("\\|") {
        s = &s[..s.len() - 1];
    }
    let mut out = Vec::new();
    let mut cell = String::new();
    let mut tick = false;
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' if chars.peek() == Some(&'|') => {
                cell.push('|');
                chars.next();
            }
            '`' => {
                tick = !tick;
                cell.push(c);
            }
            '|' if !tick => out.push(std::mem::take(&mut cell).trim().to_string()),
            _ => cell.push(c),
        }
    }
    out.push(cell.trim().to_string());
    out
}

/// A table's delimiter row, under its header: `| --- | :-: |`.
fn is_delimiter(line: &str) -> bool {
    let mut s = line.trim();
    s = s.strip_prefix('|').unwrap_or(s);
    s = s.strip_suffix('|').unwrap_or(s);
    s.split('|').all(|cell| {
        let d = cell.trim();
        let d = d.strip_prefix(':').unwrap_or(d);
        let d = d.strip_suffix(':').unwrap_or(d);
        !d.is_empty() && d.chars().all(|c| c == '-')
    })
}

/// Whether a table starts at line `i`: a row with a pipe, then a delimiter row with as many cells.
fn table_at(lines: &[&str], i: usize) -> bool {
    lines[i].contains('|') && i + 1 < lines.len() && is_delimiter(lines[i + 1]) && cells(lines[i]).len() == cells(lines[i + 1]).len()
}

fn align_of(delimiter: &str) -> MdAlign {
    match (delimiter.starts_with(':'), delimiter.ends_with(':')) {
        (true, true) => MdAlign::Center,
        (true, false) => MdAlign::Left,
        (false, true) => MdAlign::Right,
        (false, false) => MdAlign::Plain,
    }
}

/// The text's blocks, as the Mac's `blocks` reads them, without how deep in lists each is.
#[cfg(test)]
pub(crate) fn blocks(src: &str) -> Vec<MdBlock> {
    parts(src).into_iter().map(|(_, b)| b).collect()
}

/// The text's blocks, as the Mac's `blocks` reads them, each with how deep in lists it is. A
/// paragraph's lines are joined with spaces, as Markdown joins them; a blank line, or the start of
/// another kind of block, ends it.
pub(crate) fn parts(src: &str) -> Vec<(u8, MdBlock)> {
    let src = src.replace("\r\n", "\n").replace('\r', "\n");
    let mut out = Vec::new();
    read_blocks(&src, 0, &mut out);
    out
}

/// Reads `src`'s blocks into `out` at `depth`: what's indented under a list's item is read the
/// same way, a level deeper.
fn read_blocks(src: &str, depth: u8, out: &mut Vec<(u8, MdBlock)>) {
    let lines: Vec<&str> = src.split('\n').collect();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        if line.trim().is_empty() {
            i += 1;
            continue;
        }
        if is_fence(line) {
            // A fence in a list is indented with the list, and so are the lines inside it.
            let indent = line.len() - line.trim_start_matches(' ').len();
            let mut body = Vec::new();
            i += 1;
            while i < lines.len() && !is_fence(lines[i]) {
                let l = lines[i];
                let spaces = (l.len() - l.trim_start_matches(' ').len()).min(indent);
                body.push(&l[spaces..]);
                i += 1;
            }
            // A block still being written (a reply as it streams) has no closing fence yet.
            i += 1;
            out.push((depth, MdBlock::Code { text: body.join("\n") }));
            continue;
        }
        if let Some((level, text)) = heading(line) {
            out.push((depth, MdBlock::Heading { level, text: text.to_string() }));
            i += 1;
            continue;
        }
        if is_rule(line) {
            out.push((depth, MdBlock::Rule));
            i += 1;
            continue;
        }
        if table_at(&lines, i) {
            let head = cells(line);
            let delims = cells(lines[i + 1]);
            let align = (0..head.len()).map(|j| delims.get(j).map_or(MdAlign::Plain, |d| align_of(d))).collect();
            let mut rows = Vec::new();
            i += 2;
            while i < lines.len() && !lines[i].trim().is_empty() && lines[i].contains('|') {
                let r = cells(lines[i]);
                rows.push((0..head.len()).map(|j| r.get(j).cloned().unwrap_or_default()).collect());
                i += 1;
            }
            out.push((depth, MdBlock::Table { align, head, rows }));
            continue;
        }
        if let Some((number, _)) = item(line) {
            // A list's items are the items at its first one's indent and of its kind: a list of
            // another kind starts a new one, and items a blank line apart stay one list. What's
            // indented under an item (further than its marker, blank lines between included) is
            // read as Markdown of its own, a level deeper: a nested list, a paragraph, a code
            // block, which is the item's whole however its lines are indented. The list goes on
            // after it, numbered on, as the Mac's Markdown.tsx reads it.
            let ordered = number.is_some();
            let at = indent_of(line);
            let mut start = number.unwrap_or(1);
            let mut items: Vec<String> = Vec::new();
            let sibling = |l: &str| item(l).is_some_and(|(n, _)| n.is_some() == ordered) && indent_of(l).abs_diff(at) <= 1;
            while i < lines.len() {
                let l = lines[i];
                if l.trim().is_empty() {
                    match (i..lines.len()).find(|&j| !lines[j].trim().is_empty()) {
                        Some(j) if sibling(lines[j]) => {
                            i = j;
                            continue;
                        }
                        _ => break,
                    }
                }
                if !sibling(l) {
                    break;
                }
                let (_, text) = item(l).expect("a sibling is an item");
                let mut own = text.to_string();
                i += 1;
                // Its wrapped lines: indented under it, and no block of their own.
                while i < lines.len() && !lines[i].trim().is_empty() && indent_of(lines[i]) > at && !starts_block(lines[i]) {
                    own.push(' ');
                    own.push_str(lines[i].trim());
                    i += 1;
                }
                items.push(own);
                let mut under: Vec<&str> = Vec::new();
                let mut fenced = false;
                while i < lines.len() {
                    let m = lines[i];
                    if fenced {
                        fenced = !is_fence(m);
                    } else if m.trim().is_empty() {
                        match (i..lines.len()).find(|&j| !lines[j].trim().is_empty()) {
                            Some(j) if indent_of(lines[j]) > at => {}
                            _ => break,
                        }
                    } else if indent_of(m) > at {
                        fenced = is_fence(m);
                    } else {
                        break;
                    }
                    under.push(m);
                    i += 1;
                }
                if under.iter().any(|m| !m.trim().is_empty()) {
                    // The items so far, then what's under the last of them; the list goes on
                    // after it, numbered on.
                    let n = items.len() as u32;
                    out.push((depth, MdBlock::List { ordered, start, items: std::mem::take(&mut items) }));
                    if ordered {
                        start += n;
                    }
                    let cut = under.iter().filter(|m| !m.trim().is_empty()).map(|m| leading_spaces(m)).min().unwrap_or(0);
                    let inner: Vec<&str> = under.iter().map(|m| &m[leading_spaces(m).min(cut)..]).collect();
                    read_blocks(&inner.join("\n"), depth + 1, out);
                }
            }
            if !items.is_empty() {
                out.push((depth, MdBlock::List { ordered, start, items }));
            }
            continue;
        }
        if is_quote(line) {
            let mut body = Vec::new();
            while i < lines.len() && is_quote(lines[i]) {
                let l = lines[i].trim_start().trim_start_matches('>');
                body.push(l.strip_prefix(' ').unwrap_or(l));
                i += 1;
            }
            out.push((depth, MdBlock::Quote { text: body.join(" ") }));
            continue;
        }
        let mut body = Vec::new();
        while i < lines.len() {
            let l = lines[i];
            if l.trim().is_empty() || heading(l).is_some() || is_fence(l) || is_quote(l) || item(l).is_some() || table_at(&lines, i) {
                break;
            }
            body.push(l.trim());
            i += 1;
        }
        out.push((depth, MdBlock::Paragraph { text: body.join(" ") }));
    }
}

// ---- links ----

/// Where the next `http://` or `https://` starts, if anywhere.
fn web_start(s: &str) -> Option<usize> {
    let lower = s.to_ascii_lowercase();
    match (lower.find("http://"), lower.find("https://")) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    }
}

/// How long the web link at the start of `s` is, as the Mac's patterns take one: up to a space,
/// angle bracket, parenthesis or backtick (in output, a quote or backslash too), less the
/// punctuation that ends a sentence around it. None when there's nothing after the scheme.
fn web_len(s: &str, output: bool) -> Option<usize> {
    let scheme = if s[..s.len().min(8)].eq_ignore_ascii_case("https://") { 8 } else { 7 };
    let stops = |c: char| c.is_whitespace() || "<>()`".contains(c) || (output && "\"'\\".contains(c));
    let end = s[scheme..].find(stops).map_or(s.len(), |i| scheme + i);
    let trailing: &str = if output { ".,;:!?*_" } else { ".,;:!?'\"*_" };
    let body = s[..end].trim_end_matches(|c: char| trailing.contains(c));
    (body.len() > scheme).then_some(body.len())
}

fn is_web(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    lower.starts_with("http://") || lower.starts_with("https://")
}

/// A link to a GitHub PR as GitHub shortens it: `name#123`, with what in it the link goes to when
/// that isn't the PR itself (the Mac's prLinks.ts `prLabel`). None for any other link.
pub(crate) fn pr_label(url: &str) -> Option<String> {
    let rest = url.strip_prefix("https://").or_else(|| url.strip_prefix("http://"))?;
    let rest = rest.strip_prefix("www.").unwrap_or(rest);
    let rest = rest.get(..11).filter(|h| h.eq_ignore_ascii_case("github.com/")).map(|_| &rest[11..])?;
    let (path, hash) = rest.split_once('#').map_or((rest, ""), |(p, h)| (p, h));
    let path = path.split_once('?').map_or(path, |(p, _)| p);
    let parts: Vec<&str> = path.split('/').collect();
    let name_ok = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_alphanumeric() || "._-".contains(c));
    let [owner, name, "pull", number, sub @ ..] = parts.as_slice() else { return None };
    if !name_ok(owner) || !name_ok(name) || number.is_empty() || !number.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let hash = hash.to_ascii_lowercase();
    let part = if hash.starts_with("issuecomment") || hash.starts_with("discussion_r") {
        Some("comment")
    } else if hash.starts_with("pullrequestreview") {
        Some("review")
    } else {
        match sub.first().map(|s| s.to_ascii_lowercase()).as_deref() {
            Some("files") => Some("files"),
            Some("commits") => Some("commits"),
            Some("checks") => Some("checks"),
            _ => None,
        }
    };
    Some(format!("{name}#{number}{}", part.map(|p| format!(" ({p})")).unwrap_or_default()))
}

/// Text written into a link's words, with what Markdown would read as marks escaped.
fn escaped(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if "\\`*_[]<>".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// A bare web link as a Markdown link: its words are the URL, or a PR's as GitHub shortens it.
fn bare_link(url: &str) -> String {
    format!("[{}]({url})", escaped(&pr_label(url).unwrap_or_else(|| url.to_string())))
}

/// `[words](target …)` at the start of `s`: the words, the target and how long it all is. A link
/// in what an agent wrote has words; an image Codealong kept may not (`empty`).
fn link_at(s: &str, empty: bool) -> Option<(&str, &str, usize)> {
    if !s.starts_with('[') {
        return None;
    }
    let close = s.find(']')?;
    let words = &s[1..close];
    if (words.is_empty() && !empty) || words.contains('[') {
        return None;
    }
    let rest = s[close + 1..].strip_prefix('(')?;
    let end = rest.find(')')?;
    let target = rest[..end].split_whitespace().next()?;
    Some((words, target, close + 2 + end + 1))
}

/// Inline Markdown with its links settled, as the Mac's `inline` draws them: code spans as they
/// are; a link to the web kept, and its words not made links again; a link to anything else as
/// its words; `<https://…>` and bare web links as links. An image (`![alt](…)`), which the phone
/// isn't sent, reads as its words in italics.
pub(crate) fn inline(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    let b = text.as_bytes();
    while i < text.len() {
        let rest = &text[i..];
        let c = rest.chars().next().expect("not at the end");
        if c == '`' {
            // A code span, left as it is: nothing in it is a mark or a link.
            if let Some(end) = rest[1..].find('`') {
                out.push_str(&rest[..end + 2]);
                i += end + 2;
                continue;
            }
        } else if c == '!' && rest[1..].starts_with('[') {
            if let Some((words, _, len)) = link_at(&rest[1..], false) {
                out.push('*');
                out.push_str(&escaped(words));
                out.push('*');
                i += 1 + len;
                continue;
            }
        } else if c == '[' {
            if let Some((words, target, len)) = link_at(rest, false) {
                if is_web(target) {
                    out.push_str(&rest[..len]);
                } else {
                    out.push_str(&inline(words));
                }
                i += len;
                continue;
            }
        } else if c == '<' && is_web(&rest[1..]) {
            if let Some(end) = rest.find('>') {
                let url = &rest[1..end];
                if !url.contains(char::is_whitespace) {
                    out.push_str(&bare_link(url));
                    i += end + 1;
                    continue;
                }
            }
        } else if (c == 'h' || c == 'H') && is_web(rest) && (i == 0 || !(b[i - 1] as char).is_alphanumeric()) {
            if let Some(len) = web_len(rest, false) {
                out.push_str(&bare_link(&rest[..len]));
                i += len;
                continue;
            }
        }
        out.push(c);
        i += c.len_utf8();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn para(s: &str) -> MdBlock {
        MdBlock::Paragraph { text: s.into() }
    }

    #[test]
    fn reads_blocks_as_the_mac_does() {
        let src = "# Title\nFirst line\nsecond line\n\n- one\n  wrapped\n+ two\n3) three\n\n> quoted\n> more\n\n---\n\n```rust\nfn main() {}\n```\nAfter";
        assert_eq!(
            blocks(src),
            [
                MdBlock::Heading { level: 1, text: "Title".into() },
                para("First line second line"),
                // A list of another kind starts a new one, numbered from its own first number.
                MdBlock::List { ordered: false, start: 1, items: vec!["one wrapped".into(), "two".into()] },
                MdBlock::List { ordered: true, start: 3, items: vec!["three".into()] },
                MdBlock::Quote { text: "quoted more".into() },
                MdBlock::Rule,
                MdBlock::Code { text: "fn main() {}".into() },
                para("After"),
            ]
        );
        // An ordered list says where it starts, and goes on after a code block in it.
        let list = "4. four\n   ```\n   cargo test\n   ```\n5. five";
        assert_eq!(
            blocks(list),
            [
                MdBlock::List { ordered: true, start: 4, items: vec!["four".into()] },
                MdBlock::Code { text: "cargo test".into() },
                MdBlock::List { ordered: true, start: 5, items: vec!["five".into()] },
            ]
        );
        // A reply still being written has no closing fence yet.
        assert_eq!(blocks("```\nhalf"), [MdBlock::Code { text: "half".into() }]);
        // A hash without a space, or seven of them, isn't a heading.
        assert_eq!(blocks("#hashtag"), [para("#hashtag")]);
        assert_eq!(blocks("####### seven"), [para("####### seven")]);
    }

    fn list(ordered: bool, start: u32, items: &[&str]) -> MdBlock {
        MdBlock::List { ordered, start, items: items.iter().map(|i| i.to_string()).collect() }
    }

    #[test]
    fn nests_what_is_indented_under_an_item_as_the_mac_does() {
        // A reply that came out flat on the Mac, its sub-items beside their items and its
        // paragraph out of the list (Markdown.test.ts, 2026-10-08).
        let src = [
            "- **For a design review, effort sets how many checks the planner proposes:**",
            "  - Quick: about 10.",
            "  - Deep: also every interface.",
            "",
            "  The approval card would say what the next level adds.",
            "- **A customer's own list has no effort setting.** The list is the scope.",
            "- **\"Only P1s\" isn't effort.** It fits in two places:",
            "  - the list;",
            "  - a filter.",
        ]
        .join("\n");
        assert_eq!(
            parts(&src),
            [
                (0, list(false, 1, &["**For a design review, effort sets how many checks the planner proposes:**"])),
                (1, list(false, 1, &["Quick: about 10.", "Deep: also every interface."])),
                (1, para("The approval card would say what the next level adds.")),
                (0, list(false, 1, &["**A customer's own list has no effort setting.** The list is the scope.", "**\"Only P1s\" isn't effort.** It fits in two places:"])),
                (1, list(false, 1, &["the list;", "a filter."])),
            ]
        );
        // Items a blank line apart stay one list, and another starts where the kind changes.
        assert_eq!(parts("1. one\n\n2. two\n\n- a"), [(0, list(true, 1, &["one", "two"])), (0, list(false, 1, &["a"]))]);
        // A numbered list that starts later keeps its number, and lists nest three deep.
        assert_eq!(
            parts("3. three\n   - a\n     - b\n\nafter"),
            [(0, list(true, 3, &["three"])), (1, list(false, 1, &["a"])), (2, list(false, 1, &["b"])), (0, para("after"))]
        );
        // A code block under an item is part of it, whole however its lines are indented.
        assert_eq!(
            parts("- Run:\n  ```\nmake all\n  ```\n- Then check."),
            [(0, list(false, 1, &["Run:"])), (1, MdBlock::Code { text: "make all".into() }), (0, list(false, 1, &["Then check."]))]
        );
        // The numbers go on after what's under an item.
        assert_eq!(parts("1. one\n   more under it\n\n   - x\n2. two"), [(0, list(true, 1, &["one more under it"])), (1, list(false, 1, &["x"])), (0, list(true, 2, &["two"]))]);
    }

    #[test]
    fn reads_tables_with_their_alignment() {
        let src = "Results:\n| Name | Count | Note |\n|:-----|------:|:----:|\n| `a|b` | 2 | x \\| y |\n| short |\n\nAfter";
        assert_eq!(
            blocks(src),
            [
                para("Results:"),
                MdBlock::Table {
                    align: vec![MdAlign::Left, MdAlign::Right, MdAlign::Center],
                    head: vec!["Name".into(), "Count".into(), "Note".into()],
                    // A pipe in code or escaped stays in its cell; a short row is padded.
                    rows: vec![vec!["`a|b`".into(), "2".into(), "x | y".into()], vec!["short".into(), String::new(), String::new()]],
                },
                para("After"),
            ]
        );
        // Without the edge pipes, it's a table all the same.
        assert!(matches!(&blocks("a | b\n--- | ---\n1 | 2")[0], MdBlock::Table { rows, .. } if rows == &vec![vec!["1".to_string(), "2".into()]]));
        // A header with more cells than its delimiter row isn't one: as on the Mac, the lines go
        // on as a paragraph.
        assert_eq!(blocks("a | b\n---\nc"), [para("a | b --- c")]);
    }

    #[test]
    fn settles_links_as_the_mac_does() {
        // Bare web links open, without the punctuation that ends a sentence around them.
        assert_eq!(inline("See https://example.com/a_b."), "See [https://example.com/a\\_b](https://example.com/a_b).");
        // A PR's reads as GitHub shortens it, with what in it a link goes to.
        assert_eq!(inline("Opened https://github.com/acme/app/pull/12"), "Opened [app#12](https://github.com/acme/app/pull/12)");
        assert_eq!(pr_label("https://github.com/acme/app/pull/12/files").as_deref(), Some("app#12 (files)"));
        assert_eq!(pr_label("https://github.com/acme/app/pull/12#issuecomment-9").as_deref(), Some("app#12 (comment)"));
        assert_eq!(pr_label("https://github.com/acme/app/issues/12"), None);
        // A written link to the web stays; one to anything else is its words.
        assert_eq!(inline("[the docs](https://example.com) and [main.rs](src/main.rs)"), "[the docs](https://example.com) and main.rs");
        assert_eq!(inline("<https://example.com>"), "[https://example.com](https://example.com)");
        // Nothing in a code span is a link.
        assert_eq!(inline("`curl https://example.com`"), "`curl https://example.com`");
        // An image the phone isn't sent reads as its words.
        assert_eq!(inline("![image](images/a.png) here"), "*image* here");
        // Emphasis is left for Swift to draw.
        assert_eq!(inline("**bold** and *it*"), "**bold** and *it*");
        // A word that runs into the scheme isn't a link.
        assert_eq!(inline("xhttps://a.b"), "xhttps://a.b");
    }

    #[test]
    fn a_prompt_shows_as_written_with_its_links_and_what_was_kept_for_it() {
        let parts = prompt_parts("Fix **this**:\n```\nls\n```\nSee https://example.com/a. ![shot](images/0123456789abcdef.png) [log.txt](files/0123456789abcdef/log.txt) [x](src/x.rs)".into());
        let kinds: Vec<(PromptPartKind, &str)> = parts.iter().map(|p| (p.kind, p.text.as_str())).collect();
        assert_eq!(
            kinds,
            [
                // Markdown in a prompt stays as written; only what Codealong kept and web links
                // are anything else.
                (PromptPartKind::Text, "Fix **this**:\n```\nls\n```\nSee "),
                (PromptPartKind::Link, "https://example.com/a"),
                (PromptPartKind::Text, ". "),
                (PromptPartKind::Image, "shot"),
                (PromptPartKind::Text, " "),
                (PromptPartKind::File, "log.txt"),
                (PromptPartKind::Text, " [x](src/x.rs)"),
            ]
        );
        // An image link that isn't one Codealong kept is text.
        assert_eq!(prompt_parts("![a](images/b.png)".into())[0].kind, PromptPartKind::Text);
        assert_eq!(prompt_parts("![](images/0123456789abcdef.jpg)".into())[0].text, "image");
        // An image says where its Mac keeps it, to read it from there.
        assert_eq!(parts[3].url.as_deref(), Some("images/0123456789abcdef.png"));
    }

    #[test]
    fn a_tools_output_keeps_every_character_with_its_links() {
        let spans = linked_output(r#"{"url":"https://example.com/x","ok":true} see http://a.b/c."#.into());
        let urls: Vec<&str> = spans.iter().filter_map(|s| s.url.as_deref()).collect();
        assert_eq!(urls, ["https://example.com/x", "http://a.b/c"]);
        assert_eq!(spans.iter().map(|s| s.text.as_str()).collect::<String>(), r#"{"url":"https://example.com/x","ok":true} see http://a.b/c."#);
        // A PR's link in output reads as written.
        assert_eq!(linked_output("https://github.com/acme/app/pull/3".into())[0].text, "https://github.com/acme/app/pull/3");
        assert_eq!(linked_output("no links".into()), [TextSpan { text: "no links".into(), url: None }]);
        assert_eq!(linked_output("http://".into()), [TextSpan { text: "http://".into(), url: None }]);
    }
}
