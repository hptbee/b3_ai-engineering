use std::collections::{HashMap, HashSet};
use std::path::Path;

use crate::error::{fail, B3Error};
use crate::fs::{
    normalize_repo_root, sort_ordinal, split_csv_list, split_path_csv_checked, test_binary_file,
    test_test_path,
};
use crate::git::{resolve_scope_target_and_base, run_git};
use crate::guard::scope::{
    collect_scope_data, eval_risk_for_subset, get_raw_module_group, get_tshirt_size,
    test_contract_path, test_doc_or_asset_path, test_generated_code_path,
};
use crate::guard::wave::resolve_concurrency;

#[derive(Debug, Clone)]
pub(crate) struct ReviewUnit {
    pub unit_id: String,
    pub group: String,
    pub members: Vec<String>,
    pub top_seg: String,
    pub files: Vec<String>,
    pub files_cnt: usize,
    pub lines_cnt: usize,
    pub risk: &'static str,
    pub specialists: String,
    pub signals: String,
    pub files_csv: String,
    pub feature_tokens: Vec<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct InventoryResult {
    pub is_empty: bool,
    pub partition_error: Option<String>,
    pub size_class: &'static str,
    pub files_count: usize,
    pub lines_count: usize,
    pub risk_level: &'static str,
    pub risk_signals: String,
    pub recommended_specialists: String,
    pub l1_specialists: String,
    pub l1_skip_rationale: &'static str,
    pub change_types: String,
    pub contract_files: Vec<String>,
    pub generated_files: Vec<String>,
    pub test_files: Vec<String>,
    pub noise_files: Vec<String>,
    pub review_files: Vec<String>,
    pub split_recommended: bool,
    pub max_concurrency: i32,
    pub units: Vec<ReviewUnit>,
}

#[derive(Debug, Clone)]
struct Bucket {
    group: String,
    members: Vec<String>,
    files: Vec<String>,
    feature_tokens: Vec<String>,
}

pub(crate) fn is_oversized_unit(files_cnt: usize, lines_cnt: usize) -> bool {
    lines_cnt > 5000 || (files_cnt > 100 && lines_cnt > 1000)
}

fn get_unit_metrics(
    grp: Bucket,
    file_lines: &HashMap<String, usize>,
    file_signals: &HashMap<String, Vec<String>>,
) -> ReviewUnit {
    let files_sorted = sort_ordinal(grp.files, false);
    let mut lines_sum = 0usize;
    for f in &files_sorted {
        if let Some(&cnt) = file_lines.get(f) {
            lines_sum += cnt;
        }
    }
    let ev = eval_risk_for_subset(&files_sorted, Some(file_signals), Some(file_lines));
    let top_seg = if grp.group == "root" || grp.group.starts_with('(') {
        grp.group.clone()
    } else {
        grp.group.split('/').next().unwrap_or("").to_string()
    };
    let files_csv = files_sorted.join(",");
    let files_cnt = files_sorted.len();
    ReviewUnit {
        unit_id: String::new(),
        group: grp.group,
        members: grp.members,
        top_seg,
        files: files_sorted,
        files_cnt,
        lines_cnt: lines_sum,
        risk: ev.risk_level,
        specialists: ev.recommended_specialists,
        signals: ev.risk_signals,
        files_csv,
        feature_tokens: grp.feature_tokens,
    }
}

fn push_unique_str(vec: &mut Vec<String>, val: String) {
    if !vec.iter().any(|x| x == &val) {
        vec.push(val);
    }
}

fn get_file_feature_token(path_val: &str) -> String {
    let leaf = path_val.rsplit('/').next().unwrap_or("");
    let mut stem = if let Some(dot) = leaf.rfind('.') {
        &leaf[..dot]
    } else {
        leaf
    };
    let stem_low = stem.to_ascii_lowercase();
    for sfx in [".test", ".spec", ".generated", ".pb", ".g", ".designer"] {
        if stem_low.ends_with(sfx) {
            stem = &stem[..stem.len() - sfx.len()];
            break;
        }
    }

    let mut spaced = String::with_capacity(stem.len() + 8);
    let chars: Vec<char> = stem.chars().collect();
    for (idx, &ch) in chars.iter().enumerate() {
        let mapped = if ch == '-' || ch == '_' || ch == '.' {
            ' '
        } else {
            ch
        };
        if idx > 0 && mapped.is_ascii_uppercase() {
            let prev = spaced.chars().last().unwrap_or(' ');
            if prev.is_ascii_lowercase() || prev.is_ascii_digit() {
                spaced.push(' ');
            }
        }
        spaced.push(mapped);
    }

    let raw_words: Vec<String> = spaced
        .to_lowercase()
        .split_whitespace()
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect();
    if raw_words.is_empty() {
        return "misc".to_string();
    }

    const LAYER_SET: &[&str] = &[
        "controller",
        "controllers",
        "service",
        "services",
        "repository",
        "repositories",
        "repo",
        "handler",
        "handlers",
        "model",
        "models",
        "types",
        "type",
        "schema",
        "schemas",
        "utils",
        "util",
        "helper",
        "helpers",
        "view",
        "views",
        "component",
        "components",
        "slice",
        "store",
        "routes",
        "route",
        "router",
        "api",
        "client",
        "impl",
        "dto",
        "dtos",
        "spec",
        "test",
    ];
    let mut end = raw_words.len();
    while end > 1 && LAYER_SET.contains(&raw_words[end - 1].as_str()) {
        end -= 1;
    }
    raw_words[..end].join("-")
}

fn get_stem_key_no_ext(path_val: &str) -> String {
    let low = path_val.to_ascii_lowercase();
    for ext in [
        ".tsx", ".ts", ".jsx", ".js", ".mjs", ".cjs", ".py", ".go", ".rs", ".cpp", ".hpp", ".c",
        ".h", ".cs", ".java", ".proto", ".graphql", ".gql",
    ] {
        if low.ends_with(ext) {
            return low[..low.len() - ext.len()].to_string();
        }
    }
    low
}

fn resolve_rel_import_target(from_file: &str, rel_spec: &str) -> String {
    let replaced = rel_spec.replace('\\', "/");
    let before_qh = replaced.split(['?', '#']).next().unwrap_or("");
    let clean_spec = before_qh.trim();
    if clean_spec.is_empty() || !(clean_spec.starts_with("./") || clean_spec.starts_with("../")) {
        return String::new();
    }
    let mut stk: Vec<&str> = Vec::new();
    if let Some(slash_idx) = from_file.rfind('/') {
        if slash_idx > 0 {
            for dp in from_file[..slash_idx].split('/') {
                if !dp.is_empty() {
                    stk.push(dp);
                }
            }
        }
    }
    for seg in clean_spec.split('/') {
        if seg.is_empty() || seg == "." {
            continue;
        }
        if seg == ".." {
            if stk.pop().is_none() {
                return String::new();
            }
        } else {
            stk.push(seg);
        }
    }
    if stk.is_empty() {
        return String::new();
    }
    get_stem_key_no_ext(&stk.join("/"))
}

fn extract_rel_import_specs(line: &str) -> Vec<&str> {
    let bytes = line.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'"' || bytes[i] == b'\'' {
            let start = i + 1;
            if line[start..].starts_with("./") || line[start..].starts_with("../") {
                let mut end = start;
                while end < bytes.len() {
                    let b = bytes[end];
                    if b == b'"' || b == b'\'' || b == b'\r' || b == b'\n' {
                        break;
                    }
                    end += 1;
                }
                if end < bytes.len() && (bytes[end] == b'"' || bytes[end] == b'\'') && end > start {
                    out.push(&line[start..end]);
                    i = end + 1;
                    continue;
                }
            }
        }
        i += 1;
    }
    out
}

