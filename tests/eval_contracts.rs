//! Executable contracts migrating `scripts/validate-evals.sh`, guarding
//! always-on context budgets & keyword isolation, validating all 14 command +
//! command-skill contracts, and exercising native `b3` orchestration invariants.

mod common;

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use common::{git_in, init_fresh_git_repo, repo_root, run_b3, run_b3_env, write_lf, TempDirGuard};

const EXPECTED_EVAL_CATEGORIES: &[&str] = &[
    "skills",
    "agents",
    "review-loop",
    "workflows",
    "commands",
    "rules",
];

const EXPECTED_COMMANDS: &[&str] = &[
    "b3-audit",
    "b3-debug",
    "b3-implement",
    "b3-plan",
    "b3-pr-comment",
    "b3-pr-reply",
    "b3-pr-resolve",
    "b3-refactor",
    "b3-research",
    "b3-research-ship",
    "b3-review",
    "b3-review-loop",
    "b3-ship",
    "b3-verify",
];

const EXPECTED_NEW_ORCHESTRATION_EVALS: &[&str] = &[
    "evals/workflows/orchestration/inline-simple-task.yaml",
    "evals/workflows/orchestration/concurrent-independent-tasks.yaml",
    "evals/workflows/orchestration/dependency-pruning-wait.yaml",
    "evals/workflows/orchestration/continuous-unblocked-dispatch.yaml",
    "evals/workflows/orchestration/shared-read-only-no-worktree.yaml",
    "evals/workflows/orchestration/shared-disjoint-writes.yaml",
    "evals/workflows/orchestration/conflicting-writes-isolated-or-serialized.yaml",
    "evals/workflows/orchestration/external-pr-single-writer.yaml",
    "evals/workflows/orchestration/partial-worker-failure-isolation.yaml",
    "evals/workflows/orchestration/stale-evidence-rejected.yaml",
    "evals/workflows/orchestration/host-limitation-sequential-fallback.yaml",
    "evals/workflows/orchestration/resource-contention-adaptive-throttle.yaml",
    "evals/workflows/orchestration/avoid-duplicate-investigations.yaml",
    "evals/workflows/orchestration/independent-reviewers-preserved.yaml",
    "evals/workflows/orchestration/abcde-continuous-release.yaml",
    "evals/workflows/orchestration/cross-wave-write-conflict.yaml",
    "evals/workflows/orchestration/cross-wave-rw-conflict.yaml",
    "evals/workflows/orchestration/concurrency-slot-saturation.yaml",
    "evals/workflows/orchestration/isolated-output-unintegrated-gate.yaml",
    "evals/workflows/orchestration/resume-mid-wave-active-workers.yaml",
    "evals/workflows/orchestration/task-decomposition-shared-prereq.yaml",
    "evals/workflows/orchestration/research-ship-parallel-disputed-isolation.yaml",
    "evals/commands/standalone-commands-scope-preserved.yaml",
    "evals/commands/all-commands-canonical-policy.yaml",
    "evals/commands/future-commands-inheritance.yaml",
    "evals/commands/b3-research-local-explanation-no-ship-state.yaml",
    "evals/commands/b3-research-preserves-missing-conflicting-evidence.yaml",
    "evals/commands/b3-audit-unchanged-file-empty-diff.yaml",
    "evals/commands/b3-audit-missing-target-or-incomplete-coverage.yaml",
    "evals/commands/b3-refactor-preserves-behavior.yaml",
    "evals/commands/b3-refactor-cleanup-preserves-intentional-complexity.yaml",
    "evals/commands/b3-refactor-optimize-measured-guidance.yaml",
    "evals/commands/daily-commands-canonical-wrapper-parity.yaml",
];

const EXPECTED_HOOK_EVALS: &[&str] = &[
    "evals/workflows/hooks/tier0-fast-containment.yaml",
    "evals/workflows/hooks/tier1-canonical-precommit-reuse.yaml",
    "evals/workflows/hooks/disabled-preserves-workflow-guards.yaml",
    "evals/workflows/hooks/audit-mode-non-blocking.yaml",
    "evals/workflows/hooks/host-protocol-honesty-and-fallback.yaml",
    "evals/workflows/hooks/opt-in-install-preserves-user-hooks.yaml",
    "evals/workflows/hooks/recursion-and-parallel-isolation.yaml",
    "evals/workflows/hooks/clarification-boundary-separation.yaml",
];

const EXPECTED_STATIC_ANALYSIS_EVALS: &[&str] = &[
    "evals/workflows/static-analysis/01-project-lint-discovery-and-reuse.yaml",
    "evals/workflows/static-analysis/02-no-lint-fallback-and-explicit-bootstrap.yaml",
    "evals/workflows/static-analysis/03-dead-code-levels-and-prod-consumer.yaml",
    "evals/workflows/static-analysis/04-unused-deps-duplicates-and-complexity.yaml",
    "evals/workflows/static-analysis/05-security-and-boundary-offloading.yaml",
    "evals/workflows/static-analysis/06-scoped-safe-autofix-and-verify-stale.yaml",
    "evals/workflows/static-analysis/07-baseline-regression-attribution.yaml",
    "evals/workflows/static-analysis/08-workflow-only-hook-and-guard-boundary.yaml",
];

const EXPECTED_CLARIFICATION_EVALS: &[&str] = &[
    "evals/workflows/clarification/enabled-clear-proceeds.yaml",
    "evals/workflows/clarification/enabled-below-96-asks.yaml",
    "evals/workflows/clarification/enabled-exact-96-proceeds.yaml",
    "evals/workflows/clarification/critical-ambiguity-blocks-regardless-of-score.yaml",
    "evals/workflows/clarification/discoverable-info-no-question.yaml",
    "evals/workflows/clarification/disabled-mode-documented-assumptions.yaml",
    "evals/workflows/clarification/disabled-mode-preserves-mandatory-auth.yaml",
    "evals/workflows/clarification/partial-ambiguity-parallel-safe-workstreams.yaml",
    "evals/workflows/clarification/user-clarification-releases-dependents.yaml",
    "evals/workflows/clarification/execution-reassessment-targeted-invalidation.yaml",
    "evals/workflows/clarification/simple-task-lightweight.yaml",
    "evals/workflows/clarification/all-commands-inherit-policy.yaml",
    "evals/workflows/clarification/config-precedence-resolution.yaml",
    "evals/workflows/clarification/unsupported-host-graceful-degradation.yaml",
    "evals/workflows/clarification/no-duplicate-clarification-implementation.yaml",
    "evals/workflows/clarification/low-score-no-material-ambiguity-proceeds.yaml",
    "evals/workflows/clarification/parent-consolidates-worker-uncertainties.yaml",
];

fn normalize_lf(raw: &str) -> String {
    raw.replace("\r\n", "\n")
}

fn rel_slash(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .expect("path inside root")
        .to_string_lossy()
        .replace('\\', "/")
}

fn collect_eval_files(
    dir: &Path,
    evals_root: &Path,
    yaml_files: &mut Vec<PathBuf>,
    readme_files: &mut Vec<PathBuf>,
    errors: &mut Vec<String>,
) {
    let mut entries: Vec<_> = match fs::read_dir(dir) {
        Ok(rd) => rd.filter_map(Result::ok).collect(),
        Err(e) => {
            errors.push(format!("cannot read dir {}: {e}", dir.display()));
            return;
        }
    };
    entries.sort_by_key(|e| e.file_name());

    for entry in entries {
        let path = entry.path();
        let meta = match fs::symlink_metadata(&path) {
            Ok(m) => m,
            Err(e) => {
                errors.push(format!("cannot stat {}: {e}", path.display()));
                continue;
            }
        };
        if meta.file_type().is_symlink() || b3::fs::is_reparse_or_symlink(&path) {
            errors.push(format!(
                "unexpected symlink/reparse point under evals/: {}",
                rel_slash(evals_root, &path)
            ));
            continue;
        }
        if meta.is_dir() {
            collect_eval_files(&path, evals_root, yaml_files, readme_files, errors);
        } else if meta.is_file() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if name_str == "README.md" {
                readme_files.push(path);
            } else if name_str.ends_with(".yaml") {
                yaml_files.push(path);
            } else {
                errors.push(format!(
                    "unexpected non-.yaml/non-README.md file under evals/: {}",
                    rel_slash(evals_root, &path)
                ));
            }
        } else {
            errors.push(format!(
                "unexpected filesystem entry under evals/: {}",
                rel_slash(evals_root, &path)
            ));
        }
    }
}

fn strip_unquoted_comment(raw: &str) -> &str {
    let trimmed = raw.trim_start();
    if trimmed.starts_with('#') {
        return "";
    }
    let bytes = trimmed.as_bytes();
    for (idx, &b) in bytes.iter().enumerate() {
        if b == b'#' && idx > 0 && bytes[idx - 1].is_ascii_whitespace() {
            return trimmed[..idx].trim_end();
        }
    }
    trimmed.trim_end()
}

fn parse_single_line_yaml_scalar(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return Ok(String::new());
    }
    let first = trimmed.as_bytes()[0];
    if first == b'"' || first == b'\'' {
        let quote = first as char;
        let mut out = String::new();
        let mut chars = trimmed[1..].chars().peekable();
        let mut closed = false;
        while let Some(ch) = chars.next() {
            if quote == '"' {
                if ch == '\\' {
                    if let Some(esc) = chars.next() {
                        match esc {
                            'n' => out.push('\n'),
                            'r' => out.push('\r'),
                            't' => out.push('\t'),
                            '"' => out.push('"'),
                            '\\' => out.push('\\'),
                            other => {
                                out.push('\\');
                                out.push(other);
                            }
                        }
                    } else {
                        return Err(format!("unterminated escape in double-quoted value: {raw}"));
                    }
                    continue;
                }
                if ch == '"' {
                    closed = true;
                    break;
                }
            } else if ch == '\'' {
                if chars.peek() == Some(&'\'') {
                    chars.next();
                    out.push('\'');
                    continue;
                }
                closed = true;
                break;
            }
            out.push(ch);
        }
        if !closed {
            return Err(format!("unmatched {quote} quote in scalar: {raw}"));
        }
        let remainder: String = chars.collect();
        let rem_trimmed = remainder.trim();
        if !rem_trimmed.is_empty() && !rem_trimmed.starts_with('#') {
            return Err(format!("unexpected trailing tokens after quote: {raw}"));
        }
        return Ok(out.trim().to_string());
    }
    Ok(strip_unquoted_comment(trimmed).trim().to_string())
}

