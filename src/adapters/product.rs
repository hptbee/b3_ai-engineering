use std::fs;
use std::path::{Path, PathBuf};

use crate::adapters::common::{
    assert_regular_dir_or_missing, assert_regular_file_or_missing, collect_skill_md_files,
    create_dir_link, get_skill_name_from_file, initialize_personal_models_file, is_reparse_link,
    normalize_abs_path_str, normalize_path_str, path_exists_or_link, remove_link_only,
    resolve_b3_home_dir, test_link_target, text_sha256_lf, write_utf8_no_bom_lf,
};
use crate::error::{fail, B3Error};
use crate::fs::sort_ordinal;

const MANAGED_CMD_PREFIX: &str = "<!-- b3-managed-command: sha256=";
const MANAGED_CMD_SUFFIX: &str = " -->";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ManagedCmdState {
    Missing,
    Current,
    ManagedStale,
    LegacyUnmodified,
    UserModified,
}

impl ManagedCmdState {
    fn as_str(self) -> &'static str {
        match self {
            ManagedCmdState::Missing => "missing",
            ManagedCmdState::Current => "current",
            ManagedCmdState::ManagedStale => "managed-stale",
            ManagedCmdState::LegacyUnmodified => "legacy-unmodified",
            ManagedCmdState::UserModified => "user-modified",
        }
    }
}

struct CommandEntry {
    src: PathBuf,
    dest: PathBuf,
    rendered: String,
    state: ManagedCmdState,
}

fn compute_command_payload(src_path: &Path) -> Result<(String, String), B3Error> {
    let raw = fs::read_to_string(src_path).map_err(|e| {
        fail(
            format!("ADAPTER_FAIL: cannot read {}: {e}", src_path.display()),
            1,
        )
    })?;
    let clean = raw.strip_prefix('\u{FEFF}').unwrap_or(&raw);
    let body_lf = format!(
        "{}\n",
        clean
            .replace("\r\n", "\n")
            .replace('\r', "\n")
            .trim_end_matches('\n')
    );
    let body_sha = text_sha256_lf(&body_lf);
    let rendered = format!("{body_lf}{MANAGED_CMD_PREFIX}{body_sha}{MANAGED_CMD_SUFFIX}\n");
    Ok((body_lf, rendered))
}

fn inspect_command_state(dest_path: &Path, body_lf: &str, rendered: &str) -> ManagedCmdState {
    if !dest_path.is_file() {
        return ManagedCmdState::Missing;
    }
    let Ok(dest_raw) = fs::read_to_string(dest_path) else {
        return ManagedCmdState::UserModified;
    };
    let clean = dest_raw.strip_prefix('\u{FEFF}').unwrap_or(&dest_raw);
    let dest_lf = clean.replace("\r\n", "\n").replace('\r', "\n");
    if dest_lf == rendered {
        return ManagedCmdState::Current;
    }
    let no_trail_nl = dest_lf.strip_suffix('\n').unwrap_or(&dest_lf);
    if let Some(before_suffix) = no_trail_nl.strip_suffix(MANAGED_CMD_SUFFIX) {
        if let Some(marker_pos) = before_suffix.rfind(MANAGED_CMD_PREFIX) {
            let sha_part = &before_suffix[marker_pos + MANAGED_CMD_PREFIX.len()..];
            let prefix = &before_suffix[..marker_pos];
            if sha_part.len() == 64
                && sha_part
                    .bytes()
                    .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
                && prefix.ends_with('\n')
            {
                if text_sha256_lf(prefix) == sha_part {
                    return ManagedCmdState::ManagedStale;
                }
                return ManagedCmdState::UserModified;
            }
        }
    }
    let dest_norm = format!("{}\n", dest_lf.trim_end_matches('\n'));
    if dest_norm == body_lf {
        return ManagedCmdState::LegacyUnmodified;
    }
    ManagedCmdState::UserModified
}

fn install_skill_junction(dest: &Path, target: &Path, force: bool) -> Result<(), B3Error> {
    if path_exists_or_link(dest) {
        if is_reparse_link(dest) {
            if test_link_target(dest, target, false) {
                return Ok(());
            }
            if !force {
                return Err(fail(
                    format!(
                        "refusing to replace existing link {} (pass -Force to update)",
                        dest.display()
                    ),
                    1,
                ));
            }
            remove_link_only(dest)?;
        } else {
            return Err(fail(
                format!("refusing to replace existing non-link {}", dest.display()),
                1,
            ));
        }
    }
    create_dir_link(dest, target)
}