fn get_source_content_lines(root: &Path, target_commit_sha: &str, rel_path: &str) -> Vec<String> {
    if !target_commit_sha.is_empty() {
        let spec = format!("{target_commit_sha}:{rel_path}");
        let no_env: [(&str, &str); 0] = [];
        let Ok(res) = run_git(root, &["show", &spec], &no_env, None) else {
            return Vec::new();
        };
        if res.exit_code != 0 {
            return Vec::new();
        }
        return String::from_utf8_lossy(&res.stdout)
            .split('\n')
            .map(|l| l.strip_suffix('\r').unwrap_or(l).to_string())
            .collect();
    }
    let full = root.join(rel_path.replace('/', std::path::MAIN_SEPARATOR_STR));
    if !full.is_file() || test_binary_file(&full) {
        return Vec::new();
    }
    let Ok(raw) = std::fs::read(&full) else {
        return Vec::new();
    };
    String::from_utf8_lossy(&raw)
        .split('\n')
        .map(|l| l.strip_suffix('\r').unwrap_or(l).to_string())
        .collect()
}

fn attach_tests_to_sub_buckets(
    parent_group: &str,
    sub_buckets: &mut Vec<Bucket>,
    test_files: &[String],
) {
    let mut extra_tests = Vec::new();
    for tf in test_files {
        let mut assigned_idx: Option<usize> = None;
        if parent_group != "root" {
            let pfx = format!("{parent_group}/");
            if let Some(t_rem) = tf.strip_prefix(&pfx) {
                if let Some((seg0, _)) = t_rem.split_once('/') {
                    let t_seg = format!("{parent_group}/{seg0}");
                    for (i, sb) in sub_buckets.iter().enumerate() {
                        if sb.group == t_seg {
                            assigned_idx = Some(i);
                            break;
                        }
                    }
                }
            }
        }
        if assigned_idx.is_none() {
            let tf_leaf = tf.rsplit('/').next().unwrap_or("");
            let tf_stem_raw = if let Some(dot) = tf_leaf.rfind('.') {
                &tf_leaf[..dot]
            } else {
                tf_leaf
            };
            let tf_low = tf_stem_raw.to_ascii_lowercase();
            let tf_stem = tf_low
                .strip_suffix(".test")
                .or_else(|| tf_low.strip_suffix(".spec"))
                .unwrap_or(&tf_low);

            let mut matched_idxs = Vec::new();
            for (i, sb) in sub_buckets.iter().enumerate() {
                let mut hit = false;
                for rf in &sb.files {
                    let rf_leaf = rf.rsplit('/').next().unwrap_or("");
                    let rf_no_ext = if let Some(dot) = rf_leaf.rfind('.') {
                        &rf_leaf[..dot]
                    } else {
                        rf_leaf
                    };
                    if rf_no_ext.to_ascii_lowercase() == tf_stem {
                        hit = true;
                        break;
                    }
                }
                if hit {
                    matched_idxs.push(i);
                }
            }
            if matched_idxs.is_empty() {
                let t_feat = get_file_feature_token(tf);
                for (i, sb) in sub_buckets.iter().enumerate() {
                    if sb.feature_tokens.iter().any(|x| x == &t_feat) {
                        matched_idxs.push(i);
                    }
                }
            }
            if matched_idxs.len() == 1 {
                assigned_idx = Some(matched_idxs[0]);
            }
        }
        if let Some(idx) = assigned_idx {
            sub_buckets[idx].files.push(tf.clone());
        } else {
            extra_tests.push(tf.clone());
        }
    }

    if !extra_tests.is_empty() {
        let t_grp = if parent_group == "root" {
            "(tests)".to_string()
        } else {
            format!("{parent_group}/(tests)")
        };
        sub_buckets.push(Bucket {
            group: t_grp.clone(),
            members: vec![t_grp],
            files: extra_tests,
            feature_tokens: Vec::new(),
        });
    }
}

