use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use crate::adapters::common::resolve_user_home_dir;
use crate::error::{fail, B3Error};
use crate::fs::has_control_chars;

pub const DEFAULT_CLARIFICATION_GATE: bool = true;
pub const DEFAULT_UNDERSTANDING_THRESHOLD: u8 = 96;
pub const MIN_UNDERSTANDING_THRESHOLD: u8 = 1;
pub const MAX_UNDERSTANDING_THRESHOLD: u8 = 100;

/// Resolved planning preferences used by `/b3-plan` and Plan / Scope phases.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlanningConfig {
    pub clarification_gate: bool,
    pub understanding_threshold: u8,
}

impl Default for PlanningConfig {
    fn default() -> Self {
        Self {
            clarification_gate: DEFAULT_CLARIFICATION_GATE,
            understanding_threshold: DEFAULT_UNDERSTANDING_THRESHOLD,
        }
    }
}

/// Partial planning preferences parsed from a config file or per-invocation override.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PlanningConfigOverride {
    pub clarification_gate: Option<bool>,
    pub understanding_threshold: Option<u8>,
}

/// Validates that a planning understanding threshold is an integer in `1..=100`.
pub fn validate_threshold(value: i64) -> Result<u8, B3Error> {
    if value < i64::from(MIN_UNDERSTANDING_THRESHOLD)
        || value > i64::from(MAX_UNDERSTANDING_THRESHOLD)
    {
        return Err(fail(
            format!(
                "PLANNING_CONFIG_INVALID: understanding_threshold must be between {MIN_UNDERSTANDING_THRESHOLD} and {MAX_UNDERSTANDING_THRESHOLD}, got {value}"
            ),
            1,
        ));
    }
    Ok(value as u8)
}

/// Validates any present fields on a `PlanningConfigOverride`.
pub fn validate_override(override_cfg: &PlanningConfigOverride) -> Result<(), B3Error> {
    if let Some(threshold) = override_cfg.understanding_threshold {
        validate_threshold(i64::from(threshold))?;
    }
    Ok(())
}

/// Returns the default global personal preferences path (`B3_MODELS_PERSONAL` or `~/.b3/models.md`).
pub fn default_global_preferences_path(user_home: Option<&Path>) -> PathBuf {
    match std::env::var("B3_MODELS_PERSONAL") {
        Ok(val) if !val.trim().is_empty() && !has_control_chars(val.trim()) => {
            PathBuf::from(val.trim())
        }
        _ => resolve_user_home_dir(user_home)
            .join(".b3")
            .join("models.md"),
    }
}

/// Returns the default repo-local preferences path (`<project>/.b3/models.md`).
pub fn default_project_preferences_path(project_root: &Path) -> PathBuf {
    project_root.join(".b3").join("models.md")
}

/// Parses an optional `planning:` YAML mapping from Markdown content.
///
/// Scans fenced YAML blocks (```` ```yaml ````, ```` ```yml ````, or untyped fences)
/// as well as standalone top-level `planning:` sections. Returns `Ok(None)` when no
/// `planning:` section exists.
pub fn parse_planning_config_from_markdown(
    content: &str,
) -> Result<Option<PlanningConfigOverride>, B3Error> {
    let text = content.strip_prefix('\u{feff}').unwrap_or(content);

    let mut found_section = false;
    let mut merged = PlanningConfigOverride::default();

    let mut fence: Option<(char, usize, bool)> = None;
    let mut active_block: Option<ActivePlanningBlock> = None;

    for raw_line in text.split('\n') {
        let line = raw_line.strip_suffix('\r').unwrap_or(raw_line);
        let trimmed_all = line.trim();

        if let Some((fence_ch, fence_len, is_yaml_fence)) = fence {
            if is_closing_fence(trimmed_all, fence_ch, fence_len) {
                if let Some(block) = active_block.take() {
                    block.merge_into(&mut merged);
                }
                fence = None;
                continue;
            }
            if !is_yaml_fence {
                continue;
            }
        } else if let Some((fence_ch, fence_len, is_yaml_fence)) = parse_opening_fence(trimmed_all)
        {
            if let Some(block) = active_block.take() {
                block.merge_into(&mut merged);
            }
            fence = Some((fence_ch, fence_len, is_yaml_fence));
            continue;
        }

        let uncommented = strip_inline_comment(line);
        let trimmed = uncommented.trim();

        if let Some(mut block) = active_block.take() {
            if trimmed.is_empty() {
                active_block = Some(block);
                continue;
            }
            if trimmed == "---" || trimmed == "..." {
                block.merge_into(&mut merged);
                // Re-evaluated below as non-planning line (nothing more to do for doc markers).
                continue;
            }
            if line.trim_start_matches(' ').starts_with('\t') {
                return Err(fail(
                    "PLANNING_CONFIG_INVALID: tabs are not allowed for indentation inside 'planning:' block",
                    1,
                ));
            }
            let indent = line.len() - line.trim_start_matches(' ').len();
            if indent > 0 {
                block.parse_child_line(indent, trimmed)?;
                active_block = Some(block);
                continue;
            }
            // Indentation dropped back to column 0: close this block and process current line.
            block.merge_into(&mut merged);
        }

        if trimmed.is_empty() || trimmed == "---" || trimmed == "..." {
            continue;
        }

        let leading_spaces = line.len() - line.trim_start_matches(' ').len();
        if leading_spaces == 0 && is_planning_header(trimmed) {
            let rest = trimmed["planning:".len()..].trim();
            if !rest.is_empty() {
                return Err(fail(
                    format!(
                        "PLANNING_CONFIG_INVALID: 'planning:' must start a YAML mapping block, got 'planning: {rest}'"
                    ),
                    1,
                ));
            }
            found_section = true;
            active_block = Some(ActivePlanningBlock::default());
        }
    }

    if let Some(block) = active_block {
        block.merge_into(&mut merged);
    }

    if found_section {
        Ok(Some(merged))
    } else {
        Ok(None)
    }
}

