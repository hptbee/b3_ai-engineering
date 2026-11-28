use std::collections::{BTreeMap, HashMap};
use std::path::Path;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use crate::error::{fail, B3Error};
use crate::fs::{
    is_reparse_or_symlink, normalize_path_value, normalize_repo_root, resolve_safe_repo_write_path,
    sort_ordinal, split_csv_list_as_paths, split_path_csv_checked, test_checkpoint_path,
    test_contained_repo_path, test_path_match, valid_timestamp_utc, write_atomic_lf,
};
use crate::git::{
    git_err_detail, git_hash_text, is_hex40, merge_base_is_ancestor, run_git, run_git_paths_z,
    run_git_pathspecs, run_git_pathspecs_z, GitZMode,
};
use crate::process::run_command;

const ZERO_OID: &str = "0000000000000000000000000000000000000000";

#[derive(Debug, Clone)]
pub struct TreeFingerprint {
    pub head_sha: String,
    pub tree_hash: String,
    pub paths_csv: String,
}

#[derive(Debug, Clone)]
pub struct VerifyReceiptResult {
    pub code: i32,
    pub message: String,
    pub relevant_paths_csv: String,
}

#[derive(Debug, Clone)]
struct RawDiffEntry {
    new_mode: String,
    new_oid: String,
}

fn git_entry_type(mode: &str) -> &'static str {
    match mode {
        "160000" => "commit",
        "000000" => "deleted",
        "040000" => "tree",
        _ => "blob",
    }
}

/// Supplementary protection matching well-known dependency, toolchain, lint,
/// ignore, workspace, formatter, and type-checker inputs across ecosystems.
/// This list is defense-in-depth only and NOT proof of full input closure:
/// callers with imported custom lint configs or custom scripts must pass them
/// via `--relevant-paths` or omit `--relevant-paths` (`ALL`).
const MANIFEST_EXACT_NAMES: &[&str] = &[
    "cargo.toml",
    "cargo.lock",
    "rust-toolchain.toml",
    "rust-toolchain",
    "clippy.toml",
    ".clippy.toml",
    "rustfmt.toml",
    ".rustfmt.toml",
    "package.json",
    "package-lock.json",
    "pnpm-lock.yaml",
    "pnpm-workspace.yaml",
    "yarn.lock",
    ".npmrc",
    "makefile",
    "biome.json",
    "biome.jsonc",
    "knip.json",
    "knip.jsonc",
    ".editorconfig",
    "jsconfig.json",
    "go.mod",
    "go.sum",
    ".golangci.yml",
    ".golangci.yaml",
    "pyproject.toml",
    "poetry.lock",
    "uv.lock",
    "requirements.txt",
    "pipfile.lock",
    "ruff.toml",
    ".ruff.toml",
    "pyrightconfig.json",
    "mypy.ini",
    ".flake8",
    "setup.cfg",
    "gemfile",
    "gemfile.lock",
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "settings.gradle.kts",
    "tsconfig.json",
    "directory.build.props",
    "directory.build.targets",
    "directory.packages.props",
    "global.json",
    ".shellcheckrc",
    ".yamllint",
    ".yamllint.yml",
    ".yamllint.yaml",
    ".markdownlint.json",
    ".markdownlint.yaml",
    ".markdownlint.yml",
    ".markdownlint-cli2.jsonc",
    ".markdownlint-cli2.yaml",
    ".pre-commit-config.yaml",
    ".eslintrc",
    ".eslintignore",
    ".stylelintrc",
    ".stylelintignore",
    ".prettierrc",
    ".prettierignore",
];

const MANIFEST_GLOB_PATTERNS: &[&str] = &[
    "eslint.config.*",
    ".eslintrc.*",
    "tsconfig.*.json",
    "knip.config.*",
    ".stylelintrc.*",
    "stylelint.config.*",
    "prettier.config.*",
    ".prettierrc.*",
];

const MANIFEST_EXTS: &[&str] = &["csproj", "sln"];

fn matches_manifest_glob_pattern(leaf: &str, pattern: &str) -> bool {
    if let Some((prefix, suffix)) = pattern.split_once('*') {
        leaf.len() >= prefix.len() + suffix.len()
            && leaf.starts_with(prefix)
            && leaf.ends_with(suffix)
    } else {
        leaf == pattern
    }
}

pub(crate) fn is_dependency_or_config_manifest(path: &str) -> bool {
    let norm = path.replace('\\', "/");
    let low = norm.trim_start_matches("./").to_ascii_lowercase();
    if low.is_empty() {
        return false;
    }
    if low == ".cargo/config.toml" || low.ends_with("/.cargo/config.toml") {
        return true;
    }
    let leaf = low.rsplit('/').next().unwrap_or("");
    if MANIFEST_EXACT_NAMES.contains(&leaf)
        || MANIFEST_GLOB_PATTERNS
            .iter()
            .any(|pat| matches_manifest_glob_pattern(leaf, pat))
    {
        return true;
    }
    matches!(
        Path::new(&low).extension().and_then(|e| e.to_str()),
        Some(ext) if MANIFEST_EXTS.contains(&ext)
    )
}

fn manifest_git_pathspecs() -> Vec<String> {
    let mut specs = Vec::with_capacity(
        MANIFEST_EXACT_NAMES.len() + MANIFEST_GLOB_PATTERNS.len() + MANIFEST_EXTS.len() + 1,
    );
    specs.push(":(icase,glob)**/.cargo/config.toml".to_string());
    for name in MANIFEST_EXACT_NAMES {
        specs.push(format!(":(icase,glob)**/{name}"));
    }
    for pat in MANIFEST_GLOB_PATTERNS {
        specs.push(format!(":(icase,glob)**/{pat}"));
    }
    for ext in MANIFEST_EXTS {
        specs.push(format!(":(icase,glob)**/*.{ext}"));
    }
    specs
}

pub(crate) fn validate_receipt_covers_paths(
    receipt_rel_csv: &str,
    required_paths: &[String],
) -> Option<Vec<String>> {
    let trimmed = receipt_rel_csv.trim();
    if trimmed == "ALL" {
        return None;
    }
    if required_paths.is_empty() {
        return Some(Vec::new());
    }
    let rec_list = split_csv_list_as_paths(trimmed);
    let uncovered = sort_ordinal(
        required_paths
            .iter()
            .filter(|p| !test_path_match(p, &rec_list))
            .cloned(),
        false,
    );
    if uncovered.is_empty() {
        None
    } else {
        Some(uncovered)
    }
}