fn coalesce_tiny_sub_buckets(
    sub_buckets: Vec<Bucket>,
    file_lines: &HashMap<String, usize>,
    file_signals: &HashMap<String, Vec<String>>,
) -> Vec<ReviewUnit> {
    let mut cur: Vec<ReviewUnit> = sub_buckets
        .into_iter()
        .map(|sb| get_unit_metrics(sb, file_lines, file_signals))
        .collect();
    while cur.len() > 4 {
        let mut tiny_idx: Option<usize> = None;
        let mut tiny_lines = usize::MAX;
        for (i, u) in cur.iter().enumerate() {
            let has_contract = u.files.iter().any(|f| test_contract_path(f));
            if u.files_cnt < 2
                && u.lines_cnt < 200
                && u.risk != "CRITICAL"
                && !has_contract
                && u.lines_cnt < tiny_lines
            {
                tiny_lines = u.lines_cnt;
                tiny_idx = Some(i);
            }
        }
        let Some(t_idx) = tiny_idx else {
            break;
        };
        let mut best_target: Option<usize> = None;
        let mut best_score = i64::MAX;
        for (j, cand) in cur.iter().enumerate() {
            if j == t_idx {
                continue;
            }
            let comb_files = cur[t_idx].files_cnt + cand.files_cnt;
            let comb_lines = cur[t_idx].lines_cnt + cand.lines_cnt;
            if is_oversized_unit(comb_files, comb_lines) {
                continue;
            }
            let mut score = comb_lines as i64;
            if cand.risk != cur[t_idx].risk {
                score += 100_000;
            }
            if cand.risk == "CRITICAL" {
                score += 500_000;
            }
            if score < best_score {
                best_score = score;
                best_target = Some(j);
            }
        }
        let Some(b_idx) = best_target else {
            break;
        };
        let hi = t_idx.max(b_idx);
        let lo = t_idx.min(b_idx);
        let u_hi = cur.remove(hi);
        let u_lo = cur.remove(lo);
        let (tu, tgt) = if t_idx > b_idx {
            (u_hi, u_lo)
        } else {
            (u_lo, u_hi)
        };

        let mut merged_files = Vec::with_capacity(tu.files.len() + tgt.files.len());
        merged_files.extend(tu.files);
        merged_files.extend(tgt.files);

        let mut mems = Vec::new();
        for m in tu.members.into_iter().chain(tgt.members) {
            push_unique_str(&mut mems, m);
        }
        let m_group = if tgt.group.len() >= tu.group.len() {
            tgt.group
        } else {
            tu.group
        };
        let mut feats = Vec::new();
        for ft in tu.feature_tokens.into_iter().chain(tgt.feature_tokens) {
            push_unique_str(&mut feats, ft);
        }

        let merged = get_unit_metrics(
            Bucket {
                group: m_group,
                members: mems,
                files: merged_files,
                feature_tokens: feats,
            },
            file_lines,
            file_signals,
        );
        cur.push(merged);
    }
    cur
}

