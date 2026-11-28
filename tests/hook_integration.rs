//! End-to-end behavioral, host-protocol, F01-F07 regression, and installer lifecycle
//! tests for `b3 hook {run,install,uninstall,verify,status}`.

mod common;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use common::{b3_bin, git_in, init_fresh_git_repo, run_b3, run_b3_env, write_lf, TempDirGuard};

fn run_cmd_stdin(
    prog: &str,
    args: &[&str],
    cwd: Option<&Path>,
    stdin_data: &str,
    envs: &[(&str, &str)],
) -> (i32, String, String) {
    let mut cmd = Command::new(prog);
    cmd.args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    for (k, v) in envs {
        cmd.env(k, v);
    }
    let mut child = cmd.spawn().unwrap_or_else(|e| panic!("spawn {prog}: {e}"));
    {
        use std::io::{ErrorKind, Write};
        let mut sin = child.stdin.take().expect("stdin");
        if let Err(e) = sin.write_all(stdin_data.as_bytes()) {
            if e.kind() != ErrorKind::BrokenPipe {
                panic!("write stdin: {e}");
            }
        }
    }
    let out = child.wait_with_output().expect("wait child");
    (
        out.status.code().unwrap_or(1),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

fn run_b3_stdin(args: &[&str], stdin_data: &str, envs: &[(&str, &str)]) -> (i32, String, String) {
    run_cmd_stdin(b3_bin(), args, None, stdin_data, envs)
}

fn run_hook_stdin(
    host: &str,
    event: Option<&str>,
    repo_root: Option<&str>,
    mode: Option<&str>,
    cwd: Option<&Path>,
    stdin_data: &str,
    envs: &[(&str, &str)],
) -> (i32, String, String) {
    let mut args = vec!["hook", "run", "--host", host];
    if let Some(ev) = event {
        args.extend(["--event", ev]);
    }
    if let Some(r) = repo_root {
        args.extend(["--repo-root", r]);
    }
    if let Some(m) = mode {
        args.extend(["--mode", m]);
    }
    let mut full_envs = vec![
        ("B3_HOOK_ACTIVE", ""),
        ("B3_HOOK_MODE", ""),
        ("B3_CONFIG_PERSONAL", ""),
        ("B3_MODELS_PERSONAL", ""),
    ];
    full_envs.extend_from_slice(envs);
    run_cmd_stdin(b3_bin(), &args, cwd, stdin_data, &full_envs)
}

fn hook_ctl(
    action: &str,
    host: &str,
    repo: &str,
    home: Option<&str>,
    extra: &[&str],
) -> (i32, String, String) {
    let mut args = vec![
        "hook",
        action,
        "--host",
        host,
        "--scope",
        "project",
        "--repo-root",
        repo,
    ];
    if let Some(h) = home {
        args.extend(["--user-home", h]);
    }
    if action == "install" {
        args.extend(["--b3-bin", b3_bin()]);
    }
    args.extend_from_slice(extra);
    run_b3(&args)
}

fn json_str(s: &str) -> String {
    b3::json::JsonValue::str(s).to_json_string()
}
fn cursor_write(path: &str, root: &str) -> String {
    format!(
        r#"{{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{{"file_path":{}}},"cwd":{}}}"#,
        json_str(path),
        json_str(root)
    )
}
fn claude_bash(cmd: &str, root: &str) -> String {
    format!(
        r#"{{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{{"command":{}}},"cwd":{}}}"#,
        json_str(cmd),
        json_str(root)
    )
}

fn verify_receipt(repo_str: &str, receipt_rel: &str, rel_paths: &str) {
    let (c, out, err) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        repo_str,
        "--verify-cmd",
        "echo ok",
        "--receipt-path",
        receipt_rel,
        "--task-id",
        "F01",
        "--relevant-paths",
        rel_paths,
    ]);
    assert_eq!(c, 0, "verify-run failed: out={out} err={err}");
}

fn git_iso_status(tmp: &TempDirGuard, dir: &Path, args: &[&str]) -> (i32, String, String) {
    let gcfg = tmp.path.join("isolated.gitconfig");
    if !gcfg.exists() {
        write_lf(&gcfg, "");
    }
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_CONFIG_GLOBAL", &gcfg)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .expect("git");
    (
        out.status.code().unwrap_or(-1),
        common::norm_lf(&out.stdout),
        common::norm_lf(&out.stderr),
    )
}

