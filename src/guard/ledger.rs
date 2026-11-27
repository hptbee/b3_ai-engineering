use std::collections::{HashMap, HashSet};
use std::path::Path;

use crate::error::{fail, B3Error};
use crate::fs::{
    normalize_path_value, normalize_repo_root, resolve_safe_repo_write_path, sort_ordinal,
    split_csv_list, split_csv_list_as_paths, split_path_csv_checked, test_checkpoint_path,
    test_path_match, test_test_path, write_atomic_lf,
};
use crate::git::{
    assert_valid_git_rev, git_err_detail, git_hash_text, is_hex40, resolve_scope_target_and_base,
    run_git,
};
use crate::guard::inventory::{build_inventory, eval_level1_dispatch, is_oversized_unit};
use crate::guard::scope::{
    collect_scope_data, eval_risk_for_subset, get_tshirt_size, normalize_size_class,
    test_contract_path, test_doc_or_asset_path,
};
use crate::guard::snapshot::resolve_or_create_snapshot_sha;
use crate::guard::verify::{
    collect_tree_fingerprint_maps, hash_tree_fingerprint_maps, test_verify_receipt,
    valid_receipt_rel_list, validate_receipt_covers_paths, TreeFingerprintMaps,
    VerifyReceiptResult,
};
use crate::guard::wave::resolve_concurrency;

#[derive(Debug, Clone)]
pub(crate) struct LedgerUnit {
    pub unit_id: String,
    pub group: String,
    pub files_cnt: usize,
    pub lines_cnt: usize,
    pub risk: String,
    pub specialists: String,
    pub rationale: String,
    pub status: String,
    pub findings: String,
    pub verify_receipt: String,
    pub unit_tree_hash: String,
    pub files_csv: String,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub(crate) struct VerifiedReceiptRecord {
    pub unit_id: String,
    pub receipt_path: String,
    pub target_commit_sha: String,
    pub relevant_paths_csv: String,
}

#[derive(Debug, Clone)]
pub(crate) struct ReviewLedger {
    pub meta: HashMap<String, String>,
    pub units: Vec<LedgerUnit>,
    pub verified_receipts: Vec<VerifiedReceiptRecord>,
}

#[derive(Debug, Clone)]
pub(crate) struct LedgerCheckResult {
    pub message: String,
    #[allow(dead_code)]
    pub ledger: ReviewLedger,
}

enum RepoTreeSnapshot {
    WorkingTree(TreeFingerprintMaps),
    Commit(Vec<(String, String)>),
}

impl RepoTreeSnapshot {
    fn build(root: &Path, target_commit_sha: &str, ign_paths: &[String]) -> Result<Self, B3Error> {
        if target_commit_sha.is_empty() {
            let maps = collect_tree_fingerprint_maps(root, &[], ign_paths, "")?;
            return Ok(Self::WorkingTree(maps));
        }
        let no_env: [(&str, &str); 0] = [];
        let ls_res = run_git(
            root,
            &["ls-tree", "-r", "-z", "--full-tree", target_commit_sha],
            &no_env,
            None,
        )?;
        if ls_res.exit_code != 0 {
            let detail = git_err_detail(&ls_res);
            return Err(fail(
                format!("GIT_ERROR: git ls-tree target paths failed: {detail}"),
                1,
            ));
        }
        let mut entries = Vec::new();
        for rec in ls_res.stdout.split(|&b| b == 0) {
            if rec.is_empty() {
                continue;
            }
            let line = std::str::from_utf8(rec)
                .map_err(|_| fail("GIT_ERROR: unsupported_literal_git_path", 1))?;
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            if let Some(tab) = trimmed.find('\t') {
                let p = normalize_path_value(&trimmed[tab + 1..]);
                if !p.is_empty() {
                    entries.push((p, trimmed.to_string()));
                }
            }
        }
        Ok(Self::Commit(entries))
    }

