use std::fs;
use std::path::{Path, PathBuf};

use crate::adapters::common::resolve_b3_repo_root_auto;
use crate::error::B3Error;

fn read_lf_bytes(path: &Path) -> usize {
    match fs::read(path) {
        Ok(bytes) => bytes.iter().filter(|&&b| b != b'\r').count(),
        Err(_) => 0,
    }
}

fn read_lf_raw(path: &Path) -> Option<Vec<u8>> {
    let mut bytes = fs::read(path).ok()?;
    if bytes.contains(&b'\r') {
        bytes.retain(|&b| b != b'\r');
    }
    Some(bytes)
}

fn file_bytes(root: &Path, rel: &str) -> usize {
    read_lf_bytes(&root.join(rel))
}

fn est_tokens(bytes: usize) -> usize {
    (bytes + 2) / 4
}

fn extract_frontmatter_len(lf: &[u8]) -> Option<usize> {
    // Matches `(?s)\A---\n(.*?)\n---(?:\n|\z)`
    if !lf.starts_with(b"---\n") {
        return None;
    }
    // Search for the earliest `\n---` starting from byte 3 for `---\n\n---`
    // or byte 4 for non-empty frontmatter.
    let mut i = 3;
    while i + 4 <= lf.len() {
        if &lf[i..i + 4] == b"\n---" && (i + 4 == lf.len() || lf[i + 4] == b'\n') {
            if i == 3 {
                // `---\n---` has no content line between delimiters; Wait: regex `\A---\n(.*?)\n---`
                // cannot match `---\n---` because `\n` at byte 3 is already consumed by `---\n`.
                i += 1;
                continue;
            }
            return Some(i - 4);
        }
        i += 1;
    }
    None
}

fn collect_skill_files(base: &Path, root: &Path, out: &mut Vec<(String, PathBuf)>) {
    let entries = match fs::read_dir(base) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let meta = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        if meta.is_dir() {
            collect_skill_files(&path, root, out);
        } else if meta.is_file() && entry.file_name() == "SKILL.md" {
            if let Ok(rel) = path.strip_prefix(root) {
                let rel_slash = rel.to_string_lossy().replace('\\', "/");
                out.push((rel_slash, path));
            }
        }
    }
}