fn setup_remote_repo(tmp: &TempDirGuard, name: &str, governed: bool) -> (PathBuf, PathBuf) {
    let bare = tmp.path.join(format!("{name}-origin.git"));
    fs::create_dir_all(&bare).expect("bare dir");
    assert!(Command::new("git")
        .args(["init", "--bare"])
        .arg(&bare)
        .output()
        .expect("bare")
        .status
        .success());
    git_in(&bare, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    let repo = tmp.path.join(name);
    let _ = init_fresh_git_repo(&repo);
    if governed {
        write_lf(
            &repo.join(".b3/research-policy.json"),
            r#"{"auto_merge":"disabled","protected_paths":["locked/"],"allow_protected_paths":false,"require_ci":false,"require_review":false}"#,
        );
        git_in(&repo, &["add", ".b3/research-policy.json"]);
        git_in(&repo, &["commit", "-m", "add research policy"]);
    }
    git_in(&repo, &["remote", "add", "origin", bare.to_str().unwrap()]);
    git_in(&repo, &["push", "-u", "origin", "main"]);
    git_in(&repo, &["remote", "set-head", "origin", "main"]);
    let (c, out, err) = hook_ctl("install", "git", repo.to_str().unwrap(), None, &[]);
    assert_eq!(c, 0, "git hook install failed: out={out} err={err}");
    (repo, bare)
}

#[test]
fn host_protocol_fixtures_and_core_blocking_advisory_scenarios() {
    let tmp = TempDirGuard::new("hook-proto");
    let repo = &tmp.path;
    let _base = init_fresh_git_repo(repo);
    let r = repo.to_str().expect("repo utf8");

    // 1. Cursor preToolUse allow + deny (exit 2), afterFileEdit & stop return "{}" without permission key
    let (c_ca, out_ca, _) = run_hook_stdin(
        "cursor",
        None,
        Some(r),
        None,
        None,
        &cursor_write("src/ok.rs", r),
        &[],
    );
    assert_eq!(c_ca, 0);
    assert!(out_ca.contains(r#""permission":"allow""#), "{out_ca}");
    let (c_cd, out_cd, err_cd) = run_hook_stdin(
        "cursor",
        None,
        Some(r),
        None,
        None,
        &cursor_write(".env.production", r),
        &[],
    );
    assert_eq!(c_cd, 2, "out={out_cd} err={err_cd}");
    assert!(out_cd.contains(r#""permission":"deny""#), "{out_cd}");
    for ev in ["afterFileEdit", "stop"] {
        let p = format!(r#"{{"hook_event_name":"{ev}","cwd":{}}}"#, json_str(r));
        let (c, out, _) = run_hook_stdin("cursor", None, Some(r), None, None, &p, &[]);
        assert_eq!((c, out.trim()), (0, "{}"));
        assert!(!out.contains("permission"));
    }

    // 2. Claude Code PreToolUse Bash deny (exit 2 + stderr) & PostToolUse advisory (exit 0)
    let (c_cld, out_cld, err_cld) = run_hook_stdin(
        "claude",
        None,
        Some(r),
        None,
        None,
        &claude_bash("git reset --hard HEAD~1", r),
        &[],
    );
    assert_eq!(c_cld, 2, "err={err_cld}");
    assert!(out_cld.trim().is_empty() && !err_cld.trim().is_empty());
    let claude_post = format!(
        r#"{{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{{"file_path":"src/lib.rs"}},"cwd":{}}}"#,
        json_str(r)
    );
    assert_eq!(
        run_hook_stdin("claude", None, Some(r), None, None, &claude_post, &[]).0,
        0
    );

    // 3. Codex apply_patch traversal block + .codex/hooks.json nests under "hooks"
    let codex_deny = format!(
        r#"{{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{{"patch":"*** Begin Patch\n*** Update File: ../escape.txt\n*** End Patch"}},"cwd":{}}}"#,
        json_str(r)
    );
    assert_eq!(
        run_hook_stdin("codex", None, Some(r), None, None, &codex_deny, &[]).0,
        2
    );
    let codex_proj = tmp.path.join("codex-proj");
    fs::create_dir_all(&codex_proj).unwrap();
    assert_eq!(
        hook_ctl("install", "codex", codex_proj.to_str().unwrap(), None, &[]).0,
        0
    );
    let codex_cfg =
        b3::json::parse_json(&fs::read_to_string(codex_proj.join(".codex/hooks.json")).unwrap())
            .unwrap();
    assert!(codex_cfg.get("PreToolUse").is_none());
    let codex_hooks = codex_cfg.get("hooks").expect("nested hooks");
    assert!(
        codex_hooks.get("PreToolUse").is_some()
            && codex_hooks.get("PostToolUse").is_some()
            && codex_hooks.get("Stop").is_some()
    );

    // 4. Antigravity PreToolUse (run_command & CORTEX_STEP_TYPE_RUN_COMMAND), PostToolUse -> {}, Stop -> {"decision":"allow"}
    for tool in ["run_command", "CORTEX_STEP_TYPE_RUN_COMMAND"] {
        let p = format!(
            r#"{{"hookEventName":"PreToolUse","conversationId":"c1","cwd":{},"workspacePaths":[{}],"toolCall":{{"id":"t1","name":"{tool}","args":{{"CommandLine":"git commit --no-verify -m x"}}}}}}"#,
            json_str(r),
            json_str(r)
        );
        let (c, out, _) = run_hook_stdin("antigravity", None, Some(r), None, None, &p, &[]);
        assert_eq!(c, 0);
        assert!(
            out.contains(r#""decision":"deny""#),
            "tool={tool} out={out}"
        );
    }
    let agy_post = format!(
        r#"{{"hookEventName":"PostToolUse","cwd":{},"toolCall":{{"name":"write_to_file","args":{{"TargetFile":"src/lib.rs"}}}}}}"#,
        json_str(r)
    );
    assert_eq!(
        (
            run_hook_stdin("antigravity", None, Some(r), None, None, &agy_post, &[]).0,
            run_hook_stdin("antigravity", None, Some(r), None, None, &agy_post, &[])
                .1
                .trim()
                .to_string()
        ),
        (0, "{}".into())
    );
    let agy_stop = format!(
        r#"{{"hookEventName":"Stop","conversationId":"c1","continuationActive":true,"cwd":{}}}"#,
        json_str(r)
    );
    let (c_ags, out_ags, _) =
        run_hook_stdin("antigravity", None, Some(r), None, None, &agy_stop, &[]);
    assert_eq!(c_ags, 0);
    assert!(out_ags.contains(r#""decision":"allow""#), "{out_ags}");

    // 5. Unsupported event, invalid JSON, deep JSON, --repo-root precedence, SEC-06
    let (c_unsup, out_unsup, _) = run_hook_stdin(
        "cursor",
        None,
        Some(r),
        None,
        None,
        r#"{"hook_event_name":"futureUnknownEvent","cwd":"."}"#,
        &[],
    );
    assert_eq!((c_unsup, out_unsup.trim()), (0, "{}"));
    for bad in [
        "{not-json".to_string(),
        format!("{}{}", "[".repeat(200), "]".repeat(200)),
    ] {
        let (c, out, _) = run_hook_stdin("cursor", None, Some(r), None, None, &bad, &[]);
        assert_eq!(c, 2);
        assert!(out.contains(r#""permission":"deny""#), "{out}");
    }
    let other_dir = tmp.path.join("untrusted-off-repo");
    write_lf(
        &other_dir.join(".b3/models.md"),
        "```yaml\nhooks:\n  enabled: false\n  mode: off\n```\n",
    );
    let spoof = format!(
        r#"{{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{{"file_path":".env"}},"project_root":{},"cwd":{}}}"#,
        json_str(other_dir.to_str().unwrap()),
        json_str(other_dir.to_str().unwrap())
    );
    assert_eq!(
        run_hook_stdin("cursor", None, Some(r), None, None, &spoof, &[]).0,
        2
    );

    fs::create_dir_all(repo.join(".b3")).unwrap();
    for bad_cmd in ["git add ./", "git add .B3", "echo \u{001b}hi"] {
        assert_eq!(
            run_hook_stdin(
                "claude",
                None,
                Some(r),
                None,
                None,
                &claude_bash(bad_cmd, r),
                &[]
            )
            .0,
            2,
            "{bad_cmd:?}"
        );
    }
}

#[test]
fn f01_before_commit_verify_receipt_and_allowed_paths() {
    let tmp = TempDirGuard::new("hook-f01");
    let repo = &tmp.path;
    let _ = init_fresh_git_repo(repo);
    git_in(repo, &["commit", "--allow-empty", "-m", "head-base"]);
    let r = repo.to_str().expect("repo utf8");

    write_lf(&repo.join("src/app.txt"), "v2\n");
    git_in(repo, &["add", "src/app.txt"]);
    let receipt = ".b3/ship/verify/f01.verify";
    verify_receipt(r, receipt, "src/app.txt");

    let run_pc = |rec: &str, allowed: &str| {
        run_hook_stdin(
            "git",
            Some("pre-commit"),
            Some(r),
            None,
            None,
            "",
            &[("B3_VERIFY_RECEIPT", rec), ("B3_ALLOWED_PATHS", allowed)],
        )
    };

    // (a) Valid receipt -> exit 0
    assert_eq!(run_pc(receipt, "src/app.txt").0, 0);

    // (b) Same staged tree + modified WT -> blocked (exit 1)
    write_lf(&repo.join("src/app.txt"), "v2-dirty-wt\n");
    assert_eq!(run_pc(receipt, "src/app.txt").0, 1);
    write_lf(&repo.join("src/app.txt"), "v2\n");

    // (c) Mismatched scope & stale tree_hash receipt -> blocked
    let mismatch_rec = ".b3/ship/verify/f01-mismatch.verify";
    verify_receipt(r, mismatch_rec, "docs/guide.md");
    assert_eq!(run_pc(mismatch_rec, "src/app.txt").0, 1);

    let stale_rec = ".b3/ship/verify/f01-stale.verify";
    let stale_body: String = fs::read_to_string(repo.join(receipt))
        .unwrap()
        .lines()
        .map(|l| {
            if l.starts_with("tree_hash=") {
                format!("tree_hash={}", "0".repeat(40))
            } else {
                l.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    write_lf(&repo.join(stale_rec), &stale_body);
    assert_eq!(run_pc(stale_rec, "src/app.txt").0, 1);

    // (e) Changed B3_ALLOWED_PATHS excluding staged file -> blocked
    assert_eq!(run_pc(receipt, "docs/guide.md").0, 1);

    // (d) Same staged tree + moved non-ancestor HEAD -> blocked
    let tree_before = git_in(repo, &["write-tree"]);
    git_in(
        repo,
        &[
            "commit",
            "--amend",
            "--only",
            "--allow-empty",
            "-m",
            "moved-head",
        ],
    );
    assert_eq!(tree_before, git_in(repo, &["write-tree"]));
    assert_eq!(run_pc(receipt, "src/app.txt").0, 1);
}

#[test]
fn f02_f03_git_remote_governance_and_worktree_enforcement() {
    let tmp = TempDirGuard::new("hook-f02-f03");

    // (a) Non-governed repo: push & merge succeed
    let (plain, _) = setup_remote_repo(&tmp, "plain", false);
    git_in(&plain, &["checkout", "-b", "feat/ok"]);
    write_lf(&plain.join("src/f.txt"), "ok\n");
    git_in(&plain, &["add", "src/f.txt"]);
    git_in(&plain, &["commit", "-m", "feat"]);
    assert_eq!(
        git_iso_status(&tmp, &plain, &["push", "origin", "feat/ok"]).0,
        0
    );
    git_in(&plain, &["checkout", "main"]);
    assert_eq!(
        git_iso_status(
            &tmp,
            &plain,
            &["merge", "--no-ff", "feat/ok", "-m", "merge ok"]
        )
        .0,
        0
    );

    // (b) Governed repo with .b3/research-policy.json on origin/main
    let (gov, _) = setup_remote_repo(&tmp, "gov", true);
    git_in(&gov, &["checkout", "-b", "feat/clean"]);
    write_lf(&gov.join("src/app.txt"), "clean feature\n");
    git_in(&gov, &["add", "src/app.txt"]);
    git_in(&gov, &["commit", "-m", "clean change"]);
    assert_eq!(
        git_iso_status(&tmp, &gov, &["push", "origin", "feat/clean"]).0,
        0
    );

    // Editing or deleting WT .b3/research-policy.json -> blocked
    write_lf(
        &gov.join(".b3/research-policy.json"),
        r#"{"auto_merge":"authorized"}"#,
    );
    let (c_ed, _, err_ed) = git_iso_status(
        &tmp,
        &gov,
        &["push", "origin", "feat/clean:refs/heads/feat/wt-edit"],
    );
    assert!(
        c_ed != 0 && err_ed.contains("policy_modified_in_pr"),
        "{err_ed}"
    );
    fs::remove_file(gov.join(".b3/research-policy.json")).unwrap();
    let (c_del, _, err_del) = git_iso_status(
        &tmp,
        &gov,
        &["push", "origin", "feat/clean:refs/heads/feat/wt-del"],
    );
    assert!(
        c_del != 0 && err_del.contains("policy_modified_in_pr"),
        "{err_del}"
    );
    git_in(&gov, &["checkout", "--", ".b3/research-policy.json"]);

    // Commit tampering policy or touching locked/secret.txt -> blocked
    git_in(&gov, &["checkout", "-b", "feat/bad-pol", "main"]);
    write_lf(
        &gov.join(".b3/research-policy.json"),
        r#"{"auto_merge":"authorized"}"#,
    );
    git_in(&gov, &["add", ".b3/research-policy.json"]);
    git_in(&gov, &["commit", "-m", "tamper policy"]);
    let (c_bp, _, err_bp) = git_iso_status(&tmp, &gov, &["push", "origin", "feat/bad-pol"]);
    assert!(
        c_bp != 0 && err_bp.contains("policy_modified_in_pr"),
        "{err_bp}"
    );

    git_in(&gov, &["checkout", "-b", "feat/bad-prot", "main"]);
    write_lf(&gov.join("locked/secret.txt"), "locked\n");
    git_in(&gov, &["add", "locked/secret.txt"]);
    git_in(&gov, &["commit", "-m", "touch locked"]);
    let (c_bprot, _, err_bprot) = git_iso_status(&tmp, &gov, &["push", "origin", "feat/bad-prot"]);
    assert!(
        c_bprot != 0 && err_bprot.contains("protected_paths=locked/secret.txt"),
        "{err_bprot}"
    );

    // SEC-2: Orphan commit dropping .b3/research-policy.json must block push (policy_modified_in_pr)
    git_in(&gov, &["checkout", "--orphan", "feat/orphan-drop"]);
    git_in(&gov, &["rm", "-rf", "--cached", "."]);
    let _ = fs::remove_file(gov.join(".b3/research-policy.json"));
    write_lf(&gov.join("src/orphan.txt"), "orphan\n");
    git_in(&gov, &["add", "src/orphan.txt"]);
    git_in(&gov, &["commit", "-m", "orphan without policy"]);
    let (c_orp, _, err_orp) = git_iso_status(&tmp, &gov, &["push", "origin", "feat/orphan-drop"]);
    assert!(
        c_orp != 0 && err_orp.contains("policy_modified_in_pr"),
        "orphan push dropping policy must block: {err_orp}"
    );
    git_in(&gov, &["clean", "-fd"]);

    // Direct push & multi-ref push from feat/clean to refs/heads/main -> blocked
    git_in(&gov, &["checkout", "feat/clean"]);
    for refspecs in [
        vec!["push", "origin", "feat/clean:refs/heads/main"],
        vec![
            "push",
            "origin",
            "feat/clean:refs/heads/feat/clean",
            "feat/clean:refs/heads/main",
        ],
    ] {
        let (c, _, e) = git_iso_status(&tmp, &gov, &refspecs);
        assert!(c != 0 && e.contains("direct_push_blocked"), "{e}");
    }

    // Tag push & feature branch delete -> exit 0; deleting governed main -> blocked
    git_in(&gov, &["tag", "v1.0.0"]);
    assert_eq!(
        git_iso_status(&tmp, &gov, &["push", "origin", "v1.0.0"]).0,
        0
    );
    assert_eq!(
        git_iso_status(&tmp, &gov, &["push", "origin", ":refs/heads/feat/clean"]).0,
        0
    );
    let (c_dm, _, err_dm) = git_iso_status(&tmp, &gov, &["push", "origin", ":refs/heads/main"]);
    assert!(
        c_dm != 0 && err_dm.contains("protected_target_deletion"),
        "{err_dm}"
    );

    // Linked worktree push & pre-merge-commit enforce trunk policy even when WT lacks policy file
    let wt_dir = tmp.path.join("gov-wt");
    git_in(
        &gov,
        &[
            "worktree",
            "add",
            "-b",
            "feat/wt-bad",
            wt_dir.to_str().unwrap(),
            "origin/main",
        ],
    );
    write_lf(&wt_dir.join("locked/wt.txt"), "wt\n");
    git_in(&wt_dir, &["add", "locked/wt.txt"]);
    git_in(&wt_dir, &["commit", "-m", "wt locked"]);
    fs::remove_file(wt_dir.join(".b3/research-policy.json")).unwrap();
    let (c_wtp, _, err_wtp) = git_iso_status(&tmp, &wt_dir, &["push", "origin", "feat/wt-bad"]);
    assert!(
        c_wtp != 0 && err_wtp.contains("policy_modified_in_pr"),
        "{err_wtp}"
    );

    let wt_merge = tmp.path.join("gov-wt-merge");
    git_in(
        &gov,
        &[
            "worktree",
            "add",
            "--detach",
            wt_merge.to_str().unwrap(),
            "origin/main",
        ],
    );
    let (c_mf, _, err_mf) = git_iso_status(
        &tmp,
        &wt_merge,
        &["merge", "--no-ff", "feat/clean", "-m", "merge"],
    );
    assert!(
        c_mf != 0 && err_mf.contains("auto_merge=disabled"),
        "{err_mf}"
    );
    let _ = git_iso_status(&tmp, &wt_merge, &["merge", "--abort"]);

    assert_eq!(
        git_iso_status(
            &tmp,
            &wt_merge,
            &["merge", "--no-commit", "--no-ff", "feat/clean"]
        )
        .0,
        0
    );
    fs::remove_file(wt_merge.join(".b3/research-policy.json")).unwrap();
    let (c_pmc, _, err_pmc) = run_hook_stdin(
        "git",
        Some("pre-merge-commit"),
        Some(wt_merge.to_str().unwrap()),
        None,
        None,
        "",
        &[],
    );
    assert!(
        c_pmc == 1 && err_pmc.contains("policy_modified_in_pr"),
        "{err_pmc}"
    );
}

#[test]
fn f04_f07_tier0_zero_git_worktree_containment_and_guard_coexistence() {
    let tmp = TempDirGuard::new("hook-f04-f07");
    let (main_repo, wt_repo, unmanaged, empty_path) = (
        tmp.path.join("main-repo"),
        tmp.path.join("wt"),
        tmp.path.join("unmanaged"),
        tmp.path.join("empty-path"),
    );
    fs::create_dir_all(&unmanaged).unwrap();
    fs::create_dir_all(&empty_path).unwrap();
    let base_sha = init_fresh_git_repo(&main_repo);
    git_in(
        &main_repo,
        &[
            "worktree",
            "add",
            "-b",
            "feat/wt",
            wt_repo.to_str().unwrap(),
            "HEAD",
        ],
    );
    let r = main_repo.to_str().unwrap();

    // 1. BeforeCommand allows `gh pr merge 42`
    assert_eq!(
        run_hook_stdin(
            "claude",
            None,
            Some(r),
            None,
            None,
            &claude_bash("gh pr merge 42", r),
            &[]
        )
        .0,
        0
    );

    // 2. Sibling linked worktree write containment
    for (target, code) in [
        (wt_repo.join("src/ok.rs"), 0),
        (wt_repo.join(".env"), 2),
        (unmanaged.join("src/ok.rs"), 2),
    ] {
        assert_eq!(
            run_hook_stdin(
                "cursor",
                None,
                Some(r),
                None,
                None,
                &cursor_write(target.to_str().unwrap(), r),
                &[]
            )
            .0,
            code
        );
    }

    // 3. Tier 0 runs with 0 Git subprocesses (empty PATH)
    let ep = empty_path.to_str().unwrap();
    for (host, payload, code) in [
        ("cursor", cursor_write("src/ok.rs", r), 0),
        ("cursor", cursor_write(".env", r), 2),
        ("claude", claude_bash("gh pr merge 42", r), 0),
        ("claude", claude_bash("git push --force", r), 2),
    ] {
        assert_eq!(
            run_hook_stdin(host, None, Some(r), None, None, &payload, &[("PATH", ep)]).0,
            code
        );
    }

    // 4. Recursion guard & parallel worker ownership
    let (c_rec, out_rec, _) = run_b3_stdin(
        &["hook", "run", "--host", "cursor", "--repo-root", r],
        &cursor_write(".env", r),
        &[("B3_HOOK_ACTIVE", "1")],
    );
    assert_eq!(c_rec, 0);
    assert!(out_rec.contains(r#""permission":"allow""#));
    let p = format!(
        r#"{{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{{"file_path":"src/a.txt"}},"cwd":{}}}"#,
        json_str(r)
    );
    std::thread::scope(|s| {
        let h1 = s.spawn(|| {
            run_hook_stdin(
                "claude",
                None,
                Some(r),
                None,
                None,
                &p,
                &[("B3_WORKER_ALLOWED_PATHS", "src/a.txt")],
            )
        });
        let h2 = s.spawn(|| {
            run_hook_stdin(
                "claude",
                None,
                Some(r),
                None,
                None,
                &p,
                &[("B3_WORKER_ALLOWED_PATHS", "src/b.txt")],
            )
        });
        assert_eq!((h1.join().unwrap().0, h2.join().unwrap().0), (0, 2));
    });

    // 5. F07: workflow guards succeed under enforce & off, and B3_HOOK_ACTIVE=1 never disables them
    write_lf(&main_repo.join("src/app.txt"), "updated\n");
    git_in(&main_repo, &["add", "src/app.txt"]);
    for (idx, mode) in ["enforce", "off"].iter().enumerate() {
        write_lf(
            &main_repo.join(".b3/models.md"),
            &format!("```yaml\nhooks:\n  enabled: true\n  mode: {mode}\n```\n"),
        );
        let slug = format!("coexist-{idx}");
        let rec = format!(".b3/ship/verify/{slug}.verify");
        assert_eq!(
            run_b3(&["guard", "new-run", "--repo-root", r, "--slug", &slug]).0,
            0
        );
        assert_eq!(
            run_b3(&[
                "guard",
                "check-wave",
                "--repo-root",
                r,
                "--expected-base-sha",
                &base_sha,
                "--partition",
                "--ignore-dirty-paths",
                ".b3/models.md",
                "--verified-dirty-paths",
                "src/app.txt",
                "--wave-specs",
                "T1=src/a.txt;T2=src/b.txt"
            ])
            .0,
            0
        );
        verify_receipt(r, &rec, "src/app.txt");
        assert_eq!(
            run_b3(&[
                "guard",
                "mechanical-check",
                "--repo-root",
                r,
                "--base-sha",
                &base_sha,
                "--allowed-paths",
                "src/app.txt",
                "--ignore-dirty-paths",
                ".b3/models.md"
            ])
            .0,
            0
        );
        assert_eq!(
            run_b3(&[
                "guard",
                "precommit",
                "--repo-root",
                r,
                "--allowed-paths",
                "src/app.txt",
                "--require-verify-receipt",
                &rec
            ])
            .0,
            0
        );
    }

    write_lf(&main_repo.join(".env"), "SECRET=1\n");
    git_in(&main_repo, &["add", "-f", ".env"]);
    assert_ne!(
        run_b3_env(
            &[
                "guard",
                "precommit",
                "--repo-root",
                r,
                "--allowed-paths",
                "src/app.txt"
            ],
            None,
            &[("B3_HOOK_ACTIVE", "1")],
            &[]
        )
        .0,
        0
    );
    git_in(&main_repo, &["reset", "HEAD", "--", ".env"]);
    fs::remove_file(main_repo.join(".env")).unwrap();
    write_lf(&main_repo.join("src/undeclared.txt"), "bad\n");
    assert_ne!(
        run_b3_env(
            &[
                "guard",
                "mechanical-check",
                "--repo-root",
                r,
                "--base-sha",
                &base_sha,
                "--allowed-paths",
                "src/app.txt"
            ],
            None,
            &[("B3_HOOK_ACTIVE", "1")],
            &[]
        )
        .0,
        0
    );
}

#[test]
fn f05_mode_matrix_enforce_audit_off() {
    let tmp = TempDirGuard::new("hook-f05");
    let repo = &tmp.path;
    let _ = init_fresh_git_repo(repo);
    let r = repo.to_str().unwrap();

    let huge = "a".repeat(1024 * 1024 + 32);
    for (label, host, payload) in [
        ("invalid_json", "cursor", "{not-json".to_string()),
        ("oversized_1mib", "cursor", huge),
        ("non_object_array", "cursor", "[]".into()),
        ("control_chars", "claude", r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo \u001b"}}"#.into()),
        ("missing_event_name", "cursor", r#"{"tool_name":"Write","tool_input":{"file_path":".env"},"cwd":"."}"#.into()),
        ("missing_write_path", "cursor", r#"{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{},"cwd":"."}"#.into()),
        ("missing_project_root", "cursor", r#"{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{"file_path":"src/ok.rs"},"cwd":"   "}"#.into()),
    ] {
        let repo_arg = (label != "missing_project_root").then_some(r);
        let (ce, oute, erre) = run_hook_stdin(host, None, repo_arg, Some("enforce"), Some(repo), &payload, &[]);
        assert_eq!(ce, 2, "{label} enforce: {oute} {erre}");
        if host == "cursor" { assert!(oute.contains(r#""permission":"deny""#), "{label}"); } else { assert!(!erre.trim().is_empty(), "{label}"); }

        let (ca, outa, erra) = run_hook_stdin(host, None, repo_arg, Some("audit"), Some(repo), &payload, &[]);
        assert!(ca == 0 && erra.contains("[audit]"), "{label} audit: {outa} {erra}");
        if host == "cursor" { assert!(outa.contains(r#""permission":"allow""#), "{label}"); }

        let (co, outo, _) = run_hook_stdin(host, None, repo_arg, Some("off"), Some(repo), &payload, &[]);
        assert_eq!(co, 0, "{label} off");
        if host == "cursor" { assert!(outo.contains(r#""permission":"allow""#), "{label}"); }
    }

    // Malformed .b3/models.md warns in audit without blocking, and never blocks off
    write_lf(
        &repo.join(".b3/models.md"),
        "```yaml\nhooks:\n  mode: invalid\n```\n",
    );
    let ok_p = cursor_write(".env", r);
    let (c_ma, _, err_ma) = run_hook_stdin(
        "cursor",
        None,
        Some(r),
        None,
        None,
        &ok_p,
        &[("B3_HOOK_MODE", "audit")],
    );
    assert!(
        c_ma == 0 && err_ma.contains("HOOK_CONFIG_WARN") && err_ma.contains("[audit]"),
        "{err_ma}"
    );
    assert_eq!(
        run_hook_stdin(
            "cursor",
            None,
            Some(r),
            None,
            None,
            &ok_p,
            &[("B3_HOOK_MODE", "off")]
        )
        .0,
        0
    );

    // Unknown event & unsupported Read tool exit 0 Allow in all modes
    for mode in ["enforce", "audit", "off"] {
        let unk = format!(
            r#"{{"hook_event_name":"unknownFuture","cwd":{}}}"#,
            json_str(r)
        );
        let (cu, outu, _) = run_hook_stdin("cursor", None, Some(r), Some(mode), None, &unk, &[]);
        assert_eq!(cu, 0);
        if mode == "off" {
            assert!(outu.trim() == "{}" || outu.contains(r#""permission":"allow""#));
        } else {
            assert_eq!(outu.trim(), "{}");
        }

        let rd = format!(
            r#"{{"hook_event_name":"preToolUse","tool_name":"Read","tool_input":{{"file_path":".env"}},"cwd":{}}}"#,
            json_str(r)
        );
        let (cr, outr, _) = run_hook_stdin("cursor", None, Some(r), Some(mode), None, &rd, &[]);
        assert!(cr == 0 && outr.contains(r#""permission":"allow""#));
    }
}

#[test]
fn installer_lifecycle_user_hooks_unicode_spaces_and_opt_in_safety() {
    let tmp = TempDirGuard::new("hook-install-unicode");
    let (repo, user_home) = (
        tmp.path.join("repo with spaces and tiếng_việt"),
        tmp.path.join("home with spaces"),
    );
    fs::create_dir_all(&repo).unwrap();
    fs::create_dir_all(&user_home).unwrap();
    let _base = init_fresh_git_repo(&repo);
    let (r, h) = (repo.to_str().unwrap(), user_home.to_str().unwrap());

    let hooks_dir = repo.join(".git/hooks");
    fs::create_dir_all(&hooks_dir).unwrap();
    let user_pre_commit = "#!/bin/sh\necho user-pre-commit-kept\nexit 0\n";
    write_lf(&hooks_dir.join("pre-commit"), user_pre_commit);
    write_lf(
        &repo.join(".cursor/hooks.json"),
        r#"{"version":1,"customKey":"keep","hooks":{"beforeShellExecution":[{"command":"echo user-hook"}]}}"#,
    );

    assert_eq!(hook_ctl("install", "all", r, Some(h), &["--dry-run"]).0, 0);
    assert!(!hooks_dir.join("pre-commit.b3-user").exists());
    for _ in 0..2 {
        assert_eq!(hook_ctl("install", "all", r, Some(h), &[]).0, 0);
    }
    assert!(hooks_dir.join("pre-commit.b3-user").is_file());

    let cursor_raw = fs::read_to_string(repo.join(".cursor/hooks.json")).unwrap();
    assert!(cursor_raw.contains("customKey") && cursor_raw.contains("echo user-hook"));
    assert_eq!(
        cursor_raw
            .matches("hook run --host cursor --event beforeShellExecution")
            .count(),
        1
    );
    assert_eq!(hook_ctl("verify", "all", r, Some(h), &[]).0, 0);
    assert_eq!(
        run_b3(&["hook", "status", "--repo-root", r, "--user-home", h]).0,
        0
    );

    assert_eq!(hook_ctl("uninstall", "all", r, Some(h), &[]).0, 0);
    assert!(!hooks_dir.join("pre-commit.b3-user").exists());
    assert_eq!(
        fs::read_to_string(hooks_dir.join("pre-commit"))
            .unwrap()
            .replace("\r\n", "\n"),
        user_pre_commit
    );
    let cursor_after = fs::read_to_string(repo.join(".cursor/hooks.json")).unwrap();
    assert!(cursor_after.contains("echo user-hook") && !cursor_after.contains("hook run"));

    // Global core.hooksPath untouched; repo-local core.hooksPath respected
    let (global_cfg, global_hooks) = (
        tmp.path.join("global.gitconfig"),
        tmp.path.join("global-hooks-untouched"),
    );
    fs::create_dir_all(&global_hooks).unwrap();
    write_lf(
        &global_cfg,
        &format!(
            "[core]\n\thooksPath = {}\n",
            global_hooks.to_string_lossy().replace('\\', "/")
        ),
    );
    let local_hooks_repo = tmp.path.join("local-hookspath-repo");
    let _ = init_fresh_git_repo(&local_hooks_repo);
    git_in(
        &local_hooks_repo,
        &["config", "--local", "core.hooksPath", ".githooks"],
    );
    let (c_lh, _, _) = run_b3_env(
        &[
            "hook",
            "install",
            "--host",
            "git",
            "--scope",
            "project",
            "--repo-root",
            local_hooks_repo.to_str().unwrap(),
            "--b3-bin",
            b3_bin(),
        ],
        None,
        &[("GIT_CONFIG_GLOBAL", global_cfg.to_str().unwrap())],
        &[],
    );
    assert_eq!(c_lh, 0);
    assert!(
        local_hooks_repo.join(".githooks/pre-commit").is_file()
            && !global_hooks.join("pre-commit").exists()
    );

    // install product never silently installs blocking hooks
    let prod = tmp.path.join("opt-in-product");
    fs::create_dir_all(&prod).unwrap();
    let _ = init_fresh_git_repo(&prod);
    let b3_home = Path::new(env!("CARGO_MANIFEST_DIR"));
    assert_eq!(
        run_b3(&[
            "install",
            "product",
            "--product-root",
            prod.to_str().unwrap(),
            "--b3-home",
            b3_home.to_str().unwrap(),
            "--host",
            "cursor"
        ])
        .0,
        0
    );
    assert!(
        !prod.join(".cursor/hooks.json").exists() && !prod.join(".git/hooks/pre-commit").exists()
    );
}

fn sh_program() -> &'static str {
    let win_sh = r"C:\Program Files\Git\bin\sh.exe";
    if cfg!(windows) && Path::new(win_sh).is_file() {
        win_sh
    } else {
        "sh"
    }
}

#[test]
fn f06_user_hook_chaining_args_stdin_exit7_and_nonexec_preservation() {
    let tmp = TempDirGuard::new("hook-f06");
    let (repo, _bare) = setup_remote_repo(&tmp, "f06", false);
    let r = repo.to_str().unwrap();
    let hooks_dir = repo.join(".git/hooks");
    assert_eq!(hook_ctl("uninstall", "git", r, None, &[]).0, 0);

    // 1. Executable user pre-push captures args, stdin, B3_HOOK_ACTIVE=1, and exits 7
    let cap_file = tmp.path.join("user-hook-capture.txt");
    let cap_sh = cap_file.to_string_lossy().replace('\\', "/");
    let exec_hook_bytes = format!("#!/bin/sh\ns=\"$(cat)\"\nprintf '%s|%s|%s|%s\\n' \"$1\" \"$2\" \"${{B3_HOOK_ACTIVE:-}}\" \"$s\" > '{cap_sh}'\nexit 7\n");
    let pp_path = hooks_dir.join("pre-push");
    write_lf(&pp_path, &exec_hook_bytes);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&pp_path, fs::Permissions::from_mode(0o755)).unwrap();
    }
    assert_eq!(hook_ctl("install", "git", r, None, &[]).0, 0);

    let shim_stdin = format!(
        "refs/heads/feat/shim-test {} refs/heads/feat/shim-test {}\n",
        "a".repeat(40),
        "0".repeat(40)
    );
    let pp_sh = pp_path.to_string_lossy().replace('\\', "/");
    assert_eq!(
        run_cmd_stdin(
            sh_program(),
            &[&pp_sh, "origin", "https://example.local/repo.git"],
            Some(&repo),
            &shim_stdin,
            &[("B3_HOOK_ACTIVE", "")]
        )
        .0,
        7
    );
    assert!(fs::read_to_string(&cap_file)
        .unwrap()
        .contains("origin|https://example.local/repo.git|1|refs/heads/feat/shim-test"));

    git_in(&repo, &["checkout", "-b", "feat/f06"]);
    write_lf(&repo.join("src/f06.txt"), "hi\n");
    git_in(&repo, &["add", "src/f06.txt"]);
    git_in(&repo, &["commit", "-m", "f06"]);
    assert_ne!(
        git_iso_status(&tmp, &repo, &["push", "origin", "feat/f06"]).0,
        0
    );
    let gp_cap = fs::read_to_string(&cap_file).unwrap();
    assert!(
        gp_cap.contains("origin|") && gp_cap.contains("|1|refs/heads/feat/f06"),
        "{gp_cap}"
    );
    assert_eq!(hook_ctl("uninstall", "git", r, None, &[]).0, 0);
    assert_eq!(fs::read(&pp_path).unwrap(), exec_hook_bytes.as_bytes());

    // 2. Non-executable .b3-user preserves exact bytes/perms and never executes via `sh`
    let nonexec_bytes: Vec<u8> = if cfg!(unix) {
        b"#!/bin/sh\necho SHOULD_NOT_RUN\nexit 9\n".to_vec()
    } else {
        b"NON_EXEC_DATA_LINE_1\r\nexit 9\r\n".to_vec()
    };
    fs::write(&pp_path, &nonexec_bytes).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&pp_path, fs::Permissions::from_mode(0o644)).unwrap();
    }

    for _ in 0..2 {
        assert_eq!(hook_ctl("install", "git", r, None, &[]).0, 0);
    }
    assert!(!fs::read_to_string(&pp_path)
        .unwrap()
        .contains("sh \"$USER_HOOK\""));
    assert_eq!(
        git_iso_status(&tmp, &repo, &["push", "origin", "feat/f06"]).0,
        0
    );
    assert_eq!(
        fs::read(hooks_dir.join("pre-push.b3-user")).unwrap(),
        nonexec_bytes
    );
    assert_eq!(hook_ctl("uninstall", "git", r, None, &[]).0, 0);
    assert_eq!(fs::read(&pp_path).unwrap(), nonexec_bytes);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&pp_path).unwrap().permissions().mode() & 0o777,
            0o644
        );
    }
}

#[test]
fn r02_remote_policy_authority_scenarios() {
    let tmp = TempDirGuard::new("hook-r02-auth");

    // 1 & 2. Remote adds policy after last local fetch; local lacks policy & remote tracking ref is stale.
    let (local_stale, bare_stale) = setup_remote_repo(&tmp, "stale-remote", false);
    let admin = tmp.path.join("stale-admin");
    assert!(Command::new("git")
        .args([
            "clone",
            bare_stale.to_str().unwrap(),
            admin.to_str().unwrap()
        ])
        .output()
        .expect("clone admin")
        .status
        .success());
    git_in(&admin, &["config", "user.email", "t@example.com"]);
    git_in(&admin, &["config", "user.name", "Test"]);
    write_lf(
        &admin.join(".b3/research-policy.json"),
        r#"{"auto_merge":"disabled","protected_paths":["locked/"],"allow_protected_paths":false,"require_ci":false,"require_review":false}"#,
    );
    git_in(&admin, &["add", ".b3/research-policy.json"]);
    git_in(&admin, &["commit", "-m", "remote adds policy"]);
    git_in(&admin, &["push", "origin", "main"]);

    // Pushing to main from stale local repo is blocked via remote_oid mismatch (never claims policy absent).
    write_lf(&local_stale.join("src/local.txt"), "local\n");
    git_in(&local_stale, &["add", "src/local.txt"]);
    git_in(&local_stale, &["commit", "-m", "local main diverged"]);
    let (c_st, _, err_st) = git_iso_status(
        &tmp,
        &local_stale,
        &["push", "origin", "HEAD:refs/heads/main"],
    );
    assert!(
        c_st != 0 && err_st.contains("stale_remote_target_ref(main)"),
        "expected stale_remote_target_ref: {err_st}"
    );
    // Ordinary feature branch push works cleanly without remote network calls.
    git_in(&local_stale, &["checkout", "-b", "feat/local"]);
    write_lf(&local_stale.join("src/ok.txt"), "ok\n");
    git_in(&local_stale, &["add", "src/ok.txt"]);
    git_in(&local_stale, &["commit", "-m", "feat"]);
    assert_eq!(
        git_iso_status(&tmp, &local_stale, &["push", "origin", "feat/local"]).0,
        0
    );

    // 3, 4, 5, 6. Missing tracking refs, non-origin remote, pushUrl mismatch, direct URL push.
    let (multi, bare_origin) = setup_remote_repo(&tmp, "multi", true);
    let bare_up = tmp.path.join("multi-upstream.git");
    fs::create_dir_all(&bare_up).unwrap();
    assert!(Command::new("git")
        .args(["init", "--bare"])
        .arg(&bare_up)
        .output()
        .unwrap()
        .status
        .success());
    git_in(&bare_up, &["symbolic-ref", "HEAD", "refs/heads/trunk"]);
    let up_seed = tmp.path.join("up-seed");
    let _ = init_fresh_git_repo(&up_seed);
    git_in(&up_seed, &["branch", "-M", "trunk"]);
    write_lf(
        &up_seed.join(".b3/research-policy.json"),
        r#"{"auto_merge":"disabled","protected_paths":["sec/"],"allow_protected_paths":false,"require_ci":false,"require_review":false}"#,
    );
    git_in(&up_seed, &["add", ".b3/research-policy.json"]);
    git_in(&up_seed, &["commit", "-m", "trunk policy"]);
    git_in(
        &up_seed,
        &["remote", "add", "upstream", bare_up.to_str().unwrap()],
    );
    git_in(&up_seed, &["push", "-u", "upstream", "trunk"]);

    // Plain repo without local policy pushing to unfetched remote / mismatched pushUrl / direct URL:
    let (probe, bare_probe) = setup_remote_repo(&tmp, "probe", false);
    let alt_bare = tmp.path.join("alt-bare.git");
    assert!(Command::new("git")
        .args([
            "clone",
            "--bare",
            bare_probe.to_str().unwrap(),
            alt_bare.to_str().unwrap(),
        ])
        .output()
        .unwrap()
        .status
        .success());

    git_in(
        &probe,
        &["remote", "add", "unfetched", alt_bare.to_str().unwrap()],
    );
    git_in(&probe, &["checkout", "-b", "feat/adv"]);
    write_lf(&probe.join("src/adv.txt"), "hi\n");
    git_in(&probe, &["add", "src/adv.txt"]);
    git_in(&probe, &["commit", "-m", "adv"]);

    // Missing tracking refs on feature push -> Advisory exit 0; pushing existing main -> Blocked
    let (c_uf_feat, _, err_uf_feat) =
        git_iso_status(&tmp, &probe, &["push", "unfetched", "feat/adv"]);
    assert!(
        c_uf_feat == 0 && err_uf_feat.contains("UNKNOWN(missing_remote_tracking_refs)"),
        "expected missing_remote_tracking_refs advisory: {err_uf_feat}"
    );
    let (c_uf_main, _, err_uf_main) = git_iso_status(
        &tmp,
        &probe,
        &["push", "unfetched", "feat/adv:refs/heads/main"],
    );
    assert!(
        c_uf_main != 0 && err_uf_main.contains("unknown_remote_authority"),
        "{err_uf_main}"
    );

    // Direct URL push -> Advisory on feature, Blocked on existing main & main deletion
    let (c_dir_feat, _, err_dir_feat) = git_iso_status(
        &tmp,
        &probe,
        &["push", bare_probe.to_str().unwrap(), "feat/adv"],
    );
    assert!(
        c_dir_feat == 0 && err_dir_feat.contains("UNKNOWN(direct_url_push)"),
        "{err_dir_feat}"
    );
    let (c_dir_del, _, err_dir_del) = git_iso_status(
        &tmp,
        &probe,
        &["push", bare_probe.to_str().unwrap(), ":refs/heads/main"],
    );
    assert!(
        c_dir_del != 0 && err_dir_del.contains("unknown_remote_authority"),
        "{err_dir_del}"
    );

    // Push URL differs from fetch URL
    git_in(
        &probe,
        &[
            "remote",
            "set-url",
            "--push",
            "origin",
            alt_bare.to_str().unwrap(),
        ],
    );
    let (c_pu_feat, _, err_pu_feat) = git_iso_status(
        &tmp,
        &probe,
        &["push", "origin", "feat/adv:refs/heads/feat/pu-mismatch"],
    );
    assert!(
        c_pu_feat == 0 && err_pu_feat.contains("UNKNOWN(push_url_differs_from_fetch_url)"),
        "{err_pu_feat}"
    );
    let (c_pu_main, _, err_pu_main) =
        git_iso_status(&tmp, &probe, &["push", "origin", ":refs/heads/main"]);
    assert!(
        c_pu_main != 0 && err_pu_main.contains("unknown_remote_authority"),
        "{err_pu_main}"
    );

    // 7. Non-origin remote & non-main/master default branch (`trunk`), even when remote HEAD unset
    let (trunk_repo, _) = setup_remote_repo(&tmp, "trunk-only", false);
    git_in(
        &trunk_repo,
        &["remote", "add", "upstream", bare_up.to_str().unwrap()],
    );
    git_in(&trunk_repo, &["fetch", "upstream"]);
    git_in(
        &trunk_repo,
        &["checkout", "-b", "feat/up-sec", "upstream/trunk"],
    );
    write_lf(&trunk_repo.join("sec/key.txt"), "sec\n");
    git_in(&trunk_repo, &["add", "sec/key.txt"]);
    git_in(&trunk_repo, &["commit", "-m", "touch sec"]);
    let (c_up_sec, _, err_up_sec) =
        git_iso_status(&tmp, &trunk_repo, &["push", "upstream", "feat/up-sec"]);
    assert!(
        c_up_sec != 0 && err_up_sec.contains("protected_paths=sec/key.txt"),
        "expected sec/ protected path block on upstream/trunk: {err_up_sec}"
    );
    git_in(
        &trunk_repo,
        &["checkout", "-b", "feat/up-clean", "upstream/trunk"],
    );
    write_lf(&trunk_repo.join("src/clean.txt"), "ok\n");
    git_in(&trunk_repo, &["add", "src/clean.txt"]);
    git_in(&trunk_repo, &["commit", "-m", "clean up"]);
    let (c_up_dir, _, err_up_dir) = git_iso_status(
        &tmp,
        &trunk_repo,
        &["push", "upstream", "feat/up-clean:refs/heads/trunk"],
    );
    assert!(
        c_up_dir != 0 && err_up_dir.contains("direct_push_blocked"),
        "{err_up_dir}"
    );

    // 8 & R03 pre-merge-commit: multi-ref push + actual staged merge index check + octopus MERGE_HEAD
    git_in(&multi, &["checkout", "-b", "feat/m1", "origin/main"]);
    write_lf(&multi.join("src/m1.txt"), "m1\n");
    git_in(&multi, &["add", "src/m1.txt"]);
    git_in(&multi, &["commit", "-m", "m1"]);
    let (c_mr, _, err_mr) = git_iso_status(
        &tmp,
        &multi,
        &["push", "origin", "feat/m1", "feat/m1:refs/heads/main"],
    );
    assert!(
        c_mr != 0 && err_mr.contains("direct_push_blocked"),
        "{err_mr}"
    );
    let _ = bare_origin;

    git_in(&multi, &["checkout", "--detach", "origin/main"]);
    git_in(&multi, &["merge", "--no-commit", "--no-ff", "feat/m1"]);
    write_lf(&multi.join("locked/staged-merge.txt"), "bad\n");
    git_in(&multi, &["add", "locked/staged-merge.txt"]);
    let (c_stg, _, err_stg) = run_hook_stdin(
        "git",
        Some("pre-merge-commit"),
        Some(multi.to_str().unwrap()),
        None,
        None,
        "",
        &[],
    );
    assert!(
        c_stg == 1 && err_stg.contains("protected_paths=locked/staged-merge.txt"),
        "pre-merge-commit must check staged merge result: {err_stg}"
    );

    // Octopus MERGE_HEAD rejected on governed branch
    let head_sha = git_in(&multi, &["rev-parse", "HEAD"]).trim().to_string();
    let m1_sha = git_in(&multi, &["rev-parse", "feat/m1"]).trim().to_string();
    let mh_path = PathBuf::from(git_in(&multi, &["rev-parse", "--git-path", "MERGE_HEAD"]).trim());
    let mh_abs = if mh_path.is_absolute() {
        mh_path
    } else {
        multi.join(mh_path)
    };
    write_lf(&mh_abs, &format!("{m1_sha}\n{head_sha}\n"));
    let _ = git_iso_status(
        &tmp,
        &multi,
        &["reset", "HEAD", "--", "locked/staged-merge.txt"],
    );
    let _ = fs::remove_file(multi.join("locked/staged-merge.txt"));
    let (c_oct, _, err_oct) = run_hook_stdin(
        "git",
        Some("pre-merge-commit"),
        Some(multi.to_str().unwrap()),
        None,
        None,
        "",
        &[],
    );
    assert!(
        c_oct != 0
            && (err_oct.contains("unsupported_octopus_merge")
                || err_oct.contains("auto_merge=disabled")),
        "{err_oct}"
    );
    let _ = git_iso_status(&tmp, &multi, &["merge", "--abort"]);

    // F1/F2: Direct URL push in governed repo still enforces canonical origin policy + emits UNKNOWN advisory on clean feature push
    git_in(&multi, &["checkout", "-b", "feat/url-prot", "origin/main"]);
    write_lf(&multi.join("locked/url-bypass.txt"), "bypass\n");
    git_in(&multi, &["add", "locked/url-bypass.txt"]);
    git_in(&multi, &["commit", "-m", "url prot"]);
    let (c_up_bad, _, err_up_bad) = git_iso_status(
        &tmp,
        &multi,
        &["push", bare_origin.to_str().unwrap(), "feat/url-prot"],
    );
    assert!(
        c_up_bad != 0 && err_up_bad.contains("protected_paths=locked/url-bypass.txt"),
        "F1 direct URL push must enforce origin protected_paths: {err_up_bad}"
    );
    let (c_up_ok, _, err_up_ok) = git_iso_status(
        &tmp,
        &multi,
        &["push", bare_origin.to_str().unwrap(), "feat/m1"],
    );
    assert!(
        c_up_ok == 0 && err_up_ok.contains("UNKNOWN(direct_url_push)"),
        "clean feature direct URL push emits advisory: {err_up_ok}"
    );

    // F4: pre-merge-commit resolves non-origin remote non-main default branch (`upstream/trunk`)
    git_in(&trunk_repo, &["checkout", "--detach", "upstream/trunk"]);
    let (c_tr_m, _, err_tr_m) = git_iso_status(
        &tmp,
        &trunk_repo,
        &["merge", "--no-commit", "--no-ff", "feat/up-sec"],
    );
    if c_tr_m == 0 {
        let (c_pm_tr, _, err_pm_tr) = run_hook_stdin(
            "git",
            Some("pre-merge-commit"),
            Some(trunk_repo.to_str().unwrap()),
            None,
            None,
            "",
            &[],
        );
        assert!(
            c_pm_tr != 0
                && (err_pm_tr.contains("protected_paths=sec/key.txt")
                    || err_pm_tr.contains("auto_merge=disabled")),
            "F4 pre-merge-commit must enforce upstream/trunk policy: {err_pm_tr}"
        );
    } else {
        assert!(
            err_tr_m.contains("protected_paths=sec/key.txt")
                || err_tr_m.contains("auto_merge=disabled"),
            "{err_tr_m}"
        );
    }

    // N01: Unconfigured origin/HEAD + policy-absent origin/main + policy-bearing origin/trunk
    let (n01_repo, n01_bare) = setup_remote_repo(&tmp, "n01-trunk", false);
    let n01_admin = tmp.path.join("n01-admin");
    assert!(Command::new("git")
        .args([
            "clone",
            n01_bare.to_str().unwrap(),
            n01_admin.to_str().unwrap(),
        ])
        .output()
        .expect("clone n01-admin")
        .status
        .success());
    git_in(&n01_admin, &["config", "user.email", "t@example.com"]);
    git_in(&n01_admin, &["config", "user.name", "Test"]);
    git_in(&n01_admin, &["checkout", "-b", "trunk"]);
    write_lf(
        &n01_admin.join(".b3/research-policy.json"),
        r#"{"auto_merge":"disabled","protected_paths":["sec/"],"allow_protected_paths":false,"require_ci":false,"require_review":false}"#,
    );
    git_in(&n01_admin, &["add", ".b3/research-policy.json"]);
    git_in(&n01_admin, &["commit", "-m", "trunk policy"]);
    git_in(&n01_admin, &["push", "origin", "trunk"]);

    git_in(&n01_repo, &["fetch", "origin"]);
    let _ = Command::new("git")
        .current_dir(&n01_repo)
        .args(["symbolic-ref", "-d", "refs/remotes/origin/HEAD"])
        .output();
    git_in(
        &n01_repo,
        &["checkout", "-b", "feat/from-old-main", "origin/main"],
    );
    write_lf(&n01_repo.join("sec/bypass.txt"), "bypass\n");
    git_in(&n01_repo, &["add", "sec/bypass.txt"]);
    git_in(&n01_repo, &["commit", "-m", "touch sec from old main"]);
    let (c_n01_blk, _, err_n01_blk) =
        git_iso_status(&tmp, &n01_repo, &["push", "origin", "feat/from-old-main"]);
    assert!(
        c_n01_blk != 0
            && (err_n01_blk.contains("policy_modified_in_pr")
                || err_n01_blk.contains("protected_paths=sec/bypass.txt")),
        "N01 must enforce origin/trunk policy over policy-absent origin/main: {err_n01_blk}"
    );

    // Conflicting policy blobs across origin/main and origin/trunk with unset origin/HEAD fail closed
    git_in(&n01_admin, &["checkout", "main"]);
    write_lf(
        &n01_admin.join(".b3/research-policy.json"),
        r#"{"auto_merge":"disabled","protected_paths":["other/"],"allow_protected_paths":false,"require_ci":false,"require_review":false}"#,
    );
    git_in(&n01_admin, &["add", ".b3/research-policy.json"]);
    git_in(&n01_admin, &["commit", "-m", "conflicting main policy"]);
    git_in(&n01_admin, &["push", "origin", "main"]);
    git_in(&n01_repo, &["fetch", "origin"]);
    let _ = Command::new("git")
        .current_dir(&n01_repo)
        .args(["symbolic-ref", "-d", "refs/remotes/origin/HEAD"])
        .output();
    let (c_n01_amb, _, err_n01_amb) =
        git_iso_status(&tmp, &n01_repo, &["push", "origin", "feat/from-old-main"]);
    assert!(
        c_n01_amb != 0 && err_n01_amb.contains("ambiguous_policy_authority"),
        "N01 conflicting tracking policies with unset origin/HEAD must fail closed: {err_n01_amb}"
    );
}

#[test]
fn r04_and_section6_subdir_discovery_lossless_shim_and_precommit() {
    let tmp = TempDirGuard::new("hook-sec6");
    let (repo, _bare) = setup_remote_repo(&tmp, "sec6", false);
    let r = repo.to_str().unwrap();
    let nested = repo.join("src/nested");
    fs::create_dir_all(&nested).unwrap();

    // 1. Subdirectory cwd + omitted --repo-root + malformed JSON honors audit / off / enforce
    write_lf(
        &repo.join(".b3/models.md"),
        "```yaml\nhooks:\n  enabled: true\n  mode: audit\n```\n",
    );
    let (c_aud, _, err_aud) =
        run_hook_stdin("cursor", None, None, None, Some(&nested), "{not-json", &[]);
    assert!(c_aud == 0 && err_aud.contains("[audit]"), "{err_aud}");

    write_lf(
        &repo.join(".b3/models.md"),
        "```yaml\nhooks:\n  enabled: false\n  mode: enforce\n```\n",
    );
    let (c_off, _, err_off) =
        run_hook_stdin("cursor", None, None, None, Some(&nested), "{not-json", &[]);
    assert_eq!((c_off, err_off.as_str()), (0, ""));

    write_lf(
        &repo.join(".b3/models.md"),
        "```yaml\nhooks:\n  enabled: true\n  mode: enforce\n```\n",
    );
    let (c_enf, out_enf, _) =
        run_hook_stdin("cursor", None, None, None, Some(&nested), "{not-json", &[]);
    assert!(
        c_enf == 2 && out_enf.contains(r#""permission":"deny""#),
        "{out_enf}"
    );

    // 2. Lossless pre-push stdin forwarding preserves trailing newlines to .b3-user
    assert_eq!(hook_ctl("uninstall", "git", r, None, &[]).0, 0);
    let cap = tmp.path.join("stdin-bytes.len");
    let cap_sh = cap.to_string_lossy().replace('\\', "/");
    let hooks_dir = repo.join(".git/hooks");
    let pp_path = hooks_dir.join("pre-push");
    let user_pp = format!("#!/bin/sh\nwc -c < /dev/stdin > '{cap_sh}'\nexit 0\n");
    write_lf(&pp_path, &user_pp);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&pp_path, fs::Permissions::from_mode(0o755)).unwrap();
    }
    assert_eq!(hook_ctl("install", "git", r, None, &[]).0, 0);
    let exact_stdin = format!(
        "refs/heads/feat/x {} refs/heads/feat/x {}\n\n",
        "a".repeat(40),
        "0".repeat(40)
    );
    let pp_sh = pp_path.to_string_lossy().replace('\\', "/");
    let (c_pp, _, err_pp) = run_cmd_stdin(
        sh_program(),
        &[&pp_sh, "origin", "https://example.local/repo.git"],
        Some(&repo),
        &exact_stdin,
        &[("B3_HOOK_ACTIVE", "")],
    );
    assert_eq!(c_pp, 0, "err={err_pp}");
    let byte_len: usize = fs::read_to_string(&cap).unwrap().trim().parse().unwrap();
    assert_eq!(byte_len, exact_stdin.len());

    // 3. BeforeCommit allows filenames containing ',' cleanly & blocks .env even with B3_ALLOWED_PATHS=.env
    write_lf(&repo.join("src/a,b.txt"), "comma file\n");
    git_in(&repo, &["add", "src/a,b.txt"]);
    assert_eq!(
        run_hook_stdin("git", Some("pre-commit"), Some(r), None, None, "", &[]).0,
        0
    );
    write_lf(&repo.join(".env"), "SECRET=1\n");
    git_in(&repo, &["add", "-f", ".env"]);
    let (c_sec, _, err_sec) = run_hook_stdin(
        "git",
        Some("pre-commit"),
        Some(r),
        None,
        None,
        "",
        &[("B3_ALLOWED_PATHS", "src/a,b.txt,.env")],
    );
    assert!(
        c_sec != 0 && err_sec.contains("secret path staged"),
        "B3_ALLOWED_PATHS must never whitelist .env: {err_sec}"
    );
}

#[test]
fn toml_hooks_config_and_policy_toml_enforcement() {
    let tmp = TempDirGuard::new("hook-toml");
    let repo = tmp.path.join("tomlhook-repo");
    init_fresh_git_repo(&repo);
    fs::create_dir_all(repo.join(".b3")).unwrap();
    let r = repo.to_str().unwrap();

    // 1. Project .b3/config.toml [hooks] controls hook execution and overrides legacy models.md
    let nested = repo.join("sub/dir");
    fs::create_dir_all(&nested).unwrap();
    write_lf(
        &repo.join(".b3/models.md"),
        "```yaml\nhooks:\n  enabled: true\n  mode: enforce\n```\n",
    );
    write_lf(
        &repo.join(".b3/config.toml"),
        "[hooks]\nenabled = true\nmode = \"audit\"\n",
    );
    let (c_aud, _, err_aud) =
        run_hook_stdin("cursor", None, None, None, Some(&nested), "{not-json", &[]);
    assert!(
        c_aud == 0 && err_aud.contains("[audit]"),
        "expected TOML audit override: c={c_aud} err={err_aud}"
    );

    write_lf(
        &repo.join(".b3/config.toml"),
        "[hooks]\nenabled = false\nmode = \"enforce\"\n",
    );
    let (c_off, _, err_off) =
        run_hook_stdin("cursor", None, None, None, Some(&nested), "{not-json", &[]);
    assert_eq!((c_off, err_off.as_str()), (0, ""));

    write_lf(
        &repo.join(".b3/config.toml"),
        "[hooks]\nenabled = true\nmode = \"enforce\"\n",
    );

    // 2. Tier 0 BeforeFileWrite protects .b3/policy.toml just like .b3/research-policy.json
    let payload_pol = serde_json_like_cursor_write(r, ".b3/policy.toml");
    let (c_bw, out_bw, _) = run_hook_stdin(
        "cursor",
        Some("preToolUse"),
        Some(r),
        None,
        None,
        &payload_pol,
        &[],
    );
    assert!(
        c_bw == 2 && out_bw.contains(".b3/policy.toml"),
        "expected .b3/policy.toml write block: c={c_bw} out={out_bw}"
    );

    // 3. Git pre-push & pre-merge-commit enforce trunk .b3/policy.toml protection & dual-format fail-closed
    let admin = tmp.path.join("admin-toml");
    let bare = tmp.path.join("bare-toml.git");
    git_in(&tmp.path, &["init", "--bare", bare.to_str().unwrap()]);
    git_in(&bare, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    clone_seeded_git_repo_for_toml(&admin);
    git_in(&admin, &["remote", "add", "origin", bare.to_str().unwrap()]);
    write_lf(
        &admin.join(".b3/policy.toml"),
        "auto_merge = \"disabled\"\nauto_merge_max_risk = \"LOW\"\nprotected_paths = [\"docs/\"]\nallow_protected_paths = false\nallowed_target_branches = [\"main\"]\nrequire_ci = false\nrequire_review = true\n",
    );
    git_in(&admin, &["add", ".b3/policy.toml"]);
    git_in(&admin, &["commit", "-m", "add policy.toml"]);
    git_in(&admin, &["push", "-u", "origin", "main"]);

    let wt = tmp.path.join("wt-toml");
    let clone_out = Command::new("git")
        .args([
            "-c",
            "core.autocrlf=false",
            "clone",
            bare.to_str().unwrap(),
            wt.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        clone_out.status.success(),
        "clone failed: {}",
        String::from_utf8_lossy(&clone_out.stderr)
    );
    git_in(&wt, &["config", "user.name", "Test"]);
    git_in(&wt, &["config", "user.email", "t@example.com"]);
    git_in(&wt, &["config", "core.autocrlf", "false"]);
    let wt_str = wt.to_str().unwrap();
    assert_eq!(hook_ctl("install", "git", wt_str, None, &[]).0, 0);

    git_in(&wt, &["checkout", "-b", "feat/pol-edit", "origin/main"]);
    write_lf(&wt.join(".b3/policy.toml"), "auto_merge = \"authorized\"\n");
    git_in(&wt, &["add", ".b3/policy.toml"]);
    git_in(&wt, &["commit", "-m", "tamper policy.toml"]);
    let (c_push_tamper, _, err_push_tamper) =
        git_iso_status(&tmp, &wt, &["push", "-u", "origin", "feat/pol-edit"]);
    assert!(
        c_push_tamper != 0 && err_push_tamper.contains("policy_modified_in_pr"),
        "pre-push must block .b3/policy.toml modification: {err_push_tamper}"
    );

    // Real pre-merge-commit hook also blocks merging branch modifying .b3/policy.toml into main
    git_in(&wt, &["checkout", "-f", "main"]);
    let (c_merge_tamper, _, err_merge_tamper) =
        git_iso_status(&tmp, &wt, &["merge", "--no-ff", "feat/pol-edit"]);
    assert!(
        c_merge_tamper != 0 && err_merge_tamper.contains("policy_modified_in_pr"),
        "pre-merge-commit must block .b3/policy.toml modification: {err_merge_tamper}"
    );
    let _ = Command::new("git")
        .current_dir(&wt)
        .args(["merge", "--abort"])
        .output();

    // Dual-format staged/WT conflict fails closed
    git_in(&wt, &["checkout", "-b", "feat/dual", "origin/main"]);
    write_lf(&wt.join(".b3/research-policy.json"), "{}");
    let (c_dual, _, err_dual) = git_iso_status(&tmp, &wt, &["push", "-u", "origin", "feat/dual"]);
    assert!(
        c_dual != 0 && err_dual.contains("policy_conflict_dual_format"),
        "dual policy.toml + research-policy.json must fail closed: {err_dual}"
    );
}

fn serde_json_like_cursor_write(root: &str, rel_file: &str) -> String {
    let norm_root = root.replace('\\', "/");
    format!(
        r#"{{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{{"file_path":"{rel_file}"}},"workspace_roots":["{norm_root}"]}}"#
    )
}

fn clone_seeded_git_repo_for_toml(dest: &Path) {
    init_fresh_git_repo(dest);
    git_in(dest, &["branch", "-M", "main"]);
    write_lf(&dest.join("README.md"), "# Seed\n");
    git_in(dest, &["add", "README.md"]);
    git_in(dest, &["commit", "-m", "init"]);
}