    fn scope_paths_tree_hash(
        &self,
        root: &Path,
        paths_arr: &[String],
        ign_paths: &[String],
    ) -> Result<String, B3Error> {
        let mut clean = Vec::new();
        for p in paths_arr {
            let np = normalize_path_value(p);
            if np.is_empty() || test_checkpoint_path(&np) {
                continue;
            }
            if !ign_paths.is_empty() && test_path_match(&np, ign_paths) {
                continue;
            }
            if !clean.iter().any(|x| x == &np) {
                clean.push(np);
            }
        }
        if clean.is_empty() {
            return Ok("none".to_string());
        }
        let sorted = sort_ordinal(clean, false);
        match self {
            Self::WorkingTree(maps) => {
                hash_tree_fingerprint_maps(root, &sorted.join(","), maps, Some(&sorted))
            }
            Self::Commit(entries) => {
                let lines = entries
                    .iter()
                    .filter(|(p, _)| test_path_match(p, &sorted))
                    .map(|(_, line)| line.clone());
                let manifest = format!(
                    "PATHS={}\n{}\n",
                    sorted.join(","),
                    sort_ordinal(lines, false).join("\n")
                );
                git_hash_text(root, &manifest, "GIT_ERROR", "git ls-tree hash failed")
            }
        }
    }
}

pub(crate) fn get_default_max_passes(size_class: &str, unit_count: usize) -> i64 {
    match normalize_size_class(size_class).unwrap_or("") {
        "L" | "XL" => 12,
        "XXL" => {
            let u = unit_count.max(1) as i64;
            let scaled = ((5 * u + 1) / 2) + 2;
            scaled.max(24)
        }
        _ => 5,
    }
}

pub(crate) fn get_size_rank(size_class: &str) -> i32 {
    match normalize_size_class(size_class).unwrap_or("") {
        "XS" => 0,
        "S" => 1,
        "M" => 2,
        "L" => 3,
        "XL" => 4,
        "XXL" => 5,
        _ => -1,
    }
}

fn test_waiver_attempt(rationale: &str) -> bool {
    let t = rationale.trim();
    t.len() >= 7 && t[..7].eq_ignore_ascii_case("WAIVER:")
}

fn has_explicit_skip_rationale(raw: &str) -> bool {
    let t = raw.trim();
    !t.is_empty() && !t.eq_ignore_ascii_case("none") && !test_waiver_attempt(t)
}

fn serialize_review_ledger(ledger: &ReviewLedger) -> String {
    const KEYS: &[&str] = &[
        "schema",
        "base_sha",
        "head_sha",
        "target_ref",
        "target_sha",
        "snapshot_sha",
        "size_class",
        "normalized_legacy_size",
        "risk_level",
        "risk_signals",
        "recommended_specialists",
        "l1_specialists",
        "l1_skip_rationale",
        "contract_files",
        "generated_files",
        "max_concurrency",
        "max_passes",
        "passes_used",
        "budget_status",
        "review_independence",
        "cross_unit_status",
        "cross_unit_tree_hash",
        "unit_count",
    ];
    let mut out = String::from("# B3 Review Coverage Ledger\n");
    for k in KEYS {
        if let Some(v) = ledger.meta.get(*k) {
            out.push_str(&format!("{k}={v}\n"));
        }
    }
    out.push_str("\n## Units\n");
    out.push_str("| unit_id | group | files_cnt | lines_cnt | risk | specialists | rationale | status | findings | verify_receipt | unit_tree_hash | files_csv |\n");
    out.push_str("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n");
    for u in &ledger.units {
        out.push_str(&format!(
            "| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |\n",
            u.unit_id,
            u.group,
            u.files_cnt,
            u.lines_cnt,
            u.risk,
            u.specialists,
            u.rationale,
            u.status,
            u.findings,
            u.verify_receipt,
            u.unit_tree_hash,
            u.files_csv
        ));
    }
    out
}

fn is_valid_unit_id_str(s: &str) -> bool {
    let Some(rest) = s.strip_prefix('U') else {
        return false;
    };
    rest.len() >= 2 && rest.bytes().all(|b| b.is_ascii_digit())
}

fn parse_review_ledger(full_path: &Path) -> Result<ReviewLedger, B3Error> {
    let raw = std::fs::read_to_string(full_path)
        .map_err(|e| fail(format!("LEDGER_FAIL: failed reading ledger: {e}"), 1))?;
    let mut meta: HashMap<String, String> = HashMap::new();
    let mut units: Vec<LedgerUnit> = Vec::new();

    for raw_ln in raw.lines() {
        let ln = raw_ln.trim();
        if ln.is_empty() || ln.starts_with('#') {
            continue;
        }
        if ln.starts_with('|') {
            let trimmed_bars = ln.trim_matches('|');
            let cols: Vec<&str> = trimmed_bars.split('|').map(|c| c.trim()).collect();
            if cols.len() != 12 {
                return Err(fail("LEDGER_CORRUPT: malformed unit row column count", 1));
            }
            if cols[0] == "unit_id" || cols[0] == "---" {
                continue;
            }
            if !is_valid_unit_id_str(cols[0]) {
                return Err(fail(
                    format!("LEDGER_CORRUPT: invalid unit_id '{}'", cols[0]),
                    1,
                ));
            }
            if cols[2].is_empty()
                || !cols[2].bytes().all(|b| b.is_ascii_digit())
                || cols[3].is_empty()
                || !cols[3].bytes().all(|b| b.is_ascii_digit())
            {
                return Err(fail("LEDGER_CORRUPT: invalid unit row numeric field", 1));
            }
            units.push(LedgerUnit {
                unit_id: cols[0].to_string(),
                group: cols[1].to_string(),
                files_cnt: cols[2]
                    .parse()
                    .map_err(|_| fail("LEDGER_CORRUPT: invalid unit row numeric field", 1))?,
                lines_cnt: cols[3]
                    .parse()
                    .map_err(|_| fail("LEDGER_CORRUPT: invalid unit row numeric field", 1))?,
                risk: cols[4].to_string(),
                specialists: cols[5].to_string(),
                rationale: cols[6].to_string(),
                status: cols[7].to_string(),
                findings: cols[8].to_string(),
                verify_receipt: cols[9].to_string(),
                unit_tree_hash: cols[10].to_string(),
                files_csv: cols[11].to_string(),
            });
            continue;
        }
        if ln.starts_with("pass|") {
            continue;
        }
        let Some(eq) = ln.find('=') else {
            return Err(fail(format!("LEDGER_CORRUPT: unexpected line '{ln}'"), 1));
        };
        if eq < 1 {
            return Err(fail(format!("LEDGER_CORRUPT: unexpected line '{ln}'"), 1));
        }
        let k = ln[..eq].trim().to_string();
        if k == "pass_chain" {
            continue;
        }
        let v = ln[eq + 1..].trim().to_string();
        if meta.contains_key(&k) {
            return Err(fail(format!("LEDGER_CORRUPT: duplicate key '{k}'"), 1));
        }
        meta.insert(k, v);
    }

    for req in [
        "schema",
        "base_sha",
        "head_sha",
        "target_ref",
        "snapshot_sha",
        "size_class",
        "normalized_legacy_size",
        "risk_level",
        "risk_signals",
        "recommended_specialists",
        "contract_files",
        "generated_files",
        "max_concurrency",
        "max_passes",
        "passes_used",
        "budget_status",
        "cross_unit_status",
        "cross_unit_tree_hash",
        "unit_count",
    ] {
        if !meta.get(req).is_some_and(|v| !v.is_empty()) {
            return Err(fail(format!("LEDGER_CORRUPT: missing key '{req}'"), 1));
        }
    }

    if meta["schema"] != "b3-review-ledger-v1" {
        return Err(fail(
            format!("LEDGER_CORRUPT: unsupported schema '{}'", meta["schema"]),
            1,
        ));
    }
    if !is_hex40(&meta["base_sha"]) {
        return Err(fail("LEDGER_CORRUPT: invalid base_sha", 1));
    }
    if !is_hex40(&meta["head_sha"]) {
        return Err(fail("LEDGER_CORRUPT: invalid head_sha", 1));
    }

    if !meta.get("target_sha").is_some_and(|v| !v.is_empty()) {
        let tr = meta["target_ref"].clone();
        if tr == "working_tree" {
            meta.insert("target_sha".to_string(), "none".to_string());
        } else if is_hex40(&tr) {
            meta.insert("target_sha".to_string(), tr);
        } else {
            return Err(fail(
                "LEDGER_CORRUPT: missing target_sha for symbolic target_ref",
                1,
            ));
        }
    }
    if meta["target_ref"] == "working_tree" {
        if meta["target_sha"] != "none" {
            return Err(fail("LEDGER_CORRUPT: invalid target_sha", 1));
        }
    } else if !is_hex40(&meta["target_sha"]) {
        return Err(fail("LEDGER_CORRUPT: invalid target_sha", 1));
    }

    if meta["max_passes"].is_empty()
        || !meta["max_passes"].bytes().all(|b| b.is_ascii_digit())
        || meta["passes_used"].is_empty()
        || !meta["passes_used"].bytes().all(|b| b.is_ascii_digit())
    {
        return Err(fail("LEDGER_CORRUPT: invalid pass counter", 1));
    }

    if !meta
        .get("review_independence")
        .is_some_and(|v| !v.is_empty())
    {
        return Err(fail("LEDGER_CORRUPT: missing review_independence", 1));
    }
    if !matches!(
        meta["review_independence"].as_str(),
        "UNKNOWN" | "INDEPENDENT" | "SINGLE_AGENT_LIMIT"
    ) {
        return Err(fail(
            format!(
                "LEDGER_CORRUPT: invalid review_independence '{}'",
                meta["review_independence"]
            ),
            1,
        ));
    }

    if !meta.get("l1_specialists").is_some_and(|v| !v.is_empty()) {
        meta.insert("l1_specialists".to_string(), "none".to_string());
    }
    if !meta.get("l1_skip_rationale").is_some_and(|v| !v.is_empty()) {
        meta.insert("l1_skip_rationale".to_string(), "none".to_string());
    }
    if normalize_size_class(&meta["size_class"]).is_none() {
        return Err(fail(
            format!(
                "LEDGER_CORRUPT: invalid size_class '{}'",
                meta["size_class"]
            ),
            1,
        ));
    }
    let declared_units = meta["unit_count"].parse::<usize>().unwrap_or(usize::MAX);
    if declared_units != units.len() {
        return Err(fail("LEDGER_CORRUPT: unit_count mismatch", 1));
    }

    Ok(ReviewLedger {
        meta,
        units,
        verified_receipts: Vec::new(),
    })
}

fn normalize_ledger_size_meta(ledger: &mut ReviewLedger) -> Result<(String, String), B3Error> {
    let orig_raw_size = ledger.meta["size_class"].clone();
    let norm_size = normalize_size_class(&orig_raw_size)
        .ok_or_else(|| {
            fail(
                format!("LEDGER_CORRUPT: invalid size_class '{orig_raw_size}'"),
                1,
            )
        })?
        .to_string();
    let legacy_norm_note = if orig_raw_size != norm_size {
        format!("{orig_raw_size}:{norm_size}")
    } else {
        ledger.meta["normalized_legacy_size"].clone()
    };
    ledger
        .meta
        .insert("size_class".to_string(), norm_size.clone());
    ledger
        .meta
        .insert("normalized_legacy_size".to_string(), legacy_norm_note);
    Ok((orig_raw_size, norm_size))
}

fn resolve_ledger_target_commit(root: &Path, target_ref_val: &str) -> Result<String, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let spec = format!("{target_ref_val}^{{commit}}");
    let res = run_git(
        root,
        &["rev-parse", "--verify", "--quiet", &spec],
        &no_env,
        None,
    )?;
    let sha = String::from_utf8_lossy(&res.stdout).trim().to_string();
    if res.exit_code != 0 || !is_hex40(&sha) {
        return Err(fail(
            format!("LEDGER_STALE: target_ref '{target_ref_val}' cannot be resolved"),
            2,
        ));
    }
    Ok(sha)
}

