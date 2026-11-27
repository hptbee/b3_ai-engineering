use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use crate::adapters::common::{
    add_canonical_skills_with_bucket, assert_regular_dir_or_missing,
    assert_regular_file_or_missing, create_dir_link, file_sha256, get_canonical_markdown_names,
    get_skill_overlaps, is_reparse_link, normalize_abs_path_str, normalize_path_str,
    path_exists_or_link, read_b3_manifest, remove_empty_regular_dir, remove_link_only,
    resolve_b3_home_auto, resolve_user_home_dir, split_yaml_frontmatter, test_link_target,
    text_sha256_lf, to_forward_path, uninstall_managed_file, uninstall_managed_link,
    write_b3_manifest, write_utf8_no_bom_lf, B3Manifest,
};
use crate::error::{fail, B3Error};
use crate::fs::{paths_equal_fs, remove_dir_tree_safely, sort_ordinal};
use crate::json::{parse_json, JsonValue};

struct RenderedAgent {
    file_name: String,
    content: String,
}

fn parse_canonical_agent(
    file_path: &Path,
    b3_home_forward: &str,
) -> Result<RenderedAgent, B3Error> {
    let parsed = split_yaml_frontmatter(file_path, true)?;
    let mut name = String::new();
    let mut readonly_val = String::new();
    let mut desc_lines: Vec<String> = Vec::new();
    let mut current_key = String::new();

    for line in parsed
        .fm_lines
        .iter()
        .skip(1)
        .take(parsed.fm_lines.len().saturating_sub(2))
    {
        if let Some((k, v)) = parse_top_yaml_key(line) {
            current_key = k.to_string();
            match current_key.as_str() {
                "name" => name = v.trim().to_string(),
                "readonly" => readonly_val = v.trim().to_ascii_lowercase(),
                "description" => desc_lines.push(line.clone()),
                _ => {}
            }
        } else if current_key == "description"
            && ((line.starts_with(char::is_whitespace) && !line.trim().is_empty())
                || line.trim().is_empty())
        {
            desc_lines.push(line.clone());
        }
    }
    while matches!(desc_lines.last(), Some(last) if last.trim().is_empty()) {
        desc_lines.pop();
    }
    if name.is_empty() {
        return Err(fail(
            format!("agent missing name in frontmatter: {}", file_path.display()),
            1,
        ));
    }
    if desc_lines.is_empty() {
        return Err(fail(
            format!(
                "agent missing description in frontmatter: {}",
                file_path.display()
            ),
            1,
        ));
    }
    if !matches!(readonly_val.as_str(), "true" | "false") {
        return Err(fail(
            format!(
                "agent missing boolean readonly in frontmatter: {}",
                file_path.display()
            ),
            1,
        ));
    }
    let tools_line = if readonly_val == "true" {
        "tools: [read_file]"
    } else {
        "tools: [read_file, edit_file, write_file, run_command, manage_task]"
    };
    let file_name = file_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string();
    let mut out_lines = Vec::new();
    out_lines.push("---".to_string());
    out_lines.push(format!("name: {name}"));
    out_lines.extend(desc_lines);
    out_lines.push("subagent: true".to_string());
    out_lines.push("mainAgent: false".to_string());
    out_lines.push(tools_line.to_string());
    out_lines.push("---".to_string());
    out_lines.push(String::new());
    out_lines.push(format!(
        "<!-- Generated from {b3_home_forward}/agents/{file_name} - do not edit here -->"
    ));
    out_lines.push(String::new());
    if !parsed.body.is_empty() {
        out_lines.push(parsed.body);
    }
    Ok(RenderedAgent {
        file_name,
        content: format!("{}\n", out_lines.join("\n").trim_end()),
    })
}

fn parse_top_yaml_key(line: &str) -> Option<(&str, &str)> {
    let colon = line.find(':')?;
    let key = &line[..colon];
    if key.is_empty()
        || !key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return None;
    }
    let val = line[colon + 1..].trim_start_matches([' ', '\t']);
    Some((key, val))
}

fn test_b3_plugin_json(json_path: &Path, allow_extra_keys: bool) -> bool {
    if !json_path.is_file() {
        return false;
    }
    let Ok(raw) = fs::read_to_string(json_path) else {
        return false;
    };
    let Ok(JsonValue::Object(entries)) = parse_json(&raw) else {
        return false;
    };
    let is_b3 = entries
        .iter()
        .any(|(k, v)| k == "name" && v.as_str() == Some("b3-ai-engineering"));
    if !is_b3 {
        return false;
    }
    if allow_extra_keys {
        return true;
    }
    entries.iter().all(|(k, _)| {
        matches!(
            k.as_str(),
            "name" | "displayName" | "version" | "description" | "suggestedPrompts"
        )
    })
}

fn normalize_skill_json_path(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let mut p = trimmed.replace('\\', "/");
    let b = p.as_bytes();
    if b.len() >= 2 && b[0].is_ascii_lowercase() && b[1] == b':' {
        let up = (b[0] as char).to_ascii_uppercase();
        p = format!("{up}{}", &p[1..]);
    }
    let is_win_root = p.len() == 3
        && p.as_bytes()[0].is_ascii_alphabetic()
        && p.as_bytes()[1] == b':'
        && p.ends_with('/');
    if p == "/" || is_win_root {
        return p;
    }
    while p.ends_with('/') {
        p.pop();
    }
    p
}

fn test_is_b3_managed_skill_path(candidate: &str, b3_prefixes: &[String]) -> bool {
    let norm = normalize_skill_json_path(candidate);
    if norm.is_empty() {
        return false;
    }
    for raw_prefix in b3_prefixes {
        let prefix = normalize_skill_json_path(raw_prefix);
        if prefix.is_empty() {
            continue;
        }
        let cmd_path = if prefix == "/" {
            "/adapters/command-skills".to_string()
        } else {
            format!("{prefix}/adapters/command-skills")
        };
        let skills_exact = if prefix == "/" {
            "/skills".to_string()
        } else {
            format!("{prefix}/skills")
        };
        let skills_prefix = if prefix == "/" {
            "/skills/".to_string()
        } else {
            format!("{prefix}/skills/")
        };
        if paths_equal_fs(&norm, &cmd_path, cfg!(windows))
            || paths_equal_fs(&norm, &skills_exact, cfg!(windows))
            || if cfg!(windows) {
                norm.len() >= skills_prefix.len()
                    && norm[..skills_prefix.len()].eq_ignore_ascii_case(&skills_prefix)
            } else {
                norm.starts_with(&skills_prefix)
            }
        {
            return true;
        }
    }
    false
}

