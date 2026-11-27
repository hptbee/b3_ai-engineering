use std::collections::HashMap;
use std::path::Path;

use crate::error::{fail, B3Error};
use crate::fs::{has_control_chars, sort_ordinal};
use crate::git::{is_hex40, run_git};
use crate::json::{parse_json, JsonValue};
use crate::pr::gh_exec::{
    exec_gh, needs_bash_for_gh, parse_github_remote_slug, resolve_bash_binary, resolve_gh_binary,
    validate_pr_number, validate_repo_slug,
};

fn gh_err(reason: &str) -> B3Error {
    fail(format!("GH_VERIFY_ERROR: {reason}"), 1)
}

fn gh_unavail(reason: &str) -> B3Error {
    fail(format!("GH_VERIFY_UNAVAILABLE: {reason}"), 2)
}

fn safe_text(val: Option<&JsonValue>, field: &str) -> Result<String, B3Error> {
    let Some(v) = val else {
        return Ok(String::new());
    };
    let s = v.to_text_string().unwrap_or_default();
    if has_control_chars(&s) {
        return Err(gh_err(&format!("control_chars_in_response({field})")));
    }
    Ok(s)
}

fn encode_uri_component(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for &b in s.as_bytes() {
        if b.is_ascii_alphanumeric()
            || matches!(
                b,
                b'-' | b'_' | b'.' | b'!' | b'~' | b'*' | b'\'' | b'(' | b')'
            )
        {
            out.push(b as char);
        } else {
            out.push('%');
            out.push_str(&format!("{b:02X}"));
        }
    }
    out
}

fn contains_http_status(txt: &str, code: &str) -> bool {
    let low = txt.to_ascii_lowercase();
    let bytes = low.as_bytes();
    let c_bytes = code.as_bytes();
    // `\bhttp\s+<code>\b`
    let mut pos = 0;
    while let Some(idx) = low[pos..].find("http") {
        let abs = pos + idx;
        let left_ok = abs == 0 || !bytes[abs - 1].is_ascii_alphanumeric();
        let mut p = abs + 4;
        if left_ok && p < bytes.len() && bytes[p].is_ascii_whitespace() {
            while p < bytes.len() && bytes[p].is_ascii_whitespace() {
                p += 1;
            }
            if low[p..].starts_with(code) {
                let end = p + c_bytes.len();
                if end == bytes.len() || !bytes[end].is_ascii_alphanumeric() {
                    return true;
                }
            }
        }
        pos = abs + 1;
    }
    // `"status"\s*:\s*"?<code>"?`
    pos = 0;
    while let Some(idx) = low[pos..].find("\"status\"") {
        let abs = pos + idx;
        let mut p = abs + 8;
        while p < bytes.len() && bytes[p].is_ascii_whitespace() {
            p += 1;
        }
        if p < bytes.len() && bytes[p] == b':' {
            p += 1;
            while p < bytes.len() && bytes[p].is_ascii_whitespace() {
                p += 1;
            }
            if p < bytes.len() && bytes[p] == b'"' {
                p += 1;
            }
            if low[p..].starts_with(code) {
                let end = p + c_bytes.len();
                if end == bytes.len() || bytes[end] == b'"' || !bytes[end].is_ascii_alphanumeric() {
                    return true;
                }
            }
        }
        pos = abs + 1;
    }
    false
}

