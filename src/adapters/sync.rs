use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use crate::adapters::common::{
    add_canonical_skills, assert_regular_dir_or_missing, assert_regular_file_or_missing,
    collect_skill_md_files, create_dir_link, format_personal_config_status, has_active_path,
    initialize_personal_config_file, is_reparse_link, normalize_abs_path_str, path_exists_or_link,
    remove_link_only, resolve_b3_repo_root_auto, test_link_target, write_utf8_no_bom_lf,
};
use crate::error::{fail, B3Error};
use crate::fs::{sha256_bytes_hex, sort_ordinal};
use crate::json::{parse_json, JsonValue};

#[derive(Debug, Clone)]
struct FlatSkill {
    name: String,
    source: PathBuf,
}

fn test_skill_source(dir: &Path) -> bool {
    if !dir.is_dir() {
        return false;
    }
    let mut files = Vec::new();
    let _ = collect_skill_md_files(dir, &mut files);
    !files.is_empty()
}

fn get_expected_flat_skills(
    skills_source: &Path,
    command_skills_source: &Path,
) -> Result<Vec<FlatSkill>, B3Error> {
    let mut map: BTreeMap<String, PathBuf> = BTreeMap::new();
    let _ = add_canonical_skills(skills_source, &mut map)?;
    if command_skills_source.is_dir() {
        let _ = add_canonical_skills(command_skills_source, &mut map)?;
    }
    let keys = sort_ordinal(map.keys().cloned(), false);
    let mut list = Vec::with_capacity(keys.len());
    for k in keys {
        if let Some(src) = map.get(&k) {
            list.push(FlatSkill {
                name: k,
                source: src.clone(),
            });
        }
    }
    Ok(list)
}

fn sync_directory_link(
    dest: &Path,
    src: &Path,
    label: &str,
    dry_run: bool,
    out: &mut Vec<String>,
) -> Result<(), B3Error> {
    if path_exists_or_link(dest) {
        if is_reparse_link(dest) {
            if test_link_target(dest, src, false) {
                out.push(format!(
                    "ok: {} already links to {} ({label})",
                    dest.display(),
                    src.display()
                ));
                return Ok(());
            }
            return Err(fail(
                format!(
                    "existing link {} does not resolve to {}",
                    dest.display(),
                    src.display()
                ),
                1,
            ));
        }
        let is_empty_dir = dest.is_dir()
            && fs::read_dir(dest)
                .map(|mut it| it.next().is_none())
                .unwrap_or(false);
        if is_empty_dir {
            if dry_run {
                out.push(format!(
                    "dry-run: remove empty directory {} then junction to {}",
                    dest.display(),
                    src.display()
                ));
                return Ok(());
            }
            fs::remove_dir(dest).map_err(|e| {
                fail(
                    format!("cannot remove empty directory {} : {e}", dest.display()),
                    1,
                )
            })?;
        } else {
            return Err(fail(
                format!(
                    "existing non-link path with content; refusing to replace: {}",
                    dest.display()
                ),
                1,
            ));
        }
    }

    if dry_run {
        out.push(format!(
            "dry-run: junction {} -> {}",
            dest.display(),
            src.display()
        ));
        return Ok(());
    }

    create_dir_link(dest, src)?;
    if !test_link_target(dest, src, false) {
        return Err(fail(
            format!(
                "link created but verification failed: {} -> {}",
                dest.display(),
                src.display()
            ),
            1,
        ));
    }
    out.push(format!(
        "linked: {} -> {} ({label})",
        dest.display(),
        src.display()
    ));
    Ok(())
}

fn test_flat_skill_index(dest_root: &Path, expected: &[FlatSkill]) -> bool {
    if !dest_root.is_dir() || is_reparse_link(dest_root) {
        return false;
    }
    for sk in expected {
        let entry_dest = dest_root.join(&sk.name);
        if !test_link_target(&entry_dest, &sk.source, false) {
            return false;
        }
        if !entry_dest.join("SKILL.md").is_file() {
            return false;
        }
    }
    true
}