fn parse_git_raw_diff_z(
    raw_bytes: &[u8],
    ign_paths: &[String],
    clean_rel: &[String],
    include_manifests: bool,
    fail_prefix: &str,
) -> Result<BTreeMap<String, RawDiffEntry>, B3Error> {
    let mut map: BTreeMap<String, RawDiffEntry> = BTreeMap::new();
    if raw_bytes.is_empty() {
        return Ok(map);
    }

    let mut toks: Vec<&[u8]> = raw_bytes.split(|&b| b == 0).collect();
    if matches!(toks.last(), Some(last) if last.is_empty()) {
        toks.pop();
    }

    let mut i = 0;
    while i < toks.len() {
        let meta_str = std::str::from_utf8(toks[i])
            .map_err(|_| fail(format!("{fail_prefix}: unsupported_literal_git_path"), 1))?;
        i += 1;
        if !meta_str.starts_with(':') || meta_str.starts_with("::") {
            continue;
        }
        if i >= toks.len() {
            return Err(fail(
                format!("{fail_prefix}: git_parser_failed(diff-raw-z)"),
                1,
            ));
        }
        let path_str = std::str::from_utf8(toks[i])
            .map_err(|_| fail(format!("{fail_prefix}: unsupported_literal_git_path"), 1))?;
        i += 1;

        let parts: Vec<&str> = meta_str[1..].split_whitespace().collect();
        if parts.len() < 5 {
            continue;
        }
        let new_mode = parts[1];
        let new_oid = parts[3];
        if new_mode.len() != 6
            || !new_mode.bytes().all(|b| b.is_ascii_digit())
            || !is_hex40(new_oid)
        {
            continue;
        }

        let p = normalize_path_value(path_str);
        if p.is_empty() || test_checkpoint_path(&p) {
            continue;
        }
        if !ign_paths.is_empty() && test_path_match(&p, ign_paths) {
            continue;
        }
        if !clean_rel.is_empty()
            && !test_path_match(&p, clean_rel)
            && !(include_manifests && is_dependency_or_config_manifest(&p))
        {
            continue;
        }
        if let Some(existing) = map.get(&p) {
            if new_mode == "000000" && existing.new_mode != "000000" {
                continue;
            }
        }
        map.insert(
            p,
            RawDiffEntry {
                new_mode: new_mode.to_string(),
                new_oid: new_oid.to_string(),
            },
        );
    }

    Ok(map)
}

pub(crate) fn git_hash_object_file(
    root: &Path,
    rel_path: &str,
    err_ctx: &str,
) -> Result<String, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let res = run_git(root, &["hash-object", "--", rel_path], &no_env, None)?;
    let sha = String::from_utf8_lossy(&res.stdout).trim().to_string();
    if res.exit_code != 0 || !is_hex40(&sha) {
        let detail = if sha.is_empty() {
            git_err_detail(&res)
        } else {
            sha
        };
        return Err(fail(format!("GIT_ERROR: {err_ctx}: {detail}"), 1));
    }
    Ok(sha)
}

pub(crate) fn get_symlink_blob_oid(root: &Path, rel_path: &str) -> Result<Option<String>, B3Error> {
    let full = root.join(rel_path.replace('/', std::path::MAIN_SEPARATOR_STR));
    if is_reparse_or_symlink(&full) {
        if let Ok(target) = std::fs::read_link(&full) {
            let tgt = target.to_string_lossy().replace('\\', "/");
            let sha = git_hash_text(
                root,
                &tgt,
                "GIT_ERROR",
                &format!("symlink failed for {rel_path}"),
            )?;
            return Ok(Some(sha));
        }
    }
    if full.is_file() {
        let sha = git_hash_object_file(
            root,
            rel_path,
            &format!("git hash-object failed for {rel_path}"),
        )?;
        return Ok(Some(sha));
    }
    Ok(None)
}

pub(crate) fn get_submodule_entry_identity(
    root: &Path,
    rel_path: &str,
    fallback_oid: &str,
    depth: u8,
) -> Result<Option<String>, B3Error> {
    let sub_full = root.join(rel_path.replace('/', std::path::MAIN_SEPARATOR_STR));
    let has_fallback =
        !fallback_oid.is_empty() && fallback_oid != ZERO_OID && is_hex40(fallback_oid);
    let sub_git = sub_full.join(".git");
    if sub_full.is_dir() && sub_git.exists() {
        let no_env: [(&str, &str); 0] = [];
        let sh_res = run_git(&sub_full, &["rev-parse", "HEAD"], &no_env, None)?;
        let sh_trim = String::from_utf8_lossy(&sh_res.stdout).trim().to_string();
        let has_head = sh_res.exit_code == 0 && is_hex40(&sh_trim);
        let sub_head = if has_head {
            sh_trim
        } else if has_fallback {
            fallback_oid.to_string()
        } else {
            "UNBORN".to_string()
        };

        let st_res = run_git(
            &sub_full,
            &[
                "status",
                "--porcelain",
                "-uall",
                "--ignore-submodules=none",
                "-z",
            ],
            &no_env,
            None,
        )?;
        if st_res.exit_code != 0 {
            return Err(fail(
                format!(
                    "GIT_ERROR: submodule status failed for {rel_path}: {}",
                    git_err_detail(&st_res)
                ),
                1,
            ));
        }

        let mut st_list = Vec::new();
        for raw in st_res.stdout.split(|&b| b == 0) {
            if !raw.is_empty() {
                let s = String::from_utf8_lossy(raw).into_owned();
                st_list.push(s);
            }
        }
        if st_list.is_empty() {
            return Ok(Some(format!("160000 commit {sub_head}")));
        }

        let mut sb_dirty = String::new();
        for sl in sort_ordinal(st_list, false) {
            sb_dirty.push_str(&format!("S {sl}\n"));
        }

        let s_wt = if has_head {
            run_git_paths_z(
                &sub_full,
                &[
                    "diff",
                    "--no-ext-diff",
                    "--no-renames",
                    "--name-only",
                    "--ignore-submodules=none",
                    "-z",
                    "HEAD",
                    "--",
                ],
                GitZMode::Names,
                "GIT_ERROR",
                &no_env,
            )?
        } else {
            Vec::new()
        };
        let s_ca = run_git_paths_z(
            &sub_full,
            &[
                "diff",
                "--no-ext-diff",
                "--no-renames",
                "--cached",
                "--name-only",
                "-z",
                "--",
            ],
            GitZMode::Names,
            "GIT_ERROR",
            &no_env,
        )?;
        let s_un = run_git_paths_z(
            &sub_full,
            &["ls-files", "--others", "--exclude-standard", "-z"],
            GitZMode::Names,
            "GIT_ERROR",
            &no_env,
        )?;

        let cands = sort_ordinal(
            s_wt.into_iter()
                .chain(s_ca)
                .chain(s_un)
                .filter(|s| !s.is_empty()),
            false,
        );
        for sp in cands {
            let sp_full = sub_full.join(sp.replace('/', std::path::MAIN_SEPARATOR_STR));
            if is_reparse_or_symlink(&sp_full) {
                if let Some(l_sha) = get_symlink_blob_oid(&sub_full, &sp)? {
                    sb_dirty.push_str(&format!("C {sp} 120000:{l_sha}\n"));
                } else {
                    sb_dirty.push_str(&format!("C {sp} DELETED\n"));
                }
            } else if sp_full.is_file() {
                let f_sha = git_hash_object_file(
                    &sub_full,
                    &sp,
                    &format!("submodule hash-object failed for {rel_path}/{sp}"),
                )?;
                sb_dirty.push_str(&format!("C {sp} {f_sha}\n"));
            } else if sp_full.is_dir() {
                if sp_full.join(".git").exists() {
                    if depth >= 5 {
                        return Err(fail(
                            format!(
                                "GIT_ERROR: nested submodule depth exceeded for {rel_path}/{sp}"
                            ),
                            1,
                        ));
                    }
                    let nested_id = get_submodule_entry_identity(&sub_full, &sp, "", depth + 1)?;
                    let tag = nested_id.unwrap_or_else(|| "DIR".to_string());
                    sb_dirty.push_str(&format!("D {sp} {tag}\n"));
                } else {
                    sb_dirty.push_str(&format!("D {sp} DIR\n"));
                }
            } else {
                sb_dirty.push_str(&format!("C {sp} DELETED\n"));
            }
        }

        let d_sha = git_hash_text(
            root,
            &sb_dirty,
            "GIT_ERROR",
            &format!("submodule digest failed for {rel_path}"),
        )?;
        return Ok(Some(format!("160000 commit {sub_head}+dirty:{d_sha}")));
    }

    if has_fallback {
        return Ok(Some(format!("160000 commit {fallback_oid}")));
    }
    Ok(None)
}