fn contains_http_5xx(txt: &str) -> bool {
    let low = txt.to_ascii_lowercase();
    let bytes = low.as_bytes();
    let mut pos = 0;
    while let Some(idx) = low[pos..].find("http") {
        let abs = pos + idx;
        let left_ok = abs == 0 || !bytes[abs - 1].is_ascii_alphanumeric();
        let mut p = abs + 4;
        if left_ok && p < bytes.len() && bytes[p].is_ascii_whitespace() {
            while p < bytes.len() && bytes[p].is_ascii_whitespace() {
                p += 1;
            }
            if p + 3 <= bytes.len()
                && bytes[p] == b'5'
                && bytes[p + 1].is_ascii_digit()
                && bytes[p + 2].is_ascii_digit()
                && (p + 3 == bytes.len() || !bytes[p + 3].is_ascii_alphanumeric())
            {
                return true;
            }
        }
        pos = abs + 1;
    }
    pos = 0;
    while let Some(idx) = low[pos..].find("\"status\"") {
        let abs = pos + idx;
        let mut p = abs + 8;
        while p < bytes.len() && bytes[p].is_ascii_whitespace() {
            p += 1;
        }
        if p < bytes.len() && bytes[p] == b':' {
            p += 1;
            while p < bytes.len() && bytes[p].is_ascii_whitespace() {
                p += 1;
            }
            if p < bytes.len() && bytes[p] == b'"' {
                p += 1;
            }
            if p + 3 <= bytes.len()
                && bytes[p] == b'5'
                && bytes[p + 1].is_ascii_digit()
                && bytes[p + 2].is_ascii_digit()
                && (p + 3 == bytes.len()
                    || bytes[p + 3] == b'"'
                    || !bytes[p + 3].is_ascii_alphanumeric())
            {
                return true;
            }
        }
        pos = abs + 1;
    }
    false
}

fn contains_network_or_auth_error(txt: &str) -> bool {
    let low = txt.to_ascii_lowercase();
    [
        "not logged into",
        "gh auth login",
        "bad credentials",
        "authentication",
        "error connecting",
        "dial tcp",
        "i/o timeout",
        "timed out",
        "connection refused",
        "connection reset",
        "could not resolve",
        "no such host",
        "network is unreachable",
        "tls handshake",
    ]
    .iter()
    .any(|needle| low.contains(needle))
}

fn fail_on_api_failure(
    stdout: &str,
    stderr: &str,
    endpoint_label: &str,
    allow_404_reason: &str,
) -> B3Error {
    let txt = format!("{stderr}\n{stdout}");
    if !allow_404_reason.is_empty() && contains_http_status(&txt, "404") {
        return gh_err(allow_404_reason);
    }
    if contains_http_status(&txt, "401") {
        return gh_unavail("github_auth_failed");
    }
    if contains_http_status(&txt, "403") {
        return gh_unavail("github_access_denied");
    }
    if contains_http_status(&txt, "429") {
        return gh_unavail("github_rate_limited");
    }
    if contains_http_5xx(&txt) {
        return gh_unavail("github_http_5xx");
    }
    if contains_network_or_auth_error(&txt) {
        return gh_unavail("github_network_or_auth_error");
    }
    if contains_http_status(&txt, "404") {
        return gh_err(&format!("{endpoint_label}_not_found"));
    }
    gh_err(&format!("{endpoint_label}_query_failed"))
}

fn parse_json_ctx(raw: &str, ctx: &str) -> Result<JsonValue, B3Error> {
    parse_json(raw).map_err(|_| {
        let reason = if raw.trim_start_matches('\u{FEFF}').trim().is_empty() {
            "empty_json"
        } else {
            "invalid_json"
        };
        gh_err(&format!("{reason}({ctx})"))
    })
}

struct GhApiCaller {
    gh_bin: std::path::PathBuf,
    bash_bin: Option<std::path::PathBuf>,
}

impl GhApiCaller {
    fn invoke(&self, api_args: &[&str]) -> Result<(i32, String, String), B3Error> {
        let mut args = Vec::with_capacity(1 + api_args.len());
        args.push("api".to_string());
        for a in api_args {
            args.push((*a).to_string());
        }
        let res = exec_gh(&args, &self.gh_bin, self.bash_bin.as_deref(), None, None);
        if !res.ok {
            return Err(gh_unavail("gh_cli_unavailable"));
        }
        Ok((res.status.unwrap_or(1), res.stdout, res.stderr))
    }