fn expand_oversized_unit(
    root: &Path,
    target_commit_sha: &str,
    unit: &ReviewUnit,
    file_lines: &HashMap<String, usize>,
    file_signals: &HashMap<String, Vec<String>>,
    depth: usize,
) -> Result<Vec<ReviewUnit>, String> {
    for f in &unit.files {
        let fl = file_lines.get(f).copied().unwrap_or(0);
        if fl > 5000 {
            return Err(format!(
                "PARTITION_INCOMPLETE: single file '{f}' ({fl}L) exceeds max unit bound (5000L); refactor or split PR"
            ));
        }
    }

    let mut non_test = Vec::new();
    let mut tests = Vec::new();
    for f in &unit.files {
        if test_test_path(f) {
            tests.push(f.clone());
        } else {
            non_test.push(f.clone());
        }
    }
    if non_test.is_empty() {
        std::mem::swap(&mut non_test, &mut tests);
    }

    let raw_group = &unit.group;
    let base_group = raw_group
        .strip_suffix("/(root)")
        .or_else(|| raw_group.strip_suffix("/(contracts)"))
        .unwrap_or(raw_group);
    let prefix = if base_group == "root" || base_group.starts_with('(') {
        String::new()
    } else {
        format!("{base_group}/")
    };

    if depth < 4 {
        let mut dir_map: HashMap<String, Vec<String>> = HashMap::new();
        let mut has_deeper_dir = false;
        for f in &non_test {
            let rem = if !prefix.is_empty() {
                f.strip_prefix(&prefix).unwrap_or("")
            } else {
                f.as_str()
            };
            let child_key = if let Some((seg0, _)) = rem.split_once('/') {
                has_deeper_dir = true;
                if prefix.is_empty() {
                    seg0.to_string()
                } else {
                    format!("{prefix}{seg0}")
                }
            } else if test_contract_path(f) {
                if base_group == "root" {
                    "(contracts)".to_string()
                } else {
                    format!("{base_group}/(contracts)")
                }
            } else if base_group == "root" {
                "(root)".to_string()
            } else {
                format!("{base_group}/(root)")
            };
            dir_map.entry(child_key).or_default().push(f.clone());
        }

        if has_deeper_dir && dir_map.len() >= 2 {
            let mut sub_buckets = Vec::new();
            for k in sort_ordinal(dir_map.keys().cloned(), false) {
                let files = dir_map.remove(&k).unwrap_or_default();
                let mut fts = Vec::new();
                for rf in &files {
                    push_unique_str(&mut fts, get_file_feature_token(rf));
                }
                sub_buckets.push(Bucket {
                    group: k.clone(),
                    members: vec![k],
                    files,
                    feature_tokens: fts,
                });
            }
            attach_tests_to_sub_buckets(base_group, &mut sub_buckets, &tests);
            let coalesced = coalesce_tiny_sub_buckets(sub_buckets, file_lines, file_signals);
            let mut out_units = Vec::new();
            for cu in coalesced {
                if is_oversized_unit(cu.files_cnt, cu.lines_cnt) {
                    let sub_res = expand_oversized_unit(
                        root,
                        target_commit_sha,
                        &cu,
                        file_lines,
                        file_signals,
                        depth + 1,
                    )?;
                    out_units.extend(sub_res);
                } else {
                    out_units.push(cu);
                }
            }
            return Ok(out_units);
        }
    }

    // Boundary 2: contract separation + feature token + local relative imports connected components
    let mut contracts = Vec::new();
    let mut regular = Vec::new();
    for f in non_test {
        if test_contract_path(&f) {
            contracts.push(f);
        } else {
            regular.push(f);
        }
    }

    let mut b2_buckets = Vec::new();
    if !contracts.is_empty() && !regular.is_empty() {
        let c_grp = if base_group == "root" || base_group.starts_with('(') {
            "(contracts)".to_string()
        } else {
            format!("{base_group}/(contracts)")
        };
        b2_buckets.push(Bucket {
            group: c_grp.clone(),
            members: vec![c_grp],
            files: contracts,
            feature_tokens: vec!["contracts".to_string()],
        });
    } else if !contracts.is_empty() {
        regular.extend(contracts);
    }

    let n = regular.len();
    if n > 0 {
        let mut parent: Vec<usize> = (0..n).collect();
        let mut feats = Vec::with_capacity(n);
        let mut file_exts = Vec::with_capacity(n);
        let mut stem_map: HashMap<String, usize> = HashMap::new();
        let mut feat_first_idx: HashMap<String, usize> = HashMap::new();

        for (i, rf) in regular.iter().enumerate() {
            feats.push(get_file_feature_token(rf));
            let rf_leaf = rf.rsplit('/').next().unwrap_or("");
            let ext = match rf_leaf.rfind('.') {
                Some(dot_pos) if dot_pos + 1 < rf_leaf.len() => {
                    rf_leaf[dot_pos + 1..].to_ascii_lowercase()
                }
                _ => "noext".to_string(),
            };
            file_exts.push(ext);
            let sk = get_stem_key_no_ext(rf);
            stem_map.entry(sk.clone()).or_insert(i);
            if let Some(dir_stem) = sk.strip_suffix("/index") {
                if !dir_stem.is_empty() {
                    stem_map.entry(dir_stem.to_string()).or_insert(i);
                }
            }
        }

        fn uf_find(parent: &mut [usize], mut x: usize) -> usize {
            while parent[x] != x {
                parent[x] = parent[parent[x]];
                x = parent[x];
            }
            x
        }
        fn uf_union(parent: &mut [usize], a: usize, b: usize) {
            let ra = uf_find(parent, a);
            let rb = uf_find(parent, b);
            if ra != rb {
                if ra < rb {
                    parent[rb] = ra;
                } else {
                    parent[ra] = rb;
                }
            }
        }

        let mut imp_edges: Vec<(usize, usize)> = Vec::new();
        for (i, rf) in regular.iter().enumerate() {
            let ft = &feats[i];
            if let Some(&first_i) = feat_first_idx.get(ft) {
                uf_union(&mut parent, first_i, i);
            } else {
                feat_first_idx.insert(ft.clone(), i);
            }
            for ln in get_source_content_lines(root, target_commit_sha, rf) {
                for raw_spec in extract_rel_import_specs(&ln) {
                    let tgt_stem = resolve_rel_import_target(rf, raw_spec);
                    if !tgt_stem.is_empty() {
                        if let Some(&t_idx) = stem_map.get(&tgt_stem) {
                            uf_union(&mut parent, i, t_idx);
                            imp_edges.push((i, t_idx));
                        }
                    }
                }
            }
        }

        let mut comp_has_cross_ext: HashSet<usize> = HashSet::new();
        for (a, b) in imp_edges {
            if file_exts[a] != file_exts[b] {
                let r_ed = uf_find(&mut parent, a);
                comp_has_cross_ext.insert(r_ed);
            }
        }

        let mut comp_files: HashMap<usize, Vec<String>> = HashMap::new();
        let mut comp_idxs: HashMap<usize, Vec<usize>> = HashMap::new();
        let mut comp_feats: HashMap<usize, Vec<String>> = HashMap::new();
        for i in 0..n {
            let r_idx = uf_find(&mut parent, i);
            comp_files
                .entry(r_idx)
                .or_default()
                .push(regular[i].clone());
            comp_idxs.entry(r_idx).or_default().push(i);
            let cf = comp_feats.entry(r_idx).or_default();
            push_unique_str(cf, feats[i].clone());
        }

        let mut roots: Vec<usize> = comp_files.keys().copied().collect();
        roots.sort_unstable();
        for r_key in roots {
            let sorted_ft = sort_ordinal(comp_feats.remove(&r_key).unwrap_or_default(), false);
            let ft_label = sorted_ft.first().cloned().unwrap_or_default();
            let sub_grp = if base_group == "root" || base_group.starts_with('(') {
                ft_label
            } else {
                format!("{base_group}/{ft_label}")
            };
            let c_list = comp_files.remove(&r_key).unwrap_or_default();
            let c_lines: usize = c_list
                .iter()
                .map(|f| file_lines.get(f).copied().unwrap_or(0))
                .sum();
            if is_oversized_unit(c_list.len(), c_lines)
                && c_list.len() >= 2
                && !comp_has_cross_ext.contains(&r_key)
            {
                let mut ext_map: HashMap<String, Vec<String>> = HashMap::new();
                for &idx_item in comp_idxs.get(&r_key).into_iter().flatten() {
                    ext_map
                        .entry(file_exts[idx_item].clone())
                        .or_default()
                        .push(regular[idx_item].clone());
                }
                if ext_map.len() >= 2 {
                    for ext_k in sort_ordinal(ext_map.keys().cloned(), false) {
                        let ext_sub_grp = format!("{sub_grp}({ext_k})");
                        b2_buckets.push(Bucket {
                            group: ext_sub_grp.clone(),
                            members: vec![ext_sub_grp],
                            files: ext_map.remove(&ext_k).unwrap_or_default(),
                            feature_tokens: sorted_ft.clone(),
                        });
                    }
                    continue;
                }
            }
            b2_buckets.push(Bucket {
                group: sub_grp.clone(),
                members: vec![sub_grp],
                files: c_list,
                feature_tokens: sorted_ft,
            });
        }
    }

    if b2_buckets.len() >= 2 {
        attach_tests_to_sub_buckets(base_group, &mut b2_buckets, &tests);
        let coalesced = coalesce_tiny_sub_buckets(b2_buckets, file_lines, file_signals);
        for cu in &coalesced {
            if is_oversized_unit(cu.files_cnt, cu.lines_cnt) {
                return Err(format!(
                    "PARTITION_INCOMPLETE: oversized unit '{}' ({}f, {}L) cannot be cohesively partitioned without arbitrary LOC splitting",
                    cu.group, cu.files_cnt, cu.lines_cnt
                ));
            }
        }
        return Ok(coalesced);
    }

    Err(format!(
        "PARTITION_INCOMPLETE: oversized unit '{raw_group}' ({}f, {}L) cannot be cohesively partitioned without arbitrary LOC splitting",
        unit.files_cnt, unit.lines_cnt
    ))
}