/// Computes the exact B3 Context Budget Report and warnings for native
/// `b3 context measure --strict`.
pub fn measure_context(repo_root_raw: &str, strict: bool) -> Result<(String, i32), B3Error> {
    let repo_root = resolve_b3_repo_root_auto(repo_root_raw)?;
    let mut warnings: Vec<String> = Vec::new();

    let agents_bytes = file_bytes(&repo_root, "AGENTS.md");
    if agents_bytes > 3600 {
        warnings.push(format!("AGENTS.md ({agents_bytes} B > 3600 B)"));
    }

    let mut rules_bytes = 0usize;
    if let Ok(entries) = fs::read_dir(repo_root.join("rules")) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() && path.extension().and_then(|e| e.to_str()) == Some("md") {
                rules_bytes += read_lf_bytes(&path);
            }
        }
    }

    let mut skill_files: Vec<(String, PathBuf)> = Vec::new();
    for dir in ["skills", "adapters/command-skills"] {
        let p = repo_root.join(dir);
        if p.exists() {
            collect_skill_files(&p, &repo_root, &mut skill_files);
        }
    }
    skill_files.sort_by(|a, b| a.0.cmp(&b.0));

    let mut fm_total_bytes = 0usize;
    let mut max_fm_bytes = 0usize;
    let mut max_fm_file = String::new();
    let mut max_skill_bytes = 0usize;
    let mut max_skill_file = String::new();

    for (rel, full_path) in &skill_files {
        let lf = read_lf_raw(full_path).unwrap_or_default();
        let sb = lf.len();
        if sb > max_skill_bytes {
            max_skill_bytes = sb;
            max_skill_file = rel.clone();
        }
        if sb > 4000 {
            warnings.push(format!("{rel} ({sb} B > 4000 B)"));
        }
        if let Some(fm_len) = extract_frontmatter_len(&lf) {
            fm_total_bytes += fm_len;
            if fm_len > max_fm_bytes {
                max_fm_bytes = fm_len;
                max_fm_file = rel.clone();
            }
            if fm_len > 280 {
                warnings.push(format!("{rel} frontmatter ({fm_len} B > 280 B)"));
            }
        }
    }

    let always_on_bytes = agents_bytes + rules_bytes + fm_total_bytes;

    let wf_ship_bytes = file_bytes(&repo_root, "workflows/ship.md");
    if wf_ship_bytes > 9500 {
        warnings.push(format!("workflows/ship.md ({wf_ship_bytes} B > 9500 B)"));
    }
    let ship_core_bytes = wf_ship_bytes + file_bytes(&repo_root, "commands/b3-ship.md");

    let ship_refs_bytes = file_bytes(&repo_root, "workflows/references/ship-templates.md")
        + file_bytes(&repo_root, "workflows/references/ship-resume.md");
    if ship_refs_bytes > 6000 {
        warnings.push(format!(
            "workflows/references/ship-{{templates,resume}}.md ({ship_refs_bytes} B > 6000 B)"
        ));
    }

    let wf_rs_bytes = file_bytes(&repo_root, "workflows/research-ship.md");
    if wf_rs_bytes > 9500 {
        warnings.push(format!(
            "workflows/research-ship.md ({wf_rs_bytes} B > 9500 B)"
        ));
    }
    let rs_core_bytes = wf_rs_bytes + file_bytes(&repo_root, "commands/b3-research-ship.md");

    let rs_refs_bytes = file_bytes(
        &repo_root,
        "workflows/references/research-ship-templates.md",
    ) + file_bytes(&repo_root, "workflows/references/research-ship-resume.md")
        + file_bytes(&repo_root, "workflows/references/research-ship-gates.md");
    if rs_refs_bytes > 12000 {
        warnings.push(format!(
            "workflows/references/research-ship-{{templates,resume,gates}}.md ({rs_refs_bytes} B > 12000 B)"
        ));
    }

    let ctx_route_bytes = file_bytes(&repo_root, "workflows/references/context-routing.md");
    if ctx_route_bytes > 3000 {
        warnings.push(format!(
            "workflows/references/context-routing.md ({ctx_route_bytes} B > 3000 B)"
        ));
    }

    let disp_naming_bytes = file_bytes(&repo_root, "workflows/references/dispatch-naming.md");
    if disp_naming_bytes > 9200 {
        warnings.push(format!(
            "workflows/references/dispatch-naming.md ({disp_naming_bytes} B > 9200 B)"
        ));
    }

    let rl_strategy_bytes = file_bytes(&repo_root, "review-loop/strategy.md");
    if rl_strategy_bytes > 5200 {
        warnings.push(format!(
            "review-loop/strategy.md ({rl_strategy_bytes} B > 5200 B)"
        ));
    }

    let mut agent_roles_bytes = 0usize;
    let mut agent_role_count = 0usize;
    let mut rev_agent_bytes = 0usize;
    let mut fixer_agent_bytes = 0usize;
    if let Ok(entries) = fs::read_dir(repo_root.join("agents")) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() && path.extension().and_then(|e| e.to_str()) == Some("md") {
                let fname = path.file_name().and_then(|n| n.to_str());
                if fname != Some("README.md") {
                    let b = read_lf_bytes(&path);
                    agent_role_count += 1;
                    agent_roles_bytes += b;
                    if fname == Some("b3-reviewer.md") {
                        rev_agent_bytes = b;
                    } else if fname == Some("b3-fixer.md") {
                        fixer_agent_bytes = b;
                    }
                }
            }
        }
    }
    if agent_roles_bytes > 8500 {
        warnings.push(format!(
            "agents/*.md roles ({agent_roles_bytes} B > 8500 B)"
        ));
    }

    let cr_skill_bytes = file_bytes(&repo_root, "skills/engineering/code-review/SKILL.md");
    let rev_tpl_bytes = file_bytes(
        &repo_root,
        "skills/engineering/code-review/references/review-template.md",
    );
    let review_delta_bytes = rev_agent_bytes;
    let rev_iter_subag_bytes = rev_agent_bytes + fixer_agent_bytes;
    let plan_cmd_bytes = file_bytes(&repo_root, "commands/b3-plan.md")
        + file_bytes(&repo_root, "skills/engineering/planning/SKILL.md");
    let impl_cmd_bytes = file_bytes(&repo_root, "commands/b3-implement.md")
        + file_bytes(&repo_root, "skills/engineering/problem-solving/SKILL.md");
    let debug_cmd_bytes = file_bytes(&repo_root, "commands/b3-debug.md")
        + file_bytes(&repo_root, "skills/engineering/debugging/SKILL.md");
    let review_cmd_bytes = file_bytes(&repo_root, "commands/b3-review.md") + cr_skill_bytes;
    let standalone_rev_all_bytes = review_cmd_bytes + rev_tpl_bytes;
    let verify_cmd_bytes = file_bytes(&repo_root, "commands/b3-verify.md")
        + file_bytes(&repo_root, "skills/engineering/verification/SKILL.md");
    let pr_fb_skill_bytes = file_bytes(&repo_root, "skills/engineering/pr-feedback/SKILL.md");
    let pr_fb_refs_bytes = file_bytes(
        &repo_root,
        "skills/engineering/pr-feedback/references/reply-template.md",
    ) + file_bytes(
        &repo_root,
        "skills/engineering/pr-feedback/references/thread-lifecycle.md",
    ) + file_bytes(
        &repo_root,
        "skills/engineering/pr-feedback/references/github-adapter.md",
    );
    let rl_op_bytes =
        rl_strategy_bytes + file_bytes(&repo_root, "commands/b3-review-loop.md") + rev_agent_bytes;
    let rl_hier_bytes = rl_op_bytes + file_bytes(&repo_root, "review-loop/hierarchical.md");
    let rl_all_bytes = file_bytes(&repo_root, "review-loop/spec.md")
        + rl_strategy_bytes
        + file_bytes(&repo_root, "review-loop/sizing.md")
        + file_bytes(&repo_root, "review-loop/models.md")
        + file_bytes(&repo_root, "review-loop/hierarchical.md");

    let mut lines = Vec::with_capacity(20);
    lines.push("=== B3 Context Budget Report ===".to_string());
    lines.push(format!(
        "always_on_total   : {:6} B (~{:4} tok)  [AGENTS.md={} B, rules={} B, {} skill frontmatters={} B]",
        always_on_bytes,
        est_tokens(always_on_bytes),
        agents_bytes,
        rules_bytes,
        skill_files.len(),
        fm_total_bytes
    ));
    lines.push(format!(
        "ship_core_load    : {:6} B (~{:4} tok)  [ship.md={} B + commands/b3-ship.md]",
        ship_core_bytes,
        est_tokens(ship_core_bytes),
        wf_ship_bytes
    ));
    lines.push(format!(
        "ship_refs_load    : {:6} B (~{:4} tok)  [ship-templates.md + ship-resume.md]",
        ship_refs_bytes,
        est_tokens(ship_refs_bytes)
    ));
    lines.push(format!(
        "research_ship_core: {:6} B (~{:4} tok)  [research-ship.md={} B + commands/b3-research-ship.md]",
        rs_core_bytes,
        est_tokens(rs_core_bytes),
        wf_rs_bytes
    ));
    lines.push(format!(
        "research_ship_refs: {:6} B (~{:4} tok)  [research-ship-{{templates,resume,gates}}.md]",
        rs_refs_bytes,
        est_tokens(rs_refs_bytes)
    ));
    lines.push(format!(
        "context_routing   : {:6} B (~{:4} tok)  [workflows/references/context-routing.md (on-demand)]",
        ctx_route_bytes,
        est_tokens(ctx_route_bytes)
    ));
    lines.push(format!(
        "dispatch_naming   : {:6} B (~{:4} tok)  [workflows/references/dispatch-naming.md (on-demand)]",
        disp_naming_bytes,
        est_tokens(disp_naming_bytes)
    ));
    lines.push(format!(
        "review_loop_op    : {:6} B (~{:4} tok)  [strategy={} B + cmd + reviewer={} B]",
        rl_op_bytes,
        est_tokens(rl_op_bytes),
        rl_strategy_bytes,
        rev_agent_bytes
    ));
    lines.push(format!(
        "review_hier_load  : {:6} B (~{:4} tok)  [review_loop_op + hierarchical.md (L/XL/XXL on demand)]",
        rl_hier_bytes,
        est_tokens(rl_hier_bytes)
    ));
    lines.push(format!(
        "review_delta_load : {:6} B (~{:4} tok)  [b3-reviewer.md (self-contained)]",
        review_delta_bytes,
        est_tokens(review_delta_bytes)
    ));
    lines.push(format!(
        "review_iter_subag : {:6} B (~{:4} tok)  [b3-reviewer.md + b3-fixer.md (self-contained loop iter)]",
        rev_iter_subag_bytes,
        est_tokens(rev_iter_subag_bytes)
    ));
    lines.push(format!(
        "standalone_cmds   : plan={plan_cmd_bytes} B, impl={impl_cmd_bytes} B, debug={debug_cmd_bytes} B, review={review_cmd_bytes} B, verify={verify_cmd_bytes} B"
    ));
    lines.push(format!(
        "standalone_rev_all: {:6} B (~{:4} tok)  [cmd + code-review/SKILL.md + review-template.md]",
        standalone_rev_all_bytes,
        est_tokens(standalone_rev_all_bytes)
    ));
    let pr_fb_all = pr_fb_skill_bytes + pr_fb_refs_bytes;
    lines.push(format!(
        "pr_feedback_load  : {:6} B (~{:4} tok)  [pr-feedback/SKILL.md={} B + refs={} B (on-demand)]",
        pr_fb_all,
        est_tokens(pr_fb_all),
        pr_fb_skill_bytes,
        pr_fb_refs_bytes
    ));
    lines.push(format!(
        "review_loop_all   : {:6} B (~{:4} tok)  [spec+strategy+sizing+models+hierarchical (reference-only)]",
        rl_all_bytes,
        est_tokens(rl_all_bytes)
    ));
    lines.push(format!(
        "agents_roles_total: {:6} B (~{:4} tok)  [{agent_role_count} runtime subagent roles excl. README.md]",
        agent_roles_bytes,
        est_tokens(agent_roles_bytes)
    ));
    lines.push(format!(
        "max_skill_file    : {:6} B  ({max_skill_file})",
        max_skill_bytes
    ));
    lines.push(format!(
        "max_frontmatter   : {:6} B  ({max_fm_file})",
        max_fm_bytes
    ));

    let exit_code = if !warnings.is_empty() {
        lines.push(format!("warnings          : {}", warnings.len()));
        for w in &warnings {
            lines.push(format!("  - {w}"));
        }
        if strict {
            1
        } else {
            0
        }
    } else {
        lines.push("warnings          : 0".to_string());
        0
    };

    Ok((lines.join("\n") + "\n", exit_code))
}