pub(crate) struct TreeFingerprintMaps {
    pub head_sha: String,
    pub effective: BTreeMap<String, String>,
    pub index_div: BTreeMap<String, String>,
}

pub(crate) fn collect_tree_fingerprint_maps(
    root: &Path,
    clean_rel: &[String],
    ign_paths: &[String],
    target_commit_sha: &str,
) -> Result<TreeFingerprintMaps, B3Error> {
    collect_tree_fingerprint_maps_inner(root, clean_rel, ign_paths, target_commit_sha, false)
}

fn collect_tree_fingerprint_maps_inner(
    root: &Path,
    clean_rel: &[String],
    ign_paths: &[String],
    target_commit_sha: &str,
    include_manifests: bool,
) -> Result<TreeFingerprintMaps, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let t_arg = target_commit_sha.trim();
    let has_target_commit = !t_arg.is_empty();

    let head_sha = if has_target_commit {
        if t_arg.starts_with('-') {
            return Err(fail(
                format!("GIT_ERROR: invalid target commit sha: {t_arg}"),
                1,
            ));
        }
        let spec = format!("{t_arg}^{{commit}}");
        let res = run_git(root, &["rev-parse", "--verify", &spec], &no_env, None)?;
        let sha = String::from_utf8_lossy(&res.stdout).trim().to_string();
        if res.exit_code != 0 || !is_hex40(&sha) {
            let detail = if sha.is_empty() {
                git_err_detail(&res)
            } else {
                sha
            };
            return Err(fail(
                format!("GIT_ERROR: git rev-parse {t_arg} failed: {detail}"),
                1,
            ));
        }
        sha
    } else {
        let res = run_git(root, &["rev-parse", "HEAD"], &no_env, None)?;
        let sha = String::from_utf8_lossy(&res.stdout).trim().to_string();
        if res.exit_code != 0 || !is_hex40(&sha) {
            let detail = if sha.is_empty() {
                git_err_detail(&res)
            } else {
                sha
            };
            return Err(fail(
                format!("GIT_ERROR: git rev-parse HEAD failed: {detail}"),
                1,
            ));
        }
        sha
    };

    let mut effective: BTreeMap<String, String> = BTreeMap::new();
    let tree_ref = if has_target_commit {
        head_sha.as_str()
    } else {
        "HEAD"
    };
    // Note: `git ls-tree` rejects `:(glob)`/`:(icase)` magic and reads compressed `.git` tree objects only,
    // while working-tree `diff --raw` and `ls-files --others` use bounded `scope_pathspecs`.
    let mut ls_args: Vec<String> =
        vec!["ls-tree".into(), "-r".into(), "-z".into(), tree_ref.into()];
    if !clean_rel.is_empty() && !include_manifests {
        ls_args.push("--".into());
        ls_args.extend(clean_rel.iter().cloned());
    }
    let ls_res = run_git(root, &ls_args, &no_env, None)?;
    if ls_res.exit_code != 0 {
        return Err(fail(
            format!("GIT_ERROR: git ls-tree failed: {}", git_err_detail(&ls_res)),
            1,
        ));
    }

    for rec in ls_res.stdout.split(|&b| b == 0) {
        if rec.is_empty() {
            continue;
        }
        let line = std::str::from_utf8(rec)
            .map_err(|_| fail("GIT_ERROR: unsupported_literal_git_path", 1))?;
        let Some(tab_idx) = line.find('\t') else {
            continue;
        };
        let meta: Vec<&str> = line[..tab_idx].split_whitespace().collect();
        if meta.len() < 3
            || meta[0].len() != 6
            || !meta[0].bytes().all(|b| b.is_ascii_digit())
            || (meta[1] != "blob" && meta[1] != "commit")
            || !is_hex40(meta[2])
        {
            continue;
        }
        let p = normalize_path_value(&line[tab_idx + 1..]);
        if p.is_empty() || test_checkpoint_path(&p) {
            continue;
        }
        if !ign_paths.is_empty() && test_path_match(&p, ign_paths) {
            continue;
        }
        if !clean_rel.is_empty()
            && !test_path_match(&p, clean_rel)
            && !(include_manifests && is_dependency_or_config_manifest(&p))
        {
            continue;
        }
        effective.insert(p, format!("{} {} {}", meta[0], meta[1], meta[2]));
    }

    let mut index_div: BTreeMap<String, String> = BTreeMap::new();
    if !has_target_commit {
        let fm_res = run_git(root, &["config", "--bool", "core.filemode"], &no_env, None)?;
        let is_win = cfg!(windows);
        let core_filemode = if fm_res.exit_code == 0 {
            String::from_utf8_lossy(&fm_res.stdout).trim() == "true"
        } else {
            !is_win
        };

        let use_manifest_pathspecs = !clean_rel.is_empty() && include_manifests;
        let mut scope_pathspecs: Vec<String> = Vec::new();
        if use_manifest_pathspecs {
            scope_pathspecs.extend(clean_rel.iter().map(|p| format!(":(literal){p}")));
            scope_pathspecs.extend(manifest_git_pathspecs());
        } else if !clean_rel.is_empty() {
            scope_pathspecs.extend(clean_rel.iter().cloned());
        }
        let mut scope_suffix: Vec<String> = vec!["--".into()];
        scope_suffix.extend(scope_pathspecs.iter().cloned());
        let run_scoped_git = |args: &[String]| {
            if use_manifest_pathspecs {
                run_git_pathspecs(root, args, &no_env, None)
            } else {
                run_git(root, args, &no_env, None)
            }
        };

        let mut hd_args: Vec<String> = vec![
            "diff".into(),
            "--no-ext-diff".into(),
            "--raw".into(),
            "-z".into(),
            "--no-renames".into(),
            "--no-abbrev".into(),
            "--ignore-submodules=none".into(),
            "HEAD".into(),
        ];
        hd_args.extend(scope_suffix.iter().cloned());
        let hd_res = run_scoped_git(&hd_args)?;
        if hd_res.exit_code != 0 {
            return Err(fail(
                format!(
                    "GIT_ERROR: git diff --raw HEAD failed: {}",
                    git_err_detail(&hd_res)
                ),
                1,
            ));
        }

        let mut ca_args: Vec<String> = vec![
            "diff".into(),
            "--no-ext-diff".into(),
            "--cached".into(),
            "--raw".into(),
            "-z".into(),
            "--no-renames".into(),
            "--no-abbrev".into(),
            "--ignore-submodules=none".into(),
        ];
        ca_args.extend(scope_suffix.iter().cloned());
        let ca_res = run_scoped_git(&ca_args)?;
        if ca_res.exit_code != 0 {
            return Err(fail(
                format!(
                    "GIT_ERROR: git diff --cached --raw failed: {}",
                    git_err_detail(&ca_res)
                ),
                1,
            ));
        }

        let mut iw_args: Vec<String> = vec![
            "diff".into(),
            "--no-ext-diff".into(),
            "--raw".into(),
            "-z".into(),
            "--no-renames".into(),
            "--no-abbrev".into(),
            "--ignore-submodules=none".into(),
        ];
        iw_args.extend(scope_suffix);
        let iw_res = run_scoped_git(&iw_args)?;
        if iw_res.exit_code != 0 {
            return Err(fail(
                format!(
                    "GIT_ERROR: git diff --raw index-wt failed: {}",
                    git_err_detail(&iw_res)
                ),
                1,
            ));
        }

        let mut un_args: Vec<String> = vec![
            "ls-files".into(),
            "--others".into(),
            "--exclude-standard".into(),
            "-z".into(),
        ];
        if !scope_pathspecs.is_empty() {
            un_args.push("--".into());
            un_args.extend(scope_pathspecs);
        }
        let untracked = if use_manifest_pathspecs {
            run_git_pathspecs_z(root, &un_args, GitZMode::Names, "GIT_ERROR", &no_env)?
        } else {
            run_git_paths_z(root, &un_args, GitZMode::Names, "GIT_ERROR", &no_env)?
        };

        let head_diff = parse_git_raw_diff_z(
            &hd_res.stdout,
            ign_paths,
            clean_rel,
            include_manifests,
            "GIT_ERROR",
        )?;
        let cached_diff = parse_git_raw_diff_z(
            &ca_res.stdout,
            ign_paths,
            clean_rel,
            include_manifests,
            "GIT_ERROR",
        )?;
        let idx_wt_diff = parse_git_raw_diff_z(
            &iw_res.stdout,
            ign_paths,
            clean_rel,
            include_manifests,
            "GIT_ERROR",
        )?;

        for (p, entry) in &head_diff {
            let m = entry.new_mode.as_str();
            let oid = entry.new_oid.as_str();
            let full = root.join(p.replace('/', std::path::MAIN_SEPARATOR_STR));

            if m == "000000" {
                effective.remove(p);
                continue;
            }
            if m == "160000" {
                let fb_oid = if oid != ZERO_OID {
                    oid
                } else if let Some(ce) = cached_diff.get(p) {
                    if ce.new_mode == "160000" && ce.new_oid != ZERO_OID {
                        ce.new_oid.as_str()
                    } else {
                        ""
                    }
                } else {
                    ""
                };
                if let Some(sub_val) = get_submodule_entry_identity(root, p, fb_oid, 0)? {
                    effective.insert(p.clone(), sub_val);
                } else {
                    effective.remove(p);
                }
                continue;
            }
            if m == "120000" {
                if oid != ZERO_OID {
                    effective.insert(p.clone(), format!("120000 blob {oid}"));
                } else if cached_diff.get(p).is_some_and(|ce| {
                    ce.new_mode == "120000"
                        && ce.new_oid != ZERO_OID
                        && !idx_wt_diff.contains_key(p)
                }) {
                    let c_oid = &cached_diff[p].new_oid;
                    effective.insert(p.clone(), format!("120000 blob {c_oid}"));
                } else if let Some(l_sha) = get_symlink_blob_oid(root, p)? {
                    effective.insert(p.clone(), format!("120000 blob {l_sha}"));
                } else {
                    effective.remove(p);
                }
                continue;
            }
            if oid != ZERO_OID {
                effective.insert(p.clone(), format!("{m} blob {oid}"));
            } else if cached_diff.get(p).is_some_and(|ce| {
                ce.new_mode == m && ce.new_oid != ZERO_OID && !idx_wt_diff.contains_key(p)
            }) {
                let c_oid = &cached_diff[p].new_oid;
                effective.insert(p.clone(), format!("{m} blob {c_oid}"));
            } else if full.is_file() {
                let w_sha =
                    git_hash_object_file(root, p, &format!("git hash-object failed for {p}"))?;
                effective.insert(p.clone(), format!("{m} blob {w_sha}"));
            } else {
                effective.remove(p);
            }
        }

        for p in sort_ordinal(untracked, false) {
            if p.is_empty() || test_checkpoint_path(&p) {
                continue;
            }
            if !ign_paths.is_empty() && test_path_match(&p, ign_paths) {
                continue;
            }
            if !clean_rel.is_empty()
                && !test_path_match(&p, clean_rel)
                && !(include_manifests && is_dependency_or_config_manifest(&p))
            {
                continue;
            }
            if head_diff.get(&p).is_some_and(|he| he.new_mode != "000000") {
                continue;
            }
            let full = root.join(p.replace('/', std::path::MAIN_SEPARATOR_STR));
            if is_reparse_or_symlink(&full) {
                if let Some(l_sha) = get_symlink_blob_oid(root, &p)? {
                    effective.insert(p, format!("120000 blob {l_sha}"));
                }
            } else if full.is_file() {
                let w_sha =
                    git_hash_object_file(root, &p, &format!("git hash-object failed for {p}"))?;
                #[allow(unused_mut)]
                let mut u_mode = "100644";
                #[cfg(unix)]
                if core_filemode {
                    use std::os::unix::fs::PermissionsExt;
                    if let Ok(meta) = std::fs::metadata(&full) {
                        if meta.permissions().mode() & 0o111 != 0 {
                            u_mode = "100755";
                        }
                    }
                }
                let _ = core_filemode;
                effective.insert(p, format!("{u_mode} blob {w_sha}"));
            } else if full.is_dir() && full.join(".git").exists() {
                if let Some(sub_val) = get_submodule_entry_identity(root, &p, "", 0)? {
                    effective.insert(p, sub_val);
                }
            }
        }

        for (p, c) in &cached_diff {
            let c_type = git_entry_type(&c.new_mode);
            let c_entry = format!("{} {} {}", c.new_mode, c_type, c.new_oid);
            let differs = if c.new_mode == "000000" {
                effective.contains_key(p)
            } else {
                effective.get(p) != Some(&c_entry)
            };
            if differs {
                index_div.insert(p.clone(), c_entry);
            }
        }
    }

    Ok(TreeFingerprintMaps {
        head_sha,
        effective,
        index_div,
    })
}