fn install_flat_skill_index(
    dest_root: &Path,
    skills_src: &Path,
    cmd_skills_src: &Path,
    force: bool,
) -> Result<(), B3Error> {
    if path_exists_or_link(dest_root) {
        if is_reparse_link(dest_root) {
            remove_link_only(dest_root)?;
        } else if !dest_root.is_dir() {
            return Err(fail(
                format!("refusing to replace existing {}", dest_root.display()),
                1,
            ));
        }
    }
    fs::create_dir_all(dest_root)
        .map_err(|e| fail(format!("cannot create {}: {e}", dest_root.display()), 1))?;

    let mut skill_files = Vec::new();
    collect_skill_md_files(skills_src, &mut skill_files)?;
    let path_strs = sort_ordinal(
        skill_files.iter().map(|p| p.to_string_lossy().into_owned()),
        false,
    );
    for sf_str in path_strs {
        let sf = PathBuf::from(&sf_str);
        let name = get_skill_name_from_file(&sf);
        if let Some(src_dir) = sf.parent() {
            install_skill_junction(&dest_root.join(&name), src_dir, force)?;
        }
    }

    if cmd_skills_src.is_dir() {
        let mut dir_names = Vec::new();
        if let Ok(rd) = fs::read_dir(cmd_skills_src) {
            for e in rd.flatten() {
                if e.file_type().is_ok_and(|ft| ft.is_dir()) {
                    dir_names.push(e.file_name().to_string_lossy().into_owned());
                }
            }
        }
        let dir_names = sort_ordinal(dir_names, false);
        for dname in dir_names {
            let src_dir = cmd_skills_src.join(&dname);
            if src_dir.join("SKILL.md").is_file() {
                install_skill_junction(&dest_root.join(&dname), &src_dir, force)?;
            }
        }
    }
    Ok(())
}

fn has_exact_trimmed_line(text: &str, target: &str) -> bool {
    text.replace("\r\n", "\n")
        .replace('\r', "\n")
        .split('\n')
        .any(|line| line.trim() == target)
}

fn replace_exact_trimmed_line(text: &str, target: &str, replacement: &str) -> String {
    let lf = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut out = Vec::new();
    for line in lf.split('\n') {
        if line.trim() == target {
            out.push(replacement.to_string());
        } else {
            out.push(line.to_string());
        }
    }
    out.join("\n")
}

fn update_b3_gitignore(root: &Path) -> Result<&'static str, B3Error> {
    let gi = root.join(".gitignore");
    let block = "\n# B3: commit .b3/home; keep run checkpoints and local model preferences private\n.b3/ship/\n.b3/research-ship/\n.b3/pr-feedback/\n.b3/models.md\n";
    if !gi.is_file() {
        let content = format!("{}\n", block.trim_start());
        fs::write(&gi, content.as_bytes())
            .map_err(|e| fail(format!("cannot write {}: {e}", gi.display()), 1))?;
        return Ok("created");
    }
    let text = fs::read_to_string(&gi)
        .map_err(|e| fail(format!("cannot read {}: {e}", gi.display()), 1))?;
    let has_ship = has_exact_trimmed_line(&text, ".b3/ship/");
    let has_research = has_exact_trimmed_line(&text, ".b3/research-ship/");
    let has_pr_fb = has_exact_trimmed_line(&text, ".b3/pr-feedback/");
    let has_models = has_exact_trimmed_line(&text, ".b3/models.md");
    if has_ship && has_research && has_pr_fb && has_models {
        return Ok("present");
    }

    let mut missing = Vec::new();
    if !has_ship {
        missing.push(".b3/ship/");
    }
    if !has_research {
        missing.push(".b3/research-ship/");
    }
    if !has_pr_fb {
        missing.push(".b3/pr-feedback/");
    }
    if !has_models {
        missing.push(".b3/models.md");
    }

    if has_exact_trimmed_line(&text, ".b3/") {
        let replacement = missing.join("\n");
        let updated = replace_exact_trimmed_line(&text, ".b3/", &replacement);
        fs::write(&gi, updated.as_bytes())
            .map_err(|e| fail(format!("cannot update {}: {e}", gi.display()), 1))?;
        return Ok("upgraded");
    }
    if has_ship || has_research || has_pr_fb || has_models {
        let mut combined = text;
        if !combined.ends_with('\n') && !combined.is_empty() {
            combined.push('\n');
        }
        combined.push_str(&missing.join("\n"));
        combined.push('\n');
        fs::write(&gi, combined.as_bytes())
            .map_err(|e| fail(format!("cannot append {}: {e}", gi.display()), 1))?;
        return Ok("upgraded");
    }
    let mut combined = text;
    combined.push_str(block);
    fs::write(&gi, combined.as_bytes())
        .map_err(|e| fail(format!("cannot append {}: {e}", gi.display()), 1))?;
    Ok("appended")
}