fn merge_cohesive_units_to_cap(
    units: &mut Vec<ReviewUnit>,
    file_lines: &HashMap<String, usize>,
    file_signals: &HashMap<String, Vec<String>>,
    size_class: &str,
) -> Result<(), String> {
    while units.len() > 4 {
        let mut best_pair: Option<(usize, usize)> = None;
        let mut best_key: Option<(usize, usize, usize, usize, usize, String, String)> = None;

        for i in 0..units.len() {
            for j in (i + 1)..units.len() {
                let ui = &units[i];
                let uj = &units[j];
                let c_files = ui.files_cnt + uj.files_cnt;
                let c_lines = ui.lines_cnt + uj.lines_cnt;
                if is_oversized_unit(c_files, c_lines) {
                    continue;
                }
                let d_top = usize::from(ui.top_seg != uj.top_seg);
                let d_crit = usize::from((ui.risk == "CRITICAL") != (uj.risk == "CRITICAL"));
                let d_risk = usize::from(ui.risk != uj.risk);
                let (g_a, g_b) = if ui.group <= uj.group {
                    (ui.group.clone(), uj.group.clone())
                } else {
                    (uj.group.clone(), ui.group.clone())
                };
                let key = (d_top, d_crit, d_risk, c_lines, c_files, g_a, g_b);
                let is_better = match &best_key {
                    None => true,
                    Some(bk) => key < *bk,
                };
                if is_better {
                    best_key = Some(key);
                    best_pair = Some((i, j));
                }
            }
        }

        let Some((best_i, best_j)) = best_pair else {
            return Err(format!(
                "PARTITION_INCOMPLETE: cannot bound {size_class} PR to <= 4 cohesive units without exceeding unit bounds"
            ));
        };
        let ub = units.remove(best_j);
        let ua = units.remove(best_i);

        let mut m_files = Vec::with_capacity(ua.files.len() + ub.files.len());
        m_files.extend(ua.files);
        m_files.extend(ub.files);
        let mems = sort_ordinal(ua.members.into_iter().chain(ub.members), false);
        let m_group = if mems.len() == 2 {
            format!("{}+{}", mems[0], mems[1])
        } else {
            format!("{}+{}more", mems[0], mems.len() - 1)
        };
        let mut m_feats = Vec::new();
        for ft in ua.feature_tokens.into_iter().chain(ub.feature_tokens) {
            push_unique_str(&mut m_feats, ft);
        }
        let merged = get_unit_metrics(
            Bucket {
                group: m_group,
                members: mems,
                files: m_files,
                feature_tokens: m_feats,
            },
            file_lines,
            file_signals,
        );
        units.push(merged);
    }
    Ok(())
}