pub(crate) fn hash_tree_fingerprint_maps(
    root: &Path,
    paths_csv: &str,
    maps: &TreeFingerprintMaps,
    filter_paths: Option<&[String]>,
) -> Result<String, B3Error> {
    let mut manifest = String::new();
    manifest.push_str(&format!("PATHS={paths_csv}\n"));
    for (ep, ev) in &maps.effective {
        if match filter_paths {
            None => true,
            Some(fp) => test_path_match(ep, fp),
        } {
            manifest.push_str(&format!("E {ev} {ep}\n"));
        }
    }
    for (ip, iv) in &maps.index_div {
        if match filter_paths {
            None => true,
            Some(fp) => test_path_match(ip, fp),
        } {
            manifest.push_str(&format!("I {iv} {ip}\n"));
        }
    }
    git_hash_text(root, &manifest, "GIT_ERROR", "manifest failed")
}

/// Computes canonical tree fingerprint matching `Get-TreeFingerprint` (`b3 guard`).
pub fn get_tree_fingerprint(
    root: &Path,
    rel_paths: &[String],
    ign_paths: &[String],
    target_commit_sha: &str,
) -> Result<TreeFingerprint, B3Error> {
    get_tree_fingerprint_inner(root, rel_paths, ign_paths, target_commit_sha, false)
}