/// Resolves planning preferences with strict validation.
///
/// Precedence: `invocation > project > global > defaults`. Missing files are ignored;
/// unreadable or malformed files, or invalid invocation values, return `Err(B3Error)`.
pub fn resolve_planning_config(
    project_path: Option<&Path>,
    global_path: Option<&Path>,
    invocation: Option<PlanningConfigOverride>,
) -> Result<PlanningConfig, B3Error> {
    if let Some(ref ov) = invocation {
        validate_override(ov)?;
    }
    let project = match project_path {
        Some(path) => read_optional_override(path)?,
        None => None,
    };
    let global = match global_path {
        Some(path) => read_optional_override(path)?,
        None => None,
    };

    Ok(merge_overrides(invocation, project, global))
}

/// Resolves planning preferences with graceful fallback.
///
/// Precedence: `invocation > project > global > defaults`. Missing files are silently
/// ignored; malformed or unreadable files and out-of-range overrides record a warning
/// and fall back safely to the next valid layer or built-in defaults.
pub fn resolve_planning_config_graceful(
    project_path: Option<&Path>,
    global_path: Option<&Path>,
    invocation: Option<PlanningConfigOverride>,
) -> (PlanningConfig, Vec<String>) {
    let mut warnings = Vec::new();

    let clean_invocation = invocation.map(|mut ov| {
        if let Some(threshold) = ov.understanding_threshold {
            if let Err(err) = validate_threshold(i64::from(threshold)) {
                warnings.push(format!("invocation override ignored: {err}"));
                ov.understanding_threshold = None;
            }
        }
        ov
    });

    let project = project_path.and_then(|path| match read_optional_override(path) {
        Ok(ov) => ov,
        Err(err) => {
            warnings.push(format!(
                "ignoring malformed or unreadable project planning config {}: {err}",
                path.display()
            ));
            None
        }
    });

    let global = global_path.and_then(|path| match read_optional_override(path) {
        Ok(ov) => ov,
        Err(err) => {
            warnings.push(format!(
                "ignoring malformed or unreadable global planning config {}: {err}",
                path.display()
            ));
            None
        }
    });

    (merge_overrides(clean_invocation, project, global), warnings)
}

#[derive(Default)]
struct ActivePlanningBlock {
    child_indent: Option<usize>,
    seen_clarification_gate: bool,
    seen_understanding_threshold: bool,
    clarification_gate: Option<bool>,
    understanding_threshold: Option<u8>,
}

impl ActivePlanningBlock {
    fn parse_child_line(&mut self, indent: usize, trimmed: &str) -> Result<(), B3Error> {
        match self.child_indent {
            Some(expected) if indent != expected => {
                return Err(fail(
                    format!(
                        "PLANNING_CONFIG_INVALID: inconsistent indentation inside 'planning:' block (expected {expected} spaces, got {indent})"
                    ),
                    1,
                ));
            }
            None => self.child_indent = Some(indent),
            _ => {}
        }

        let (raw_key, raw_val) = trimmed.split_once(':').ok_or_else(|| {
            fail(
                format!(
                    "PLANNING_CONFIG_INVALID: expected 'key: value' inside 'planning:' block, got '{trimmed}'"
                ),
                1,
            )
        })?;
        let key = raw_key.trim();
        let val = raw_val.trim();

        match key {
            "clarification_gate" => {
                if self.seen_clarification_gate {
                    return Err(fail(
                        "PLANNING_CONFIG_INVALID: duplicate key 'clarification_gate' in 'planning:' block",
                        1,
                    ));
                }
                self.seen_clarification_gate = true;
                self.clarification_gate = Some(parse_strict_bool(val)?);
            }
            "understanding_threshold" => {
                if self.seen_understanding_threshold {
                    return Err(fail(
                        "PLANNING_CONFIG_INVALID: duplicate key 'understanding_threshold' in 'planning:' block",
                        1,
                    ));
                }
                self.seen_understanding_threshold = true;
                self.understanding_threshold = Some(parse_strict_threshold(val)?);
            }
            _ => {
                return Err(fail(
                    format!("PLANNING_CONFIG_INVALID: unknown key '{key}' in 'planning:' block"),
                    1,
                ));
            }
        }

        Ok(())
    }