fn is_block_scalar_header(raw: &str) -> Option<bool> {
    let no_comment = strip_unquoted_comment(raw).trim();
    match no_comment {
        "|" | "|-" | "|+" => Some(false),
        ">" | ">-" | ">+" => Some(true),
        _ => None,
    }
}

fn finish_block_scalar(folded: bool, lines: &[String]) -> String {
    let min_indent = lines
        .iter()
        .filter(|l| !l.trim().is_empty())
        .map(|l| l.len() - l.trim_start_matches([' ', '\t']).len())
        .min()
        .unwrap_or(0);

    let stripped: Vec<&str> = lines
        .iter()
        .map(|l| {
            if l.trim().is_empty() {
                ""
            } else {
                &l[min_indent.min(l.len())..]
            }
        })
        .collect();

    let joined = if folded {
        stripped
            .into_iter()
            .map(str::trim)
            .collect::<Vec<_>>()
            .join(" ")
    } else {
        stripped.join("\n")
    };
    joined.trim().to_string()
}

fn parse_eval_yaml_scalars(raw: &str) -> Result<BTreeMap<String, String>, String> {
    let text = normalize_lf(raw);
    let mut map: BTreeMap<String, String> = BTreeMap::new();
    let mut block: Option<(String, bool, Vec<String>)> = None;

    for line in text.lines() {
        if let Some((ref key, folded, ref mut acc)) = block {
            if line.trim().is_empty() || line.starts_with(' ') || line.starts_with('\t') {
                acc.push(line.to_string());
                continue;
            }
            let finished = finish_block_scalar(folded, acc);
            map.entry(key.clone()).or_insert(finished);
            block = None;
        }

        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if line.starts_with(' ') || line.starts_with('\t') {
            continue;
        }
        let Some((raw_key, raw_val)) = line.split_once(':') else {
            continue;
        };
        let key = raw_key.trim();
        if key.is_empty()
            || !key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            continue;
        }
        if let Some(folded) = is_block_scalar_header(raw_val) {
            block = Some((key.to_string(), folded, Vec::new()));
        } else {
            let val = parse_single_line_yaml_scalar(raw_val)?;
            map.entry(key.to_string()).or_insert(val);
        }
    }

    if let Some((key, folded, acc)) = block {
        let finished = finish_block_scalar(folded, &acc);
        map.entry(key).or_insert(finished);
    }

    Ok(map)
}

fn is_unsafe_artifact_path(artifact: &str) -> bool {
    if artifact.starts_with('/') || artifact.contains('\\') {
        return true;
    }
    let bytes = artifact.as_bytes();
    if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        return true;
    }
    artifact.split('/').any(|seg| seg == "..")
}

fn find_pascal_case_cli_flag(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    for i in 0..bytes.len() {
        if bytes[i] != b'-' {
            continue;
        }
        let prev_ok = i == 0
            || bytes[i - 1].is_ascii_whitespace()
            || matches!(bytes[i - 1], b'(' | b'`' | b'"' | b'\'' | b'/');
        if !prev_ok || i + 2 >= bytes.len() {
            continue;
        }
        if bytes[i + 1].is_ascii_uppercase() && bytes[i + 2].is_ascii_lowercase() {
            let mut end = i + 3;
            while end < bytes.len() && bytes[end].is_ascii_alphanumeric() {
                end += 1;
            }
            return Some(text[i..end].to_string());
        }
    }
    None
}

fn contains_legacy_script_ref(text: &str) -> Option<&'static str> {
    [
        "b3-guard",
        "b3-pr-github",
        "validate-evals.sh",
        "validate-standalone-commands.ps1",
        "validate-pr-feedback.ps1",
        "validate-tshirt-hierarchical.ps1",
        "validate-merge-security.sh",
        "validate-ship-behavior.ps1",
        "validate-context-routing.ps1",
        "validate-research-ship.ps1",
        "smoke-ship-product.ps1",
        "<=4 concurrent workers",
    ]
    .into_iter()
    .find(|&pat| text.contains(pat))
}

fn extract_skill_frontmatter(raw: &str) -> Option<String> {
    let lf = normalize_lf(raw);
    let rest = lf.strip_prefix("---\n")?;
    let end = rest.find("\n---")?;
    let tail = &rest[end + 4..];
    if tail.is_empty() || tail.starts_with('\n') {
        Some(rest[..end].to_string())
    } else {
        None
    }
}

fn contains_forbidden_always_on_routing_keyword(text: &str) -> Option<&'static str> {
    let lower = text.to_ascii_lowercase();
    [
        "context-routing.md",
        "context-cache",
        "codebase-memory",
        "codebase memory",
        "serena",
    ]
    .into_iter()
    .find(|&pat| lower.contains(pat))
}

fn collect_skill_md_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let mut entries: Vec<_> = fs::read_dir(dir)
        .expect("read skill dir")
        .filter_map(Result::ok)
        .collect();
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        let p = entry.path();
        let meta = fs::symlink_metadata(&p).expect("stat skill path");
        if meta.file_type().is_symlink() {
            continue;
        }
        if meta.is_dir() {
            collect_skill_md_files(&p, out);
        } else if meta.is_file() && entry.file_name() == "SKILL.md" {
            out.push(p);
        }
    }
}

#[test]
fn eval_fixtures_schema_uniqueness_and_artifact_safety() {
    let root = repo_root();
    let canon_root = fs::canonicalize(&root).expect("canonicalize repo_root");
    let evals_dir = root.join("evals");
    assert!(
        evals_dir.is_dir(),
        "evals directory missing: {}",
        evals_dir.display()
    );

    let mut errors: Vec<String> = Vec::new();
    let mut top_dirs = BTreeSet::new();
    for entry in fs::read_dir(&evals_dir).expect("read evals dir") {
        let entry = entry.expect("evals dir entry");
        let p = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        let meta = fs::symlink_metadata(&p).expect("stat top-level eval entry");
        if meta.file_type().is_symlink() || b3::fs::is_reparse_or_symlink(&p) {
            errors.push(format!("top-level eval entry cannot be symlink: {name}"));
        } else if meta.is_dir() {
            if !EXPECTED_EVAL_CATEGORIES.contains(&name.as_str()) {
                errors.push(format!("unknown top-level eval category directory: {name}"));
            }
            top_dirs.insert(name);
        } else if meta.is_file() && name != "README.md" {
            errors.push(format!("unexpected top-level file in evals/: {name}"));
        }
    }

    for &cat in EXPECTED_EVAL_CATEGORIES {
        if !top_dirs.contains(cat) {
            errors.push(format!("missing required eval category directory: {cat}"));
        }
    }

    let mut yaml_files = Vec::new();
    let mut readme_files = Vec::new();
    collect_eval_files(
        &evals_dir,
        &evals_dir,
        &mut yaml_files,
        &mut readme_files,
        &mut errors,
    );

    let mut category_counts: BTreeMap<&str, usize> =
        EXPECTED_EVAL_CATEGORIES.iter().map(|&c| (c, 0)).collect();
    let mut seen_ids: BTreeMap<String, String> = BTreeMap::new();

    for path in &yaml_files {
        let rel_eval = rel_slash(&evals_dir, path);
        let rel_repo = rel_slash(&root, path);
        let raw = match fs::read_to_string(path) {
            Ok(s) => s,
            Err(e) => {
                errors.push(format!("{rel_repo}: failed to read: {e}"));
                continue;
            }
        };

        if let Some(legacy) = contains_legacy_script_ref(&raw) {
            errors.push(format!(
                "{rel_repo}: contains stale legacy reference '{legacy}'"
            ));
        }
        if let Some(pascal_flag) = find_pascal_case_cli_flag(&raw) {
            errors.push(format!(
                "{rel_repo}: contains stale PascalCase CLI flag '{pascal_flag}'"
            ));
        }

        let scalars = match parse_eval_yaml_scalars(&raw) {
            Ok(m) => m,
            Err(e) => {
                errors.push(format!("{rel_repo}: YAML parse error: {e}"));
                continue;
            }
        };

        let require_non_empty = |key: &str, errs: &mut Vec<String>| -> Option<String> {
            match scalars.get(key) {
                None => {
                    errs.push(format!("{rel_repo}: missing required key '{key}'"));
                    None
                }
                Some(v) if v.trim().is_empty() => {
                    errs.push(format!("{rel_repo}: empty value for required key '{key}'"));
                    None
                }
                Some(v) => Some(v.trim().to_string()),
            }
        };

        if let Some(id_val) = require_non_empty("id", &mut errors) {
            if let Some(prev) = seen_ids.get(&id_val) {
                errors.push(format!(
                    "{rel_repo}: duplicate id '{id_val}' (already seen in {prev})"
                ));
            } else {
                seen_ids.insert(id_val, rel_repo.clone());
            }
        }

        let artifact_opt = require_non_empty("artifact", &mut errors);
        let _ = require_non_empty("intent", &mut errors);

        let category = rel_eval.split('/').next().unwrap_or("");
        match category {
            "skills" | "agents" => {
                let _ = require_non_empty("expected_bucket", &mut errors);
                *category_counts.get_mut(category).unwrap() += 1;
            }
            "review-loop" | "workflows" | "commands" | "rules" => {
                let _ = require_non_empty("expected_outcome", &mut errors);
                *category_counts.get_mut(category).unwrap() += 1;
            }
            other => {
                errors.push(format!("{rel_repo}: unknown eval category '{other}'"));
            }
        }

        if let Some(artifact) = artifact_opt {
            if is_unsafe_artifact_path(&artifact) {
                errors.push(format!("{rel_repo}: unsafe artifact path '{artifact}'"));
            } else {
                let target = root.join(artifact.replace('/', std::path::MAIN_SEPARATOR_STR));
                let meta = fs::symlink_metadata(&target);
                match meta {
                    Ok(m)
                        if m.is_file()
                            && !m.file_type().is_symlink()
                            && !b3::fs::is_reparse_or_symlink(&target) =>
                    {
                        match fs::canonicalize(&target) {
                            Ok(canon_target) => {
                                if !canon_target.starts_with(&canon_root) {
                                    errors.push(format!(
                                        "{rel_repo}: artifact escapes repo_root: '{artifact}'"
                                    ));
                                }
                            }
                            Err(e) => {
                                errors.push(format!(
                                    "{rel_repo}: cannot canonicalize artifact '{artifact}': {e}"
                                ));
                            }
                        }
                    }
                    _ => {
                        errors.push(format!(
                            "{rel_repo}: artifact is not a regular contained file: '{artifact}'"
                        ));
                    }
                }
            }
        }
    }

    for readme in &readme_files {
        let rel_repo = rel_slash(&root, readme);
        let raw = fs::read_to_string(readme).expect("read eval README.md");
        if let Some(legacy) = contains_legacy_script_ref(&raw) {
            errors.push(format!(
                "{rel_repo}: README contains stale legacy reference '{legacy}'"
            ));
        }
        if let Some(pascal_flag) = find_pascal_case_cli_flag(&raw) {
            errors.push(format!(
                "{rel_repo}: README contains stale PascalCase flag '{pascal_flag}'"
            ));
        }
    }

    for (&cat, &cnt) in &category_counts {
        if cnt == 0 {
            errors.push(format!("eval category '{cat}/' has 0 .yaml fixtures"));
        }
    }

    for expected_rel in EXPECTED_NEW_ORCHESTRATION_EVALS
        .iter()
        .chain(EXPECTED_CLARIFICATION_EVALS.iter())
        .chain(EXPECTED_HOOK_EVALS.iter())
        .chain(EXPECTED_STATIC_ANALYSIS_EVALS.iter())
    {
        let full = root.join(expected_rel.replace('/', std::path::MAIN_SEPARATOR_STR));
        if !full.is_file() {
            errors.push(format!(
                "missing required semantic orchestration/clarification/hook/static-analysis eval: {expected_rel}"
            ));
        }
    }

    assert!(
        !yaml_files.is_empty() && yaml_files.len() >= 371,
        "expected >= 371 eval fixtures, found {}",
        yaml_files.len()
    );
    assert!(
        errors.is_empty(),
        "eval validation failed with {} error(s):\n{}",
        errors.len(),
        errors.join("\n")
    );
}

