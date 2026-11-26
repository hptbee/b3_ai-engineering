use std::collections::HashMap;
use std::path::Path;

use crate::error::{fail, B3Error};
use crate::fs::{
    is_hex64_lower, normalize_repo_root, resolve_unresolved_path, sha256_file_hex, sort_ordinal,
    split_path_csv_checked, test_contained_repo_path, valid_timestamp_utc, write_atomic_lf,
};
use crate::git::{is_hex40, run_git};
use crate::guard::verify::format_utc_iso8601_now;

fn sha256_file_for_evidence(path: &Path) -> Result<String, B3Error> {
    sha256_file_hex(path).map_err(|e| {
        fail(
            format!("EVIDENCE_MISSING: failed reading file: {}", e.message),
            1,
        )
    })
}

/// Executes `b3 guard evidence-check`.
pub fn run(
    repo_root_raw: &str,
    source_paths: &str,
    manifest_path: &str,
    write_manifest: bool,
) -> Result<(String, i32), B3Error> {
    let repo_root = normalize_repo_root(repo_root_raw)?;
    let Some((m_full, m_rel)) = test_contained_repo_path(&repo_root, manifest_path) else {
        return Err(fail("EVIDENCE_MISSING: invalid manifest path", 1));
    };

    let src_list = split_path_csv_checked(
        source_paths,
        "EVIDENCE_MISSING",
        true,
        Some("EVIDENCE_MISSING: invalid path ."),
    )?;

    if write_manifest {
        if src_list.is_empty() {
            return Err(fail("EVIDENCE_MISSING: missing -SourcePaths", 1));
        }
        let mut checked = Vec::with_capacity(src_list.len());
        for sp in &src_list {
            let Some((_, rel)) = test_contained_repo_path(&repo_root, sp) else {
                return Err(fail(format!("EVIDENCE_MISSING: invalid path {sp}"), 1));
            };
            checked.push(rel);
        }
        let sorted_src = sort_ordinal(checked, false);
        let mut missing_list = Vec::new();
        let mut entries = Vec::with_capacity(sorted_src.len());
        for rel in &sorted_src {
            let full = resolve_unresolved_path(&repo_root, rel);
            if !full.is_file() {
                missing_list.push(rel.clone());
            } else {
                let hash_hex = sha256_file_for_evidence(&full)?;
                entries.push(format!("file={hash_hex} {rel}"));
            }
        }
        if !missing_list.is_empty() {
            return Err(fail(
                format!("EVIDENCE_MISSING: {}", missing_list.join(",")),
                1,
            ));
        }

        let no_env: [(&str, &str); 0] = [];
        let head_res = run_git(
            &repo_root,
            &["rev-parse", "--verify", "--quiet", "HEAD"],
            &no_env,
            None,
        )?;
        let raw_head = String::from_utf8_lossy(&head_res.stdout).trim().to_string();
        let head_sha = if head_res.exit_code == 0 && is_hex40(&raw_head) {
            raw_head
        } else {
            "NO_HEAD".to_string()
        };
        let ts_utc = format_utc_iso8601_now();
        let mut body_lines = vec![
            "schema=b3-evidence-v1".to_string(),
            format!("head_sha={head_sha}"),
            format!("timestamp_utc={ts_utc}"),
        ];
        let count = entries.len();
        body_lines.extend(entries);
        let body = body_lines.join("\n") + "\n";
        write_atomic_lf(&m_full, &body)?;
        return Ok((format!("EVIDENCE_WRITTEN: {count} files -> {m_rel}"), 0));
    }

    if !m_full.is_file() {
        return Err(fail(
            format!("EVIDENCE_MISSING: missing manifest ({m_rel})"),
            1,
        ));
    }
    let raw_manifest = std::fs::read_to_string(&m_full)
        .map_err(|_| fail(format!("EVIDENCE_MISSING: missing manifest ({m_rel})"), 1))?;

    let mut has_schema = false;
    let mut has_head = false;
    let mut has_ts = false;
    let mut manifest_map: HashMap<String, String> = HashMap::new();
    let mut manifest_order: Vec<String> = Vec::new();

    for raw_line in raw_manifest.lines() {
        let ln = raw_line.trim();
        if ln.is_empty() {
            continue;
        }
        if ln == "schema=b3-evidence-v1" {
            has_schema = true;
            continue;
        }
        if let Some(hs) = ln.strip_prefix("head_sha=") {
            if hs == "NO_HEAD" || is_hex40(hs) {
                has_head = true;
                continue;
            }
        }
        if let Some(ts) = ln.strip_prefix("timestamp_utc=") {
            if valid_timestamp_utc(ts) {
                has_ts = true;
                continue;
            }
        }
        if let Some(rest) = ln.strip_prefix("file=") {
            if rest.len() > 65 {
                let h = &rest[..64];
                let sep_and_rp = &rest[64..];
                if is_hex64_lower(h)
                    && (sep_and_rp.starts_with(' ') || sep_and_rp.starts_with('\t'))
                {
                    let rp = sep_and_rp.trim_start_matches([' ', '\t']).trim();
                    if !rp.is_empty() {
                        let Some((_, rel)) = test_contained_repo_path(&repo_root, rp) else {
                            return Err(fail(format!("EVIDENCE_MISSING: invalid path {rp}"), 1));
                        };
                        if manifest_map.contains_key(&rel) {
                            return Err(fail(
                                format!("EVIDENCE_MISSING: duplicate entry {rel}"),
                                1,
                            ));
                        }
                        manifest_map.insert(rel.clone(), h.to_string());
                        manifest_order.push(rel);
                        continue;
                    }
                }
            }
        }
        return Err(fail(
            format!("EVIDENCE_MISSING: invalid manifest ({m_rel})"),
            1,
        ));
    }

    if !has_schema || !has_head || !has_ts || manifest_order.is_empty() {
        return Err(fail(
            format!("EVIDENCE_MISSING: invalid manifest ({m_rel})"),
            1,
        ));
    }

    if !src_list.is_empty() {
        let mut uncovered = Vec::new();
        for sp in &src_list {
            let Some((_, rel)) = test_contained_repo_path(&repo_root, sp) else {
                return Err(fail(format!("EVIDENCE_MISSING: invalid path {sp}"), 1));
            };
            if !manifest_map.contains_key(&rel) && !uncovered.iter().any(|u| u == &rel) {
                uncovered.push(rel);
            }
        }
        if !uncovered.is_empty() {
            let sorted_unc = sort_ordinal(uncovered, false).join(",");
            return Err(fail(format!("EVIDENCE_MISSING: uncovered {sorted_unc}"), 1));
        }
    }

    let mut missing_files = Vec::new();
    let mut stale_files = Vec::new();
    for rel in &manifest_order {
        let Some((c_full, _)) = test_contained_repo_path(&repo_root, rel) else {
            return Err(fail(format!("EVIDENCE_MISSING: invalid path {rel}"), 1));
        };
        if !c_full.is_file() {
            missing_files.push(rel.clone());
        } else {
            let cur_hash = sha256_file_for_evidence(&c_full)?;
            if cur_hash != manifest_map[rel] {
                stale_files.push(rel.clone());
            }
        }
    }
    if !missing_files.is_empty() {
        return Err(fail(
            format!(
                "EVIDENCE_MISSING: {}",
                sort_ordinal(missing_files, false).join(",")
            ),
            1,
        ));
    }
    if !stale_files.is_empty() {
        return Err(fail(
            format!(
                "EVIDENCE_STALE: {}",
                sort_ordinal(stale_files, false).join(",")
            ),
            2,
        ));
    }
    Ok((format!("EVIDENCE_FRESH: {} files", manifest_order.len()), 0))
}