fn sync_flat_skill_index(
    dest_root: &Path,
    expected: &[FlatSkill],
    label: &str,
    dry_run: bool,
    out: &mut Vec<String>,
) -> Result<(), B3Error> {
    if path_exists_or_link(dest_root) {
        if is_reparse_link(dest_root) {
            if dry_run {
                out.push(format!(
                    "dry-run: replace legacy nested link {} with flattened {}-skill index ({label})",
                    dest_root.display(),
                    expected.len()
                ));
                return Ok(());
            }
            remove_link_only(dest_root)?;
        } else if !dest_root.is_dir() {
            return Err(fail(
                format!(
                    "existing non-directory path; refusing to replace: {}",
                    dest_root.display()
                ),
                1,
            ));
        } else if let Ok(entries) = fs::read_dir(dest_root) {
            for child in entries.flatten() {
                let cp = child.path();
                if !is_reparse_link(&cp) {
                    return Err(fail(
                        format!(
                            "existing non-link content in {}; refusing to replace: {}",
                            dest_root.display(),
                            cp.display()
                        ),
                        1,
                    ));
                }
            }
        }
    }

    if dry_run {
        out.push(format!(
            "dry-run: flatten {} with {} skill junctions ({label})",
            dest_root.display(),
            expected.len()
        ));
        return Ok(());
    }

    fs::create_dir_all(dest_root).map_err(|e| {
        fail(
            format!("cannot create skill index {}: {e}", dest_root.display()),
            1,
        )
    })?;
    let mut expected_names = BTreeSet::new();
    for sk in expected {
        expected_names.insert(sk.name.clone());
        let entry_dest = dest_root.join(&sk.name);
        if path_exists_or_link(&entry_dest) {
            if test_link_target(&entry_dest, &sk.source, false) {
                continue;
            }
            remove_link_only(&entry_dest)?;
        }
        create_dir_link(&entry_dest, &sk.source)?;
    }
    if let Ok(entries) = fs::read_dir(dest_root) {
        for child in entries.flatten() {
            let name = child.file_name().to_string_lossy().into_owned();
            if !expected_names.contains(&name) {
                remove_link_only(&child.path())?;
            }
        }
    }
    if !test_flat_skill_index(dest_root, expected) {
        return Err(fail(
            format!(
                "flattened skill index verification failed: {}",
                dest_root.display()
            ),
            1,
        ));
    }
    out.push(format!(
        "linked: {} ({} flattened skills; {label})",
        dest_root.display(),
        expected.len()
    ));
    Ok(())
}

fn dir_has_one_level_skill(dir: &Path) -> bool {
    let Ok(entries) = fs::read_dir(dir) else {
        return false;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if entry.file_type().is_ok_and(|ft| ft.is_dir()) && p.join("SKILL.md").is_file() {
            return true;
        }
    }
    false
}

fn get_antigravity_entry_paths(repo_root: &Path) -> Vec<String> {
    let mut entries = Vec::new();
    let core_skills = repo_root.join("skills");
    if core_skills.is_dir() {
        let mut cat_names = Vec::new();
        if let Ok(rd) = fs::read_dir(&core_skills) {
            for e in rd.flatten() {
                if e.file_type().is_ok_and(|ft| ft.is_dir()) {
                    cat_names.push(e.file_name().to_string_lossy().into_owned());
                }
            }
        }
        cat_names.sort();
        for cat in cat_names {
            if dir_has_one_level_skill(&core_skills.join(&cat)) {
                entries.push(format!("skills/{cat}"));
            }
        }
    }
    let cmd_skills = repo_root.join("adapters").join("command-skills");
    if cmd_skills.is_dir() && dir_has_one_level_skill(&cmd_skills) {
        entries.push("adapters/command-skills".to_string());
    }
    entries
}

fn test_antigravity_manifest(repo_root: &Path, manifest_path: &Path) -> Result<usize, String> {
    if !manifest_path.is_file() {
        return Err(format!("missing manifest: {}", manifest_path.display()));
    }
    let raw = fs::read_to_string(manifest_path)
        .map_err(|_| format!("invalid JSON in {}", manifest_path.display()))?;
    let parsed =
        parse_json(&raw).map_err(|_| format!("invalid JSON in {}", manifest_path.display()))?;
    let Some(entries) = parsed
        .get_exact_unique("entries")
        .map_err(|_| format!("duplicate entries key in {}", manifest_path.display()))?
        .and_then(JsonValue::as_array)
    else {
        return Err(format!(
            "manifest has no entries: {}",
            manifest_path.display()
        ));
    };
    if entries.is_empty() {
        return Err(format!(
            "manifest has no entries: {}",
            manifest_path.display()
        ));
    }

    let mut manifest_paths = Vec::new();
    let mut total_skills = 0usize;
    let mut seen_names = BTreeSet::new();

    for entry in entries {
        let rel_path = entry
            .get_exact_unique("path")
            .map_err(|_| "manifest entry has duplicate path key".to_string())?
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        if rel_path.is_empty() {
            return Err("manifest entry missing path".to_string());
        }
        if !rel_path.split('/').all(|seg| {
            !seg.is_empty()
                && seg != "."
                && seg != ".."
                && !seg.contains('\\')
                && !seg.contains(':')
                && !seg.contains('\0')
        }) {
            return Err(format!("manifest entry path is unsafe: {rel_path}"));
        }
        manifest_paths.push(rel_path.clone());
        let resolved = repo_root.join(rel_path.replace('/', std::path::MAIN_SEPARATOR_STR));
        if is_reparse_link(&resolved) || !resolved.is_dir() {
            return Err(format!("manifest entry path not found: {rel_path}"));
        }
        let mut entry_count = 0usize;
        if let Ok(rd) = fs::read_dir(&resolved) {
            for sub in rd.flatten() {
                if !sub.file_type().is_ok_and(|ft| ft.is_dir()) {
                    continue;
                }
                let skill_file = sub.path().join("SKILL.md");
                if !skill_file.is_file() {
                    continue;
                }
                let skill_raw = fs::read_to_string(&skill_file).unwrap_or_default();
                let fm_name = extract_exact_fm_name(&skill_raw).ok_or_else(|| {
                    format!("SKILL.md missing valid name: {}", skill_file.display())
                })?;
                let dir_name = sub.file_name().to_string_lossy().into_owned();
                if fm_name != dir_name {
                    return Err(format!(
                        "skill folder '{dir_name}' does not match frontmatter name '{fm_name}'"
                    ));
                }
                if !seen_names.insert(fm_name.clone()) {
                    return Err(format!("duplicate skill name '{fm_name}'"));
                }
                entry_count += 1;
                total_skills += 1;
            }
        }
        if entry_count < 1 {
            return Err(format!(
                "manifest entry has no 1-level SKILL.md: {rel_path}"
            ));
        }
    }

    for expected in get_antigravity_entry_paths(repo_root) {
        if !manifest_paths.contains(&expected) {
            return Err(format!("manifest missing expected entry: {expected}"));
        }
    }
    if total_skills < 1 {
        return Err("manifest resolved 0 skills".to_string());
    }
    Ok(total_skills)
}