fn update_host_skill_gitignore(root: &Path, target_host: &str) -> Result<&'static str, B3Error> {
    let mut lines = Vec::new();
    if matches!(target_host, "codex" | "antigravity" | "all") {
        lines.push(".agents/skills");
    }
    if matches!(target_host, "claude" | "all") {
        lines.push(".claude/skills");
        lines.push(".claude/agents");
    }
    if lines.is_empty() {
        return Ok("n/a");
    }
    let gi = root.join(".gitignore");
    if !gi.is_file() {
        let content = format!(
            "# B3: local host links (do not commit)\n{}\n",
            lines.join("\n")
        );
        fs::write(&gi, content.as_bytes())
            .map_err(|e| fail(format!("cannot write {}: {e}", gi.display()), 1))?;
        return Ok("created");
    }
    let text = fs::read_to_string(&gi)
        .map_err(|e| fail(format!("cannot read {}: {e}", gi.display()), 1))?;
    let mut missing = Vec::new();
    for ln in lines {
        if !has_exact_trimmed_line(&text, ln) {
            missing.push(ln);
        }
    }
    if missing.is_empty() {
        return Ok("present");
    }
    let mut combined = text;
    if !combined.ends_with('\n') && !combined.is_empty() {
        combined.push('\n');
    }
    combined.push_str("\n# B3: local host links (do not commit)\n");
    combined.push_str(&missing.join("\n"));
    combined.push('\n');
    fs::write(&gi, combined.as_bytes())
        .map_err(|e| fail(format!("cannot append {}: {e}", gi.display()), 1))?;
    Ok("appended")
}

