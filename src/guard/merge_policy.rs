use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use crate::error::{fail, B3Error};
use crate::fs::{
    has_control_chars, is_reparse_or_symlink, normalize_repo_root, resolve_unresolved_path,
    sort_ordinal, split_csv_list_as_paths, split_path_csv_checked, test_checkpoint_path,
    test_contained_repo_path,
};
use crate::git::{
    git_program, is_hex40, run_git, run_git_paths_z, test_repo_case_insensitive,
    test_valid_literal_git_path, GitZMode,
};
use crate::guard::ledger::{invoke_review_ledger_check, ReviewLedger};
use crate::guard::push_unique_str;
use crate::guard::verify::{test_verify_receipt, validate_receipt_covers_paths};
use crate::json::{parse_json, JsonValue};
use crate::process::run_command_timeout;

fn is_invalid_ref_token(s: &str) -> bool {
    let low = s.to_ascii_lowercase();
    if s.starts_with('-') || has_control_chars(s) || s.chars().any(|c| c.is_whitespace()) {
        return true;
    }
    if low == "head" || low.starts_with("head~") || low.starts_with("head^") {
        return true;
    }
    if low == "@" || low.starts_with("@~") || low.starts_with("@^") || low.starts_with("@{") {
        return true;
    }
    false
}

fn rev_parse_commit(root: &Path, rev: &str) -> Result<Option<String>, B3Error> {
    let spec = format!("{rev}^{{commit}}");
    let no_env: [(&str, &str); 0] = [];
    let res = run_git(
        root,
        &["rev-parse", "--verify", "--quiet", &spec],
        &no_env,
        None,
    )?;
    if res.exit_code != 0 {
        return Ok(None);
    }
    let sha = String::from_utf8_lossy(&res.stdout).trim().to_string();
    if is_hex40(&sha) {
        Ok(Some(sha))
    } else {
        Ok(None)
    }
}

fn rev_parse_sym_full(root: &Path, rev: &str) -> Result<Option<String>, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let res = run_git(
        root,
        &["rev-parse", "--symbolic-full-name", rev],
        &no_env,
        None,
    )?;
    if res.exit_code != 0 {
        return Ok(None);
    }
    Ok(Some(
        String::from_utf8_lossy(&res.stdout).trim().to_string(),
    ))
}

fn is_ancestor_commit(root: &Path, anc: &str, desc: &str) -> Result<bool, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let res = run_git(
        root,
        &["merge-base", "--is-ancestor", anc, desc],
        &no_env,
        None,
    )?;
    Ok(res.exit_code == 0)
}

fn list_remotes(root: &Path) -> Result<Vec<String>, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let res = run_git(root, &["remote"], &no_env, None)?;
    if res.exit_code != 0 {
        return Ok(Vec::new());
    }
    Ok(String::from_utf8_lossy(&res.stdout)
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect())
}

fn normalize_merge_policy_path(raw_path: &str) -> Option<String> {
    if raw_path.is_empty() || has_control_chars(raw_path) {
        return None;
    }
    let mut s = raw_path.replace('\\', "/");
    if s == "." || s == "./" {
        return Some(".".to_string());
    }
    if s.ends_with('/') {
        s.pop();
    }
    if s.contains(':') || s.starts_with('/') || s.starts_with('~') || s.contains(['*', '?']) {
        return None;
    }
    if !test_valid_literal_git_path(&s) {
        return None;
    }
    Some(s)
}

fn test_protected_path_match_ci(
    candidate: &str,
    patterns: &[String],
    case_insensitive: bool,
) -> bool {
    if candidate.is_empty() || patterns.is_empty() {
        return false;
    }
    for p in patterns {
        if p.is_empty() {
            continue;
        }
        if p == "." || candidate == "." {
            return true;
        }
        let eq = if case_insensitive {
            candidate.eq_ignore_ascii_case(p)
        } else {
            candidate == p
        };
        if eq {
            return true;
        }
        if candidate.len() > p.len() && candidate.as_bytes()[p.len()] == b'/' {
            let pfx_match = if case_insensitive {
                candidate[..p.len()].eq_ignore_ascii_case(p)
            } else {
                &candidate[..p.len()] == p
            };
            if pfx_match {
                return true;
            }
        }
        if p.len() > candidate.len() && p.as_bytes()[candidate.len()] == b'/' {
            let rev_match = if case_insensitive {
                p[..candidate.len()].eq_ignore_ascii_case(candidate)
            } else {
                &p[..candidate.len()] == candidate
            };
            if rev_match {
                return true;
            }
        }
    }
    false
}

enum LsRemoteResult {
    Ok(HashMap<String, String>),
    Unreachable,
}

fn invoke_git_ls_remote_refs(root: &Path, full_refs: &[String]) -> Result<LsRemoteResult, B3Error> {
    let mut clean = Vec::new();
    for r in full_refs {
        if !r.trim().is_empty() {
            push_unique_str(&mut clean, r.clone());
        }
    }
    let mut refs_map = HashMap::new();
    if clean.is_empty() {
        return Ok(LsRemoteResult::Ok(refs_map));
    }

    let mut args = vec![
        "-c".to_string(),
        "credential.helper=".to_string(),
        "ls-remote".to_string(),
        "origin".to_string(),
    ];
    args.extend(clean);
    let env_ls = [
        ("GIT_TERMINAL_PROMPT", "0"),
        ("GCM_INTERACTIVE", "never"),
        ("GIT_ASKPASS", ""),
        ("SSH_ASKPASS", ""),
    ];
    let res = run_command_timeout(
        git_program(),
        &args,
        Some(root),
        &env_ls,
        &["MSYS2_ARG_CONV_EXCL"],
        None,
        Some(8000),
    )?;
    if res.exit_code != 0 {
        return Ok(LsRemoteResult::Unreachable);
    }
    for ln in String::from_utf8_lossy(&res.stdout).lines() {
        let ln_tr = ln.strip_suffix('\r').unwrap_or(ln);
        if let Some((sha, r_name)) = ln_tr.split_once('\t') {
            if is_hex40(sha) && !r_name.is_empty() && !r_name.chars().any(|c| c.is_whitespace()) {
                refs_map.insert(r_name.to_string(), sha.to_string());
            }
        }
    }
    Ok(LsRemoteResult::Ok(refs_map))
}

struct TrunkAuthority {
    sym_full: String,
    branch: String,
    sha: String,
}

fn get_remote_trunk_authority(
    root: &Path,
    remote: &str,
) -> Result<Option<TrunkAuthority>, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let head_sym = format!("refs/remotes/{remote}/HEAD");
    let prefix = format!("refs/remotes/{remote}/");
    let oh_sym = run_git(root, &["symbolic-ref", "-q", &head_sym], &no_env, None)?;
    let oh_full = String::from_utf8_lossy(&oh_sym.stdout).trim().to_string();
    if oh_sym.exit_code == 0 && oh_full.starts_with(&prefix) {
        if let Some(sha) = rev_parse_commit(root, &oh_full)? {
            let branch = oh_full[prefix.len()..].to_string();
            return Ok(Some(TrunkAuthority {
                sym_full: oh_full,
                branch,
                sha,
            }));
        }
    }
    for cand in ["main", "master"] {
        let c_full = format!("refs/remotes/{remote}/{cand}");
        if let Some(sha) = rev_parse_commit(root, &c_full)? {
            return Ok(Some(TrunkAuthority {
                sym_full: c_full,
                branch: cand.to_string(),
                sha,
            }));
        }
    }
    Ok(None)
}

fn get_canonical_trunk_authority(
    root: &Path,
    has_origin: bool,
    allow_local_fallback: bool,
) -> Result<TrunkAuthority, B3Error> {
    if has_origin {
        if let Some(trunk) = get_remote_trunk_authority(root, "origin")? {
            return Ok(trunk);
        }
    }
    if allow_local_fallback {
        for cand in ["main", "master"] {
            let c_full = format!("refs/heads/{cand}");
            if let Some(sha) = rev_parse_commit(root, &c_full)? {
                return Ok(TrunkAuthority {
                    sym_full: c_full,
                    branch: cand.to_string(),
                    sha,
                });
            }
        }
    }
    Ok(TrunkAuthority {
        sym_full: String::new(),
        branch: String::new(),
        sha: String::new(),
    })
}

fn resolve_default_policy_path(repo_root: &Path) -> Result<Option<PathBuf>, B3Error> {
    let dot_b3_raw = repo_root.join(".b3");
    if is_reparse_or_symlink(&dot_b3_raw) {
        return Err(fail("MERGE_BLOCKED: invalid_policy_path", 1));
    }
    let def_pol_raw = repo_root.join(".b3").join("research-policy.json");
    if def_pol_raw.exists() || is_reparse_or_symlink(&def_pol_raw) {
        let Some((full, _)) = test_contained_repo_path(repo_root, ".b3/research-policy.json")
        else {
            return Err(fail("MERGE_BLOCKED: invalid_policy_path", 1));
        };
        if !full.is_file() || is_reparse_or_symlink(&full) {
            return Err(fail("MERGE_BLOCKED: invalid_policy_path", 1));
        }
        Ok(Some(full))
    } else {
        Ok(None)
    }
}

fn diff_against_base_or_tree(
    repo_root: &Path,
    base_sha: &str,
    commit_sha: &str,
) -> Result<Vec<String>, B3Error> {
    if base_sha.is_empty() || base_sha == commit_sha {
        return Ok(Vec::new());
    }
    let no_env: [(&str, &str); 0] = [];
    let (mb_rc, mb_sha) = merge_base_sha(repo_root, base_sha, commit_sha)?;
    if mb_rc == 0 && is_hex40(&mb_sha) {
        run_git_paths_z(
            repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "--name-status",
                "-z",
                &format!("{mb_sha}..{commit_sha}"),
                "--",
            ],
            GitZMode::NameStatus,
            "MERGE_BLOCKED",
            &no_env,
        )
    } else if mb_rc > 1 {
        Err(fail("MERGE_BLOCKED: git_diff_failed", 1))
    } else {
        run_git_paths_z(
            repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "--name-status",
                "-z",
                base_sha,
                commit_sha,
                "--",
            ],
            GitZMode::NameStatus,
            "MERGE_BLOCKED",
            &no_env,
        )
    }
}

fn assert_merge_dirty_worktree_clean(
    root: &Path,
    policy_protected: &[String],
    case_insensitive: bool,
    pol_violation_reason: &str,
) -> Result<(), B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let paths = run_git_paths_z(
        root,
        &["status", "--porcelain=v1", "-z", "-uall"],
        GitZMode::Status,
        "MERGE_BLOCKED",
        &no_env,
    )?;
    let mut has_dirty = false;
    for dp in paths {
        if dp.is_empty() || test_checkpoint_path(&dp) {
            continue;
        }
        if test_protected_path_match_ci(&dp, policy_protected, case_insensitive) {
            return Err(fail(format!("MERGE_BLOCKED: {pol_violation_reason}"), 1));
        }
        has_dirty = true;
    }
    if has_dirty {
        return Err(fail("MERGE_BLOCKED: dirty_worktree", 1));
    }
    Ok(())
}

fn invoke_merge_ledger_gate(
    root: &Path,
    ledger_path_arg: &str,
    expected_base_sha: &str,
    expected_head_sha: &str,
) -> Result<ReviewLedger, B3Error> {
    if ledger_path_arg.trim().is_empty() {
        return Err(fail("MERGE_BLOCKED: missing_ledger_path", 1));
    }
    let Some((led_full, led_rel)) = test_contained_repo_path(root, ledger_path_arg) else {
        return Err(fail("MERGE_BLOCKED: invalid_ledger_path", 1));
    };
    if !led_full.is_file() {
        return Err(fail("MERGE_BLOCKED: missing_ledger_path", 1));
    }
    let chk = invoke_review_ledger_check(root, &led_full, &led_rel, &[]).map_err(|e| {
        fail(
            format!("MERGE_BLOCKED: ledger_check_failed ({})", e.message),
            1,
        )
    })?;
    let led = chk.ledger;
    if led.meta["base_sha"] != expected_base_sha {
        return Err(fail("MERGE_BLOCKED: ledger_target_mismatch", 1));
    }
    if led.meta["head_sha"] != expected_head_sha
        || (led.meta["target_ref"] != "working_tree" && led.meta["target_sha"] != expected_head_sha)
    {
        return Err(fail("MERGE_BLOCKED: ledger_head_mismatch", 1));
    }
    if led.meta["review_independence"] == "SINGLE_AGENT_LIMIT" {
        return Err(fail("MERGE_BLOCKED: single_agent_limit", 1));
    }
    if led.meta["review_independence"] != "INDEPENDENT" {
        return Err(fail("MERGE_BLOCKED: review_independence_unknown", 1));
    }
    Ok(led)
}

