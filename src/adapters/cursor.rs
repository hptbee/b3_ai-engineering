use std::collections::BTreeMap;
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
use crate::fs::{remove_dir_tree_safely, sort_ordinal};

fn check_cross_host_coexistence(user_home: &Path, skill_names: &[String], out: &mut Vec<String>) {
    for (sub_rel, sub_disp) in [
        (".agents/skills", "~/.agents/skills"),
        (".claude/skills", "~/.claude/skills"),
    ] {
        let dir = user_home.join(sub_rel.replace('/', std::path::MAIN_SEPARATOR_STR));
        let overlaps = get_skill_overlaps(&dir, skill_names);
        if !overlaps.is_empty() {
            out.push(format!(
                "COEXISTENCE_WARNING: {sub_disp} contains {} overlapping B3 skill(s); Cursor cross-loads {sub_disp} and may show duplicates.",
                overlaps.len()
            ));
        }
    }
}

fn assert_managed_doc_preflight(path: &Path, label: &str, force: bool) -> Result<(), B3Error> {
    assert_regular_file_or_missing(path, label)?;
    if path.is_file() && !force {
        let txt = fs::read_to_string(path).unwrap_or_default();
        if !txt.contains("b3-global-cursor-managed:") {
            return Err(fail(
                format!(
                    "refusing to overwrite unmanaged {label} {} (re-run with -Force to replace)",
                    path.display()
                ),
                1,
            ));
        }
    }
    Ok(())
}

