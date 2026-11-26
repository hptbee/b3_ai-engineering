use std::collections::HashSet;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use crate::error::{fail, B3Error};
use crate::fs::{
    has_control_chars, next_tmp_suffix, normalize_path_value, resolve_unresolved_path,
    test_checkpoint_path, test_secret_path,
};
use crate::process::{run_command, CmdOutput};

static GIT_BIN: OnceLock<OsString> = OnceLock::new();

fn git_program() -> &'static OsStr {
    GIT_BIN
        .get_or_init(|| {
            #[cfg(windows)]
            {
                if let Some(cmd_git) = find_windows_cmd_git() {
                    return cmd_git.into_os_string();
                }
            }
            OsString::from("git")
        })
        .as_os_str()
}

#[cfg(windows)]
fn find_windows_cmd_git() -> Option<PathBuf> {
    let path_var = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path_var) {
        let candidate = dir.join("git.exe");
        if candidate.is_file() {
            let lower = candidate
                .to_string_lossy()
                .to_ascii_lowercase()
                .replace('\\', "/");
            if lower.ends_with("/mingw64/bin/git.exe") || lower.ends_with("/mingw32/bin/git.exe") {
                if let Some(cmd_wrap) = candidate
                    .parent()
                    .and_then(|p| p.parent())
                    .and_then(|p| p.parent())
                    .map(|p| p.join("cmd").join("git.exe"))
                {
                    if cmd_wrap.is_file() {
                        return Some(cmd_wrap);
                    }
                }
            }
            return Some(candidate);
        }
    }
    None
}

/// Parsing mode for NUL-delimited (`-z`) Git commands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GitZMode {
    Names,
    NameStatus,
    Status,
    LsTreeFull,
    LsFilesStage,
}

/// Executes Git with canonical non-interpolating flags (`--literal-pathspecs`,
/// `-C <root>`, `core.quotepath=false`, consistent diff prefixes).
pub fn run_git<S, K, V>(
    root: &Path,
    git_args: &[S],
    extra_env: &[(K, V)],
    stdin_bytes: Option<&[u8]>,
) -> Result<CmdOutput, B3Error>
where
    S: AsRef<OsStr>,
    K: AsRef<OsStr>,
    V: AsRef<OsStr>,
{
    let mut use_lit_ps = true;
    for arg in git_args {
        let s = arg.as_ref().to_string_lossy();
        if s == "--" {
            break;
        }
        if s == "grep" {
            use_lit_ps = false;
            break;
        }
    }

    let mut all_args: Vec<OsString> = Vec::with_capacity(git_args.len() + 14);
    if use_lit_ps {
        all_args.push(OsString::from("--literal-pathspecs"));
    }
    all_args.push(OsString::from("-C"));
    all_args.push(root.as_os_str().to_os_string());
    for cfg_arg in [
        "-c",
        "core.quotepath=false",
        "-c",
        "diff.noprefix=false",
        "-c",
        "diff.mnemonicPrefix=false",
        "-c",
        "diff.srcPrefix=a/",
        "-c",
        "diff.dstPrefix=b/",
    ] {
        all_args.push(OsString::from(cfg_arg));
    }
    for arg in git_args {
        all_args.push(arg.as_ref().to_os_string());
    }

    run_command(
        git_program(),
        &all_args,
        None,
        extra_env,
        &["MSYS2_ARG_CONV_EXCL"],
        stdin_bytes,
    )
}

pub fn git_err_detail(out: &CmdOutput) -> String {
    let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
    if !err.is_empty() {
        err
    } else {
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }
}