    fn merge_into(self, target: &mut PlanningConfigOverride) {
        if let Some(gate) = self.clarification_gate {
            target.clarification_gate = Some(gate);
        }
        if let Some(threshold) = self.understanding_threshold {
            target.understanding_threshold = Some(threshold);
        }
    }
}

fn read_optional_override(path: &Path) -> Result<Option<PlanningConfigOverride>, B3Error> {
    let content = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(err) if err.kind() == ErrorKind::NotFound => return Ok(None),
        Err(err) => {
            return Err(fail(
                format!(
                    "PLANNING_CONFIG_READ_FAIL: cannot read {}: {err}",
                    path.display()
                ),
                1,
            ));
        }
    };
    parse_planning_config_from_markdown(&content)
}

fn merge_overrides(
    invocation: Option<PlanningConfigOverride>,
    project: Option<PlanningConfigOverride>,
    global: Option<PlanningConfigOverride>,
) -> PlanningConfig {
    let clarification_gate = invocation
        .and_then(|o| o.clarification_gate)
        .or_else(|| project.and_then(|o| o.clarification_gate))
        .or_else(|| global.and_then(|o| o.clarification_gate))
        .unwrap_or(DEFAULT_CLARIFICATION_GATE);
    let understanding_threshold = invocation
        .and_then(|o| o.understanding_threshold)
        .or_else(|| project.and_then(|o| o.understanding_threshold))
        .or_else(|| global.and_then(|o| o.understanding_threshold))
        .unwrap_or(DEFAULT_UNDERSTANDING_THRESHOLD);
    PlanningConfig {
        clarification_gate,
        understanding_threshold,
    }
}

fn parse_strict_bool(val: &str) -> Result<bool, B3Error> {
    match val {
        "true" => Ok(true),
        "false" => Ok(false),
        "" => Err(fail(
            "PLANNING_CONFIG_INVALID: clarification_gate cannot be empty; expected true or false",
            1,
        )),
        _ => Err(fail(
            format!(
                "PLANNING_CONFIG_INVALID: clarification_gate must be strictly true or false, got '{val}'"
            ),
            1,
        )),
    }
}

fn parse_strict_threshold(val: &str) -> Result<u8, B3Error> {
    if val.is_empty() {
        return Err(fail(
            "PLANNING_CONFIG_INVALID: understanding_threshold cannot be empty; expected integer 1..=100",
            1,
        ));
    }
    if val.starts_with('+') {
        return Err(fail(
            format!(
                "PLANNING_CONFIG_INVALID: understanding_threshold must be an integer 1..=100, got '{val}'"
            ),
            1,
        ));
    }
    let parsed = val.parse::<i64>().map_err(|_| {
        fail(
            format!(
                "PLANNING_CONFIG_INVALID: understanding_threshold must be an integer 1..=100, got '{val}'"
            ),
            1,
        )
    })?;
    validate_threshold(parsed)
}

fn is_planning_header(trimmed: &str) -> bool {
    if let Some(after) = trimmed.strip_prefix("planning:") {
        after.is_empty() || after.starts_with(char::is_whitespace)
    } else {
        false
    }
}

fn strip_inline_comment(line: &str) -> &str {
    let mut in_single = false;
    let mut in_double = false;
    let mut escaped = false;
    let bytes = line.as_bytes();

    for (idx, ch) in line.char_indices() {
        if in_double {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_double = false;
            }
            continue;
        }
        if in_single {
            if ch == '\'' {
                in_single = false;
            }
            continue;
        }
        match ch {
            '"' => in_double = true,
            '\'' => in_single = true,
            '#' if idx == 0 || bytes[idx - 1] == b' ' || bytes[idx - 1] == b'\t' => {
                return &line[..idx];
            }
            _ => {}
        }
    }
    line
}

fn parse_opening_fence(trimmed: &str) -> Option<(char, usize, bool)> {
    let first = trimmed.chars().next()?;
    if first != '`' && first != '~' {
        return None;
    }
    let fence_len = trimmed.chars().take_while(|&c| c == first).count();
    if fence_len < 3 {
        return None;
    }
    let info = trimmed[fence_len..].trim();
    if first == '`' && info.contains('`') {
        return None;
    }
    let lang = info.split_whitespace().next().unwrap_or("");
    let is_yaml_or_untyped =
        lang.is_empty() || lang.eq_ignore_ascii_case("yaml") || lang.eq_ignore_ascii_case("yml");
    Some((first, fence_len, is_yaml_or_untyped))
}

fn is_closing_fence(trimmed: &str, fence_ch: char, fence_len: usize) -> bool {
    let count = trimmed.chars().take_while(|&c| c == fence_ch).count();
    count >= fence_len && trimmed[count..].trim().is_empty()
}