fn is_valid_sha256_hex(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn render_antigravity_manifest(entries: &[String]) -> String {
    let mut json_lines = Vec::new();
    json_lines.push("{".to_string());
    json_lines.push("  \"entries\": [".to_string());
    for (i, e) in entries.iter().enumerate() {
        let comma = if i + 1 < entries.len() { "," } else { "" };
        json_lines.push(format!("    {{ \"path\": \"{e}\" }}{comma}"));
    }
    json_lines.push("  ]".to_string());
    json_lines.push("}".to_string());
    format!("{}\n", json_lines.join("\n"))
}

fn check_antigravity_manifest_ownership(
    manifest_path: &Path,
    sidecar_path: &Path,
) -> Result<(), B3Error> {
    if !manifest_path.is_file() {
        return Ok(());
    }
    let raw = fs::read(manifest_path)
        .map_err(|e| fail(format!("cannot read {}: {e}", manifest_path.display()), 1))?;
    if sidecar_path.is_file() {
        let recorded = fs::read_to_string(sidecar_path)
            .map_err(|e| fail(format!("cannot read {}: {e}", sidecar_path.display()), 1))?;
        let recorded = recorded.trim();
        if !is_valid_sha256_hex(recorded) {
            return Err(fail(
                format!(
                    "OWNERSHIP_UNKNOWN: corrupt B3 manifest sidecar at {}; refusing to overwrite without --force",
                    sidecar_path.display()
                ),
                1,
            ));
        }
        if sha256_bytes_hex(&raw) == recorded {
            return Ok(());
        }
        return Err(fail(
            format!(
                "OWNERSHIP_MODIFIED: .agents/skills.json at {} was modified since last B3 sync; refusing to overwrite without --force",
                manifest_path.display()
            ),
            1,
        ));
    }
    Err(fail(
        format!(
            "OWNERSHIP_UNKNOWN: existing .agents/skills.json at {} has no B3 ownership record ({}); refusing to adopt or overwrite without --force",
            manifest_path.display(),
            sidecar_path.display()
        ),
        1,
    ))
}

fn read_cursor_rules_sidecar(sidecar_path: &Path) -> Result<BTreeMap<String, String>, B3Error> {
    assert_regular_file_or_missing(sidecar_path, ".cursor/rules/.b3-rules-manifest.sha256")?;
    let mut map = BTreeMap::new();
    if !sidecar_path.is_file() {
        return Ok(map);
    }
    let raw = fs::read_to_string(sidecar_path)
        .map_err(|e| fail(format!("cannot read {}: {e}", sidecar_path.display()), 1))?;
    for line in raw.replace("\r\n", "\n").lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Some((name, hex)) = trimmed.split_once('=') else {
            return Err(fail(
                format!(
                    "OWNERSHIP_UNKNOWN: corrupt Cursor rules sidecar at {}; refusing to overwrite without --force",
                    sidecar_path.display()
                ),
                1,
            ));
        };
        if !name.ends_with(".mdc")
            || name.contains('/')
            || name.contains('\\')
            || name.contains(':')
            || name.contains('\0')
            || name == ".."
            || !is_valid_sha256_hex(hex)
        {
            return Err(fail(
                format!(
                    "OWNERSHIP_UNKNOWN: invalid entry in Cursor rules sidecar at {}; refusing to overwrite without --force",
                    sidecar_path.display()
                ),
                1,
            ));
        }
        if map.insert(name.to_string(), hex.to_string()).is_some() {
            return Err(fail(
                format!(
                    "OWNERSHIP_UNKNOWN: duplicate entry in Cursor rules sidecar at {}; refusing to overwrite without --force",
                    sidecar_path.display()
                ),
                1,
            ));
        }
    }
    Ok(map)
}

