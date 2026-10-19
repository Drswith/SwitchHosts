//! Find and replace over hosts content: search, single and bulk replace, and
//! the find / replace history. No window or host code lives here, so the
//! Tauri app and the native app share one implementation.
//!
//! Search covers every local and remote node. Group and folder nodes are
//! skipped; they hold references, not content.

use std::path::{Path, PathBuf};

use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::storage::{
    atomic::atomic_write,
    entries,
    error::StorageError,
    manifest::{self, Manifest},
    AppState,
};

pub const FIND_HISTORY_FILE: &str = "find.json";
pub const REPLACE_HISTORY_FILE: &str = "replace.json";
pub const HISTORY_MAX: usize = 20;

// ---- search options + result types ----------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FindOptions {
    #[serde(default)]
    pub is_regexp: bool,
    #[serde(default)]
    pub is_ignore_case: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct FindPosition {
    pub start: usize,
    pub end: usize,
    pub line: usize,
    pub line_pos: usize,
    pub end_line: usize,
    pub end_line_pos: usize,
    pub before: String,
    #[serde(rename = "match")]
    pub match_text: String,
    pub after: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct FindItem {
    pub item_id: String,
    pub item_title: String,
    pub item_type: String,
    // Keep search payloads lean: the renderer only needs row display data and
    // jump offsets. Replacement re-reads content on the Rust side.
    pub positions: Vec<FindPosition>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct FindReplaceOneArgs {
    pub item_id: String,
    pub start: usize,
    pub end: usize,
    pub expected: String,
    pub replace_to: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct FindReplaceAllOutcome {
    pub item_ids: Vec<String>,
    pub replaced_count: usize,
}

// ---- search engine --------------------------------------------------------

/// Run a find pass against every local/remote node in the manifest
/// and return one `FindItem` per node that matched.
pub fn find_in_manifest(
    state: &AppState,
    keyword: &str,
    options: &FindOptions,
) -> Result<Vec<FindItem>, String> {
    if keyword.is_empty() {
        return Ok(Vec::new());
    }
    let regex = build_regex(keyword, options)?;

    let _guard = state.lock_store().map_err(|e| e.to_string())?;
    let manifest = Manifest::load(&state.paths).map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    walk_searchable(&manifest.root, &mut |id, title, kind| {
        let content = match entries::read_entry(&state.paths.entries_dir, id) {
            Ok(c) => c,
            Err(e) => {
                log::warn!("read {id}: {e}");
                return;
            }
        };
        let positions = find_positions_in_content(&content, &regex);
        if positions.is_empty() {
            return;
        }
        out.push(FindItem {
            item_id: id.to_string(),
            item_title: title.to_string(),
            item_type: kind.to_string(),
            positions,
        });
    });
    Ok(out)
}

pub fn build_regex(keyword: &str, options: &FindOptions) -> Result<Regex, String> {
    let pattern = if options.is_regexp {
        keyword.to_string()
    } else {
        // Escape regex metacharacters so the user gets a literal
        // string search by default. Mirrors the
        // `keyword.replace(/([.^$([?*+])/gi, '\\$1')` pass in
        // `src/main/actions/find/findBy.ts` — `regex::escape` is
        // a strict superset (also escapes `]`, `}`, `|`, `\\`, etc.)
        // so any string the user types becomes a valid literal.
        regex::escape(keyword)
    };
    RegexBuilder::new(&pattern)
        .case_insensitive(options.is_ignore_case)
        .build()
        .map_err(|e| format!("invalid pattern: {e}"))
}

/// Mirror of `src/main/actions/find/findPositionsInContent.ts`. For
/// each match in `content` we record positions (in UTF-16 code units,
/// matching CodeMirror / JS string indexing), line numbers, and the
/// surrounding line slices the renderer needs to render the result
/// list and jump back to the source view.
///
pub fn find_positions_in_content(content: &str, regex: &Regex) -> Vec<FindPosition> {
    let line_index = LineIndex::new(content);
    let mut positions = Vec::new();
    let mut line_idx = 0;
    let mut utf16_cursor = Utf16Cursor::default();

    for mat in regex.find_iter(content) {
        let start = mat.start();
        let end = mat.end();

        // CodeMirror counts offsets in UTF-16 code units (== JS string
        // length); the regex crate returns UTF-8 byte offsets. Convert
        // every outgoing offset / position so non-ASCII content (CJK,
        // emoji) doesn't skew the find-window jump or the result list's
        // column display.
        let start_u16 = utf16_cursor.advance_to(content, start);
        line_idx = line_index.line_idx_for_start(line_idx, start);
        let line_info = &line_index.lines[line_idx];
        let line = line_idx + 1;
        let line_pos = start_u16 - line_info.start_u16;

        let match_text = mat.as_str();
        let metrics = MatchMetrics::new(match_text);
        let end_u16 = start_u16 + metrics.utf16_len;

        let end_line_idx = line_idx + metrics.newline_count;
        let end_line = line + metrics.newline_count;
        let end_line_pos = if metrics.newline_count == 0 {
            line_pos + metrics.utf16_len
        } else {
            metrics.utf16_len_after_last_newline
        };
        let end_line_end_byte = line_index
            .lines
            .get(end_line_idx)
            .map(|line| line.end_byte)
            .unwrap_or(content.len());

        utf16_cursor.set(end, end_u16);

        positions.push(FindPosition {
            start: start_u16,
            end: end_u16,
            line,
            line_pos,
            end_line,
            end_line_pos,
            before: content[line_info.start_byte..start].to_string(),
            match_text: match_text.to_string(),
            after: content[end..end_line_end_byte].to_string(),
        });
    }
    positions
}

#[derive(Debug, Clone, Copy)]
pub struct LineInfo {
    start_byte: usize,
    end_byte: usize,
    start_u16: usize,
}

#[derive(Debug)]
pub struct LineIndex {
    lines: Vec<LineInfo>,
}

impl LineIndex {
    /// Precompute line byte starts and UTF-16 starts once. High-hit searches
    /// can otherwise devolve into rescanning the content prefix for each match.
    fn new(content: &str) -> Self {
        let mut lines = vec![LineInfo {
            start_byte: 0,
            end_byte: content.len(),
            start_u16: 0,
        }];
        let mut utf16_offset = 0;

        for (byte_idx, ch) in content.char_indices() {
            utf16_offset += ch.len_utf16();
            if ch == '\n' {
                if let Some(last) = lines.last_mut() {
                    last.end_byte = byte_idx;
                }
                lines.push(LineInfo {
                    start_byte: byte_idx + ch.len_utf8(),
                    end_byte: content.len(),
                    start_u16: utf16_offset,
                });
            }
        }

        Self { lines }
    }

    fn line_idx_for_start(&self, mut current_idx: usize, byte_idx: usize) -> usize {
        while current_idx + 1 < self.lines.len()
            && self.lines[current_idx + 1].start_byte <= byte_idx
        {
            current_idx += 1;
        }
        current_idx
    }
}

#[derive(Debug, Default)]
pub struct Utf16Cursor {
    byte: usize,
    utf16: usize,
}

impl Utf16Cursor {
    /// Move forward from the last match boundary and return the UTF-16 offset
    /// for `target_byte`. Regex matches are yielded in byte order, so normal
    /// search remains linear.
    fn advance_to(&mut self, content: &str, target_byte: usize) -> usize {
        if target_byte < self.byte {
            self.byte = 0;
            self.utf16 = 0;
        }

        for ch in content[self.byte..target_byte].chars() {
            self.utf16 += ch.len_utf16();
        }
        self.byte = target_byte;
        self.utf16
    }

    fn set(&mut self, byte: usize, utf16: usize) {
        self.byte = byte;
        self.utf16 = utf16;
    }
}

#[derive(Debug, Default)]
pub struct MatchMetrics {
    utf16_len: usize,
    newline_count: usize,
    utf16_len_after_last_newline: usize,
}

impl MatchMetrics {
    fn new(match_text: &str) -> Self {
        let mut out = Self::default();
        for ch in match_text.chars() {
            out.utf16_len += ch.len_utf16();
            if ch == '\n' {
                out.newline_count += 1;
                out.utf16_len_after_last_newline = 0;
            } else {
                out.utf16_len_after_last_newline += ch.len_utf16();
            }
        }
        out
    }
}

pub fn replace_one_in_manifest(state: &AppState, args: FindReplaceOneArgs) -> Result<bool, String> {
    if args.start > args.end {
        return Err("find_replace_one: start must be <= end".to_string());
    }

    let _guard = state.lock_store().map_err(|e| e.to_string())?;
    let manifest = Manifest::load(&state.paths).map_err(|e| e.to_string())?;
    let Some(node) = manifest::find_node(&manifest.root, &args.item_id) else {
        return Ok(false);
    };
    // Missing type is treated as local for older/migrated manifests; remote
    // entries remain read-only from the find window.
    if node.get("type").and_then(Value::as_str).unwrap_or("local") != "local" {
        return Ok(false);
    }

    let mut content =
        entries::read_entry(&state.paths.entries_dir, &args.item_id).map_err(|e| e.to_string())?;
    let Some((start, end)) = utf16_range_to_byte_range(&content, args.start, args.end) else {
        return Ok(false);
    };
    if content[start..end] != args.expected {
        return Ok(false);
    }

    content.replace_range(start..end, &args.replace_to);
    entries::write_entry(&state.paths.entries_dir, &args.item_id, &content)
        .map_err(|e| e.to_string())?;
    Ok(true)
}

pub fn replace_all_in_manifest(
    state: &AppState,
    keyword: &str,
    options: &FindOptions,
    replace_to: &str,
) -> Result<FindReplaceAllOutcome, String> {
    if keyword.is_empty() {
        return Ok(FindReplaceAllOutcome {
            item_ids: Vec::new(),
            replaced_count: 0,
        });
    }
    let regex = build_regex(keyword, options)?;
    let _guard = state.lock_store().map_err(|e| e.to_string())?;
    let manifest = Manifest::load(&state.paths).map_err(|e| e.to_string())?;
    // First read every local entry and compute its replacement. That way a
    // later read error does not leave earlier entries already written.
    let mut pending_writes: Vec<(String, String, usize)> = Vec::new();
    let mut read_error: Option<String> = None;

    walk_searchable(&manifest.root, &mut |id, _title, kind| {
        if read_error.is_some() {
            return;
        }
        if kind != "local" {
            return;
        }
        let content = match entries::read_entry(&state.paths.entries_dir, id) {
            Ok(c) => c,
            Err(e) => {
                read_error = Some(format!("read {id}: {e}"));
                return;
            }
        };
        let (next_content, count) = replace_all_in_content(&content, &regex, replace_to);
        if count > 0 {
            pending_writes.push((id.to_string(), next_content, count));
        }
    });

    if let Some(error) = read_error {
        return Err(error);
    }

    let mut item_ids = Vec::new();
    let mut replaced_count = 0;

    for (id, next_content, count) in pending_writes {
        entries::write_entry(&state.paths.entries_dir, &id, &next_content)
            .map_err(|e| format!("write {id}: {e}"))?;
        item_ids.push(id);
        replaced_count += count;
    }

    Ok(FindReplaceAllOutcome {
        item_ids,
        replaced_count,
    })
}

pub fn replace_all_in_content(content: &str, regex: &Regex, replace_to: &str) -> (String, usize) {
    // Do literal replacement. Regex::replace_all would expand `$1`-style
    // captures, which is not how the existing find window behaved.
    let mut out = String::with_capacity(content.len());
    let mut last_end = 0;
    let mut count = 0;

    for mat in regex.find_iter(content) {
        out.push_str(&content[last_end..mat.start()]);
        out.push_str(replace_to);
        last_end = mat.end();
        count += 1;
    }

    if count == 0 {
        return (content.to_string(), 0);
    }

    out.push_str(&content[last_end..]);
    (out, count)
}

pub fn utf16_range_to_byte_range(content: &str, start: usize, end: usize) -> Option<(usize, usize)> {
    let start_byte = utf16_offset_to_byte(content, start)?;
    let end_byte = utf16_offset_to_byte(content, end)?;
    Some((start_byte, end_byte))
}

pub fn utf16_offset_to_byte(content: &str, target: usize) -> Option<usize> {
    // Renderer/editor offsets are JS string offsets (UTF-16 code units), while
    // Rust string slicing needs UTF-8 byte boundaries.
    if target == 0 {
        return Some(0);
    }

    let mut utf16_offset = 0;
    for (byte_idx, ch) in content.char_indices() {
        if utf16_offset == target {
            return Some(byte_idx);
        }
        utf16_offset += ch.len_utf16();
        if utf16_offset == target {
            return Some(byte_idx + ch.len_utf8());
        }
        if utf16_offset > target {
            return None;
        }
    }

    if utf16_offset == target {
        Some(content.len())
    } else {
        None
    }
}

pub fn walk_searchable<F: FnMut(&str, &str, &str)>(nodes: &[Value], visit: &mut F) {
    for node in nodes {
        let kind = node.get("type").and_then(Value::as_str).unwrap_or("local");
        if kind != "group" && kind != "folder" {
            if let Some(id) = node.get("id").and_then(Value::as_str) {
                let title = node.get("title").and_then(Value::as_str).unwrap_or("");
                visit(id, title, kind);
            }
        }
        if let Some(children) = node.get("children").and_then(Value::as_array) {
            walk_searchable(children, visit);
        }
    }
}

// ---- find / replace history persistence -----------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FindHistoryEntry {
    pub value: String,
    #[serde(default)]
    pub is_regexp: bool,
    #[serde(default)]
    pub is_ignore_case: bool,
}

pub fn find_history_path(state: &AppState) -> PathBuf {
    state.paths.histories_dir.join(FIND_HISTORY_FILE)
}

pub fn replace_history_path(state: &AppState) -> PathBuf {
    state.paths.histories_dir.join(REPLACE_HISTORY_FILE)
}

pub fn get_find_history(state: &AppState) -> Result<Vec<FindHistoryEntry>, StorageError> {
    load_json_array(&find_history_path(state))
}

pub fn set_find_history(state: &AppState, items: &[FindHistoryEntry]) -> Result<(), StorageError> {
    save_json_array(&find_history_path(state), items)
}

pub fn add_find_history(
    state: &AppState,
    entry: FindHistoryEntry,
) -> Result<Vec<FindHistoryEntry>, StorageError> {
    let mut all = get_find_history(state).unwrap_or_default();
    all.retain(|i| i.value != entry.value);
    all.push(entry);
    while all.len() > HISTORY_MAX {
        all.remove(0);
    }
    set_find_history(state, &all)?;
    Ok(all)
}

pub fn get_replace_history(state: &AppState) -> Result<Vec<String>, StorageError> {
    load_json_array(&replace_history_path(state))
}

pub fn set_replace_history(state: &AppState, items: &[String]) -> Result<(), StorageError> {
    save_json_array(&replace_history_path(state), items)
}

pub fn add_replace_history(state: &AppState, value: String) -> Result<Vec<String>, StorageError> {
    let mut all = get_replace_history(state).unwrap_or_default();
    all.retain(|v| v != &value);
    all.push(value);
    while all.len() > HISTORY_MAX {
        all.remove(0);
    }
    set_replace_history(state, &all)?;
    Ok(all)
}

pub fn load_json_array<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<Vec<T>, StorageError> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let bytes = std::fs::read(path).map_err(|e| StorageError::io(path.display().to_string(), e))?;
    serde_json::from_slice::<Vec<T>>(&bytes).or_else(|_| {
        // Tolerate slight schema drift: anything that doesn't decode
        // as the expected list shape resets to empty rather than
        // crashing the find window.
        log::warn!("{} could not be parsed; treating as empty.", path.display());
        Ok(Vec::new())
    })
}

pub fn save_json_array<T: Serialize>(path: &Path, items: &[T]) -> Result<(), StorageError> {
    let bytes = serde_json::to_vec_pretty(items)
        .map_err(|e| StorageError::serialize(path.display().to_string(), e))?;
    atomic_write(path, &bytes)
}

// ---- window create + show -------------------------------------------------