/// Validates a Git revision (`commit`, `tree`, `object`, ...) and resolves its SHA.
pub fn assert_valid_git_rev(
    root: &Path,
    rev: &str,
    kind: &str,
    fail_prefix: &str,
    option_name: &str,
) -> Result<String, B3Error> {
    if rev.is_empty() || rev.starts_with('-') {
        return Err(fail(
            format!("{fail_prefix}: invalid {option_name} '{rev}'"),
            1,
        ));
    }
    let spec = format!("{rev}^{{{kind}}}");
    let no_env: [(&str, &str); 0] = [];
    let res = run_git(
        root,
        &["rev-parse", "--verify", "--quiet", &spec],
        &no_env,
        None,
    )?;
    let sha = String::from_utf8_lossy(&res.stdout).trim().to_string();
    if res.exit_code != 0 || sha.is_empty() {
        return Err(fail(
            format!("{fail_prefix}: invalid {option_name} '{rev}'"),
            1,
        ));
    }
    Ok(sha)
}

/// Validates literal repo-relative Git paths returned by `-z` queries.
pub fn test_valid_literal_git_path(path_val: &str) -> bool {
    if path_val.is_empty() || has_control_chars(path_val) || path_val.starts_with('/') {
        return false;
    }
    for seg in path_val.split('/') {
        if seg.is_empty() || seg == "." || seg == ".." {
            return false;
        }
    }
    true
}

/// Runs a NUL-delimited (`-z`) Git command and extracts deduplicated literal paths.
/// Fails closed on Git command failure, malformed records, non-UTF-8 bytes, or
/// unsafe literal path components.
pub fn run_git_paths_z<S, K, V>(
    root: &Path,
    git_args: &[S],
    mode: GitZMode,
    fail_prefix: &str,
    extra_env: &[(K, V)],
) -> Result<Vec<String>, B3Error>
where
    S: AsRef<OsStr>,
    K: AsRef<OsStr>,
    V: AsRef<OsStr>,
{
    let res = run_git(root, git_args, extra_env, None)?;
    if res.exit_code != 0 {
        let joined: Vec<String> = git_args
            .iter()
            .map(|a| a.as_ref().to_string_lossy().into_owned())
            .collect();
        return Err(fail(
            format!(
                "{fail_prefix}: git {} failed: {}",
                joined.join(" "),
                git_err_detail(&res)
            ),
            1,
        ));
    }
    if res.stdout.is_empty() {
        return Ok(Vec::new());
    }

    let mut raw_tokens: Vec<&[u8]> = res.stdout.split(|&b| b == 0).collect();
    if matches!(raw_tokens.last(), Some(last) if last.is_empty()) {
        raw_tokens.pop();
    }

    let mut toks: Vec<String> = Vec::with_capacity(raw_tokens.len());
    for t in raw_tokens {
        let s = std::str::from_utf8(t)
            .map_err(|_| fail(format!("{fail_prefix}: unsupported_literal_git_path"), 1))?;
        toks.push(s.to_string());
    }

    let mut paths = Vec::new();
    let mut seen = HashSet::new();
    let mut add_lit = |mut p_val: String| -> Result<(), B3Error> {
        if p_val.len() > 1 && p_val.ends_with('/') {
            p_val.pop();
        }
        if !test_valid_literal_git_path(&p_val) {
            return Err(fail(
                format!("{fail_prefix}: unsupported_literal_git_path"),
                1,
            ));
        }
        if seen.insert(p_val.clone()) {
            paths.push(p_val);
        }
        Ok(())
    };

    match mode {
        GitZMode::Names => {
            for t in toks {
                add_lit(t)?;
            }
        }
        GitZMode::NameStatus => {
            let mut i = 0;
            while i < toks.len() {
                let st = &toks[i];
                i += 1;
                if st.is_empty() || has_control_chars(st) {
                    return Err(fail(
                        format!("{fail_prefix}: git_parser_failed(name-status)"),
                        1,
                    ));
                }
                if i >= toks.len() {
                    return Err(fail(
                        format!("{fail_prefix}: git_parser_failed(name-status)"),
                        1,
                    ));
                }
                let p1 = toks[i].clone();
                i += 1;
                add_lit(p1)?;
                if st.starts_with('R') || st.starts_with('C') {
                    if i >= toks.len() {
                        return Err(fail(
                            format!("{fail_prefix}: git_parser_failed(name-status-rename)"),
                            1,
                        ));
                    }
                    let p2 = toks[i].clone();
                    i += 1;
                    add_lit(p2)?;
                }
            }
        }
        GitZMode::Status => {
            let mut i = 0;
            while i < toks.len() {
                let rec = &toks[i];
                i += 1;
                let bytes = rec.as_bytes();
                if bytes.len() < 4 || bytes[2] != b' ' {
                    return Err(fail(
                        format!("{fail_prefix}: git_parser_failed(status-z)"),
                        1,
                    ));
                }
                let x = bytes[0];
                let y = bytes[1];
                let p1 = rec[3..].to_string();
                add_lit(p1)?;
                if x == b'R' || x == b'C' || y == b'R' || y == b'C' {
                    if i >= toks.len() {
                        return Err(fail(
                            format!("{fail_prefix}: git_parser_failed(status-z-rename)"),
                            1,
                        ));
                    }
                    let p2 = toks[i].clone();
                    i += 1;
                    add_lit(p2)?;
                }
            }
        }
        GitZMode::LsTreeFull | GitZMode::LsFilesStage => {
            for rec in toks {
                let tab = rec.find('\t').ok_or_else(|| {
                    let label = match mode {
                        GitZMode::LsTreeFull => "ls-tree-full-z",
                        GitZMode::LsFilesStage => "ls-files-stage-z",
                        _ => unreachable!(),
                    };
                    fail(format!("{fail_prefix}: git_parser_failed({label})"), 1)
                })?;
                if tab == 0 {
                    return Err(fail(format!("{fail_prefix}: git_parser_failed(tab)"), 1));
                }
                add_lit(rec[tab + 1..].to_string())?;
            }
        }
    }

    Ok(paths)
}