fn assert_single_verify_receipt_matches_target(
    root: &Path,
    rec_path: &str,
    ign_paths: &[String],
    head_sha: &str,
    required_paths: &[String],
) -> Result<(), B3Error> {
    if !is_hex40(head_sha) {
        return Err(fail(
            "MERGE_BLOCKED: ci_evidence_invalid(invalid_head_sha)",
            1,
        ));
    }
    let vr = test_verify_receipt(root, rec_path, ign_paths, "", "", head_sha);
    if vr.code != 0 {
        return Err(fail(
            format!("MERGE_BLOCKED: ci_evidence_invalid({})", vr.message),
            1,
        ));
    }
    if let Some(uncovered) = validate_receipt_covers_paths(&vr.relevant_paths_csv, required_paths) {
        if uncovered.is_empty() {
            return Err(fail(
                "MERGE_BLOCKED: ci_evidence_invalid(VERIFY_SCOPE_MISMATCH)",
                1,
            ));
        }
        return Err(fail(
            format!(
                "MERGE_BLOCKED: ci_evidence_invalid(VERIFY_SCOPE_MISMATCH: {})",
                uncovered[0]
            ),
            1,
        ));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn assert_local_ci_evidence(
    root: &Path,
    head_sha: &str,
    changed_paths: &[String],
    rec_path: &str,
    ledger_obj: Option<&ReviewLedger>,
    ign_paths: &[String],
    caller_ci_status: &str,
    require_ci: bool,
) -> Result<(), B3Error> {
    if !rec_path.trim().is_empty() {
        assert_single_verify_receipt_matches_target(
            root,
            rec_path,
            ign_paths,
            head_sha,
            changed_paths,
        )?;
        return Ok(());
    }
    if !require_ci {
        return Ok(());
    }
    if let Some(led) = ledger_obj {
        if !led.units.is_empty() {
            let mut has_all_scope = false;
            let mut covered_list = Vec::new();
            for u in &led.units {
                let ur = u.verify_receipt.as_str();
                if ur.is_empty() || ur == "none" {
                    return Err(fail(
                        format!(
                            "MERGE_BLOCKED: ci_evidence_invalid(ledger_unit_missing_verify_receipt:{})",
                            u.unit_id
                        ),
                        1,
                    ));
                }
                let cached_rel = led
                    .verified_receipts
                    .iter()
                    .find(|rec| {
                        rec.unit_id == u.unit_id
                            && rec.receipt_path == ur
                            && rec.target_commit_sha == head_sha
                    })
                    .map(|rec| rec.relevant_paths_csv.clone());
                let rel_csv = match cached_rel {
                    Some(csv) => csv,
                    None => {
                        let vr_u = test_verify_receipt(root, ur, ign_paths, "", "", head_sha);
                        if vr_u.code != 0 {
                            return Err(fail(
                                format!("MERGE_BLOCKED: ci_evidence_invalid({})", vr_u.message),
                                1,
                            ));
                        }
                        vr_u.relevant_paths_csv
                    }
                };
                if rel_csv == "ALL" {
                    has_all_scope = true;
                } else {
                    for rp in split_csv_list_as_paths(&rel_csv) {
                        if !rp.is_empty() {
                            push_unique_str(&mut covered_list, rp);
                        }
                    }
                }
            }
            if !has_all_scope {
                let covered_csv = covered_list.join(",");
                if let Some(uncovered) = validate_receipt_covers_paths(&covered_csv, changed_paths)
                {
                    if uncovered.is_empty() {
                        return Err(fail(
                            "MERGE_BLOCKED: ci_evidence_invalid(VERIFY_SCOPE_MISMATCH)",
                            1,
                        ));
                    }
                    return Err(fail(
                        format!(
                            "MERGE_BLOCKED: ci_evidence_invalid(VERIFY_SCOPE_MISMATCH: {})",
                            uncovered[0]
                        ),
                        1,
                    ));
                }
            }
            return Ok(());
        }
    }
    if caller_ci_status == "PASS" {
        return Err(fail(
            "MERGE_BLOCKED: ci_evidence_unverified(caller_reported_ci_cannot_authorize)",
            1,
        ));
    }
    Err(fail("MERGE_BLOCKED: ci_evidence_missing", 1))
}

#[derive(Debug, Clone)]
struct MergePolicyConfig {
    auto_merge: String,
    allow_protected: bool,
    require_ci: bool,
    require_review: bool,
    protected_paths: Vec<String>,
    allowed_target_branches: Vec<String>,
}

fn parse_merge_policy_json_text(raw_json: &str) -> Result<MergePolicyConfig, B3Error> {
    let val = parse_json(raw_json).map_err(|_| fail("MERGE_BLOCKED: invalid_policy_json", 1))?;
    if !matches!(val, JsonValue::Object(_)) {
        return Err(fail("MERGE_BLOCKED: invalid_policy_json", 1));
    }

    let mut cfg = MergePolicyConfig {
        auto_merge: "disabled".to_string(),
        allow_protected: false,
        require_ci: true,
        require_review: true,
        protected_paths: Vec::new(),
        allowed_target_branches: Vec::new(),
    };

    if let Some(v) = val
        .get_exact_unique("auto_merge")
        .map_err(|_| fail("MERGE_BLOCKED: invalid_policy_json", 1))?
    {
        let JsonValue::String(s) = v else {
            return Err(fail("MERGE_BLOCKED: invalid_policy_json", 1));
        };
        if has_control_chars(s) {
            return Err(fail("MERGE_BLOCKED: invalid_policy_json", 1));
        }
        let am_val = s.trim();
        if am_val != "disabled" && am_val != "authorized" {
            return Err(fail(
                format!("MERGE_BLOCKED: invalid_auto_merge={am_val}"),
                1,
            ));
        }
        cfg.auto_merge = am_val.to_string();
    }

    for (key, target) in [
        ("allow_protected_paths", &mut cfg.allow_protected),
        ("require_ci", &mut cfg.require_ci),
        ("require_review", &mut cfg.require_review),
    ] {
        if let Some(v) = val
            .get_exact_unique(key)
            .map_err(|_| fail("MERGE_BLOCKED: invalid_policy_json", 1))?
        {
            let JsonValue::Bool(b) = v else {
                return Err(fail("MERGE_BLOCKED: invalid_policy_json", 1));
            };
            *target = *b;
        }
    }

    if let Some(v) = val
        .get_exact_unique("protected_paths")
        .map_err(|_| fail("MERGE_BLOCKED: invalid_policy_json", 1))?
    {
        let JsonValue::Array(arr) = v else {
            return Err(fail("MERGE_BLOCKED: invalid_policy_json", 1));
        };
        for item in arr {
            let JsonValue::String(pp) = item else {
                return Err(fail("MERGE_BLOCKED: invalid_policy_json", 1));
            };
            if pp.contains(['\r', '\n', '\0']) {
                return Err(fail("MERGE_BLOCKED: invalid_policy_json", 1));
            }
            let Some(np) = normalize_merge_policy_path(pp) else {
                return Err(fail("MERGE_BLOCKED: invalid_policy_json", 1));
            };
            push_unique_str(&mut cfg.protected_paths, np);
        }
    }

    if let Some(v) = val
        .get_exact_unique("allowed_target_branches")
        .map_err(|_| fail("MERGE_BLOCKED: invalid_policy_json", 1))?
    {
        let JsonValue::Array(arr) = v else {
            return Err(fail("MERGE_BLOCKED: invalid_policy_json", 1));
        };
        for item in arr {
            let JsonValue::String(bp) = item else {
                return Err(fail("MERGE_BLOCKED: invalid_policy_json", 1));
            };
            if has_control_chars(bp) || bp.chars().any(|c| c.is_whitespace()) {
                return Err(fail("MERGE_BLOCKED: invalid_policy_json", 1));
            }
            let b_trim = bp.trim();
            if b_trim.is_empty() || b_trim.starts_with('-') || b_trim.contains("..") {
                return Err(fail("MERGE_BLOCKED: invalid_policy_json", 1));
            }
            push_unique_str(&mut cfg.allowed_target_branches, b_trim.to_string());
        }
    }

    Ok(cfg)
}

fn match_wildcard_glob(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let t: Vec<char> = text.chars().collect();
    let (mut pi, mut ti) = (0usize, 0usize);
    let mut star_p: Option<usize> = None;
    let mut star_t = 0usize;

    while ti < t.len() {
        if pi < p.len() && p[pi] == t[ti] {
            pi += 1;
            ti += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star_p = Some(pi);
            star_t = ti;
            pi += 1;
        } else if let Some(sp) = star_p {
            pi = sp + 1;
            star_t += 1;
            ti = star_t;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

fn test_branch_pattern_match(branch_name: &str, patterns: &[String]) -> bool {
    if branch_name.is_empty() {
        return false;
    }
    patterns
        .iter()
        .filter(|pat| !pat.is_empty())
        .any(|pat| match_wildcard_glob(pat, branch_name))
}

fn is_governed_target_branch(
    branch: &str,
    trunk_branch: &str,
    allowed_target_branches: &[String],
) -> bool {
    (!trunk_branch.is_empty() && branch == trunk_branch)
        || (!allowed_target_branches.is_empty()
            && test_branch_pattern_match(branch, allowed_target_branches))
        || (trunk_branch.is_empty() && matches!(branch, "main" | "master"))
}

fn enforce_policy_and_protected_paths(
    changed_paths: &[String],
    policy_protected_arr: &[String],
    pol_violation_reason: &str,
    auth_pol_protected: &[String],
    allow_protected: bool,
    require_nonempty_when_protected: bool,
    case_insensitive: bool,
) -> Result<(), B3Error> {
    for cp in changed_paths {
        if !cp.is_empty()
            && test_protected_path_match_ci(cp, policy_protected_arr, case_insensitive)
        {
            return Err(fail(format!("MERGE_BLOCKED: {pol_violation_reason}"), 1));
        }
    }
    if !auth_pol_protected.is_empty() && !allow_protected {
        if changed_paths.is_empty() {
            if require_nonempty_when_protected {
                return Err(fail("MERGE_BLOCKED: missing_changed_paths", 1));
            }
            return Ok(());
        }
        let mut prot_hits = Vec::new();
        for cp in changed_paths {
            if !cp.is_empty()
                && test_protected_path_match_ci(cp, auth_pol_protected, case_insensitive)
            {
                push_unique_str(&mut prot_hits, cp.clone());
            }
        }
        if !prot_hits.is_empty() {
            return Err(fail(
                format!(
                    "MERGE_BLOCKED: protected_paths={}",
                    sort_ordinal(prot_hits, false).join(",")
                ),
                1,
            ));
        }
    }
    Ok(())
}

fn assert_target_branch_preserved_policy(
    repo_root: &Path,
    auth_sha: &str,
    target_base_sha: &str,
    policy_protected_arr: &[String],
    case_insensitive: bool,
) -> Result<(), B3Error> {
    if target_base_sha == auth_sha {
        return Ok(());
    }
    let (mb_rc, mb_sha) = merge_base_sha(repo_root, auth_sha, target_base_sha)?;
    if mb_rc != 0 || !is_hex40(&mb_sha) {
        return Err(fail(
            "MERGE_BLOCKED: target_branch_unrelated_to_authority",
            1,
        ));
    }
    let no_env: [(&str, &str); 0] = [];
    let t_pol_paths = run_git_paths_z(
        repo_root,
        &[
            "diff",
            "--no-ext-diff",
            "--name-status",
            "-z",
            &format!("{mb_sha}..{target_base_sha}"),
            "--",
        ],
        GitZMode::NameStatus,
        "MERGE_BLOCKED",
        &no_env,
    )?;
    for tp in t_pol_paths {
        if !tp.is_empty()
            && test_protected_path_match_ci(&tp, policy_protected_arr, case_insensitive)
        {
            return Err(fail("MERGE_BLOCKED: target_branch_modified_policy", 1));
        }
    }
    Ok(())
}

fn resolve_explicit_github_verify_adapter(err_prefix: &str) -> Result<Option<PathBuf>, B3Error> {
    if let Ok(explicit) = std::env::var("B3_GITHUB_VERIFY_ADAPTER") {
        let trimmed = explicit.trim();
        if !trimmed.is_empty() {
            let p = PathBuf::from(trimmed);
            if p.is_file() {
                return Ok(Some(p));
            }
            return Err(fail(format!("{err_prefix}: github_adapter_missing"), 1));
        }
    }
    Ok(None)
}

struct GhVerifyData {
    fields: HashMap<String, String>,
    pr_changed_files: Vec<String>,
}

fn invoke_b3_github_verify(
    mode: &str,
    root_dir: &Path,
    explicit_repo: &str,
    pr_num: &str,
    err_prefix: &str,
) -> Result<GhVerifyData, B3Error> {
    let root_str = root_dir.to_string_lossy().into_owned();
    let repo_trimmed = explicit_repo.trim();

    let (exit_code, combined) = if let Some(adapter_path) =
        resolve_explicit_github_verify_adapter(err_prefix)?
    {
        let adapter_str = adapter_path.to_string_lossy().into_owned();
        let no_env: [(&str, &str); 0] = [];
        let is_ps1 = adapter_path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| e.eq_ignore_ascii_case("ps1"));

        let out = if is_ps1 {
            let mut args = vec![
                "-NoProfile".to_string(),
                "-ExecutionPolicy".to_string(),
                "Bypass".to_string(),
                "-File".to_string(),
                adapter_str,
                "-Mode".to_string(),
                mode.to_string(),
                "-RepoRoot".to_string(),
                root_str,
            ];
            if !repo_trimmed.is_empty() {
                args.push("-Repo".to_string());
                args.push(repo_trimmed.to_string());
            }
            args.push("-PrNumber".to_string());
            args.push(pr_num.to_string());
            run_command_timeout(
                OsStr::new("powershell"),
                &args,
                Some(root_dir),
                &no_env,
                &[],
                None,
                None,
            )?
        } else {
            let bash_exe =
                if cfg!(windows) && Path::new("C:\\Program Files\\Git\\bin\\bash.exe").is_file() {
                    "C:\\Program Files\\Git\\bin\\bash.exe"
                } else {
                    "bash"
                };
            let mut args = vec![
                adapter_str,
                "--mode".to_string(),
                mode.to_string(),
                "--repo-root".to_string(),
                root_str,
            ];
            if !repo_trimmed.is_empty() {
                args.push("--repo".to_string());
                args.push(repo_trimmed.to_string());
            }
            args.push("--pr-number".to_string());
            args.push(pr_num.to_string());
            run_command_timeout(
                OsStr::new(bash_exe),
                &args,
                Some(root_dir),
                &no_env,
                &[],
                None,
                None,
            )?
        };

        let mut msg = String::from_utf8_lossy(&out.stdout).into_owned();
        if !out.stderr.is_empty() {
            if !msg.is_empty() && !msg.ends_with('\n') {
                msg.push('\n');
            }
            msg.push_str(&String::from_utf8_lossy(&out.stderr));
        }
        (out.exit_code, msg)
    } else {
        match crate::pr::verify::run(mode, &root_str, true, repo_trimmed, pr_num, "", "") {
            Ok((stdout, code)) => (code, stdout),
            Err(err) => (err.code, err.message),
        }
    };

    let lines: Vec<&str> = combined
        .split('\n')
        .map(|l| l.strip_suffix('\r').unwrap_or(l))
        .collect();

    if exit_code != 0 {
        let first = lines.first().copied().unwrap_or("");
        let stripped = first
            .strip_prefix("GH_VERIFY_UNAVAILABLE:")
            .or_else(|| first.strip_prefix("GH_VERIFY_ERROR:"))
            .unwrap_or(first)
            .trim();
        let detail = if stripped.is_empty() {
            "unknown"
        } else {
            stripped
        };
        if exit_code == 2 {
            return Err(fail(
                format!("PROVIDER_UNAVAILABLE: github_verification_failed({detail})"),
                2,
            ));
        }
        if detail.eq_ignore_ascii_case("origin_remote_missing")
            || detail.eq_ignore_ascii_case("origin_remote_not_github")
            || detail.eq_ignore_ascii_case("repo_mismatch")
            || detail.eq_ignore_ascii_case("invalid_repo")
        {
            return Err(fail(format!("{err_prefix}: {detail}"), 1));
        }
        return Err(fail(
            format!("{err_prefix}: github_verification_failed({detail})"),
            1,
        ));
    }

    let mut fields = HashMap::new();
    let mut pr_changed_files = Vec::new();
    for ln in lines {
        if ln.is_empty() {
            continue;
        }
        let Some((k, v)) = ln.split_once('=') else {
            return Err(fail(
                format!("{err_prefix}: github_verification_failed(malformed_adapter_output)"),
                1,
            ));
        };
        if k.is_empty() {
            return Err(fail(
                format!("{err_prefix}: github_verification_failed(malformed_adapter_output)"),
                1,
            ));
        }
        if k == "pr_changed_file" {
            if !v.is_empty() {
                pr_changed_files.push(v.to_string());
            }
        } else if fields.insert(k.to_string(), v.to_string()).is_some() {
            return Err(fail(
                format!("{err_prefix}: github_verification_failed(duplicate_adapter_key)"),
                1,
            ));
        }
    }

    let schema = fields.get("schema").map(String::as_str).unwrap_or("");
    let got_mode = fields.get("mode").map(String::as_str).unwrap_or("");
    if !matches!(schema, "b3-gh-verify-v2" | "b3-gh-verify-v1") || got_mode != mode {
        return Err(fail(
            format!("{err_prefix}: github_verification_failed(invalid_adapter_schema)"),
            1,
        ));
    }
    Ok(GhVerifyData {
        fields,
        pr_changed_files,
    })
}

fn check_policy_blob_in_tree(root: &Path, commit_sha: &str) -> Result<bool, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let ls = run_git(
        root,
        &["ls-tree", commit_sha, "--", ".b3/research-policy.json"],
        &no_env,
        None,
    )?;
    if ls.exit_code != 0 {
        return Ok(false);
    }
    let line = String::from_utf8_lossy(&ls.stdout).trim().to_string();
    Ok(is_policy_ls_tree_line(&line))
}

fn is_policy_ls_tree_line(line: &str) -> bool {
    let Some((meta, path)) = line.split_once('\t') else {
        return false;
    };
    if path != ".b3/research-policy.json" {
        return false;
    }
    let parts: Vec<&str> = meta.split_whitespace().collect();
    parts.len() == 3
        && matches!(parts[0], "100644" | "100755")
        && parts[1] == "blob"
        && is_hex40(parts[2])
}

fn show_commit_file(
    root: &Path,
    commit_sha: &str,
    rel_path: &str,
) -> Result<Option<String>, B3Error> {
    let spec = format!("{commit_sha}:{rel_path}");
    let no_env: [(&str, &str); 0] = [];
    let res = run_git(root, &["show", &spec], &no_env, None)?;
    if res.exit_code != 0 {
        return Ok(None);
    }
    Ok(Some(String::from_utf8_lossy(&res.stdout).into_owned()))
}

fn map_policy_parse_err(e: B3Error, post_merge: bool) -> B3Error {
    if post_merge {
        if let Some(detail) = e.message.strip_prefix("MERGE_BLOCKED: ") {
            return fail(format!("POST_MERGE_FAILED: {detail}"), 1);
        }
        return fail("POST_MERGE_FAILED: invalid_policy_json", 1);
    }
    e
}

fn extract_branch_from_sym_full(sym_full: &str, origin_only: bool) -> Option<String> {
    if let Some(rest) = sym_full.strip_prefix("refs/heads/") {
        return Some(rest.to_string());
    }
    if origin_only {
        return sym_full
            .strip_prefix("refs/remotes/origin/")
            .map(|s| s.to_string());
    }
    let after_rem = sym_full.strip_prefix("refs/remotes/")?;
    let (_, branch) = after_rem.split_once('/')?;
    if branch.is_empty() {
        None
    } else {
        Some(branch.to_string())
    }
}

fn merge_base_sha(root: &Path, a: &str, b: &str) -> Result<(i32, String), B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let res = run_git(root, &["merge-base", a, b], &no_env, None)?;
    Ok((
        res.exit_code,
        String::from_utf8_lossy(&res.stdout).trim().to_string(),
    ))
}

/// Executes `b3 guard merge-policy-check`.
#[allow(clippy::too_many_arguments)]
pub fn run(
    repo_root_raw: &str,
    policy_path: &str,
    pr_state_opt: Option<&str>,
    ci_status_opt: Option<&str>,
    review_status_opt: Option<&str>,
    blocking_findings: i32,
    governance_status: &str,
    changed_paths: &str,
    post_merge: bool,
    merged_sha: &str,
    main_ref: &str,
    target_ref: &str,
    authority_ref: &str,
    base_sha: &str,
    head_sha_arg: &str,
    ledger_path: &str,
    receipt_path: &str,
    ignore_dirty_paths: &str,
    pr_number: &str,
    repo_arg: &str,
    target_branch: &str,
    local_only: bool,
    require_remote_ci: bool,
) -> Result<(String, i32), B3Error> {
    let repo_root = normalize_repo_root(repo_root_raw)?;
    let mp_err_prefix = if post_merge {
        "POST_MERGE_FAILED"
    } else {
        "MERGE_BLOCKED"
    };
    let ignored = split_path_csv_checked(ignore_dirty_paths, mp_err_prefix, true, None)?;

    let pr_state_explicit = pr_state_opt.is_some();
    let ci_status_explicit = ci_status_opt.is_some();
    let rev_status_explicit = review_status_opt.is_some();

    let pr_st = pr_state_opt.unwrap_or("NONE").trim();
    if !matches!(pr_st, "OPEN" | "MERGED" | "CLOSED" | "NONE") {
        return Err(fail(format!("MERGE_BLOCKED: invalid_pr_state={pr_st}"), 1));
    }
    let ci_st = ci_status_opt.unwrap_or("UNKNOWN").trim();
    if !matches!(ci_st, "PASS" | "FAIL" | "PENDING" | "UNKNOWN") {
        return Err(fail(format!("MERGE_BLOCKED: invalid_ci_status={ci_st}"), 1));
    }
    let rev_st = review_status_opt.unwrap_or("UNKNOWN").trim();
    if !matches!(rev_st, "PASS" | "BLOCKED" | "PENDING" | "UNKNOWN") {
        return Err(fail(
            format!("MERGE_BLOCKED: invalid_review_status={rev_st}"),
            1,
        ));
    }
    let gov_st = if governance_status.trim().is_empty() {
        "CLEAR"
    } else {
        governance_status.trim()
    };
    if !matches!(
        gov_st,
        "CLEAR"
            | "BLOCKED"
            | "MISSING_OWNER_DECISION"
            | "WITHHELD_PROMOTION"
            | "UNAUTHORIZED_AUTHORITY"
            | "INVALID_EDITORIAL_REVIEW"
            | "UNAUTHORIZED_REVIEWER"
    ) {
        return Err(fail(
            format!("MERGE_BLOCKED: invalid_governance={gov_st}"),
            1,
        ));
    }
    if blocking_findings < 0 {
        return Err(fail(
            format!("MERGE_BLOCKED: invalid_blocking_findings={blocking_findings}"),
            1,
        ));
    }

    let pr_num_trim = pr_number.trim();
    let target_br_trim = target_branch.trim();
    if !target_br_trim.is_empty()
        && (target_br_trim.starts_with('-')
            || has_control_chars(target_br_trim)
            || target_br_trim.chars().any(|c| c.is_whitespace())
            || target_br_trim.contains(".."))
    {
        return Err(fail(format!("{mp_err_prefix}: invalid_target_branch"), 1));
    }

    let t_ref_arg = target_ref.trim();
    let m_ref_arg = main_ref.trim();
    if !t_ref_arg.is_empty() && !m_ref_arg.is_empty() && t_ref_arg != m_ref_arg {
        return Err(fail(format!("{mp_err_prefix}: conflicting_target_ref"), 1));
    }
    let eff_target_ref_arg = if !t_ref_arg.is_empty() {
        t_ref_arg
    } else {
        m_ref_arg
    };
    let auth_ref_arg = authority_ref.trim();
    let head_sha_arg_trim = head_sha_arg.trim();

    if post_merge {
        if pr_state_explicit && pr_st != "MERGED" {
            return Err(fail(format!("POST_MERGE_FAILED: pr_state={pr_st}"), 1));
        }
        let m_ref = eff_target_ref_arg;
        if m_ref.is_empty() {
            return Err(fail("POST_MERGE_FAILED: missing_main_ref", 1));
        }
        if is_invalid_ref_token(m_ref) {
            return Err(fail("POST_MERGE_FAILED: invalid_main_ref", 1));
        }
        let Some(sym_full) = rev_parse_sym_full(&repo_root, m_ref)? else {
            return Err(fail("POST_MERGE_FAILED: invalid_main_ref", 1));
        };
        let Some(local_target_branch) = extract_branch_from_sym_full(&sym_full, false) else {
            return Err(fail("POST_MERGE_FAILED: invalid_main_ref", 1));
        };
        if !target_br_trim.is_empty() && target_br_trim != local_target_branch {
            return Err(fail(
                format!(
                    "POST_MERGE_FAILED: target_branch_mismatch(expected={target_br_trim},got={local_target_branch})"
                ),
                1,
            ));
        }
        let m_sha = merged_sha.trim();
        if m_sha.starts_with('-') || head_sha_arg_trim.starts_with('-') {
            return Err(fail("POST_MERGE_FAILED: invalid_ref", 1));
        }

        if !pr_num_trim.is_empty() {
            if pr_num_trim.starts_with('0') || !pr_num_trim.bytes().all(|b| b.is_ascii_digit()) {
                return Err(fail("POST_MERGE_FAILED: invalid_pr_number", 1));
            }
            let gh_post = invoke_b3_github_verify(
                "post-merge",
                &repo_root,
                repo_arg,
                pr_num_trim,
                "POST_MERGE_FAILED",
            )?;
            let f = &gh_post.fields;
            let f_get = |k: &str| f.get(k).map(String::as_str).unwrap_or("");
            if f_get("pr_number") != pr_num_trim {
                return Err(fail("POST_MERGE_FAILED: pr_identity_mismatch", 1));
            }
            if !repo_arg.trim().is_empty()
                && !f_get("base_repo").eq_ignore_ascii_case(repo_arg.trim())
            {
                return Err(fail("POST_MERGE_FAILED: pr_identity_mismatch", 1));
            }
            if f_get("pr_merged") != "true" || f_get("pr_state") != "CLOSED" {
                return Err(fail(
                    format!(
                        "POST_MERGE_FAILED: pr_not_merged(state={},merged={})",
                        f_get("pr_state"),
                        f_get("pr_merged")
                    ),
                    1,
                ));
            }
            let gh_merge_sha = f_get("merge_commit_sha");
            let gh_base_ref = f_get("base_ref");
            let gh_head_sha = f_get("head_sha");
            if !is_hex40(gh_merge_sha) {
                return Err(fail("POST_MERGE_FAILED: missing_merge_commit_sha", 1));
            }
            if local_target_branch != gh_base_ref {
                return Err(fail(
                    format!("POST_MERGE_FAILED: target_branch_mismatch(expected={gh_base_ref},got={local_target_branch})"),
                    1,
                ));
            }
            if !target_br_trim.is_empty() && target_br_trim != gh_base_ref {
                return Err(fail(
                    format!("POST_MERGE_FAILED: target_branch_mismatch(expected={gh_base_ref},got={target_br_trim})"),
                    1,
                ));
            }
            if !m_sha.is_empty() {
                let Some(caller_m_sha) = rev_parse_commit(&repo_root, m_sha)? else {
                    return Err(fail("POST_MERGE_FAILED: unresolvable_commit", 1));
                };
                if caller_m_sha != gh_merge_sha {
                    return Err(fail(
                        format!("POST_MERGE_FAILED: merge_commit_sha_mismatch(expected={gh_merge_sha},got={caller_m_sha})"),
                        1,
                    ));
                }
            }
            if !head_sha_arg_trim.is_empty() {
                let Some(caller_h_sha) = rev_parse_commit(&repo_root, head_sha_arg_trim)? else {
                    return Err(fail("POST_MERGE_FAILED: invalid_head_sha", 1));
                };
                if caller_h_sha != gh_head_sha {
                    return Err(fail(
                        format!("POST_MERGE_FAILED: head_sha_mismatch(expected={gh_head_sha},got={caller_h_sha})"),
                        1,
                    ));
                }
            }
            let cmp_st = f_get("compare_status");
            let cmp_behind = f_get("compare_behind_by");
            if !matches!(cmp_st, "identical" | "ahead") || cmp_behind != "0" {
                return Err(fail(
                    format!("POST_MERGE_FAILED: merge_commit_not_in_remote_target(status={cmp_st},target_ref={gh_base_ref})"),
                    1,
                ));
            }

            let Some(res_merged) = rev_parse_commit(&repo_root, gh_merge_sha)? else {
                return Err(fail("POST_MERGE_FAILED: unresolvable_commit", 1));
            };
            let Some(res_main) = rev_parse_commit(&repo_root, m_ref)? else {
                return Err(fail("POST_MERGE_FAILED: unresolvable_commit", 1));
            };
            if !is_ancestor_commit(&repo_root, &res_merged, &res_main)? {
                return Err(fail(
                    format!("POST_MERGE_FAILED: sha_not_in_target(sha={res_merged},target_ref={gh_base_ref},main_ref={m_ref})"),
                    1,
                ));
            }

            let gh_pm_auth_ref = f_get("policy_authority_ref");
            let gh_pm_auth_sha = f_get("policy_authority_sha");
            if gh_pm_auth_ref.is_empty() || !is_hex40(gh_pm_auth_sha) {
                return Err(fail("POST_MERGE_FAILED: incomplete_pr_metadata", 1));
            }
            if rev_parse_commit(&repo_root, gh_pm_auth_sha)?.as_deref() != Some(gh_pm_auth_sha) {
                return Err(fail("POST_MERGE_FAILED: policy_authority_not_fetched", 1));
            }
            let no_env: [(&str, &str); 0] = [];
            let pm_pol_ls = run_git(
                &repo_root,
                &["ls-tree", gh_pm_auth_sha, "--", ".b3/research-policy.json"],
                &no_env,
                None,
            )?;
            if pm_pol_ls.exit_code != 0 {
                return Err(fail("POST_MERGE_FAILED: policy_authority_not_fetched", 1));
            }
            let pm_pol_ln = String::from_utf8_lossy(&pm_pol_ls.stdout)
                .trim()
                .to_string();
            if !pm_pol_ln.is_empty() {
                if !is_policy_ls_tree_line(&pm_pol_ln) {
                    return Err(fail("POST_MERGE_FAILED: invalid_policy_path", 1));
                }
                let Some(pol_txt) =
                    show_commit_file(&repo_root, gh_pm_auth_sha, ".b3/research-policy.json")?
                else {
                    return Err(fail("POST_MERGE_FAILED: policy_not_in_authority", 1));
                };
                let pol_obj = parse_merge_policy_json_text(&pol_txt)
                    .map_err(|e| map_policy_parse_err(e, true))?;
                if !pol_obj.allowed_target_branches.is_empty()
                    && !test_branch_pattern_match(gh_base_ref, &pol_obj.allowed_target_branches)
                {
                    return Err(fail(
                        format!("POST_MERGE_FAILED: target_branch_not_allowed({gh_base_ref})"),
                        1,
                    ));
                }
            }

            let par_res = run_git(
                &repo_root,
                &["rev-list", "--parents", "-n", "1", &res_merged],
                &no_env,
                None,
            )?;
            if par_res.exit_code != 0 {
                return Err(fail("POST_MERGE_FAILED: unresolvable_commit", 1));
            }
            let par_cnt = String::from_utf8_lossy(&par_res.stdout)
                .split_whitespace()
                .count()
                .saturating_sub(1);
            let merge_kind = if par_cnt >= 2 {
                if !is_ancestor_commit(&repo_root, gh_head_sha, &res_merged)? {
                    return Err(fail("POST_MERGE_FAILED: merge_commit_head_mismatch", 1));
                }
                "merge_commit"
            } else if res_merged == gh_head_sha {
                "fast_forward"
            } else {
                "squash_or_rebase"
            };
            return Ok((
                format!(
                    "POST_MERGE_VERIFIED: mode=github pr={}#{} pr_status=PR_MERGED sha={res_merged} target_ref={gh_base_ref} main_ref={m_ref} merge_kind={merge_kind} runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED",
                    f_get("base_repo"),
                    pr_num_trim
                ),
                0,
            ));
        }

        // Provider-neutral local post-merge verification
        if m_sha.is_empty() {
            return Err(fail("POST_MERGE_FAILED: missing_merged_sha", 1));
        }
        if !is_hex40(&m_sha.to_ascii_lowercase()) {
            return Err(fail("POST_MERGE_FAILED: invalid_merged_sha", 1));
        }
        if head_sha_arg_trim.is_empty() {
            return Err(fail("POST_MERGE_FAILED: missing_head_sha", 1));
        }
        if !is_hex40(&head_sha_arg_trim.to_ascii_lowercase()) {
            return Err(fail("POST_MERGE_FAILED: invalid_head_sha", 1));
        }
        let Some(res_merged) = rev_parse_commit(&repo_root, m_sha)? else {
            return Err(fail("POST_MERGE_FAILED: unresolvable_commit", 1));
        };
        let Some(res_head_pm) = rev_parse_commit(&repo_root, head_sha_arg_trim)? else {
            return Err(fail("POST_MERGE_FAILED: unresolvable_commit", 1));
        };
        let Some(res_main) = rev_parse_commit(&repo_root, m_ref)? else {
            return Err(fail("POST_MERGE_FAILED: unresolvable_commit", 1));
        };

        let mut res_base_pm = String::new();
        let base_pm_trim = base_sha.trim();
        if !base_pm_trim.is_empty() {
            if base_pm_trim.starts_with('-') || !is_hex40(&base_pm_trim.to_ascii_lowercase()) {
                return Err(fail("POST_MERGE_FAILED: invalid_base_sha", 1));
            }
            let Some(rb) = rev_parse_commit(&repo_root, base_pm_trim)? else {
                return Err(fail("POST_MERGE_FAILED: invalid_base_sha", 1));
            };
            if rb == res_merged {
                return Err(fail("POST_MERGE_FAILED: base_sha_equals_merged_sha", 1));
            }
            if rb == res_head_pm {
                return Err(fail("POST_MERGE_FAILED: base_sha_equals_head", 1));
            }
            if !is_ancestor_commit(&repo_root, &rb, &res_merged)? {
                return Err(fail("POST_MERGE_FAILED: base_not_ancestor_of_merged", 1));
            }
            if !is_ancestor_commit(&repo_root, &rb, &res_head_pm)? {
                return Err(fail("POST_MERGE_FAILED: base_not_ancestor_of_head", 1));
            }
            res_base_pm = rb;
        }

        let remotes_pm = list_remotes(&repo_root)?;
        let has_origin_pm = remotes_pm.iter().any(|r| r == "origin");
        if !local_only && !remotes_pm.is_empty() && !has_origin_pm {
            return Err(fail("POST_MERGE_FAILED: origin_remote_missing", 1));
        }

        let pm_trunk = get_canonical_trunk_authority(&repo_root, has_origin_pm, true)?;
        let mut pm_allowed_branches = Vec::new();
        if !pm_trunk.sha.is_empty() && check_policy_blob_in_tree(&repo_root, &pm_trunk.sha)? {
            if let Some(pol_txt) =
                show_commit_file(&repo_root, &pm_trunk.sha, ".b3/research-policy.json")?
            {
                let pol_obj = parse_merge_policy_json_text(&pol_txt)
                    .map_err(|e| map_policy_parse_err(e, true))?;
                pm_allowed_branches = pol_obj.allowed_target_branches;
            }
        }
        if !pm_allowed_branches.is_empty() {
            if !test_branch_pattern_match(&local_target_branch, &pm_allowed_branches) {
                return Err(fail(
                    format!("POST_MERGE_FAILED: target_branch_not_allowed({local_target_branch})"),
                    1,
                ));
            }
        } else if !pm_trunk.branch.is_empty() {
            if local_target_branch != pm_trunk.branch {
                return Err(fail(
                    format!("POST_MERGE_FAILED: target_branch_not_allowed({local_target_branch})"),
                    1,
                ));
            }
        } else {
            return Err(fail("POST_MERGE_FAILED: canonical_trunk_missing", 1));
        }

        if !is_ancestor_commit(&repo_root, &res_merged, &res_main)? {
            return Err(fail(
                format!("POST_MERGE_FAILED: sha_not_in_target(sha={res_merged},target_ref={local_target_branch},main_ref={m_ref})"),
                1,
            ));
        }
        if has_origin_pm && !local_only {
            let Some(rem_target_sha) = rev_parse_commit(
                &repo_root,
                &format!("refs/remotes/origin/{local_target_branch}"),
            )?
            else {
                return Err(fail("POST_MERGE_FAILED: remote_target_not_fetched", 1));
            };
            let pm_tgt_ref = format!("refs/heads/{local_target_branch}");
            let mut query_refs = vec![pm_tgt_ref.clone()];
            let pm_auth_ref =
                if !pm_trunk.branch.is_empty() && pm_trunk.branch != local_target_branch {
                    Some(format!("refs/heads/{}", pm_trunk.branch))
                } else {
                    None
                };
            if let Some(ref ar) = pm_auth_ref {
                query_refs.push(ar.clone());
            }
            let LsRemoteResult::Ok(refs_map) = invoke_git_ls_remote_refs(&repo_root, &query_refs)?
            else {
                return Err(fail(
                    "PROVIDER_UNAVAILABLE: post_merge_remote_unverifiable",
                    2,
                ));
            };
            let Some(pm_live_target_sha) = refs_map.get(&pm_tgt_ref) else {
                return Err(fail("POST_MERGE_FAILED: remote_target_ref_missing", 1));
            };
            if pm_live_target_sha != &rem_target_sha {
                return Err(fail(
                    format!("POST_MERGE_FAILED: stale_remote_target_ref(local={rem_target_sha} remote={pm_live_target_sha})"),
                    1,
                ));
            }
            if !pm_trunk.branch.is_empty() {
                if let Some(ref ar) = pm_auth_ref {
                    let Some(rem_auth) = refs_map.get(ar) else {
                        return Err(fail("POST_MERGE_FAILED: remote_authority_ref_missing", 1));
                    };
                    if rem_auth != &pm_trunk.sha {
                        return Err(fail(
                            format!("POST_MERGE_FAILED: stale_remote_authority_ref(local={} remote={rem_auth})", pm_trunk.sha),
                            1,
                        ));
                    }
                } else if pm_live_target_sha != &pm_trunk.sha {
                    return Err(fail(
                        format!("POST_MERGE_FAILED: stale_remote_authority_ref(local={} remote={pm_live_target_sha})", pm_trunk.sha),
                        1,
                    ));
                }
            }
            if !is_ancestor_commit(&repo_root, &res_merged, &rem_target_sha)? {
                return Err(fail(
                    format!("POST_MERGE_FAILED: merge_commit_not_in_remote_target(target_ref={local_target_branch})"),
                    1,
                ));
            }
        }

        let no_env: [(&str, &str); 0] = [];
        let par_res = run_git(
            &repo_root,
            &["rev-list", "--parents", "-n", "1", &res_merged],
            &no_env,
            None,
        )?;
        if par_res.exit_code != 0 {
            return Err(fail("POST_MERGE_FAILED: unresolvable_commit", 1));
        }
        let par_stdout = String::from_utf8_lossy(&par_res.stdout);
        let par_toks: Vec<&str> = par_stdout.split_whitespace().collect();
        let par_cnt = par_toks.len().saturating_sub(1);
        let merge_kind = if res_merged == res_head_pm {
            "fast_forward"
        } else if par_cnt >= 2 {
            let in_first = is_ancestor_commit(&repo_root, &res_head_pm, par_toks[1])?;
            let mut in_merged = false;
            for p_sha in &par_toks[2..] {
                if is_ancestor_commit(&repo_root, &res_head_pm, p_sha)? {
                    in_merged = true;
                    break;
                }
            }
            if !in_merged || in_first {
                return Err(fail("POST_MERGE_FAILED: merge_commit_head_mismatch", 1));
            }
            "merge_commit"
        } else if par_cnt == 1 {
            if res_base_pm.is_empty() {
                return Err(fail(
                    "POST_MERGE_FAILED: squash_or_rebase_requires_base_sha",
                    1,
                ));
            }
            let p1_sha = par_toks[1];
            if !is_ancestor_commit(&repo_root, &res_base_pm, p1_sha)? {
                return Err(fail(
                    "POST_MERGE_FAILED: base_not_ancestor_of_merged_parent",
                    1,
                ));
            }
            let m_tree_res = run_git(
                &repo_root,
                &[
                    "rev-parse",
                    "--verify",
                    "--quiet",
                    &format!("{res_merged}^{{tree}}"),
                ],
                &no_env,
                None,
            )?;
            let h_tree_res = run_git(
                &repo_root,
                &[
                    "rev-parse",
                    "--verify",
                    "--quiet",
                    &format!("{res_head_pm}^{{tree}}"),
                ],
                &no_env,
                None,
            )?;
            let m_tree = String::from_utf8_lossy(&m_tree_res.stdout)
                .trim()
                .to_string();
            let h_tree = String::from_utf8_lossy(&h_tree_res.stdout)
                .trim()
                .to_string();
            let mut tree_ok = is_hex40(&m_tree) && (p1_sha == res_base_pm && m_tree == h_tree);
            if !tree_ok && is_hex40(&m_tree) {
                let mt_res = run_git(
                    &repo_root,
                    &["merge-tree", "--write-tree", p1_sha, &res_head_pm],
                    &no_env,
                    None,
                )?;
                if mt_res.exit_code == 0 {
                    let mt_line = String::from_utf8_lossy(&mt_res.stdout)
                        .lines()
                        .next()
                        .unwrap_or("")
                        .trim()
                        .to_string();
                    if mt_line == m_tree {
                        tree_ok = true;
                    }
                }
            }
            if !tree_ok {
                return Err(fail("POST_MERGE_FAILED: squash_tree_mismatch", 1));
            }
            "squash_or_rebase"
        } else {
            return Err(fail("POST_MERGE_FAILED: merge_commit_head_mismatch", 1));
        };

        return Ok((
            format!(
                "POST_MERGE_VERIFIED: mode=local sha={res_merged} target_ref={local_target_branch} main_ref={m_ref} merge_kind={merge_kind} runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED"
            ),
            0,
        ));
    }

    // --- Unified Provider-Neutral Pre-Merge Pipeline ---
    let mp_case_insensitive = test_repo_case_insensitive(&repo_root);
    let def_pol_file_full = resolve_default_policy_path(&repo_root)?;

    let pol_explicit = !policy_path.trim().is_empty();
    let mut pol_file_full: Option<PathBuf> = None;
    let mut pol_rel = String::new();
    if pol_explicit {
        let Some((full, rel)) = test_contained_repo_path(&repo_root, policy_path) else {
            return Err(fail("MERGE_BLOCKED: invalid_policy_path", 1));
        };
        if !full.is_file() {
            return Err(fail("MERGE_BLOCKED: missing_policy", 1));
        }
        pol_file_full = Some(full);
        pol_rel = rel;
    }

    let mut changed_arr = Vec::new();
    if !changed_paths.trim().is_empty() {
        let trim_cp = changed_paths.trim();
        if trim_cp != "[]" && trim_cp != "none" {
            let raw_cp = if trim_cp.starts_with('[') && trim_cp.ends_with(']') && trim_cp.len() >= 2
            {
                &trim_cp[1..trim_cp.len() - 1]
            } else {
                changed_paths
            };
            for part in raw_cp.split(',') {
                if part.is_empty() {
                    return Err(fail("MERGE_BLOCKED: invalid_changed_path", 1));
                }
                let mut tok = part.replace('\\', "/");
                if tok == "./" {
                    tok = ".".to_string();
                }
                if tok != "." && !test_valid_literal_git_path(&tok) {
                    let trimmed_tok = tok.trim_start_matches(' ').to_string();
                    if test_valid_literal_git_path(&trimmed_tok) {
                        tok = trimmed_tok;
                    } else {
                        return Err(fail("MERGE_BLOCKED: invalid_changed_path", 1));
                    }
                }
                push_unique_str(&mut changed_arr, tok);
            }
        }
    }

    if !eff_target_ref_arg.is_empty() && is_invalid_ref_token(eff_target_ref_arg) {
        return Err(fail("MERGE_BLOCKED: invalid_target_ref", 1));
    }
    if !auth_ref_arg.is_empty() && is_invalid_ref_token(auth_ref_arg) {
        return Err(fail("MERGE_BLOCKED: invalid_authority_ref", 1));
    }

    let live_head_sha = rev_parse_commit(&repo_root, "HEAD")?.unwrap_or_default();
    if !head_sha_arg_trim.is_empty() {
        if head_sha_arg_trim.starts_with('-') {
            return Err(fail("MERGE_BLOCKED: invalid_head", 1));
        }
        let Some(caller_head_sha) = rev_parse_commit(&repo_root, head_sha_arg_trim)? else {
            return Err(fail("MERGE_BLOCKED: invalid_head", 1));
        };
        if live_head_sha.is_empty() {
            return Err(fail("MERGE_BLOCKED: invalid_head", 1));
        }
        if caller_head_sha != live_head_sha {
            return Err(fail("MERGE_BLOCKED: head_sha_mismatch", 1));
        }
    }

    let remotes_list = list_remotes(&repo_root)?;
    let has_any_remote = !remotes_list.is_empty();
    let has_origin = remotes_list.iter().any(|r| r == "origin");

    let no_env: [(&str, &str); 0] = [];
    let cur_sym_res = run_git(&repo_root, &["symbolic-ref", "-q", "HEAD"], &no_env, None)?;
    let cur_sym_full = if cur_sym_res.exit_code == 0 {
        String::from_utf8_lossy(&cur_sym_res.stdout)
            .trim()
            .to_string()
    } else {
        String::new()
    };

    let canon_trunk = get_canonical_trunk_authority(&repo_root, has_origin, !has_any_remote)?;
    let mut caller_auth_branch = String::new();
    if !auth_ref_arg.is_empty() {
        let Some(caller_auth_sym_full) = rev_parse_sym_full(&repo_root, auth_ref_arg)? else {
            return Err(fail("MERGE_BLOCKED: invalid_authority_ref", 1));
        };
        if !cur_sym_full.is_empty() && caller_auth_sym_full == cur_sym_full {
            return Err(fail("MERGE_BLOCKED: invalid_authority_ref", 1));
        }
        let Some(br) = extract_branch_from_sym_full(&caller_auth_sym_full, false) else {
            return Err(fail("MERGE_BLOCKED: invalid_authority_ref", 1));
        };
        caller_auth_branch = br;
        if !canon_trunk.sym_full.is_empty() && caller_auth_sym_full != canon_trunk.sym_full {
            return Err(fail("MERGE_BLOCKED: authority_ref_mismatch", 1));
        }
    }

    let effective_pol_rel = if !pol_rel.is_empty() {
        pol_rel.clone()
    } else {
        ".b3/research-policy.json".to_string()
    };
    let pol_is_default_path =
        !pol_explicit || effective_pol_rel.eq_ignore_ascii_case(".b3/research-policy.json");
    let mut policy_protected_arr = vec![".b3/research-policy.json".to_string()];
    if !pol_is_default_path {
        policy_protected_arr.push(effective_pol_rel.clone());
    }

    let mut auto_merge = "disabled".to_string();
    let mut pol_protected_paths: Vec<String> = Vec::new();
    let mut allow_protected = false;
    let mut require_ci = false;
    let mut require_review = true;
    let mut _allowed_target_branches: Vec<String> = Vec::new();

    let mut fallback_local_trunk_sha = String::new();
    if canon_trunk.sha.is_empty() && !has_any_remote {
        for cand_br in ["main", "master"] {
            if let Some(sha) = rev_parse_commit(&repo_root, &format!("refs/heads/{cand_br}"))? {
                fallback_local_trunk_sha = sha;
                break;
            }
        }
    }
    let inspect_auth_sha = if !canon_trunk.sha.is_empty() {
        canon_trunk.sha.clone()
    } else {
        fallback_local_trunk_sha
    };
    let is_github_pr_mode = !pr_num_trim.is_empty() && !local_only;
    if !is_github_pr_mode && !local_only && has_any_remote && !has_origin {
        return Err(fail("MERGE_BLOCKED: origin_remote_missing", 1));
    }

    if !pol_is_default_path {
        let p_full = pol_file_full
            .as_ref()
            .expect("pol_file_full set when pol_explicit");
        let pol_txt = std::fs::read_to_string(p_full)
            .map_err(|_| fail("MERGE_BLOCKED: missing_policy", 1))?;
        let pol_parsed = parse_merge_policy_json_text(&pol_txt)?;
        auto_merge = pol_parsed.auto_merge;
        allow_protected = pol_parsed.allow_protected;
        require_ci = pol_parsed.require_ci;
        require_review = pol_parsed.require_review;
        pol_protected_paths = pol_parsed.protected_paths;
        _allowed_target_branches = pol_parsed.allowed_target_branches;
        if !is_github_pr_mode
            && !inspect_auth_sha.is_empty()
            && check_policy_blob_in_tree(&repo_root, &inspect_auth_sha)?
        {
            if let Some(t_txt) =
                show_commit_file(&repo_root, &inspect_auth_sha, ".b3/research-policy.json")?
            {
                let trunk_pol = parse_merge_policy_json_text(&t_txt)?;
                require_ci = require_ci || trunk_pol.require_ci;
                require_review = require_review || trunk_pol.require_review;
                if !trunk_pol.protected_paths.is_empty() {
                    for pp in trunk_pol.protected_paths {
                        push_unique_str(&mut pol_protected_paths, pp);
                    }
                    if !trunk_pol.allow_protected {
                        allow_protected = false;
                    }
                }
            }
        }
    } else if !is_github_pr_mode {
        let mut auth_has_committed_pol = false;
        if !inspect_auth_sha.is_empty() && check_policy_blob_in_tree(&repo_root, &inspect_auth_sha)?
        {
            auth_has_committed_pol = true;
            let Some(a_txt) =
                show_commit_file(&repo_root, &inspect_auth_sha, ".b3/research-policy.json")?
            else {
                return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
            };
            let pol_parsed = parse_merge_policy_json_text(&a_txt)?;
            auto_merge = pol_parsed.auto_merge;
            allow_protected = pol_parsed.allow_protected;
            require_ci = pol_parsed.require_ci;
            require_review = pol_parsed.require_review;
            pol_protected_paths = pol_parsed.protected_paths;
            _allowed_target_branches = pol_parsed.allowed_target_branches;
        }
        if auth_has_committed_pol {
            if !inspect_auth_sha.is_empty()
                && !live_head_sha.is_empty()
                && inspect_auth_sha != live_head_sha
            {
                let (mb_rc, mb_sha) =
                    merge_base_sha(&repo_root, &inspect_auth_sha, &live_head_sha)?;
                if mb_rc == 0 && is_hex40(&mb_sha) {
                    let cr_paths = run_git_paths_z(
                        &repo_root,
                        &[
                            "diff",
                            "--no-ext-diff",
                            "--name-status",
                            "-z",
                            &format!("{mb_sha}..{live_head_sha}"),
                            "--",
                            ".b3/research-policy.json",
                        ],
                        GitZMode::NameStatus,
                        "MERGE_BLOCKED",
                        &no_env,
                    )?;
                    if !cr_paths.is_empty() {
                        return Err(fail("MERGE_BLOCKED: policy_modified_in_pr", 1));
                    }
                } else if mb_rc > 1 {
                    return Err(fail("MERGE_BLOCKED: git_diff_failed", 1));
                }
            }
            for d_args in [
                &[
                    "diff",
                    "--no-ext-diff",
                    "--cached",
                    "--name-status",
                    "-z",
                    "--",
                    ".b3/research-policy.json",
                ][..],
                &[
                    "diff",
                    "--no-ext-diff",
                    "--name-status",
                    "-z",
                    "--",
                    ".b3/research-policy.json",
                ][..],
                &[
                    "diff",
                    "--no-ext-diff",
                    "--name-status",
                    "-z",
                    "HEAD",
                    "--",
                    ".b3/research-policy.json",
                ][..],
            ] {
                let d_paths = run_git_paths_z(
                    &repo_root,
                    d_args,
                    GitZMode::NameStatus,
                    "MERGE_BLOCKED",
                    &no_env,
                )?;
                if !d_paths.is_empty() {
                    return Err(fail("MERGE_BLOCKED: policy_modified_in_pr", 1));
                }
            }
        } else if !inspect_auth_sha.is_empty()
            && !live_head_sha.is_empty()
            && inspect_auth_sha != live_head_sha
        {
            let (mb_rc, mb_sha) = merge_base_sha(&repo_root, &inspect_auth_sha, &live_head_sha)?;
            if mb_rc == 0 && is_hex40(&mb_sha) {
                let cr_paths = run_git_paths_z(
                    &repo_root,
                    &[
                        "diff",
                        "--no-ext-diff",
                        "--name-status",
                        "-z",
                        &format!("{mb_sha}..{live_head_sha}"),
                        "--",
                        ".b3/research-policy.json",
                    ],
                    GitZMode::NameStatus,
                    "MERGE_BLOCKED",
                    &no_env,
                )?;
                if !cr_paths.is_empty() {
                    return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
                }
            } else if mb_rc > 1 {
                return Err(fail("MERGE_BLOCKED: git_diff_failed", 1));
            }
            if def_pol_file_full.is_some() {
                return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
            }
        } else if let Some(ref dp_full) = def_pol_file_full {
            let wt_txt = std::fs::read_to_string(dp_full)
                .map_err(|_| fail("MERGE_BLOCKED: invalid_policy_json", 1))?;
            let wt_pol = parse_merge_policy_json_text(&wt_txt)?;
            if wt_pol.auto_merge == "authorized" {
                return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
            }
            auto_merge = "disabled".to_string();
            allow_protected = wt_pol.allow_protected;
            require_ci = wt_pol.require_ci;
            require_review = true;
            pol_protected_paths = wt_pol.protected_paths;
            _allowed_target_branches = wt_pol.allowed_target_branches;
        }
    }

    if gov_st != "CLEAR" {
        return Err(fail(format!("MERGE_BLOCKED: governance={gov_st}"), 1));
    }

    let mut local_pre_changed = changed_arr.clone();
    if !is_github_pr_mode
        && !inspect_auth_sha.is_empty()
        && !live_head_sha.is_empty()
        && inspect_auth_sha != live_head_sha
    {
        let (mb_rc, mb_sha) = merge_base_sha(&repo_root, &inspect_auth_sha, &live_head_sha)?;
        if mb_rc == 0 && is_hex40(&mb_sha) {
            let loc_diff = run_git_paths_z(
                &repo_root,
                &[
                    "diff",
                    "--no-ext-diff",
                    "--name-status",
                    "-z",
                    &format!("{mb_sha}..{live_head_sha}"),
                    "--",
                ],
                GitZMode::NameStatus,
                "MERGE_BLOCKED",
                &no_env,
            )?;
            for lp in loc_diff {
                if !lp.is_empty() && !test_checkpoint_path(&lp) {
                    push_unique_str(&mut local_pre_changed, lp);
                }
            }
        } else if mb_rc > 1 {
            return Err(fail("MERGE_BLOCKED: git_diff_failed", 1));
        }
    }

    enforce_policy_and_protected_paths(
        &local_pre_changed,
        &policy_protected_arr,
        "policy_modified_in_pr",
        &pol_protected_paths,
        allow_protected,
        false,
        mp_case_insensitive,
    )?;

    if blocking_findings > 0 {
        return Err(fail(
            format!("MERGE_BLOCKED: blocking_findings={blocking_findings}"),
            1,
        ));
    }

    if ci_status_explicit && matches!(ci_st, "FAIL" | "PENDING") {
        return Err(fail(format!("MERGE_BLOCKED: ci_status={ci_st}"), 1));
    }
    if rev_status_explicit && matches!(rev_st, "BLOCKED" | "PENDING") {
        return Err(fail(format!("MERGE_BLOCKED: review_status={rev_st}"), 1));
    }
    if pr_state_explicit && matches!(pr_st, "CLOSED" | "MERGED") {
        return Err(fail(format!("MERGE_BLOCKED: pr_state={pr_st}"), 1));
    }

    if !pol_is_default_path
        && (is_github_pr_mode
            || auto_merge == "authorized"
            || (!inspect_auth_sha.is_empty()
                && !live_head_sha.is_empty()
                && inspect_auth_sha != live_head_sha))
    {
        return Err(fail("MERGE_BLOCKED: policy_path_override_not_allowed", 1));
    }

    // --- GitHub PR Authorization Path ---
    if is_github_pr_mode {
        if pr_num_trim.starts_with('0') || !pr_num_trim.bytes().all(|b| b.is_ascii_digit()) {
            return Err(fail("MERGE_BLOCKED: invalid_pr_number", 1));
        }
        let gh = invoke_b3_github_verify(
            "pre-merge",
            &repo_root,
            repo_arg,
            pr_num_trim,
            "MERGE_BLOCKED",
        )?;
        let f = &gh.fields;
        let f_get = |k: &str| f.get(k).map(String::as_str).unwrap_or("");
        if f_get("pr_number") != pr_num_trim {
            return Err(fail("MERGE_BLOCKED: pr_identity_mismatch", 1));
        }
        if !repo_arg.trim().is_empty() && !f_get("base_repo").eq_ignore_ascii_case(repo_arg.trim())
        {
            return Err(fail("MERGE_BLOCKED: cross_repo_mismatch", 1));
        }
        if f_get("same_repo") != "true" {
            return Err(fail("MERGE_BLOCKED: cross_repo_head_pr", 1));
        }
        if f_get("pr_state") != "OPEN" || f_get("pr_merged") == "true" {
            return Err(fail(
                format!("MERGE_BLOCKED: pr_state={}", f_get("pr_state")),
                1,
            ));
        }
        if f_get("pr_draft") == "true" {
            return Err(fail("MERGE_BLOCKED: pr_is_draft", 1));
        }

        let gh_base_ref = f_get("base_ref");
        let gh_pr_base_sha = f_get("pr_base_sha");
        let gh_live_target_sha = f_get("live_target_sha");
        let gh_head_sha = f_get("head_sha");
        let gh_auth_ref = f_get("policy_authority_ref");
        let gh_auth_sha = f_get("policy_authority_sha");
        if gh_base_ref.is_empty()
            || gh_auth_ref.is_empty()
            || !is_hex40(gh_pr_base_sha)
            || !is_hex40(gh_live_target_sha)
            || !is_hex40(gh_head_sha)
            || !is_hex40(gh_auth_sha)
        {
            return Err(fail("MERGE_BLOCKED: incomplete_pr_metadata", 1));
        }
        if gh_live_target_sha != gh_pr_base_sha {
            return Err(fail("MERGE_BLOCKED: target_branch_moved", 1));
        }
        if !target_br_trim.is_empty() && target_br_trim != gh_base_ref {
            return Err(fail("MERGE_BLOCKED: target_ref_mismatch", 1));
        }
        if !eff_target_ref_arg.is_empty() {
            let t_br_gh = rev_parse_sym_full(&repo_root, eff_target_ref_arg)?
                .and_then(|s| extract_branch_from_sym_full(&s, true))
                .unwrap_or_default();
            if t_br_gh.is_empty() || t_br_gh != gh_base_ref {
                return Err(fail("MERGE_BLOCKED: target_ref_mismatch", 1));
            }
        }
        if !caller_auth_branch.is_empty() && caller_auth_branch != gh_auth_ref {
            return Err(fail("MERGE_BLOCKED: authority_ref_mismatch", 1));
        }

        let base_trim = base_sha.trim();
        if !base_trim.is_empty() {
            if base_trim.starts_with('-') {
                return Err(fail("MERGE_BLOCKED: invalid_base_sha", 1));
            }
            let Some(caller_base_sha) = rev_parse_commit(&repo_root, base_trim)? else {
                return Err(fail("MERGE_BLOCKED: invalid_base_sha", 1));
            };
            if caller_base_sha != gh_live_target_sha {
                if !live_head_sha.is_empty() && caller_base_sha == live_head_sha {
                    return Err(fail("MERGE_BLOCKED: base_sha_equals_head", 1));
                }
                return Err(fail("MERGE_BLOCKED: base_sha_mismatch", 1));
            }
        }
        let resolved_base_sha = gh_live_target_sha;
        if live_head_sha.is_empty() {
            return Err(fail("MERGE_BLOCKED: invalid_head", 1));
        }
        if live_head_sha != gh_head_sha {
            return Err(fail("MERGE_BLOCKED: head_sha_mismatch", 1));
        }
        if resolved_base_sha == live_head_sha {
            return Err(fail("MERGE_BLOCKED: base_sha_equals_head", 1));
        }
        if rev_parse_commit(&repo_root, resolved_base_sha)?.as_deref() != Some(resolved_base_sha) {
            return Err(fail("MERGE_BLOCKED: target_sha_not_fetched", 1));
        }
        if rev_parse_commit(&repo_root, gh_auth_sha)?.as_deref() != Some(gh_auth_sha) {
            return Err(fail("MERGE_BLOCKED: policy_authority_not_fetched", 1));
        }
        if let Some(rem_track_sha) =
            rev_parse_commit(&repo_root, &format!("refs/remotes/origin/{gh_base_ref}"))?
        {
            if rem_track_sha != resolved_base_sha {
                return Err(fail("MERGE_BLOCKED: target_branch_moved", 1));
            }
        }
        if !is_ancestor_commit(&repo_root, resolved_base_sha, &live_head_sha)? {
            return Err(fail("MERGE_BLOCKED: target_branch_moved", 1));
        }

        let auth_has_policy = check_policy_blob_in_tree(&repo_root, gh_auth_sha)?;
        let auth_pol = if auth_has_policy {
            let Some(a_txt) =
                show_commit_file(&repo_root, gh_auth_sha, ".b3/research-policy.json")?
            else {
                return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
            };
            parse_merge_policy_json_text(&a_txt)?
        } else {
            if pol_explicit || def_pol_file_full.is_some() {
                return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
            }
            MergePolicyConfig {
                auto_merge: "disabled".to_string(),
                allow_protected: false,
                require_ci: false,
                require_review: true,
                protected_paths: Vec::new(),
                allowed_target_branches: Vec::new(),
            }
        };
        let gh_pol_violation_reason = if auth_has_policy {
            "policy_modified_in_pr"
        } else {
            "policy_not_in_authority"
        };

        if gh_base_ref != gh_auth_ref {
            assert_target_branch_preserved_policy(
                &repo_root,
                gh_auth_sha,
                resolved_base_sha,
                &policy_protected_arr,
                mp_case_insensitive,
            )?;
        }

        assert_merge_dirty_worktree_clean(
            &repo_root,
            &policy_protected_arr,
            mp_case_insensitive,
            gh_pol_violation_reason,
        )?;

        let mut all_changed = changed_arr.clone();
        for ghf in gh.pr_changed_files {
            if !test_valid_literal_git_path(&ghf) {
                return Err(fail("MERGE_BLOCKED: invalid_pr_changed_path", 1));
            }
            push_unique_str(&mut all_changed, ghf);
        }
        let c_diff_paths = run_git_paths_z(
            &repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "--name-status",
                "-z",
                &format!("{resolved_base_sha}..{live_head_sha}"),
                "--",
            ],
            GitZMode::NameStatus,
            "MERGE_BLOCKED",
            &no_env,
        )?;
        for gp in c_diff_paths {
            if !gp.is_empty() && !test_checkpoint_path(&gp) {
                push_unique_str(&mut all_changed, gp);
            }
        }

        enforce_policy_and_protected_paths(
            &all_changed,
            &policy_protected_arr,
            gh_pol_violation_reason,
            &auth_pol.protected_paths,
            auth_pol.allow_protected,
            true,
            mp_case_insensitive,
        )?;
        if !auth_pol.allowed_target_branches.is_empty()
            && !test_branch_pattern_match(gh_base_ref, &auth_pol.allowed_target_branches)
        {
            return Err(fail(
                format!("MERGE_BLOCKED: target_branch_not_allowed({gh_base_ref})"),
                1,
            ));
        }

        let m_state = f_get("mergeable_state");
        if f_get("mergeable") == "false" {
            return Err(fail(
                format!(
                    "MERGE_BLOCKED: pr_not_mergeable(mergeable={},state={m_state})",
                    f_get("mergeable")
                ),
                1,
            ));
        }
        if m_state == "dirty" {
            return Err(fail(format!("MERGE_BLOCKED: mergeable_state={m_state}"), 1));
        }

        let eff_req_ci = auth_pol.require_ci || require_remote_ci;
        let gh_ci = f_get("gh_ci_status");
        if eff_req_ci {
            if gh_ci != "PASS" {
                return Err(fail(format!("MERGE_BLOCKED: ci_status={gh_ci}"), 1));
            }
        } else if gh_ci == "FAIL" || gh_ci == "PENDING" {
            return Err(fail(format!("MERGE_BLOCKED: ci_status={gh_ci}"), 1));
        }

        if auth_pol.auto_merge != "authorized" {
            if !ledger_path.trim().is_empty()
                && test_contained_repo_path(&repo_root, ledger_path).is_none()
            {
                return Err(fail("MERGE_BLOCKED: invalid_ledger_path", 1));
            }
            return Err(fail("PR_READY: auto_merge=disabled", 2));
        }

        invoke_merge_ledger_gate(&repo_root, ledger_path, resolved_base_sha, &live_head_sha)?;
        return Ok((
            format!(
                "MERGE_AUTHORIZED: mode=github pr={}#{} target_ref={gh_base_ref} target_sha={resolved_base_sha} head_sha={live_head_sha} policy_authority={gh_auth_ref}@{gh_auth_sha} auto_merge=authorized ci={gh_ci} governance=CLEAR",
                f_get("base_repo"),
                pr_num_trim
            ),
            0,
        ));
    }

    // --- Provider-Neutral Local / -LocalOnly / auto_merge=disabled Path ---
    if require_remote_ci {
        return Err(fail(
            "PROVIDER_UNAVAILABLE: remote_ci_requires_provider_verification",
            2,
        ));
    }
    if auto_merge != "authorized" {
        let mut opt_led_obj = None;
        if !ledger_path.trim().is_empty() {
            let Some((l_full, l_rel)) = test_contained_repo_path(&repo_root, ledger_path) else {
                return Err(fail("MERGE_BLOCKED: invalid_ledger_path", 1));
            };
            if l_full.is_file() && require_ci && receipt_path.trim().is_empty() {
                if let Ok(chk) = invoke_review_ledger_check(&repo_root, &l_full, &l_rel, &[]) {
                    opt_led_obj = Some(chk.ledger);
                }
            }
        }
        if !pol_protected_paths.is_empty() && !allow_protected && local_pre_changed.is_empty() {
            return Err(fail("MERGE_BLOCKED: missing_changed_paths", 1));
        }
        if require_ci || !receipt_path.trim().is_empty() {
            assert_local_ci_evidence(
                &repo_root,
                &live_head_sha,
                &local_pre_changed,
                receipt_path,
                opt_led_obj.as_ref(),
                &ignored,
                ci_st,
                require_ci,
            )?;
        }
        if require_review && rev_st != "PASS" && ledger_path.trim().is_empty() {
            return Err(fail(format!("MERGE_BLOCKED: review_status={rev_st}"), 1));
        }
        let bt = base_sha.trim();
        if !bt.is_empty() && (bt.starts_with('-') || rev_parse_commit(&repo_root, bt)?.is_none()) {
            return Err(fail("MERGE_BLOCKED: invalid_base_sha", 1));
        }
        return Err(fail("PR_READY: auto_merge=disabled", 2));
    }

    // auto_merge == 'authorized' without -PrNumber (or with -LocalOnly)
    if pol_explicit && !effective_pol_rel.eq_ignore_ascii_case(".b3/research-policy.json") {
        return Err(fail("MERGE_BLOCKED: policy_path_override_not_allowed", 1));
    }
    if live_head_sha.is_empty() {
        return Err(fail("MERGE_BLOCKED: invalid_head", 1));
    }

    assert_merge_dirty_worktree_clean(
        &repo_root,
        &policy_protected_arr,
        mp_case_insensitive,
        "policy_modified_in_pr",
    )?;

    if !local_only {
        if require_remote_ci {
            return Err(fail("MERGE_BLOCKED: missing_pr_number", 1));
        }
        if has_any_remote && !has_origin {
            return Err(fail("MERGE_BLOCKED: origin_remote_missing", 1));
        }
        if has_origin && canon_trunk.sha.is_empty() {
            return Err(fail("MERGE_BLOCKED: missing_pr_number", 1));
        }
    }

    let eff_auth_sym_full = canon_trunk.sym_full;
    let eff_auth_branch = canon_trunk.branch;
    let eff_auth_sha = inspect_auth_sha;
    if eff_auth_sha.is_empty() {
        return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
    }
    if !check_policy_blob_in_tree(&repo_root, &eff_auth_sha)? {
        return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
    }
    let Some(auth_loc_txt) =
        show_commit_file(&repo_root, &eff_auth_sha, ".b3/research-policy.json")?
    else {
        return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
    };
    let auth_loc_pol = parse_merge_policy_json_text(&auth_loc_txt)?;
    if auth_loc_pol.auto_merge != "authorized" {
        return Err(fail("PR_READY: auto_merge=disabled", 2));
    }

    let mut target_sym_full = String::new();
    let mut target_branch_name = String::new();
    let mut resolved_base_sha = String::new();
    if !eff_target_ref_arg.is_empty() {
        let Some(sym) = rev_parse_sym_full(&repo_root, eff_target_ref_arg)? else {
            return Err(fail("MERGE_BLOCKED: invalid_target_ref", 1));
        };
        if !(sym.starts_with("refs/heads/") || sym.starts_with("refs/remotes/")) {
            return Err(fail("MERGE_BLOCKED: invalid_target_ref", 1));
        }
        if !cur_sym_full.is_empty() && sym == cur_sym_full {
            return Err(fail("MERGE_BLOCKED: invalid_target_ref", 1));
        }
        if !local_only && has_origin && !sym.starts_with("refs/remotes/origin/") {
            return Err(fail("MERGE_BLOCKED: remote_tracking_target_required", 1));
        }
        if !local_only && !has_any_remote && !sym.starts_with("refs/heads/") {
            return Err(fail("MERGE_BLOCKED: invalid_target_ref", 1));
        }
        target_branch_name = extract_branch_from_sym_full(&sym, false).unwrap_or_default();
        if !target_br_trim.is_empty() && target_br_trim != target_branch_name {
            return Err(fail("MERGE_BLOCKED: target_ref_mismatch", 1));
        }
        let Some(sha) = rev_parse_commit(&repo_root, &sym)? else {
            return Err(fail("MERGE_BLOCKED: invalid_target_ref", 1));
        };
        target_sym_full = sym;
        resolved_base_sha = sha;
    } else if !target_br_trim.is_empty() {
        let cand_refs: Vec<String> = if has_origin {
            if local_only {
                vec![
                    format!("refs/remotes/origin/{target_br_trim}"),
                    format!("refs/heads/{target_br_trim}"),
                ]
            } else {
                vec![format!("refs/remotes/origin/{target_br_trim}")]
            }
        } else {
            vec![format!("refs/heads/{target_br_trim}")]
        };
        for cr in cand_refs {
            if let Some(sha) = rev_parse_commit(&repo_root, &cr)? {
                target_sym_full = cr;
                target_branch_name = target_br_trim.to_string();
                resolved_base_sha = sha;
                break;
            }
        }
        if resolved_base_sha.is_empty() {
            return Err(fail("MERGE_BLOCKED: target_sha_not_fetched", 1));
        }
        if !cur_sym_full.is_empty() && target_sym_full == cur_sym_full {
            return Err(fail("MERGE_BLOCKED: invalid_target_ref", 1));
        }
    } else if !eff_auth_sym_full.is_empty() {
        if !cur_sym_full.is_empty() && eff_auth_sym_full == cur_sym_full {
            if !local_only {
                return Err(fail("MERGE_BLOCKED: base_sha_equals_head", 1));
            }
        } else {
            target_sym_full = eff_auth_sym_full.clone();
            target_branch_name = eff_auth_branch.clone();
            resolved_base_sha = eff_auth_sha.clone();
        }
    }

    let base_trim_loc = base_sha.trim();
    if !base_trim_loc.is_empty() {
        if base_trim_loc.starts_with('-') {
            return Err(fail("MERGE_BLOCKED: invalid_base_sha", 1));
        }
        let Some(caller_base_loc) = rev_parse_commit(&repo_root, base_trim_loc)? else {
            return Err(fail("MERGE_BLOCKED: invalid_base_sha", 1));
        };
        if caller_base_loc == live_head_sha {
            return Err(fail("MERGE_BLOCKED: base_sha_equals_head", 1));
        }
        if !resolved_base_sha.is_empty() {
            if caller_base_loc != resolved_base_sha {
                if local_only && eff_target_ref_arg.is_empty() && target_br_trim.is_empty() {
                    resolved_base_sha = caller_base_loc;
                } else {
                    return Err(fail("MERGE_BLOCKED: base_sha_mismatch", 1));
                }
            }
        } else if local_only {
            resolved_base_sha = caller_base_loc;
        }
    }

    if resolved_base_sha.is_empty() {
        return Err(fail(
            if local_only {
                "MERGE_BLOCKED: missing_base_sha"
            } else {
                "MERGE_BLOCKED: invalid_target_ref"
            },
            1,
        ));
    }
    if resolved_base_sha == live_head_sha {
        return Err(fail("MERGE_BLOCKED: base_sha_equals_head", 1));
    }
    if !is_ancestor_commit(&repo_root, &resolved_base_sha, &live_head_sha)? {
        return Err(fail("MERGE_BLOCKED: target_branch_moved", 1));
    }
    if !target_branch_name.is_empty()
        && !auth_loc_pol.allowed_target_branches.is_empty()
        && !test_branch_pattern_match(&target_branch_name, &auth_loc_pol.allowed_target_branches)
    {
        return Err(fail(
            format!("MERGE_BLOCKED: target_branch_not_allowed({target_branch_name})"),
            1,
        ));
    }

    assert_target_branch_preserved_policy(
        &repo_root,
        &eff_auth_sha,
        &resolved_base_sha,
        &policy_protected_arr,
        mp_case_insensitive,
    )?;

    let mut all_changed_loc = changed_arr;
    let c_diff_loc = run_git_paths_z(
        &repo_root,
        &[
            "diff",
            "--no-ext-diff",
            "--name-status",
            "-z",
            &format!("{resolved_base_sha}..{live_head_sha}"),
            "--",
        ],
        GitZMode::NameStatus,
        "MERGE_BLOCKED",
        &no_env,
    )?;
    for gp in c_diff_loc {
        if !gp.is_empty() && !test_checkpoint_path(&gp) {
            push_unique_str(&mut all_changed_loc, gp);
        }
    }

    enforce_policy_and_protected_paths(
        &all_changed_loc,
        &policy_protected_arr,
        "policy_modified_in_pr",
        &auth_loc_pol.protected_paths,
        auth_loc_pol.allow_protected,
        true,
        mp_case_insensitive,
    )?;

    let led_loc_obj =
        invoke_merge_ledger_gate(&repo_root, ledger_path, &resolved_base_sha, &live_head_sha)?;
    assert_local_ci_evidence(
        &repo_root,
        &live_head_sha,
        &all_changed_loc,
        receipt_path,
        Some(&led_loc_obj),
        &ignored,
        ci_st,
        auth_loc_pol.require_ci,
    )?;

    if target_sym_full.is_empty() || eff_auth_sym_full.is_empty() {
        return Err(fail("MERGE_BLOCKED: invalid_target_ref", 1));
    }
    if has_origin && !local_only && !target_sym_full.starts_with("refs/remotes/origin/") {
        return Err(fail("MERGE_BLOCKED: remote_tracking_target_required", 1));
    }
    if !has_any_remote
        && (!target_sym_full.starts_with("refs/heads/")
            || (!cur_sym_full.is_empty() && target_sym_full == cur_sym_full))
    {
        return Err(fail("MERGE_BLOCKED: invalid_target_ref", 1));
    }

    if has_any_remote {
        let mut remote_auth_state = "no_provider_verification";
        if has_origin {
            let mut loc_query_refs = Vec::new();
            let auth_full_ref = if !eff_auth_branch.is_empty() {
                format!("refs/heads/{eff_auth_branch}")
            } else {
                String::new()
            };
            let tgt_full_ref = if !target_branch_name.is_empty() {
                format!("refs/heads/{target_branch_name}")
            } else {
                String::new()
            };
            if !auth_full_ref.is_empty() {
                loc_query_refs.push(auth_full_ref.clone());
            }
            if !tgt_full_ref.is_empty() && tgt_full_ref != auth_full_ref {
                loc_query_refs.push(tgt_full_ref.clone());
            }
            match invoke_git_ls_remote_refs(&repo_root, &loc_query_refs)? {
                LsRemoteResult::Unreachable => {
                    remote_auth_state = "remote_ref_unverifiable";
                }
                LsRemoteResult::Ok(refs_map) => {
                    if !auth_full_ref.is_empty() {
                        let Some(rem_auth) = refs_map.get(&auth_full_ref) else {
                            return Err(fail("MERGE_BLOCKED: remote_authority_ref_missing", 1));
                        };
                        if rem_auth != &eff_auth_sha {
                            return Err(fail(
                                format!("MERGE_BLOCKED: stale_remote_ref(authority local={eff_auth_sha} remote={rem_auth})"),
                                1,
                            ));
                        }
                    }
                    if !tgt_full_ref.is_empty() {
                        let Some(rem_tgt) = refs_map.get(&tgt_full_ref) else {
                            return Err(fail("MERGE_BLOCKED: remote_target_ref_missing", 1));
                        };
                        if rem_tgt != &resolved_base_sha {
                            return Err(fail(
                                format!("MERGE_BLOCKED: stale_remote_ref(target local={resolved_base_sha} remote={rem_tgt})"),
                                1,
                            ));
                        }
                    }
                }
            }
        } else {
            remote_auth_state = "no_origin_remote";
        }
        return Err(fail(
            format!(
                "LOCAL_ELIGIBLE_ONLY: engineering_ready=true remote_authorization=UNVERIFIED({remote_auth_state}) auto_merge=authorized target_ref={target_sym_full} target_sha={resolved_base_sha} head_sha={live_head_sha} policy_authority={eff_auth_sym_full}@{eff_auth_sha} governance=CLEAR"
            ),
            2,
        ));
    }

    if local_only {
        return Err(fail(
            "LOCAL_ELIGIBLE_ONLY: engineering_ready=true auto_merge=authorized",
            2,
        ));
    }

    Ok((
        format!(
            "MERGE_AUTHORIZED: mode=local target_ref={target_sym_full} target_sha={resolved_base_sha} head_sha={live_head_sha} policy_authority={eff_auth_sym_full}@{eff_auth_sha} auto_merge=authorized governance=CLEAR"
        ),
        0,
    ))
}

/// Parsed ref update line from Git's `pre-push` hook standard input.
#[derive(Debug, Clone, PartialEq, Eq)]
struct PrePushRefUpdate {
    local_ref: String,
    local_oid: String,
    remote_ref: String,
    remote_oid: String,
}

fn is_valid_git_oid_hex(s: &str) -> bool {
    (s.len() == 40 || s.len() == 64) && s.bytes().all(|b| b.is_ascii_hexdigit())
}

fn is_invalid_pre_push_ref_token(s: &str) -> bool {
    s.is_empty()
        || s.starts_with('-')
        || s.contains("..")
        || has_control_chars(s)
        || s.chars().any(|c| c.is_whitespace())
}

/// Parses Git's `pre-push` hook stdin lines (`<local-ref> <local-oid> <remote-ref> <remote-oid>`).
fn parse_pre_push_stdin(raw: &str) -> Result<Vec<PrePushRefUpdate>, B3Error> {
    if raw
        .chars()
        .any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t'))
    {
        return Err(fail("MERGE_BLOCKED: invalid_pre_push_stdin", 1));
    }

    let mut updates = Vec::new();
    for line in raw.split(['\n', '\r']) {
        if line.bytes().all(|b| b.is_ascii_whitespace()) {
            continue;
        }
        let toks: Vec<&str> = line.split_ascii_whitespace().collect();
        if toks.len() != 4 {
            return Err(fail("MERGE_BLOCKED: invalid_pre_push_stdin", 1));
        }
        let (local_ref, local_oid, remote_ref, remote_oid) = (toks[0], toks[1], toks[2], toks[3]);
        if is_invalid_pre_push_ref_token(local_ref)
            || is_invalid_pre_push_ref_token(remote_ref)
            || !is_valid_git_oid_hex(local_oid)
            || !is_valid_git_oid_hex(remote_oid)
        {
            return Err(fail("MERGE_BLOCKED: invalid_pre_push_stdin", 1));
        }
        updates.push(PrePushRefUpdate {
            local_ref: local_ref.to_string(),
            local_oid: local_oid.to_string(),
            remote_ref: remote_ref.to_string(),
            remote_oid: remote_oid.to_string(),
        });
    }
    Ok(updates)
}

fn verify_hook_target_ledger_and_ci(
    repo_root: &Path,
    base_sha: &str,
    head_sha: &str,
    ledger_path: &str,
    receipt_path: &str,
    require_ci: bool,
) -> Result<(), B3Error> {
    if base_sha.is_empty() {
        return Err(fail("MERGE_BLOCKED: missing_base_sha", 1));
    }
    let led_obj = invoke_merge_ledger_gate(repo_root, ledger_path, base_sha, head_sha)?;
    let ci_changed: Vec<String> = diff_against_base_or_tree(repo_root, base_sha, head_sha)?
        .into_iter()
        .filter(|p| !p.is_empty() && !test_checkpoint_path(p))
        .collect();
    assert_local_ci_evidence(
        repo_root,
        head_sha,
        &ci_changed,
        receipt_path,
        Some(&led_obj),
        &[],
        "",
        require_ci,
    )
}

enum HookPolicyAuthority {
    EstablishedPolicy,
    LocalAbsentOnly,
    UnknownRemoteAuthority(String),
}

enum RemoteTrackingResolution {
    Trunk(TrunkAuthority),
    Unknown(String),
}

fn is_zero_oid(oid: &str) -> bool {
    oid.bytes().all(|b| b == b'0')
}

fn normalize_remote_url_cmp(raw: &str) -> String {
    let mut s = raw.trim().replace('\\', "/");
    while s.len() > 1 && s.ends_with('/') {
        s.pop();
    }
    #[cfg(windows)]
    {
        let bytes = s.as_bytes();
        if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
            let mut chars: Vec<char> = s.chars().collect();
            chars[0] = chars[0].to_ascii_lowercase();
            return chars.into_iter().collect();
        }
    }
    s
}