#[test]
fn yaml_scalar_parser_handles_multiline_blocks_and_quotes() {
    let sample = "\
id: \"test-001\" # trailing comment
artifact: 'workflows/ship.md'
intent: |
  First line
  Second line
scenario: >-
  Folded line one
  line two
expected_outcome: PASS
";
    let parsed = parse_eval_yaml_scalars(sample).expect("parse sample yaml");
    assert_eq!(parsed.get("id").map(String::as_str), Some("test-001"));
    assert_eq!(
        parsed.get("artifact").map(String::as_str),
        Some("workflows/ship.md")
    );
    assert_eq!(
        parsed.get("intent").map(String::as_str),
        Some("First line\nSecond line")
    );
    assert_eq!(
        parsed.get("scenario").map(String::as_str),
        Some("Folded line one line two")
    );
    assert_eq!(
        parsed.get("expected_outcome").map(String::as_str),
        Some("PASS")
    );
}

fn assert_always_on_context_budget(root: &Path) {
    let root_str = root.to_str().expect("repo_root utf8");
    let (report, code) = b3::context::measure_context(root_str, true).expect("measure_context");
    assert_eq!(code, 0, "strict context budget failed:\n{report}");
    assert!(
        report.contains("warnings          : 0"),
        "expected zero context warnings:\n{report}"
    );

    let always_line = report
        .lines()
        .find(|l| l.starts_with("always_on_total"))
        .expect("always_on_total line");
    let after_colon = always_line.split(':').nth(1).expect("colon in line").trim();
    let bytes_str = after_colon.split_whitespace().next().expect("bytes number");
    let always_on_bytes: usize = bytes_str.parse().expect("parse always_on_total bytes");
    assert!(
        always_on_bytes <= 15_777,
        "always_on_total {always_on_bytes} B exceeds cap 15777 B:\n{report}"
    );
}

#[test]
fn always_on_context_budget_and_no_forbidden_routing_leaks() {
    let root = repo_root();
    assert_always_on_context_budget(&root);

    let agents_raw = fs::read_to_string(root.join("AGENTS.md")).expect("read AGENTS.md");
    assert_eq!(
        contains_forbidden_always_on_routing_keyword(&agents_raw),
        None,
        "AGENTS.md leaked forbidden context-routing/MCP keyword"
    );

    for entry in fs::read_dir(root.join("rules")).expect("read rules/") {
        let p = entry.expect("rule entry").path();
        if p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("md") {
            let raw = fs::read_to_string(&p).expect("read rule file");
            assert_eq!(
                contains_forbidden_always_on_routing_keyword(&raw),
                None,
                "{} leaked forbidden context-routing/MCP keyword",
                rel_slash(&root, &p)
            );
        }
    }

    let mut skill_files = Vec::new();
    collect_skill_md_files(&root.join("skills"), &mut skill_files);
    collect_skill_md_files(&root.join("adapters/command-skills"), &mut skill_files);
    assert_eq!(
        skill_files.len(),
        38,
        "expected 38 SKILL.md files (24 skills + 14 command-skills), found {}",
        skill_files.len()
    );

    for sf in skill_files {
        let raw = fs::read_to_string(&sf).expect("read SKILL.md");
        let fm = extract_skill_frontmatter(&raw)
            .unwrap_or_else(|| panic!("missing YAML frontmatter in {}", rel_slash(&root, &sf)));
        assert_eq!(
            contains_forbidden_always_on_routing_keyword(&fm),
            None,
            "{} frontmatter leaked forbidden context-routing/MCP keyword",
            rel_slash(&root, &sf)
        );
        for line in fm.lines() {
            if let Some(val) = line.strip_prefix("description:") {
                let v = val.trim();
                let quoted = (v.starts_with('"') && v.ends_with('"'))
                    || (v.starts_with('\'') && v.ends_with('\''))
                    || v == ">"
                    || v == "|";
                assert!(
                    quoted || !v.contains(": "),
                    "{} frontmatter description YAML must quote values containing ': '",
                    rel_slash(&root, &sf)
                );
            }
        }
    }
}