fn match_test_group_token(path_val: &str) -> Option<&str> {
    let mut parts = path_val.split('/');
    if let Some(first) = parts.next() {
        if matches!(first, "test" | "tests" | "__tests__") {
            if let Some(second) = parts.next() {
                if !second.is_empty() && parts.next().is_some() {
                    return Some(second);
                }
            }
        }
    }
    let leaf = path_val.rsplit('/').next().unwrap_or("");
    let no_ext = leaf.rsplit_once('.')?.0;
    no_ext
        .strip_suffix(".test")
        .or_else(|| no_ext.strip_suffix(".spec"))
        .filter(|tok| !tok.is_empty())
}

fn build_unit_assignments(
    root: &Path,
    target_commit_sha: &str,
    review_files: &[String],
    file_lines: &HashMap<String, usize>,
    file_signals: &HashMap<String, Vec<String>>,
    size_class: &str,
) -> Result<Vec<ReviewUnit>, String> {
    let mut groups_map: HashMap<String, Vec<String>> = HashMap::new();
    let mut non_test_groups: HashSet<String> = HashSet::new();
    for f in review_files {
        if test_test_path(f) {
            continue;
        }
        let g = get_raw_module_group(f);
        non_test_groups.insert(g.clone());
        groups_map.entry(g).or_default().push(f.clone());
    }

    let active_nt_keys = sort_ordinal(non_test_groups.iter().cloned(), false);
    for f in review_files {
        if !test_test_path(f) {
            continue;
        }
        let g = get_raw_module_group(f);
        let mut assigned = g.clone();
        if !non_test_groups.contains(&g) {
            if let Some(token) = match_test_group_token(f) {
                let sfx = format!("/{token}");
                let matches_nt: Vec<&String> = active_nt_keys
                    .iter()
                    .filter(|k| k.as_str() == token || k.ends_with(&sfx))
                    .collect();
                if matches_nt.len() == 1 {
                    assigned = matches_nt[0].clone();
                }
            }
        }
        groups_map.entry(assigned).or_default().push(f.clone());
    }

    let mut work_units = Vec::new();
    for grp in sort_ordinal(groups_map.keys().cloned(), false) {
        let files = groups_map.remove(&grp).unwrap_or_default();
        let u_raw = get_unit_metrics(
            Bucket {
                group: grp.clone(),
                members: vec![grp],
                files,
                feature_tokens: Vec::new(),
            },
            file_lines,
            file_signals,
        );
        if is_oversized_unit(u_raw.files_cnt, u_raw.lines_cnt) {
            let expanded = expand_oversized_unit(
                root,
                target_commit_sha,
                &u_raw,
                file_lines,
                file_signals,
                0,
            )?;
            work_units.extend(expanded);
        } else {
            work_units.push(u_raw);
        }
    }

    if matches!(size_class, "L" | "XL") && work_units.len() > 4 {
        merge_cohesive_units_to_cap(&mut work_units, file_lines, file_signals, size_class)?;
    }

    work_units.sort_by(|a, b| {
        let fa = a.files.first().map(|s| s.as_str()).unwrap_or("");
        let fb = b.files.first().map(|s| s.as_str()).unwrap_or("");
        a.group.cmp(&b.group).then_with(|| fa.cmp(fb))
    });

    for (i, unit) in work_units.iter_mut().enumerate() {
        unit.unit_id = format!("U{:02}", i + 1);
    }
    Ok(work_units)
}