fn get_desired_skills_json_entries(
    core_map: &BTreeMap<String, PathBuf>,
    cmd_map: &BTreeMap<String, PathBuf>,
) -> Vec<String> {
    let mut seen: Vec<String> = Vec::new();
    let mut result = Vec::new();
    for bucket in [core_map, cmd_map] {
        let mut parents = Vec::new();
        for skill_dir in bucket.values() {
            if let Some(parent_dir) = skill_dir.parent() {
                let p = normalize_skill_json_path(&to_forward_path(parent_dir));
                if !p.is_empty() {
                    parents.push(p);
                }
            }
        }
        for p in sort_ordinal(parents, false) {
            if !seen.iter().any(|s| paths_equal_fs(s, &p, cfg!(windows))) {
                seen.push(p.clone());
                result.push(p);
            }
        }
    }
    result
}

struct SkillsJsonState {
    exists: bool,
    valid: bool,
    error: String,
    other_fields: Vec<(String, JsonValue)>,
    has_entries_key: bool,
    entries: Vec<JsonValue>,
}

fn read_skills_json_state(json_path: &Path) -> SkillsJsonState {
    let mut st = SkillsJsonState {
        exists: false,
        valid: true,
        error: String::new(),
        other_fields: Vec::new(),
        has_entries_key: false,
        entries: Vec::new(),
    };
    if !json_path.is_file() {
        return st;
    }
    st.exists = true;
    let raw = match fs::read_to_string(json_path) {
        Ok(s) => s,
        Err(e) => {
            st.valid = false;
            st.error = format!("invalid JSON in global skills.json: {e}");
            return st;
        }
    };
    let clean = raw.strip_prefix('\u{FEFF}').unwrap_or(&raw);
    let parsed = match parse_json(clean) {
        Ok(v) => v,
        Err(e) => {
            st.valid = false;
            st.error = format!("invalid JSON in global skills.json: {e}");
            return st;
        }
    };
    let JsonValue::Object(props) = parsed else {
        st.valid = false;
        st.error = "global skills.json root must be a JSON object".to_string();
        return st;
    };
    for (k, v) in props {
        if k == "entries" {
            st.has_entries_key = true;
            if let JsonValue::Array(arr) = v {
                st.entries = arr;
            } else {
                st.valid = false;
                st.error = "global skills.json \"entries\" must be a JSON array".to_string();
                return st;
            }
        } else {
            st.other_fields.push((k, v));
        }
    }
    st
}

fn convert_to_skills_json_content(
    other_fields: &[(String, JsonValue)],
    entries: &[JsonValue],
) -> String {
    let mut obj_fields = other_fields.to_vec();
    obj_fields.push(("entries".to_string(), JsonValue::Array(entries.to_vec())));
    format!("{}\n", JsonValue::Object(obj_fields).to_json_pretty())
}

fn get_uninstall_b3_prefixes(plugin_root: &Path, manifest: &B3Manifest) -> Vec<String> {
    let mut raw_prefixes = Vec::new();
    if manifest.exists && !manifest.b3_home.is_empty() {
        let p = normalize_skill_json_path(&manifest.b3_home);
        if !p.is_empty() {
            raw_prefixes.push(p);
        }
    }
    let r_path = plugin_root.join("rules").join("AGENTS.md");
    if r_path.is_file() && !is_reparse_link(&r_path) {
        if let Ok(r_text) = fs::read_to_string(&r_path) {
            if let Some(pos) = r_text.find("Generated from B3_HOME:") {
                let rest = &r_text[pos + "Generated from B3_HOME:".len()..];
                if let Some(q1) = rest.find('`') {
                    let after_q1 = &rest[q1 + 1..];
                    if let Some(q2) = after_q1.find('`') {
                        let p = normalize_skill_json_path(&after_q1[..q2]);
                        if !p.is_empty() {
                            raw_prefixes.push(p);
                        }
                    }
                }
            }
        }
    }
    let sk_dir = plugin_root.join("skills");
    if sk_dir.is_dir() && !is_reparse_link(&sk_dir) {
        if let Ok(rd) = fs::read_dir(&sk_dir) {
            for entry in rd.flatten() {
                let p = entry.path();
                if !is_reparse_link(&p) {
                    continue;
                }
                if let Ok(target) = fs::read_link(&p) {
                    let t_norm = normalize_skill_json_path(&to_forward_path(&target));
                    if let Some(prefix) = extract_prefix_from_skill_target(&t_norm) {
                        raw_prefixes.push(prefix);
                    }
                }
            }
        }
    }
    let mut uniq = BTreeSet::new();
    for p in raw_prefixes {
        if !p.is_empty() {
            uniq.insert(p);
        }
    }
    sort_ordinal(uniq, false)
}

fn extract_prefix_from_skill_target(t_norm: &str) -> Option<String> {
    let parts: Vec<&str> = t_norm.split('/').collect();
    if parts.len() >= 3
        && parts[parts.len() - 3] == "adapters"
        && parts[parts.len() - 2] == "command-skills"
    {
        let prefix = parts[..parts.len() - 3].join("/");
        return Some(normalize_skill_json_path(&prefix));
    }
    if parts.len() >= 3 && parts[parts.len() - 3] == "skills" {
        let prefix = parts[..parts.len() - 3].join("/");
        return Some(normalize_skill_json_path(&prefix));
    }
    None
}

fn check_antigravity_coexistence(
    user_home: &Path,
    plugin_root: &Path,
    all_skill_names: &[String],
    out: &mut Vec<String>,
) {
    let plugin_norm = normalize_abs_path_str(plugin_root);
    let loose_overlaps = get_skill_overlaps(
        &user_home.join(".gemini").join("config").join("skills"),
        all_skill_names,
    );
    if !loose_overlaps.is_empty() {
        out.push(format!(
            "COEXISTENCE_WARNING: ~/.gemini/config/skills contains {} overlapping B3 skill(s) ({}...); remove loose copies to prevent duplicate discovery.",
            loose_overlaps.len(),
            loose_overlaps[0]
        ));
    }
    let plugins_dir = user_home.join(".gemini").join("config").join("plugins");
    if plugins_dir.is_dir() {
        if let Ok(rd) = fs::read_dir(&plugins_dir) {
            for cand in rd.flatten() {
                if !cand.file_type().is_ok_and(|ft| ft.is_dir()) {
                    continue;
                }
                let cand_path = cand.path();
                let cand_norm = normalize_abs_path_str(&cand_path);
                if paths_equal_fs(&cand_norm, &plugin_norm, cfg!(windows)) {
                    continue;
                }
                if test_b3_plugin_json(&cand_path.join("plugin.json"), true) {
                    out.push(format!(
                        "COEXISTENCE_WARNING: duplicate b3-ai-engineering plugin found at {}; only one plugin directory with name 'b3-ai-engineering' should exist.",
                        cand_path.display()
                    ));
                }
            }
        }
    }
    let ag_overlaps =
        get_skill_overlaps(&user_home.join(".agents").join("skills"), all_skill_names);
    if !ag_overlaps.is_empty() {
        out.push(format!(
            "COEXISTENCE_WARNING: ~/.agents/skills contains {} overlapping B3 skill(s); global Antigravity discovery may duplicate bundled plugin skills.",
            ag_overlaps.len()
        ));
    }
}