fn contains_unresolved_finding_word(findings: &str) -> bool {
    const TAGS: &[&str] = &["OPEN", "FIXED", "CONFIRMED", "NEW", "INVESTIGATING"];
    let bytes = findings.as_bytes();
    let is_word = |b: u8| b.is_ascii_alphanumeric() || b == b'_';
    let mut i = 0;
    while i < bytes.len() {
        if !is_word(bytes[i]) {
            i += 1;
            continue;
        }
        let start = i;
        while i < bytes.len() && is_word(bytes[i]) {
            i += 1;
        }
        let tok = &findings[start..i];
        if TAGS.contains(&tok) {
            return true;
        }
    }
    false
}

pub(crate) fn invoke_review_ledger_check(
    root: &Path,
    ledger_full: &Path,
    ledger_rel: &str,
    ign_paths: &[String],
) -> Result<LedgerCheckResult, B3Error> {
    if !ledger_full.is_file() {
        return Err(fail(format!("LEDGER_MISSING: {ledger_rel}"), 1));
    }
    let mut ledger = parse_review_ledger(ledger_full)?;
    let (orig_raw_size, norm_size) = normalize_ledger_size_meta(&mut ledger)?;

    let target_ref_val = ledger.meta["target_ref"].clone();
    let target_commit_sha = if target_ref_val != "working_tree" {
        ledger.meta["target_sha"].clone()
    } else {
        String::new()
    };

    let max_p: i64 = ledger.meta["max_passes"].parse().unwrap_or(0);
    let used_p: i64 = ledger.meta["passes_used"].parse().unwrap_or(0);
    if max_p <= 0 {
        return Err(fail(
            format!("LEDGER_INCOMPLETE: unbounded or invalid max_passes ({max_p})"),
            2,
        ));
    }
    if ledger.meta["budget_status"] == "EXHAUSTED" || used_p > max_p {
        return Err(fail(
            format!("LEDGER_INCOMPLETE: budget exhausted (passes={used_p}/{max_p})"),
            2,
        ));
    }
    let reviewed_cnt_chk = ledger
        .units
        .iter()
        .filter(|u| u.status == "REVIEWED")
        .count() as i64;
    let min_req_passes =
        reviewed_cnt_chk + i64::from(ledger.meta["cross_unit_status"] == "REVIEWED");
    if used_p < min_req_passes {
        return Err(fail(
            format!(
                "LEDGER_INCOMPLETE: passes_used ({used_p}) below minimum reviewed passes ({min_req_passes})"
            ),
            2,
        ));
    }
    if matches!(norm_size.as_str(), "L" | "XL") && ledger.units.len() > 4 {
        return Err(fail(
            format!(
                "LEDGER_INCOMPLETE: {norm_size} PR exceeds max 4 units ({})",
                ledger.units.len()
            ),
            2,
        ));
    }
    for u in &ledger.units {
        if is_oversized_unit(u.files_cnt, u.lines_cnt) {
            return Err(fail(
                format!(
                    "LEDGER_INCOMPLETE: oversized unit {} ({}f, {}L)",
                    u.unit_id, u.files_cnt, u.lines_cnt
                ),
                2,
            ));
        }
    }

    if target_ref_val != "working_tree" {
        let sha = resolve_ledger_target_commit(root, &target_ref_val)?;
        if sha != target_commit_sha {
            return Err(fail(
                format!("LEDGER_STALE: target_ref '{target_ref_val}' moved ({target_commit_sha}->{sha})"),
                2,
            ));
        }
        if ledger.meta["head_sha"] != sha {
            return Err(fail(
                format!(
                    "LEDGER_STALE: head_sha moved ({}->{sha})",
                    ledger.meta["head_sha"]
                ),
                2,
            ));
        }
    } else {
        let no_env: [(&str, &str); 0] = [];
        let res = run_git(
            root,
            &["rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
            &no_env,
            None,
        )?;
        let sha = String::from_utf8_lossy(&res.stdout).trim().to_string();
        if res.exit_code != 0 || !is_hex40(&sha) {
            return Err(fail("LEDGER_STALE: HEAD cannot be resolved", 2));
        }
        if sha != ledger.meta["head_sha"] {
            return Err(fail(
                format!(
                    "LEDGER_STALE: head_sha moved ({}->{sha})",
                    ledger.meta["head_sha"]
                ),
                2,
            ));
        }
    }

    let live_scope = collect_scope_data(
        root,
        &ledger.meta["base_sha"],
        &target_commit_sha,
        ign_paths,
        "LEDGER_FAIL",
    )?;
    if live_scope.review_files.is_empty() && live_scope.noise_files.is_empty() {
        return Err(fail("LEDGER_INCOMPLETE: empty diff target", 2));
    }

    let live_size = get_tshirt_size(live_scope.review_files.len(), live_scope.total_lines);
    if get_size_rank(live_size) > get_size_rank(&norm_size) {
        return Err(fail(
            format!("LEDGER_STALE: size_class escalated ({norm_size}->{live_size})"),
            2,
        ));
    }

    let risk_eval_paths = if !live_scope.review_files.is_empty() {
        &live_scope.review_files
    } else {
        &live_scope.noise_files
    };
    let live_overall_risk = eval_risk_for_subset(
        risk_eval_paths,
        Some(&live_scope.file_signals),
        Some(&live_scope.file_lines),
    );
    let rev_indep = ledger.meta["review_independence"].clone();
    if rev_indep == "SINGLE_AGENT_LIMIT"
        && matches!(live_overall_risk.risk_level, "HIGH" | "CRITICAL")
    {
        return Err(fail(
            "LEDGER_INCOMPLETE: single_agent_limit_blocks_high_risk",
            2,
        ));
    }
    if rev_indep == "UNKNOWN" && matches!(live_overall_risk.risk_level, "HIGH" | "CRITICAL") {
        return Err(fail(
            "LEDGER_INCOMPLETE: review_independence_unknown_blocks_high_risk",
            2,
        ));
    }

    let mut assigned_set = HashSet::new();
    for u in &ledger.units {
        for uf in split_csv_list_as_paths(&u.files_csv) {
            assigned_set.insert(uf);
        }
    }
    let uncovered = sort_ordinal(
        live_scope
            .review_files
            .iter()
            .filter(|f| !assigned_set.contains(f.as_str()))
            .cloned(),
        false,
    );
    if !uncovered.is_empty() {
        return Err(fail(
            format!(
                "LEDGER_INCOMPLETE: uncovered files ({})",
                uncovered.join(",")
            ),
            2,
        ));
    }

    let live_contracts: Vec<String> = live_scope
        .review_files
        .iter()
        .filter(|f| test_contract_path(f))
        .cloned()
        .collect();
    let unit_count = ledger.units.len();
    let mut verified_receipts = Vec::new();
    let mut receipt_cache: HashMap<String, VerifyReceiptResult> = HashMap::new();
    let tree_snap = RepoTreeSnapshot::build(root, &target_commit_sha, ign_paths)?;

    for u in &ledger.units {
        let uid = &u.unit_id;
        if u.status == "BLOCKED" {
            return Err(fail(format!("LEDGER_BLOCKED: unit {uid}"), 2));
        }
        if u.status == "STALE" {
            return Err(fail(format!("LEDGER_STALE: unit {uid}"), 2));
        }
        if u.status != "REVIEWED" {
            return Err(fail(
                format!("LEDGER_INCOMPLETE: unit {uid} status={}", u.status),
                2,
            ));
        }
        if contains_unresolved_finding_word(&u.findings) {
            return Err(fail(
                format!(
                    "LEDGER_INCOMPLETE: unresolved findings in {uid} ({})",
                    u.findings
                ),
                2,
            ));
        }

        let u_files = split_csv_list_as_paths(&u.files_csv);
        let live_u_risk = eval_risk_for_subset(
            &u_files,
            Some(&live_scope.file_signals),
            Some(&live_scope.file_lines),
        );
        if rev_indep == "SINGLE_AGENT_LIMIT"
            && matches!(live_u_risk.risk_level, "HIGH" | "CRITICAL")
        {
            return Err(fail(
                "LEDGER_INCOMPLETE: single_agent_limit_blocks_high_risk",
                2,
            ));
        }
        if rev_indep == "UNKNOWN" && matches!(live_u_risk.risk_level, "HIGH" | "CRITICAL") {
            return Err(fail(
                "LEDGER_INCOMPLETE: review_independence_unknown_blocks_high_risk",
                2,
            ));
        }
        if live_u_risk.risk_level != u.risk {
            return Err(fail(
                format!(
                    "LEDGER_STALE: unit {uid} risk changed ({}->{})",
                    u.risk, live_u_risk.risk_level
                ),
                2,
            ));
        }
        if live_u_risk.recommended_specialists != "none" {
            let rec_sp = split_csv_list(&u.specialists);
            let missing_sp: Vec<String> = split_csv_list(&live_u_risk.recommended_specialists)
                .into_iter()
                .filter(|sp| !rec_sp.iter().any(|r| r == sp))
                .collect();
            if !missing_sp.is_empty() {
                let missing_csv = missing_sp.join(",");
                if live_u_risk.risk_level == "CRITICAL" {
                    if test_waiver_attempt(&u.rationale) {
                        return Err(fail(
                            format!("LEDGER_BLOCKED: unverified CRITICAL specialist waiver rejected on {uid} (missing {missing_csv}; self-declared waivers are disabled without trusted owner approval)"),
                            2,
                        ));
                    }
                    return Err(fail(
                        format!("LEDGER_INCOMPLETE: mandatory CRITICAL specialist ({missing_csv}) required on {uid} (waivers disabled without trusted owner approval)"),
                        2,
                    ));
                } else if !has_explicit_skip_rationale(&u.rationale) {
                    let msg = if live_u_risk.risk_level == "HIGH" {
                        format!("LEDGER_INCOMPLETE: missing specialist ({missing_csv}) or valid HIGH skip rationale on {uid}")
                    } else {
                        format!("LEDGER_INCOMPLETE: missing specialist ({missing_csv}) or rationale on {uid}")
                    };
                    return Err(fail(msg, 2));
                }
            }
        }

        let mut scope_paths = u_files.clone();
        scope_paths.extend(live_contracts.iter().cloned());
        let cur_u_hash = tree_snap.scope_paths_tree_hash(root, &scope_paths, ign_paths)?;
        if cur_u_hash != u.unit_tree_hash {
            return Err(fail(
                format!("LEDGER_STALE: unit {uid} invalidated (files or shared contracts changed)"),
                2,
            ));
        }

        let live_u_files = u_files.len();
        let live_u_lines: usize = u_files
            .iter()
            .filter_map(|f| live_scope.file_lines.get(f))
            .sum();
        if is_oversized_unit(live_u_files, live_u_lines) {
            return Err(fail(
                format!(
                    "LEDGER_INCOMPLETE: oversized unit {uid} ({live_u_files}f, {live_u_lines}L)"
                ),
                2,
            ));
        }

        let has_code_file = u_files
            .iter()
            .any(|f| !(test_doc_or_asset_path(f) || test_test_path(f)));
        if u.verify_receipt == "none" {
            if has_code_file && matches!(u.risk.as_str(), "HIGH" | "CRITICAL") {
                return Err(fail(
                    format!(
                        "LEDGER_INCOMPLETE: missing verify_receipt for {} unit {uid}",
                        u.risk
                    ),
                    2,
                ));
            }
        } else {
            let vr = receipt_cache
                .entry(u.verify_receipt.clone())
                .or_insert_with(|| {
                    test_verify_receipt(
                        root,
                        &u.verify_receipt,
                        ign_paths,
                        "",
                        "",
                        &target_commit_sha,
                    )
                });
            if vr.code == 2 {
                return Err(fail(
                    format!("LEDGER_STALE: unit {uid} receipt invalid ({})", vr.message),
                    2,
                ));
            }
            if vr.code != 0 {
                return Err(fail(
                    format!(
                        "LEDGER_INCOMPLETE: unit {uid} receipt invalid ({})",
                        vr.message
                    ),
                    2,
                ));
            }
            let Some(valid_unit_files) = valid_receipt_rel_list(&u.files_csv) else {
                return Err(fail(
                    format!(
                        "LEDGER_INCOMPLETE: unit {uid} receipt invalid (VERIFY_CHECK_FAIL: invalid relevant_paths)"
                    ),
                    2,
                ));
            };
            if let Some(uncovered) =
                validate_receipt_covers_paths(&vr.relevant_paths_csv, &valid_unit_files)
            {
                return Err(fail(
                    format!(
                        "LEDGER_INCOMPLETE: unit {uid} receipt invalid (VERIFY_SCOPE_MISMATCH: uncovered path ({}))",
                        uncovered.join(",")
                    ),
                    2,
                ));
            }
            if !target_commit_sha.is_empty() {
                verified_receipts.push(VerifiedReceiptRecord {
                    unit_id: uid.clone(),
                    receipt_path: u.verify_receipt.clone(),
                    target_commit_sha: target_commit_sha.clone(),
                    relevant_paths_csv: vr.relevant_paths_csv.clone(),
                });
            }
        }
    }
    ledger.verified_receipts = verified_receipts;

    let cu_status = ledger.meta["cross_unit_status"].clone();
    if matches!(norm_size.as_str(), "L" | "XL" | "XXL") && unit_count > 1 {
        if cu_status == "BLOCKED" {
            return Err(fail("LEDGER_BLOCKED: cross_unit blocked", 2));
        }
        if cu_status == "STALE" {
            return Err(fail("LEDGER_STALE: cross_unit stale", 2));
        }
        if cu_status != "REVIEWED" {
            return Err(fail(
                format!("LEDGER_INCOMPLETE: cross_unit_status={cu_status}"),
                2,
            ));
        }
        let cu_paths = if !live_contracts.is_empty() {
            &live_contracts
        } else {
            &live_scope.review_files
        };
        let cur_cu_hash = tree_snap.scope_paths_tree_hash(root, cu_paths, ign_paths)?;
        if cur_cu_hash != ledger.meta["cross_unit_tree_hash"] {
            return Err(fail("LEDGER_STALE: cross_unit invalidated", 2));
        }
    }

    let norm_tag = if orig_raw_size != norm_size {
        format!(" normalized_from={orig_raw_size}")
    } else {
        String::new()
    };
    let message = format!(
        "LEDGER_GATE_PASS: size={norm_size} risk={} units={unit_count}/{unit_count} cross_unit={cu_status} review_independence={rev_indep}{norm_tag}",
        ledger.meta["risk_level"]
    );
    Ok(LedgerCheckResult { message, ledger })
}

fn normalize_ledger_text(raw: &str) -> (String, usize) {
    let mut changes = 0usize;
    let mut lines: Vec<String> = Vec::new();
    let mut has_schema = false;
    let mut has_ri = false;

    for raw_line in raw.lines() {
        let ln = raw_line.strip_suffix('\r').unwrap_or(raw_line);
        if ln == "schema=b3-review-ledger-v1" {
            has_schema = true;
        }
        if ln.starts_with("review_independence=") {
            has_ri = true;
        }
        lines.push(rewrite_legacy_size_line(ln, &mut changes));
    }

    let mut out_lines = Vec::with_capacity(lines.len() + 1);
    let mut inserted = false;
    for ln in lines {
        let is_budget = ln.starts_with("budget_status=");
        out_lines.push(ln);
        if has_schema && !has_ri && !inserted && is_budget {
            out_lines.push("review_independence=UNKNOWN".to_string());
            changes += 1;
            inserted = true;
        }
    }

    let mut out = out_lines.join("\n");
    if raw.ends_with('\n') || !out.is_empty() {
        out.push('\n');
    }
    (out, changes)
}

fn rewrite_legacy_size_line(ln: &str, changes: &mut usize) -> String {
    let bytes = ln.as_bytes();
    let mut pos = 0usize;
    if pos < bytes.len() && bytes[pos] == b'-' {
        pos += 1;
    }
    while pos < bytes.len() && (bytes[pos] == b' ' || bytes[pos] == b'\t') {
        pos += 1;
    }
    if ln.len() < pos + 10 || !ln[pos..pos + 10].eq_ignore_ascii_case("size_class") {
        return ln.to_string();
    }
    pos += 10;
    while pos < bytes.len() && (bytes[pos] == b' ' || bytes[pos] == b'\t') {
        pos += 1;
    }
    if pos >= bytes.len() || (bytes[pos] != b':' && bytes[pos] != b'=') {
        return ln.to_string();
    }
    pos += 1;
    while pos < bytes.len() && (bytes[pos] == b' ' || bytes[pos] == b'\t') {
        pos += 1;
    }
    let val_start = pos;
    while pos < bytes.len() && (bytes[pos].is_ascii_alphanumeric() || bytes[pos] == b'_') {
        pos += 1;
    }
    let tok = &ln[val_start..pos];
    let rep = match tok.to_ascii_uppercase().as_str() {
        "SMALL" => Some("S"),
        "MEDIUM" => Some("M"),
        "LARGE" => Some("L"),
        "VERY_LARGE" => Some("XL"),
        _ => None,
    };
    if let Some(new_sz) = rep {
        *changes += 1;
        format!("{}{new_sz}{}", &ln[..val_start], &ln[pos..])
    } else {
        ln.to_string()
    }
}

/// Executes `b3 guard review-ledger`.
#[allow(clippy::too_many_arguments)]
pub fn run(
    repo_root_raw: &str,
    action: &str,
    ledger_path: &str,
    base_sha_raw: &str,
    target_ref_raw: &str,
    ignore_dirty_paths: &str,
    max_concurrency: i32,
    max_passes: Option<i64>,
    unit_id: &str,
    status: &str,
    findings: &str,
    specialists: &str,
    rationale: &str,
    receipt_path: &str,
    cross_unit_status: &str,
    budget_status: &str,
    review_independence: &str,
    passes_used: Option<i64>,
    scope: &str,
    force: bool,
) -> Result<(String, i32), B3Error> {
    let act = action.trim().to_ascii_lowercase();
    if !matches!(act.as_str(), "init" | "update" | "normalize" | "check") {
        return Err(fail(
            "LEDGER_FAIL: -Action must be init, update, normalize, or check",
            1,
        ));
    }
    let max_concurrency = resolve_concurrency(max_concurrency, "LEDGER_FAIL")?;

    if act == "normalize" && ledger_path.trim().is_empty() {
        if scope.trim().is_empty() {
            return Err(fail(
                "LEDGER_FAIL: -LedgerPath or -Scope required for normalize",
                1,
            ));
        }
        let norm = normalize_size_class(scope)
            .ok_or_else(|| fail(format!("LEDGER_FAIL: unknown size class '{scope}'"), 1))?;
        return Ok((norm.to_string(), 0));
    }

    let repo_root = normalize_repo_root(repo_root_raw)?;
    let Some((ledger_full, ledger_rel)) = resolve_safe_repo_write_path(&repo_root, ledger_path)
    else {
        return Err(fail("LEDGER_FAIL: invalid -LedgerPath", 1));
    };
    let ignored = split_path_csv_checked(ignore_dirty_paths, "LEDGER_FAIL", true, None)?;

    if act == "normalize" {
        if !ledger_full.is_file() {
            return Err(fail(format!("LEDGER_MISSING: {ledger_rel}"), 1));
        }
        let orig = std::fs::read_to_string(&ledger_full)
            .map_err(|e| fail(format!("LEDGER_FAIL: failed reading ledger: {e}"), 1))?;
        let (updated, changes) = normalize_ledger_text(&orig);
        if changes > 0 {
            write_atomic_lf(&ledger_full, &updated)?;
        }
        return Ok((
            format!("LEDGER_NORMALIZED: path={ledger_rel} changes={changes}"),
            0,
        ));
    }

    if act == "init" {
        if ledger_full.is_dir() {
            return Err(fail("LEDGER_FAIL: -LedgerPath is a directory", 1));
        }
        if let Some(mp) = max_passes {
            if mp <= 0 {
                return Err(fail(
                    "LEDGER_FAIL: -MaxPasses must be a positive integer",
                    1,
                ));
            }
        }
        let ri_init = if !review_independence.trim().is_empty() {
            review_independence.trim().to_ascii_uppercase()
        } else {
            "UNKNOWN".to_string()
        };
        if !matches!(
            ri_init.as_str(),
            "UNKNOWN" | "INDEPENDENT" | "SINGLE_AGENT_LIMIT"
        ) {
            return Err(fail(
                format!("LEDGER_FAIL: invalid -ReviewIndependence '{ri_init}'"),
                1,
            ));
        }

        let scope_res = resolve_scope_target_and_base(
            &repo_root,
            target_ref_raw,
            base_sha_raw,
            &ignored,
            "LEDGER_FAIL",
            "commit",
        )?;
        let target_trim = scope_res.target_ref;
        let target_commit_sha = scope_res.target_commit_sha;
        let resolved_base = scope_res.base_sha;
        let head_sha = if !target_commit_sha.is_empty() {
            target_commit_sha.clone()
        } else {
            assert_valid_git_rev(&repo_root, "HEAD", "commit", "LEDGER_FAIL", "HEAD")?
        };

        if !force && ledger_full.is_file() {
            let Ok(existing_led) = parse_review_ledger(&ledger_full) else {
                return Err(fail(
                    format!("LEDGER_CORRUPT: cannot overwrite corrupt ledger '{ledger_rel}' without --force"),
                    1,
                ));
            };
            if existing_led.meta["base_sha"] == resolved_base {
                let p_used: i64 = existing_led.meta["passes_used"].parse().unwrap_or(0);
                if p_used > 0
                    || existing_led.meta["budget_status"] == "EXHAUSTED"
                    || existing_led.meta["review_independence"] == "SINGLE_AGENT_LIMIT"
                {
                    return Err(fail(
                        format!("LEDGER_FAIL: cannot reset active ledger '{ledger_rel}' on same base_sha without --force"),
                        1,
                    ));
                }
            }
        }

        let inv = build_inventory(
            &repo_root,
            &resolved_base,
            &target_commit_sha,
            &ignored,
            max_concurrency,
            "LEDGER_FAIL",
        )?;
        if inv.is_empty {
            return Err(fail("LEDGER_FAIL: EMPTY_DIFF", 2));
        }
        if let Some(pe) = inv.partition_error {
            return Err(fail(pe, 2));
        }
        let effective_max_passes =
            max_passes.unwrap_or_else(|| get_default_max_passes(inv.size_class, inv.units.len()));

        let snap_sha = if !target_commit_sha.is_empty() {
            target_commit_sha.clone()
        } else {
            resolve_or_create_snapshot_sha(&repo_root, "LEDGER_FAIL")?
        };

        let tree_snap = RepoTreeSnapshot::build(&repo_root, &target_commit_sha, &ignored)?;
        let mut unit_rows = Vec::with_capacity(inv.units.len());
        for u in &inv.units {
            let mut fp_paths = u.files.clone();
            fp_paths.extend(inv.contract_files.iter().cloned());
            let u_hash = tree_snap.scope_paths_tree_hash(&repo_root, &fp_paths, &ignored)?;
            unit_rows.push(LedgerUnit {
                unit_id: u.unit_id.clone(),
                group: u.group.clone(),
                files_cnt: u.files_cnt,
                lines_cnt: u.lines_cnt,
                risk: u.risk.to_string(),
                specialists: "none".to_string(),
                rationale: "none".to_string(),
                status: "PENDING".to_string(),
                findings: "none".to_string(),
                verify_receipt: "none".to_string(),
                unit_tree_hash: u_hash,
                files_csv: u.files_csv.clone(),
            });
        }

        let need_cross = matches!(inv.size_class, "L" | "XL" | "XXL") && unit_rows.len() > 1;
        let cross_status = if need_cross { "PENDING" } else { "N_A" };
        let cross_hash = if need_cross {
            let cross_paths = if !inv.contract_files.is_empty() {
                &inv.contract_files
            } else {
                &inv.review_files
            };
            tree_snap.scope_paths_tree_hash(&repo_root, cross_paths, &ignored)?
        } else {
            "none".to_string()
        };

        let mut meta = HashMap::new();
        meta.insert("schema".to_string(), "b3-review-ledger-v1".to_string());
        meta.insert("base_sha".to_string(), resolved_base);
        meta.insert("head_sha".to_string(), head_sha);
        meta.insert(
            "target_ref".to_string(),
            if target_trim.is_empty() {
                "working_tree".to_string()
            } else {
                target_trim
            },
        );
        meta.insert(
            "target_sha".to_string(),
            if target_commit_sha.is_empty() {
                "none".to_string()
            } else {
                target_commit_sha
            },
        );
        meta.insert("snapshot_sha".to_string(), snap_sha.clone());
        meta.insert("size_class".to_string(), inv.size_class.to_string());
        meta.insert("normalized_legacy_size".to_string(), "none".to_string());
        meta.insert("risk_level".to_string(), inv.risk_level.to_string());
        meta.insert("risk_signals".to_string(), inv.risk_signals);
        meta.insert(
            "recommended_specialists".to_string(),
            inv.recommended_specialists,
        );
        meta.insert("l1_specialists".to_string(), inv.l1_specialists);
        meta.insert(
            "l1_skip_rationale".to_string(),
            inv.l1_skip_rationale.to_string(),
        );
        meta.insert(
            "contract_files".to_string(),
            if inv.contract_files.is_empty() {
                "none".to_string()
            } else {
                inv.contract_files.join(",")
            },
        );
        meta.insert(
            "generated_files".to_string(),
            if inv.generated_files.is_empty() {
                "none".to_string()
            } else {
                inv.generated_files.join(",")
            },
        );
        meta.insert(
            "max_concurrency".to_string(),
            inv.max_concurrency.to_string(),
        );
        meta.insert("max_passes".to_string(), effective_max_passes.to_string());
        meta.insert("passes_used".to_string(), "0".to_string());
        meta.insert("budget_status".to_string(), "OK".to_string());
        meta.insert("review_independence".to_string(), ri_init);
        meta.insert("cross_unit_status".to_string(), cross_status.to_string());
        meta.insert("cross_unit_tree_hash".to_string(), cross_hash);
        meta.insert("unit_count".to_string(), unit_rows.len().to_string());

        let ledger = ReviewLedger {
            meta,
            units: unit_rows,
            verified_receipts: Vec::new(),
        };
        write_atomic_lf(&ledger_full, &serialize_review_ledger(&ledger))?;
        return Ok((
            format!(
                "LEDGER_INIT: path={ledger_rel} size={} risk={} units={} max_passes={effective_max_passes} snapshot={snap_sha}",
                inv.size_class,
                inv.risk_level,
                ledger.units.len()
            ),
            0,
        ));
    }

    if !ledger_full.is_file() {
        return Err(fail(format!("LEDGER_MISSING: {ledger_rel}"), 1));
    }

    if act == "update" {
        let mut ledger = parse_review_ledger(&ledger_full)?;
        let _ = normalize_ledger_size_meta(&mut ledger)?;

        let cur_max_passes: i64 = ledger.meta["max_passes"].parse().unwrap_or(0);
        if let Some(mp) = max_passes {
            if mp <= 0 {
                return Err(fail(
                    "LEDGER_FAIL: -MaxPasses must be a positive integer",
                    1,
                ));
            }
            if mp > cur_max_passes {
                return Err(fail(
                    format!("LEDGER_CORRUPT: cannot raise max_passes ({cur_max_passes}->{mp})"),
                    1,
                ));
            }
        }
        if let Some(pu) = passes_used {
            if pu < 0 {
                return Err(fail("LEDGER_FAIL: -PassesUsed must be non-negative", 1));
            }
        }

        let orig_head_sha = ledger.meta["head_sha"].clone();
        let ri_explicit = !review_independence.trim().is_empty();
        if ri_explicit {
            let ri_upd = review_independence.trim().to_ascii_uppercase();
            if !matches!(
                ri_upd.as_str(),
                "UNKNOWN" | "INDEPENDENT" | "SINGLE_AGENT_LIMIT"
            ) {
                return Err(fail(
                    format!("LEDGER_FAIL: invalid -ReviewIndependence '{ri_upd}'"),
                    1,
                ));
            }
            if ledger.meta["review_independence"] == "SINGLE_AGENT_LIMIT" && ri_upd == "INDEPENDENT"
            {
                return Err(fail(
                    "LEDGER_FAIL: cannot upgrade SINGLE_AGENT_LIMIT to INDEPENDENT",
                    1,
                ));
            }
            if ledger.meta["review_independence"] == "SINGLE_AGENT_LIMIT" && ri_upd == "UNKNOWN" {
                return Err(fail("LEDGER_FAIL: cannot clear SINGLE_AGENT_LIMIT", 1));
            }
            ledger
                .meta
                .insert("review_independence".to_string(), ri_upd);
        }

        let target_ref_val = ledger.meta["target_ref"].clone();
        let mut target_commit_sha = if target_ref_val != "working_tree" {
            ledger.meta["target_sha"].clone()
        } else {
            String::new()
        };

        let mut found_idx: Option<usize> = None;
        let mut st_val = String::new();
        let mut added_new_spec = false;
        let cu_val = if !cross_unit_status.trim().is_empty() {
            cross_unit_status.trim().to_ascii_uppercase()
        } else {
            String::new()
        };

        let target_u = unit_id.trim();
        if !target_u.is_empty() {
            found_idx = ledger.units.iter().position(|u| u.unit_id == target_u);
            let Some(idx) = found_idx else {
                return Err(fail(
                    format!("LEDGER_FAIL: unknown -UnitId '{target_u}'"),
                    1,
                ));
            };
            let u = &mut ledger.units[idx];

            if !status.trim().is_empty() {
                st_val = status.trim().to_ascii_uppercase();
                if !matches!(
                    st_val.as_str(),
                    "PENDING" | "IN_PROGRESS" | "REVIEWED" | "INCOMPLETE" | "STALE" | "BLOCKED"
                ) {
                    return Err(fail(
                        format!("LEDGER_FAIL: invalid unit -Status '{st_val}'"),
                        1,
                    ));
                }
                u.status = st_val.clone();
            }
            if !findings.trim().is_empty() {
                u.findings = replace_run_chars(findings.trim(), &['\r', '\n', '|'], ";");
            }
            if !specialists.trim().is_empty() {
                let old_sp_list: Vec<&str> = u
                    .specialists
                    .split(',')
                    .filter(|s| !s.is_empty() && *s != "none")
                    .collect();
                let sp_arr: Vec<String> = split_csv_list(specialists)
                    .into_iter()
                    .map(|item| replace_run_chars(item.trim(), &['\r', '\n', '|'], ""))
                    .filter(|s| !s.is_empty())
                    .collect();
                if sp_arr
                    .iter()
                    .any(|ns_item| !old_sp_list.contains(&ns_item.as_str()))
                {
                    added_new_spec = true;
                }
                u.specialists = if sp_arr.is_empty() {
                    "none".to_string()
                } else {
                    sort_ordinal(sp_arr, false).join(",")
                };
            }
            if !rationale.trim().is_empty() {
                u.rationale = replace_run_chars(rationale.trim(), &['\r', '\n', '|'], " ");
            }
            if !receipt_path.trim().is_empty() {
                if receipt_path.trim() == "none" {
                    u.verify_receipt = "none".to_string();
                } else {
                    let Some((_, r_rel)) = resolve_safe_repo_write_path(&repo_root, receipt_path)
                    else {
                        return Err(fail("LEDGER_FAIL: invalid -ReceiptPath", 1));
                    };
                    u.verify_receipt = r_rel;
                }
            }
        }

        let mut live_scope_upd = None;
        let mut live_contracts_upd: Vec<String> = Vec::new();
        if (found_idx.is_some() && st_val == "REVIEWED") || cu_val == "REVIEWED" {
            if target_ref_val != "working_tree" {
                let tr_sha = resolve_ledger_target_commit(&repo_root, &target_ref_val)?;
                target_commit_sha = tr_sha.clone();
                ledger.meta.insert("target_sha".to_string(), tr_sha.clone());
                ledger.meta.insert("head_sha".to_string(), tr_sha.clone());
                ledger.meta.insert("snapshot_sha".to_string(), tr_sha);
            }
            let base_sha = ledger.meta["base_sha"].clone();
            let ls = collect_scope_data(
                &repo_root,
                &base_sha,
                &target_commit_sha,
                &ignored,
                "LEDGER_FAIL",
            )?;
            let contracts: Vec<String> = ls
                .review_files
                .iter()
                .filter(|f| test_contract_path(f))
                .cloned()
                .collect();
            ledger.meta.insert(
                "contract_files".to_string(),
                if contracts.is_empty() {
                    "none".to_string()
                } else {
                    contracts.join(",")
                },
            );
            if !ls.review_files.is_empty() {
                let overall = eval_risk_for_subset(
                    &ls.review_files,
                    Some(&ls.file_signals),
                    Some(&ls.file_lines),
                );
                let (l1_sp, l1_skip) = eval_level1_dispatch(
                    &contracts,
                    &overall.recommended_specialists,
                    overall.risk_level,
                    &ls.review_files,
                );
                ledger
                    .meta
                    .insert("risk_level".to_string(), overall.risk_level.to_string());
                ledger
                    .meta
                    .insert("risk_signals".to_string(), overall.risk_signals);
                ledger.meta.insert(
                    "recommended_specialists".to_string(),
                    overall.recommended_specialists,
                );
                ledger.meta.insert("l1_specialists".to_string(), l1_sp);
                ledger
                    .meta
                    .insert("l1_skip_rationale".to_string(), l1_skip.to_string());
            }
            live_contracts_upd = contracts;
            live_scope_upd = Some(ls);
        }

        let need_unit_hash = found_idx.is_some() && st_val == "REVIEWED";
        let need_cu_hash = cu_val == "REVIEWED";
        let upd_tree_snap = if need_unit_hash || need_cu_hash {
            Some(RepoTreeSnapshot::build(
                &repo_root,
                &target_commit_sha,
                &ignored,
            )?)
        } else {
            None
        };

        if let Some(idx) = found_idx {
            if st_val == "REVIEWED" {
                let ls = live_scope_upd
                    .as_ref()
                    .expect("live_scope_upd populated when st_val == REVIEWED");
                let u_files = split_csv_list_as_paths(&ledger.units[idx].files_csv);
                let live_u_lines: usize = u_files.iter().filter_map(|f| ls.file_lines.get(f)).sum();
                let live_u_risk =
                    eval_risk_for_subset(&u_files, Some(&ls.file_signals), Some(&ls.file_lines));
                let mut hash_paths = u_files.clone();
                hash_paths.extend(live_contracts_upd.iter().cloned());
                let u_hash = upd_tree_snap
                    .as_ref()
                    .expect("upd_tree_snap populated")
                    .scope_paths_tree_hash(&repo_root, &hash_paths, &ignored)?;
                let head_now = if !target_commit_sha.is_empty() {
                    target_commit_sha.clone()
                } else {
                    assert_valid_git_rev(&repo_root, "HEAD", "commit", "LEDGER_FAIL", "HEAD")?
                };
                let u = &mut ledger.units[idx];
                u.files_cnt = u_files.len();
                u.lines_cnt = live_u_lines;
                u.risk = live_u_risk.risk_level.to_string();
                u.unit_tree_hash = u_hash;
                ledger.meta.insert("head_sha".to_string(), head_now);
            }
        }

        if !cu_val.is_empty() {
            if !matches!(
                cu_val.as_str(),
                "N_A" | "PENDING" | "REVIEWED" | "INCOMPLETE" | "STALE" | "BLOCKED"
            ) {
                return Err(fail(
                    format!("LEDGER_FAIL: invalid -CrossUnitStatus '{cu_val}'"),
                    1,
                ));
            }
            ledger
                .meta
                .insert("cross_unit_status".to_string(), cu_val.clone());
            if cu_val == "REVIEWED" {
                let cu_paths = if !live_contracts_upd.is_empty() {
                    live_contracts_upd
                } else {
                    let mut all_unit_files = Vec::new();
                    for u in &ledger.units {
                        for uf in split_csv_list_as_paths(&u.files_csv) {
                            if !all_unit_files.iter().any(|x| x == &uf) {
                                all_unit_files.push(uf);
                            }
                        }
                    }
                    all_unit_files
                };
                let cu_hash = upd_tree_snap
                    .as_ref()
                    .expect("upd_tree_snap populated")
                    .scope_paths_tree_hash(&repo_root, &cu_paths, &ignored)?;
                ledger
                    .meta
                    .insert("cross_unit_tree_hash".to_string(), cu_hash);
            }
        }

        if ledger.meta["head_sha"] != orig_head_sha
            && !ri_explicit
            && ledger.meta["review_independence"] == "INDEPENDENT"
        {
            ledger
                .meta
                .insert("review_independence".to_string(), "UNKNOWN".to_string());
        }

        let mut auto_delta = 0i64;
        if found_idx.is_some()
            && (matches!(st_val.as_str(), "REVIEWED" | "INCOMPLETE" | "BLOCKED") || added_new_spec)
        {
            auto_delta += 1;
        }
        if matches!(cu_val.as_str(), "REVIEWED" | "INCOMPLETE" | "BLOCKED") {
            auto_delta += 1;
        }

        let cur_passes: i64 = ledger.meta["passes_used"].parse().unwrap_or(0);
        let min_next_passes = cur_passes + auto_delta;
        let new_passes = if let Some(pu) = passes_used {
            if pu < cur_passes {
                return Err(fail(
                    format!(
                        "LEDGER_FAIL: passes_used cannot be reduced or reset ({cur_passes}->{pu})"
                    ),
                    1,
                ));
            }
            if pu < min_next_passes {
                return Err(fail(
                    format!("LEDGER_FAIL: passes_used ({pu}) cannot bypass consumed passes (minimum {min_next_passes})"),
                    1,
                ));
            }
            pu
        } else {
            min_next_passes
        };

        ledger
            .meta
            .insert("passes_used".to_string(), new_passes.to_string());

        if let Some(mp) = max_passes {
            ledger.meta.insert("max_passes".to_string(), mp.to_string());
        }
        let eff_max_p: i64 = ledger.meta["max_passes"].parse().unwrap_or(0);
        if !budget_status.trim().is_empty() {
            let bs = budget_status.trim().to_ascii_uppercase();
            if bs != "OK" && bs != "EXHAUSTED" {
                return Err(fail(
                    format!("LEDGER_FAIL: invalid -BudgetStatus '{bs}'"),
                    1,
                ));
            }
            if bs == "OK" && eff_max_p > 0 && new_passes > eff_max_p {
                return Err(fail(
                    format!("LEDGER_FAIL: cannot set budget_status=OK while passes_used ({new_passes}) exceeds max_passes ({eff_max_p})"),
                    1,
                ));
            }
            ledger.meta.insert("budget_status".to_string(), bs);
        } else if eff_max_p > 0 && new_passes > eff_max_p {
            ledger
                .meta
                .insert("budget_status".to_string(), "EXHAUSTED".to_string());
        }

        write_atomic_lf(&ledger_full, &serialize_review_ledger(&ledger))?;
        return Ok((format!("LEDGER_UPDATED: path={ledger_rel}"), 0));
    }

    // check
    let chk_res = invoke_review_ledger_check(&repo_root, &ledger_full, &ledger_rel, &ignored)?;
    Ok((chk_res.message, 0))
}

fn replace_run_chars(input: &str, targets: &[char], replacement: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut in_run = false;
    for ch in input.chars() {
        if targets.contains(&ch) {
            if !in_run {
                out.push_str(replacement);
                in_run = true;
            }
        } else {
            in_run = false;
            out.push(ch);
        }
    }
    out
}