    fn resolve_policy_authority_sha(
        &self,
        base_repo_full: &str,
        default_branch: &str,
        base_ref: &str,
        live_target_sha: &str,
    ) -> Result<String, B3Error> {
        if default_branch == base_ref {
            return Ok(live_target_sha.to_string());
        }
        let enc_def = encode_uri_component(default_branch);
        let endpoint = format!("repos/{base_repo_full}/branches/{enc_def}");
        let (code, stdout, stderr) = self.invoke(&[&endpoint])?;
        if code != 0 {
            return Err(fail_on_api_failure(
                &stdout,
                &stderr,
                "policy_authority",
                "",
            ));
        }
        let def_obj = parse_json_ctx(&stdout, "default_branch")?;
        let sha_val = def_obj.get("commit").and_then(|c| c.get("sha"));
        let sha = safe_text(sha_val, "policy_authority_sha")?
            .trim()
            .to_ascii_lowercase();
        if !is_hex40(&sha) {
            return Err(gh_err("invalid_policy_authority_sha"));
        }
        Ok(sha)
    }
}

fn flatten_pages(parsed: &JsonValue) -> Vec<&JsonValue> {
    let Some(arr) = parsed.as_array() else {
        return match parsed {
            JsonValue::Null => Vec::new(),
            other => vec![other],
        };
    };
    let mut out = Vec::new();
    for el in arr {
        if let Some(sub) = el.as_array() {
            for item in sub {
                if !matches!(item, JsonValue::Null) {
                    out.push(item);
                }
            }
        } else if !matches!(el, JsonValue::Null) {
            out.push(el);
        }
    }
    out
}