fn write_cursor_rules_sidecar(
    sidecar_path: &Path,
    hashes: &BTreeMap<String, String>,
) -> Result<(), B3Error> {
    let mut lines = Vec::with_capacity(hashes.len());
    for (name, hex) in hashes {
        lines.push(format!("{name}={hex}"));
    }
    let body = if lines.is_empty() {
        String::new()
    } else {
        format!("{}\n", lines.join("\n"))
    };
    write_utf8_no_bom_lf(sidecar_path, &body)
}

#[derive(Debug, Clone)]
struct CanonicalRule {
    stem: String,
    always_apply: bool,
    description: String,
}

fn collect_canonical_rules(rules_dir: &Path) -> Result<Vec<CanonicalRule>, B3Error> {
    if !rules_dir.is_dir() {
        return Ok(Vec::new());
    }
    let mut paths = Vec::new();
    let rd = fs::read_dir(rules_dir)
        .map_err(|e| fail(format!("cannot read {}: {e}", rules_dir.display()), 1))?;
    for entry in rd.flatten() {
        if !entry.file_type().is_ok_and(|ft| ft.is_file()) {
            continue;
        }
        let p = entry.path();
        if p.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        paths.push(p);
    }
    paths.sort();

    let mut rules = Vec::new();
    for p in paths {
        let raw = fs::read_to_string(&p)
            .map_err(|e| fail(format!("cannot read {}: {e}", p.display()), 1))?;
        let norm = raw.replace("\r\n", "\n").replace('\r', "\n");
        let mut lines = norm.split('\n');
        if lines.next().map(str::trim) != Some("---") {
            continue;
        }
        let mut rule_type = String::new();
        let mut strength = String::new();
        let mut scope = String::new();
        let mut found_end = false;
        let mut body_lines = Vec::new();
        for line in lines {
            if !found_end {
                if line.trim() == "---" {
                    found_end = true;
                } else if let Some((k, v)) = line.split_once(':') {
                    let key = k.trim();
                    let val = v.trim();
                    match key {
                        "type" => rule_type = val.to_string(),
                        "strength" => strength = val.to_string(),
                        "scope" => scope = val.to_string(),
                        _ => {}
                    }
                }
            } else {
                body_lines.push(line);
            }
        }
        if !found_end || rule_type != "rule" {
            continue;
        }
        let stem = p
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        if stem.is_empty() {
            continue;
        }
        let mut heading = String::new();
        let mut summary = String::new();
        for b in body_lines {
            let t = b.trim();
            if t.is_empty() {
                continue;
            }
            if heading.is_empty() && t.starts_with("# ") {
                heading = t.trim_start_matches("# ").trim().to_string();
                continue;
            }
            summary = t.to_string();
            break;
        }
        let raw_desc = match (heading.is_empty(), summary.is_empty()) {
            (false, false) => format!("{heading} — {summary}"),
            (false, true) => heading,
            (true, false) => summary,
            (true, true) => format!("Portable B3 rule: {stem}"),
        };
        let description: String = raw_desc.chars().take(160).collect();
        rules.push(CanonicalRule {
            stem,
            always_apply: strength == "hard" && scope == "global",
            description,
        });
    }
    Ok(rules)
}

fn render_cursor_rule_mdc(rule: &CanonicalRule) -> String {
    let escaped_desc = rule.description.replace('\\', "\\\\").replace('"', "\\\"");
    format!(
        "---\ndescription: \"{escaped_desc}\"\nalwaysApply: {}\n---\n<!-- b3-generated-cursor-rule: source=rules/{}.md -->\n\nFollow the portable {} rule:\n\n@rules/{}.md\n",
        rule.always_apply, rule.stem, rule.stem, rule.stem
    )
}