fn get_tree_fingerprint_inner(
    root: &Path,
    rel_paths: &[String],
    ign_paths: &[String],
    target_commit_sha: &str,
    include_manifests: bool,
) -> Result<TreeFingerprint, B3Error> {
    let clean_rel = if !rel_paths.is_empty() {
        let filtered: Vec<String> = rel_paths
            .iter()
            .filter_map(|rp| {
                let np = normalize_path_value(rp);
                if np.is_empty()
                    || test_checkpoint_path(&np)
                    || (!ign_paths.is_empty() && test_path_match(&np, ign_paths))
                {
                    None
                } else {
                    Some(np)
                }
            })
            .collect();
        let sorted = sort_ordinal(filtered, false);
        if sorted.is_empty() {
            return Err(fail(
                "TREE_FP_FAIL: relevant paths resolved to empty after exclusions",
                1,
            ));
        }
        sorted
    } else {
        Vec::new()
    };

    let paths_csv = if clean_rel.is_empty() {
        "ALL".to_string()
    } else {
        clean_rel.join(",")
    };

    let maps = collect_tree_fingerprint_maps_inner(
        root,
        &clean_rel,
        ign_paths,
        target_commit_sha,
        include_manifests,
    )?;
    let tree_hash = hash_tree_fingerprint_maps(root, &paths_csv, &maps, None)?;
    Ok(TreeFingerprint {
        head_sha: maps.head_sha,
        tree_hash,
        paths_csv,
    })
}

fn valid_exit_code_str(s: &str) -> bool {
    let digits = s.strip_prefix('-').unwrap_or(s);
    !digits.is_empty() && digits.len() <= 9 && digits.bytes().all(|b| b.is_ascii_digit())
}

pub(crate) fn valid_receipt_rel_list(raw_csv: &str) -> Option<Vec<String>> {
    let mut trimmed = raw_csv.trim();
    if trimmed.starts_with('[') && trimmed.ends_with(']') && trimmed.len() >= 2 {
        trimmed = &trimmed[1..trimmed.len() - 1];
    }
    if trimmed.contains('*') || trimmed.contains('?') {
        return None;
    }
    let spec = split_csv_list_as_paths(raw_csv);
    if spec.is_empty() {
        return None;
    }
    for p in &spec {
        if p.is_empty()
            || test_checkpoint_path(p)
            || p.contains(':')
            || p.starts_with('/')
            || p.split('/').any(|seg| seg == "..")
        {
            return None;
        }
    }
    Some(spec)
}