#[test]
fn commands_and_command_skills_canonical_contracts() {
    let root = repo_root();

    let mut cmd_names: Vec<String> = fs::read_dir(root.join("commands"))
        .expect("read commands/")
        .filter_map(Result::ok)
        .filter_map(|e| {
            let p = e.path();
            if p.is_file() && p.extension().and_then(|x| x.to_str()) == Some("md") {
                let stem = p.file_stem()?.to_string_lossy().into_owned();
                if stem != "README" {
                    return Some(stem);
                }
            }
            None
        })
        .collect();
    cmd_names.sort();
    assert_eq!(cmd_names, EXPECTED_COMMANDS, "commands/*.md mismatch");

    let mut cs_names: Vec<String> = fs::read_dir(root.join("adapters/command-skills"))
        .expect("read adapters/command-skills/")
        .filter_map(Result::ok)
        .filter_map(|e| {
            let p = e.path();
            if p.is_dir() && p.join("SKILL.md").is_file() {
                Some(e.file_name().to_string_lossy().into_owned())
            } else {
                None
            }
        })
        .collect();
    cs_names.sort();
    assert_eq!(
        cs_names, EXPECTED_COMMANDS,
        "adapters/command-skills/*/SKILL.md mismatch"
    );

    for name in EXPECTED_COMMANDS {
        let cmd_path = root.join("commands").join(format!("{name}.md"));
        let cs_path = root
            .join("adapters/command-skills")
            .join(name)
            .join("SKILL.md");

        for (label, path) in [("command", &cmd_path), ("command-skill", &cs_path)] {
            let raw = fs::read_to_string(path).expect("read command file");
            assert!(
                !raw.contains(".ps1") && !raw.contains(".sh"),
                "{label} {name} must not reference legacy .ps1/.sh wrappers"
            );
            assert!(
                !raw.contains("b3-guard") && !raw.contains("b3-pr-github"),
                "{label} {name} must not reference legacy b3-guard/b3-pr-github"
            );
            assert_eq!(
                find_pascal_case_cli_flag(&raw),
                None,
                "{label} {name} must not contain -PascalCase flags"
            );
            assert!(
                raw.contains("dispatch-naming.md"),
                "{label} {name} must reference dispatch-naming.md"
            );
            if let Some(fm) = extract_skill_frontmatter(&raw) {
                for line in fm.lines() {
                    if let Some(val) = line.strip_prefix("description:") {
                        let v = val.trim();
                        let quoted = (v.starts_with('"') && v.ends_with('"'))
                            || (v.starts_with('\'') && v.ends_with('\''))
                            || v == ">"
                            || v == "|";
                        assert!(
                            quoted || !v.contains(": "),
                            "{label} {name} description YAML must quote values containing ': '"
                        );
                    }
                }
            }
        }
    }

    let read_pair = |name: &str| -> (String, String) {
        let cmd = fs::read_to_string(root.join("commands").join(format!("{name}.md")))
            .expect("read command");
        let cs = fs::read_to_string(
            root.join("adapters/command-skills")
                .join(name)
                .join("SKILL.md"),
        )
        .expect("read command-skill");
        (cmd, cs)
    };

    let (plan_cmd, plan_cs) = read_pair("b3-plan");
    assert!(plan_cmd.contains("plan-only") && plan_cs.contains("plan-only"));
    assert!(
        !plan_cmd.contains("inline on `main`")
            && !plan_cs.contains("inline on `main`")
            && plan_cmd.contains("independent of parallelism")
            && plan_cs.contains("independent of parallelism")
            && plan_cmd.contains("never disabled by")
            && plan_cs.contains("never disabled by"),
        "b3-plan command and skill must decouple model routing from parallelism"
    );

    let (impl_cmd, impl_cs) = read_pair("b3-implement");
    assert!(impl_cmd.contains("do **not** eagerly load"));
    assert!(impl_cs.contains("skip `workflows/feature-implementation.md`"));
    assert!(impl_cmd.contains("/b3-review-loop") && impl_cmd.contains("/b3-ship"));

    let (dbg_cmd, dbg_cs) = read_pair("b3-debug");
    assert!(
        dbg_cmd.contains("debugging/SKILL.md")
            && dbg_cmd.contains("verification/SKILL.md")
            && dbg_cmd.contains("3 failed")
            && !dbg_cmd.contains("inline on `main`")
            && dbg_cmd.contains("independent of parallelism")
            && dbg_cmd.contains("never disabled by")
    );
    assert!(
        dbg_cs.contains("debugging/SKILL.md")
            && dbg_cs.contains("verification/SKILL.md")
            && dbg_cs.contains("3 failed")
            && !dbg_cs.contains("inline on `main`")
            && dbg_cs.contains("independent of parallelism")
            && dbg_cs.contains("never disabled by")
    );

    let (rev_cmd, rev_cs) = read_pair("b3-review");
    assert!(
        rev_cmd.contains("review-template.md")
            && rev_cmd.contains("code-review/SKILL.md")
            && rev_cmd.contains("single-pass")
    );
    assert!(
        rev_cs.contains("review-template.md")
            && rev_cs.contains("code-review/SKILL.md")
            && rev_cs.contains("single-pass")
    );

    let (rl_cmd, rl_cs) = read_pair("b3-review-loop");
    assert!(rl_cmd.contains("review-loop/strategy.md") && rl_cmd.contains(".b3/ship/review-loop/"));
    assert!(rl_cs.contains("review-loop/strategy.md") && rl_cs.contains(".b3/ship/review-loop/"));

    let strategy =
        fs::read_to_string(root.join("review-loop/strategy.md")).expect("read strategy.md");
    assert!(
        strategy.contains("SINGLE_AGENT_LIMIT")
            && strategy.contains("cannot emit `PASS` on `HIGH`/`CRITICAL`"),
        "review-loop/strategy.md must enforce SINGLE_AGENT_LIMIT blocking HIGH/CRITICAL PASS"
    );

    let (ship_cmd, _) = read_pair("b3-ship");
    assert!(ship_cmd.contains("SINGLE_AGENT_LIMIT") && ship_cmd.contains("workflows/ship.md"));

    let (ver_cmd, ver_cs) = read_pair("b3-verify");
    assert!(
        ver_cmd.contains("verify-run")
            && ver_cmd.contains("verify-check")
            && ver_cmd.contains("verification/SKILL.md")
    );
    assert!(
        ver_cs.contains("verify-run")
            && ver_cs.contains("verify-check")
            && ver_cs.contains("verification/SKILL.md")
    );

    let (res_cmd, res_cs) = read_pair("b3-research");
    for (label, body) in [
        ("command", res_cmd.as_str()),
        ("command-skill", res_cs.as_str()),
    ] {
        let low = body.to_ascii_lowercase();
        assert!(
            body.contains(".b3/research-ship/")
                && body.contains("research-engineering-patterns/SKILL.md")
                && body.contains("workflows/research-ship.md")
                && low.contains("read-only")
                && low.contains("stop when"),
            "b3-research {label} missing lightweight/read-only/routing boundaries"
        );
    }

    let (aud_cmd, aud_cs) = read_pair("b3-audit");
    for (label, body) in [
        ("command", aud_cmd.as_str()),
        ("command-skill", aud_cs.as_str()),
    ] {
        assert!(
            body.contains("references/baseline-audit.md")
                && body.contains("references/review-template.md")
                && body.contains("UNKNOWN / INCOMPLETE")
                && body.contains("EMPTY_DIFF")
                && body.contains("SINGLE_AGENT_LIMIT")
                && body.contains("verify-check")
                && body.contains("verify-run")
                && body.contains(".b3/"),
            "b3-audit {label} missing baseline-audit, strict read-only verify-check vs verify-run exclusion, or empty-diff/honesty contracts"
        );
    }
    let baseline_ref = fs::read_to_string(
        root.join("skills/engineering/code-review/references/baseline-audit.md"),
    )
    .expect("read baseline-audit.md");
    assert!(
        baseline_ref.contains("EMPTY_DIFF")
            && baseline_ref.contains("UNKNOWN / INCOMPLETE")
            && baseline_ref.contains("SINGLE_AGENT_LIMIT")
            && baseline_ref.contains("review-template.md")
            && baseline_ref.contains("**Allowed read-only verification & checks")
            && baseline_ref.contains("b3 guard verify-check")
            && baseline_ref.contains("**Disallowed artifact-creating operations")
            && baseline_ref.contains("never invoke `b3 guard verify-run`"),
        "baseline-audit.md missing strict read-only vs artifact-creating boundary"
    );

    let (ref_cmd, ref_cs) = read_pair("b3-refactor");
    for (label, body) in [
        ("command", ref_cmd.as_str()),
        ("command-skill", ref_cs.as_str()),
    ] {
        assert!(
            body.contains("problem-solving/SKILL.md")
                && body.contains("verification/SKILL.md")
                && body.contains("refactoring/SKILL.md")
                && body.contains("residue-checklist.md")
                && body.contains("INTENTIONAL COMPLEXITY")
                && body.contains("b3-performance-reviewer.md")
                && body.contains("/b3-audit")
                && body.contains("/b3-review-loop")
                && body.contains("/b3-ship"),
            "b3-refactor {label} missing refactor/cleanup/optimize routing or non-escalation contracts"
        );
    }

    for pr_cmd_name in ["b3-pr-resolve", "b3-pr-reply", "b3-pr-comment"] {
        let (c, s) = read_pair(pr_cmd_name);
        assert!(
            c.contains("pr-feedback/SKILL.md") && c.contains("PR_MUTATION_OWNER_REQUIRED"),
            "{pr_cmd_name} command missing pr-feedback/SKILL.md or PR_MUTATION_OWNER_REQUIRED"
        );
        assert!(
            s.contains("pr-feedback/SKILL.md") && s.contains("PR_MUTATION_OWNER_REQUIRED"),
            "{pr_cmd_name} command-skill missing pr-feedback/SKILL.md or PR_MUTATION_OWNER_REQUIRED"
        );
    }

    // Items B, E, H: proportional escalation, advisory vs blocker triage, anti-overengineering parity
    let ship_wf = fs::read_to_string(root.join("workflows/ship.md")).expect("read ship.md");
    assert!(
        !ship_wf.contains("`>=4` tasks"),
        "workflows/ship.md must not escalate to detailed purely on task count"
    );
    assert!(
        ship_wf.contains("SYMBOL_ADVISORY") && ship_wf.contains("MECHANICAL_ADVISORY"),
        "workflows/ship.md must distinguish advisory heuristic signals from confirmed blockers"
    );
    let rev_role =
        fs::read_to_string(root.join("agents/b3-reviewer.md")).expect("read b3-reviewer");
    let fix_role = fs::read_to_string(root.join("agents/b3-fixer.md")).expect("read b3-fixer");
    let arch_role =
        fs::read_to_string(root.join("agents/b3-architecture-reviewer.md")).expect("read arch");
    for (name, body) in [
        ("b3-reviewer", rev_role.as_str()),
        ("b3-fixer", fix_role.as_str()),
        ("b3-architecture-reviewer", arch_role.as_str()),
        ("review-loop/strategy", strategy.as_str()),
    ] {
        assert!(
            body.contains("INTENTIONAL COMPLEXITY"),
            "{name} must recognize INTENTIONAL COMPLEXITY consistently"
        );
    }
}