/// Executes `b3 install antigravity`.
pub fn run(
    action_raw: &str,
    plugin_root_raw: &str,
    b3_home_raw: &str,
    user_home_raw: &str,
    dry_run: bool,
    force: bool,
) -> Result<(String, i32), B3Error> {
    let action = if action_raw.trim().is_empty() {
        "install"
    } else {
        action_raw.trim()
    };
    if !matches!(action, "install" | "update" | "verify" | "uninstall") {
        return Err(fail(
            format!("invalid --action '{action}' (expected install|update|verify|uninstall)"),
            1,
        ));
    }

    let user_home_override = if user_home_raw.trim().is_empty() {
        None
    } else {
        Some(PathBuf::from(normalize_path_str(user_home_raw.trim())?))
    };
    let user_home = resolve_user_home_dir(user_home_override.as_deref());

    let plugin_root_str = if plugin_root_raw.trim().is_empty() {
        normalize_abs_path_str(
            &user_home
                .join(".gemini")
                .join("config")
                .join("plugins")
                .join("b3-ai-engineering"),
        )
    } else {
        normalize_path_str(plugin_root_raw.trim())?
    };
    let plugin_root = PathBuf::from(&plugin_root_str);
    let plugin_root_forward = to_forward_path(&plugin_root);
    let manifest_file = plugin_root.join(".b3-plugin-manifest");
    let gemini_dir = user_home.join(".gemini");
    let gemini_config_dir = gemini_dir.join("config");
    let skills_json_path = gemini_config_dir.join("skills.json");

    let mut out = Vec::new();

    if action == "uninstall" {
        if is_reparse_link(&plugin_root) {
            return Err(fail(
                format!(
                    "refusing to uninstall link-based PluginRoot: {}",
                    plugin_root.display()
                ),
                1,
            ));
        }
        if is_reparse_link(&manifest_file) {
            return Err(fail(
                format!(
                    "refusing to read link-based manifest: {}",
                    manifest_file.display()
                ),
                1,
            ));
        }
        let manifest = read_b3_manifest(&manifest_file);
        if manifest.exists && (manifest.corrupt || manifest.schema != "b3-antigravity-plugin-v1") {
            return Err(fail(
                format!(
                    "refusing to uninstall invalid or corrupt B3 manifest at {}",
                    manifest_file.display()
                ),
                1,
            ));
        }
        let has_plugin_json = test_b3_plugin_json(&plugin_root.join("plugin.json"), false);
        if !manifest.exists && !has_plugin_json {
            if path_exists_or_link(&plugin_root) {
                return Err(fail(
                    format!(
                        "refusing to uninstall unrecognized directory (missing B3 manifest or plugin.json): {}",
                        plugin_root.display()
                    ),
                    1,
                ));
            }
            return Ok((
                format!(
                    "nothing installed (no B3 plugin at {})",
                    plugin_root.display()
                ),
                0,
            ));
        }

        let uninstall_b3_prefixes = get_uninstall_b3_prefixes(&plugin_root, &manifest);
        let mut removed = 0usize;
        let mut skipped = 0usize;
        let mut tracked_files = Vec::new();
        let mut tracked_links = Vec::new();

        if manifest.exists {
            tracked_files = sort_ordinal(manifest.section("file").keys().cloned(), false);
            tracked_links = sort_ordinal(manifest.section("link").keys().cloned(), false);
        } else {
            if plugin_root.join("plugin.json").is_file() {
                tracked_files.push("plugin.json".to_string());
            }
            let r_path = plugin_root.join("rules").join("AGENTS.md");
            if r_path.is_file()
                && fs::read_to_string(&r_path)
                    .unwrap_or_default()
                    .contains("Generated from B3_HOME:")
            {
                tracked_files.push("rules/AGENTS.md".to_string());
            }
            let ag_dir = plugin_root.join("agents");
            if ag_dir.is_dir() && !is_reparse_link(&ag_dir) {
                if let Ok(rd) = fs::read_dir(&ag_dir) {
                    for af in rd.flatten() {
                        if af.file_type().is_ok_and(|ft| ft.is_file()) {
                            let fname = af.file_name().to_string_lossy().into_owned();
                            if fname.ends_with(".md") {
                                let txt = fs::read_to_string(af.path()).unwrap_or_default();
                                if txt.contains("<!-- Generated from ")
                                    && (txt.contains("/agents/")
                                        || txt.contains("/.cursor/agents/"))
                                {
                                    tracked_files.push(format!("agents/{fname}"));
                                }
                            }
                        }
                    }
                }
            }
            let sk_dir = plugin_root.join("skills");
            if sk_dir.is_dir() && !is_reparse_link(&sk_dir) {
                if let Ok(rd) = fs::read_dir(&sk_dir) {
                    for sk in rd.flatten() {
                        if is_reparse_link(&sk.path()) {
                            tracked_links
                                .push(format!("skills/{}", sk.file_name().to_string_lossy()));
                        }
                    }
                }
            }
        }

        let skills_container = plugin_root.join("skills");
        if is_reparse_link(&skills_container) {
            eprintln!(
                "WARNING: skipping symlinked skills directory: {}",
                skills_container.display()
            );
            skipped += 1;
        } else {
            for lk in &tracked_links {
                let exp_target = manifest
                    .section("link")
                    .get(lk)
                    .map(String::as_str)
                    .unwrap_or("");
                uninstall_managed_link(
                    &plugin_root,
                    "PluginRoot",
                    &plugin_root.join(lk.replace('/', std::path::MAIN_SEPARATOR_STR)),
                    exp_target,
                    manifest.exists,
                    force,
                    dry_run,
                    "unmanaged non-link entry",
                    &mut removed,
                    &mut skipped,
                    &mut out,
                )?;
            }
        }

        let mut warned_set = BTreeSet::new();
        let mut warned_opt = Some(&mut warned_set);
        for fk in &tracked_files {
            let exp_sha = manifest
                .section("file")
                .get(fk)
                .map(String::as_str)
                .unwrap_or("");
            uninstall_managed_file(
                &plugin_root,
                "PluginRoot",
                &plugin_root.join(fk.replace('/', std::path::MAIN_SEPARATOR_STR)),
                exp_sha,
                manifest.exists,
                "",
                "file path",
                "modified managed file",
                &mut warned_opt,
                force,
                dry_run,
                &mut removed,
                &mut skipped,
                &mut out,
            )?;
        }

        if !dry_run {
            for sub in ["skills", "rules", "agents"] {
                remove_empty_regular_dir(&plugin_root.join(sub));
            }
        }

        if path_exists_or_link(&skills_json_path) {
            if is_reparse_link(&gemini_dir)
                || is_reparse_link(&gemini_config_dir)
                || is_reparse_link(&skills_json_path)
            {
                eprintln!(
                    "WARNING: skipping symlinked global skills.json path: {}",
                    skills_json_path.display()
                );
                skipped += 1;
            } else if !skills_json_path.is_file() {
                eprintln!(
                    "WARNING: skipping non-file global skills.json path: {}",
                    skills_json_path.display()
                );
                skipped += 1;
            } else {
                let sj_state = read_skills_json_state(&skills_json_path);
                if !sj_state.valid {
                    eprintln!(
                        "WARNING: skipping invalid global skills.json: {} ({})",
                        skills_json_path.display(),
                        sj_state.error
                    );
                    skipped += 1;
                } else if !uninstall_b3_prefixes.is_empty() {
                    let mut kept = Vec::new();
                    let mut removed_entries = 0usize;
                    for item in &sj_state.entries {
                        let item_path = item.get("path").and_then(JsonValue::as_str).unwrap_or("");
                        if !item_path.is_empty()
                            && test_is_b3_managed_skill_path(item_path, &uninstall_b3_prefixes)
                        {
                            removed_entries += 1;
                        } else {
                            kept.push(item.clone());
                        }
                    }
                    if removed_entries > 0 {
                        if kept.is_empty() && sj_state.other_fields.is_empty() {
                            if dry_run {
                                out.push(format!("dry-run: remove {}", skills_json_path.display()));
                            } else {
                                let _ = fs::remove_file(&skills_json_path);
                            }
                        } else {
                            let updated_sj =
                                convert_to_skills_json_content(&sj_state.other_fields, &kept);
                            if dry_run {
                                out.push(format!(
                                    "dry-run: update {} (remove {removed_entries} B3 entries)",
                                    skills_json_path.display()
                                ));
                            } else {
                                write_utf8_no_bom_lf(&skills_json_path, &updated_sj)?;
                            }
                        }
                        removed += 1;
                    }
                }
            }
        }

        if skipped > 0 {
            out.push(format!(
                "UNINSTALL_CONFLICT: removed={removed} skipped={skipped} plugin_root={} (re-run with -Force to remove modified managed entries)",
                plugin_root.display()
            ));
            return Ok((out.join("\n"), 1));
        }

        if manifest.exists && manifest_file.is_file() && !is_reparse_link(&manifest_file) {
            if dry_run {
                out.push(format!(
                    "dry-run: remove manifest {}",
                    manifest_file.display()
                ));
            } else {
                let _ = fs::remove_file(&manifest_file);
            }
            removed += 1;
        }
        if !dry_run {
            for sub in ["skills", "rules", "agents"] {
                remove_empty_regular_dir(&plugin_root.join(sub));
            }
            remove_empty_regular_dir(&plugin_root);
        }
        out.push(format!(
            "UNINSTALL_OK: removed={removed} plugin_root={}",
            plugin_root.display()
        ));
        return Ok((out.join("\n"), 0));
    }

    let b3_home = resolve_b3_home_auto(b3_home_raw)?;
    let b3_home_forward = to_forward_path(&b3_home);

    let workflow_path = b3_home.join("workflows").join("ship.md");
    let skills_src = b3_home.join("skills");
    let cmd_skills_src = b3_home.join("adapters").join("command-skills");
    let rules_dir = b3_home.join("rules");
    let agents_dir = b3_home.join("agents");

    if !workflow_path.is_file() {
        return Err(fail(
            format!("B3_HOME missing workflow: {}", workflow_path.display()),
            1,
        ));
    }
    if !skills_src.is_dir() {
        return Err(fail(
            format!("B3_HOME missing skills: {}", skills_src.display()),
            1,
        ));
    }

    let mut core_skill_map = BTreeMap::new();
    let mut cmd_skill_map = BTreeMap::new();
    let mut skill_map = BTreeMap::new();
    if add_canonical_skills_with_bucket(&skills_src, &mut skill_map, Some(&mut core_skill_map))? < 1
    {
        return Err(fail(
            format!(
                "B3_HOME has no SKILL.md under skills: {}",
                skills_src.display()
            ),
            1,
        ));
    }
    if !cmd_skills_src.is_dir()
        || add_canonical_skills_with_bucket(
            &cmd_skills_src,
            &mut skill_map,
            Some(&mut cmd_skill_map),
        )? < 1
    {
        return Err(fail(
            format!(
                "B3_HOME has no command skills under: {}",
                cmd_skills_src.display()
            ),
            1,
        ));
    }
    let sorted_skill_names = sort_ordinal(skill_map.keys().cloned(), false);
    let desired_skills_json_entries =
        get_desired_skills_json_entries(&core_skill_map, &cmd_skill_map);

    let rule_names = get_canonical_markdown_names_all(&rules_dir);
    if rule_names.is_empty() {
        return Err(fail(
            format!("B3_HOME has no rules under {}", rules_dir.display()),
            1,
        ));
    }
    let rules_header = format!(
        "# B3 AI Engineering Rules\n\n\
Generated from B3_HOME: `{b3_home_forward}` (do not edit here).\n\
Resolve B3_HOME from `B3_HOME` env, product `.b3/home`, or `{b3_home_forward}`.\n\
Precedence: `{b3_home_forward}/docs/precedence.md`. Ship: `{b3_home_forward}/workflows/ship.md`. Review loop: `{b3_home_forward}/review-loop/strategy.md`.\n\
Project-level AGENTS.md, GEMINI.md, .agents/rules/, and .agents/skills/ override this global baseline within their project scope; per-project install-product is optional.\n\
B3 commands (`/b3-plan`, `/b3-implement`, `/b3-debug`, `/b3-research`, `/b3-audit`, `/b3-review`, `/b3-refactor`, `/b3-verify`, `/b3-review-loop`, `/b3-ship`, `/b3-research-ship`, `/b3-pr-resolve`, `/b3-pr-reply`, `/b3-pr-comment`) and workflows remain available across local projects via bundled skills using the fallback B3_HOME above."
    );
    let mut rules_parts = vec![rules_header];
    for rname in &rule_names {
        let stripped = split_yaml_frontmatter(&rules_dir.join(rname), false)?.body;
        if !stripped.is_empty() {
            rules_parts.push(stripped);
        }
    }
    let rules_content = format!("{}\n", rules_parts.join("\n\n---\n\n").trim_end());
    let rules_bytes = rules_content.len();
    if rules_bytes >= 24_000 {
        return Err(fail(
            format!(
                "generated rules/AGENTS.md is {rules_bytes} bytes (must stay under 24000 bytes)"
            ),
            1,
        ));
    }

    let agent_names = get_canonical_markdown_names(&agents_dir);
    if agent_names.is_empty() {
        return Err(fail(
            format!(
                "B3_HOME has no agent definitions under {}",
                agents_dir.display()
            ),
            1,
        ));
    }
    let mut rendered_agents = Vec::with_capacity(agent_names.len());
    for an in &agent_names {
        rendered_agents.push(parse_canonical_agent(
            &agents_dir.join(an),
            &b3_home_forward,
        )?);
    }

    let plugin_json = "{\n  \"name\": \"b3-ai-engineering\",\n  \"displayName\": \"B3 AI Engineering\",\n  \"version\": \"1.0.0\",\n  \"description\": \"Personal AI engineering system: portable rules, engineering and domain skills, independent review-loop roles, and autonomous development lifecycle.\",\n  \"suggestedPrompts\": [\n    \"Run /b3-ship for a new feature or plan in this repository\",\n    \"Run an independent review-loop on the current git diff\",\n    \"Create an implementation plan without editing code yet\"\n  ]\n}\n";

    if action == "verify" {
        let mut errors = Vec::new();
        let mut plugin_ok = true;
        let mut rules_ok = true;
        let mut skills_ok = true;
        let mut commands_ok = true;
        let mut agents_ok = true;
        let mut skills_json_ok = true;

        if !plugin_root.is_dir() || is_reparse_link(&plugin_root) {
            plugin_ok = false;
            rules_ok = false;
            skills_ok = false;
            commands_ok = false;
            agents_ok = false;
            errors.push(format!(
                "plugin directory missing or invalid: {}",
                plugin_root.display()
            ));
        } else {
            let manifest = if is_reparse_link(&manifest_file) {
                plugin_ok = false;
                errors.push(format!(
                    "missing or invalid .b3-plugin-manifest at {}",
                    manifest_file.display()
                ));
                B3Manifest::empty()
            } else {
                let m = read_b3_manifest(&manifest_file);
                if !m.exists || m.corrupt || m.schema != "b3-antigravity-plugin-v1" {
                    plugin_ok = false;
                    errors.push(format!(
                        "missing or invalid .b3-plugin-manifest at {}",
                        manifest_file.display()
                    ));
                }
                m
            };

            let pj_path = plugin_root.join("plugin.json");
            if is_reparse_link(&pj_path) {
                plugin_ok = false;
                errors.push(format!(
                    "plugin.json is a link (expected regular file): {}",
                    pj_path.display()
                ));
            } else if !test_b3_plugin_json(&pj_path, false) {
                plugin_ok = false;
                errors.push(format!(
                    "missing or invalid plugin.json at {}",
                    pj_path.display()
                ));
            } else if file_sha256(&pj_path).unwrap_or_default() != text_sha256_lf(plugin_json) {
                plugin_ok = false;
                errors.push(format!(
                    "stale or modified plugin.json at {}",
                    pj_path.display()
                ));
            }

            let rules_dir_out = plugin_root.join("rules");
            let rules_out = rules_dir_out.join("AGENTS.md");
            if is_reparse_link(&rules_dir_out) {
                rules_ok = false;
                errors.push(format!(
                    "rules directory is a link (expected regular directory): {}",
                    rules_dir_out.display()
                ));
            } else if is_reparse_link(&rules_out) {
                rules_ok = false;
                errors.push(format!(
                    "rules/AGENTS.md is a link (expected regular file): {}",
                    rules_out.display()
                ));
            } else if !rules_out.is_file() {
                rules_ok = false;
                errors.push(format!(
                    "missing rules/AGENTS.md at {}",
                    rules_out.display()
                ));
            } else if let Ok(bytes) = fs::read(&rules_out) {
                let text = String::from_utf8_lossy(&bytes);
                if bytes.len() >= 24_000 || text.trim_start().starts_with("---") {
                    rules_ok = false;
                    errors.push(format!(
                        "invalid rules/AGENTS.md format or size ({} B)",
                        bytes.len()
                    ));
                } else if crate::fs::sha256_bytes_hex(&bytes) != text_sha256_lf(&rules_content) {
                    rules_ok = false;
                    errors.push(format!(
                        "stale or modified rules/AGENTS.md at {}",
                        rules_out.display()
                    ));
                }
            } else {
                rules_ok = false;
                errors.push(format!(
                    "missing rules/AGENTS.md at {}",
                    rules_out.display()
                ));
            }

            let skills_out = plugin_root.join("skills");
            if is_reparse_link(&skills_out) {
                skills_ok = false;
                commands_ok = false;
                errors.push(format!(
                    "skills directory is a link (expected container of 1-level skill links): {}",
                    skills_out.display()
                ));
            } else {
                for sn in sort_ordinal(core_skill_map.keys().cloned(), false) {
                    let dest = skills_out.join(&sn);
                    if !test_link_target(&dest, &core_skill_map[&sn], false)
                        || !dest.join("SKILL.md").is_file()
                    {
                        skills_ok = false;
                        errors.push(format!(
                            "missing or broken skill link: {} -> {}",
                            dest.display(),
                            core_skill_map[&sn].display()
                        ));
                    }
                }
                if skills_out.is_dir() {
                    if let Ok(rd) = fs::read_dir(&skills_out) {
                        for child in rd.flatten() {
                            let cp = child.path();
                            let cname = child.file_name().to_string_lossy().into_owned();
                            if is_reparse_link(&cp)
                                && !skill_map.contains_key(&cname)
                                && manifest
                                    .section("link")
                                    .contains_key(&format!("skills/{cname}"))
                            {
                                skills_ok = false;
                                errors.push(format!(
                                    "stale managed skill link present: {}",
                                    cp.display()
                                ));
                            }
                        }
                    }
                }
                for cn in sort_ordinal(cmd_skill_map.keys().cloned(), false) {
                    let dest = skills_out.join(&cn);
                    if !test_link_target(&dest, &cmd_skill_map[&cn], false)
                        || !dest.join("SKILL.md").is_file()
                    {
                        commands_ok = false;
                        errors.push(format!(
                            "missing or broken command-skill link: {} -> {}",
                            dest.display(),
                            cmd_skill_map[&cn].display()
                        ));
                    }
                }
            }
            for cmd_md in get_canonical_markdown_names(&b3_home.join("commands")) {
                let core_cmd = cmd_md.strip_suffix(".md").unwrap_or(&cmd_md);
                if !cmd_skill_map.contains_key(core_cmd) {
                    commands_ok = false;
                    errors.push(format!(
                        "missing expected command skill in B3_HOME: {core_cmd}"
                    ));
                }
            }

            let agents_out = plugin_root.join("agents");
            let expected_agent_set: BTreeSet<&str> = rendered_agents
                .iter()
                .map(|a| a.file_name.as_str())
                .collect();
            if is_reparse_link(&agents_out) {
                agents_ok = false;
                errors.push(format!(
                    "agents directory is a link (expected regular directory): {}",
                    agents_out.display()
                ));
            } else {
                for ag in &rendered_agents {
                    let dest = agents_out.join(&ag.file_name);
                    if is_reparse_link(&dest) {
                        agents_ok = false;
                        errors.push(format!(
                            "agent file is a link (expected regular file): {}",
                            dest.display()
                        ));
                    } else if !dest.is_file() {
                        agents_ok = false;
                        errors.push(format!("missing agent file: {}", dest.display()));
                    } else if let Ok(bytes) = fs::read(&dest) {
                        let a_sha = crate::fs::sha256_bytes_hex(&bytes);
                        let a_text = String::from_utf8_lossy(&bytes).replace("\r\n", "\n");
                        if a_sha != text_sha256_lf(&ag.content) {
                            agents_ok = false;
                            errors
                                .push(format!("stale or modified agent file: {}", dest.display()));
                        } else if !a_text.lines().any(|l| l.trim_end() == "subagent: true")
                            || !a_text.lines().any(|l| l.trim_end() == "mainAgent: false")
                            || !a_text
                                .lines()
                                .any(|l| l.trim_start().starts_with("tools:") && l.contains('['))
                        {
                            agents_ok = false;
                            errors.push(format!(
                                "invalid subagent frontmatter in: {}",
                                dest.display()
                            ));
                        }
                    } else {
                        agents_ok = false;
                        errors.push(format!("missing agent file: {}", dest.display()));
                    }
                }
                if agents_out.is_dir() {
                    if let Ok(rd) = fs::read_dir(&agents_out) {
                        for existing in rd.flatten() {
                            if !existing.file_type().is_ok_and(|ft| ft.is_file()) {
                                continue;
                            }
                            let ename = existing.file_name().to_string_lossy().into_owned();
                            if !ename.ends_with(".md") {
                                continue;
                            }
                            if !expected_agent_set.contains(ename.as_str())
                                && manifest.exists
                                && manifest
                                    .section("file")
                                    .contains_key(&format!("agents/{ename}"))
                            {
                                agents_ok = false;
                                errors.push(format!(
                                    "stale generated agent file present: {}",
                                    existing.path().display()
                                ));
                            }
                        }
                    }
                }
            }
        }

        if is_reparse_link(&gemini_dir)
            || is_reparse_link(&gemini_config_dir)
            || is_reparse_link(&skills_json_path)
        {
            skills_json_ok = false;
            errors.push(format!(
                "global skills.json path uses symlink or junction: {}",
                skills_json_path.display()
            ));
        } else if !skills_json_path.is_file() {
            skills_json_ok = false;
            errors.push(format!(
                "missing global skills.json at {}",
                skills_json_path.display()
            ));
        } else {
            let sj_state = read_skills_json_state(&skills_json_path);
            if !sj_state.valid {
                skills_json_ok = false;
                errors.push(format!(
                    "invalid global skills.json at {} : {}",
                    skills_json_path.display(),
                    sj_state.error
                ));
            } else if !sj_state.has_entries_key {
                skills_json_ok = false;
                errors.push(format!(
                    "global skills.json missing entries array at {}",
                    skills_json_path.display()
                ));
            } else {
                let norm_paths: Vec<String> = sj_state
                    .entries
                    .iter()
                    .filter_map(|item| {
                        item.get("path")
                            .and_then(JsonValue::as_str)
                            .map(normalize_skill_json_path)
                            .filter(|s| !s.is_empty())
                    })
                    .collect();
                for req in &desired_skills_json_entries {
                    if !norm_paths
                        .iter()
                        .any(|np| paths_equal_fs(np, req, cfg!(windows)))
                    {
                        skills_json_ok = false;
                        errors.push(format!("global skills.json missing B3 entry: {req}"));
                    }
                }
                let prefixes = [b3_home_forward.clone()];
                for item in &sj_state.entries {
                    let raw_item_path = item.get("path").and_then(JsonValue::as_str).unwrap_or("");
                    let np = normalize_skill_json_path(raw_item_path);
                    if !np.is_empty()
                        && test_is_b3_managed_skill_path(&np, &prefixes)
                        && !desired_skills_json_entries
                            .iter()
                            .any(|req| paths_equal_fs(&np, req, cfg!(windows)))
                    {
                        skills_json_ok = false;
                        errors.push(format!(
                            "stale B3 entry in global skills.json: {raw_item_path}"
                        ));
                    }
                }
            }
        }

        out.push(format!(
            "check.plugin={}",
            if plugin_ok { "OK" } else { "FAIL" }
        ));
        out.push(format!(
            "check.rules={}",
            if rules_ok { "OK" } else { "FAIL" }
        ));
        out.push(format!(
            "check.skills={}",
            if skills_ok { "OK" } else { "FAIL" }
        ));
        out.push(format!(
            "check.commands={}",
            if commands_ok { "OK" } else { "FAIL" }
        ));
        out.push(format!(
            "check.agents={}",
            if agents_ok { "OK" } else { "FAIL" }
        ));
        out.push(format!(
            "check.skills_json={}",
            if skills_json_ok { "OK" } else { "FAIL" }
        ));

        check_antigravity_coexistence(&user_home, &plugin_root, &sorted_skill_names, &mut out);

        if !errors.is_empty() {
            for e in &errors {
                out.push(format!("VERIFY_ERROR: {e}"));
            }
            out.push(format!(
                "VERIFY_FAIL: errors={} plugin_root={}",
                errors.len(),
                plugin_root.display()
            ));
            out.push("note: filesystem verification only -- Antigravity runtime discovery is UNKNOWN / INCOMPLETE until verified in a live session".to_string());
            return Ok((out.join("\n"), 1));
        }

        out.push(format!(
            "VERIFY_OK: skills={} commands={} agents={} rules_bytes={rules_bytes} plugin_root={} b3_home={b3_home_forward}",
            core_skill_map.len(),
            cmd_skill_map.len(),
            rendered_agents.len(),
            plugin_root.display()
        ));
        out.push("note: filesystem verification only -- Antigravity runtime discovery is UNKNOWN / INCOMPLETE until verified in a live session".to_string());
        return Ok((out.join("\n"), 0));
    }

    if is_reparse_link(&manifest_file) {
        return Err(fail(
            format!(
                "existing link blocks managed file: {}",
                manifest_file.display()
            ),
            1,
        ));
    }
    let old_manifest = read_b3_manifest(&manifest_file);
    if old_manifest.exists
        && (old_manifest.corrupt || old_manifest.schema != "b3-antigravity-plugin-v1")
    {
        return Err(fail(
            format!(
                "refusing to update invalid B3 manifest at {}",
                manifest_file.display()
            ),
            1,
        ));
    }

    assert_regular_dir_or_missing(&gemini_dir, ".gemini")?;
    assert_regular_dir_or_missing(&gemini_config_dir, ".gemini/config")?;
    assert_regular_file_or_missing(&skills_json_path, "global skills.json")?;
    let existing_skills_json = read_skills_json_state(&skills_json_path);
    if existing_skills_json.exists && !existing_skills_json.valid && !force {
        return Err(fail(
            format!(
                "UPDATE_CONFLICT: invalid global skills.json at {} ({}) (preserved; use -Force only after backing it up)",
                skills_json_path.display(),
                existing_skills_json.error
            ),
            1,
        ));
    }

    if path_exists_or_link(&plugin_root) {
        if is_reparse_link(&plugin_root) {
            return Err(fail(
                format!(
                    "refusing to replace link at PluginRoot: {}",
                    plugin_root.display()
                ),
                1,
            ));
        }
        if !plugin_root.is_dir() {
            return Err(fail(
                format!(
                    "refusing to replace existing file: {}",
                    plugin_root.display()
                ),
                1,
            ));
        }
        let is_b3_plugin =
            old_manifest.exists || test_b3_plugin_json(&plugin_root.join("plugin.json"), false);
        if !is_b3_plugin && !force {
            return Err(fail(
                format!(
                    "refusing to overwrite existing non-B3 directory without -Force: {}",
                    plugin_root.display()
                ),
                1,
            ));
        }
        for sub_name in ["rules", "skills", "agents"] {
            assert_regular_dir_or_missing(&plugin_root.join(sub_name), sub_name)?;
        }

        let mut managed_paths = vec![
            (plugin_root.join("plugin.json"), "plugin.json".to_string()),
            (
                plugin_root.join("rules").join("AGENTS.md"),
                "rules/AGENTS.md".to_string(),
            ),
            (manifest_file.clone(), ".b3-plugin-manifest".to_string()),
        ];
        for ag in &rendered_agents {
            managed_paths.push((
                plugin_root.join("agents").join(&ag.file_name),
                format!("agents/{}", ag.file_name),
            ));
        }
        for (mp, rel) in &managed_paths {
            if !path_exists_or_link(mp) {
                continue;
            }
            assert_regular_file_or_missing(mp, "managed file")?;
            if mp == &manifest_file {
                continue;
            }
            let expected_sha = old_manifest
                .section("file")
                .get(rel)
                .map(String::as_str)
                .unwrap_or("");
            if !force
                && (expected_sha.is_empty() || file_sha256(mp).unwrap_or_default() != expected_sha)
            {
                return Err(fail(
                    format!(
                        "UPDATE_CONFLICT: unmanaged or modified file: {} (preserved; use -Force only after backing it up)",
                        mp.display()
                    ),
                    1,
                ));
            }
        }

        let existing_skills_dir = plugin_root.join("skills");
        if existing_skills_dir.is_dir() {
            if let Ok(rd) = fs::read_dir(&existing_skills_dir) {
                for child in rd.flatten() {
                    let cp = child.path();
                    let cname = child.file_name().to_string_lossy().into_owned();
                    let key = format!("skills/{cname}");
                    let desired = skill_map.contains_key(&cname);
                    let tracked_target = old_manifest.section("link").get(&key);
                    if is_reparse_link(&cp) {
                        if let Some(t) = tracked_target {
                            if !force && !test_link_target(&cp, Path::new(t), true) {
                                return Err(fail(
                                    format!(
                                        "UPDATE_CONFLICT: modified B3 skill link: {}",
                                        cp.display()
                                    ),
                                    1,
                                ));
                            }
                        } else if desired {
                            return Err(fail(
                                format!(
                                    "UPDATE_CONFLICT: untracked skill link: {} (move it manually; -Force cannot delete it)",
                                    cp.display()
                                ),
                                1,
                            ));
                        }
                        continue;
                    }
                    if desired && (!force || !cp.join("SKILL.md").is_file()) {
                        return Err(fail(
                            format!(
                                "UPDATE_CONFLICT: existing skill directory: {} (explicit -Force requires a valid SKILL.md)",
                                cp.display()
                            ),
                            1,
                        ));
                    }
                }
            }
        }

        let expected_agent_files: BTreeSet<&str> = rendered_agents
            .iter()
            .map(|a| a.file_name.as_str())
            .collect();
        let agent_dir_prune = plugin_root.join("agents");
        if agent_dir_prune.is_dir() {
            if let Ok(rd) = fs::read_dir(&agent_dir_prune) {
                for af in rd.flatten() {
                    if !af.file_type().is_ok_and(|ft| ft.is_file()) {
                        continue;
                    }
                    let fname = af.file_name().to_string_lossy().into_owned();
                    if !fname.ends_with(".md") || expected_agent_files.contains(fname.as_str()) {
                        continue;
                    }
                    let rel = format!("agents/{fname}");
                    if let Some(exp_sha) = old_manifest.section("file").get(&rel) {
                        if !force && file_sha256(&af.path()).unwrap_or_default() != *exp_sha {
                            return Err(fail(
                                format!(
                                    "UPDATE_CONFLICT: modified stale B3 agent: {}",
                                    af.path().display()
                                ),
                                1,
                            ));
                        }
                    }
                }
            }
        }
    }

    if dry_run {
        out.push(format!(
            "dry-run: action={action} plugin_root={}",
            plugin_root.display()
        ));
        out.push(format!("dry-run: B3_HOME={}", b3_home.display()));
        out.push(format!(
            "dry-run: write {}{}plugin.json",
            plugin_root.display(),
            std::path::MAIN_SEPARATOR
        ));
        out.push(format!(
            "dry-run: write {0}{1}rules{1}AGENTS.md ({rules_bytes} bytes)",
            plugin_root.display(),
            std::path::MAIN_SEPARATOR
        ));
        out.push(format!(
            "dry-run: link {} skills ({} skills + {} command-skills) into {}{}skills",
            skill_map.len(),
            core_skill_map.len(),
            cmd_skill_map.len(),
            plugin_root.display(),
            std::path::MAIN_SEPARATOR
        ));
        out.push(format!(
            "dry-run: write {} agents into {}{}agents",
            rendered_agents.len(),
            plugin_root.display(),
            std::path::MAIN_SEPARATOR
        ));
        out.push(format!(
            "dry-run: update {} ({} skill category entries)",
            skills_json_path.display(),
            desired_skills_json_entries.len()
        ));
        check_antigravity_coexistence(&user_home, &plugin_root, &sorted_skill_names, &mut out);
        out.push(format!(
            "DRY_RUN_OK: action={action} plugin_root={}",
            plugin_root.display()
        ));
        return Ok((out.join("\n"), 0));
    }

    let rules_out_dir = plugin_root.join("rules");
    let skills_out_dir = plugin_root.join("skills");
    let agents_out_dir = plugin_root.join("agents");
    for d in [
        &plugin_root,
        &rules_out_dir,
        &skills_out_dir,
        &agents_out_dir,
    ] {
        if !d.is_dir() {
            fs::create_dir_all(d)
                .map_err(|e| fail(format!("cannot create {}: {e}", d.display()), 1))?;
        }
    }

    let mut manifest_lines = Vec::new();
    write_utf8_no_bom_lf(&plugin_root.join("plugin.json"), plugin_json)?;
    manifest_lines.push(format!("file|plugin.json|{}", text_sha256_lf(plugin_json)));
    write_utf8_no_bom_lf(&rules_out_dir.join("AGENTS.md"), &rules_content)?;
    manifest_lines.push(format!(
        "file|rules/AGENTS.md|{}",
        text_sha256_lf(&rules_content)
    ));

    if let Ok(rd) = fs::read_dir(&skills_out_dir) {
        for child in rd.flatten() {
            let cp = child.path();
            let cname = child.file_name().to_string_lossy().into_owned();
            let key = format!("skills/{cname}");
            if is_reparse_link(&cp) {
                if old_manifest.section("link").contains_key(&key)
                    && !skill_map.contains_key(&cname)
                {
                    remove_link_only(&cp)?;
                }
            } else if force && skill_map.contains_key(&cname) {
                remove_dir_tree_safely(&cp)?;
            }
        }
    }
    for sn in &sorted_skill_names {
        let src = &skill_map[sn];
        let dest = skills_out_dir.join(sn);
        if !test_link_target(&dest, src, false) {
            if is_reparse_link(&dest) {
                if !old_manifest
                    .section("link")
                    .contains_key(&format!("skills/{sn}"))
                {
                    return Err(fail(
                        format!(
                            "UPDATE_CONFLICT: refusing to replace untracked skill link: {}",
                            dest.display()
                        ),
                        1,
                    ));
                }
                remove_link_only(&dest)?;
            }
            create_dir_link(&dest, src)?;
        }
        manifest_lines.push(format!("link|skills/{sn}|{}", to_forward_path(src)));
    }

    let expected_agent_files: BTreeSet<&str> = rendered_agents
        .iter()
        .map(|a| a.file_name.as_str())
        .collect();
    if let Ok(rd) = fs::read_dir(&agents_out_dir) {
        for existing in rd.flatten() {
            if !existing.file_type().is_ok_and(|ft| ft.is_file()) {
                continue;
            }
            let ename = existing.file_name().to_string_lossy().into_owned();
            if ename.ends_with(".md")
                && !expected_agent_files.contains(ename.as_str())
                && old_manifest
                    .section("file")
                    .contains_key(&format!("agents/{ename}"))
            {
                let _ = fs::remove_file(existing.path());
            }
        }
    }
    for ag in &rendered_agents {
        write_utf8_no_bom_lf(&agents_out_dir.join(&ag.file_name), &ag.content)?;
        manifest_lines.push(format!(
            "file|agents/{}|{}",
            ag.file_name,
            text_sha256_lf(&ag.content)
        ));
    }

    write_b3_manifest(
        &manifest_file,
        "b3-antigravity-plugin-v1",
        &b3_home_forward,
        &plugin_root_forward,
        &manifest_lines,
    )?;

    let mut replace_prefixes = vec![b3_home_forward.clone()];
    if old_manifest.exists && !old_manifest.b3_home.is_empty() {
        replace_prefixes.push(normalize_skill_json_path(&old_manifest.b3_home));
    }
    let mut merged_entries = Vec::new();
    let other_fields = if existing_skills_json.exists && existing_skills_json.valid {
        for item in &existing_skills_json.entries {
            let item_path = item
                .get("path")
                .and_then(JsonValue::as_str)
                .map(normalize_skill_json_path)
                .unwrap_or_default();
            if !item_path.is_empty()
                && (test_is_b3_managed_skill_path(&item_path, &replace_prefixes)
                    || desired_skills_json_entries
                        .iter()
                        .any(|req| paths_equal_fs(&item_path, req, cfg!(windows))))
            {
                continue;
            }
            merged_entries.push(item.clone());
        }
        existing_skills_json.other_fields
    } else {
        Vec::new()
    };
    for req in &desired_skills_json_entries {
        merged_entries.push(JsonValue::obj(vec![(
            "path".to_string(),
            JsonValue::str(req),
        )]));
    }
    let skills_json_content = convert_to_skills_json_content(&other_fields, &merged_entries);
    write_utf8_no_bom_lf(&skills_json_path, &skills_json_content)?;

    check_antigravity_coexistence(&user_home, &plugin_root, &sorted_skill_names, &mut out);
    let plugin_dir_name = plugin_root
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("b3-ai-engineering");
    out.push(format!(
        "{}_OK: skills={} commands={} agents={} rules_bytes={rules_bytes} plugin_root={} b3_home={b3_home_forward}",
        action.to_ascii_uppercase(),
        core_skill_map.len(),
        cmd_skill_map.len(),
        rendered_agents.len(),
        plugin_root.display()
    ));
    out.push(format!(
        "installed Antigravity plugin at {}",
        plugin_root.display()
    ));
    out.push(format!("B3_HOME={}", b3_home.display()));
    out.push(format!("skills={}", skill_map.len()));
    out.push(format!(
        "skills_json={} ({} entries)",
        skills_json_path.display(),
        desired_skills_json_entries.len()
    ));
    out.push(format!("agents={}", rendered_agents.len()));
    out.push(format!("rules_bytes={rules_bytes}"));
    out.push(format!("manage=customization://{plugin_dir_name}"));
    out.push(
        "note: this proves plugin files were generated, not Antigravity runtime discovery"
            .to_string(),
    );
    Ok((out.join("\n"), 0))
}

fn get_canonical_markdown_names_all(dir_path: &Path) -> Vec<String> {
    if !dir_path.is_dir() {
        return Vec::new();
    }
    let mut full_paths = Vec::new();
    if let Ok(rd) = fs::read_dir(dir_path) {
        for entry in rd.flatten() {
            if !entry.file_type().is_ok_and(|ft| ft.is_file()) {
                continue;
            }
            if entry.file_name().to_string_lossy().ends_with(".md") {
                full_paths.push(entry.path().to_string_lossy().into_owned());
            }
        }
    }
    let sorted = sort_ordinal(full_paths, false);
    sorted
        .into_iter()
        .filter_map(|p| {
            Path::new(&p)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
        })
        .collect()
}