fn sync_cursor_rules(
    root: &Path,
    dry_run: bool,
    verify_only: bool,
    force: bool,
    out: &mut Vec<String>,
) -> Result<(), B3Error> {
    let rules = collect_canonical_rules(&root.join("rules"))?;
    if rules.is_empty() {
        return Err(fail(
            format!(
                "no canonical rules found under {}",
                root.join("rules").display()
            ),
            1,
        ));
    }
    let cursor_dir = root.join(".cursor");
    let rules_dest = cursor_dir.join("rules");
    let sidecar_path = rules_dest.join(".b3-rules-manifest.sha256");
    assert_regular_dir_or_missing(&cursor_dir, ".cursor")?;
    assert_regular_dir_or_missing(&rules_dest, ".cursor/rules")?;
    assert_regular_file_or_missing(&sidecar_path, ".cursor/rules/.b3-rules-manifest.sha256")?;

    let mut expected_stems = BTreeSet::new();
    for r in &rules {
        expected_stems.insert(r.stem.as_str());
    }

    if verify_only {
        if !rules_dest.is_dir() {
            return Err(fail(
                format!(
                    "verify failed: missing generated Cursor rules directory {}",
                    rules_dest.display()
                ),
                1,
            ));
        }
        let sidecar = read_cursor_rules_sidecar(&sidecar_path)?;
        for r in &rules {
            let mdc_path = rules_dest.join(format!("{}.mdc", r.stem));
            assert_regular_file_or_missing(&mdc_path, &format!(".cursor/rules/{}.mdc", r.stem))?;
            if !mdc_path.is_file() {
                return Err(fail(
                    format!("verify failed: missing {}", mdc_path.display()),
                    1,
                ));
            }
            let raw = fs::read_to_string(&mdc_path)
                .map_err(|e| fail(format!("verify failed: {}: {e}", mdc_path.display()), 1))?;
            let expected_content = render_cursor_rule_mdc(r);
            if raw != expected_content {
                return Err(fail(
                    format!(
                        "verify failed: {} does not match exact generated wrapper for canonical rules/{}.md (alwaysApply: {})",
                        mdc_path.display(),
                        r.stem,
                        r.always_apply
                    ),
                    1,
                ));
            }
        }
        if let Ok(rd) = fs::read_dir(&rules_dest) {
            for entry in rd.flatten() {
                let p = entry.path();
                if p.extension().and_then(|e| e.to_str()) != Some("mdc") {
                    continue;
                }
                let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
                if expected_stems.contains(stem) {
                    continue;
                }
                if is_reparse_link(&p) {
                    return Err(fail(
                        format!(
                            "verify failed: reparse link found in Cursor rules: {}",
                            p.display()
                        ),
                        1,
                    ));
                }
                let file_name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
                let has_marker = fs::read_to_string(&p)
                    .ok()
                    .is_some_and(|raw| raw.contains("<!-- b3-generated-cursor-rule:"));
                if sidecar.contains_key(file_name) || has_marker {
                    return Err(fail(
                        format!(
                            "verify failed: stale B3-generated Cursor rule wrapper found at {}",
                            p.display()
                        ),
                        1,
                    ));
                }
            }
        }
        return Ok(());
    }

    let sidecar = if force {
        read_cursor_rules_sidecar(&sidecar_path).unwrap_or_default()
    } else {
        read_cursor_rules_sidecar(&sidecar_path)?
    };

    for r in &rules {
        let file_name = format!("{}.mdc", r.stem);
        let mdc_path = rules_dest.join(&file_name);
        assert_regular_file_or_missing(&mdc_path, &format!(".cursor/rules/{file_name}"))?;
        if !force && mdc_path.is_file() {
            let desired = render_cursor_rule_mdc(r);
            let raw_bytes = fs::read(&mdc_path)
                .map_err(|e| fail(format!("cannot read {}: {e}", mdc_path.display()), 1))?;
            let exact_unchanged = raw_bytes == desired.as_bytes();
            let sidecar_unchanged = sidecar
                .get(&file_name)
                .is_some_and(|recorded| *recorded == sha256_bytes_hex(&raw_bytes));
            if !exact_unchanged && !sidecar_unchanged {
                return Err(fail(
                    format!(
                        "existing modified or unmanaged .cursor/rules/{file_name} at {}; refusing to overwrite without --force",
                        mdc_path.display()
                    ),
                    1,
                ));
            }
        }
    }

    let mut stale_paths = Vec::new();
    let mut stale_conflicts = Vec::new();
    for (file_name, recorded_sha) in &sidecar {
        let stem = file_name.strip_suffix(".mdc").unwrap_or("");
        if expected_stems.contains(stem) {
            continue;
        }
        let p = rules_dest.join(file_name);
        assert_regular_file_or_missing(&p, &format!(".cursor/rules/{file_name}"))?;
        if p.is_file() {
            if force {
                stale_paths.push(p);
            } else {
                let bytes = fs::read(&p)
                    .map_err(|e| fail(format!("cannot read {}: {e}", p.display()), 1))?;
                if sha256_bytes_hex(&bytes) == *recorded_sha {
                    stale_paths.push(p);
                } else {
                    stale_conflicts.push(p.display().to_string());
                }
            }
        }
    }
    if rules_dest.is_dir() {
        if let Ok(rd) = fs::read_dir(&rules_dest) {
            for entry in rd.flatten() {
                let p = entry.path();
                if p.extension().and_then(|e| e.to_str()) != Some("mdc") {
                    continue;
                }
                let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
                if expected_stems.contains(stem) {
                    continue;
                }
                let file_name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
                if sidecar.contains_key(file_name) || is_reparse_link(&p) {
                    continue;
                }
                if fs::read_to_string(&p)
                    .ok()
                    .is_some_and(|raw| raw.contains("<!-- b3-generated-cursor-rule:"))
                {
                    if force {
                        stale_paths.push(p);
                    } else {
                        stale_conflicts.push(p.display().to_string());
                    }
                }
            }
        }
    }
    if !stale_conflicts.is_empty() {
        return Err(fail(
            format!(
                "STALE_RULE_CONFLICT: modified stale B3 Cursor rule wrapper(s) preserved at {}; resolve manually by reviewing edits and removing/renaming the stale file (or re-run 'b3 sync --host cursor --force' to prune)",
                stale_conflicts.join(", ")
            ),
            1,
        ));
    }

    if dry_run {
        out.push(format!(
            "dry-run: sync {} Cursor rule wrapper(s) in {} (prune {} stale)",
            rules.len(),
            rules_dest.display(),
            stale_paths.len()
        ));
        return Ok(());
    }

    fs::create_dir_all(&rules_dest)
        .map_err(|e| fail(format!("cannot create {}: {e}", rules_dest.display()), 1))?;
    let mut written = 0usize;
    let mut next_hashes = BTreeMap::new();
    for r in &rules {
        let file_name = format!("{}.mdc", r.stem);
        let mdc_path = rules_dest.join(&file_name);
        let desired = render_cursor_rule_mdc(r);
        let unchanged = fs::read_to_string(&mdc_path).ok().as_deref() == Some(desired.as_str());
        if !unchanged {
            write_utf8_no_bom_lf(&mdc_path, &desired)?;
            written += 1;
        }
        next_hashes.insert(file_name, sha256_bytes_hex(desired.as_bytes()));
    }
    for stale in &stale_paths {
        fs::remove_file(stale)
            .map_err(|e| fail(format!("cannot prune {}: {e}", stale.display()), 1))?;
    }
    write_cursor_rules_sidecar(&sidecar_path, &next_hashes)?;
    out.push(format!(
        "synced: {} ({} Cursor rule wrappers; {} updated, {} pruned)",
        rules_dest.display(),
        rules.len(),
        written,
        stale_paths.len()
    ));
    Ok(())
}