#[test]
fn b3_binary_adaptive_concurrency_partitioning_and_shared_read_only() {
    let tmp = TempDirGuard::new("eval-wave");
    let repo = &tmp.path;
    let base_sha = init_fresh_git_repo(repo);
    let r = repo.to_str().expect("repo utf8");

    // 1. Adaptive concurrency: 8 allowed, 65 rejected
    let (c8, out8, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--wave-specs",
        "T001=src/a.txt;T002=src/b.txt",
        "--partition",
        "--max-concurrency",
        "8",
    ]);
    assert_eq!(c8, 0, "max-concurrency 8 failed: {out8}");
    assert!(out8.contains("max_concurrency=8"), "out={out8}");
    assert!(
        out8.contains("wave|1|PARALLEL|agents=2|tasks=T001,T002"),
        "out={out8}"
    );

    let (c65, out65, err65) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--wave-specs",
        "T001=src/a.txt;T002=src/b.txt",
        "--partition",
        "--max-concurrency",
        "65",
    ]);
    assert_eq!(
        c65, 1,
        "max-concurrency 65 must fail: out={out65} err={err65}"
    );
    let combined65 = format!("{out65}\n{err65}");
    assert!(
        combined65.contains("--max-concurrency must be between 1 and 64"),
        "combined={combined65}"
    );

    // 2. Continuous ready-task partitioning: independent + conflicting + bounded split
    let (c_part, out_part, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--wave-specs",
        "T001=src/a.txt;T002=docs/guide.md;T003=src/a.txt",
        "--expected-base-sha",
        &base_sha,
        "--partition",
    ]);
    assert_eq!(c_part, 0, "partition failed: {out_part}");
    assert!(
        out_part.contains("wave|1|PARALLEL|agents=2|tasks=T001,T002"),
        "out={out_part}"
    );
    assert!(
        out_part.contains("wave|2|SEQUENTIAL|agents=1|tasks=T003|reason=shared_write_conflict"),
        "out={out_part}"
    );
    assert!(out_part.contains("WAVE_PARTITIONED:"), "out={out_part}");

    // 3. SHARED_READ_ONLY (TaskId=none / []) with overlapping --wave-reads
    let (c_ro, out_ro, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--wave-specs",
        "R001=none;R002=[]",
        "--wave-reads",
        "R001=src/app.txt;R002=src/app.txt",
        "--partition",
    ]);
    assert_eq!(c_ro, 0, "SHARED_READ_ONLY failed: {out_ro}");
    assert!(
        out_ro.contains("wave|1|PARALLEL|agents=2|tasks=R001,R002"),
        "out={out_ro}"
    );
    assert!(
        out_ro.contains("WAVE_OK: disjoint (2 tasks, 0 paths)"),
        "out={out_ro}"
    );

    // Mixed reader/writer triggers rw conflict
    let (c_rw, out_rw, err_rw) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--wave-specs",
        "W001=src/app.txt;R001=none",
        "--wave-reads",
        "R001=src/app.txt",
        "--partition",
    ]);
    assert_eq!(
        c_rw, 2,
        "RW conflict expected exit 2: out={out_rw} err={err_rw}"
    );
    assert!(
        out_rw.contains("conflicts=rw:src/app.txt(W001->R001)"),
        "out={out_rw}"
    );
}

#[test]
fn b3_binary_mechanical_check_partial_failure_and_protected_paths() {
    let tmp = TempDirGuard::new("eval-mech");
    let repo = &tmp.path;
    let base_sha = init_fresh_git_repo(repo);
    let r = repo.to_str().expect("repo utf8");

    write_lf(&repo.join("src/a.txt"), "edited a\n");

    // Missing T002 in --worker-changes reports PARTIAL_ATTRIBUTION without losing T001
    let (c_partial, out_partial, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &base_sha,
        "--allowed-paths",
        "src/a.txt,src/b.txt",
        "--wave-specs",
        "T001=src/a.txt;T002=src/b.txt",
        "--worker-changes",
        "T001=src/a.txt",
    ]);
    assert_eq!(
        c_partial, 2,
        "partial attribution must exit 2: {out_partial}"
    );
    assert!(
        out_partial.contains("ownership_verification=PARTIAL_ATTRIBUTION"),
        "out={out_partial}"
    );
    assert!(
        out_partial.contains("ownership_violations=T002(missing_worker)"),
        "out={out_partial}"
    );

    // Protected path declared in worker scope is rejected (exit 1 MECHANICAL_FAIL)
    write_lf(&repo.join("ledger/state.md"), "tamper\n");
    let (c_prot_decl, out_prot_decl, err_prot_decl) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &base_sha,
        "--allowed-paths",
        "src/a.txt,ledger/state.md",
        "--wave-specs",
        "T001=src/a.txt,ledger/state.md",
        "--worker-changes",
        "T001=src/a.txt,ledger/state.md",
        "--protected-paths",
        "ledger/state.md",
    ]);
    assert_eq!(
        c_prot_decl, 1,
        "protected path declared in wave-specs must exit 1: out={out_prot_decl} err={err_prot_decl}"
    );
    let combined_prot_decl = format!("{out_prot_decl}\n{err_prot_decl}");
    assert!(
        combined_prot_decl.contains("MECHANICAL_FAIL: protected path 'ledger/state.md'"),
        "combined={combined_prot_decl}"
    );

    // Protected path modified outside declared scope triggers protected_violations + VIOLATION (exit 2)
    let (c_prot, out_prot, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &base_sha,
        "--allowed-paths",
        "src/a.txt",
        "--wave-specs",
        "T001=src/a.txt",
        "--worker-changes",
        "T001=src/a.txt",
        "--protected-paths",
        "ledger/state.md",
    ]);
    assert_eq!(c_prot, 2, "protected path must exit 2: {out_prot}");
    assert!(
        out_prot.contains("protected_violations=ledger/state.md"),
        "out={out_prot}"
    );
    assert!(
        out_prot.contains("ownership_verification=VIOLATION"),
        "out={out_prot}"
    );
    assert!(out_prot.contains("MECHANICAL_FINDINGS"), "out={out_prot}");
}

#[test]
fn b3_binary_verify_check_staleness_and_pr_mutation_owner_guards() {
    let tmp = TempDirGuard::new("eval-verify-pr");
    let repo = &tmp.path;
    let base_sha = init_fresh_git_repo(repo);
    let r = repo.to_str().expect("repo utf8");

    // 1. verify-run + verify-check valid -> modify file -> VERIFY_STALE
    let (cv_run, out_run, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r,
        "--verify-cmd",
        "echo ok",
        "--receipt-path",
        ".b3/ship/verify/t001.verify",
        "--task-id",
        "T001",
        "--relevant-paths",
        "src/app.txt",
    ]);
    assert_eq!(cv_run, 0, "verify-run failed: {out_run}");
    assert!(out_run.contains("VERIFY_PASS:"), "out={out_run}");

    let (cv_ok, out_ok, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r,
        "--receipt-path",
        ".b3/ship/verify/t001.verify",
        "--expected-cmd",
        "echo ok",
        "--relevant-paths",
        "src/app.txt",
    ]);
    assert_eq!(cv_ok, 0, "verify-check valid failed: {out_ok}");
    assert!(out_ok.contains("VERIFY_VALID:"), "out={out_ok}");

    write_lf(&repo.join("src/app.txt"), "v2 modified\n");
    let (cv_stale, out_stale, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r,
        "--receipt-path",
        ".b3/ship/verify/t001.verify",
    ]);
    assert_eq!(cv_stale, 2, "stale verify-check must exit 2: {out_stale}");
    assert!(out_stale.contains("VERIFY_STALE:"), "out={out_stale}");

    // 2. PR mutation owner & missing --authorize-* guards
    write_lf(&repo.join(".b3/reply.md"), "Fixed in local commit.\n");
    write_lf(&repo.join(".b3/summary.md"), "Verified summary.\n");
    let reply_file = repo.join(".b3/reply.md");
    let summary_file = repo.join(".b3/summary.md");
    let reply_str = reply_file.to_str().expect("reply path");
    let summary_str = summary_file.to_str().expect("summary path");

    // Missing --authorize-write / --authorize-resolve -> PR_AUTH_REQUIRED (exit 2)
    let (c_noauth_reply, out_noauth_reply, _) = run_b3(&[
        "pr",
        "reply",
        "--repo",
        "acme/demo",
        "--pr",
        "1",
        "--repo-root",
        r,
        "--expected-head",
        &base_sha,
        "--target-kind",
        "review_thread",
        "--target-id",
        "PRRT_1",
        "--body-file",
        reply_str,
    ]);
    assert_eq!(c_noauth_reply, 2, "reply without auth: {out_noauth_reply}");
    assert!(
        out_noauth_reply.contains("PR_AUTH_REQUIRED"),
        "out={out_noauth_reply}"
    );

    let (c_noauth_comment, out_noauth_comment, _) = run_b3(&[
        "pr",
        "comment",
        "--repo",
        "acme/demo",
        "--pr",
        "1",
        "--repo-root",
        r,
        "--expected-head",
        &base_sha,
        "--mode",
        "summary",
        "--summary-file",
        summary_str,
    ]);
    assert_eq!(
        c_noauth_comment, 2,
        "comment without auth: {out_noauth_comment}"
    );
    assert!(
        out_noauth_comment.contains("PR_AUTH_REQUIRED"),
        "out={out_noauth_comment}"
    );

    let (c_noauth_resolve, out_noauth_resolve, _) = run_b3(&[
        "pr",
        "resolve",
        "--repo",
        "acme/demo",
        "--pr",
        "1",
        "--repo-root",
        r,
        "--expected-head",
        &base_sha,
        "--thread-id",
        "PRRT_1",
        "--fix-commit",
        &base_sha,
    ]);
    assert_eq!(
        c_noauth_resolve, 2,
        "resolve without auth: {out_noauth_resolve}"
    );
    assert!(
        out_noauth_resolve.contains("PR_AUTH_REQUIRED"),
        "out={out_noauth_resolve}"
    );

    // Worker context with --authorize-* -> PR_MUTATION_OWNER_REQUIRED (exit 2)
    let worker_env = [("B3_PR_MUTATION_ROLE", "worker")];
    let (c_wrk_reply, out_wrk_reply, _) = run_b3_env(
        &[
            "pr",
            "reply",
            "--repo",
            "acme/demo",
            "--pr",
            "1",
            "--repo-root",
            r,
            "--expected-head",
            &base_sha,
            "--target-kind",
            "review_thread",
            "--target-id",
            "PRRT_1",
            "--body-file",
            reply_str,
            "--authorize-write",
        ],
        None,
        &worker_env,
        &[],
    );
    assert_eq!(c_wrk_reply, 2, "worker reply must block: {out_wrk_reply}");
    assert!(
        out_wrk_reply.contains("PR_MUTATION_OWNER_REQUIRED"),
        "out={out_wrk_reply}"
    );

    let (c_wrk_resolve, out_wrk_resolve, _) = run_b3_env(
        &[
            "pr",
            "resolve",
            "--repo",
            "acme/demo",
            "--pr",
            "1",
            "--repo-root",
            r,
            "--expected-head",
            &base_sha,
            "--thread-id",
            "PRRT_1",
            "--fix-commit",
            &base_sha,
            "--authorize-resolve",
        ],
        None,
        &worker_env,
        &[],
    );
    assert_eq!(
        c_wrk_resolve, 2,
        "worker resolve must block: {out_wrk_resolve}"
    );
    assert!(
        out_wrk_resolve.contains("PR_MUTATION_OWNER_REQUIRED"),
        "out={out_wrk_resolve}"
    );

    // Linked worktree context -> PR_MUTATION_OWNER_REQUIRED (exit 2)
    let wt_dir = tmp.path.join("linked-wt");
    let wt_str = wt_dir.to_str().expect("wt utf8");
    git_in(repo, &["worktree", "add", "--detach", wt_str, "HEAD"]);
    let (c_wt_comment, out_wt_comment, _) = run_b3_env(
        &[
            "pr",
            "comment",
            "--repo",
            "acme/demo",
            "--pr",
            "1",
            "--repo-root",
            wt_str,
            "--expected-head",
            &base_sha,
            "--mode",
            "summary",
            "--summary-file",
            summary_str,
            "--authorize-write",
        ],
        None,
        &[],
        &["B3_PR_MUTATION_ROLE", "B3_SUBAGENT"],
    );
    assert_eq!(
        c_wt_comment, 2,
        "linked worktree comment must block: {out_wt_comment}"
    );
    assert!(
        out_wt_comment.contains("PR_MUTATION_OWNER_REQUIRED"),
        "out={out_wt_comment}"
    );
    assert!(
        out_wt_comment.contains("linked_worktree_forbidden"),
        "out={out_wt_comment}"
    );
    let _ = git_in(repo, &["worktree", "remove", "--force", wt_str]);
}