/// Checks whether `ancestor` is an ancestor commit of `descendant`.
pub fn merge_base_is_ancestor(
    root: &Path,
    ancestor: &str,
    descendant: &str,
    fail_prefix: &str,
) -> Result<bool, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let res = run_git(
        root,
        &["merge-base", "--is-ancestor", ancestor, descendant],
        &no_env,
        None,
    )?;
    match res.exit_code {
        0 => Ok(true),
        1 => Ok(false),
        _ => Err(fail(
            format!(
                "{fail_prefix}: git merge-base failed: {}",
                git_err_detail(&res)
            ),
            1,
        )),
    }
}

struct TempIndexGuard {
    path: PathBuf,
}

impl TempIndexGuard {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("b3-snap-idx-{}.tmp", next_tmp_suffix()));
        Self { path }
    }
}

impl Drop for TempIndexGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn assert_snapshot_safe(root: &Path, fail_prefix: &str) -> Result<(), B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let changed = run_git_paths_z(
        root,
        &[
            "diff",
            "--no-ext-diff",
            "--no-renames",
            "--diff-filter=d",
            "--name-only",
            "-z",
            "HEAD",
            "--",
        ],
        GitZMode::Names,
        fail_prefix,
        &no_env,
    )?;
    let untracked = run_git_paths_z(
        root,
        &["ls-files", "--others", "--exclude-standard", "-z"],
        GitZMode::Names,
        fail_prefix,
        &no_env,
    )?;
    for p in changed.into_iter().chain(untracked) {
        if !p.is_empty() && test_secret_path(&p) {
            return Err(fail(
                format!("{fail_prefix}: sensitive path cannot be snapshotted ({p})"),
                1,
            ));
        }
    }

    let stage_res = run_git(root, &["ls-files", "--stage", "-z"], &no_env, None)?;
    if stage_res.exit_code != 0 {
        return Err(fail(
            format!("{fail_prefix}: unable to inspect submodules"),
            1,
        ));
    }
    if !stage_res.stdout.is_empty() {
        for raw_entry in stage_res.stdout.split(|&b| b == 0) {
            if raw_entry.is_empty() {
                continue;
            }
            let entry = std::str::from_utf8(raw_entry)
                .map_err(|_| fail(format!("{fail_prefix}: unsupported_literal_git_path"), 1))?;
            // Match `^160000 [0-9a-f]{40} [0-3]\t(.+)$`
            if let Some(rest) = entry.strip_prefix("160000 ") {
                if rest.len() > 43 {
                    let sha = &rest[..40];
                    let bytes = rest.as_bytes();
                    if sha.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
                        && bytes[40] == b' '
                        && matches!(bytes[41], b'0'..=b'3')
                        && bytes[42] == b'\t'
                    {
                        let rel = &rest[43..];
                        if !rel.is_empty() {
                            if !test_valid_literal_git_path(rel) {
                                return Err(fail(
                                    format!("{fail_prefix}: unsupported_literal_git_path"),
                                    1,
                                ));
                            }
                            let sub_path =
                                root.join(rel.replace('/', std::path::MAIN_SEPARATOR_STR));
                            if sub_path.join(".git").exists() {
                                let sub_dirty = run_git_paths_z(
                                    &sub_path,
                                    &[
                                        "status",
                                        "--porcelain",
                                        "--untracked-files=all",
                                        "--ignore-submodules=none",
                                        "-z",
                                    ],
                                    GitZMode::Status,
                                    fail_prefix,
                                    &no_env,
                                )?;
                                if !sub_dirty.is_empty() {
                                    return Err(fail(
                                        format!(
                                            "{fail_prefix}: dirty submodule cannot be snapshotted ({rel})"
                                        ),
                                        1,
                                    ));
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    Ok(())
}

fn run_chunked_git_with_index(
    root: &Path,
    env_map: &[(OsString, OsString)],
    fail_prefix: &str,
    fail_label: &str,
    base_args: &[&str],
    paths: &[String],
) -> Result<(), B3Error> {
    if paths.is_empty() {
        return Ok(());
    }
    for chunk in paths.chunks(50) {
        let mut args: Vec<OsString> = base_args.iter().map(OsString::from).collect();
        for p in chunk {
            args.push(OsString::from(p));
        }
        let res = run_git(root, &args, env_map, None)?;
        if res.exit_code != 0 {
            return Err(fail(
                format!("{fail_prefix}: {fail_label}: {}", git_err_detail(&res)),
                1,
            ));
        }
    }
    Ok(())
}

/// Builds a Git tree OID representing the working tree while excluding `.b3/`
/// checkpoint directories (and validating secrets/submodules unless handled).
pub fn new_working_tree_oid(root: &Path, fail_prefix: &str) -> Result<String, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    assert_snapshot_safe(root, fail_prefix)?;

    let untracked_all = run_git_paths_z(
        root,
        &["ls-files", "--others", "--exclude-standard", "-z"],
        GitZMode::Names,
        fail_prefix,
        &no_env,
    )?;
    let untracked_to_add: Vec<String> = untracked_all
        .into_iter()
        .filter(|p| !p.is_empty() && !test_checkpoint_path(p))
        .collect();

    let idx_res = run_git(root, &["rev-parse", "--git-path", "index"], &no_env, None)?;
    if idx_res.exit_code != 0 {
        return Err(fail(
            format!("{fail_prefix}: failed to locate git index"),
            1,
        ));
    }
    let real_idx_raw = String::from_utf8_lossy(&idx_res.stdout).trim().to_string();
    let real_idx = resolve_unresolved_path(root, &real_idx_raw);

    let tmp_guard = TempIndexGuard::new();
    if real_idx.is_file() {
        std::fs::copy(&real_idx, &tmp_guard.path)
            .map_err(|e| fail(format!("{fail_prefix}: failed to copy git index: {e}"), 1))?;
    }

    let env_map = [(
        OsString::from("GIT_INDEX_FILE"),
        tmp_guard.path.as_os_str().to_os_os_string_or_lossy(),
    )];

    let add_u_res = run_git(root, &["add", "-u"], &env_map, None)?;
    if add_u_res.exit_code != 0 {
        return Err(fail(
            format!(
                "{fail_prefix}: git add -u failed: {}",
                git_err_detail(&add_u_res)
            ),
            1,
        ));
    }

    run_chunked_git_with_index(
        root,
        &env_map,
        fail_prefix,
        "git add untracked failed",
        &["add", "--"],
        &untracked_to_add,
    )?;

    let rm_res = run_git(
        root,
        &[
            "rm",
            "-r",
            "--cached",
            "--ignore-unmatch",
            "--quiet",
            "--",
            ".b3/ship",
            ".b3/research-ship",
            ".b3/autodev",
        ],
        &env_map,
        None,
    )?;
    if rm_res.exit_code != 0 {
        return Err(fail(
            format!(
                "{fail_prefix}: git rm checkpoint failed: {}",
                git_err_detail(&rm_res)
            ),
            1,
        ));
    }

    let wt_res = run_git(root, &["write-tree"], &env_map, None)?;
    let tree_sha = String::from_utf8_lossy(&wt_res.stdout).trim().to_string();
    if wt_res.exit_code != 0 || tree_sha.is_empty() {
        return Err(fail(
            format!(
                "{fail_prefix}: git write-tree failed: {}",
                git_err_detail(&wt_res)
            ),
            1,
        ));
    }
    Ok(tree_sha)
}

/// Resolves `--git-dir` (or another `--git-*` rev-parse flag) to a normalized slash path.
pub fn get_canonical_git_path(dir: &Path, rev_flag: &str) -> Option<String> {
    let no_env: [(&str, &str); 0] = [];
    let res = run_git(dir, &["rev-parse", rev_flag], &no_env, None).ok()?;
    let gd = String::from_utf8_lossy(&res.stdout).trim().to_string();
    if res.exit_code != 0 || gd.is_empty() {
        return None;
    }
    let resolved = resolve_unresolved_path(dir, &gd);
    Some(normalize_path_value(&resolved.to_string_lossy()))
}

/// Resolves the active `.git` directory for `root`.
pub fn get_resolved_git_dir(root: &Path) -> Option<PathBuf> {
    let no_env: [(&str, &str); 0] = [];
    let res = run_git(root, &["rev-parse", "--git-dir"], &no_env, None).ok()?;
    let gd = String::from_utf8_lossy(&res.stdout).trim().to_string();
    if res.exit_code != 0 || gd.is_empty() {
        return None;
    }
    Some(resolve_unresolved_path(root, &gd))
}

/// Checks for in-progress merge, rebase, cherry-pick, revert, or bisect operations.
pub fn test_git_mid_operation(root: &Path) -> Option<&'static str> {
    let git_dir = get_resolved_git_dir(root)?;
    [
        "MERGE_HEAD",
        "REBASE_HEAD",
        "rebase-merge",
        "rebase-apply",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
        "BISECT_LOG",
    ]
    .into_iter()
    .find(|&marker| git_dir.join(marker).exists())
}

/// Computes canonical Git blob OID for UTF-8 `text` via `git hash-object -t blob --stdin`.
pub fn git_hash_text(
    root: &Path,
    text: &str,
    fail_prefix: &str,
    fail_desc: &str,
) -> Result<String, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let res = run_git(
        root,
        &["hash-object", "-t", "blob", "--stdin"],
        &no_env,
        Some(text.as_bytes()),
    )?;
    let sha = String::from_utf8_lossy(&res.stdout).trim().to_string();
    if res.exit_code != 0 || !is_hex40(&sha) {
        return Err(fail(
            format!("{fail_prefix}: {fail_desc}: {}", git_err_detail(&res)),
            1,
        ));
    }
    Ok(sha)
}

/// Returns `true` if `s` is a lowercase 40-character hex SHA-1 OID.
pub fn is_hex40(s: &str) -> bool {
    s.len() == 40 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

trait OsStrExtHelper {
    fn to_os_os_string_or_lossy(&self) -> OsString;
}

impl OsStrExtHelper for OsStr {
    fn to_os_os_string_or_lossy(&self) -> OsString {
        self.to_os_string()
    }
}