fn check_remote_push_destination(
    repo_root: &Path,
    remotes: &[String],
    git_args: &[String],
) -> Result<Result<String, String>, B3Error> {
    if git_args.is_empty() {
        return Ok(Err("missing_push_destination".to_string()));
    }
    let rem = git_args[0].trim();
    if rem.is_empty() || rem.starts_with('-') || !remotes.iter().any(|r| r == rem) {
        return Ok(Err("direct_url_push".to_string()));
    }
    let no_env: [(&str, &str); 0] = [];
    let fetch_res = run_git(repo_root, &["remote", "get-url", rem], &no_env, None)?;
    let fetch_url = String::from_utf8_lossy(&fetch_res.stdout)
        .trim()
        .to_string();
    if fetch_res.exit_code != 0 || fetch_url.is_empty() {
        return Ok(Err("missing_remote_url".to_string()));
    }
    let fetch_norm = normalize_remote_url_cmp(&fetch_url);

    let push_res = run_git(
        repo_root,
        &["remote", "get-url", "--all", "--push", rem],
        &no_env,
        None,
    )?;
    if push_res.exit_code == 0 {
        for line in String::from_utf8_lossy(&push_res.stdout).lines() {
            let p_trim = line.trim();
            if !p_trim.is_empty() && normalize_remote_url_cmp(p_trim) != fetch_norm {
                return Ok(Err("push_url_differs_from_fetch_url".to_string()));
            }
        }
    }

    if let Some(arg_url) = git_args.get(1).map(|s| s.trim()).filter(|s| !s.is_empty()) {
        if normalize_remote_url_cmp(arg_url) != fetch_norm {
            return Ok(Err("push_url_differs_from_fetch_url".to_string()));
        }
    }

    Ok(Ok(rem.to_string()))
}