fn extract_exact_fm_name(raw: &str) -> Option<String> {
    let norm = raw.replace("\r\n", "\n").replace('\r', "\n");
    for line in norm.split('\n') {
        let trimmed = line.trim_end();
        if let Some(rest) = trimmed.strip_prefix("name:") {
            let candidate = rest.trim();
            if !candidate.is_empty()
                && candidate
                    .bytes()
                    .all(|b| matches!(b, b'a'..=b'z' | b'0'..=b'9' | b'-'))
            {
                return Some(candidate.to_string());
            }
        }
    }
    None
}

fn sync_personal_config(home_dir: &Path, dry_run: bool, verify_only: bool, out: &mut Vec<String>) {
    if dry_run
        || verify_only
        || std::env::var("B3_SKIP_CONFIG_INIT").ok().as_deref() == Some("1")
        || std::env::var("B3_SKIP_MODEL_INIT").ok().as_deref() == Some("1")
    {
        return;
    }
    if let Ok(status) = initialize_personal_config_file(home_dir, None, false, true) {
        if let Some(msg) = format_personal_config_status(home_dir, &status, true) {
            out.push(msg);
        }
    }
}

/// Executes `b3 sync` for `cursor|codex|claude|antigravity`.
pub fn run(
    repo_root_raw: &str,
    host_name: &str,
    dry_run: bool,
    verify_only: bool,
    force: bool,
) -> Result<(String, i32), B3Error> {
    if !matches!(host_name, "cursor" | "codex" | "claude" | "antigravity") {
        return Err(fail(
            "Usage: b3 sync --host cursor|codex|claude|antigravity [--repo-root <dir>] [--dry-run] [--verify-only] [--force]",
            1,
        ));
    }

    let root_resolved = resolve_b3_repo_root_auto(repo_root_raw)?;
    let root = PathBuf::from(normalize_abs_path_str(&root_resolved));
    if !verify_only && is_reparse_link(&root) {
        return Err(fail(
            format!("refusing to sync link-based repo root: {}", root.display()),
            1,
        ));
    }
    let skills_source = root.join("skills");
    let commands_source = root.join("commands");
    let agents_source = root.join("agents");
    let command_skills_source = root.join("adapters").join("command-skills");

    if !test_skill_source(&skills_source) {
        return Err(fail(
            format!(
                "Skills source missing or has no SKILL.md: {}",
                skills_source.display()
            ),
            1,
        ));
    }

    let cursor_skills_dest = root.join(".cursor").join("skills");
    let cursor_commands_dest = root.join(".cursor").join("commands");
    let cursor_agents_dest = root.join(".cursor").join("agents");
    let codex_skills_dest = root.join(".agents").join("skills");
    let claude_skills_dest = root.join(".claude").join("skills");
    let claude_agents_dest = root.join(".claude").join("agents");
    let antigravity_manifest = root.join(".agents").join("skills.json");
    let antigravity_sidecar = root.join(".agents").join(".b3-skills-manifest.sha256");

    let mut out = Vec::new();

    match host_name {
        "antigravity" => {
            if has_active_path(&codex_skills_dest) {
                eprintln!(
                    "WARNING: coexistence notice: .agents/skills exists alongside .agents/skills.json; Antigravity may double-discover skills."
                );
            }
            assert_regular_dir_or_missing(&root.join(".agents"), ".agents")?;
            assert_regular_file_or_missing(&antigravity_manifest, ".agents/skills.json")?;
            assert_regular_file_or_missing(
                &antigravity_sidecar,
                ".agents/.b3-skills-manifest.sha256",
            )?;
            let entries = get_antigravity_entry_paths(&root);
            if entries.is_empty() {
                return Err(fail(
                    format!(
                        "no 1-level skill category directories found under {}",
                        skills_source.display()
                    ),
                    1,
                ));
            }
            let json_text = render_antigravity_manifest(&entries);

            if verify_only {
                let count = test_antigravity_manifest(&root, &antigravity_manifest)
                    .map_err(|reason| fail(format!("verify failed: {reason}"), 1))?;
                check_antigravity_manifest_ownership(&antigravity_manifest, &antigravity_sidecar)?;
                let raw = fs::read(&antigravity_manifest).map_err(|e| {
                    fail(
                        format!(
                            "verify failed: cannot read {}: {e}",
                            antigravity_manifest.display()
                        ),
                        1,
                    )
                })?;
                if raw != json_text.as_bytes() {
                    return Err(fail(
                        format!(
                            "verify failed: .agents/skills.json at {} has drifted from expected canonical B3 manifest; re-run 'b3 sync --host antigravity'",
                            antigravity_manifest.display()
                        ),
                        1,
                    ));
                }
                return Ok((
                    format!(
                        "verify ok: {} (antigravity); {count} SKILL.md entries visible",
                        antigravity_manifest.display()
                    ),
                    0,
                ));
            }

            if !force {
                check_antigravity_manifest_ownership(&antigravity_manifest, &antigravity_sidecar)?;
            }

            if dry_run {
                return Ok((
                    format!(
                        "dry-run: write {} with {} entries ({})",
                        antigravity_manifest.display(),
                        entries.len(),
                        entries.join(", ")
                    ),
                    0,
                ));
            }

            write_utf8_no_bom_lf(&antigravity_manifest, &json_text)?;
            write_utf8_no_bom_lf(
                &antigravity_sidecar,
                &format!("{}\n", sha256_bytes_hex(json_text.as_bytes())),
            )?;
            let count = test_antigravity_manifest(&root, &antigravity_manifest)
                .map_err(|r| fail(format!("manifest written but verification failed: {r}"), 1))?;
            sync_personal_config(&root, dry_run, verify_only, &mut out);
            out.push(format!(
                "synced: {} (antigravity); {count} SKILL.md entries visible",
                antigravity_manifest.display()
            ));
            out.push(
                "note: this proves .agents/skills.json resolves to 1-level SKILL.md entries, not Antigravity runtime discovery"
                    .to_string(),
            );
            Ok((out.join("\n"), 0))
        }
        "cursor" => {
            if !commands_source.is_dir() {
                return Err(fail(
                    format!("Commands source missing: {}", commands_source.display()),
                    1,
                ));
            }
            if !agents_source.is_dir() {
                return Err(fail(
                    format!("Agents source missing: {}", agents_source.display()),
                    1,
                ));
            }
            if verify_only {
                let ok = test_link_target(&cursor_skills_dest, &skills_source, false)
                    && test_skill_source(&cursor_skills_dest)
                    && test_link_target(&cursor_commands_dest, &commands_source, false)
                    && test_link_target(&cursor_agents_dest, &agents_source, false);
                if !ok {
                    return Err(fail(
                        "verify failed: .cursor/{skills,commands,agents} links are missing or invalid",
                        1,
                    ));
                }
                sync_cursor_rules(&root, false, true, force, &mut out)?;
                return Ok((
                    "verify ok: .cursor/{skills,commands,agents,rules} -> canonical root (cursor)"
                        .to_string(),
                    0,
                ));
            }
            if !force {
                if has_active_path(&codex_skills_dest) {
                    return Err(fail(
                        "coexistence guard: .agents/skills exists; Cursor cross-loads it and would duplicate skills. Remove .agents/skills or re-run with -Force",
                        1,
                    ));
                }
                if has_active_path(&claude_skills_dest) {
                    return Err(fail(
                        "coexistence guard: .claude/skills exists; Cursor cross-loads it and would duplicate skills. Remove .claude/skills or re-run with -Force",
                        1,
                    ));
                }
            }
            assert_regular_dir_or_missing(&root.join(".cursor"), ".cursor")?;
            if !dry_run {
                let mut rule_preflight = Vec::new();
                sync_cursor_rules(&root, true, false, force, &mut rule_preflight)?;
            }
            sync_directory_link(
                &cursor_skills_dest,
                &skills_source,
                "cursor skills",
                dry_run,
                &mut out,
            )?;
            sync_directory_link(
                &cursor_commands_dest,
                &commands_source,
                "cursor commands",
                dry_run,
                &mut out,
            )?;
            sync_directory_link(
                &cursor_agents_dest,
                &agents_source,
                "cursor agents",
                dry_run,
                &mut out,
            )?;
            sync_cursor_rules(&root, dry_run, false, force, &mut out)?;
            sync_personal_config(&root, dry_run, verify_only, &mut out);
            out.push(
                "note: this proves filesystem links, not Cursor runtime skill discovery"
                    .to_string(),
            );
            Ok((out.join("\n"), 0))
        }
        "codex" => {
            let expected_flat = get_expected_flat_skills(&skills_source, &command_skills_source)?;
            if verify_only {
                if test_flat_skill_index(&codex_skills_dest, &expected_flat) {
                    return Ok((
                        format!(
                            "verify ok: {} ({} flattened skills; codex)",
                            codex_skills_dest.display(),
                            expected_flat.len()
                        ),
                        0,
                    ));
                }
                return Err(fail(
                    format!(
                        "verify failed: {} is not a valid flattened skill index",
                        codex_skills_dest.display()
                    ),
                    1,
                ));
            }
            if !force && has_active_path(&cursor_skills_dest) {
                return Err(fail(
                    "coexistence guard: .cursor/skills exists; Cursor cross-loads .agents/skills and would duplicate skills. Remove .cursor/skills or re-run with -Force",
                    1,
                ));
            }
            if antigravity_manifest.is_file() {
                eprintln!(
                    "WARNING: coexistence notice: .agents/skills.json exists for Antigravity; if Antigravity also opens this checkout, it may read both .agents/skills.json and .agents/skills."
                );
            }
            if !dry_run {
                assert_regular_dir_or_missing(&root.join(".agents"), ".agents")?;
            }
            sync_flat_skill_index(
                &codex_skills_dest,
                &expected_flat,
                "codex",
                dry_run,
                &mut out,
            )?;
            sync_personal_config(&root, dry_run, verify_only, &mut out);
            out.push(
                "note: this proves filesystem links, not Codex runtime skill discovery".to_string(),
            );
            Ok((out.join("\n"), 0))
        }
        "claude" => {
            if !agents_source.is_dir() {
                return Err(fail(
                    format!("Agents source missing: {}", agents_source.display()),
                    1,
                ));
            }
            let expected_flat = get_expected_flat_skills(&skills_source, &command_skills_source)?;
            if verify_only {
                if test_flat_skill_index(&claude_skills_dest, &expected_flat)
                    && test_link_target(&claude_agents_dest, &agents_source, false)
                {
                    return Ok((
                        format!(
                            "verify ok: {} ({} flattened skills) + {} -> {} (claude)",
                            claude_skills_dest.display(),
                            expected_flat.len(),
                            claude_agents_dest.display(),
                            agents_source.display()
                        ),
                        0,
                    ));
                }
                return Err(fail(
                    "verify failed: .claude/skills or .claude/agents link is missing or invalid",
                    1,
                ));
            }
            if !force && has_active_path(&cursor_skills_dest) {
                return Err(fail(
                    "coexistence guard: .cursor/skills exists; Cursor cross-loads .claude/skills and would duplicate skills. Remove .cursor/skills or re-run with -Force",
                    1,
                ));
            }
            if !dry_run {
                assert_regular_dir_or_missing(&root.join(".claude"), ".claude")?;
            }
            sync_flat_skill_index(
                &claude_skills_dest,
                &expected_flat,
                "claude",
                dry_run,
                &mut out,
            )?;
            sync_directory_link(
                &claude_agents_dest,
                &agents_source,
                "claude agents",
                dry_run,
                &mut out,
            )?;
            sync_personal_config(&root, dry_run, verify_only, &mut out);
            out.push(
                "note: this proves filesystem links, not Claude Code runtime skill discovery"
                    .to_string(),
            );
            Ok((out.join("\n"), 0))
        }
        _ => unreachable!(),
    }
}
