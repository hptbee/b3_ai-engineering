//! End-to-end behavioral, host-protocol, concurrency, and installer lifecycle tests
//! for `b3 hook {run,install,uninstall,verify,status}`.

mod common;

use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};

use common::{b3_bin, git_in, init_fresh_git_repo, run_b3, run_b3_env, write_lf, TempDirGuard};

fn run_b3_stdin(args: &[&str], stdin_data: &str, envs: &[(&str, &str)]) -> (i32, String, String) {
    let mut cmd = Command::new(b3_bin());
    cmd.args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (k, v) in envs {
        cmd.env(k, v);
    }
    let mut child = cmd.spawn().expect("spawn b3 with stdin");
    {
        use std::io::Write;
        let mut sin = child.stdin.take().expect("stdin handle");
        sin.write_all(stdin_data.as_bytes()).expect("write stdin");
    }
    let out = child.wait_with_output().expect("wait b3 child");
    (
        out.status.code().unwrap_or(1),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

fn json_str(s: &str) -> String {
    b3::json::JsonValue::str(s).to_json_string()
}

#[test]
fn host_protocol_fixtures_and_core_blocking_advisory_scenarios() {
    let tmp = TempDirGuard::new("hook-proto");
    let repo = &tmp.path;
    let _base = init_fresh_git_repo(repo);
    let r = repo.to_str().expect("repo utf8");

    // 1. Cursor preToolUse allow + deny + exit code 2
    let cursor_allow = format!(
        r#"{{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{{"file_path":"src/ok.rs"}},"cwd":{}}}"#,
        json_str(r)
    );
    let (c_ca, out_ca, _) = run_b3_stdin(
        &["hook", "run", "--host", "cursor", "--repo-root", r],
        &cursor_allow,
        &[("B3_HOOK_ACTIVE", "")],
    );
    assert_eq!(c_ca, 0, "cursor allow failed: {out_ca}");
    assert!(out_ca.contains(r#""permission":"allow""#), "out={out_ca}");

    let cursor_deny = format!(
        r#"{{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{{"file_path":".env.production"}},"cwd":{}}}"#,
        json_str(r)
    );
    let (c_cd, out_cd, err_cd) = run_b3_stdin(
        &["hook", "run", "--host", "cursor", "--repo-root", r],
        &cursor_deny,
        &[("B3_HOOK_ACTIVE", "")],
    );
    assert_eq!(
        c_cd, 2,
        "cursor deny must exit 2: out={out_cd} err={err_cd}"
    );
    assert!(out_cd.contains(r#""permission":"deny""#), "out={out_cd}");

    // 2. Claude Code PreToolUse Bash deny (exit 2 + stderr) & PostToolUse advisory (exit 0)
    let claude_deny = format!(
        r#"{{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{{"command":"git reset --hard HEAD~1"}},"cwd":{}}}"#,
        json_str(r)
    );
    let (c_cld, out_cld, err_cld) = run_b3_stdin(
        &["hook", "run", "--host", "claude", "--repo-root", r],
        &claude_deny,
        &[("B3_HOOK_ACTIVE", "")],
    );
    assert_eq!(c_cld, 2, "claude deny must exit 2: err={err_cld}");
    assert!(
        out_cld.trim().is_empty(),
        "claude deny stdout must be empty"
    );
    assert!(
        !err_cld.trim().is_empty(),
        "claude deny needs stderr feedback"
    );

    let claude_post = format!(
        r#"{{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{{"file_path":"src/lib.rs"}},"cwd":{}}}"#,
        json_str(r)
    );
    let (c_clp, _, _) = run_b3_stdin(
        &["hook", "run", "--host", "claude", "--repo-root", r],
        &claude_post,
        &[("B3_HOOK_ACTIVE", "")],
    );
    assert_eq!(c_clp, 0, "advisory PostToolUse must exit 0");

    // 3. Codex PreToolUse apply_patch path traversal block + allow
    let codex_deny = format!(
        r#"{{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{{"patch":"*** Begin Patch\n*** Update File: ../escape.txt\n*** End Patch"}},"cwd":{}}}"#,
        json_str(r)
    );
    let (c_cxd, _, err_cxd) = run_b3_stdin(
        &["hook", "run", "--host", "codex", "--repo-root", r],
        &codex_deny,
        &[("B3_HOOK_ACTIVE", "")],
    );
    assert_eq!(c_cxd, 2, "codex traversal must exit 2: err={err_cxd}");

    // 4. Antigravity PreToolUse deny JSON + PostToolUse {} + Stop continuation loop safety
    let agy_deny = format!(
        r#"{{"hookEventName":"PreToolUse","conversationId":"conv-1","cwd":{},"workspacePaths":[{}],"toolCall":{{"id":"t1","name":"run_command","args":{{"CommandLine":"git commit --no-verify -m x"}}}}}}"#,
        json_str(r),
        json_str(r)
    );
    let (c_agd, out_agd, _) = run_b3_stdin(
        &["hook", "run", "--host", "antigravity", "--repo-root", r],
        &agy_deny,
        &[("B3_HOOK_ACTIVE", "")],
    );
    assert_eq!(c_agd, 0, "antigravity PreToolUse returns JSON with exit 0");
    assert!(out_agd.contains(r#""decision":"deny""#), "out={out_agd}");

    let agy_stop = format!(
        r#"{{"hookEventName":"Stop","conversationId":"conv-1","continuationActive":true,"cwd":{}}}"#,
        json_str(r)
    );
    let (c_ags, out_ags, _) = run_b3_stdin(
        &["hook", "run", "--host", "antigravity", "--repo-root", r],
        &agy_stop,
        &[("B3_HOOK_ACTIVE", "")],
    );
    assert_eq!(c_ags, 0);
    assert_eq!(out_ags.trim(), "{}");

    // 5. Unsupported event degrades gracefully (exit 0) & invalid/deeply-nested payloads fail closed on IDE hosts
    let (c_unsup, out_unsup, _) = run_b3_stdin(
        &[
            "hook",
            "run",
            "--host",
            "cursor",
            "--repo-root",
            r,
            "--payload",
            r#"{"hook_event_name":"futureUnknownEvent","cwd":"."}"#,
        ],
        "",
        &[("B3_HOOK_ACTIVE", "")],
    );
    assert_eq!(c_unsup, 0);
    assert!(out_unsup.contains(r#""permission":"allow""#));

    // SEC-03: invalid JSON on Cursor fails closed (exit 2 + deny JSON)
    let (c_bad_json, out_bad, _) = run_b3(&[
        "hook",
        "run",
        "--host",
        "cursor",
        "--repo-root",
        r,
        "--payload",
        "{not-json",
    ]);
    assert_eq!(
        c_bad_json, 2,
        "cursor invalid JSON must fail closed: {out_bad}"
    );
    assert!(out_bad.contains(r#""permission":"deny""#), "out={out_bad}");

    // SEC-01: excessive JSON nesting depth fails closed cleanly without stack overflow
    let deep_json = format!("{}{}", "[".repeat(200), "]".repeat(200));
    let (c_deep, out_deep, _) = run_b3_stdin(
        &["hook", "run", "--host", "cursor", "--repo-root", r],
        &deep_json,
        &[("B3_HOOK_ACTIVE", "")],
    );
    assert_eq!(c_deep, 2, "deeply nested JSON must fail closed: {out_deep}");
    assert!(
        out_deep.contains(r#""permission":"deny""#),
        "out={out_deep}"
    );

    // SEC-04: explicit --repo-root overrides untrusted payload workspace_roots/project_root
    let other_dir = tmp.path.join("untrusted-off-repo");
    write_lf(
        &other_dir.join(".b3/models.md"),
        "```yaml\nhooks:\n  enabled: false\n  mode: off\n```\n",
    );
    let spoof_payload = format!(
        r#"{{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{{"file_path":".env"}},"project_root":{},"cwd":{}}}"#,
        json_str(other_dir.to_str().unwrap()),
        json_str(other_dir.to_str().unwrap())
    );
    let (c_spoof, out_spoof, _) = run_b3_stdin(
        &["hook", "run", "--host", "cursor", "--repo-root", r],
        &spoof_payload,
        &[("B3_HOOK_ACTIVE", "")],
    );
    assert_eq!(
        c_spoof, 2,
        "payload project_root must not override explicit --repo-root: {out_spoof}"
    );

    // SEC-06: git add ./ and case-variant .B3 are blocked when .b3/ exists, and non-ws control chars fail closed
    fs::create_dir_all(repo.join(".b3")).expect("create .b3 dir");
    let dot_slash_cmd = format!(
        r#"{{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{{"command":"git add ./"}},"cwd":{}}}"#,
        json_str(r)
    );
    let (c_ds, _, _) = run_b3_stdin(
        &["hook", "run", "--host", "claude", "--repo-root", r],
        &dot_slash_cmd,
        &[("B3_HOOK_ACTIVE", "")],
    );
    assert_eq!(c_ds, 2, "git add ./ must be blocked when .b3/ exists");

    let dot_b3_cmd = format!(
        r#"{{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{{"command":"git add .B3"}},"cwd":{}}}"#,
        json_str(r)
    );
    let (c_b3u, _, _) = run_b3_stdin(
        &["hook", "run", "--host", "claude", "--repo-root", r],
        &dot_b3_cmd,
        &[("B3_HOOK_ACTIVE", "")],
    );
    assert_eq!(c_b3u, 2, "git add .B3 must be blocked");

    let esc_cmd = "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo \\u001bhi\"}}";
    let (c_esc, _, err_esc) = run_b3_stdin(
        &["hook", "run", "--host", "claude", "--repo-root", r],
        esc_cmd,
        &[("B3_HOOK_ACTIVE", "")],
    );
    assert_eq!(
        c_esc, 2,
        "control char in command must fail closed: {err_esc}"
    );
}

#[test]
fn disabled_mode_preserves_workflow_guards_recursion_ownership_and_evidence_reuse() {
    let tmp = TempDirGuard::new("hook-modes-reuse");
    let repo = &tmp.path;
    let _base = init_fresh_git_repo(repo);
    let r = repo.to_str().expect("repo utf8");

    // Configure hooks.mode: off in project .b3/models.md
    write_lf(
        &repo.join(".b3/models.md"),
        "```yaml\nhooks:\n  enabled: true\n  mode: off\n```\n",
    );

    // Hook run allows when off
    let (c_off, out_off, _) = run_b3(&[
        "hook",
        "run",
        "--host",
        "cursor",
        "--repo-root",
        r,
        "--payload",
        &format!(
            r#"{{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{{"file_path":".env"}},"cwd":{}}}"#,
            json_str(r)
        ),
    ]);
    assert_eq!(c_off, 0);
    assert!(out_off.contains(r#""permission":"allow""#));

    // Mandatory workflow guard precommit STILL blocks undeclared/secret staged files even when hooks are off!
    write_lf(&repo.join(".env"), "SECRET=1\n");
    let _ = git_in(repo, &["add", "-f", ".env"]);
    let (c_pre, out_pre, _) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r,
        "--allowed-paths",
        "src/app.txt",
    ]);
    assert_ne!(c_pre, 0, "workflow guard must still block: {out_pre}");
    assert!(out_pre.contains("PRECOMMIT_FAIL"), "out={out_pre}");
    let _ = git_in(repo, &["reset", "HEAD", "--", ".env"]);
    let _ = fs::remove_file(repo.join(".env"));

    // Reset mode to enforce for remaining checks
    write_lf(
        &repo.join(".b3/models.md"),
        "```yaml\nhooks:\n  enabled: true\n  mode: enforce\n```\n",
    );

    // Recursion guard (B3_HOOK_ACTIVE=1) short-circuits even dangerous payload
    let (c_rec, out_rec, _) = run_b3_env(
        &[
            "hook",
            "run",
            "--host",
            "cursor",
            "--repo-root",
            r,
            "--payload",
            &format!(
                r#"{{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{{"file_path":".env"}},"cwd":{}}}"#,
                json_str(r)
            ),
        ],
        None,
        &[("B3_HOOK_ACTIVE", "1")],
        &[],
    );
    assert_eq!(c_rec, 0);
    assert!(out_rec.contains(r#""permission":"allow""#));

    // Worker ownership enforcement & parallel concurrent checks
    std::thread::scope(|scope| {
        let h1 = scope.spawn(|| {
            run_b3_env(
                &[
                    "hook",
                    "run",
                    "--host",
                    "claude",
                    "--repo-root",
                    r,
                    "--payload",
                    &format!(
                        r#"{{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{{"file_path":"src/a.txt"}},"cwd":{}}}"#,
                        json_str(r)
                    ),
                ],
                None,
                &[("B3_HOOK_ACTIVE", ""), ("B3_WORKER_ALLOWED_PATHS", "src/a.txt")],
                &[],
            )
        });
        let h2 = scope.spawn(|| {
            run_b3_env(
                &[
                    "hook",
                    "run",
                    "--host",
                    "claude",
                    "--repo-root",
                    r,
                    "--payload",
                    &format!(
                        r#"{{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{{"file_path":"src/a.txt"}},"cwd":{}}}"#,
                        json_str(r)
                    ),
                ],
                None,
                &[("B3_HOOK_ACTIVE", ""), ("B3_WORKER_ALLOWED_PATHS", "src/b.txt")],
                &[],
            )
        });
        let (c1, _, _) = h1.join().unwrap();
        let (c2, _, err2) = h2.join().unwrap();
        assert_eq!(c1, 0, "worker owning src/a.txt must pass");
        assert_eq!(
            c2, 2,
            "conflicting write by worker owning src/b.txt must block: {err2}"
        );
    });

    // Git pre-commit evidence reuse + stale mutation invalidation
    write_lf(&repo.join("src/app.txt"), "staged v1\n");
    let _ = git_in(repo, &["add", "src/app.txt"]);
    let tree_v1 = git_in(repo, &["write-tree"]).trim().to_string();

    // Matching verified tree skips redundant precommit even if B3_ALLOWED_PATHS would differ
    let (c_skip, _, err_skip) = run_b3_env(
        &[
            "hook",
            "run",
            "--host",
            "git",
            "--event",
            "pre-commit",
            "--repo-root",
            r,
            "--payload",
            "{}",
        ],
        None,
        &[
            ("B3_HOOK_ACTIVE", ""),
            ("B3_HOOK_SKIP_PRECOMMIT", "1"),
            ("B3_PRECOMMIT_VERIFIED_TREE", &tree_v1),
            ("B3_ALLOWED_PATHS", "src/other.txt"),
        ],
        &[],
    );
    assert_eq!(c_skip, 0, "matching verified tree must allow: {err_skip}");

    // Mutate staged tree -> stale B3_PRECOMMIT_VERIFIED_TREE no longer skips -> precommit blocks undeclared src/app.txt
    write_lf(&repo.join("src/app.txt"), "staged v2\n");
    let _ = git_in(repo, &["add", "src/app.txt"]);
    let (c_stale, _, err_stale) = run_b3_env(
        &[
            "hook",
            "run",
            "--host",
            "git",
            "--event",
            "pre-commit",
            "--repo-root",
            r,
            "--payload",
            "{}",
        ],
        None,
        &[
            ("B3_HOOK_ACTIVE", ""),
            ("B3_HOOK_SKIP_PRECOMMIT", "1"),
            ("B3_PRECOMMIT_VERIFIED_TREE", &tree_v1),
            ("B3_ALLOWED_PATHS", "src/other.txt"),
        ],
        &[],
    );
    assert_eq!(
        c_stale, 1,
        "stale tree must run precommit and fail: {err_stale}"
    );
}

#[test]
fn installer_lifecycle_user_hooks_unicode_spaces_and_opt_in_safety() {
    let tmp = TempDirGuard::new("hook-install-unicode");
    let repo = tmp.path.join("repo with spaces and tiếng_việt");
    let user_home = tmp.path.join("home with spaces");
    fs::create_dir_all(&repo).expect("create unicode/spaces repo");
    fs::create_dir_all(&user_home).expect("create user home");
    let _base = init_fresh_git_repo(&repo);
    let r = repo.to_str().expect("repo utf8");
    let h = user_home.to_str().expect("home utf8");

    // 1. Existing user-managed pre-commit hook + user JSON hooks must be preserved
    let hooks_dir = repo.join(".git/hooks");
    fs::create_dir_all(&hooks_dir).expect("hooks dir");
    let user_pre_commit = "#!/bin/sh\necho user-pre-commit-kept\nexit 0\n";
    write_lf(&hooks_dir.join("pre-commit"), user_pre_commit);

    write_lf(
        &repo.join(".cursor/hooks.json"),
        r#"{"version":1,"customKey":"keep","hooks":{"beforeShellExecution":[{"command":"echo user-hook"}]}}"#,
    );

    // 2. Dry-run makes no mutations beyond existing files
    let (c_dry, out_dry, _) = run_b3(&[
        "hook",
        "install",
        "--host",
        "all",
        "--scope",
        "project",
        "--repo-root",
        r,
        "--user-home",
        h,
        "--b3-bin",
        b3_bin(),
        "--dry-run",
    ]);
    assert_eq!(c_dry, 0, "dry-run failed: {out_dry}");
    assert!(!hooks_dir.join("pre-commit.b3-user").exists());

    // 3. Idempotent install across all hosts (including spaces/Unicode repo path)
    let (c_i1, out_i1, err_i1) = run_b3(&[
        "hook",
        "install",
        "--host",
        "all",
        "--scope",
        "project",
        "--repo-root",
        r,
        "--user-home",
        h,
        "--b3-bin",
        b3_bin(),
    ]);
    assert_eq!(c_i1, 0, "install 1 failed: out={out_i1} err={err_i1}");
    assert!(hooks_dir.join("pre-commit.b3-user").is_file());

    let (c_i2, out_i2, _) = run_b3(&[
        "hook",
        "install",
        "--host",
        "all",
        "--scope",
        "project",
        "--repo-root",
        r,
        "--user-home",
        h,
        "--b3-bin",
        b3_bin(),
    ]);
    assert_eq!(c_i2, 0, "install 2 failed: {out_i2}");

    // Verify no duplicate B3 entries in .cursor/hooks.json and customKey preserved
    let cursor_raw = fs::read_to_string(repo.join(".cursor/hooks.json")).unwrap();
    assert!(cursor_raw.contains("customKey"));
    assert!(cursor_raw.contains("echo user-hook"));
    assert_eq!(cursor_raw.matches("\"beforeShellExecution\":").count(), 1);
    assert_eq!(
        cursor_raw
            .matches("hook run --host cursor --event beforeShellExecution")
            .count(),
        1
    );

    // 4. Verify & status pass
    let (c_ver, out_ver, _) = run_b3(&[
        "hook",
        "verify",
        "--host",
        "all",
        "--scope",
        "project",
        "--repo-root",
        r,
        "--user-home",
        h,
    ]);
    assert_eq!(c_ver, 0, "hook verify failed: {out_ver}");

    let (c_st, out_st, _) = run_b3(&["hook", "status", "--repo-root", r, "--user-home", h]);
    assert_eq!(c_st, 0, "hook status failed: {out_st}");

    // 5. Uninstall removes ONLY B3 entries and restores user pre-commit
    let (c_un, out_un, _) = run_b3(&[
        "hook",
        "uninstall",
        "--host",
        "all",
        "--scope",
        "project",
        "--repo-root",
        r,
        "--user-home",
        h,
    ]);
    assert_eq!(c_un, 0, "uninstall failed: {out_un}");
    assert!(!hooks_dir.join("pre-commit.b3-user").exists());
    let restored = fs::read_to_string(hooks_dir.join("pre-commit")).unwrap();
    assert_eq!(restored.replace("\r\n", "\n"), user_pre_commit);

    let cursor_after = fs::read_to_string(repo.join(".cursor/hooks.json")).unwrap();
    assert!(cursor_after.contains("echo user-hook"));
    assert!(!cursor_after.contains("hook run"));

    // 6. Global core.hooksPath must NEVER be touched by project-scope install;
    //    repo-local core.hooksPath IS respected.
    let global_cfg = tmp.path.join("global.gitconfig");
    let global_hooks = tmp.path.join("global-hooks-untouched");
    fs::create_dir_all(&global_hooks).expect("global hooks dir");
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
    let (c_lh, out_lh, err_lh) = run_b3_env(
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
    assert_eq!(
        c_lh, 0,
        "local core.hooksPath install failed: out={out_lh} err={err_lh}"
    );
    assert!(local_hooks_repo.join(".githooks/pre-commit").is_file());
    assert!(!global_hooks.join("pre-commit").exists());

    // 7. Verify global/product installer never silently installs blocking hooks
    let prod = tmp.path.join("opt-in-product");
    fs::create_dir_all(&prod).expect("prod dir");
    let _ = init_fresh_git_repo(&prod);
    let b3_home = Path::new(env!("CARGO_MANIFEST_DIR"));
    let (c_prod, out_prod, _) = run_b3(&[
        "install",
        "product",
        "--product-root",
        prod.to_str().unwrap(),
        "--b3-home",
        b3_home.to_str().unwrap(),
        "--host",
        "cursor",
    ]);
    assert_eq!(c_prod, 0, "install product failed: {out_prod}");
    assert!(!prod.join(".cursor/hooks.json").exists());
    assert!(!prod.join(".git/hooks/pre-commit").exists());
}