#[test]
fn continuous_scheduling_and_incremental_integration_contracts() {
    let root = repo_root();
    let canon_root = fs::canonicalize(&root).expect("canonicalize repo_root");
    let read_lf = |rel: &str| -> String {
        let raw = fs::read_to_string(root.join(rel))
            .unwrap_or_else(|e| panic!("failed to read {rel}: {e}"));
        normalize_lf(&raw)
    };

    // 1. Canonical planning: 3-way dependency classification, early shared-contract extraction,
    //    critical-path ordering, and strict <= 4,000 B caps.
    let planning_skill = read_lf("skills/engineering/planning/SKILL.md");
    let plan_cmd = read_lf("commands/b3-plan.md");
    let plan_cs = read_lf("adapters/command-skills/b3-plan/SKILL.md");

    for (rel, body) in [
        (
            "skills/engineering/planning/SKILL.md",
            planning_skill.as_str(),
        ),
        ("commands/b3-plan.md", plan_cmd.as_str()),
        ("adapters/command-skills/b3-plan/SKILL.md", plan_cs.as_str()),
    ] {
        assert!(
            body.len() <= 4_000,
            "{rel} ({} B) exceeds 4000 B cap",
            body.len()
        );
        let low = body.to_ascii_lowercase();
        assert!(
            body.contains("depends_on")
                && body.contains("read_only_deps")
                && low.contains("integration constraint")
                && low.contains("3-way")
                && low.contains("shared")
                && low.contains("early")
                && (low.contains("critical-path") || low.contains("critical path")),
            "{rel} missing 3-way dependency classification, early shared-contract extraction, or critical-path ordering"
        );
    }

    // 2. Canonical scheduling (`workflows/references/dispatch-naming.md` <= 9,200 B).
    let dispatch_doc = read_lf("workflows/references/dispatch-naming.md");
    assert!(
        dispatch_doc.len() <= 9_200,
        "workflows/references/dispatch-naming.md ({} B) exceeds 9200 B cap",
        dispatch_doc.len()
    );
    for token in [
        "14 B3 commands",
        "TASK_VERIFIED != DEPENDENCY_OUTPUT_AVAILABLE",
        "--active-specs",
        "--active-reads",
        "--verified-dirty-paths",
        "admitted_tasks",
        "deferred_tasks",
        "--worker-bases",
        "stale_base_conflict",
    ] {
        assert!(
            dispatch_doc.contains(token),
            "workflows/references/dispatch-naming.md missing '{token}'"
        );
    }

    // 3. Workflows (`ship.md`, `research-ship.md`), resume procedures, and templates
    //    wire `output_ready` / `integrated`, `--active-specs`, `--verified-dirty-paths`,
    //    and `--worker-bases` within strict byte caps.
    let ship_wf = read_lf("workflows/ship.md");
    let rs_wf = read_lf("workflows/research-ship.md");
    let ship_resume = read_lf("workflows/references/ship-resume.md");
    let rs_resume = read_lf("workflows/references/research-ship-resume.md");
    let ship_tpl = read_lf("workflows/references/ship-templates.md");
    let rs_tpl = read_lf("workflows/references/research-ship-templates.md");
    let rs_gates = read_lf("workflows/references/research-ship-gates.md");

    assert!(
        ship_wf.len() <= 9_500,
        "workflows/ship.md ({} B) exceeds 9500 B cap",
        ship_wf.len()
    );
    assert!(
        rs_wf.len() <= 9_500,
        "workflows/research-ship.md ({} B) exceeds 9500 B cap",
        rs_wf.len()
    );
    assert!(
        ship_tpl.len() + ship_resume.len() <= 6_000,
        "ship-templates.md + ship-resume.md ({} B) exceeds 6000 B cap",
        ship_tpl.len() + ship_resume.len()
    );
    assert!(
        rs_tpl.len() + rs_resume.len() + rs_gates.len() <= 12_000,
        "research-ship-{{templates,resume,gates}}.md ({} B) exceeds 12000 B cap",
        rs_tpl.len() + rs_resume.len() + rs_gates.len()
    );

    for (rel, body) in [
        ("workflows/ship.md", ship_wf.as_str()),
        ("workflows/research-ship.md", rs_wf.as_str()),
        ("workflows/references/ship-resume.md", ship_resume.as_str()),
        (
            "workflows/references/research-ship-resume.md",
            rs_resume.as_str(),
        ),
    ] {
        for token in [
            "output_ready",
            "integrated",
            "--active-specs",
            "--active-reads",
            "--verified-dirty-paths",
            "--worker-bases",
        ] {
            assert!(body.contains(token), "{rel} missing '{token}'");
        }
    }

    for (rel, body) in [
        ("workflows/references/ship-templates.md", ship_tpl.as_str()),
        (
            "workflows/references/research-ship-templates.md",
            rs_tpl.as_str(),
        ),
    ] {
        assert!(
            body.contains("pending|output_ready|integrated") && body.contains("| integration |"),
            "{rel} missing integration state column or pending|output_ready|integrated enum"
        );
    }

    // 4. All 10 mandatory orchestration scenarios exist in `evals/workflows/orchestration/`,
    //    parse cleanly with valid contained `artifact` links, and match `evals/README.md` (`338` / `22`).
    const MANDATORY_ORCHESTRATION_SCENARIOS: &[&str] = &[
        "abcde-continuous-release.yaml",
        "cross-wave-write-conflict.yaml",
        "cross-wave-rw-conflict.yaml",
        "concurrency-slot-saturation.yaml",
        "isolated-output-unintegrated-gate.yaml",
        "partial-worker-failure-isolation.yaml",
        "resume-mid-wave-active-workers.yaml",
        "task-decomposition-shared-prereq.yaml",
        "research-ship-parallel-disputed-isolation.yaml",
        "host-limitation-sequential-fallback.yaml",
    ];

    let orch_dir = root.join("evals/workflows/orchestration");
    for fname in MANDATORY_ORCHESTRATION_SCENARIOS {
        let p = orch_dir.join(fname);
        assert!(
            p.is_file(),
            "missing mandatory orchestration scenario: evals/workflows/orchestration/{fname}"
        );
        let raw = fs::read_to_string(&p).expect("read orchestration yaml");
        let parsed = parse_eval_yaml_scalars(&raw)
            .unwrap_or_else(|e| panic!("failed to parse {fname}: {e}"));
        for req_key in ["id", "intent", "expected_outcome", "artifact"] {
            let val = parsed.get(req_key).map(|s| s.trim()).unwrap_or_default();
            assert!(!val.is_empty(), "{fname} missing or empty '{req_key}'");
        }
        let artifact = parsed["artifact"].trim();
        assert!(
            !is_unsafe_artifact_path(artifact),
            "{fname} has unsafe artifact path '{artifact}'"
        );
        let target = root.join(artifact.replace('/', std::path::MAIN_SEPARATOR_STR));
        let meta = fs::symlink_metadata(&target)
            .unwrap_or_else(|e| panic!("{fname} artifact '{artifact}' missing: {e}"));
        assert!(
            meta.is_file()
                && !meta.file_type().is_symlink()
                && !b3::fs::is_reparse_or_symlink(&target),
            "{fname} artifact '{artifact}' is not a regular file"
        );
        let canon_target = fs::canonicalize(&target).expect("canonicalize artifact");
        assert!(
            canon_target.starts_with(&canon_root),
            "{fname} artifact '{artifact}' escapes repo_root"
        );
    }

    let orch_yaml_count = fs::read_dir(&orch_dir)
        .expect("read evals/workflows/orchestration")
        .filter_map(Result::ok)
        .filter(|e| e.path().is_file() && e.file_name().to_string_lossy().ends_with(".yaml"))
        .count();
    assert_eq!(
        orch_yaml_count, 22,
        "expected 22 YAML fixtures in evals/workflows/orchestration/, found {orch_yaml_count}"
    );

    let evals_dir = root.join("evals");
    let mut all_yaml = Vec::new();
    let mut all_readmes = Vec::new();
    let mut collect_errs = Vec::new();
    collect_eval_files(
        &evals_dir,
        &evals_dir,
        &mut all_yaml,
        &mut all_readmes,
        &mut collect_errs,
    );
    assert!(collect_errs.is_empty(), "collect errors: {collect_errs:?}");
    assert_eq!(
        all_yaml.len(),
        371,
        "expected 371 total YAML fixtures across evals/, found {}",
        all_yaml.len()
    );

    let evals_readme = read_lf("evals/README.md");
    assert!(
        evals_readme.contains("`371` YAML")
            && evals_readme.contains("| `workflows/clarification/` | 17 |")
            && evals_readme.contains("| `workflows/orchestration/` | 22 |")
            && evals_readme.contains("| `workflows/hooks/` | 8 |")
            && evals_readme.contains("| `workflows/static-analysis/` | 8 |"),
        "evals/README.md inventory out of sync with 371 total / 17 workflows/clarification / 22 workflows/orchestration / 8 workflows/hooks / 8 workflows/static-analysis fixtures"
    );

    // 5. `scripts/README.md` flag documentation & end-to-end `run_b3` smoke check on
    //    `check-wave --partition --active-specs ... --verified-dirty-paths ...`.
    let scripts_readme = read_lf("scripts/README.md");
    for flag in [
        "--active-specs",
        "--active-reads",
        "--verified-dirty-paths",
        "--worker-bases",
    ] {
        assert!(
            scripts_readme.contains(flag),
            "scripts/README.md missing CLI flag documentation for '{flag}'"
        );
    }

    let tmp = TempDirGuard::new("eval-cont-wave");
    let repo = &tmp.path;
    let base_sha = init_fresh_git_repo(repo);
    let r = repo.to_str().expect("repo utf8");

    // Simulate A verified in shared WT (`src/a.txt` dirty, uncommitted) while E is still active (`src/e.txt` dirty).
    // Newly ready B, C, D read `src/a.txt`; F conflicts with active E (`src/e.txt`); max-concurrency=3 -> 2 slots open.
    write_lf(&repo.join("src/a.txt"), "verified output from A\n");
    write_lf(&repo.join("src/e.txt"), "in-flight edit from E\n");

    let (code, out, err) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--expected-base-sha",
        &base_sha,
        "--check-dirty-scope",
        "--partition",
        "--max-concurrency",
        "3",
        "--wave-specs",
        "B=src/b.txt;C=src/c.txt;D=src/d.txt;F=src/e.txt",
        "--wave-reads",
        "B=src/a.txt;C=src/a.txt;D=src/a.txt",
        "--active-specs",
        "E=src/e.txt",
        "--active-reads",
        "E=docs/guide.md",
        "--verified-dirty-paths",
        "src/a.txt",
    ]);
    assert_eq!(
        code, 0,
        "continuous check-wave smoke test failed: out={out} err={err}"
    );
    for expected in [
        "dirty_scope=clean",
        "unexpected_dirty=none",
        "active_tasks=E",
        "active_count=1",
        "available_slots=2",
        "active_dirty=src/e.txt",
        "verified_dirty=src/a.txt",
        "conflicts=active:src/e.txt(E,F)",
        "admitted_tasks=B,C",
        "deferred_tasks=D,F",
        "wave|1|PARALLEL|agents=2|tasks=B,C|reason=independent_ready_tasks",
        "wave|2|SEQUENTIAL|agents=1|tasks=D|reason=bounded_concurrency",
        "WAVE_PARTITIONED: waves=2 max_parallel=2",
    ] {
        assert!(
            out.contains(expected),
            "expected '{expected}' in check-wave output:\n{out}"
        );
    }
}