/// Executes `b3 install cursor`.
pub fn run(
    action_raw: &str,
    cursor_home_raw: &str,
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

    let cursor_home_norm = if cursor_home_raw.trim().is_empty() {
        normalize_abs_path_str(&user_home.join(".cursor"))
    } else {
        normalize_path_str(cursor_home_raw.trim())?
    };
    let cursor_home = PathBuf::from(&cursor_home_norm);
    let skills_dest = cursor_home.join("skills");
    let commands_dest = cursor_home.join("commands");
    let agents_dest = cursor_home.join("agents");
    let b3_home_file = cursor_home.join("b3-home");
    let user_rules_file = cursor_home.join("b3-user-rules.txt");
    let manifest_file = cursor_home.join(".b3-global-manifest");

    let mut out = Vec::new();

    if action == "uninstall" {
        if is_reparse_link(&cursor_home) {
            return Err(fail(
                format!(
                    "refusing to uninstall link-based CursorHome: {}",
                    cursor_home.display()
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
        if !manifest.exists {
            return Ok((
                format!(
                    "nothing installed (no manifest at {})",
                    manifest_file.display()
                ),
                0,
            ));
        }
        if manifest.corrupt || manifest.schema != "b3-cursor-global-v1" {
            return Err(fail(
                format!(
                    "refusing to uninstall invalid or corrupt B3 manifest at {}",
                    manifest_file.display()
                ),
                1,
            ));
        }
        let mut removed = 0usize;
        let mut skipped = 0usize;

        if is_reparse_link(&skills_dest) {
            eprintln!(
                "WARNING: skipping symlinked skills directory: {}",
                skills_dest.display()
            );
            skipped += 1;
        } else {
            let sk_keys = sort_ordinal(manifest.section("skill").keys().cloned(), false);
            for sk in sk_keys {
                let target = manifest.section("skill")[&sk].as_str();
                uninstall_managed_link(
                    &cursor_home,
                    "CursorHome",
                    &skills_dest.join(&sk),
                    target,
                    true,
                    force,
                    dry_run,
                    "unmanaged non-link skill directory",
                    &mut removed,
                    &mut skipped,
                    &mut out,
                )?;
            }
        }
        if is_reparse_link(&commands_dest) {
            eprintln!(
                "WARNING: skipping symlinked commands directory: {}",
                commands_dest.display()
            );
            skipped += 1;
        } else {
            let cmd_keys = sort_ordinal(manifest.section("command").keys().cloned(), false);
            for cmd in cmd_keys {
                let sha = manifest.section("command")[&cmd].as_str();
                uninstall_managed_file(
                    &cursor_home,
                    "CursorHome",
                    &commands_dest.join(&cmd),
                    sha,
                    true,
                    "b3-global-cursor-managed:",
                    "command file",
                    "modified or unverified command file",
                    &mut None,
                    force,
                    dry_run,
                    &mut removed,
                    &mut skipped,
                    &mut out,
                )?;
            }
        }
        if is_reparse_link(&agents_dest) {
            eprintln!(
                "WARNING: skipping symlinked agents directory: {}",
                agents_dest.display()
            );
            skipped += 1;
        } else {
            let ag_keys = sort_ordinal(manifest.section("agent").keys().cloned(), false);
            for ag in ag_keys {
                let sha = manifest.section("agent")[&ag].as_str();
                uninstall_managed_file(
                    &cursor_home,
                    "CursorHome",
                    &agents_dest.join(&ag),
                    sha,
                    true,
                    "b3-global-cursor-managed:",
                    "agent file",
                    "modified or unverified agent file",
                    &mut None,
                    force,
                    dry_run,
                    &mut removed,
                    &mut skipped,
                    &mut out,
                )?;
            }
        }
        if let Some(sha) = manifest.section("file").get("b3-user-rules.txt") {
            uninstall_managed_file(
                &cursor_home,
                "CursorHome",
                &user_rules_file,
                sha,
                true,
                "b3-global-cursor-managed:",
                "file",
                "modified or unverified file",
                &mut None,
                force,
                dry_run,
                &mut removed,
                &mut skipped,
                &mut out,
            )?;
        }
        if let Some(sha) = manifest.section("file").get("b3-home") {
            uninstall_managed_file(
                &cursor_home,
                "CursorHome",
                &b3_home_file,
                sha,
                true,
                "",
                "b3-home",
                "modified or unverified b3-home",
                &mut None,
                force,
                dry_run,
                &mut removed,
                &mut skipped,
                &mut out,
            )?;
        }
        if !dry_run {
            for sub in [&skills_dest, &commands_dest, &agents_dest] {
                remove_empty_regular_dir(sub);
            }
        }
        if skipped > 0 {
            out.push(format!(
                "UNINSTALL_CONFLICT: removed={removed} skipped={skipped} cursor_home={} (re-run with -Force to remove modified managed entries)",
                cursor_home.display()
            ));
            return Ok((out.join("\n"), 1));
        }
        if dry_run {
            out.push(format!(
                "dry-run: remove manifest {}",
                manifest_file.display()
            ));
        } else {
            let _ = fs::remove_file(&manifest_file);
            for sub in [&skills_dest, &commands_dest, &agents_dest] {
                remove_empty_regular_dir(sub);
            }
        }
        out.push(format!(
            "UNINSTALL_OK: removed={removed} cursor_home={}",
            cursor_home.display()
        ));
        return Ok((out.join("\n"), 0));
    }

    let b3_home = resolve_b3_home_auto(b3_home_raw)?;
    let b3_home_forward = to_forward_path(&b3_home);

    let workflow_path = b3_home.join("workflows").join("ship.md");
    let skills_src = b3_home.join("skills");
    let commands_src = b3_home.join("commands");
    let agents_src = b3_home.join("agents");
    let rules_src = b3_home.join("rules");

    if !workflow_path.is_file() {
        return Err(fail(
            format!("B3_HOME missing workflow: {}", workflow_path.display()),
            1,
        ));
    }
    if !skills_src.is_dir() {
        return Err(fail(
            format!("B3_HOME missing skills dir: {}", skills_src.display()),
            1,
        ));
    }
    if !commands_src.is_dir() {
        return Err(fail(
            format!("B3_HOME missing commands dir: {}", commands_src.display()),
            1,
        ));
    }
    if !agents_src.is_dir() {
        return Err(fail(
            format!("B3_HOME missing agents dir: {}", agents_src.display()),
            1,
        ));
    }
    let has_rules = fs::read_dir(&rules_src).ok().is_some_and(|rd| {
        rd.flatten().any(|e| {
            e.file_type().is_ok_and(|ft| ft.is_file())
                && e.file_name().to_string_lossy().ends_with(".md")
        })
    });
    if !has_rules {
        return Err(fail(
            format!("B3_HOME missing rules/*.md under: {}", rules_src.display()),
            1,
        ));
    }

    let expected_commands = get_canonical_markdown_names(&commands_src);
    if expected_commands.is_empty() {
        return Err(fail(
            format!(
                "B3_HOME has no canonical commands under: {}",
                commands_src.display()
            ),
            1,
        ));
    }
    let expected_agents = get_canonical_markdown_names(&agents_src);
    if expected_agents.is_empty() {
        return Err(fail(
            format!(
                "B3_HOME has no canonical agents under: {}",
                agents_src.display()
            ),
            1,
        ));
    }

    let mut skill_targets: BTreeMap<String, PathBuf> = BTreeMap::new();
    if add_canonical_skills_with_bucket(&skills_src, &mut skill_targets, None)? < 1 {
        return Err(fail(
            format!("B3_HOME has no SKILL.md under: {}", skills_src.display()),
            1,
        ));
    }
    let sorted_skill_names = sort_ordinal(skill_targets.keys().cloned(), false);

    let mut rendered_commands: BTreeMap<String, String> = BTreeMap::new();
    for c in &expected_commands {
        let parsed = split_yaml_frontmatter(&commands_src.join(c), true)?;
        let content = format!(
            "{}\n<!-- b3-global-cursor-managed: source={b3_home_forward}/commands/{c} -->\n\n**Global B3_HOME fallback:** if `B3_HOME` env and project `.b3/home` are absent, read `~/.cursor/b3-home` (`{b3_home_forward}`). Project `AGENTS.md` and `.cursor/rules/*.mdc` override global defaults on project requirements.\n\n{}\n",
            parsed.frontmatter,
            parsed.body
        );
        rendered_commands.insert(c.clone(), content.trim_end().to_string() + "\n");
    }

    let mut rendered_agents: BTreeMap<String, String> = BTreeMap::new();
    for a in &expected_agents {
        let parsed = split_yaml_frontmatter(&agents_src.join(a), true)?;
        let content = format!(
            "{}\n<!-- b3-global-cursor-managed: source={b3_home_forward}/agents/{a} -->\n\n**Global B3_HOME:** resolve `B3_HOME` env, project `.b3/home`, or `~/.cursor/b3-home` (`{b3_home_forward}`).\n\n{}\n",
            parsed.frontmatter,
            parsed.body
        );
        rendered_agents.insert(a.clone(), content.trim_end().to_string() + "\n");
    }

    let rendered_user_rules = format!(
        "# B3 Global User Rules (paste into Cursor Settings > Rules > User Rules)\n\
# b3-global-cursor-managed: source={b3_home_forward}/rules/\n\
B3 Engineering Baseline (personal/global; project AGENTS.md and .cursor/rules/*.mdc override these on project requirements):\n\
1. Resolve B3_HOME: B3_HOME env var -> project .b3/home -> ~/.cursor/b3-home ({b3_home_forward}). Never copy skills/ into product repos.\n\
2. Verification honesty: never claim PASS without executed evidence; missing evidence, skipped suite, or tool failure = UNKNOWN / INCOMPLETE.\n\
3. Scope & design: understand before editing; prefer simplest correct change meeting stated requirements; load only the smallest matching skill from ~/.cursor/skills/.\n\
4. Provenance: cite official docs vs practice vs preference; never copy external repos verbatim without provenance.\n\
5. Delegation: independent review and fixer roles stay separate; report host limit honestly if subagent isolation is unavailable.\n"
    );
    let rendered_b3_home = format!("{b3_home_forward}\n");

    let manifest = if is_reparse_link(&manifest_file) {
        B3Manifest::empty()
    } else {
        read_b3_manifest(&manifest_file)
    };

    if action == "verify" {
        let mut errors = Vec::new();
        for (p, label) in [
            (&cursor_home, "cursor_home"),
            (&skills_dest, "skills directory"),
            (&commands_dest, "commands directory"),
            (&agents_dest, "agents directory"),
        ] {
            if is_reparse_link(p) {
                errors.push(format!(
                    "{label} is a link (expected regular directory): {}",
                    p.display()
                ));
            }
        }
        if is_reparse_link(&manifest_file) {
            errors.push(format!(
                "manifest is a link (expected regular file): {}",
                manifest_file.display()
            ));
        } else if !manifest.exists {
            errors.push(format!("missing manifest: {}", manifest_file.display()));
        } else if manifest.corrupt || manifest.schema != "b3-cursor-global-v1" {
            errors.push(format!(
                "invalid or corrupt manifest at {}",
                manifest_file.display()
            ));
        }

        let legacy_skill_dir = skills_dest.join("b3-ai-engineering");
        if path_exists_or_link(&legacy_skill_dir) {
            errors.push(format!(
                "legacy b3-ai-engineering entry still exists at {} (run with -Force to migrate)",
                legacy_skill_dir.display()
            ));
        }

        for (p, expected, label) in [
            (&b3_home_file, &rendered_b3_home, "b3-home"),
            (&user_rules_file, &rendered_user_rules, "b3-user-rules.txt"),
        ] {
            if is_reparse_link(p) {
                errors.push(format!(
                    "{label} is a link (expected regular file): {}",
                    p.display()
                ));
            } else if !p.is_file() {
                errors.push(format!("missing {label}: {}", p.display()));
            } else if file_sha256(p).unwrap_or_default() != text_sha256_lf(expected) {
                errors.push(format!("stale or modified {label} at {}", p.display()));
            }
        }

        for sn in &sorted_skill_names {
            let dest = skills_dest.join(sn);
            let target = &skill_targets[sn];
            if !test_link_target(&dest, target, false) || !dest.join("SKILL.md").is_file() {
                errors.push(format!(
                    "invalid or missing skill link: {} -> {}",
                    dest.display(),
                    target.display()
                ));
            }
        }
        for old_sk in manifest.section("skill").keys() {
            if !skill_targets.contains_key(old_sk) {
                let old_path = skills_dest.join(old_sk);
                if path_exists_or_link(&old_path) {
                    errors.push(format!(
                        "stale managed skill entry present: {}",
                        old_path.display()
                    ));
                }
            }
        }

        for c in &expected_commands {
            let dest = commands_dest.join(c);
            if is_reparse_link(&dest) {
                errors.push(format!(
                    "command is a link (expected regular file): {}",
                    dest.display()
                ));
            } else if !dest.is_file() {
                errors.push(format!("missing command: {}", dest.display()));
            } else if file_sha256(&dest).unwrap_or_default()
                != text_sha256_lf(&rendered_commands[c])
            {
                errors.push(format!("stale or modified command: {}", dest.display()));
            }
        }
        for a in &expected_agents {
            let dest = agents_dest.join(a);
            if is_reparse_link(&dest) {
                errors.push(format!(
                    "agent is a link (expected regular file): {}",
                    dest.display()
                ));
            } else if !dest.is_file() {
                errors.push(format!("missing agent: {}", dest.display()));
            } else if file_sha256(&dest).unwrap_or_default() != text_sha256_lf(&rendered_agents[a])
            {
                errors.push(format!("stale or modified agent: {}", dest.display()));
            }
        }

        check_cross_host_coexistence(&user_home, &sorted_skill_names, &mut out);

        if !errors.is_empty() {
            for e in &errors {
                out.push(format!("VERIFY_ERROR: {e}"));
            }
            out.push(format!("VERIFY_FAIL: errors={}", errors.len()));
            return Ok((out.join("\n"), 1));
        }

        out.push(format!(
            "VERIFY_OK: skills={} commands={} agents={} cursor_home={} b3_home={b3_home_forward}",
            sorted_skill_names.len(),
            expected_commands.len(),
            expected_agents.len(),
            cursor_home.display()
        ));
        out.push(
            "note: filesystem links and hashes verified (PASS); live Cursor IDE/CLI activation and User Rules UI application remain UNKNOWN / INCOMPLETE until verified in Cursor."
                .to_string(),
        );
        return Ok((out.join("\n"), 0));
    }

    assert_regular_dir_or_missing(&cursor_home, "cursor_home")?;
    assert_regular_dir_or_missing(&skills_dest, "skills")?;
    assert_regular_dir_or_missing(&commands_dest, "commands")?;
    assert_regular_dir_or_missing(&agents_dest, "agents")?;
    assert_regular_file_or_missing(&manifest_file, "manifest")?;
    if manifest.exists && (manifest.corrupt || manifest.schema != "b3-cursor-global-v1") {
        return Err(fail(
            format!(
                "refusing to {action}: invalid or corrupt B3 manifest at {}",
                manifest_file.display()
            ),
            1,
        ));
    }

    let legacy_skill_dir = skills_dest.join("b3-ai-engineering");
    let mut remove_legacy_link = false;
    if path_exists_or_link(&legacy_skill_dir) {
        if force
            && is_reparse_link(&legacy_skill_dir)
            && test_link_target(&legacy_skill_dir, &skills_src, false)
        {
            remove_legacy_link = true;
        } else {
            return Err(fail(
                format!(
                    "legacy {} exists; re-run with -Force if it is a link to {} (or move unmanaged directory aside)",
                    legacy_skill_dir.display(),
                    skills_src.display()
                ),
                1,
            ));
        }
    }

    let mut skill_already_ok = std::collections::BTreeSet::new();
    for sn in &sorted_skill_names {
        let dest = skills_dest.join(sn);
        let src = &skill_targets[sn];
        if path_exists_or_link(&dest) {
            if test_link_target(&dest, src, false) {
                skill_already_ok.insert(sn.clone());
                continue;
            }
            let is_managed = manifest.section("skill").contains_key(sn) && action == "update";
            if is_reparse_link(&dest) {
                if is_managed || force {
                    continue;
                }
                return Err(fail(
                    format!(
                        "conflicting link at {} (does not point to {}). Re-run with -Force or update.",
                        dest.display(),
                        src.display()
                    ),
                    1,
                ));
            }
            if force {
                if !dest.join("SKILL.md").is_file() {
                    return Err(fail(
                        format!(
                            "refusing to overwrite non-skill directory even with -Force: {}",
                            dest.display()
                        ),
                        1,
                    ));
                }
                continue;
            }
            return Err(fail(
                format!(
                    "conflicting unmanaged directory at {}; move aside or re-run with -Force",
                    dest.display()
                ),
                1,
            ));
        }
    }

    for c in &expected_commands {
        assert_managed_doc_preflight(&commands_dest.join(c), "command", force)?;
    }
    for a in &expected_agents {
        assert_managed_doc_preflight(&agents_dest.join(a), "agent", force)?;
    }
    assert_managed_doc_preflight(&user_rules_file, "user rules", force)?;

    assert_regular_file_or_missing(&b3_home_file, "b3-home")?;
    if b3_home_file.is_file() {
        let cur_home = fs::read_to_string(&b3_home_file)
            .unwrap_or_default()
            .trim()
            .replace('\\', "/");
        let home_managed = manifest.section("file").contains_key("b3-home") && action == "update";
        if cur_home != b3_home_forward && !home_managed && !force {
            return Err(fail(
                format!(
                    "refusing to overwrite unmanaged {} (points to {cur_home}; re-run with -Force)",
                    b3_home_file.display()
                ),
                1,
            ));
        }
    }

    if dry_run {
        if remove_legacy_link {
            out.push(format!(
                "dry-run: remove legacy link {}",
                legacy_skill_dir.display()
            ));
        }
        out.push(format!(
            "dry-run: ensure {}, write {} ({b3_home_forward}), {}",
            cursor_home.display(),
            b3_home_file.display(),
            user_rules_file.display()
        ));
        out.push(format!(
            "dry-run: link {} flattened skills under {}",
            sorted_skill_names.len(),
            skills_dest.display()
        ));
        out.push(format!(
            "dry-run: write {} commands under {} and {} agents under {}",
            expected_commands.len(),
            commands_dest.display(),
            expected_agents.len(),
            agents_dest.display()
        ));
        let old_sks = sort_ordinal(manifest.section("skill").keys().cloned(), false);
        for old_sk in old_sks {
            if !skill_targets.contains_key(&old_sk) {
                out.push(format!(
                    "dry-run: prune removed skill {}",
                    skills_dest.join(&old_sk).display()
                ));
            }
        }
        check_cross_host_coexistence(&user_home, &sorted_skill_names, &mut out);
        out.push(format!(
            "DRY_RUN_OK: action={action} cursor_home={}",
            cursor_home.display()
        ));
        return Ok((out.join("\n"), 0));
    }

    for d in [&cursor_home, &skills_dest, &commands_dest, &agents_dest] {
        if !d.is_dir() {
            fs::create_dir_all(d)
                .map_err(|e| fail(format!("cannot create {}: {e}", d.display()), 1))?;
        }
    }
    if remove_legacy_link {
        remove_link_only(&legacy_skill_dir)?;
        out.push(format!(
            "migrated: removed legacy link {}",
            legacy_skill_dir.display()
        ));
    }

    let mut manifest_lines = Vec::new();
    for sn in &sorted_skill_names {
        let dest = skills_dest.join(sn);
        let src = &skill_targets[sn];
        let src_fwd = to_forward_path(src);
        if !skill_already_ok.contains(sn) {
            if is_reparse_link(&dest) {
                remove_link_only(&dest)?;
            } else if dest.is_dir() {
                remove_dir_tree_safely(&dest)?;
            }
            create_dir_link(&dest, src)?;
        }
        manifest_lines.push(format!("skill|{sn}|{src_fwd}"));
    }

    let old_sks = sort_ordinal(manifest.section("skill").keys().cloned(), false);
    for old_sk in old_sks {
        if !skill_targets.contains_key(&old_sk) {
            let old_path = skills_dest.join(&old_sk);
            if is_reparse_link(&old_path) {
                remove_link_only(&old_path)?;
            } else if path_exists_or_link(&old_path) {
                eprintln!(
                    "WARNING: skipping prune of non-link directory {}",
                    old_path.display()
                );
            }
        }
    }

    for c in &expected_commands {
        let dest = commands_dest.join(c);
        let body = &rendered_commands[c];
        write_utf8_no_bom_lf(&dest, body)?;
        manifest_lines.push(format!("command|{c}|{}", text_sha256_lf(body)));
    }
    for a in &expected_agents {
        let dest = agents_dest.join(a);
        let body = &rendered_agents[a];
        write_utf8_no_bom_lf(&dest, body)?;
        manifest_lines.push(format!("agent|{a}|{}", text_sha256_lf(body)));
    }

    for old_name in manifest.section("command").keys() {
        if !expected_commands.contains(old_name) {
            let old_path = commands_dest.join(old_name);
            if old_path.is_file()
                && fs::read_to_string(&old_path)
                    .unwrap_or_default()
                    .contains("b3-global-cursor-managed:")
            {
                let _ = fs::remove_file(&old_path);
            }
        }
    }
    for old_name in manifest.section("agent").keys() {
        if !expected_agents.contains(old_name) {
            let old_path = agents_dest.join(old_name);
            if old_path.is_file()
                && fs::read_to_string(&old_path)
                    .unwrap_or_default()
                    .contains("b3-global-cursor-managed:")
            {
                let _ = fs::remove_file(&old_path);
            }
        }
    }

    write_utf8_no_bom_lf(&b3_home_file, &rendered_b3_home)?;
    manifest_lines.push(format!(
        "file|b3-home|{}",
        text_sha256_lf(&rendered_b3_home)
    ));
    write_utf8_no_bom_lf(&user_rules_file, &rendered_user_rules)?;
    manifest_lines.push(format!(
        "file|b3-user-rules.txt|{}",
        text_sha256_lf(&rendered_user_rules)
    ));

    write_b3_manifest(
        &manifest_file,
        "b3-cursor-global-v1",
        &b3_home_forward,
        "",
        &manifest_lines,
    )?;

    check_cross_host_coexistence(&user_home, &sorted_skill_names, &mut out);
    out.push(format!(
        "{}_OK: skills={} commands={} agents={} cursor_home={} b3_home={b3_home_forward}",
        action.to_ascii_uppercase(),
        sorted_skill_names.len(),
        expected_commands.len(),
        expected_agents.len(),
        cursor_home.display()
    ));
    out.push(format!(
        "note: Cursor global User Rules must be pasted once manually from {} into Cursor Settings > Rules > User Rules (runtime discovery UNKNOWN / INCOMPLETE until verified in Cursor).",
        user_rules_file.display()
    ));
    Ok((out.join("\n"), 0))
}