fn resolve_remote_tracking_authority(
    repo_root: &Path,
    rem: &str,
) -> Result<RemoteTrackingResolution, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let prefix = format!("refs/remotes/{rem}/");
    let head_sym = format!("{prefix}HEAD");
    let oh_sym = run_git(repo_root, &["symbolic-ref", "-q", &head_sym], &no_env, None)?;
    let oh_full = String::from_utf8_lossy(&oh_sym.stdout).trim().to_string();
    if oh_sym.exit_code == 0 && oh_full.starts_with(&prefix) {
        if let Some(sha) = rev_parse_commit(repo_root, &oh_full)? {
            let branch = oh_full[prefix.len()..].to_string();
            return Ok(RemoteTrackingResolution::Trunk(TrunkAuthority {
                sym_full: oh_full,
                branch,
                sha,
            }));
        }
    }

    let f_res = run_git(
        repo_root,
        &[
            "for-each-ref",
            "--format=%(refname)%09%(objecttype)%09%(objectname)",
            &prefix,
        ],
        &no_env,
        None,
    )?;
    if f_res.exit_code != 0 {
        return Ok(RemoteTrackingResolution::Unknown(
            "missing_remote_tracking_refs".to_string(),
        ));
    }

    let mut tracking_refs: Vec<TrunkAuthority> = Vec::new();
    for line in String::from_utf8_lossy(&f_res.stdout).lines() {
        let ln = line.strip_suffix('\r').unwrap_or(line);
        if ln.is_empty() {
            continue;
        }
        let mut parts = ln.split('\t');
        let (Some(refname), Some(obj_type), Some(oid)) = (parts.next(), parts.next(), parts.next())
        else {
            continue;
        };
        if refname == head_sym || !refname.starts_with(&prefix) {
            continue;
        }
        let branch = refname[prefix.len()..].to_string();
        if branch.is_empty() {
            continue;
        }
        let commit_sha = if obj_type == "commit" && is_valid_git_oid_hex(oid) {
            Some(oid.to_string())
        } else {
            rev_parse_commit(repo_root, refname)?
        };
        if let Some(sha) = commit_sha {
            tracking_refs.push(TrunkAuthority {
                sym_full: refname.to_string(),
                branch,
                sha,
            });
        }
    }

    if tracking_refs.is_empty() {
        return Ok(RemoteTrackingResolution::Unknown(
            "missing_remote_tracking_refs".to_string(),
        ));
    }

    let specs: Vec<String> = tracking_refs
        .iter()
        .map(|t| format!("{}:.b3/research-policy.json", t.sha))
        .collect();
    let query_input = format!("{}\n", specs.join("\n"));
    let batch_res = run_git(
        repo_root,
        &["cat-file", "--batch-check"],
        &no_env,
        Some(query_input.as_bytes()),
    )?;
    let mut policy_refs: Vec<(&TrunkAuthority, String)> = Vec::new();
    if batch_res.exit_code == 0 {
        let out = String::from_utf8_lossy(&batch_res.stdout);
        for (t, line) in tracking_refs.iter().zip(out.lines()) {
            let ln = line.strip_suffix('\r').unwrap_or(line).trim();
            let toks: Vec<&str> = ln.split_ascii_whitespace().collect();
            if toks.len() == 3
                && toks[1] == "blob"
                && is_valid_git_oid_hex(toks[0])
                && check_policy_blob_in_tree(repo_root, &t.sha)?
            {
                policy_refs.push((t, toks[0].to_string()));
            }
        }
    }

    for cand in ["main", "master"] {
        if let Some(found) = tracking_refs.iter().find(|t| t.branch == cand) {
            return Ok(RemoteTrackingResolution::Trunk(TrunkAuthority {
                sym_full: found.sym_full.clone(),
                branch: found.branch.clone(),
                sha: found.sha.clone(),
            }));
        }
    }

    if !policy_refs.is_empty() {
        let first_blob = &policy_refs[0].1;
        if policy_refs.iter().all(|(_, b)| b == first_blob) {
            let chosen = ["trunk", "develop", "development"]
                .iter()
                .find_map(|pref| policy_refs.iter().find(|(t, _)| t.branch == *pref))
                .map(|(t, _)| *t)
                .unwrap_or_else(|| {
                    policy_refs
                        .iter()
                        .min_by(|(a, _), (b, _)| a.branch.cmp(&b.branch))
                        .expect("non-empty policy_refs")
                        .0
                });
            return Ok(RemoteTrackingResolution::Trunk(TrunkAuthority {
                sym_full: chosen.sym_full.clone(),
                branch: chosen.branch.clone(),
                sha: chosen.sha.clone(),
            }));
        }
        return Err(fail("MERGE_BLOCKED: ambiguous_policy_authority", 1));
    }

    Ok(RemoteTrackingResolution::Unknown(
        "unconfigured_remote_head".to_string(),
    ))
}