/// Validates a `b3-verify-v1` receipt against working tree or `target_commit_sha`.
pub fn test_verify_receipt(
    root: &Path,
    receipt_arg: &str,
    ign_paths: &[String],
    expected_cmd_arg: &str,
    req_rel_paths_arg: &str,
    target_commit_sha: &str,
) -> VerifyReceiptResult {
    let fail_res = |code: i32, msg: String| VerifyReceiptResult {
        code,
        message: msg,
        relevant_paths_csv: String::new(),
    };

    let trim_arg = receipt_arg.trim();
    if trim_arg.is_empty() {
        return fail_res(1, "VERIFY_MISSING: empty receipt path".to_string());
    }
    let Some((full_receipt, disp_path)) = test_contained_repo_path(root, trim_arg) else {
        return fail_res(1, "VERIFY_CORRUPT: invalid receipt_path".to_string());
    };
    if !full_receipt.is_file() {
        return fail_res(1, format!("VERIFY_MISSING: {disp_path}"));
    }

    let Ok(raw_text) = std::fs::read_to_string(&full_receipt) else {
        return fail_res(1, format!("VERIFY_MISSING: {disp_path}"));
    };

    let mut kv: HashMap<String, String> = HashMap::new();
    for raw_line in raw_text.lines() {
        let ln = raw_line.trim();
        if ln.is_empty() {
            continue;
        }
        let Some(eq_idx) = ln.find('=') else {
            return fail_res(1, "VERIFY_CORRUPT: malformed line in receipt".to_string());
        };
        if eq_idx < 1 {
            return fail_res(1, "VERIFY_CORRUPT: malformed line in receipt".to_string());
        }
        let k = ln[..eq_idx].trim().to_string();
        let v = ln[eq_idx + 1..].trim().to_string();
        if kv.contains_key(&k) {
            return fail_res(1, format!("VERIFY_CORRUPT: duplicate field '{k}'"));
        }
        kv.insert(k, v);
    }

    for req_key in [
        "schema",
        "task_id",
        "scope",
        "head_sha",
        "tree_hash",
        "relevant_paths",
        "exit_code",
        "status",
        "command",
        "log_path",
        "timestamp_utc",
    ] {
        if !kv.get(req_key).is_some_and(|v| !v.is_empty()) {
            return fail_res(1, format!("VERIFY_CORRUPT: missing field '{req_key}'"));
        }
    }

    if kv["schema"] != "b3-verify-v1" {
        return fail_res(
            1,
            format!("VERIFY_CORRUPT: unsupported schema '{}'", kv["schema"]),
        );
    }
    if !is_hex40(&kv["head_sha"]) {
        return fail_res(1, "VERIFY_CORRUPT: invalid head_sha".to_string());
    }
    if !is_hex40(&kv["tree_hash"]) {
        return fail_res(1, "VERIFY_CORRUPT: invalid tree_hash".to_string());
    }
    if !valid_exit_code_str(&kv["exit_code"]) {
        return fail_res(1, "VERIFY_CORRUPT: invalid exit_code".to_string());
    }
    if kv["status"] != "PASS" && kv["status"] != "FAIL" {
        return fail_res(
            1,
            format!("VERIFY_CORRUPT: invalid status '{}'", kv["status"]),
        );
    }
    if !valid_timestamp_utc(&kv["timestamp_utc"]) {
        return fail_res(1, "VERIFY_CORRUPT: invalid timestamp_utc".to_string());
    }
    if let Some(dur) = kv.get("duration_ms") {
        if dur.is_empty() || !dur.bytes().all(|b| b.is_ascii_digit()) {
            return fail_res(1, "VERIFY_CORRUPT: invalid duration_ms".to_string());
        }
    }

    if kv["log_path"] != "none" {
        let lp_slash = kv["log_path"].trim().replace('\\', "/");
        if lp_slash.is_empty()
            || lp_slash == "."
            || lp_slash.starts_with('/')
            || lp_slash.starts_with('~')
            || (lp_slash.len() >= 2
                && lp_slash.as_bytes()[0].is_ascii_alphabetic()
                && lp_slash.as_bytes()[1] == b':')
            || lp_slash.split('/').any(|seg| seg == "..")
        {
            return fail_res(1, "VERIFY_CORRUPT: invalid log_path".to_string());
        }
        let Some((log_full, _)) = resolve_safe_repo_write_path(root, &lp_slash) else {
            return fail_res(1, "VERIFY_CORRUPT: invalid log_path".to_string());
        };
        if !log_full.is_file() {
            return fail_res(1, "VERIFY_CORRUPT: missing log_path".to_string());
        }
    }

    let exit_int = kv["exit_code"].parse::<i32>().unwrap_or(-1);
    if exit_int != 0 || kv["status"] != "PASS" {
        return fail_res(
            1,
            format!(
                "VERIFY_FAILED_RECEIPT: exit={} status={}",
                kv["exit_code"], kv["status"]
            ),
        );
    }

    let rel_spec = if kv["relevant_paths"] == "ALL" {
        Vec::new()
    } else {
        match valid_receipt_rel_list(&kv["relevant_paths"]) {
            Some(v) => v,
            None => return fail_res(1, "VERIFY_CORRUPT: invalid relevant_paths".to_string()),
        }
    };

    if !expected_cmd_arg.trim().is_empty() {
        let norm_expected = normalize_single_line_ws(expected_cmd_arg);
        if kv["command"] != norm_expected {
            return fail_res(1, "VERIFY_MISMATCH: command mismatch".to_string());
        }
    }

    if !req_rel_paths_arg.trim().is_empty() {
        let Some(valid_req) = valid_receipt_rel_list(req_rel_paths_arg) else {
            return fail_res(1, "VERIFY_CHECK_FAIL: invalid relevant_paths".to_string());
        };
        if let Some(uncovered) = validate_receipt_covers_paths(&kv["relevant_paths"], &valid_req) {
            return fail_res(
                1,
                format!(
                    "VERIFY_SCOPE_MISMATCH: uncovered path ({})",
                    uncovered.join(",")
                ),
            );
        }
    }

    let target_trim = target_commit_sha.trim();
    let cur = match get_tree_fingerprint_inner(root, &rel_spec, ign_paths, target_trim, true) {
        Ok(fp) => fp,
        Err(e) => return fail_res(1, e.message),
    };

    if !target_trim.is_empty() {
        if cur.head_sha != kv["head_sha"] {
            return fail_res(
                2,
                format!(
                    "VERIFY_STALE: head_sha={} target={}",
                    &kv["head_sha"][..12],
                    &cur.head_sha[..12]
                ),
            );
        }
    } else if cur.head_sha != kv["head_sha"] {
        match merge_base_is_ancestor(root, &kv["head_sha"], &cur.head_sha, "GIT_ERROR") {
            Ok(true) => {}
            _ => {
                return fail_res(
                    2,
                    format!(
                        "VERIFY_STALE: receipt={} current={}",
                        &kv["tree_hash"][..12],
                        &cur.tree_hash[..12]
                    ),
                );
            }
        }
    }

    if cur.tree_hash != kv["tree_hash"] {
        return fail_res(
            2,
            format!(
                "VERIFY_STALE: receipt={} current={}",
                &kv["tree_hash"][..12],
                &cur.tree_hash[..12]
            ),
        );
    }

    VerifyReceiptResult {
        code: 0,
        message: format!(
            "VERIFY_VALID: task={} scope={} tree={}",
            kv["task_id"],
            kv["scope"],
            &kv["tree_hash"][..12]
        ),
        relevant_paths_csv: kv["relevant_paths"].clone(),
    }
}