pub(crate) fn eval_level1_dispatch(
    contract_files: &[String],
    recommended_specialists: &str,
    risk_level: &str,
    review_files: &[String],
) -> (String, &'static str) {
    let rec_arr = if !recommended_specialists.is_empty() && recommended_specialists != "none" {
        split_csv_list(recommended_specialists)
    } else {
        Vec::new()
    };
    let mut l1 = Vec::new();
    if !contract_files.is_empty() || rec_arr.iter().any(|s| s == "b3-architecture-reviewer") {
        l1.push("b3-architecture-reviewer".to_string());
    }
    if rec_arr.iter().any(|s| s == "b3-security-reviewer") {
        push_unique_str(&mut l1, "b3-security-reviewer".to_string());
    }
    if rec_arr.iter().any(|s| s == "b3-performance-reviewer") {
        push_unique_str(&mut l1, "b3-performance-reviewer".to_string());
    }
    let l1_out = if l1.is_empty() {
        "none".to_string()
    } else {
        sort_ordinal(l1, false).join(",")
    };
    let skip_rat = if l1_out == "none" {
        let all_docs =
            !review_files.is_empty() && review_files.iter().all(|f| test_doc_or_asset_path(f));
        if all_docs {
            "low-risk-docs-only"
        } else if risk_level == "LOW" {
            "low-risk-isolated-no-contracts"
        } else {
            "no-contract-or-arch-signals"
        }
    } else {
        "none"
    };
    (l1_out, skip_rat)
}