#[test]
fn hook_integration_canonical_contract_and_no_duplication() {
    let root = repo_root();

    let hook_ref = fs::read_to_string(root.join("workflows/references/hook-integration.md"))
        .expect("read workflows/references/hook-integration.md");
    for required in [
        "hooks:",
        "enabled: true",
        "mode: enforce",
        "Tier 0",
        "Tier 1",
        "Tier 2",
        "B3_HOOK_ACTIVE",
        "clarification-gate.md",
    ] {
        assert!(
            hook_ref.contains(required),
            "workflows/references/hook-integration.md missing '{required}'"
        );
    }

    let hooks_doc = fs::read_to_string(root.join("docs/hooks.md")).expect("read docs/hooks.md");
    for required in [
        "EVENT_BLOCKING",
        "NATIVE_BLOCKING",
        "NOT_VERIFIED",
        "Cursor",
        "Claude Code",
        "Codex",
        "Antigravity",
        "Git",
        "mermaid",
    ] {
        assert!(
            hooks_doc.contains(required),
            "docs/hooks.md missing '{required}'"
        );
    }

    let adr = fs::read_to_string(
        root.join("research/decisions/decision-015-native-guard-event-hooks.md"),
    )
    .expect("read decision-015");
    assert!(adr.contains("hook-integration.md") || adr.contains("b3 hook"));

    let disp = fs::read_to_string(root.join("workflows/references/dispatch-naming.md"))
        .expect("read dispatch-naming.md");
    assert!(disp.contains("hook-integration.md"));

    let models_ex =
        fs::read_to_string(root.join("config/models.example.md")).expect("read models.example.md");
    let parsed_hooks = b3::hook::config::parse_hook_config_from_markdown(&models_ex)
        .expect("parse models.example.md hooks")
        .expect("hooks section present");
    assert_eq!(parsed_hooks.enabled, Some(true));
    assert_eq!(parsed_hooks.mode, Some(b3::hook::config::HookMode::Enforce));
    assert!(
        models_ex.contains("clarification_gate:") && models_ex.contains("understanding_threshold:"),
        "config/models.example.md must preserve PR #47 planning clarification keys alongside hooks"
    );

    // Removed legacy hook variables must not remain in canonical reference or docs
    for removed in [
        "B3_HOOK_SKIP_PRECOMMIT",
        "B3_PRECOMMIT_VERIFIED_TREE",
        "B3_MERGE_AUTHORIZED",
        "B3_PROTECTED_PATHS",
        "B3_IGNORE_DIRTY_PATHS",
    ] {
        assert!(
            !hook_ref.contains(removed),
            "workflows/references/hook-integration.md must not contain removed '{removed}'"
        );
        assert!(
            !hooks_doc.contains(removed),
            "docs/hooks.md must not contain removed '{removed}'"
        );
    }

    assert_always_on_context_budget(&root);
}

#[test]
fn clarification_gate_canonical_contract_and_no_duplication() {
    // Static contract & anti-bloat checks only (NOT live AI behavioral verification).
    let root = repo_root();

    // F01 dead-code regression guards: no unused Rust planning_config parser.
    assert!(
        !root.join("src/planning_config.rs").exists(),
        "unused src/planning_config.rs must remain removed"
    );
    assert!(
        !root.join("tests/planning_config.rs").exists(),
        "unused tests/planning_config.rs must remain removed"
    );
    let lib_rs = fs::read_to_string(root.join("src/lib.rs")).expect("read src/lib.rs");
    assert!(
        !lib_rs.contains("planning_config"),
        "src/lib.rs must not expose or reference planning_config"
    );

    let rule_raw = fs::read_to_string(root.join("rules/engineering-principles.md"))
        .expect("read rules/engineering-principles.md");
    assert!(
        rule_raw.contains("workflows/references/clarification-gate.md") && rule_raw.contains("96%"),
        "rules/engineering-principles.md must embed the proportional >=96% invariant pointing to clarification-gate.md"
    );

    let contract = fs::read_to_string(root.join("workflows/references/clarification-gate.md"))
        .expect("read workflows/references/clarification-gate.md");
    let contract_lf = normalize_lf(&contract);
    assert!(
        contract_lf.len() <= 5_800,
        "workflows/references/clarification-gate.md ({} B) exceeds 5800 B static cap",
        contract_lf.len()
    );
    for required_fragment in [
        "clarification_gate: true",
        "understanding_threshold: 96",
        "clarification_gate: false",
        "next valid layer",
        "evidence-grounded heuristic trigger",
        "block solely on score",
        "Parent-Only Ownership & Maximum Safe Parallelism",
        "sole clarification owner",
        "Workers **must NOT** load `clarification-gate.md`",
        "`XS` | `S` | `M` | `L` | `XL` | `XXL`",
        "`XS` / `S`",
        "**7-Step Contract:**",
        "**10 Dimensions:**",
        "Critical, irreversible, security, or authz ambiguity:",
        "**regardless of score**",
        "Targeted Reassessment & Inheritance",
        "Reassess **only** on material triggers",
        "Continuous isolation (`A..F`):",
    ] {
        assert!(
            contract_lf.contains(required_fragment),
            "workflows/references/clarification-gate.md missing '{required_fragment}'"
        );
    }

    for rel in [
        "workflows/references/dispatch-naming.md",
        "skills/engineering/planning/SKILL.md",
        "workflows/ship.md",
        "workflows/research-ship.md",
        "workflows/feature-implementation.md",
    ] {
        let raw = fs::read_to_string(root.join(rel)).unwrap_or_else(|e| panic!("read {rel}: {e}"));
        assert!(
            raw.contains("clarification-gate.md"),
            "{rel} must cross-link clarification-gate.md"
        );
    }

    // F03 regression guards on workflows/ship.md.
    let ship_wf =
        fs::read_to_string(root.join("workflows/ship.md")).expect("read workflows/ship.md");
    assert!(
        ship_wf.contains("skip immediate `verify-check` after `verify-run` `0` w/ 0 edits"),
        "workflows/ship.md must preserve skip immediate verify-check after verify-run 0 with 0 edits"
    );
    assert!(
        ship_wf.contains("Unignored run-dirty files block `PASS`"),
        "workflows/ship.md must preserve 'Unignored run-dirty files block `PASS`'"
    );

    let models_example = fs::read_to_string(root.join("config/models.example.md"))
        .expect("read config/models.example.md");
    assert!(
        models_example.contains("planning:")
            && models_example.contains("clarification_gate: true")
            && models_example.contains("understanding_threshold: 96"),
        "config/models.example.md missing canonical planning config"
    );

    let models_doc = fs::read_to_string(root.join("docs/model-preferences.md"))
        .expect("read docs/model-preferences.md");
    for required_doc_fragment in [
        "Field-level precedence:",
        "next valid layer",
        "understanding_threshold: 90",
        "clarification_gate: false",
    ] {
        assert!(
            models_doc.contains(required_doc_fragment),
            "docs/model-preferences.md missing '{required_doc_fragment}'"
        );
    }

    assert_eq!(
        EXPECTED_CLARIFICATION_EVALS.len(),
        17,
        "expected 17 clarification eval entries"
    );
    let clarif_yaml_count = fs::read_dir(root.join("evals/workflows/clarification"))
        .expect("read evals/workflows/clarification")
        .filter_map(Result::ok)
        .filter(|e| e.path().is_file() && e.file_name().to_string_lossy().ends_with(".yaml"))
        .count();
    assert_eq!(
        clarif_yaml_count, 17,
        "expected 17 YAML fixtures in evals/workflows/clarification/, found {clarif_yaml_count}"
    );

    // Ensure no command or command-skill duplicates the clarification rubric.
    for name in EXPECTED_COMMANDS {
        for path in [
            root.join("commands").join(format!("{name}.md")),
            root.join("adapters/command-skills")
                .join(name)
                .join("SKILL.md"),
        ] {
            let raw = fs::read_to_string(&path).expect("read command/skill file");
            assert!(
                !raw.contains("understanding_threshold")
                    && !raw.contains("10 Understanding Assessment Dimensions")
                    && !raw.contains("**10 Dimensions:**"),
                "{} must not duplicate clarification rubric",
                rel_slash(&root, &path)
            );
        }
    }

    // Ensure no extra agent roles were added (still 5 canonical b3-*.md roles).
    let mut role_count = 0usize;
    for entry in fs::read_dir(root.join("agents")).expect("read agents/") {
        let p = entry.expect("agent entry").path();
        if p.is_file()
            && p.extension().and_then(|e| e.to_str()) == Some("md")
            && p.file_name().and_then(|n| n.to_str()) != Some("README.md")
        {
            role_count += 1;
        }
    }
    assert_eq!(role_count, 5, "expected 5 canonical agent roles");
}

