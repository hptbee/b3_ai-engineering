use std::collections::{HashMap, HashSet};

use crate::error::{fail, B3Error};
use crate::fs::{
    convert_to_wave_paths, convert_to_wave_task_map, find_reparse_in_path_hierarchy,
    normalize_repo_root, sort_ordinal, test_checkpoint_path, test_wave_path_contained,
    test_wave_path_overlap, WaveOverlap,
};
use crate::git::{
    run_git, run_git_paths_z, test_git_mid_operation, test_repo_case_insensitive, GitZMode,
};

struct DirtyEntry {
    path: String,
    tag: &'static str,
}

#[allow(clippy::too_many_arguments)]
pub fn run(
    repo_root_raw: &str,
    wave_specs: &str,
    wave_reads: &str,
    expected_base_sha: &str,
    max_concurrency: i32,
    partition: bool,
    protected_paths: &str,
    check_dirty_scope: bool,
    ignore_dirty_paths: &str,
) -> Result<(String, i32), B3Error> {
    if wave_specs.trim().is_empty() {
        return Err(fail("WAVE_FAIL: missing --wave-specs", 1));
    }
    if repo_root_raw.is_empty() {
        return Err(fail("WAVE_FAIL: missing --repo-root", 1));
    }
    if !(1..=4).contains(&max_concurrency) {
        return Err(fail(
            "WAVE_FAIL: --max-concurrency must be between 1 and 4",
            1,
        ));
    }

    let repo_root = normalize_repo_root(repo_root_raw)?;
    if find_reparse_in_path_hierarchy(&repo_root).is_some() {
        return Err(fail(
            "WAVE_FAIL: unsafe symlink or junction alias in path '.'",
            1,
        ));
    }

    let no_env: [(&str, &str); 0] = [];
    let exp_base = expected_base_sha.trim();
    if !exp_base.is_empty() {
        if let Some(mid_op) = test_git_mid_operation(&repo_root) {
            return Err(fail(
                format!("WAVE_BASE_MISMATCH: git_op_in_progress({mid_op})"),
                2,
            ));
        }
        let head_res = run_git(&repo_root, &["rev-parse", "HEAD"], &no_env, None)?;
        let act_head = String::from_utf8_lossy(&head_res.stdout).trim().to_string();
        if head_res.exit_code != 0 || act_head.is_empty() {
            return Err(fail("WAVE_BASE_MISMATCH: git rev-parse HEAD failed", 2));
        }
        if act_head != exp_base {
            return Err(fail(
                format!("WAVE_BASE_MISMATCH: expected={exp_base} actual={act_head}"),
                2,
            ));
        }
    }

    let repo_exists = repo_root.is_dir();
    let wave_parsed = convert_to_wave_task_map(
        wave_specs,
        &repo_root,
        "WAVE_FAIL",
        "WaveSpecs",
        "--wave-specs",
        true,
        partition,
        true,
        None,
    )?;
    let task_order = wave_parsed.order;
    let task_paths = wave_parsed.map;
    let total_paths = wave_parsed.total_paths;

    let mut read_paths: HashMap<String, Vec<String>> = HashMap::new();
    if !wave_reads.trim().is_empty() {
        for entry in wave_reads.split(';') {
            let trim_entry = entry.trim();
            if trim_entry.is_empty() {
                continue;
            }
            let Some(eq_idx) = trim_entry.find('=') else {
                return Err(fail(
                    format!("WAVE_FAIL: invalid WaveReads entry '{trim_entry}' (expected TaskId=path1,path2)"),
                    1,
                ));
            };
            let rtid = trim_entry[..eq_idx].trim().to_string();
            let r_csv = &trim_entry[eq_idx + 1..];
            if rtid.is_empty() {
                return Err(fail(
                    format!("WAVE_FAIL: empty task id in WaveReads '{trim_entry}'"),
                    1,
                ));
            }
            if !crate::fs::is_valid_task_id(&rtid) {
                return Err(fail(format!("WAVE_FAIL: invalid task id '{rtid}'"), 1));
            }
            if read_paths.contains_key(&rtid) {
                return Err(fail(
                    format!("WAVE_FAIL: duplicate task id '{rtid}' in WaveReads"),
                    1,
                ));
            }
            if !task_paths.contains_key(&rtid) {
                return Err(fail(
                    format!("WAVE_FAIL: unknown task id '{rtid}' in WaveReads"),
                    1,
                ));
            }
            let parsed_r = convert_to_wave_paths(r_csv, false, false, "WAVE_FAIL")?;
            if repo_exists {
                for rp in &parsed_r.paths {
                    if !test_wave_path_contained(&repo_root, rp) {
                        return Err(fail(
                            format!("WAVE_FAIL: unsafe symlink or junction alias in path '{rp}'"),
                            1,
                        ));
                    }
                }
            }
            read_paths.insert(rtid, parsed_r.paths);
        }
    }

    let case_insensitive = test_repo_case_insensitive(&repo_root);
    let mut protected_list = Vec::new();
    if !protected_paths.trim().is_empty() {
        let parsed_prot = convert_to_wave_paths(protected_paths, false, false, "WAVE_FAIL")?;
        for prot in &parsed_prot.paths {
            if prot == "." {
                return Err(fail("WAVE_FAIL: invalid protected path '.'", 1));
            }
            if repo_exists && !test_wave_path_contained(&repo_root, prot) {
                return Err(fail(
                    format!("WAVE_FAIL: unsafe symlink or junction alias in path '{prot}'"),
                    1,
                ));
            }
        }
        protected_list = parsed_prot.paths;
    }

    for ti in &task_order {
        for pi in &task_paths[ti] {
            for prot in &protected_list {
                if test_wave_path_overlap(pi, prot, case_insensitive) != WaveOverlap::None {
                    return Err(fail(
                        format!(
                            "WAVE_FAIL: protected path '{pi}' overlaps single-writer boundary '{prot}'"
                        ),
                        1,
                    ));
                }
            }
        }
    }

    let n_tasks = task_order.len();
    let task_index_map: HashMap<&str, usize> = task_order
        .iter()
        .enumerate()
        .map(|(i, s)| (s.as_str(), i))
        .collect();
    let mut has_conflict = vec![vec![false; n_tasks]; n_tasks];
    let mut conflicts = Vec::new();

    for i in 0..n_tasks {
        for j in (i + 1)..n_tasks {
            let ti = &task_order[i];
            let tj = &task_order[j];
            for pi in &task_paths[ti] {
                for pj in &task_paths[tj] {
                    match test_wave_path_overlap(pi, pj, case_insensitive) {
                        WaveOverlap::Equal => {
                            conflicts.push(format!("{pi}({ti},{tj})"));
                            has_conflict[i][j] = true;
                            has_conflict[j][i] = true;
                        }
                        WaveOverlap::Prefix => {
                            conflicts.push(format!("{pi}<->{pj}({ti},{tj})"));
                            has_conflict[i][j] = true;
                            has_conflict[j][i] = true;
                        }
                        WaveOverlap::None => {}
                    }
                }
            }
        }
    }

    for (i, ti) in task_order.iter().enumerate() {
        for (tj, rpaths) in &read_paths {
            if ti == tj {
                continue;
            }
            let j = task_index_map[tj.as_str()];
            for pi in &task_paths[ti] {
                for rj in rpaths {
                    match test_wave_path_overlap(pi, rj, case_insensitive) {
                        WaveOverlap::Equal => {
                            conflicts.push(format!("rw:{pi}({ti}->{tj})"));
                            has_conflict[i][j] = true;
                            has_conflict[j][i] = true;
                        }
                        WaveOverlap::Prefix => {
                            conflicts.push(format!("rw:{pi}<->{rj}({ti}->{tj})"));
                            has_conflict[i][j] = true;
                            has_conflict[j][i] = true;
                        }
                        WaveOverlap::None => {}
                    }
                }
            }
        }
    }

    let run_dirty_check = check_dirty_scope
        || !ignore_dirty_paths.trim().is_empty()
        || (partition && !exp_base.is_empty());
    let mut dirty_blocked = vec![false; n_tasks];
    let mut user_dirty_list = Vec::new();
    let mut unexpected_dirty_list = Vec::new();
    let mut dirty_scope_val = "not_checked";
    let mut user_dirty_csv = "none".to_string();
    let mut unexpected_dirty_csv = "none".to_string();
    let mut blocked_tasks_csv = "none".to_string();

    if run_dirty_check {
        let mut ignore_list = Vec::new();
        if !ignore_dirty_paths.trim().is_empty() {
            let parsed_ign = convert_to_wave_paths(ignore_dirty_paths, false, false, "WAVE_FAIL")?;
            for ign in &parsed_ign.paths {
                if ign == "." {
                    return Err(fail("WAVE_FAIL: invalid ignore-dirty path '.'", 1));
                }
                if repo_exists && !test_wave_path_contained(&repo_root, ign) {
                    return Err(fail(
                        format!("WAVE_FAIL: unsafe symlink or junction alias in path '{ign}'"),
                        1,
                    ));
                }
            }
            ignore_list = parsed_ign.paths;
        }

        if let Some(mid_op) = test_git_mid_operation(&repo_root) {
            return Err(fail(
                format!("WAVE_BASE_MISMATCH: git_op_in_progress({mid_op})"),
                2,
            ));
        }

        let diff_head = run_git_paths_z(
            &repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "--no-renames",
                "--name-only",
                "-z",
                "HEAD",
                "--",
            ],
            GitZMode::Names,
            "WAVE_FAIL",
            &no_env,
        )
        .map_err(|e| {
            if e.message.contains("unsupported_literal_git_path") {
                fail("WAVE_FAIL: unsupported_literal_git_path", 1)
            } else {
                fail(
                    format!("WAVE_BASE_MISMATCH: git diff HEAD failed ({})", e.message),
                    2,
                )
            }
        })?;
        let diff_cached = run_git_paths_z(
            &repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "--cached",
                "--no-renames",
                "--name-only",
                "-z",
                "--",
            ],
            GitZMode::Names,
            "WAVE_FAIL",
            &no_env,
        )
        .map_err(|e| {
            if e.message.contains("unsupported_literal_git_path") {
                fail("WAVE_FAIL: unsupported_literal_git_path", 1)
            } else {
                fail(
                    format!("WAVE_BASE_MISMATCH: git diff HEAD failed ({})", e.message),
                    2,
                )
            }
        })?;
        let ls_untracked = run_git_paths_z(
            &repo_root,
            &["ls-files", "--others", "--exclude-standard", "-z"],
            GitZMode::Names,
            "WAVE_FAIL",
            &no_env,
        )
        .map_err(|e| {
            if e.message.contains("unsupported_literal_git_path") {
                fail("WAVE_FAIL: unsupported_literal_git_path", 1)
            } else {
                fail(
                    format!("WAVE_BASE_MISMATCH: git diff HEAD failed ({})", e.message),
                    2,
                )
            }
        })?;

        let mut dirty_seen = HashSet::new();
        for dp in diff_head.into_iter().chain(diff_cached).chain(ls_untracked) {
            if !dp.is_empty() && !test_checkpoint_path(&dp) {
                dirty_seen.insert(dp);
            }
        }
        let all_dirty_sorted = sort_ordinal(dirty_seen, false);
        let mut dirty_entries = Vec::with_capacity(all_dirty_sorted.len());
        for d in all_dirty_sorted {
            let d_cmp = if case_insensitive {
                d.to_ascii_lowercase()
            } else {
                d.clone()
            };
            let mut is_user_dirty = false;
            for ign in &ignore_list {
                let ign_cmp = if case_insensitive {
                    ign.to_ascii_lowercase()
                } else {
                    ign.clone()
                };
                if d_cmp == ign_cmp || (ign != "." && d_cmp.starts_with(&format!("{ign_cmp}/"))) {
                    is_user_dirty = true;
                    break;
                }
            }
            if is_user_dirty {
                user_dirty_list.push(d.clone());
                dirty_entries.push(DirtyEntry {
                    path: d,
                    tag: "USER_DIRTY",
                });
            } else {
                unexpected_dirty_list.push(d.clone());
                dirty_entries.push(DirtyEntry {
                    path: d,
                    tag: "UNEXPECTED_DIRTY",
                });
            }
        }

        for i in 0..n_tasks {
            let ti = &task_order[i];
            let mut task_all = task_paths[ti].clone();
            if let Some(rp) = read_paths.get(ti) {
                task_all.extend(rp.iter().cloned());
            }
            for de in &dirty_entries {
                for tp in &task_all {
                    if test_wave_path_overlap(&de.path, tp, case_insensitive) != WaveOverlap::None {
                        dirty_blocked[i] = true;
                        conflicts.push(format!("dirty:{}({}->{ti})", de.path, de.tag));
                        break;
                    }
                }
            }
        }

        dirty_scope_val = if !unexpected_dirty_list.is_empty() {
            "unexpected"
        } else if !user_dirty_list.is_empty() {
            "user_only"
        } else {
            "clean"
        };
        if !user_dirty_list.is_empty() {
            user_dirty_csv = user_dirty_list.join(",");
        }
        if !unexpected_dirty_list.is_empty() {
            unexpected_dirty_csv = unexpected_dirty_list.join(",");
        }
        let blocked_names: Vec<String> = (0..n_tasks)
            .filter(|&i| dirty_blocked[i])
            .map(|i| task_order[i].clone())
            .collect();
        if !blocked_names.is_empty() {
            blocked_tasks_csv = blocked_names.join(",");
        }
    }

    if !partition {
        if run_dirty_check && !unexpected_dirty_list.is_empty() {
            return Err(fail(
                format!("WAVE_BASE_MISMATCH: unexpected_dirty({unexpected_dirty_csv})"),
                2,
            ));
        }
        if dirty_blocked.iter().any(|&b| b) || !conflicts.is_empty() {
            let sorted_conf = sort_ordinal(conflicts, false).join(", ");
            return Err(fail(format!("WAVE_CONFLICT: {sorted_conf}"), 2));
        }
        return Ok((
            format!("WAVE_OK: disjoint ({n_tasks} tasks, {total_paths} paths)"),
            0,
        ));
    }

    let eligible_indices: Vec<usize> = (0..n_tasks).filter(|&i| !dirty_blocked[i]).collect();
    let eligible_count = eligible_indices.len();
    let blocked_count = n_tasks - eligible_count;

    let mut waves: Vec<Vec<usize>> = Vec::new();
    for &i in &eligible_indices {
        let mut placed = false;
        for members in &mut waves {
            if members.len() >= max_concurrency as usize {
                continue;
            }
            if members.iter().all(|&m| !has_conflict[i][m]) {
                members.push(i);
                placed = true;
                break;
            }
        }
        if !placed {
            waves.push(vec![i]);
        }
    }

    let w_count = waves.len();
    let max_parallel = waves.iter().map(|w| w.len()).max().unwrap_or(0);
    let conflicts_csv = if conflicts.is_empty() {
        "none".to_string()
    } else {
        sort_ordinal(conflicts, false).join(",")
    };

    let mut lines = Vec::new();
    lines.push(format!("dirty_scope={dirty_scope_val}"));
    lines.push(format!("user_dirty={user_dirty_csv}"));
    lines.push(format!("unexpected_dirty={unexpected_dirty_csv}"));
    lines.push(format!("blocked_tasks={blocked_tasks_csv}"));
    lines.push(format!("wave_count={w_count}"));
    lines.push(format!("max_concurrency={max_concurrency}"));
    lines.push(format!("max_parallel={max_parallel}"));
    lines.push(format!("conflicts={conflicts_csv}"));

    for (w, members) in waves.iter().enumerate() {
        let cnt = members.len();
        let t_names: Vec<&str> = members.iter().map(|&m| task_order[m].as_str()).collect();
        let tasks_csv = t_names.join(",");
        if cnt >= 2 {
            lines.push(format!(
                "wave|{}|PARALLEL|agents={cnt}|tasks={tasks_csv}|reason=independent_ready_tasks",
                w + 1
            ));
        } else {
            let t = members[0];
            let w_reason = if eligible_count == 1 {
                "single_ready_task"
            } else {
                let mut bounded = false;
                for prior in waves.iter().take(w) {
                    if prior.len() == max_concurrency as usize
                        && prior.iter().all(|&pm| !has_conflict[t][pm])
                    {
                        bounded = true;
                        break;
                    }
                }
                if !bounded
                    && max_concurrency == 1
                    && eligible_indices
                        .iter()
                        .all(|&u| u == t || !has_conflict[t][u])
                {
                    bounded = true;
                }
                if bounded {
                    "bounded_concurrency"
                } else {
                    "shared_write_conflict"
                }
            };
            lines.push(format!(
                "wave|{}|SEQUENTIAL|agents=1|tasks={tasks_csv}|reason={w_reason}",
                w + 1
            ));
        }
    }

    let mut eligible_has_pair_conflict = false;
    'outer: for ei in 0..eligible_count {
        for ej in (ei + 1)..eligible_count {
            if has_conflict[eligible_indices[ei]][eligible_indices[ej]] {
                eligible_has_pair_conflict = true;
                break 'outer;
            }
        }
    }

    let (term_line, exit_code) = if run_dirty_check && !unexpected_dirty_list.is_empty() {
        (
            format!("WAVE_BASE_MISMATCH: unexpected_dirty({unexpected_dirty_csv})"),
            2,
        )
    } else if eligible_count == 0 {
        (
            "WAVE_SEQUENTIAL: waves=0 max_parallel=0 reason=dirty_scope_conflict".to_string(),
            2,
        )
    } else if blocked_count > 0 {
        if max_parallel >= 2 {
            (
                format!(
                    "WAVE_PARTITIONED: waves={w_count} max_parallel={max_parallel} reason=dirty_scope_partial_split"
                ),
                0,
            )
        } else {
            let code = if eligible_has_pair_conflict { 2 } else { 0 };
            (
                format!(
                    "WAVE_SEQUENTIAL: waves={w_count} max_parallel=1 reason=dirty_scope_partial_split"
                ),
                code,
            )
        }
    } else if w_count == 1 && conflicts_csv == "none" {
        (
            format!("WAVE_OK: disjoint ({n_tasks} tasks, {total_paths} paths)"),
            0,
        )
    } else if max_parallel >= 2 {
        let term_reason = if conflicts_csv == "none" {
            "bounded_concurrency_split"
        } else {
            "conflicting_wave_split"
        };
        (
            format!("WAVE_PARTITIONED: waves={w_count} max_parallel={max_parallel} reason={term_reason}"),
            0,
        )
    } else if conflicts_csv == "none" {
        (
            format!("WAVE_SEQUENTIAL: waves={w_count} max_parallel=1 reason=bounded_concurrency"),
            0,
        )
    } else {
        (
            format!("WAVE_SEQUENTIAL: waves={w_count} max_parallel=1 reason=shared_write_conflict"),
            2,
        )
    };

    lines.push(term_line);
    Ok((lines.join("\n"), exit_code))
}
