use std::collections::{HashMap, HashSet};
use std::path::Path;

use crate::config::{resolve_config, B3Config, ExecutionMode, MaxConcurrency};
use crate::error::{fail, B3Error};
use crate::fs::{
    convert_to_wave_paths, convert_to_wave_task_map, find_reparse_in_path_hierarchy,
    is_protected_wave_path, normalize_repo_root, sort_ordinal, test_checkpoint_path,
    test_wave_path_contained, test_wave_path_overlap, WaveOverlap,
};
use crate::git::{
    run_git, run_git_paths_z, test_git_mid_operation, test_repo_case_insensitive, GitZMode,
};
use crate::guard::push_unique_str;

pub const MAX_CONCURRENCY_LIMIT: i32 = 64;

pub fn default_adaptive_concurrency() -> i32 {
    std::thread::available_parallelism()
        .map(|n| n.get().clamp(4, 16) as i32)
        .unwrap_or(4)
}

pub fn resolve_concurrency(max_concurrency: i32, err_prefix: &str) -> Result<i32, B3Error> {
    if max_concurrency == 0 {
        return Ok(default_adaptive_concurrency());
    }
    if !(1..=MAX_CONCURRENCY_LIMIT).contains(&max_concurrency) {
        return Err(fail(
            format!(
                "{err_prefix}: --max-concurrency must be between 1 and {MAX_CONCURRENCY_LIMIT}"
            ),
            1,
        ));
    }
    Ok(max_concurrency)
}

pub fn resolve_concurrency_with_config(
    max_concurrency: i32,
    cfg: &B3Config,
    err_prefix: &str,
) -> Result<i32, B3Error> {
    if max_concurrency != 0 {
        return resolve_concurrency(max_concurrency, err_prefix);
    }
    match cfg.parallel.max_concurrency {
        MaxConcurrency::Auto => Ok(default_adaptive_concurrency()),
        MaxConcurrency::Fixed(n) => Ok((n as i32).clamp(1, MAX_CONCURRENCY_LIMIT)),
    }
}

struct DirtyEntry {
    path: String,
    tag: &'static str,
}

fn assert_repo_contained_input_path(
    repo_root: &Path,
    repo_exists: bool,
    norm_path: &str,
) -> Result<(), B3Error> {
    if repo_exists && !test_wave_path_contained(repo_root, norm_path) {
        return Err(fail(
            format!("WAVE_FAIL: unsafe symlink or junction alias in path '{norm_path}'"),
            1,
        ));
    }
    Ok(())
}