fn read_merge_head_commits(repo_root: &Path) -> Result<Vec<String>, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let res = run_git(
        repo_root,
        &["rev-parse", "--git-path", "MERGE_HEAD"],
        &no_env,
        None,
    )?;
    if res.exit_code != 0 {
        return Ok(Vec::new());
    }
    let raw_rel = String::from_utf8_lossy(&res.stdout).trim().to_string();
    if raw_rel.is_empty() {
        return Ok(Vec::new());
    }
    let mh_path = resolve_unresolved_path(repo_root, &raw_rel);
    if !mh_path.is_file() {
        return Ok(Vec::new());
    }
    let body = std::fs::read_to_string(&mh_path)
        .map_err(|_| fail("MERGE_BLOCKED: invalid_merge_head", 1))?;
    let mut commits = Vec::new();
    for line in body.lines() {
        let tok = line.trim();
        if tok.is_empty() {
            continue;
        }
        if tok.starts_with('-') || !is_valid_git_oid_hex(tok) {
            return Err(fail("MERGE_BLOCKED: invalid_merge_head", 1));
        }
        let Some(sha) = rev_parse_commit(repo_root, tok)? else {
            return Err(fail("MERGE_BLOCKED: invalid_merge_head", 1));
        };
        push_unique_str(&mut commits, sha);
    }
    Ok(commits)
}