/// Executes `b3 pr verify` GitHub PR pre-merge / post-merge verification.
#[allow(clippy::too_many_arguments)]
pub fn run(
    mode: &str,
    repo_root: &str,
    has_repo_root: bool,
    repo_arg: &str,
    pr_arg: &str,
    gh_bin_arg: &str,
    bash_bin_arg: &str,
) -> Result<(String, i32), B3Error> {
    let mode_trim = mode.trim();
    if mode_trim != "pre-merge" && mode_trim != "post-merge" {
        return Err(gh_err("invalid_mode"));
    }

    let (pr_int, pr_trim) = validate_pr_number(pr_arg).map_err(|_| gh_err("invalid_pr_number"))?;
    let repo_trim = repo_arg.trim();
    if !repo_trim.is_empty() {
        validate_repo_slug(repo_trim).map_err(|_| gh_err("invalid_repo"))?;
    }

    let mut resolved_repo = repo_trim.to_string();
    if has_repo_root || repo_trim.is_empty() {
        let root_dir = if has_repo_root && !repo_root.trim().is_empty() {
            repo_root.trim()
        } else {
            "."
        };
        let no_env: [(&str, &str); 0] = [];
        let git_res = run_git(
            Path::new(root_dir),
            &["remote", "get-url", "origin"],
            &no_env,
            None,
        )
        .map_err(|_| gh_err("git_unavailable"))?;
        if git_res.exit_code != 0 {
            return Err(gh_err("origin_remote_missing"));
        }
        let remote_out = String::from_utf8_lossy(&git_res.stdout);
        let Some(origin_slug) = parse_github_remote_slug(&remote_out) else {
            return Err(gh_err("origin_remote_not_github"));
        };
        if !repo_trim.is_empty() && !repo_trim.eq_ignore_ascii_case(&origin_slug) {
            return Err(gh_err("repo_mismatch"));
        }
        resolved_repo = origin_slug;
    }

    let Some(gh_bin) = resolve_gh_binary(gh_bin_arg) else {
        return Err(gh_unavail("gh_cli_unavailable"));
    };
    let bash_bin = if needs_bash_for_gh(&gh_bin) {
        let Some(b) = resolve_bash_binary(bash_bin_arg) else {
            return Err(gh_unavail("gh_cli_unavailable"));
        };
        Some(b)
    } else {
        None
    };

    let caller = GhApiCaller { gh_bin, bash_bin };

    let pr_endpoint = format!("repos/{resolved_repo}/pulls/{pr_trim}");
    let (pr_code, pr_stdout, pr_stderr) = caller.invoke(&[&pr_endpoint])?;
    if pr_code != 0 {
        return Err(fail_on_api_failure(
            &pr_stdout,
            &pr_stderr,
            "pr",
            "pr_not_found",
        ));
    }
    let pr_obj = parse_json_ctx(&pr_stdout, "pull")?;
    if !pr_obj.is_object() || pr_obj.get("number").and_then(|v| v.as_i64()) != Some(pr_int as i64) {
        return Err(gh_err("pr_number_mismatch"));
    }

    let base_obj = pr_obj.get("base");
    let head_obj = pr_obj.get("head");
    let base_repo_obj = base_obj.and_then(|b| b.get("repo"));
    let head_repo_obj = head_obj.and_then(|h| h.get("repo"));

    let base_repo_full = safe_text(base_repo_obj.and_then(|r| r.get("full_name")), "base_repo")?
        .trim()
        .to_string();
    if base_repo_full.is_empty() || !base_repo_full.eq_ignore_ascii_case(&resolved_repo) {
        return Err(gh_err("cross_repo_mismatch"));
    }
    let default_branch = safe_text(
        base_repo_obj.and_then(|r| r.get("default_branch")),
        "default_branch",
    )?
    .trim()
    .to_string();
    if default_branch.is_empty() {
        return Err(gh_err("missing_default_branch"));
    }

    let base_ref = safe_text(base_obj.and_then(|b| b.get("ref")), "base_ref")?
        .trim()
        .to_string();
    let pr_base_sha = safe_text(base_obj.and_then(|b| b.get("sha")), "pr_base_sha")?
        .trim()
        .to_ascii_lowercase();
    let head_ref = safe_text(head_obj.and_then(|h| h.get("ref")), "head_ref")?
        .trim()
        .to_string();
    let head_sha = safe_text(head_obj.and_then(|h| h.get("sha")), "head_sha")?
        .trim()
        .to_ascii_lowercase();
    if base_ref.is_empty() || !is_hex40(&pr_base_sha) || !is_hex40(&head_sha) {
        return Err(gh_err("incomplete_pr_refs"));
    }

    let pr_state = safe_text(pr_obj.get("state"), "pr_state")?
        .trim()
        .to_ascii_uppercase();
    if pr_state != "OPEN" && pr_state != "CLOSED" {
        return Err(gh_err(&format!("invalid_pr_state({pr_state})")));
    }

    let pr_merged = pr_obj.get("merged").and_then(|v| v.as_bool()) == Some(true);
    let merged_at = match pr_obj.get("merged_at") {
        Some(v) if !matches!(v, JsonValue::Null) => {
            let s = safe_text(Some(v), "merged_at")?.trim().to_string();
            if s.is_empty() {
                "none".to_string()
            } else {
                s
            }
        }
        _ => "none".to_string(),
    };
    let merge_commit_sha = match pr_obj.get("merge_commit_sha") {
        Some(v) if !matches!(v, JsonValue::Null) => {
            let s = safe_text(Some(v), "merge_commit_sha")?
                .trim()
                .to_ascii_lowercase();
            if s.is_empty() {
                "none".to_string()
            } else {
                s
            }
        }
        _ => "none".to_string(),
    };
    if merge_commit_sha != "none" && !is_hex40(&merge_commit_sha) {
        return Err(gh_err("invalid_merge_commit_sha"));
    }

    if mode_trim == "post-merge" {
        let pr_commits = pr_obj.get("commits").and_then(|v| v.as_i64()).unwrap_or(0);
        let mut live_target_sha = "none".to_string();
        let mut compare_status = "not_merged".to_string();
        let mut compare_behind: i64 = -1;
        let policy_authority_ref = default_branch.clone();
        let mut policy_authority_sha = "none".to_string();

        if pr_merged && is_hex40(&merge_commit_sha) {
            let enc_base = encode_uri_component(&base_ref);
            let br_ep = format!("repos/{base_repo_full}/branches/{enc_base}");
            let (br_code, br_out, br_err) = caller.invoke(&[&br_ep])?;
            if br_code != 0 {
                let txt = format!("{br_err}\n{br_out}");
                if contains_http_status(&txt, "404") {
                    compare_status = "target_branch_missing".to_string();
                } else {
                    return Err(fail_on_api_failure(&br_out, &br_err, "target_branch", ""));
                }
            } else {
                let br_obj = parse_json_ctx(&br_out, "target_branch")?;
                let lt_sha = safe_text(
                    br_obj.get("commit").and_then(|c| c.get("sha")),
                    "live_target_sha",
                )?
                .trim()
                .to_ascii_lowercase();
                if !is_hex40(&lt_sha) {
                    return Err(gh_err("invalid_live_target_sha"));
                }
                live_target_sha = lt_sha.clone();

                let cmp_ep =
                    format!("repos/{base_repo_full}/compare/{merge_commit_sha}...{lt_sha}");
                let (cmp_code, cmp_out, cmp_err) = caller.invoke(&[&cmp_ep])?;
                if cmp_code != 0 {
                    return Err(fail_on_api_failure(&cmp_out, &cmp_err, "compare", ""));
                }
                let cmp_obj = parse_json_ctx(&cmp_out, "compare")?;
                let c_stat = safe_text(cmp_obj.get("status"), "compare_status")?
                    .trim()
                    .to_ascii_lowercase();
                if !matches!(
                    c_stat.as_str(),
                    "identical" | "ahead" | "behind" | "diverged"
                ) {
                    return Err(gh_err(&format!("invalid_compare_status({c_stat})")));
                }
                compare_status = c_stat;
                compare_behind = cmp_obj
                    .get("behind_by")
                    .and_then(|v| v.as_i64())
                    .unwrap_or(-1);
            }

            policy_authority_sha = caller.resolve_policy_authority_sha(
                &base_repo_full,
                &default_branch,
                &base_ref,
                &live_target_sha,
            )?;
        }

        let lines = [
            "schema=b3-gh-verify-v2".to_string(),
            "mode=post-merge".to_string(),
            format!("repo={resolved_repo}"),
            format!("pr_number={pr_int}"),
            format!("base_repo={base_repo_full}"),
            format!("default_branch={default_branch}"),
            format!("pr_state={pr_state}"),
            format!("pr_merged={pr_merged}"),
            format!("merged_at={merged_at}"),
            format!("merge_commit_sha={merge_commit_sha}"),
            format!("base_ref={base_ref}"),
            format!("head_sha={head_sha}"),
            format!("pr_commits={pr_commits}"),
            format!("live_target_sha={live_target_sha}"),
            format!("policy_authority_ref={policy_authority_ref}"),
            format!("policy_authority_sha={policy_authority_sha}"),
            format!("compare_status={compare_status}"),
            format!("compare_behind_by={compare_behind}"),
        ];
        return Ok((lines.join("\n"), 0));
    }

    // --- pre-merge mode ---
    let head_repo_full = match head_repo_obj.and_then(|r| r.get("full_name")) {
        Some(v) if !matches!(v, JsonValue::Null) => {
            let s = safe_text(Some(v), "head_repo")?.trim().to_string();
            if s.is_empty() {
                "none".to_string()
            } else {
                s
            }
        }
        _ => "none".to_string(),
    };
    let same_repo =
        head_repo_full != "none" && head_repo_full.eq_ignore_ascii_case(&base_repo_full);
    let pr_draft = pr_obj.get("draft").and_then(|v| v.as_bool()) == Some(true);
    let mergeable_str = match pr_obj.get("mergeable").and_then(|v| v.as_bool()) {
        Some(true) => "true",
        Some(false) => "false",
        None => "unknown",
    };
    let mergeable_state = match pr_obj.get("mergeable_state") {
        Some(v) if !matches!(v, JsonValue::Null) => {
            let s = safe_text(Some(v), "mergeable_state")?
                .trim()
                .to_ascii_lowercase();
            if s.is_empty() {
                "unknown".to_string()
            } else {
                s
            }
        }
        _ => "unknown".to_string(),
    };

    let enc_base_ref = encode_uri_component(&base_ref);
    let base_br_ep = format!("repos/{base_repo_full}/branches/{enc_base_ref}");
    let (b_code, b_out, b_err) = caller.invoke(&[&base_br_ep])?;
    if b_code != 0 {
        return Err(fail_on_api_failure(&b_out, &b_err, "target_branch", ""));
    }
    let base_br_obj = parse_json_ctx(&b_out, "target_branch")?;
    let live_target_sha = safe_text(
        base_br_obj.get("commit").and_then(|c| c.get("sha")),
        "live_target_sha",
    )?
    .trim()
    .to_ascii_lowercase();
    if !is_hex40(&live_target_sha) {
        return Err(gh_err("invalid_live_target_sha"));
    }

    let policy_authority_ref = default_branch.clone();
    let policy_authority_sha = caller.resolve_policy_authority_sha(
        &base_repo_full,
        &default_branch,
        &base_ref,
        &live_target_sha,
    )?;

    let files_ep = format!("repos/{base_repo_full}/pulls/{pr_trim}/files?per_page=100");
    let (f_code, f_out, f_err) = caller.invoke(&["--paginate", "--slurp", &files_ep])?;
    if f_code != 0 {
        return Err(fail_on_api_failure(&f_out, &f_err, "pr_files", ""));
    }
    let files_parsed = parse_json_ctx(&f_out, "pr_files")?;
    let mut pr_changed_raw = Vec::new();
    for fi in flatten_pages(&files_parsed) {
        if !fi.is_object() {
            continue;
        }
        if let Some(fname) = fi.get("filename").and_then(|v| v.as_str()) {
            if !fname.is_empty() {
                if has_control_chars(fname) {
                    return Err(gh_err("control_chars_in_response(pr_file)"));
                }
                pr_changed_raw.push(fname.to_string());
            }
        }
        if let Some(prev) = fi.get("previous_filename").and_then(|v| v.as_str()) {
            if !prev.is_empty() {
                if has_control_chars(prev) {
                    return Err(gh_err("control_chars_in_response(pr_prev_file)"));
                }
                pr_changed_raw.push(prev.to_string());
            }
        }
    }
    let pr_changed_sorted = sort_ordinal(pr_changed_raw, false);

    let cr_ep = format!("repos/{base_repo_full}/commits/{head_sha}/check-runs?per_page=100");
    let (cr_code, cr_out, cr_err) = caller.invoke(&["--paginate", "--slurp", &cr_ep])?;
    if cr_code != 0 {
        return Err(fail_on_api_failure(&cr_out, &cr_err, "check_runs", ""));
    }
    let cr_parsed = parse_json_ctx(&cr_out, "check_runs")?;
    let cr_pages: Vec<&JsonValue> = match cr_parsed.as_array() {
        Some(arr) => arr.iter().collect(),
        None => vec![&cr_parsed],
    };
    struct CheckRunInfo {
        id: i64,
        status: String,
        conclusion: String,
    }
    let mut latest_checks: HashMap<String, CheckRunInfo> = HashMap::new();
    for pg in cr_pages {
        let Some(runs) = pg.get("check_runs").and_then(|v| v.as_array()) else {
            continue;
        };
        for run in runs {
            if !run.is_object() {
                continue;
            }
            if let Some(r_sha) = run.get("head_sha").and_then(|v| v.to_text_string()) {
                if !r_sha.is_empty() && r_sha.trim().to_ascii_lowercase() != head_sha {
                    return Err(gh_err("check_run_sha_mismatch"));
                }
            }
            let name = safe_text(run.get("name"), "check_name")?.trim().to_string();
            if name.is_empty() {
                continue;
            }
            let app_id = run
                .get("app")
                .and_then(|a| a.get("id"))
                .and_then(|v| v.to_text_string())
                .unwrap_or_else(|| "0".to_string());
            let c_key = format!("{app_id}\0{name}");
            let id = run.get("id").and_then(|v| v.as_i64()).unwrap_or(0);
            let status = safe_text(run.get("status"), "check_status")?
                .trim()
                .to_ascii_lowercase();
            let conclusion = safe_text(run.get("conclusion"), "check_conclusion")?
                .trim()
                .to_ascii_lowercase();
            let replace = match latest_checks.get(&c_key) {
                None => true,
                Some(prev) => id >= prev.id,
            };
            if replace {
                latest_checks.insert(
                    c_key,
                    CheckRunInfo {
                        id,
                        status,
                        conclusion,
                    },
                );
            }
        }
    }

    let st_ep = format!("repos/{base_repo_full}/commits/{head_sha}/status?per_page=100");
    let (st_code, st_out, st_err) = caller.invoke(&["--paginate", "--slurp", &st_ep])?;
    if st_code != 0 {
        return Err(fail_on_api_failure(&st_out, &st_err, "commit_status", ""));
    }
    let st_parsed = parse_json_ctx(&st_out, "commit_status")?;
    let st_pages: Vec<&JsonValue> = match st_parsed.as_array() {
        Some(arr) => arr.iter().collect(),
        None => vec![&st_parsed],
    };
    let mut latest_statuses: HashMap<String, String> = HashMap::new();
    let mut combined_status_failed = false;
    let mut combined_status_pending = false;
    for st_obj in st_pages {
        if !st_obj.is_object() {
            continue;
        }
        if let Some(s_sha) = st_obj.get("sha").and_then(|v| v.to_text_string()) {
            if !s_sha.is_empty() && s_sha.trim().to_ascii_lowercase() != head_sha {
                return Err(gh_err("commit_status_sha_mismatch"));
            }
        }
        let st_total = st_obj
            .get("total_count")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let st_top = safe_text(st_obj.get("state"), "status_top_state")?
            .trim()
            .to_ascii_lowercase();
        if st_total > 0 {
            if st_top == "failure" || st_top == "error" {
                combined_status_failed = true;
            } else if st_top == "pending" {
                combined_status_pending = true;
            }
        }
        if let Some(items) = st_obj.get("statuses").and_then(|v| v.as_array()) {
            for st_item in items {
                if !st_item.is_object() {
                    continue;
                }
                let ctx = safe_text(st_item.get("context"), "status_context")?
                    .trim()
                    .to_string();
                if ctx.is_empty() || latest_statuses.contains_key(&ctx) {
                    continue;
                }
                let state = safe_text(st_item.get("state"), "status_state")?
                    .trim()
                    .to_ascii_lowercase();
                latest_statuses.insert(ctx, state);
            }
        }
    }

    let mut has_failed = combined_status_failed;
    let mut has_pending = false;
    let mut total_checks_seen = 0usize;
    let mut success_count = 0usize;

    for c in latest_checks.values() {
        total_checks_seen += 1;
        if c.status != "completed" {
            has_pending = true;
        } else if c.conclusion == "success" {
            success_count += 1;
        } else if c.conclusion != "neutral" && c.conclusion != "skipped" {
            has_failed = true;
        }
    }
    for st in latest_statuses.values() {
        total_checks_seen += 1;
        if st == "success" {
            success_count += 1;
        } else if st == "pending" {
            has_pending = true;
        } else {
            has_failed = true;
        }
    }
    if combined_status_pending && latest_statuses.is_empty() {
        has_pending = true;
    }

    let gh_ci_status = if has_failed {
        "FAIL"
    } else if has_pending {
        "PENDING"
    } else if total_checks_seen == 0 || success_count == 0 {
        "UNKNOWN"
    } else {
        "PASS"
    };

    let mut out_lines = vec![
        "schema=b3-gh-verify-v2".to_string(),
        "mode=pre-merge".to_string(),
        format!("repo={resolved_repo}"),
        format!("pr_number={pr_trim}"),
        format!("base_repo={base_repo_full}"),
        format!("head_repo={head_repo_full}"),
        format!("same_repo={same_repo}"),
        format!("default_branch={default_branch}"),
        format!("pr_state={pr_state}"),
        format!("pr_merged={pr_merged}"),
        format!("pr_draft={pr_draft}"),
        format!("base_ref={base_ref}"),
        format!("pr_base_sha={pr_base_sha}"),
        format!("live_target_sha={live_target_sha}"),
        format!("head_ref={head_ref}"),
        format!("head_sha={head_sha}"),
        format!("policy_authority_ref={policy_authority_ref}"),
        format!("policy_authority_sha={policy_authority_sha}"),
        format!("mergeable={mergeable_str}"),
        format!("mergeable_state={mergeable_state}"),
        format!("gh_ci_status={gh_ci_status}"),
    ];
    for cf in pr_changed_sorted {
        out_lines.push(format!("pr_changed_file={cf}"));
    }
    Ok((out_lines.join("\n"), 0))
}