fn path_is_within_scope(dirty: &str, scope: &str, case_insensitive: bool) -> bool {
    if scope.is_empty() || scope == "." {
        return false;
    }
    if case_insensitive {
        let d_low = dirty.to_ascii_lowercase();
        let s_low = scope.to_ascii_lowercase();
        d_low == s_low || d_low.starts_with(&format!("{s_low}/"))
    } else {
        dirty == scope || dirty.starts_with(&format!("{scope}/"))
    }
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
    active_specs: &str,
    active_reads: &str,
    verified_dirty_paths: &str,
) -> Result<(String, i32), B3Error> {
    if wave_specs.trim().is_empty() {
        return Err(fail("WAVE_FAIL: missing --wave-specs", 1));
    }
    if repo_root_raw.is_empty() {
        return Err(fail("WAVE_FAIL: missing --repo-root", 1));
    }
    let repo_root = normalize_repo_root(repo_root_raw)?;
    let cfg = resolve_config(Some(&repo_root), None, &[]).config;
    let explicit_conc = max_concurrency != 0;
    let mut max_concurrency = resolve_concurrency_with_config(max_concurrency, &cfg, "WAVE_FAIL")?;
    let cfg_exec_mode = cfg.parallel.execution_mode;
    if !explicit_conc && cfg_exec_mode == ExecutionMode::Sequential {
        max_concurrency = 1;
    }
    let has_continuous_ctx = !active_specs.trim().is_empty()
        || !active_reads.trim().is_empty()
        || !verified_dirty_paths.trim().is_empty();
    if !active_reads.trim().is_empty() && active_specs.trim().is_empty() {
        return Err(fail("WAVE_FAIL: --active-reads requires --active-specs", 1));
    }

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
            for rp in &parsed_r.paths {
                if has_continuous_ctx && rp == "." {
                    return Err(fail(
                        format!("WAVE_FAIL: --wave-reads task '{rtid}' cannot use root '.'"),
                        1,
                    ));
                }
                if repo_exists && !test_wave_path_contained(&repo_root, rp) {
                    return Err(fail(
                        format!("WAVE_FAIL: unsafe symlink or junction alias in path '{rp}'"),
                        1,
                    ));
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

    let mut active_order: Vec<String> = Vec::new();
    let mut active_paths: HashMap<String, Vec<String>> = HashMap::new();
    let mut active_read_map: HashMap<String, Vec<String>> = HashMap::new();
    let mut verified_dirty_spec: Vec<String> = Vec::new();

    if has_continuous_ctx {
        if !active_specs.trim().is_empty() {
            let active_parsed = convert_to_wave_task_map(
                active_specs,
                &repo_root,
                "WAVE_FAIL",
                "ActiveSpecs",
                "--active-specs",
                false,
                true,
                true,
                None,
            )?;
            for ak in &active_parsed.order {
                for ap in &active_parsed.map[ak] {
                    if ap == "." {
                        return Err(fail(
                            format!(
                                "WAVE_FAIL: --active-specs task '{ak}' touches protected path '.'"
                            ),
                            1,
                        ));
                    }
                    assert_repo_contained_input_path(&repo_root, repo_exists, ap)?;
                    if is_protected_wave_path(ap)
                        || protected_list.iter().any(|prot| {
                            test_wave_path_overlap(ap, prot, case_insensitive) != WaveOverlap::None
                        })
                    {
                        return Err(fail(
                            format!("WAVE_FAIL: --active-specs task '{ak}' touches protected path '{ap}'"),
                            1,
                        ));
                    }
                }
            }
            for tk in &task_order {
                if active_parsed.map.contains_key(tk) {
                    return Err(fail(
                        format!("WAVE_FAIL: duplicate active task '{tk}' in --wave-specs"),
                        1,
                    ));
                }
            }
            active_order = active_parsed.order;
            active_paths = active_parsed.map;
        }

        if !active_reads.trim().is_empty() {
            let ar_parsed = convert_to_wave_task_map(
                active_reads,
                &repo_root,
                "WAVE_FAIL",
                "ActiveReads",
                "--active-reads",
                false,
                true,
                true,
                None,
            )?;
            for rk in &ar_parsed.order {
                if !active_paths.contains_key(rk) {
                    return Err(fail(
                        format!("WAVE_FAIL: --active-reads references unknown active task '{rk}'"),
                        1,
                    ));
                }
                for rp in &ar_parsed.map[rk] {
                    if rp == "." {
                        return Err(fail(
                            format!("WAVE_FAIL: --active-reads task '{rk}' cannot use root '.'"),
                            1,
                        ));
                    }
                    assert_repo_contained_input_path(&repo_root, repo_exists, rp)?;
                }
            }
            active_read_map = ar_parsed.map;
        }

        if !verified_dirty_paths.trim().is_empty() {
            let parsed_vd = convert_to_wave_paths(verified_dirty_paths, false, false, "WAVE_FAIL")?;
            for vp in &parsed_vd.paths {
                assert_repo_contained_input_path(&repo_root, repo_exists, vp)?;
                if vp == "."
                    || is_protected_wave_path(vp)
                    || protected_list.iter().any(|prot| {
                        test_wave_path_overlap(vp, prot, case_insensitive) != WaveOverlap::None
                    })
                {
                    return Err(fail(
                        format!("WAVE_FAIL: --verified-dirty-paths touches protected path '{vp}'"),
                        1,
                    ));
                }
                for ak in &active_order {
                    for ap in &active_paths[ak] {
                        if test_wave_path_overlap(vp, ap, case_insensitive) != WaveOverlap::None {
                            return Err(fail(
                                format!(
                                    "WAVE_FAIL: --verified-dirty-paths overlaps active task '{ak}' path '{vp}'"
                                ),
                                1,
                            ));
                        }
                    }
                }
            }
            verified_dirty_spec = parsed_vd.paths;
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

    let mut active_blocked = vec![false; n_tasks];
    if has_continuous_ctx {
        for (i, ti) in task_order.iter().enumerate() {
            for pi in &task_paths[ti] {
                for vp in &verified_dirty_spec {
                    match test_wave_path_overlap(vp, pi, case_insensitive) {
                        WaveOverlap::Equal => {
                            active_blocked[i] = true;
                            push_unique_str(
                                &mut conflicts,
                                format!("verified_uncommitted:{pi}({ti})"),
                            );
                        }
                        WaveOverlap::Prefix => {
                            active_blocked[i] = true;
                            push_unique_str(
                                &mut conflicts,
                                format!("verified_uncommitted:{vp}<->{pi}({ti})"),
                            );
                        }
                        WaveOverlap::None => {}
                    }
                }
            }

            for ak in &active_order {
                for ap in &active_paths[ak] {
                    for pi in &task_paths[ti] {
                        match test_wave_path_overlap(ap, pi, case_insensitive) {
                            WaveOverlap::Equal => {
                                active_blocked[i] = true;
                                push_unique_str(&mut conflicts, format!("active:{ap}({ak},{ti})"));
                            }
                            WaveOverlap::Prefix => {
                                active_blocked[i] = true;
                                push_unique_str(
                                    &mut conflicts,
                                    format!("active:{ap}<->{pi}({ak},{ti})"),
                                );
                            }
                            WaveOverlap::None => {}
                        }
                    }
                }

                if let Some(areads) = active_read_map.get(ak) {
                    for ar in areads {
                        for pi in &task_paths[ti] {
                            match test_wave_path_overlap(pi, ar, case_insensitive) {
                                WaveOverlap::Equal => {
                                    active_blocked[i] = true;
                                    push_unique_str(
                                        &mut conflicts,
                                        format!("active_rw:{pi}({ti}->{ak})"),
                                    );
                                }
                                WaveOverlap::Prefix => {
                                    active_blocked[i] = true;
                                    push_unique_str(
                                        &mut conflicts,
                                        format!("active_rw:{pi}<->{ar}({ti}->{ak})"),
                                    );
                                }
                                WaveOverlap::None => {}
                            }
                        }
                    }
                }

                if let Some(creads) = read_paths.get(ti) {
                    for ap in &active_paths[ak] {
                        for cr in creads {
                            match test_wave_path_overlap(ap, cr, case_insensitive) {
                                WaveOverlap::Equal => {
                                    active_blocked[i] = true;
                                    push_unique_str(
                                        &mut conflicts,
                                        format!("active_rw:{ap}({ak}->{ti})"),
                                    );
                                }
                                WaveOverlap::Prefix => {
                                    active_blocked[i] = true;
                                    push_unique_str(
                                        &mut conflicts,
                                        format!("active_rw:{ap}<->{cr}({ak}->{ti})"),
                                    );
                                }
                                WaveOverlap::None => {}
                            }
                        }
                    }
                }
            }
        }
    }

    let run_dirty_check = check_dirty_scope
        || !ignore_dirty_paths.trim().is_empty()
        || !verified_dirty_paths.trim().is_empty()
        || (partition && !exp_base.is_empty());
    let mut dirty_blocked = vec![false; n_tasks];
    let mut user_dirty_list = Vec::new();
    let mut active_dirty_list = Vec::new();
    let mut verified_dirty_list = Vec::new();
    let mut unexpected_dirty_list = Vec::new();
    let mut dirty_scope_val = "not_checked";
    let mut user_dirty_csv = "none".to_string();
    let mut active_dirty_csv = "none".to_string();
    let mut verified_dirty_csv = "none".to_string();
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
            let is_prot_dirty = is_protected_wave_path(&d)
                || protected_list.iter().any(|prot| {
                    test_wave_path_overlap(&d, prot, case_insensitive) != WaveOverlap::None
                });
            if is_user_dirty {
                user_dirty_list.push(d.clone());
                dirty_entries.push(DirtyEntry {
                    path: d,
                    tag: "USER_DIRTY",
                });
            } else if has_continuous_ctx
                && !is_prot_dirty
                && active_order.iter().any(|ak| {
                    active_paths[ak]
                        .iter()
                        .any(|ap| path_is_within_scope(&d, ap, case_insensitive))
                })
            {
                active_dirty_list.push(d);
            } else if has_continuous_ctx
                && !is_prot_dirty
                && verified_dirty_spec
                    .iter()
                    .any(|vp| path_is_within_scope(&d, vp, case_insensitive))
            {
                verified_dirty_list.push(d);
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
                        push_unique_str(
                            &mut conflicts,
                            format!("dirty:{}({}->{ti})", de.path, de.tag),
                        );
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
        if !active_dirty_list.is_empty() {
            active_dirty_csv = sort_ordinal(active_dirty_list, false).join(",");
        }
        if !verified_dirty_list.is_empty() {
            verified_dirty_csv = sort_ordinal(verified_dirty_list, false).join(",");
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

    let active_count = active_order.len();
    let available_slots = (max_concurrency - active_count as i32).max(0) as usize;

    if !partition {
        if run_dirty_check && !unexpected_dirty_list.is_empty() {
            return Err(fail(
                format!("WAVE_BASE_MISMATCH: unexpected_dirty({unexpected_dirty_csv})"),
                2,
            ));
        }
        if dirty_blocked.iter().any(|&b| b)
            || active_blocked.iter().any(|&b| b)
            || !conflicts.is_empty()
        {
            let sorted_conf = sort_ordinal(conflicts, false).join(", ");
            return Err(fail(format!("WAVE_CONFLICT: {sorted_conf}"), 2));
        }
        if has_continuous_ctx && n_tasks > available_slots {
            return Err(fail(
                format!(
                    "WAVE_CONFLICT: concurrency_saturated(active={active_count},requested={n_tasks},max={max_concurrency})"
                ),
                2,
            ));
        }
        return Ok((
            format!("WAVE_OK: disjoint ({n_tasks} tasks, {total_paths} paths)"),
            0,
        ));
    }

    if has_continuous_ctx {
        let conflicts_empty = conflicts.is_empty();
        let conflicts_csv = if conflicts_empty {
            "none".to_string()
        } else {
            sort_ordinal(conflicts, false).join(",")
        };
        let active_tasks_csv = if active_order.is_empty() {
            "none".to_string()
        } else {
            active_order.join(",")
        };

        let non_dirty_indices: Vec<usize> = (0..n_tasks).filter(|&i| !dirty_blocked[i]).collect();
        let eligible_now: Vec<usize> = (0..n_tasks)
            .filter(|&i| !dirty_blocked[i] && !active_blocked[i])
            .collect();

        let mut waves: Vec<Vec<usize>> = Vec::new();
        let admitted_csv: String;
        let deferred_csv: String;
        let term_line: String;
        let exit_code: i32;

        if run_dirty_check && !unexpected_dirty_list.is_empty() {
            admitted_csv = "none".to_string();
            deferred_csv = "none".to_string();
            term_line = format!("WAVE_BASE_MISMATCH: unexpected_dirty({unexpected_dirty_csv})");
            exit_code = 2;
        } else if non_dirty_indices.is_empty() {
            admitted_csv = "none".to_string();
            deferred_csv = "none".to_string();
            term_line =
                "WAVE_SEQUENTIAL: waves=0 max_parallel=0 reason=dirty_scope_conflict".to_string();
            exit_code = 2;
        } else if available_slots == 0 {
            admitted_csv = "none".to_string();
            deferred_csv = non_dirty_indices
                .iter()
                .map(|&i| task_order[i].as_str())
                .collect::<Vec<_>>()
                .join(",");
            term_line =
                "WAVE_SEQUENTIAL: waves=0 max_parallel=0 reason=concurrency_saturated".to_string();
            exit_code = 2;
        } else if eligible_now.is_empty() {
            admitted_csv = "none".to_string();
            deferred_csv = non_dirty_indices
                .iter()
                .map(|&i| task_order[i].as_str())
                .collect::<Vec<_>>()
                .join(",");
            term_line =
                "WAVE_SEQUENTIAL: waves=0 max_parallel=0 reason=active_worker_conflict".to_string();
            exit_code = 2;
        } else {
            for &i in &eligible_now {
                let mut placed = false;
                for (w_idx, members) in waves.iter_mut().enumerate() {
                    let cap = if w_idx == 0 {
                        available_slots
                    } else {
                        max_concurrency as usize
                    };
                    if members.len() >= cap {
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

            let wave_1_set: HashSet<usize> = waves[0].iter().copied().collect();
            admitted_csv = waves[0]
                .iter()
                .map(|&i| task_order[i].as_str())
                .collect::<Vec<_>>()
                .join(",");
            let deferred_vec: Vec<&str> = non_dirty_indices
                .iter()
                .filter(|&&i| !wave_1_set.contains(&i))
                .map(|&i| task_order[i].as_str())
                .collect();
            deferred_csv = if deferred_vec.is_empty() {
                "none".to_string()
            } else {
                deferred_vec.join(",")
            };

            let w_count = waves.len();
            let max_parallel = waves.iter().map(|w| w.len()).max().unwrap_or(0);
            let mut pair_conflict = false;
            'pair_outer: for ei in 0..eligible_now.len() {
                for ej in (ei + 1)..eligible_now.len() {
                    if has_conflict[eligible_now[ei]][eligible_now[ej]] {
                        pair_conflict = true;
                        break 'pair_outer;
                    }
                }
            }

            exit_code = 0;
            term_line = if w_count == 1 && deferred_csv == "none" && conflicts_empty {
                if waves[0].len() > 1 {
                    format!("WAVE_OK: disjoint ({n_tasks} tasks, {total_paths} paths)")
                } else {
                    "WAVE_SEQUENTIAL: waves=1 max_parallel=1 reason=single_task".to_string()
                }
            } else if max_parallel > 1 {
                format!("WAVE_PARTITIONED: waves={w_count} max_parallel={max_parallel}")
            } else {
                let seq_reason = if available_slots == 1 && eligible_now.len() > 1 {
                    "concurrency_cap"
                } else if active_blocked.iter().any(|&b| b) {
                    "active_worker_conflict"
                } else if dirty_blocked.iter().any(|&b| b) {
                    "dirty_scope_conflict"
                } else if pair_conflict {
                    "path_overlap"
                } else {
                    "single_task"
                };
                format!("WAVE_SEQUENTIAL: waves={w_count} max_parallel=1 reason={seq_reason}")
            };
        }

        let w_count = waves.len();
        let max_parallel = waves.iter().map(|w| w.len()).max().unwrap_or(0);
        let mut lines = Vec::new();
        lines.push(format!("dirty_scope={dirty_scope_val}"));
        lines.push(format!("user_dirty={user_dirty_csv}"));
        lines.push(format!("unexpected_dirty={unexpected_dirty_csv}"));
        lines.push(format!("blocked_tasks={blocked_tasks_csv}"));
        lines.push(format!("wave_count={w_count}"));
        lines.push(format!("max_concurrency={max_concurrency}"));
        lines.push(format!("max_parallel={max_parallel}"));
        lines.push(format!("conflicts={conflicts_csv}"));
        if cfg_exec_mode == ExecutionMode::Isolated {
            lines.push("preferred_isolation=ISOLATED_WRITES".to_string());
        } else if !explicit_conc && cfg_exec_mode == ExecutionMode::Sequential {
            lines.push("execution_mode=sequential".to_string());
        }
        lines.push(format!("active_tasks={active_tasks_csv}"));
        lines.push(format!("active_count={active_count}"));
        lines.push(format!("available_slots={available_slots}"));
        if run_dirty_check {
            lines.push(format!("active_dirty={active_dirty_csv}"));
            lines.push(format!("verified_dirty={verified_dirty_csv}"));
        }
        lines.push(format!("admitted_tasks={admitted_csv}"));
        lines.push(format!("deferred_tasks={deferred_csv}"));

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
                let w_reason = if eligible_now.len() == 1
                    && !active_blocked.iter().any(|&b| b)
                    && !dirty_blocked.iter().any(|&b| b)
                {
                    "single_ready_task"
                } else {
                    let mut bounded = false;
                    for (p_idx, prior) in waves.iter().enumerate().take(w) {
                        let p_cap = if p_idx == 0 {
                            available_slots
                        } else {
                            max_concurrency as usize
                        };
                        if prior.len() == p_cap && prior.iter().all(|&pm| !has_conflict[t][pm]) {
                            bounded = true;
                            break;
                        }
                    }
                    if !bounded
                        && ((w == 0 && available_slots == 1) || max_concurrency == 1)
                        && eligible_now.len() > 1
                        && eligible_now.iter().all(|&u| u == t || !has_conflict[t][u])
                    {
                        bounded = true;
                    }
                    if bounded {
                        "bounded_concurrency"
                    } else if active_blocked.iter().any(|&b| b) && eligible_now.len() == 1 {
                        "active_worker_conflict"
                    } else if dirty_blocked.iter().any(|&b| b) && eligible_now.len() == 1 {
                        "dirty_scope_conflict"
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

        lines.push(term_line);
        return Ok((lines.join("\n"), exit_code));
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
    if cfg_exec_mode == ExecutionMode::Isolated {
        lines.push("preferred_isolation=ISOLATED_WRITES".to_string());
    } else if !explicit_conc && cfg_exec_mode == ExecutionMode::Sequential {
        lines.push("execution_mode=sequential".to_string());
    }

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

#[cfg(test)]
mod tests {
    use super::run;
    use crate::git::run_git;
    use std::fs;

    #[test]
    fn continuous_validation_rejects_bad_inputs() {
        let err = run(
            ".",
            "T2=src/b.rs",
            "",
            "",
            4,
            true,
            "",
            false,
            "",
            "",
            "T1=src/a.rs",
            "",
        )
        .unwrap_err();
        assert_eq!(err.code, 1);
        assert_eq!(
            err.message,
            "WAVE_FAIL: --active-reads requires --active-specs"
        );

        let err_dup = run(
            ".",
            "T1=src/b.rs",
            "",
            "",
            4,
            true,
            "",
            false,
            "",
            "T1=src/a.rs",
            "",
            "",
        )
        .unwrap_err();
        assert_eq!(err_dup.code, 1);
        assert_eq!(
            err_dup.message,
            "WAVE_FAIL: duplicate active task 'T1' in --wave-specs"
        );

        let err_prot = run(
            ".",
            "T2=src/b.rs",
            "",
            "",
            4,
            true,
            "Cargo.lock",
            false,
            "",
            "T1=Cargo.lock",
            "",
            "",
        )
        .unwrap_err();
        assert_eq!(err_prot.code, 1);
        assert_eq!(
            err_prot.message,
            "WAVE_FAIL: --active-specs task 'T1' touches protected path 'Cargo.lock'"
        );

        let err_ar = run(
            ".",
            "T2=src/b.rs",
            "",
            "",
            4,
            true,
            "",
            false,
            "",
            "T1=src/a.rs",
            "T9=src/c.rs",
            "",
        )
        .unwrap_err();
        assert_eq!(err_ar.code, 1);
        assert_eq!(
            err_ar.message,
            "WAVE_FAIL: --active-reads references unknown active task 'T9'"
        );

        let err_vd_active = run(
            ".",
            "T2=src/b.rs",
            "",
            "",
            4,
            true,
            "",
            false,
            "",
            "T1=src/a.rs",
            "",
            "src/a.rs",
        )
        .unwrap_err();
        assert_eq!(err_vd_active.code, 1);
        assert_eq!(
            err_vd_active.message,
            "WAVE_FAIL: --verified-dirty-paths overlaps active task 'T1' path 'src/a.rs'"
        );
    }

    #[test]
    fn continuous_admission_slot_accounting_and_dirty_classification() {
        let tmp = std::env::temp_dir().join(format!(
            "b3-wave-cont-test-{}-{}",
            std::process::id(),
            crate::fs::next_tmp_suffix()
        ));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(tmp.join("src")).expect("mkdir");
        fs::write(tmp.join("src/active.rs"), "fn a() {}\n").expect("write");
        fs::write(tmp.join("src/verified.rs"), "fn v() {}\n").expect("write");
        fs::write(tmp.join("src/c.rs"), "fn c() {}\n").expect("write");
        fs::write(tmp.join("src/d.rs"), "fn d() {}\n").expect("write");

        let no_env: [(&str, &str); 0] = [];
        assert_eq!(
            run_git(&tmp, &["init"], &no_env, None).unwrap().exit_code,
            0
        );
        assert_eq!(
            run_git(
                &tmp,
                &["config", "user.email", "t@example.com"],
                &no_env,
                None
            )
            .unwrap()
            .exit_code,
            0
        );
        assert_eq!(
            run_git(&tmp, &["config", "user.name", "Test"], &no_env, None)
                .unwrap()
                .exit_code,
            0
        );
        assert_eq!(
            run_git(&tmp, &["add", "."], &no_env, None)
                .unwrap()
                .exit_code,
            0
        );
        assert_eq!(
            run_git(&tmp, &["commit", "-m", "init"], &no_env, None)
                .unwrap()
                .exit_code,
            0
        );

        // Simulate active worker E modifying src/active.rs and verified worker A having modified src/verified.rs
        fs::write(tmp.join("src/active.rs"), "fn a() { /* wip */ }\n").expect("write");
        fs::write(tmp.join("src/verified.rs"), "fn v() { /* done */ }\n").expect("write");
        let root_str = tmp.to_string_lossy().into_owned();

        // Candidate C reads src/verified.rs (ALLOWED!) and writes src/c.rs;
        // Candidate F writes src/active.rs (active_blocked -> deferred);
        // Candidate G writes src/d.rs (deferred by slot cap when max_concurrency=2, active=1 -> available_slots=1).
        let (out, code) = run(
            &root_str,
            "C=src/c.rs;F=src/active.rs;G=src/d.rs",
            "C=src/verified.rs",
            "",
            2,
            true,
            "",
            true,
            "",
            "E=src/active.rs",
            "",
            "src/verified.rs",
        )
        .expect("run partition");
        assert_eq!(code, 0, "out={out}");
        assert!(out.contains("active_tasks=E\n"), "out={out}");
        assert!(out.contains("active_count=1\n"), "out={out}");
        assert!(out.contains("available_slots=1\n"), "out={out}");
        assert!(out.contains("active_dirty=src/active.rs\n"), "out={out}");
        assert!(
            out.contains("verified_dirty=src/verified.rs\n"),
            "out={out}"
        );
        assert!(out.contains("admitted_tasks=C\n"), "out={out}");
        assert!(out.contains("deferred_tasks=F,G\n"), "out={out}");
        assert!(
            out.contains("conflicts=active:src/active.rs(E,F)\n"),
            "out={out}"
        );
        assert!(
            out.contains("WAVE_SEQUENTIAL: waves=2 max_parallel=1 reason=concurrency_cap"),
            "out={out}"
        );

        // Candidate overwriting uncommitted verified file is deferred with verified_uncommitted
        let (out_vu, code_vu) = run(
            &root_str,
            "H=src/verified.rs",
            "",
            "",
            3,
            true,
            "",
            true,
            "",
            "E=src/active.rs",
            "",
            "src/verified.rs",
        )
        .expect("run verified_uncommitted");
        assert_eq!(code_vu, 2, "out={out_vu}");
        assert!(
            out_vu.contains("conflicts=verified_uncommitted:src/verified.rs(H)\n"),
            "out={out_vu}"
        );
        assert!(out_vu.contains("admitted_tasks=none\n"), "out={out_vu}");
        assert!(out_vu.contains("deferred_tasks=H\n"), "out={out_vu}");
        assert!(
            out_vu
                .contains("WAVE_SEQUENTIAL: waves=0 max_parallel=0 reason=active_worker_conflict"),
            "out={out_vu}"
        );

        let _ = fs::remove_dir_all(&tmp);
    }
}