fn check_policy_staged_in_index(repo_root: &Path) -> Result<bool, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let res = run_git(
        repo_root,
        &["ls-files", "--stage", "--", ".b3/research-policy.json"],
        &no_env,
        None,
    )?;
    if res.exit_code != 0 {
        return Ok(false);
    }
    let out = String::from_utf8_lossy(&res.stdout);
    for line in out.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Some((meta, path)) = trimmed.split_once('\t') else {
            continue;
        };
        if path != ".b3/research-policy.json" {
            continue;
        }
        let parts: Vec<&str> = meta.split_whitespace().collect();
        if parts.len() == 3
            && matches!(parts[0], "100644" | "100755")
            && is_valid_git_oid_hex(parts[1])
            && matches!(parts[2], "0" | "1" | "2" | "3")
        {
            return Ok(true);
        }
    }
    Ok(false)
}

fn show_staged_policy_file(repo_root: &Path) -> Result<Option<String>, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    for spec in [
        ":0:.b3/research-policy.json",
        ":2:.b3/research-policy.json",
        ":3:.b3/research-policy.json",
    ] {
        let res = run_git(repo_root, &["show", spec], &no_env, None)?;
        if res.exit_code == 0 {
            return Ok(Some(String::from_utf8_lossy(&res.stdout).into_owned()));
        }
    }
    Ok(None)
}