#[test]
fn static_analysis_canonical_contract_and_anti_bloat() {
    let root = repo_root();

    // (a) Canonical static-analysis contract size & required tokens.
    let contract_raw = fs::read_to_string(root.join("workflows/references/static-analysis.md"))
        .expect("read workflows/references/static-analysis.md");
    let contract = normalize_lf(&contract_raw);
    assert!(
        contract.len() <= 6_500,
        "workflows/references/static-analysis.md ({} B) exceeds 6500 B static cap",
        contract.len()
    );
    for required in [
        "REUSE",
        "FALLBACK",
        "BOOTSTRAP",
        "L1",
        "L2",
        "L3",
        "L4",
        "Production-consumer verification",
        "unit tests != runtime/production caller",
        "VERIFY_STALE",
        "PREEXISTING_BASELINE",
        "WORKFLOW_ONLY",
        "allowed-paths",
        "Adaptive Scope",
        "Coverage-gap",
        "XS",
        "XXL",
        "Inline / Sequential",
        "Shared Disjoint Writes",
        "Isolated Writes",
        "supplementary protection",
        "unrelated, unchanged, non-blocking",
        "only when",
    ] {
        assert!(
            contract.contains(required),
            "workflows/references/static-analysis.md missing '{required}'"
        );
    }

    // Review-loop strategy & conditional dispatch-naming & narrow baseline reviewer checks
    let rl_strategy = normalize_lf(
        &fs::read_to_string(root.join("review-loop/strategy.md")).expect("read strategy.md"),
    );
    assert!(
        rl_strategy.len() <= 5_200,
        "review-loop/strategy.md ({} B) exceeds 5200 B cap",
        rl_strategy.len()
    );
    assert!(
        rl_strategy.contains("static-analysis.md"),
        "review-loop/strategy.md must reference static-analysis.md"
    );
    let disp_ref = normalize_lf(
        &fs::read_to_string(root.join("workflows/references/dispatch-naming.md"))
            .expect("read dispatch-naming.md"),
    );
    assert!(
        disp_ref.len() <= 9_200 && disp_ref.contains("only when") && disp_ref.contains("static-analysis.md"),
        "workflows/references/dispatch-naming.md must load static-analysis.md conditionally within 9200 B"
    );
    let rev_agent = normalize_lf(
        &fs::read_to_string(root.join("agents/b3-reviewer.md")).expect("read b3-reviewer.md"),
    );
    assert!(
        !rev_agent.contains("ignore `PREEXISTING_BASELINE`")
            && !rev_agent.contains("ignore PREEXISTING_BASELINE"),
        "agents/b3-reviewer.md must not instruct blanket ignoring PREEXISTING_BASELINE"
    );
    assert!(
        rev_agent.contains("unrelated unchanged non-blocking `PREEXISTING_BASELINE`"),
        "agents/b3-reviewer.md must qualify baseline skipping narrowly"
    );

    // (b) Cross-links across workflows, review-loop, skills, reviewer agent, and docs.
    for rel in [
        "workflows/ship.md",
        "workflows/research-ship.md",
        "workflows/feature-implementation.md",
        "review-loop/strategy.md",
        "skills/engineering/verification/SKILL.md",
        "skills/engineering/code-review/SKILL.md",
        "skills/engineering/refactoring/SKILL.md",
        "agents/b3-reviewer.md",
        "docs/hooks.md",
        "docs/ship-and-review-guide.md",
    ] {
        let raw = fs::read_to_string(root.join(rel)).unwrap_or_else(|e| panic!("read {rel}: {e}"));
        assert!(
            raw.contains("static-analysis.md"),
            "{rel} must cross-link static-analysis.md"
        );
    }

    // Eval suite inventory for workflows/static-analysis/.
    assert_eq!(
        EXPECTED_STATIC_ANALYSIS_EVALS.len(),
        8,
        "expected 8 static-analysis eval entries"
    );
    let sa_yaml_count = fs::read_dir(root.join("evals/workflows/static-analysis"))
        .expect("read evals/workflows/static-analysis")
        .filter_map(Result::ok)
        .filter(|e| e.path().is_file() && e.file_name().to_string_lossy().ends_with(".yaml"))
        .count();
    assert_eq!(
        sa_yaml_count, 8,
        "expected 8 YAML fixtures in evals/workflows/static-analysis/, found {sa_yaml_count}"
    );

    // (c) Strict anti-bloat counts: commands, agents, guard modules, Cargo.toml deps, and context budget.
    let count_md_excl_readme = |dir: &Path| -> usize {
        fs::read_dir(dir)
            .unwrap_or_else(|e| panic!("read {}: {e}", dir.display()))
            .filter_map(Result::ok)
            .filter(|e| {
                let p = e.path();
                p.is_file()
                    && p.extension().and_then(|x| x.to_str()) == Some("md")
                    && p.file_name().and_then(|n| n.to_str()) != Some("README.md")
            })
            .count()
    };

    let cmd_count = count_md_excl_readme(&root.join("commands"));
    assert_eq!(
        cmd_count, 14,
        "expected 14 commands/*.md, found {cmd_count}"
    );

    let agent_count = count_md_excl_readme(&root.join("agents"));
    assert_eq!(
        agent_count, 5,
        "expected 5 runtime agent files in agents/*.md (excl. README.md), found {agent_count}"
    );

    let guard_module_count = fs::read_dir(root.join("src/guard"))
        .expect("read src/guard")
        .filter_map(Result::ok)
        .filter(|e| {
            let p = e.path();
            p.is_file()
                && p.extension().and_then(|x| x.to_str()) == Some("rs")
                && p.file_name().and_then(|n| n.to_str()) != Some("mod.rs")
        })
        .count();
    assert_eq!(
        guard_module_count, 16,
        "expected 16 guard modules under src/guard/*.rs (excl. mod.rs), found {guard_module_count}"
    );

    let cargo_toml =
        normalize_lf(&fs::read_to_string(root.join("Cargo.toml")).expect("read Cargo.toml"));
    let mut in_deps = false;
    let mut found_deps_header = false;
    let mut dep_lines = Vec::new();
    for line in cargo_toml.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            if trimmed == "[dependencies]" {
                in_deps = true;
                found_deps_header = true;
                continue;
            }
            if in_deps {
                break;
            }
        } else if in_deps && !trimmed.is_empty() && !trimmed.starts_with('#') {
            dep_lines.push(trimmed.to_string());
        }
    }
    assert!(
        found_deps_header,
        "Cargo.toml missing [dependencies] section"
    );
    assert!(
        dep_lines.is_empty(),
        "Cargo.toml must retain zero external dependencies, found: {dep_lines:?}"
    );

    let root_str = root.to_str().expect("repo_root utf8");
    let (report, code) = b3::context::measure_context(root_str, true).expect("measure_context");
    assert_eq!(code, 0, "strict context budget failed:\n{report}");
    assert!(
        report.contains("warnings          : 0"),
        "expected zero context warnings:\n{report}"
    );
    let always_line = report
        .lines()
        .find(|l| l.starts_with("always_on_total"))
        .expect("always_on_total line");
    let after_colon = always_line.split(':').nth(1).expect("colon in line").trim();
    let bytes_str = after_colon.split_whitespace().next().expect("bytes number");
    let always_on_bytes: usize = bytes_str.parse().expect("parse always_on_total bytes");
    assert_eq!(
        always_on_bytes, 15_579,
        "always_on_total must remain 15579 B:\n{report}"
    );
}