fn normalize_single_line_ws(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_nl = false;
    for ch in s.chars() {
        if ch == '\r' || ch == '\n' {
            if !in_nl {
                out.push(' ');
                in_nl = true;
            }
        } else {
            in_nl = false;
            out.push(ch);
        }
    }
    out.trim().to_string()
}

pub(crate) fn format_utc_iso8601_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let hour = rem / 3_600;
    let minute = (rem % 3_600) / 60;
    let second = rem % 60;

    // Howard Hinnant's civil-from-days algorithm
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = y + if m <= 2 { 1 } else { 0 };
    format!("{year:04}-{m:02}-{d:02}T{hour:02}:{minute:02}:{second:02}Z")
}

#[cfg(windows)]
fn base64_encode(bytes: &[u8]) -> String {
    const TBL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as usize;
        let b1 = if chunk.len() > 1 {
            chunk[1] as usize
        } else {
            0
        };
        let b2 = if chunk.len() > 2 {
            chunk[2] as usize
        } else {
            0
        };
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(TBL[(n >> 18) & 0x3F] as char);
        out.push(TBL[(n >> 12) & 0x3F] as char);
        out.push(if chunk.len() > 1 {
            TBL[(n >> 6) & 0x3F] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TBL[n & 0x3F] as char
        } else {
            '='
        });
    }
    out
}

/// Executes `verify_cmd` inside `repo_root` and writes a `b3-verify-v1` receipt.
#[allow(clippy::too_many_arguments)]
pub fn verify_run(
    repo_root_raw: &str,
    verify_cmd: &str,
    receipt_path: &str,
    task_id: &str,
    scope: &str,
    relevant_paths: &str,
    ignore_dirty_paths: &str,
    log_path: &str,
) -> Result<(String, i32), B3Error> {
    if verify_cmd.trim().is_empty() {
        return Err(fail("VERIFY_RUN_FAIL: missing --verify-cmd", 1));
    }
    if receipt_path.trim().is_empty() {
        return Err(fail("VERIFY_RUN_FAIL: missing --receipt-path", 1));
    }

    let repo_root = normalize_repo_root(repo_root_raw)?;
    let Some((full_receipt, receipt_rel)) = resolve_safe_repo_write_path(&repo_root, receipt_path)
    else {
        return Err(fail("VERIFY_RUN_FAIL: invalid receipt_path", 1));
    };
    if full_receipt.is_dir() {
        return Err(fail("VERIFY_RUN_FAIL: invalid receipt_path", 1));
    }

    let eff_log_arg = if log_path.trim().is_empty() {
        format!("{receipt_rel}.log")
    } else {
        log_path.to_string()
    };
    let Some((full_log, log_rel)) = resolve_safe_repo_write_path(&repo_root, &eff_log_arg) else {
        return Err(fail("VERIFY_RUN_FAIL: invalid log_path", 1));
    };
    if full_log.is_dir() {
        return Err(fail("VERIFY_RUN_FAIL: invalid log_path", 1));
    }

    let eff_task_id = {
        let s = normalize_single_line_ws(task_id);
        if s.is_empty() {
            "unknown".to_string()
        } else {
            s
        }
    };
    let eff_scope = {
        let s = normalize_single_line_ws(scope);
        if s.is_empty() {
            "scoped".to_string()
        } else {
            s
        }
    };

    let ignored = split_path_csv_checked(ignore_dirty_paths, "VERIFY_RUN_FAIL", true, None)?;
    let rel_arr = split_path_csv_checked(relevant_paths, "VERIFY_RUN_FAIL", false, None)?;

    let no_env: [(&str, &str); 0] = [];
    let sw = Instant::now();
    let cmd_out = {
        #[cfg(windows)]
        {
            let wrapper = format!(
                "$global:LASTEXITCODE = 0\n& {{\n{verify_cmd}\n}}\nif (-not $?) {{ if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {{ exit $LASTEXITCODE }} else {{ exit 1 }} }}\nif ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {{ exit $LASTEXITCODE }}\nexit 0"
            );
            let mut utf16 = Vec::with_capacity(wrapper.len() * 2);
            for u in wrapper.encode_utf16() {
                utf16.push((u & 0xFF) as u8);
                utf16.push((u >> 8) as u8);
            }
            let enc = base64_encode(&utf16);
            run_command(
                std::ffi::OsStr::new("powershell"),
                &[
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-EncodedCommand",
                    &enc,
                ],
                Some(&repo_root),
                &no_env,
                &[],
                None,
            )?
        }
        #[cfg(not(windows))]
        {
            run_command(
                std::ffi::OsStr::new("sh"),
                &["-c", verify_cmd],
                Some(&repo_root),
                &no_env,
                &[],
                None,
            )?
        }
    };
    let duration_ms = sw.elapsed().as_millis();

    let mut combined = String::from_utf8_lossy(&cmd_out.stdout).into_owned();
    if !cmd_out.stderr.is_empty() {
        if !combined.is_empty() && !combined.ends_with('\n') {
            combined.push('\n');
        }
        combined.push_str(&String::from_utf8_lossy(&cmd_out.stderr));
    }
    let out_lines: Vec<String> = combined.lines().map(|l| l.to_string()).collect();

    let fp = get_tree_fingerprint_inner(&repo_root, &rel_arr, &ignored, "", true)?;
    let cmd_exit = cmd_out.exit_code;
    let status_val = if cmd_exit == 0 { "PASS" } else { "FAIL" };

    let log_disp = if cmd_exit != 0 || out_lines.len() > 35 {
        let log_body = if out_lines.is_empty() {
            String::new()
        } else {
            out_lines.join("\n") + "\n"
        };
        write_atomic_lf(&full_log, &log_body)?;
        log_rel
    } else {
        "none".to_string()
    };

    let single_cmd = normalize_single_line_ws(verify_cmd);
    let ts_utc = format_utc_iso8601_now();
    let receipt_body = [
        "schema=b3-verify-v1".to_string(),
        format!("task_id={eff_task_id}"),
        format!("scope={eff_scope}"),
        format!("head_sha={}", fp.head_sha),
        format!("tree_hash={}", fp.tree_hash),
        format!("relevant_paths={}", fp.paths_csv),
        format!("exit_code={cmd_exit}"),
        format!("status={status_val}"),
        format!("duration_ms={duration_ms}"),
        format!("command={single_cmd}"),
        format!("log_path={log_disp}"),
        format!("timestamp_utc={ts_utc}"),
    ]
    .join("\n")
        + "\n";
    write_atomic_lf(&full_receipt, &receipt_body)?;

    let short_tree = &fp.tree_hash[..12];
    if cmd_exit == 0 {
        Ok((
            format!("VERIFY_PASS: exit=0 tree={short_tree} receipt={receipt_rel} duration_ms={duration_ms}"),
            0,
        ))
    } else {
        let mut msg_lines = Vec::with_capacity(1 + out_lines.len().min(35));
        msg_lines.push(format!(
            "VERIFY_FAIL: exit={cmd_exit} tree={short_tree} receipt={receipt_rel} log={log_disp} duration_ms={duration_ms}"
        ));
        for ln in out_lines.iter().take(35) {
            msg_lines.push(ln.clone());
        }
        Ok((msg_lines.join("\n"), 1))
    }
}