#[allow(clippy::too_many_arguments)]
fn load_hook_policy_config(
    repo_root: &Path,
    trunk_sha: &str,
    trunk_has_policy: bool,
    remote_obj_policy_sha: Option<&str>,
    wt_pol_path: Option<&Path>,
    staged_has_policy: bool,
    head_sha: &str,
    head_has_policy: bool,
    first_candidate_policy_sha: Option<&str>,
) -> Result<MergePolicyConfig, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    if trunk_has_policy {
        let Some(a_txt) = show_commit_file(repo_root, trunk_sha, ".b3/research-policy.json")?
        else {
            return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
        };
        let parsed = parse_merge_policy_json_text(&a_txt)?;
        let wt_pol_status = run_git_paths_z(
            repo_root,
            &[
                "status",
                "--porcelain=v1",
                "-z",
                "--",
                ".b3/research-policy.json",
            ],
            GitZMode::Status,
            "MERGE_BLOCKED",
            &no_env,
        )?;
        if !wt_pol_status.is_empty() {
            return Err(fail("MERGE_BLOCKED: policy_modified_in_pr", 1));
        }
        return Ok(parsed);
    }
    if let Some(rem_pol_sha) = remote_obj_policy_sha {
        let Some(r_txt) = show_commit_file(repo_root, rem_pol_sha, ".b3/research-policy.json")?
        else {
            return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
        };
        return parse_merge_policy_json_text(&r_txt);
    }
    if !trunk_sha.is_empty() {
        return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
    }
    let mut commit_pol_sha = None;
    if head_has_policy {
        let wt_pol_status = run_git_paths_z(
            repo_root,
            &[
                "status",
                "--porcelain=v1",
                "-z",
                "--",
                ".b3/research-policy.json",
            ],
            GitZMode::Status,
            "MERGE_BLOCKED",
            &no_env,
        )?;
        if !wt_pol_status.is_empty() {
            return Err(fail("MERGE_BLOCKED: policy_modified_in_pr", 1));
        }
        commit_pol_sha = Some(head_sha);
    }
    let unmerged_pol = if commit_pol_sha.is_some() || first_candidate_policy_sha.is_some() {
        let c_sha = commit_pol_sha
            .or(first_candidate_policy_sha)
            .expect("checked above");
        let Some(c_txt) = show_commit_file(repo_root, c_sha, ".b3/research-policy.json")? else {
            return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
        };
        parse_merge_policy_json_text(&c_txt)?
    } else if let Some(wt_path) = wt_pol_path {
        let wt_txt = std::fs::read_to_string(wt_path)
            .map_err(|_| fail("MERGE_BLOCKED: invalid_policy_json", 1))?;
        parse_merge_policy_json_text(&wt_txt)?
    } else if staged_has_policy {
        let Some(s_txt) = show_staged_policy_file(repo_root)? else {
            return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
        };
        parse_merge_policy_json_text(&s_txt)?
    } else {
        return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
    };
    if unmerged_pol.auto_merge == "authorized" {
        return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
    }
    Ok(unmerged_pol)
}

fn validate_hook_candidate_commit(
    repo_root: &Path,
    policy_base_sha: &str,
    require_policy_blob: bool,
    commit_sha: &str,
    policy_protected_arr: &[String],
    auth_pol: &MergePolicyConfig,
    case_insensitive: bool,
) -> Result<(), B3Error> {
    if commit_sha == policy_base_sha {
        return Ok(());
    }
    if require_policy_blob && !check_policy_blob_in_tree(repo_root, commit_sha)? {
        return Err(fail("MERGE_BLOCKED: policy_modified_in_pr", 1));
    }
    let no_env: [(&str, &str); 0] = [];
    let diff_paths: Vec<String> = if policy_base_sha.is_empty() {
        run_git_paths_z(
            repo_root,
            &[
                "diff-tree",
                "--no-commit-id",
                "--name-only",
                "-r",
                "--root",
                "-z",
                commit_sha,
                "--",
            ],
            GitZMode::Names,
            "MERGE_BLOCKED",
            &no_env,
        )?
    } else {
        diff_against_base_or_tree(repo_root, policy_base_sha, commit_sha)?
    }
    .into_iter()
    .filter(|p| !p.is_empty() && !test_checkpoint_path(p))
    .collect();
    enforce_policy_and_protected_paths(
        &diff_paths,
        if policy_base_sha.is_empty() {
            &[]
        } else {
            policy_protected_arr
        },
        "policy_modified_in_pr",
        &auth_pol.protected_paths,
        auth_pol.allow_protected,
        false,
        case_insensitive,
    )
}

fn resolve_fallback_hook_trunk_authority(
    repo_root: &Path,
    remotes: &[String],
    skip_remote: Option<&str>,
) -> Result<Option<TrunkAuthority>, B3Error> {
    let mut non_policy: Option<TrunkAuthority> = None;
    let has_origin = remotes.iter().any(|r| r == "origin");
    let ordered: Vec<&str> = if has_origin {
        std::iter::once("origin")
            .chain(
                remotes
                    .iter()
                    .map(String::as_str)
                    .filter(|r| *r != "origin"),
            )
            .collect()
    } else {
        remotes.iter().map(String::as_str).collect()
    };

    for rem in ordered {
        if skip_remote == Some(rem) {
            continue;
        }
        if let RemoteTrackingResolution::Trunk(t) =
            resolve_remote_tracking_authority(repo_root, rem)?
        {
            if check_policy_blob_in_tree(repo_root, &t.sha)? {
                return Ok(Some(t));
            }
            if non_policy.is_none() {
                non_policy = Some(t);
            }
        }
    }
    if let Ok(local_t) = get_canonical_trunk_authority(repo_root, false, true) {
        if !local_t.sha.is_empty() && check_policy_blob_in_tree(repo_root, &local_t.sha)? {
            return Ok(Some(local_t));
        }
        if non_policy.is_none() && !local_t.sha.is_empty() {
            non_policy = Some(local_t);
        }
    }
    Ok(non_policy)
}