/// Executes `b3 install product`.
pub fn run(
    product_root_raw: &str,
    b3_home_raw: &str,
    host_name_raw: &str,
    dry_run: bool,
    force: bool,
) -> Result<(String, i32), B3Error> {
    let host_name = if host_name_raw.trim().is_empty() {
        "cursor"
    } else {
        host_name_raw.trim()
    };
    if !matches!(
        host_name,
        "cursor" | "codex" | "claude" | "antigravity" | "all"
    ) {
        return Err(fail(
            format!("invalid --host '{host_name}' (expected cursor|codex|claude|antigravity|all)"),
            1,
        ));
    }
    if product_root_raw.trim().is_empty() {
        return Err(fail("--product-root is required", 1));
    }
    let prod_norm = normalize_path_str(product_root_raw)?;
    let prod_cand = PathBuf::from(&prod_norm);
    if !prod_cand.exists() {
        return Err(fail(
            format!("ProductRoot not found: {product_root_raw}"),
            1,
        ));
    }
    let product_root = PathBuf::from(normalize_abs_path_str(&prod_cand));

    let fallback_root = if let Ok(env_home) = std::env::var("B3_HOME") {
        if !env_home.trim().is_empty() {
            PathBuf::from(env_home.trim())
        } else {
            std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
        }
    } else {
        std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
    };
    let b3_home = resolve_b3_home_dir(b3_home_raw, &fallback_root)?;
    let b3_home_str = b3_home.to_string_lossy().into_owned();

    let workflow = b3_home.join("workflows").join("ship.md");
    let b3_commands = b3_home.join("commands");
    let template = b3_commands.join("b3-ship.md");
    let skills = b3_home.join("skills");
    let b3_agents = b3_home.join("agents");
    let cmd_skills_src = b3_home.join("adapters").join("command-skills");
    let adapters_dir = b3_home.join("adapters");

    if !workflow.exists() {
        return Err(fail(
            format!("B3_HOME missing workflow: {}", workflow.display()),
            1,
        ));
    }
    if !template.exists() {
        return Err(fail(format!("missing template: {}", template.display()), 1));
    }
    let mut b3_skill_files = Vec::new();
    let _ = collect_skill_md_files(&skills, &mut b3_skill_files);
    if b3_skill_files.is_empty() {
        return Err(fail(
            format!("B3_HOME has no SKILL.md under skills: {}", skills.display()),
            1,
        ));
    }

    let use_cursor = matches!(host_name, "cursor" | "all");
    let use_flat_agents_skills = matches!(host_name, "codex" | "antigravity" | "all");
    let use_claude = matches!(host_name, "claude" | "all");

    let product_skills = product_root.join(".cursor").join("skills");
    let cursor_dir = product_root.join(".cursor");
    let cursor_commands_dir = cursor_dir.join("commands");
    let command_dest = cursor_commands_dir.join("b3-ship.md");
    let home_dest = product_root.join(".b3").join("home");
    let agents_dest = product_root.join(".agents").join("skills");
    let claude_skills_dest = product_root.join(".claude").join("skills");
    let claude_agents_dest = product_root.join(".claude").join("agents");
    let claude_md_dest = product_root.join("CLAUDE.md");
    let cursor_readme_template = adapters_dir.join("product-cursor-readme.md");
    let agents_md_template = adapters_dir.join("product-agents.md");
    let claude_md_template = adapters_dir.join("product-claude.md");
    let cursor_readme_dest = cursor_dir.join("README.md");
    let agents_md_dest = product_root.join("AGENTS.md");

    if product_skills.is_dir() {
        let mut prod_skill_files = Vec::new();
        let _ = collect_skill_md_files(&product_skills, &mut prod_skill_files);
        if !prod_skill_files.is_empty() {
            return Err(fail(
                format!(
                    "product already has {} SKILL.md under .cursor/skills; refusing to install a duplicate skill tree",
                    prod_skill_files.len()
                ),
                1,
            ));
        }
    }

    if host_name == "cursor" && !force {
        if path_exists_or_link(&agents_dest) {
            return Err(fail(
                "product has .agents/skills; Cursor would duplicate discovery. Remove it, use -Force, or install with -HostName codex only in a Codex-only checkout",
                1,
            ));
        }
        if path_exists_or_link(&claude_skills_dest) {
            return Err(fail(
                "product has .claude/skills; Cursor would duplicate discovery. Remove it or pass -Force before a Cursor install",
                1,
            ));
        }
    }

    assert_regular_dir_or_missing(&product_root.join(".b3"), ".b3")?;
    assert_regular_file_or_missing(&home_dest, ".b3/home")?;
    let mut rewrite_home = !home_dest.is_file() || force;
    if home_dest.is_file() {
        let existing_home = fs::read_to_string(&home_dest)
            .ok()
            .map(|s| s.trim().to_string())
            .unwrap_or_default();
        if existing_home.is_empty() {
            if !force {
                return Err(fail(
                    format!(
                        "refusing to overwrite empty or invalid {}. Pass -Force to update",
                        home_dest.display()
                    ),
                    1,
                ));
            }
            rewrite_home = true;
        } else {
            let looks_abs = existing_home.starts_with('/')
                || existing_home.starts_with("\\\\")
                || (existing_home.len() >= 3
                    && existing_home.as_bytes()[0].is_ascii_alphabetic()
                    && existing_home.as_bytes()[1] == b':'
                    && matches!(existing_home.as_bytes()[2], b'\\' | b'/'));
            let same_home = if looks_abs {
                let norm_ex = normalize_path_str(&existing_home).unwrap_or_default();
                let norm_req = normalize_abs_path_str(&b3_home);
                !norm_ex.is_empty()
                    && if cfg!(windows) {
                        norm_ex.eq_ignore_ascii_case(&norm_req)
                    } else {
                        norm_ex == norm_req
                    }
            } else {
                false
            };
            if !same_home && !force {
                return Err(fail(
                    format!(
                        "refusing to overwrite {} (points to {existing_home}, requested {b3_home_str}). Pass -Force to update",
                        home_dest.display()
                    ),
                    1,
                ));
            }
            if !same_home {
                rewrite_home = true;
            }
        }
    }

    let mut command_entries = Vec::new();
    if use_cursor {
        assert_regular_dir_or_missing(&cursor_dir, ".cursor")?;
        assert_regular_dir_or_missing(&cursor_commands_dir, ".cursor/commands")?;
        assert_regular_file_or_missing(&cursor_readme_dest, ".cursor/README.md")?;

        let mut cmd_paths = Vec::new();
        if let Ok(rd) = fs::read_dir(&b3_commands) {
            for e in rd.flatten() {
                if !e.file_type().is_ok_and(|ft| ft.is_file()) {
                    continue;
                }
                let name = e.file_name().to_string_lossy().into_owned();
                if name != "README.md" && name.ends_with(".md") {
                    cmd_paths.push(e.path().to_string_lossy().into_owned());
                }
            }
        }
        let cmd_paths = sort_ordinal(cmd_paths, false);

        for src_str in cmd_paths {
            let src_p = PathBuf::from(&src_str);
            let name = src_p
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string();
            let dest_p = cursor_commands_dir.join(&name);
            assert_regular_file_or_missing(&dest_p, &name)?;
            let (body_lf, rendered) = compute_command_payload(&src_p)?;
            let state = inspect_command_state(&dest_p, &body_lf, &rendered);
            if state == ManagedCmdState::UserModified && !force {
                return Err(fail(
                    format!(
                        "refusing to overwrite modified command pointer {}. Re-run with -Force to overwrite",
                        dest_p.display()
                    ),
                    1,
                ));
            }
            command_entries.push(CommandEntry {
                src: src_p,
                dest: dest_p,
                rendered,
                state,
            });
        }
    }

    let mut out = Vec::new();
    if dry_run {
        out.push(format!(
            "dry-run: write {} = {b3_home_str}",
            home_dest.display()
        ));
        if use_cursor {
            for entry in &command_entries {
                match entry.state {
                    ManagedCmdState::Current => out.push(format!(
                        "dry-run: keep existing {} (up to date)",
                        entry.dest.display()
                    )),
                    ManagedCmdState::Missing => out.push(format!(
                        "dry-run: write {} from {}",
                        entry.dest.display(),
                        entry.src.display()
                    )),
                    other => out.push(format!(
                        "dry-run: refresh {} from {} ({})",
                        entry.dest.display(),
                        entry.src.display(),
                        other.as_str()
                    )),
                }
            }
            if cursor_readme_template.is_file() {
                out.push(format!("dry-run: write {}", cursor_readme_dest.display()));
            }
        }
        if agents_md_dest.exists() {
            out.push(format!(
                "dry-run: keep existing {}",
                agents_md_dest.display()
            ));
        } else if agents_md_template.is_file() {
            out.push(format!(
                "dry-run: write {} from {}",
                agents_md_dest.display(),
                agents_md_template.display()
            ));
        }
        if use_claude {
            if claude_md_dest.exists() {
                out.push(format!(
                    "dry-run: keep existing {}",
                    claude_md_dest.display()
                ));
            } else if claude_md_template.is_file() {
                out.push(format!(
                    "dry-run: write {} from {}",
                    claude_md_dest.display(),
                    claude_md_template.display()
                ));
            }
        }
        out.push(
            "dry-run: gitignore .b3/ship/, .b3/research-ship/, .b3/pr-feedback/, and .b3/models.md (see Update-B3Gitignore)"
                .to_string(),
        );
        if use_flat_agents_skills {
            out.push("dry-run: gitignore .agents/skills".to_string());
            out.push(format!(
                "dry-run: flatten {} (one junction per skill + command-skills linked)",
                agents_dest.display()
            ));
        }
        if use_claude {
            out.push("dry-run: gitignore .claude/skills and .claude/agents".to_string());
            out.push(format!(
                "dry-run: flatten {} (one junction per skill + command-skills linked)",
                claude_skills_dest.display()
            ));
            out.push(format!(
                "dry-run: junction {} -> {}",
                claude_agents_dest.display(),
                b3_agents.display()
            ));
        }
        if let Ok(ms) = initialize_personal_models_file(&b3_home, None, true, true) {
            if let Some(rest) = ms.strip_prefix("kept:") {
                out.push(format!(
                    "dry-run: keep existing personal model preferences {rest}"
                ));
            } else if let Some(rest) = ms.strip_prefix("dry-run:") {
                let tmpl = b3_home.join("config").join("models.example.md");
                out.push(format!(
                    "dry-run: initialize personal model preferences at {rest} from {}",
                    tmpl.display()
                ));
            }
        }
        return Ok((out.join("\n"), 0));
    }

    let ignore_plan = update_b3_gitignore(&product_root)?;
    let skill_ignore_plan = update_host_skill_gitignore(&product_root, host_name)?;

    fs::create_dir_all(product_root.join(".b3")).map_err(|e| {
        fail(
            format!("cannot create {}: {e}", product_root.join(".b3").display()),
            1,
        )
    })?;
    if rewrite_home {
        fs::write(&home_dest, b3_home_str.as_bytes())
            .map_err(|e| fail(format!("cannot write {}: {e}", home_dest.display()), 1))?;
    }
    if !agents_md_dest.exists() && agents_md_template.is_file() {
        fs::copy(&agents_md_template, &agents_md_dest)
            .map_err(|e| fail(format!("cannot copy {}: {e}", agents_md_dest.display()), 1))?;
    }
    if use_claude && !claude_md_dest.exists() && claude_md_template.is_file() {
        fs::copy(&claude_md_template, &claude_md_dest)
            .map_err(|e| fail(format!("cannot copy {}: {e}", claude_md_dest.display()), 1))?;
    }

    if use_cursor {
        fs::create_dir_all(&cursor_commands_dir).map_err(|e| {
            fail(
                format!("cannot create {}: {e}", cursor_commands_dir.display()),
                1,
            )
        })?;
        for entry in &command_entries {
            if entry.state != ManagedCmdState::Current {
                write_utf8_no_bom_lf(&entry.dest, &entry.rendered)?;
            }
        }
        if cursor_readme_template.is_file() {
            fs::copy(&cursor_readme_template, &cursor_readme_dest).map_err(|e| {
                fail(
                    format!("cannot copy {}: {e}", cursor_readme_dest.display()),
                    1,
                )
            })?;
        }
    }

    if use_flat_agents_skills {
        install_flat_skill_index(&agents_dest, &skills, &cmd_skills_src, force)?;
    }
    if use_claude {
        install_flat_skill_index(&claude_skills_dest, &skills, &cmd_skills_src, force)?;
        if b3_agents.is_dir() {
            if let Some(parent) = claude_agents_dest.parent() {
                fs::create_dir_all(parent)
                    .map_err(|e| fail(format!("cannot create {}: {e}", parent.display()), 1))?;
            }
            install_skill_junction(&claude_agents_dest, &b3_agents, force)?;
        }
    }

    let model_pref_status =
        initialize_personal_models_file(&b3_home, None, false, true).unwrap_or_default();

    out.push(format!(
        "installed B3 pointer in {}",
        product_root.display()
    ));
    out.push(format!("B3_HOME={b3_home_str}"));
    if use_cursor {
        out.push(format!("command={}", command_dest.display()));
    } else if matches!(host_name, "codex" | "antigravity") {
        out.push(format!(
            "command=command-skills ({})",
            agents_dest.display()
        ));
    } else {
        out.push(format!(
            "command=command-skills ({})",
            claude_skills_dest.display()
        ));
    }
    out.push(format!("agents.md={}", agents_md_dest.display()));
    if use_claude {
        out.push(format!("claude.md={}", claude_md_dest.display()));
    }
    out.push(format!("gitignore.b3={ignore_plan}"));
    out.push(format!("gitignore.skills={skill_ignore_plan}"));
    out.push(format!("model_preferences={model_pref_status}"));
    out.push(format!("host={host_name}"));
    match host_name {
        "codex" => out.push(format!(
            "skills={} (flattened junctions + command-skills linked incl. $b3-ship; gitignored, not copied)",
            agents_dest.display()
        )),
        "antigravity" => out.push(format!(
            "skills={} (flattened junctions + command-skills linked; gitignored, not copied; use adapters/install-global.ps1 -HostName antigravity if Cursor also opens this repo)",
            agents_dest.display()
        )),
        "claude" => out.push(format!(
            "skills={} (flattened junctions + command-skills linked) + {} -> {} (gitignored, not copied)",
            claude_skills_dest.display(),
            claude_agents_dest.display(),
            b3_agents.display()
        )),
        "all" => out.push(format!(
            "skills={} + {} (flattened junctions + command-skills linked incl. $b3-ship) + .cursor/commands",
            agents_dest.display(),
            claude_skills_dest.display()
        )),
        _ => out.push(
            "skills=user-level ~/.cursor/skills/<name> via adapters/install-global.ps1 -HostName cursor (not copied into product)"
                .to_string(),
        ),
    }
    out.push(
        "note: this proves files were written, not host slash-command or skill discovery"
            .to_string(),
    );

    Ok((out.join("\n"), 0))
}