pub(crate) fn build_inventory(
    root: &Path,
    resolved_base: &str,
    target_commit_sha: &str,
    ignored: &[String],
    max_concurrency: i32,
    fail_prefix: &str,
) -> Result<InventoryResult, B3Error> {
    let resolved_conc = resolve_concurrency(max_concurrency, fail_prefix)?;
    let scope = collect_scope_data(root, resolved_base, target_commit_sha, ignored, fail_prefix)?;
    if scope.review_files.is_empty() && scope.noise_files.is_empty() {
        return Ok(InventoryResult {
            is_empty: true,
            partition_error: None,
            size_class: "NOISE_ONLY",
            files_count: 0,
            lines_count: 0,
            risk_level: "LOW",
            risk_signals: "none".to_string(),
            recommended_specialists: "none".to_string(),
            l1_specialists: "none".to_string(),
            l1_skip_rationale: "none",
            change_types: String::new(),
            contract_files: Vec::new(),
            generated_files: Vec::new(),
            test_files: Vec::new(),
            noise_files: Vec::new(),
            review_files: Vec::new(),
            split_recommended: false,
            max_concurrency: resolved_conc,
            units: Vec::new(),
        });
    }

    let size_class = get_tshirt_size(scope.review_files.len(), scope.total_lines);
    let risk_all_set = if !scope.review_files.is_empty() {
        &scope.review_files
    } else {
        &scope.noise_files
    };
    let overall_risk = eval_risk_for_subset(
        risk_all_set,
        Some(&scope.file_signals),
        Some(&scope.file_lines),
    );

    let contract_files: Vec<String> = scope
        .review_files
        .iter()
        .filter(|f| test_contract_path(f))
        .cloned()
        .collect();
    let gen_all: Vec<String> = scope
        .review_files
        .iter()
        .chain(scope.noise_files.iter())
        .filter(|f| test_generated_code_path(f))
        .cloned()
        .collect();
    let generated_files = if gen_all.is_empty() {
        Vec::new()
    } else {
        sort_ordinal(gen_all, false)
    };
    let test_files: Vec<String> = scope
        .review_files
        .iter()
        .filter(|f| test_test_path(f))
        .cloned()
        .collect();

    let (l1_specialists, l1_skip_rationale) = eval_level1_dispatch(
        &contract_files,
        &overall_risk.recommended_specialists,
        overall_risk.risk_level,
        &scope.review_files,
    );

    let mut units = Vec::new();
    let mut partition_error = None;
    if !scope.review_files.is_empty() {
        match build_unit_assignments(
            root,
            target_commit_sha,
            &scope.review_files,
            &scope.file_lines,
            &scope.file_signals,
            size_class,
        ) {
            Ok(u) => units = u,
            Err(pe) => partition_error = Some(pe),
        }
    }

    let split_recommended =
        matches!(size_class, "L" | "XL" | "XXL") && (units.len() >= 2 || scope.total_lines > 800);

    Ok(InventoryResult {
        is_empty: false,
        partition_error,
        size_class,
        files_count: scope.review_files.len(),
        lines_count: scope.total_lines,
        risk_level: overall_risk.risk_level,
        risk_signals: overall_risk.risk_signals,
        recommended_specialists: overall_risk.recommended_specialists,
        l1_specialists,
        l1_skip_rationale,
        change_types: scope.change_types,
        contract_files,
        generated_files,
        test_files,
        noise_files: scope.noise_files,
        review_files: scope.review_files,
        split_recommended,
        max_concurrency: resolved_conc,
        units,
    })
}

/// Executes `b3 guard review-inventory`.
pub fn run(
    repo_root_raw: &str,
    base_sha_raw: &str,
    target_ref_raw: &str,
    ignore_dirty_paths: &str,
    max_concurrency: i32,
) -> Result<(String, i32), B3Error> {
    let max_concurrency = resolve_concurrency(max_concurrency, "INVENTORY_FAIL")?;
    let ignored = split_path_csv_checked(ignore_dirty_paths, "INVENTORY_FAIL", true, None)?;
    let repo_root = normalize_repo_root(repo_root_raw)?;
    let scope = resolve_scope_target_and_base(
        &repo_root,
        target_ref_raw,
        base_sha_raw,
        &ignored,
        "INVENTORY_FAIL",
        "object",
    )?;
    let inv = build_inventory(
        &repo_root,
        &scope.base_sha,
        &scope.target_commit_sha,
        &ignored,
        max_concurrency,
        "INVENTORY_FAIL",
    )?;
    if inv.is_empty {
        return Err(fail("EMPTY_DIFF", 2));
    }
    if let Some(pe) = inv.partition_error {
        return Err(fail(pe, 2));
    }

    let cf_out = if inv.contract_files.is_empty() {
        "none".to_string()
    } else {
        inv.contract_files.join(",")
    };
    let gf_out = if inv.generated_files.is_empty() {
        "none".to_string()
    } else {
        inv.generated_files.join(",")
    };
    let tf_out = if inv.test_files.is_empty() {
        "none".to_string()
    } else {
        inv.test_files.join(",")
    };
    let nf_out = if inv.noise_files.is_empty() {
        "none".to_string()
    } else {
        inv.noise_files.join(",")
    };

    let mut lines = vec![
        format!("size_class={}", inv.size_class),
        format!("files={}", inv.files_count),
        format!("lines={}", inv.lines_count),
        format!("risk_level={}", inv.risk_level),
        format!("risk_signals={}", inv.risk_signals),
        format!("recommended_specialists={}", inv.recommended_specialists),
        format!("l1_specialists={}", inv.l1_specialists),
        format!("l1_skip_rationale={}", inv.l1_skip_rationale),
        format!("change_types={}", inv.change_types),
        format!("contract_files={cf_out}"),
        format!("generated_files={gf_out}"),
        format!("test_files={tf_out}"),
        format!("noise_files={nf_out}"),
        format!("split_recommended={}", inv.split_recommended),
        format!("max_concurrency={}", inv.max_concurrency),
        format!("unit_count={}", inv.units.len()),
    ];
    for u in &inv.units {
        lines.push(format!(
            "unit|{}|{}|{}|{}|{}|{}|{}|{}",
            u.unit_id,
            u.group,
            u.files_cnt,
            u.lines_cnt,
            u.risk,
            u.specialists,
            u.signals,
            u.files_csv
        ));
    }
    Ok((lines.join("\n"), 0))
}