/// Validates Git `pre-push` (`is_push == true`) or `pre-merge-commit` (`is_push == false`)
/// against canonical trunk authority and `.b3/research-policy.json`.
///
/// Returns `Ok(None)` for clean allow, `Ok(Some(advisory))` for non-blocking advisory
/// warnings emitted to stderr, and `Err(B3Error)` for blocked operations.
pub(crate) fn check_git_hook_operation(
    repo_root_raw: &str,
    is_push: bool,
    git_args: &[String],
    git_stdin: &str,
    ledger_path: &str,
    receipt_path: &str,
) -> Result<Option<String>, B3Error> {
    let repo_root = normalize_repo_root(repo_root_raw)?;
    let no_env: [(&str, &str); 0] = [];
    let remotes = list_remotes(&repo_root)?;
    let wt_pol_path = resolve_default_policy_path(&repo_root)?;
    let wt_has_policy = wt_pol_path.is_some();
    let live_head_sha = rev_parse_commit(&repo_root, "HEAD")?.unwrap_or_default();
    let head_has_policy =
        !live_head_sha.is_empty() && check_policy_blob_in_tree(&repo_root, &live_head_sha)?;
    let policy_protected_arr = vec![".b3/research-policy.json".to_string()];

    if is_push {
        let updates = parse_pre_push_stdin(git_stdin)?;
        if updates.is_empty() {
            if !git_args.is_empty() {
                return Ok(None);
            }
            return Err(fail("MERGE_BLOCKED: missing_pre_push_refs", 1));
        }

        let mut trunk = TrunkAuthority {
            sym_full: String::new(),
            branch: String::new(),
            sha: String::new(),
        };
        let mut unknown_reason: Option<String> = None;
        let mut target_remote_name: Option<String> = None;

        match check_remote_push_destination(&repo_root, &remotes, git_args)? {
            Ok(rem) => {
                target_remote_name = Some(rem.clone());
                match resolve_remote_tracking_authority(&repo_root, &rem)? {
                    RemoteTrackingResolution::Trunk(t) => trunk = t,
                    RemoteTrackingResolution::Unknown(reason) => {
                        unknown_reason = Some(reason);
                        if let Some(fb) =
                            resolve_fallback_hook_trunk_authority(&repo_root, &remotes, Some(&rem))?
                        {
                            if check_policy_blob_in_tree(&repo_root, &fb.sha)? {
                                trunk = fb;
                            }
                        }
                    }
                }
            }
            Err(reason) => {
                unknown_reason = Some(reason);
                if let Some(fb) = resolve_fallback_hook_trunk_authority(&repo_root, &remotes, None)?
                {
                    if check_policy_blob_in_tree(&repo_root, &fb.sha)? {
                        trunk = fb;
                    }
                }
            }
        }

        let trunk_has_policy =
            !trunk.sha.is_empty() && check_policy_blob_in_tree(&repo_root, &trunk.sha)?;

        let mut unfetched_refs: HashSet<String> = HashSet::new();
        let mut stale_tracking_refs: HashSet<String> = HashSet::new();
        let mut remote_obj_policy_sha: Option<String> = None;

        let mut push_commits: Vec<Option<String>> = Vec::with_capacity(updates.len());
        let mut first_candidate_policy_sha: Option<String> = None;
        let mut any_candidate_has_policy = false;

        for upd in &updates {
            if let Some(br) = upd.remote_ref.strip_prefix("refs/heads/") {
                if !is_zero_oid(&upd.remote_oid) {
                    match rev_parse_commit(&repo_root, &upd.remote_oid)? {
                        None => {
                            unfetched_refs.insert(br.to_string());
                        }
                        Some(rem_c_sha) => {
                            if let Some(ref rem_name) = target_remote_name {
                                if let Some(track_sha) = rev_parse_commit(
                                    &repo_root,
                                    &format!("refs/remotes/{rem_name}/{br}"),
                                )? {
                                    if track_sha != rem_c_sha {
                                        stale_tracking_refs.insert(br.to_string());
                                    }
                                }
                            }
                            if !trunk_has_policy
                                && remote_obj_policy_sha.is_none()
                                && check_policy_blob_in_tree(&repo_root, &rem_c_sha)?
                            {
                                remote_obj_policy_sha = Some(rem_c_sha);
                            }
                        }
                    }
                }
            }

            let is_delete = upd.local_ref == "(delete)" || is_zero_oid(&upd.local_oid);
            if is_delete {
                push_commits.push(None);
                continue;
            }
            let c_opt = rev_parse_commit(&repo_root, &upd.local_oid)?;
            if let Some(ref c_sha) = c_opt {
                let has_pol = if c_sha == &live_head_sha {
                    head_has_policy
                } else if c_sha == &trunk.sha {
                    trunk_has_policy
                } else {
                    check_policy_blob_in_tree(&repo_root, c_sha)?
                };
                if has_pol {
                    any_candidate_has_policy = true;
                    if first_candidate_policy_sha.is_none() {
                        first_candidate_policy_sha = Some(c_sha.clone());
                    }
                }
            }
            push_commits.push(c_opt);
        }

        let has_any_local_policy = wt_has_policy || head_has_policy || any_candidate_has_policy;

        let authority = if trunk_has_policy || remote_obj_policy_sha.is_some() {
            HookPolicyAuthority::EstablishedPolicy
        } else if has_any_local_policy {
            if !trunk.sha.is_empty() {
                return Err(fail("MERGE_BLOCKED: policy_not_in_authority", 1));
            }
            HookPolicyAuthority::EstablishedPolicy
        } else if let Some(ref reason) = unknown_reason {
            HookPolicyAuthority::UnknownRemoteAuthority(reason.clone())
        } else {
            HookPolicyAuthority::LocalAbsentOnly
        };

        return match authority {
            HookPolicyAuthority::UnknownRemoteAuthority(reason) => {
                let strict_dest = matches!(
                    reason.as_str(),
                    "direct_url_push"
                        | "push_url_differs_from_fetch_url"
                        | "missing_push_destination"
                );
                let mut saw_branch_push = false;
                for upd in &updates {
                    let is_delete = upd.local_ref == "(delete)" || is_zero_oid(&upd.local_oid);
                    if let Some(br) = upd.remote_ref.strip_prefix("refs/heads/") {
                        if is_delete {
                            if matches!(br, "main" | "master") {
                                return Err(fail(
                                    format!(
                                        "MERGE_BLOCKED: unknown_remote_authority(reason={reason},op=delete,branch={br})"
                                    ),
                                    1,
                                ));
                            }
                        } else {
                            if matches!(br, "main" | "master")
                                && (strict_dest || !is_zero_oid(&upd.remote_oid))
                            {
                                return Err(fail(
                                    format!(
                                        "MERGE_BLOCKED: unknown_remote_authority(reason={reason},branch={br})"
                                    ),
                                    1,
                                ));
                            }
                            saw_branch_push = true;
                        }
                    }
                }
                if saw_branch_push {
                    Ok(Some(format!(
                        "HOOK_ADVISORY: remote_policy_authority=UNKNOWN({reason}); local pre-push cannot verify remote trunk policy — deferring remote governance to canonical merge-policy-check"
                    )))
                } else {
                    Ok(None)
                }
            }
            HookPolicyAuthority::LocalAbsentOnly => {
                for upd in &updates {
                    if let Some(br) = upd.remote_ref.strip_prefix("refs/heads/") {
                        if is_governed_target_branch(br, &trunk.branch, &[])
                            && !is_zero_oid(&upd.remote_oid)
                            && (unfetched_refs.contains(br) || stale_tracking_refs.contains(br))
                        {
                            return Err(fail(
                                format!("MERGE_BLOCKED: stale_remote_target_ref({br})"),
                                1,
                            ));
                        }
                    }
                }
                Ok(None)
            }
            HookPolicyAuthority::EstablishedPolicy => {
                let mp_ci = test_repo_case_insensitive(&repo_root);
                let auth_pol = load_hook_policy_config(
                    &repo_root,
                    &trunk.sha,
                    trunk_has_policy,
                    remote_obj_policy_sha.as_deref(),
                    wt_pol_path.as_deref(),
                    false,
                    &live_head_sha,
                    head_has_policy,
                    first_candidate_policy_sha.as_deref(),
                )?;
                let policy_base_sha = if !trunk.sha.is_empty() {
                    trunk.sha.as_str()
                } else if let Some(ref rem_pol_sha) = remote_obj_policy_sha {
                    rem_pol_sha.as_str()
                } else if head_has_policy {
                    live_head_sha.as_str()
                } else {
                    ""
                };
                let require_pol_blob =
                    trunk_has_policy || remote_obj_policy_sha.is_some() || head_has_policy;

                let mut saw_branch_push = false;
                for (upd, commit_opt) in updates.iter().zip(push_commits) {
                    let is_delete = upd.local_ref == "(delete)" || is_zero_oid(&upd.local_oid);
                    if is_delete {
                        if let Some(br) = upd.remote_ref.strip_prefix("refs/heads/") {
                            if is_governed_target_branch(
                                br,
                                &trunk.branch,
                                &auth_pol.allowed_target_branches,
                            ) {
                                return Err(fail(
                                    format!("MERGE_BLOCKED: protected_target_deletion({br})"),
                                    1,
                                ));
                            }
                        }
                        continue;
                    }

                    if let Some(ref c_sha) = commit_opt {
                        validate_hook_candidate_commit(
                            &repo_root,
                            policy_base_sha,
                            require_pol_blob,
                            c_sha,
                            &policy_protected_arr,
                            &auth_pol,
                            mp_ci,
                        )?;
                    }

                    if let Some(rem_branch) = upd.remote_ref.strip_prefix("refs/heads/") {
                        saw_branch_push = true;
                        if is_governed_target_branch(
                            rem_branch,
                            &trunk.branch,
                            &auth_pol.allowed_target_branches,
                        ) {
                            let Some(c_sha) = commit_opt else {
                                return Err(fail(
                                    "MERGE_BLOCKED: non_commit_push_to_governed_branch",
                                    1,
                                ));
                            };
                            if unfetched_refs.contains(rem_branch)
                                || stale_tracking_refs.contains(rem_branch)
                            {
                                return Err(fail(
                                    format!("MERGE_BLOCKED: stale_remote_target_ref({rem_branch})"),
                                    1,
                                ));
                            }
                            if auth_pol.auto_merge != "authorized" {
                                return Err(fail(
                                    format!(
                                        "PR_READY: direct_push_blocked(branch={rem_branch},auto_merge=disabled)"
                                    ),
                                    2,
                                ));
                            }
                            assert_merge_dirty_worktree_clean(
                                &repo_root,
                                &policy_protected_arr,
                                mp_ci,
                                "policy_modified_in_pr",
                            )?;
                            let remote_base_opt = if is_zero_oid(&upd.remote_oid) {
                                None
                            } else {
                                rev_parse_commit(&repo_root, &upd.remote_oid)?
                            };
                            let base_for_gate =
                                remote_base_opt.unwrap_or_else(|| trunk.sha.clone());
                            verify_hook_target_ledger_and_ci(
                                &repo_root,
                                &base_for_gate,
                                &c_sha,
                                ledger_path,
                                receipt_path,
                                auth_pol.require_ci,
                            )?;
                            if !remotes.is_empty() {
                                return Err(fail(
                                    format!(
                                        "LOCAL_ELIGIBLE_ONLY: remote_pr_verification_required(branch={rem_branch})"
                                    ),
                                    2,
                                ));
                            }
                        }
                    }
                }
                if let (true, Some(reason)) = (saw_branch_push, unknown_reason) {
                    Ok(Some(format!(
                        "HOOK_ADVISORY: remote_policy_authority=UNKNOWN({reason}); validated local policy only — deferring remote governance to canonical merge-policy-check"
                    )))
                } else {
                    Ok(None)
                }
            }
        };
    }

    // pre-merge-commit
    let trunk = resolve_fallback_hook_trunk_authority(&repo_root, &remotes, None)?.unwrap_or(
        TrunkAuthority {
            sym_full: String::new(),
            branch: String::new(),
            sha: String::new(),
        },
    );
    let trunk_has_policy =
        !trunk.sha.is_empty() && check_policy_blob_in_tree(&repo_root, &trunk.sha)?;
    let merge_heads = read_merge_head_commits(&repo_root)?;
    let staged_has_policy = check_policy_staged_in_index(&repo_root)?;

    let mut first_candidate_policy_sha: Option<String> = None;
    let mut any_candidate_has_policy = false;
    for mh in &merge_heads {
        let has_pol = if mh == &trunk.sha {
            trunk_has_policy
        } else if mh == &live_head_sha {
            head_has_policy
        } else {
            check_policy_blob_in_tree(&repo_root, mh)?
        };
        if has_pol {
            any_candidate_has_policy = true;
            if first_candidate_policy_sha.is_none() {
                first_candidate_policy_sha = Some(mh.clone());
            }
        }
    }

    if !trunk_has_policy
        && !wt_has_policy
        && !head_has_policy
        && !any_candidate_has_policy
        && !staged_has_policy
    {
        return Ok(None);
    }

    let mp_ci = test_repo_case_insensitive(&repo_root);
    let auth_pol = load_hook_policy_config(
        &repo_root,
        &trunk.sha,
        trunk_has_policy,
        None,
        wt_pol_path.as_deref(),
        staged_has_policy,
        &live_head_sha,
        head_has_policy,
        first_candidate_policy_sha.as_deref(),
    )?;

    if !live_head_sha.is_empty() {
        validate_hook_candidate_commit(
            &repo_root,
            &trunk.sha,
            trunk_has_policy,
            &live_head_sha,
            &policy_protected_arr,
            &auth_pol,
            mp_ci,
        )?;
    }
    for mh in &merge_heads {
        validate_hook_candidate_commit(
            &repo_root,
            &trunk.sha,
            trunk_has_policy,
            mh,
            &policy_protected_arr,
            &auth_pol,
            mp_ci,
        )?;
    }

    if !trunk.sha.is_empty() {
        if trunk_has_policy && !staged_has_policy {
            return Err(fail("MERGE_BLOCKED: policy_modified_in_pr", 1));
        }
        let staged_diff: Vec<String> = run_git_paths_z(
            &repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "--cached",
                "--name-status",
                "-z",
                &trunk.sha,
                "--",
            ],
            GitZMode::NameStatus,
            "MERGE_BLOCKED",
            &no_env,
        )?
        .into_iter()
        .filter(|p| !p.is_empty() && !test_checkpoint_path(p))
        .collect();
        enforce_policy_and_protected_paths(
            &staged_diff,
            &policy_protected_arr,
            "policy_modified_in_pr",
            &auth_pol.protected_paths,
            auth_pol.allow_protected,
            false,
            mp_ci,
        )?;
    }

    let cur_sym_res = run_git(&repo_root, &["symbolic-ref", "-q", "HEAD"], &no_env, None)?;
    let cur_sym_full = if cur_sym_res.exit_code == 0 {
        String::from_utf8_lossy(&cur_sym_res.stdout)
            .trim()
            .to_string()
    } else {
        String::new()
    };
    let on_governed_target = if let Some(cur_branch) = cur_sym_full.strip_prefix("refs/heads/") {
        is_governed_target_branch(cur_branch, &trunk.branch, &auth_pol.allowed_target_branches)
    } else {
        !live_head_sha.is_empty() && !trunk.sha.is_empty() && live_head_sha == trunk.sha
    };

    if on_governed_target {
        if auth_pol.auto_merge != "authorized" {
            return Err(fail("PR_READY: auto_merge=disabled", 2));
        }
        if !remotes.is_empty() {
            return Err(fail(
                "LOCAL_ELIGIBLE_ONLY: remote_authorization=UNVERIFIED",
                2,
            ));
        }
        if merge_heads.is_empty() {
            return Err(fail("MERGE_BLOCKED: missing_merge_head", 1));
        }
        if merge_heads.len() > 1 {
            return Err(fail("MERGE_BLOCKED: unsupported_octopus_merge", 1));
        }
        let base_for_gate = if !live_head_sha.is_empty() {
            live_head_sha
        } else {
            trunk.sha
        };
        verify_hook_target_ledger_and_ci(
            &repo_root,
            &base_for_gate,
            &merge_heads[0],
            ledger_path,
            receipt_path,
            auth_pol.require_ci,
        )?;
    }

    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_pre_push_stdin_accepts_sha1_sha256_and_delete() {
        let oid40 = "a".repeat(40);
        let oid64 = "b".repeat(64);
        let zero40 = "0".repeat(40);
        let raw = format!(
            "refs/heads/feat/x {oid40} refs/heads/feat/x {zero40}\r\n(delete) {zero40} refs/heads/old {oid64}\n   \n"
        );
        let parsed = parse_pre_push_stdin(&raw).expect("valid pre-push stdin");
        assert_eq!(parsed.len(), 2);
        assert_eq!(
            parsed[0],
            PrePushRefUpdate {
                local_ref: "refs/heads/feat/x".to_string(),
                local_oid: oid40,
                remote_ref: "refs/heads/feat/x".to_string(),
                remote_oid: zero40.clone(),
            }
        );
        assert_eq!(
            parsed[1],
            PrePushRefUpdate {
                local_ref: "(delete)".to_string(),
                local_oid: zero40,
                remote_ref: "refs/heads/old".to_string(),
                remote_oid: oid64,
            }
        );
    }

    #[test]
    fn parse_pre_push_stdin_rejects_malformed_lines_and_control_chars() {
        let oid40 = "a".repeat(40);
        let zero40 = "0".repeat(40);
        for bad in [
            format!("refs/heads/a {oid40} refs/heads/a"),
            format!("refs/heads/a {oid40} refs/heads/a {zero40} extra"),
            format!("refs/heads/a\x00 {oid40} refs/heads/a {zero40}"),
            format!("refs/heads/a\x1b {oid40} refs/heads/a {zero40}"),
            format!("refs/heads/a not-hex refs/heads/a {zero40}"),
            format!("refs/heads/a {} refs/heads/a {zero40}", "a".repeat(39)),
            format!("-refs/heads/a {oid40} refs/heads/a {zero40}"),
            format!("refs/heads/a {oid40} refs/heads/a..b {zero40}"),
        ] {
            let err = parse_pre_push_stdin(&bad).expect_err("should reject malformed stdin");
            assert_eq!(err.code, 1);
            assert_eq!(err.message, "MERGE_BLOCKED: invalid_pre_push_stdin");
        }
    }
}