/// Validates a `b3-verify-v1` receipt for `verify-check`.
pub fn verify_check(
    repo_root_raw: &str,
    receipt_path: &str,
    expected_cmd: &str,
    relevant_paths: &str,
    ignore_dirty_paths: &str,
    target_commit_sha: &str,
    has_target_commit_sha: bool,
) -> Result<(String, i32), B3Error> {
    if has_target_commit_sha && target_commit_sha.trim().is_empty() {
        return Err(fail("VERIFY_CHECK_FAIL: empty --target-commit-sha", 1));
    }
    let ignored = split_path_csv_checked(ignore_dirty_paths, "VERIFY_CHECK_FAIL", true, None)?;
    let repo_root = normalize_repo_root(repo_root_raw)?;
    let res = test_verify_receipt(
        &repo_root,
        receipt_path,
        &ignored,
        expected_cmd,
        relevant_paths,
        target_commit_sha,
    );
    Ok((res.message, res.code))
}

#[cfg(test)]
mod tests {
    use super::{
        is_dependency_or_config_manifest, manifest_git_pathspecs, MANIFEST_EXACT_NAMES,
        MANIFEST_EXTS, MANIFEST_GLOB_PATTERNS,
    };

    #[test]
    fn manifest_matcher_accepts_exact_lint_and_analyzer_configs() {
        for path in [
            "clippy.toml",
            ".clippy.toml",
            "rustfmt.toml",
            ".rustfmt.toml",
            "biome.json",
            "biome.jsonc",
            "knip.json",
            "knip.jsonc",
            ".editorconfig",
            "jsconfig.json",
            "ruff.toml",
            ".ruff.toml",
            "pyrightconfig.json",
            "mypy.ini",
            ".flake8",
            "setup.cfg",
            ".golangci.yml",
            ".golangci.yaml",
            ".shellcheckrc",
            ".yamllint",
            ".yamllint.yml",
            ".yamllint.yaml",
            ".markdownlint.json",
            ".markdownlint.yaml",
            ".markdownlint.yml",
            ".markdownlint-cli2.jsonc",
            ".markdownlint-cli2.yaml",
            ".pre-commit-config.yaml",
            ".eslintrc",
            ".eslintignore",
            ".stylelintrc",
            ".stylelintignore",
            ".prettierrc",
            ".prettierignore",
            "Makefile",
            ".npmrc",
            "pnpm-workspace.yaml",
            "packages/app/.ruff.toml",
            r".\SubDir\Clippy.TOML",
            ".cargo/config.toml",
            "services/api/Api.csproj",
            "MyApp.sln",
        ] {
            assert!(
                is_dependency_or_config_manifest(path),
                "expected manifest match for {path}"
            );
        }
    }

    #[test]
    fn manifest_matcher_accepts_glob_config_patterns() {
        for path in [
            "eslint.config.mjs",
            "apps/web/eslint.config.ts",
            ".eslintrc.cjs",
            ".eslintrc.json",
            "tsconfig.app.json",
            "packages/ui/tsconfig.build.json",
            "knip.config.ts",
            ".stylelintrc.json",
            "stylelint.config.mjs",
            "prettier.config.mjs",
            ".prettierrc.json",
            ".PrettierRC.YAML",
        ] {
            assert!(
                is_dependency_or_config_manifest(path),
                "expected glob manifest match for {path}"
            );
        }
    }

    #[test]
    fn manifest_matcher_rejects_non_manifest_files() {
        for path in [
            "",
            "src/main.rs",
            "eslint.config",
            "notes/tsconfig.txt",
            "tsconfig.json.bak",
            "docs/clippy.toml.md",
            "prettier.config",
            "knip.config",
        ] {
            assert!(
                !is_dependency_or_config_manifest(path),
                "expected non-manifest rejection for {path}"
            );
        }
    }

    #[test]
    fn manifest_git_pathspecs_contains_all_exact_glob_and_ext_patterns() {
        let specs = manifest_git_pathspecs();
        assert!(specs.contains(&":(icase,glob)**/.cargo/config.toml".to_string()));
        for name in MANIFEST_EXACT_NAMES {
            let expected = format!(":(icase,glob)**/{name}");
            assert!(
                specs.contains(&expected),
                "missing exact pathspec {expected}"
            );
        }
        for pat in MANIFEST_GLOB_PATTERNS {
            let expected = format!(":(icase,glob)**/{pat}");
            assert!(
                specs.contains(&expected),
                "missing glob pathspec {expected}"
            );
        }
        for ext in MANIFEST_EXTS {
            let expected = format!(":(icase,glob)**/*.{ext}");
            assert!(specs.contains(&expected), "missing ext pathspec {expected}");
        }
        assert_eq!(
            specs.len(),
            1 + MANIFEST_EXACT_NAMES.len() + MANIFEST_GLOB_PATTERNS.len() + MANIFEST_EXTS.len()
        );
    }
}
