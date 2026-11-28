//! Cross-platform native integration tests for B3 global & product adapters,
//! `b3 sync`, smart `B3_HOME` auto-discovery, and `B3_CONFIG_PERSONAL` /
//! `B3_SKIP_CONFIG_INIT` lifecycle with zero PowerShell/Bash script dependencies.

mod common;

use std::fs;
use std::path::Path;
use std::process::Command;

use b3::adapters::common::{create_dir_link, to_forward_path};
use b3::fs::{remove_dir_tree_safely, sha256_bytes_hex};
use b3::json::{parse_json, JsonValue};
use common::{
    b3_bin, clone_seeded_git_repo, copy_dir_recursive, git_in, repo_root, run_b3_env, write_lf,
    TempDirGuard,
};

fn copy_b3_snapshot(dest: &Path, include_command_skills: bool) {
    let root = repo_root();
    copy_dir_recursive(&root.join("skills"), &dest.join("skills"));
    copy_dir_recursive(&root.join("commands"), &dest.join("commands"));
    copy_dir_recursive(&root.join("agents"), &dest.join("agents"));
    copy_dir_recursive(&root.join("rules"), &dest.join("rules"));
    copy_dir_recursive(&root.join("workflows"), &dest.join("workflows"));
    copy_dir_recursive(&root.join("config"), &dest.join("config"));
    fs::copy(root.join("AGENTS.md"), dest.join("AGENTS.md")).expect("copy AGENTS.md");

    let ad_dst = dest.join("adapters");
    fs::create_dir_all(&ad_dst).expect("create adapters dir");
    for f in [
        "product-agents.md",
        "product-claude.md",
        "product-cursor-readme.md",
    ] {
        let src_f = root.join("adapters").join(f);
        if src_f.is_file() {
            fs::copy(&src_f, ad_dst.join(f)).expect("copy adapter template");
        }
    }
    if include_command_skills {
        copy_dir_recursive(
            &root.join("adapters/command-skills"),
            &ad_dst.join("command-skills"),
        );
    }
}

fn count_skill_md(dir: &Path) -> usize {
    let mut files = Vec::new();
    b3::adapters::common::collect_skill_md_files(dir, &mut files).unwrap();
    files.len()
}

fn count_canonical_md(dir: &Path) -> usize {
    b3::adapters::common::get_canonical_markdown_names(dir).len()
}

fn sha256_file(path: &Path) -> String {
    sha256_bytes_hex(&fs::read(path).expect("read file for sha256"))
}

fn add_custom_cursor_artifacts(cursor_home: &Path) {
    write_lf(
        &cursor_home.join("skills/my-custom-skill/SKILL.md"),
        "---\nname: my-custom-skill\ndescription: user custom\n---\n# user\n",
    );
    write_lf(&cursor_home.join("commands/my-cmd.md"), "# user cmd\n");
    write_lf(&cursor_home.join("agents/my-agent.md"), "# user agent\n");
}

fn manifest_bad_variants(
    clean: &str,
    entry_prefix: &str,
    link_prefix: &str,
    valid_sha: &str,
) -> Vec<(&'static str, String)> {
    let replace_line = |prefix: &str, new_val: &str| -> String {
        clean
            .lines()
            .map(|ln| {
                if ln.starts_with(prefix) {
                    format!("{prefix}{new_val}")
                } else {
                    ln.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
            + "\n"
    };
    let replace_schema = clean
        .lines()
        .map(|ln| {
            if ln.starts_with("schema=") {
                "schema="
            } else {
                ln
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";

    vec![
        ("empty-hash", replace_line(entry_prefix, "")),
        ("non-hex-hash", replace_line(entry_prefix, "not-a-sha256")),
        ("empty-target", replace_line(link_prefix, "")),
        ("rel-target", replace_line(link_prefix, "relative/path")),
        ("trav-target", replace_line(link_prefix, "C:/ok/../escape")),
        ("pipe-target", replace_line(link_prefix, "C:/ok|extra")),
        (
            "dup-entry",
            format!(
                "{}\n{}{valid_sha}\n",
                clean.trim_end_matches('\n'),
                entry_prefix
            ),
        ),
        ("empty-schema", replace_schema),
        (
            "dup-header",
            format!("{}\nb3_home=C:/other\n", clean.trim_end_matches('\n')),
        ),
    ]
}

#[test]
fn cursor_global_lifecycle_links_guards_and_manifest_hardening() {
    let root = repo_root();
    let root_str = root.to_str().unwrap();
    let expected_skills = count_skill_md(&root.join("skills"));
    let expected_cmds = count_canonical_md(&root.join("commands"));
    let tmp = TempDirGuard::new("cur-glob");

    // 1. Dry-run zero mutation
    let uh1 = tmp.path.join("u1");
    let ch1 = uh1.join(".cursor");
    let (c_dr, out_dr, _) = run_b3_env(
        &[
            "install",
            "cursor",
            "install",
            "--b3-home",
            root_str,
            "--cursor-home",
            ch1.to_str().unwrap(),
            "--user-home",
            uh1.to_str().unwrap(),
            "--dry-run",
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_dr, 0);
    assert!(out_dr.contains("DRY_RUN_OK:"), "out={out_dr}");
    assert!(!ch1.exists());

    // 2. Fresh install + verify + model-neutrality + <=1200B user rules + idempotency
    let uh2 = tmp.path.join("u2");
    let ch2 = uh2.join(".cursor");
    let (c_in2, out_in2, err_in2) = run_b3_env(
        &[
            "install",
            "cursor",
            "install",
            "--b3-home",
            root_str,
            "--cursor-home",
            ch2.to_str().unwrap(),
            "--user-home",
            uh2.to_str().unwrap(),
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_in2, 0, "fresh install: {out_in2}\n{err_in2}");
    let (c_ver2, out_ver2, _) = run_b3_env(
        &[
            "install",
            "cursor",
            "verify",
            "--b3-home",
            root_str,
            "--cursor-home",
            ch2.to_str().unwrap(),
            "--user-home",
            uh2.to_str().unwrap(),
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_ver2, 0, "fresh verify: {out_ver2}");
    assert!(out_ver2.contains("VERIFY_OK:"));
    assert!(out_ver2.contains("UNKNOWN / INCOMPLETE"));

    assert_eq!(
        fs::read_dir(ch2.join("skills")).unwrap().count(),
        expected_skills
    );
    assert!(!ch2.join("skills/b3-ship").exists());
    assert!(!ch2.join("skills/b3-plan").exists());
    assert!(!ch2.join("skills/b3-research-ship").exists());
    let cmd_count = fs::read_dir(ch2.join("commands"))
        .unwrap()
        .filter(|e| {
            e.as_ref()
                .is_ok_and(|d| d.file_name().to_string_lossy().starts_with("b3-"))
        })
        .count();
    assert_eq!(cmd_count, expected_cmds);
    assert!(ch2.join("commands/b3-research-ship.md").is_file());
    for new_cmd in ["b3-research", "b3-audit", "b3-refactor"] {
        assert!(
            ch2.join("commands").join(format!("{new_cmd}.md")).is_file(),
            "missing Cursor global command {new_cmd}"
        );
        assert!(
            !ch2.join("skills").join(new_cmd).exists(),
            "Cursor global must not duplicate command-skill {new_cmd} under skills/"
        );
    }

    let ag_files: Vec<_> = fs::read_dir(ch2.join("agents"))
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().starts_with("b3-"))
        .collect();
    assert_eq!(ag_files.len(), 5);
    let rev_txt = fs::read_to_string(ch2.join("agents/b3-reviewer.md")).unwrap();
    assert!(rev_txt.lines().any(|l| l.trim() == "model: inherit"));
    assert!(
        !rev_txt.contains("claude-") && !rev_txt.contains("gpt-") && !rev_txt.contains("gemini-")
    );
    let rules_bytes = fs::read(ch2.join("b3-user-rules.txt")).unwrap();
    assert!(rules_bytes.len() <= 1200, "rules len={}", rules_bytes.len());

    // Idempotent repeat preserves custom artifacts
    add_custom_cursor_artifacts(&ch2);
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "install",
                "--b3-home",
                root_str,
                "--cursor-home",
                ch2.to_str().unwrap(),
                "--user-home",
                uh2.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert!(fs::read_to_string(ch2.join("commands/my-cmd.md"))
        .unwrap()
        .contains("user cmd"));
    assert!(ch2.join("skills/my-custom-skill/SKILL.md").is_file());
    assert!(ch2.join("agents/my-agent.md").is_file());

    // 3. Broken link & tampered command detection + update repair
    let wrong_target = tmp.path.join("wrong-skill-dir");
    fs::create_dir_all(&wrong_target).unwrap();
    b3::adapters::common::remove_link_only(&ch2.join("skills/debugging")).unwrap();
    create_dir_link(&ch2.join("skills/debugging"), &wrong_target).unwrap();
    let dbg_cmd = ch2.join("commands/b3-debug.md");
    let orig_dbg = fs::read_to_string(&dbg_cmd).unwrap();
    write_lf(&dbg_cmd, &format!("{orig_dbg}\n<!-- tampered -->\n"));

    let (c_bad, out_bad, _) = run_b3_env(
        &[
            "install",
            "cursor",
            "verify",
            "--b3-home",
            root_str,
            "--cursor-home",
            ch2.to_str().unwrap(),
            "--user-home",
            uh2.to_str().unwrap(),
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_bad, 1);
    assert!(out_bad.contains("VERIFY_FAIL:"));

    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "update",
                "--b3-home",
                root_str,
                "--cursor-home",
                ch2.to_str().unwrap(),
                "--user-home",
                uh2.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "verify",
                "--b3-home",
                root_str,
                "--cursor-home",
                ch2.to_str().unwrap(),
                "--user-home",
                uh2.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );

    // 4. Update + obsolete skill pruning + custom preservation using snapshot B3_HOME
    let b3_copy = tmp.path.join("b3-copy");
    copy_b3_snapshot(&b3_copy, false);
    let uh4 = tmp.path.join("u4");
    let ch4 = uh4.join(".cursor");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "install",
                "--b3-home",
                b3_copy.to_str().unwrap(),
                "--cursor-home",
                ch4.to_str().unwrap(),
                "--user-home",
                uh4.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    add_custom_cursor_artifacts(&ch4);
    write_lf(
        &b3_copy.join("skills/engineering/demo-extra/SKILL.md"),
        "---\nname: demo-extra\ndescription: extra skill\n---\n# demo\n",
    );
    let plan_src = b3_copy.join("commands/b3-plan.md");
    let plan_orig = fs::read_to_string(&plan_src).unwrap();
    write_lf(&plan_src, &format!("{plan_orig}\n<!-- updated line -->\n"));
    remove_dir_tree_safely(&b3_copy.join("skills/engineering/refactoring")).unwrap();

    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "update",
                "--b3-home",
                b3_copy.to_str().unwrap(),
                "--cursor-home",
                ch4.to_str().unwrap(),
                "--user-home",
                uh4.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "verify",
                "--b3-home",
                b3_copy.to_str().unwrap(),
                "--cursor-home",
                ch4.to_str().unwrap(),
                "--user-home",
                uh4.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert!(ch4.join("skills/demo-extra/SKILL.md").is_file());
    assert!(!ch4.join("skills/refactoring").exists());
    assert!(fs::read_to_string(ch4.join("commands/b3-plan.md"))
        .unwrap()
        .contains("updated line"));
    assert!(ch4.join("skills/my-custom-skill/SKILL.md").is_file());

    // 5. Legacy b3-ai-engineering migration (--force), unmanaged conflict protection, & non-skill dir refusal
    let uh5 = tmp.path.join("u5");
    let ch5 = uh5.join(".cursor");
    write_lf(
        &ch5.join("commands/b3-ship.md"),
        "# user custom ship override\n",
    );
    write_lf(&ch5.join("commands/keep-me.md"), "# keep\n");
    write_lf(
        &ch5.join("agents/b3-reviewer.md"),
        "# user custom reviewer\n",
    );
    write_lf(
        &ch5.join("skills/code-review/SKILL.md"),
        "---\nname: code-review\ndescription: local copy\n---\n",
    );
    create_dir_link(&ch5.join("skills/b3-ai-engineering"), &root.join("skills")).unwrap();

    let (c_ref5, _, _) = run_b3_env(
        &[
            "install",
            "cursor",
            "install",
            "--b3-home",
            root_str,
            "--cursor-home",
            ch5.to_str().unwrap(),
            "--user-home",
            uh5.to_str().unwrap(),
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_ref5, 1);
    assert!(fs::read_to_string(ch5.join("commands/b3-ship.md"))
        .unwrap()
        .contains("user custom ship override"));

    let (c_f5, out_f5, err_f5) = run_b3_env(
        &[
            "install",
            "cursor",
            "install",
            "--b3-home",
            root_str,
            "--cursor-home",
            ch5.to_str().unwrap(),
            "--user-home",
            uh5.to_str().unwrap(),
            "--force",
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_f5, 0, "force migration failed: {out_f5}\n{err_f5}");
    assert!(!ch5.join("skills/b3-ai-engineering").exists());
    assert!(ch5.join("commands/keep-me.md").is_file());

    // Non-skill dir under skills/ must be rejected even with --force
    let uh_ns = tmp.path.join("u-nonskill");
    let ch_ns = uh_ns.join(".cursor");
    write_lf(
        &ch_ns.join("skills/debugging/not-a-skill.txt"),
        "not a skill\n",
    );
    let (c_ns, out_ns, err_ns) = run_b3_env(
        &[
            "install",
            "cursor",
            "install",
            "--b3-home",
            root_str,
            "--cursor-home",
            ch_ns.to_str().unwrap(),
            "--user-home",
            uh_ns.to_str().unwrap(),
            "--force",
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_ns, 1);
    let combined_ns = format!("{out_ns}\n{err_ns}");
    assert!(combined_ns.contains("non-skill"), "out={combined_ns}");

    // 6. Paths containing spaces & '&' special chars
    let uh_sp = tmp.path.join("u15 amp & space dir");
    let ch_sp = uh_sp.join(".cursor");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "install",
                "--b3-home",
                root_str,
                "--cursor-home",
                ch_sp.to_str().unwrap(),
                "--user-home",
                uh_sp.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "verify",
                "--b3-home",
                root_str,
                "--cursor-home",
                ch_sp.to_str().unwrap(),
                "--user-home",
                uh_sp.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "uninstall",
                "--cursor-home",
                ch_sp.to_str().unwrap(),
                "--user-home",
                uh_sp.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert!(!ch_sp.join("skills/debugging").exists());
    assert!(!ch_sp.join(".b3-global-manifest").exists());

    // 7. Coexistence warning + uninstall keeping custom & ~/.agents/skills
    let uh8 = tmp.path.join("u8");
    let ch8 = uh8.join(".cursor");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "install",
                "--b3-home",
                root_str,
                "--cursor-home",
                ch8.to_str().unwrap(),
                "--user-home",
                uh8.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    write_lf(
        &uh8.join(".agents/skills/code-review/SKILL.md"),
        "---\nname: code-review\ndescription: codex copy\n---\n",
    );
    let (c_coex, out_coex, _) = run_b3_env(
        &[
            "install",
            "cursor",
            "verify",
            "--b3-home",
            root_str,
            "--cursor-home",
            ch8.to_str().unwrap(),
            "--user-home",
            uh8.to_str().unwrap(),
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_coex, 0);
    assert!(out_coex.contains("COEXISTENCE_WARNING:"));
    add_custom_cursor_artifacts(&ch8);
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "uninstall",
                "--cursor-home",
                ch8.to_str().unwrap(),
                "--user-home",
                uh8.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert!(ch8.join("skills/my-custom-skill/SKILL.md").is_file());
    assert!(ch8.join("commands/my-cmd.md").is_file());
    assert!(ch8.join("agents/my-agent.md").is_file());
    assert!(uh8.join(".agents/skills/code-review/SKILL.md").is_file());

    // 8. Symlink/junction destination & subdir parent rejection
    let uh11 = tmp.path.join("u11");
    let live_target = uh11.join("live-cu-target");
    let live_link = uh11.join("live-cu-link");
    fs::create_dir_all(&live_target).unwrap();
    create_dir_link(&live_link, &live_target).unwrap();
    for act in ["install", "verify", "uninstall"] {
        let mut args = vec![
            "install",
            "cursor",
            act,
            "--b3-home",
            root_str,
            "--cursor-home",
            live_link.to_str().unwrap(),
            "--user-home",
            uh11.to_str().unwrap(),
        ];
        if act == "install" {
            args.push("--force");
        }
        assert_eq!(
            run_b3_env(&args, None, &[], &[]).0,
            1,
            "link cursor_home {act}"
        );
    }
    assert_eq!(fs::read_dir(&live_target).unwrap().count(), 0);

    let sub_cu = uh11.join("sub-cu");
    let ext_cmd = uh11.join("ext-cmd");
    fs::create_dir_all(&sub_cu).unwrap();
    fs::create_dir_all(&ext_cmd).unwrap();
    create_dir_link(&sub_cu.join("commands"), &ext_cmd).unwrap();
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "install",
                "--b3-home",
                root_str,
                "--cursor-home",
                sub_cu.to_str().unwrap(),
                "--user-home",
                uh11.to_str().unwrap(),
                "--force",
            ],
            None,
            &[],
            &[],
        )
        .0,
        1
    );
    assert!(!ext_cmd.join("b3-ship.md").exists());

    // 9. F4 modified managed file protection on uninstall
    let uh12 = tmp.path.join("u12");
    let ch12 = uh12.join(".cursor");
    let dbg_tgt = uh12.join("custom-dbg");
    fs::create_dir_all(&dbg_tgt).unwrap();
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "install",
                "--b3-home",
                root_str,
                "--cursor-home",
                ch12.to_str().unwrap(),
                "--user-home",
                uh12.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    let plan12 = ch12.join("commands/b3-plan.md");
    write_lf(
        &plan12,
        &format!(
            "{}\n<!-- user edit -->\n",
            fs::read_to_string(&plan12).unwrap()
        ),
    );
    b3::adapters::common::remove_link_only(&ch12.join("skills/debugging")).unwrap();
    create_dir_link(&ch12.join("skills/debugging"), &dbg_tgt).unwrap();

    let (c_uc, out_uc, _) = run_b3_env(
        &[
            "install",
            "cursor",
            "uninstall",
            "--cursor-home",
            ch12.to_str().unwrap(),
            "--user-home",
            uh12.to_str().unwrap(),
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_uc, 1);
    assert!(out_uc.contains("UNINSTALL_CONFLICT:"));
    assert!(fs::read_to_string(&plan12).unwrap().contains("user edit"));
    assert!(ch12.join(".b3-global-manifest").is_file());

    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "uninstall",
                "--cursor-home",
                ch12.to_str().unwrap(),
                "--user-home",
                uh12.to_str().unwrap(),
                "--force",
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert!(!plan12.exists() && !ch12.join(".b3-global-manifest").exists());
    assert!(dbg_tgt.is_dir());

    // 10. Manifest corruption, path traversal refusal, & R025 9-variant malformed manifest parser tests
    let uh13 = tmp.path.join("u13");
    let ch13 = uh13.join(".cursor");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "cursor",
                "install",
                "--b3-home",
                root_str,
                "--cursor-home",
                ch13.to_str().unwrap(),
                "--user-home",
                uh13.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    let m13 = ch13.join(".b3-global-manifest");
    let clean_m13 = fs::read_to_string(&m13).unwrap();

    let decoy_file = uh13.join("outside-decoy.txt");
    let decoy_dir = uh13.join("outside-dir");
    write_lf(&decoy_file, "keep outside decoy\n");
    fs::create_dir_all(&decoy_dir).unwrap();
    let decoy_sha = sha256_file(&decoy_file);
    let trav_manifest = format!(
        "{}\ncommand|../../outside-decoy.txt|{decoy_sha}\nskill|../outside-dir|{}\nfile|C:/outside.txt|{decoy_sha}\nagent|..\\outside.md|{decoy_sha}\n",
        clean_m13.trim_end(),
        to_forward_path(&decoy_dir),
    );
    write_lf(&m13, &trav_manifest);
    for act in ["install", "update", "verify", "uninstall"] {
        assert_ne!(
            run_b3_env(
                &[
                    "install",
                    "cursor",
                    act,
                    "--b3-home",
                    root_str,
                    "--cursor-home",
                    ch13.to_str().unwrap(),
                    "--user-home",
                    uh13.to_str().unwrap(),
                ],
                None,
                &[],
                &[],
            )
            .0,
            0,
            "traversal manifest must block {act}"
        );
    }
    assert!(
        decoy_file.is_file() && decoy_dir.is_dir() && ch13.join("commands/b3-plan.md").is_file()
    );

    // R025 9-variant malformed manifest tests + general corrupt manifest
    let mut bad_cases: Vec<(&str, String)> = manifest_bad_variants(
        &clean_m13,
        "command|b3-plan.md|",
        "skill|debugging|",
        &"a".repeat(64),
    );
    bad_cases.push((
        "corrupt-line",
        "schema=corrupt\nbad_line_without_equals\n".to_string(),
    ));
    for (vname, body) in bad_cases {
        write_lf(&m13, &body);
        for act in ["install", "update", "verify", "uninstall"] {
            assert_ne!(
                run_b3_env(
                    &[
                        "install",
                        "cursor",
                        act,
                        "--b3-home",
                        root_str,
                        "--cursor-home",
                        ch13.to_str().unwrap(),
                        "--user-home",
                        uh13.to_str().unwrap(),
                    ],
                    None,
                    &[],
                    &[],
                )
                .0,
                0,
                "R025 {vname} must block {act}"
            );
        }
        assert!(
            ch13.join("commands/b3-plan.md").is_file(),
            "R025 {vname} deleted managed file"
        );
    }
}

#[test]
fn antigravity_plugin_and_unified_global_lifecycle() {
    let root = repo_root();
    let root_str = root.to_str().unwrap();
    let core_skills = count_skill_md(&root.join("skills"));
    let cmd_skills = count_skill_md(&root.join("adapters/command-skills"));
    let total_skills = core_skills + cmd_skills;
    let tmp = TempDirGuard::new("ag-glob");

    // 1. Dry-run zero mutation
    let uh1 = tmp.path.join("u1");
    let pr1 = uh1.join(".gemini/config/plugins/b3-ai-engineering");
    let (c_dr, out_dr, _) = run_b3_env(
        &[
            "install",
            "antigravity",
            "install",
            "--b3-home",
            root_str,
            "--plugin-root",
            pr1.to_str().unwrap(),
            "--user-home",
            uh1.to_str().unwrap(),
            "--dry-run",
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_dr, 0);
    assert!(out_dr.contains("DRY_RUN_OK:"));
    assert!(!pr1.exists());

    // 2. Fresh install + 6-surface verify + strict 5-key plugin.json + <24KB frontmatter-stripped rules + subagent tools
    let uh2 = tmp.path.join("u2");
    let pr2 = uh2.join(".gemini/config/plugins/b3-ai-engineering");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "install",
                "--b3-home",
                root_str,
                "--plugin-root",
                pr2.to_str().unwrap(),
                "--user-home",
                uh2.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    let (c_v2, out_v2, _) = run_b3_env(
        &[
            "install",
            "antigravity",
            "verify",
            "--b3-home",
            root_str,
            "--plugin-root",
            pr2.to_str().unwrap(),
            "--user-home",
            uh2.to_str().unwrap(),
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_v2, 0, "verify: {out_v2}");
    for surf in [
        "check.plugin=OK",
        "check.rules=OK",
        "check.skills=OK",
        "check.commands=OK",
        "check.agents=OK",
        "check.skills_json=OK",
    ] {
        assert!(out_v2.contains(surf), "missing {surf} in {out_v2}");
    }
    assert!(out_v2.contains("UNKNOWN / INCOMPLETE"));
    assert_eq!(
        fs::read_dir(pr2.join("skills")).unwrap().count(),
        total_skills
    );
    for new_cmd in ["b3-research", "b3-audit", "b3-refactor"] {
        assert!(
            pr2.join("skills").join(new_cmd).join("SKILL.md").is_file(),
            "missing Antigravity plugin skill {new_cmd}"
        );
    }

    // Strict 5-key plugin.json
    let pj_val = parse_json(&fs::read_to_string(pr2.join("plugin.json")).unwrap()).unwrap();
    let JsonValue::Object(pj_props) = &pj_val else {
        panic!("plugin.json must be object");
    };
    assert_eq!(pj_props.len(), 5);
    assert_eq!(
        pj_val.get("name").and_then(JsonValue::as_str),
        Some("b3-ai-engineering")
    );
    assert_eq!(
        pj_val
            .get("suggestedPrompts")
            .and_then(JsonValue::as_array)
            .unwrap()
            .len(),
        3
    );

    // <24KB frontmatter-stripped rules/AGENTS.md
    let rules_bytes = fs::read(pr2.join("rules/AGENTS.md")).unwrap();
    assert!(
        rules_bytes.len() < 24_000,
        "rules_bytes={}",
        rules_bytes.len()
    );
    let rules_txt = String::from_utf8(rules_bytes).unwrap();
    assert!(!rules_txt.trim_start().starts_with("---"));
    assert!(rules_txt.contains("Project-level AGENTS.md"));
    assert!(rules_txt.contains("install-product is optional"));
    for slash in ["/b3-research", "/b3-audit", "/b3-refactor"] {
        assert!(
            rules_txt.contains(slash),
            "Antigravity rules/AGENTS.md missing {slash}"
        );
    }

    // Subagent tools: mapping (readonly=true -> [read_file]; b3-fixer readonly=false -> full tools)
    let rev_ag = fs::read_to_string(pr2.join("agents/b3-reviewer.md")).unwrap();
    assert!(rev_ag.contains("subagent: true") && rev_ag.contains("mainAgent: false"));
    assert!(rev_ag.contains("tools: [read_file]"));
    assert!(!rev_ag.lines().any(|l| l.starts_with("model:")));
    let fix_ag = fs::read_to_string(pr2.join("agents/b3-fixer.md")).unwrap();
    assert!(fix_ag.contains("tools: [read_file, edit_file, write_file, run_command, manage_task]"));

    // 3. P1 modified managed file -> UPDATE_CONFLICT pre-write abort; untracked custom skill survival
    let uh_p1 = tmp.path.join("u-p1");
    let pr_p1 = uh_p1.join(".gemini/config/plugins/b3-ai-engineering");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "install",
                "--b3-home",
                root_str,
                "--plugin-root",
                pr_p1.to_str().unwrap(),
                "--user-home",
                uh_p1.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    let ext_skill = uh_p1.join("external-user-skill");
    write_lf(
        &ext_skill.join("SKILL.md"),
        "---\nname: user-custom\ndescription: user\n---\n",
    );
    create_dir_link(&pr_p1.join("skills/user-custom"), &ext_skill).unwrap();
    write_lf(
        &pr_p1.join("agents/user-generated.md"),
        "<!-- Generated from /other/agents/user-generated.md -->\n",
    );

    let pj_sha0 = sha256_file(&pr_p1.join("plugin.json"));
    let man_sha0 = sha256_file(&pr_p1.join(".b3-plugin-manifest"));
    let ag_p1 = pr_p1.join("agents/b3-reviewer.md");
    write_lf(
        &ag_p1,
        &format!(
            "{}\n<!-- personal edit -->\n",
            fs::read_to_string(&ag_p1).unwrap()
        ),
    );
    let (c_uc1, out_uc1, err_uc1) = run_b3_env(
        &[
            "install",
            "antigravity",
            "update",
            "--b3-home",
            root_str,
            "--plugin-root",
            pr_p1.to_str().unwrap(),
            "--user-home",
            uh_p1.to_str().unwrap(),
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_uc1, 1);
    assert!(format!("{out_uc1}\n{err_uc1}").contains("UPDATE_CONFLICT"));
    assert_eq!(sha256_file(&pr_p1.join("plugin.json")), pj_sha0);
    assert_eq!(sha256_file(&pr_p1.join(".b3-plugin-manifest")), man_sha0);
    assert!(fs::read_to_string(&ag_p1)
        .unwrap()
        .contains("personal edit"));

    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "update",
                "--b3-home",
                root_str,
                "--plugin-root",
                pr_p1.to_str().unwrap(),
                "--user-home",
                uh_p1.to_str().unwrap(),
                "--force",
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert!(pr_p1.join("skills/user-custom/SKILL.md").is_file());
    assert!(pr_p1.join("agents/user-generated.md").is_file());

    // 4. --force preserves non-b3 custom skills while rejecting non-skill dir overwrite + extra-key plugin.json rejection
    let uh_f = tmp.path.join("u-force");
    let pr_f = uh_f.join(".gemini/config/plugins/b3-ai-engineering");
    write_lf(
        &pr_f.join("skills/verification/SKILL.md"),
        "---\nname: verification\ndescription: local\n---\n",
    );
    write_lf(
        &pr_f.join("skills/my-custom-skill/SKILL.md"),
        "---\nname: my-custom-skill\ndescription: user\n---\n",
    );
    write_lf(&pr_f.join("skills/user-note.txt"), "keep me\n");
    write_lf(
        &pr_f.join("skills/debugging/not-a-skill.txt"),
        "not a skill\n",
    );
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "install",
                "--b3-home",
                root_str,
                "--plugin-root",
                pr_f.to_str().unwrap(),
                "--user-home",
                uh_f.to_str().unwrap(),
                "--force",
            ],
            None,
            &[],
            &[],
        )
        .0,
        1
    );
    remove_dir_tree_safely(&pr_f.join("skills/debugging")).unwrap();
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "install",
                "--b3-home",
                root_str,
                "--plugin-root",
                pr_f.to_str().unwrap(),
                "--user-home",
                uh_f.to_str().unwrap(),
                "--force",
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert!(pr_f.join("skills/my-custom-skill/SKILL.md").is_file());
    assert!(pr_f.join("skills/user-note.txt").is_file());
    assert!(pr_f.join("skills/verification/SKILL.md").is_file());

    // Extra-key plugin.json must not pass verify/unforced install
    let pr_extra = uh_f.join("extra-key-plugin");
    write_lf(
        &pr_extra.join("plugin.json"),
        "{\"name\":\"b3-ai-engineering\",\"skills\":\"./x\"}\n",
    );
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "install",
                "--b3-home",
                root_str,
                "--plugin-root",
                pr_extra.to_str().unwrap(),
                "--user-home",
                uh_f.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        1
    );

    // 5. Drift diagnostics (check.plugin=FAIL, check.rules=FAIL, stale agent, skills.json)
    let b3_drift = tmp.path.join("b3-drift");
    copy_b3_snapshot(&b3_drift, true);
    let stale_ag = b3_drift.join("agents/b3-stale-generated.md");
    write_lf(
        &stale_ag,
        "---\nname: b3-stale\ndescription: temp\nreadonly: true\n---\nTemp.\n",
    );
    let uh_dr = tmp.path.join("u-drift");
    let pr_dr = uh_dr.join(".gemini/config/plugins/b3-ai-engineering");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "install",
                "--b3-home",
                b3_drift.to_str().unwrap(),
                "--plugin-root",
                pr_dr.to_str().unwrap(),
                "--user-home",
                uh_dr.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    write_lf(
        &pr_dr.join("plugin.json"),
        &format!(
            "{} \n",
            fs::read_to_string(pr_dr.join("plugin.json")).unwrap()
        ),
    );
    let (cvp, ovp, _) = run_b3_env(
        &[
            "install",
            "antigravity",
            "verify",
            "--b3-home",
            b3_drift.to_str().unwrap(),
            "--plugin-root",
            pr_dr.to_str().unwrap(),
            "--user-home",
            uh_dr.to_str().unwrap(),
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(cvp, 1);
    assert!(ovp.contains("check.plugin=FAIL") && ovp.contains("check.rules=OK"));
    fs::remove_file(&stale_ag).unwrap();
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "update",
                "--b3-home",
                b3_drift.to_str().unwrap(),
                "--plugin-root",
                pr_dr.to_str().unwrap(),
                "--user-home",
                uh_dr.to_str().unwrap(),
                "--force",
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert!(!pr_dr.join("agents/b3-stale-generated.md").exists());

    // 6. skills.json merge, dedup, custom-key preservation, corrupt refusal, symlink refusal, & pure uninstall removal
    let uh22 = tmp.path.join("u22");
    let pr22 = uh22.join(".gemini/config/plugins/b3-ai-engineering");
    let sj22 = uh22.join(".gemini/config/skills.json");
    let b3_fwd = to_forward_path(&root);
    let seed_sj = format!(
        "{{\n  \"inherits\": [\"./shared.json\"],\n  \"note\": \"keep-top\",\n  \"entries\": [\n    {{ \"path\": \"D:/my-custom-skills\", \"include_only\": [\"foo\"] }},\n    {{ \"path\": \"{b3_fwd}/skills/removed-cat\" }},\n    {{ \"path\": \"{b3_fwd}/adapters/command-skills\" }}\n  ]\n}}\n"
    );
    write_lf(&sj22, &seed_sj);
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "install",
                "--b3-home",
                root_str,
                "--plugin-root",
                pr22.to_str().unwrap(),
                "--user-home",
                uh22.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    let sj_parsed = parse_json(&fs::read_to_string(&sj22).unwrap()).unwrap();
    assert_eq!(
        sj_parsed.get("note").and_then(JsonValue::as_str),
        Some("keep-top")
    );
    assert_eq!(
        sj_parsed
            .get("inherits")
            .and_then(JsonValue::as_array)
            .unwrap()
            .len(),
        1
    );
    let sj_paths: Vec<String> = sj_parsed
        .get("entries")
        .and_then(JsonValue::as_array)
        .unwrap()
        .iter()
        .filter_map(|e| {
            e.get("path")
                .and_then(JsonValue::as_str)
                .map(str::to_string)
        })
        .collect();
    assert!(sj_paths.iter().any(|p| p == "D:/my-custom-skills"));
    assert!(!sj_paths.iter().any(|p| p.ends_with("/skills/removed-cat")));
    assert_eq!(
        sj_paths
            .iter()
            .filter(|p| p.ends_with("/adapters/command-skills"))
            .count(),
        1
    );
    assert!(sj_paths.iter().any(|p| p.ends_with("/skills/engineering")));

    // Corrupt skills.json refused without --force, healed with --force
    write_lf(&sj22, "{bad json\n");
    let (c_sjc, o_sjc, e_sjc) = run_b3_env(
        &[
            "install",
            "antigravity",
            "update",
            "--b3-home",
            root_str,
            "--plugin-root",
            pr22.to_str().unwrap(),
            "--user-home",
            uh22.to_str().unwrap(),
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_sjc, 1);
    let combined_sjc = format!("{o_sjc}\n{e_sjc}");
    assert!(
        combined_sjc.contains("UPDATE_CONFLICT"),
        "out={combined_sjc}"
    );
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "update",
                "--b3-home",
                root_str,
                "--plugin-root",
                pr22.to_str().unwrap(),
                "--user-home",
                uh22.to_str().unwrap(),
                "--force",
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );

    // Re-seed custom skills.json, update, then uninstall removes only B3 entries & preserves custom
    write_lf(&sj22, &seed_sj);
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "update",
                "--b3-home",
                root_str,
                "--plugin-root",
                pr22.to_str().unwrap(),
                "--user-home",
                uh22.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "uninstall",
                "--plugin-root",
                pr22.to_str().unwrap(),
                "--user-home",
                uh22.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    let sj_post = parse_json(&fs::read_to_string(&sj22).unwrap()).unwrap();
    assert_eq!(
        sj_post.get("note").and_then(JsonValue::as_str),
        Some("keep-top")
    );
    let post_entries = sj_post
        .get("entries")
        .and_then(JsonValue::as_array)
        .unwrap();
    assert_eq!(post_entries.len(), 1);
    assert_eq!(
        post_entries[0].get("path").and_then(JsonValue::as_str),
        Some("D:/my-custom-skills")
    );

    // Pure B3-only install then uninstall deletes skills.json completely
    let uh_pure = tmp.path.join("u22pure");
    let pr_pure = uh_pure.join(".gemini/config/plugins/b3-ai-engineering");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "install",
                "--b3-home",
                root_str,
                "--plugin-root",
                pr_pure.to_str().unwrap(),
                "--user-home",
                uh_pure.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert!(uh_pure.join(".gemini/config/skills.json").is_file());
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "uninstall",
                "--plugin-root",
                pr_pure.to_str().unwrap(),
                "--user-home",
                uh_pure.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert!(!uh_pure.join(".gemini/config/skills.json").exists());

    // Symlinked skills.json refused even with --force
    let uh_sym = tmp.path.join("u22sym");
    let pr_sym = uh_sym.join(".gemini/config/plugins/b3-ai-engineering");
    let sym_tgt = uh_sym.join("sym-target");
    fs::create_dir_all(&sym_tgt).unwrap();
    create_dir_link(&uh_sym.join(".gemini/config/skills.json"), &sym_tgt).unwrap();
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "install",
                "--b3-home",
                root_str,
                "--plugin-root",
                pr_sym.to_str().unwrap(),
                "--user-home",
                uh_sym.to_str().unwrap(),
                "--force",
            ],
            None,
            &[],
            &[],
        )
        .0,
        1
    );

    // 7. Pre-manifest legacy uninstall fallback + R025 9-variant plugin manifest hardening
    let uh_leg = tmp.path.join("u-leg");
    let pr_leg = uh_leg.join(".gemini/config/plugins/b3-ai-engineering");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "install",
                "--b3-home",
                root_str,
                "--plugin-root",
                pr_leg.to_str().unwrap(),
                "--user-home",
                uh_leg.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    fs::remove_file(pr_leg.join(".b3-plugin-manifest")).unwrap();
    write_lf(&pr_leg.join("keep-legacy.txt"), "keep\n");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "uninstall",
                "--plugin-root",
                pr_leg.to_str().unwrap(),
                "--user-home",
                uh_leg.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert!(pr_leg.join("keep-legacy.txt").is_file());
    assert!(!pr_leg.join("plugin.json").exists());
    assert!(!pr_leg.join("rules/AGENTS.md").exists());

    // R025 manifest hardening on Antigravity
    let uh_m = tmp.path.join("u-ag-m");
    let pr_m = uh_m.join(".gemini/config/plugins/b3-ai-engineering");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "antigravity",
                "install",
                "--b3-home",
                root_str,
                "--plugin-root",
                pr_m.to_str().unwrap(),
                "--user-home",
                uh_m.to_str().unwrap(),
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    let ag_man = pr_m.join(".b3-plugin-manifest");
    let ag_clean = fs::read_to_string(&ag_man).unwrap();
    for (vname, body) in manifest_bad_variants(
        &ag_clean,
        "file|plugin.json|",
        "link|skills/debugging|",
        &"b".repeat(64),
    ) {
        write_lf(&ag_man, &body);
        for act in ["verify", "update", "uninstall"] {
            assert_ne!(
                run_b3_env(
                    &[
                        "install",
                        "antigravity",
                        act,
                        "--b3-home",
                        root_str,
                        "--plugin-root",
                        pr_m.to_str().unwrap(),
                        "--user-home",
                        uh_m.to_str().unwrap(),
                    ],
                    None,
                    &[],
                    &[],
                )
                .0,
                0,
                "ag R025 {vname} must block {act}"
            );
        }
        assert!(pr_m.join("plugin.json").is_file());
    }

    // 8. Unified `b3 install global` (trailing-slash --b3-home, --host all partial failure, full lifecycle)
    let uh_tr = tmp.path.join("User Trail Space");
    fs::create_dir_all(&uh_tr).unwrap();
    let sep = std::path::MAIN_SEPARATOR;
    let b3_trail = format!("{root_str}{sep}");
    let uh_trail = format!("{}{sep}", uh_tr.display());
    let ch_trail = format!("{}{sep}", uh_tr.join(".cursor").display());
    let pr_trail = format!(
        "{}{sep}",
        uh_tr
            .join(".gemini/config/plugins/Ag Trail Space")
            .display()
    );
    for act in ["install", "verify", "uninstall"] {
        let (c, out, err) = run_b3_env(
            &[
                "install",
                "global",
                act,
                "--host",
                "all",
                "--b3-home",
                &b3_trail,
                "--cursor-home",
                &ch_trail,
                "--plugin-root",
                &pr_trail,
                "--user-home",
                &uh_trail,
            ],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        );
        assert_eq!(c, 0, "trailing-slash global {act}: {out}\n{err}");
        assert!(out.contains("GLOBAL_OK:"));
    }

    // Mixed-host partial failure propagation: Cursor fails (unmanaged command), Antigravity still succeeds, overall exits 1
    let uh_mix = tmp.path.join("u-mix");
    write_lf(
        &uh_mix.join(".cursor/commands/b3-ship.md"),
        "unmanaged custom\n",
    );
    let (c_mix, out_mix, _) = run_b3_env(
        &[
            "install",
            "global",
            "install",
            "--host",
            "all",
            "--b3-home",
            root_str,
            "--user-home",
            uh_mix.to_str().unwrap(),
        ],
        None,
        &[],
        &["B3_SKIP_CONFIG_INIT", "B3_CONFIG_PERSONAL"],
    );
    assert_eq!(c_mix, 1);
    assert!(out_mix.contains("host=cursor status=FAIL"));
    assert!(out_mix.contains("host=antigravity status=OK"));
    assert!(out_mix.contains("GLOBAL_FAIL:"));
    assert!(!uh_mix.join(".b3/models.md").exists());
}

#[test]
fn product_attach_sync_smart_b3_home_and_model_preferences() {
    let root = repo_root();
    let root_str = root.to_str().unwrap();
    let tmp = TempDirGuard::new("prod-sync");

    // 0. Source repo has no committed .cursor/rules or .agents/skills.json; verify-only fails cleanly before sync
    let tracked_host_cfg = std::process::Command::new("git")
        .arg("-C")
        .arg(&root)
        .args(["ls-files", ".cursor/rules", ".agents/skills.json"])
        .output()
        .expect("git ls-files");
    assert!(tracked_host_cfg.status.success());
    assert!(
        String::from_utf8_lossy(&tracked_host_cfg.stdout)
            .trim()
            .is_empty(),
        "source repo must not commit .cursor/rules or .agents/skills.json"
    );

    // 1. b3 sync across cursor/codex/claude/antigravity + verify-only + unmanaged conflict + empty vs non-empty replacement + coexistence guard
    let sync_fx = tmp.path.join("sync-fx");
    copy_b3_snapshot(&sync_fx, true);
    assert!(!sync_fx.join(".cursor/rules").exists());
    assert!(!sync_fx.join(".agents/skills.json").exists());
    let sync_s = sync_fx.to_str().unwrap();

    // Antigravity & Cursor verify-only report missing activation before sync
    let (c_agv_pre, out_agv_pre, err_agv_pre) = run_b3_env(
        &[
            "sync",
            "--repo-root",
            sync_s,
            "--host",
            "antigravity",
            "--verify-only",
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_agv_pre, 1);
    assert!(
        format!("{out_agv_pre}\n{err_agv_pre}").contains("missing manifest"),
        "expected missing manifest, got: {out_agv_pre}\n{err_agv_pre}"
    );
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                sync_s,
                "--host",
                "cursor",
                "--verify-only",
            ],
            None,
            &[],
            &[],
        )
        .0,
        1
    );

    // Path-traversal entry in .agents/skills.json is rejected by --verify-only and refused by sync without --force
    let ag_manifest = sync_fx.join(".agents/skills.json");
    write_lf(
        &ag_manifest,
        "{\n  \"entries\": [{ \"path\": \"../outside\" }]\n}\n",
    );
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                sync_s,
                "--host",
                "antigravity",
                "--verify-only",
            ],
            None,
            &[],
            &[],
        )
        .0,
        1
    );

    // Unmanaged .agents/skills.json (extra top-level key or extra per-entry key) refused without --force, overwritten with --force
    write_lf(
        &ag_manifest,
        "{\n  \"entries\": [{ \"path\": \"custom\", \"note\": \"keep\" }],\n  \"inherits\": true\n}\n",
    );
    let (c_ag_unmanaged, out_ag_unmanaged, err_ag_unmanaged) = run_b3_env(
        &["sync", "--repo-root", sync_s, "--host", "antigravity"],
        None,
        &[("B3_SKIP_CONFIG_INIT", "1")],
        &[],
    );
    assert_eq!(c_ag_unmanaged, 1);
    assert!(
        format!("{out_ag_unmanaged}\n{err_ag_unmanaged}").contains("OWNERSHIP_UNKNOWN"),
        "got: {out_ag_unmanaged}\n{err_ag_unmanaged}"
    );
    assert!(fs::read_to_string(&ag_manifest)
        .unwrap()
        .contains("inherits"));

    // Antigravity sync (--force overwrites unmanaged, repeated sync is idempotent, verify-only passes)
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                sync_s,
                "--host",
                "antigravity",
                "--force"
            ],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "antigravity"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    let (c_agv, out_agv, _) = run_b3_env(
        &[
            "sync",
            "--repo-root",
            sync_s,
            "--host",
            "antigravity",
            "--verify-only",
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_agv, 0);
    assert!(out_agv.contains("verify ok:"));

    // Codex sync + verify-only
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "codex"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                sync_s,
                "--host",
                "codex",
                "--verify-only"
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    for new_cmd in ["b3-research", "b3-audit", "b3-refactor"] {
        assert!(
            sync_fx
                .join(".agents/skills")
                .join(new_cmd)
                .join("SKILL.md")
                .is_file(),
            "missing Codex synced skill {new_cmd}"
        );
    }

    // Cursor coexistence guard against .agents/skills, then clean empty dir replacement vs non-empty refusal
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "cursor"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        1
    );
    remove_dir_tree_safely(&sync_fx.join(".agents/skills")).unwrap();

    // Empty .cursor/commands replaced; non-empty .cursor/agents refused
    fs::create_dir_all(sync_fx.join(".cursor/commands")).unwrap();
    write_lf(&sync_fx.join(".cursor/agents/keep.md"), "non-empty\n");
    let (c_nonempty, out_nonempty, err_nonempty) = run_b3_env(
        &["sync", "--repo-root", sync_s, "--host", "cursor"],
        None,
        &[("B3_SKIP_CONFIG_INIT", "1")],
        &[],
    );
    assert_eq!(c_nonempty, 1);
    let combined_nonempty = format!("{out_nonempty}\n{err_nonempty}");
    assert!(
        combined_nonempty.contains("refusing to replace"),
        "out={combined_nonempty}"
    );
    remove_dir_tree_safely(&sync_fx.join(".cursor/agents")).unwrap();

    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "cursor"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    // Repeated cursor sync is idempotent and generates thin .cursor/rules/*.mdc wrappers without duplicating rule bodies
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "cursor"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    for (stem, expected_apply) in [
        ("engineering-principles", true),
        ("evidence-and-provenance", true),
        ("portability", true),
        ("verification", true),
        ("simplest-correct", false),
    ] {
        let mdc = fs::read_to_string(sync_fx.join(format!(".cursor/rules/{stem}.mdc"))).unwrap();
        assert!(
            mdc.contains(&format!("alwaysApply: {expected_apply}")),
            "{stem}.mdc missing alwaysApply: {expected_apply}:\n{mdc}"
        );
        assert!(
            mdc.contains(&format!("@rules/{stem}.md")),
            "{stem}.mdc missing @rules/{stem}.md:\n{mdc}"
        );
        assert!(
            mdc.lines().count() <= 10 && !mdc.contains("Record tradeoffs"),
            "{stem}.mdc must stay a thin wrapper without duplicating canonical rule body:\n{mdc}"
        );
    }
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                sync_s,
                "--host",
                "cursor",
                "--verify-only"
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );

    // Cursor rules ownership, stale pruning, user-edit preservation, and honest --verify-only
    let custom_mdc = sync_fx.join(".cursor/rules/my-custom.mdc");
    write_lf(
        &custom_mdc,
        "---\nalwaysApply: false\n---\n# custom user rule\n",
    );

    // Unrelated user .mdc passes --verify-only and is never touched
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                sync_s,
                "--host",
                "cursor",
                "--verify-only"
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );

    // 1) Generated wrapper modified while RETAINING B3 marker -> refused without --force and preserved
    let eng_mdc = sync_fx.join(".cursor/rules/engineering-principles.mdc");
    let eng_orig = fs::read_to_string(&eng_mdc).unwrap();
    write_lf(&eng_mdc, &format!("{eng_orig}# user local tweak\n"));
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "cursor"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        1
    );
    assert!(fs::read_to_string(&eng_mdc)
        .unwrap()
        .contains("# user local tweak"));

    // 2) Legacy wrapper with user modification -> refused without --force and preserved
    write_lf(
        &eng_mdc,
        "---\ndescription: custom\nalwaysApply: true\n---\nFollow the portable engineering-principles rule:\n@rules/engineering-principles.md\n# legacy user note\n",
    );
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "cursor"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        1
    );
    assert!(fs::read_to_string(&eng_mdc)
        .unwrap()
        .contains("# legacy user note"));

    // 3) Explicit --force replaces conflicting wrapper while preserving custom my-custom.mdc
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "cursor", "--force"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert_eq!(fs::read_to_string(&eng_mdc).unwrap(), eng_orig);
    assert!(custom_mdc.is_file(), "user custom .mdc must be preserved");

    // 4) Stale unmodified B3 wrapper fails --verify-only and is pruned on sync; stale modified wrapper is NOT deleted
    let tmp_rule_src = sync_fx.join("rules/temp-b3-rule.md");
    write_lf(
        &tmp_rule_src,
        "---\ntype: rule\nstrength: hard\nscope: global\n---\n# Temp rule\nTemp constraint.\n",
    );
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "cursor"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    let tmp_rule_mdc = sync_fx.join(".cursor/rules/temp-b3-rule.mdc");
    assert!(tmp_rule_mdc.is_file());
    fs::remove_file(&tmp_rule_src).unwrap();
    // Stale managed wrapper fails --verify-only
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                sync_s,
                "--host",
                "cursor",
                "--verify-only"
            ],
            None,
            &[],
            &[],
        )
        .0,
        1
    );
    // Normal sync prunes unmodified stale B3 wrapper
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "cursor"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert!(
        !tmp_rule_mdc.exists(),
        "unmodified stale B3 wrapper must be pruned"
    );

    // Stale modified wrapper must NOT be deleted and must fail sync with STALE_RULE_CONFLICT + preserve sidecar
    write_lf(
        &tmp_rule_src,
        "---\ntype: rule\nstrength: hard\nscope: global\n---\n# Temp rule 2\nTemp constraint.\n",
    );
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "cursor"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    fs::remove_file(&tmp_rule_src).unwrap();
    fs::write(
        &tmp_rule_mdc,
        format!(
            "{}\n# user kept\n",
            fs::read_to_string(&tmp_rule_mdc).unwrap()
        ),
    )
    .unwrap();
    let rules_sidecar = sync_fx.join(".cursor/rules/.b3-rules-manifest.sha256");
    let sidecar_before_conflict = fs::read_to_string(&rules_sidecar).unwrap();
    assert!(sidecar_before_conflict.contains("temp-b3-rule.mdc="));
    let (c_stale_mod, out_stale_mod, err_stale_mod) = run_b3_env(
        &["sync", "--repo-root", sync_s, "--host", "cursor"],
        None,
        &[("B3_SKIP_CONFIG_INIT", "1")],
        &[],
    );
    assert_eq!(
        c_stale_mod, 1,
        "modified stale wrapper must fail sync: {out_stale_mod}\n{err_stale_mod}"
    );
    let stale_msg = format!("{out_stale_mod}\n{err_stale_mod}");
    assert!(
        stale_msg.contains("STALE_RULE_CONFLICT") && stale_msg.contains("temp-b3-rule.mdc"),
        "expected STALE_RULE_CONFLICT naming temp-b3-rule.mdc, got: {stale_msg}"
    );
    assert!(
        tmp_rule_mdc.is_file()
            && fs::read_to_string(&tmp_rule_mdc)
                .unwrap()
                .contains("# user kept"),
        "stale wrapper modified by user must NOT be deleted"
    );
    assert_eq!(
        fs::read_to_string(&rules_sidecar).unwrap(),
        sidecar_before_conflict,
        "sidecar ownership evidence must be preserved until conflict is resolved"
    );
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                sync_s,
                "--host",
                "cursor",
                "--verify-only"
            ],
            None,
            &[],
            &[],
        )
        .0,
        1
    );
    assert!(custom_mdc.is_file(), "unrelated user .mdc must stay intact");
    // Manual resolution -> sync, idempotent repeat sync, and --verify-only all pass and prune sidecar entry
    fs::remove_file(&tmp_rule_mdc).unwrap();
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "cursor"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "cursor"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                sync_s,
                "--host",
                "cursor",
                "--verify-only"
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert!(
        !fs::read_to_string(&rules_sidecar)
            .unwrap()
            .contains("temp-b3-rule.mdc"),
        "resolved stale wrapper must be removed from sidecar"
    );

    // 5) Honest --verify-only checks (no false PASS from substring spoofing, duplicate frontmatter, missing hard rule, or empty rules/)
    for bad_eng in [
        "---\nalwaysApply: false\n---\n@rules/engineering-principles.md\n",
        "---\nalwaysApply: false\n---\n# body spoof\nalwaysApply: true\n@rules/engineering-principles.md\n",
        "---\nalwaysApply: true\nalwaysApply: false\n---\n@rules/engineering-principles.md\n",
    ] {
        write_lf(&eng_mdc, bad_eng);
        assert_eq!(
            run_b3_env(
                &[
                    "sync",
                    "--repo-root",
                    sync_s,
                    "--host",
                    "cursor",
                    "--verify-only"
                ],
                None,
                &[],
                &[],
            )
            .0,
            1
        );
    }
    // Missing hard rule wrapper fails --verify-only
    fs::remove_file(&eng_mdc).unwrap();
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                sync_s,
                "--host",
                "cursor",
                "--verify-only"
            ],
            None,
            &[],
            &[],
        )
        .0,
        1
    );
    // Restore clean Cursor rules via --force
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "cursor", "--force"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );

    // Empty canonical rules/ directory fails --verify-only
    let empty_rules_fx = tmp.path.join("sync-empty-rules");
    copy_b3_snapshot(&empty_rules_fx, true);
    for entry in fs::read_dir(empty_rules_fx.join("rules")).unwrap() {
        fs::remove_file(entry.unwrap().path()).unwrap();
    }
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                empty_rules_fx.to_str().unwrap(),
                "--host",
                "cursor",
                "--verify-only"
            ],
            None,
            &[],
            &[],
        )
        .0,
        1
    );

    // Junctioned .cursor/rules is refused even with --force (isolated repo so sync_fx remains valid)
    let junc_fx = tmp.path.join("sync-cursor-junc");
    copy_b3_snapshot(&junc_fx, true);
    let decoy_rules = tmp.path.join("decoy-rules");
    fs::create_dir_all(&decoy_rules).unwrap();
    create_dir_link(&junc_fx.join(".cursor/rules"), &decoy_rules).unwrap();
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                junc_fx.to_str().unwrap(),
                "--host",
                "cursor",
                "--force"
            ],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        1
    );

    // Claude sync + verify-only (using clean snapshot)
    let sync_cl = tmp.path.join("sync-cl");
    copy_b3_snapshot(&sync_cl, true);
    let cl_s = sync_cl.to_str().unwrap();
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", cl_s, "--host", "claude"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                cl_s,
                "--host",
                "claude",
                "--verify-only"
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    for new_cmd in ["b3-research", "b3-audit", "b3-refactor"] {
        assert!(
            sync_cl
                .join(".claude/skills")
                .join(new_cmd)
                .join("SKILL.md")
                .is_file(),
            "missing Claude synced skill {new_cmd}"
        );
    }

    // 2. Product attach: Cursor coexistence guard, customized b3-ship.md protection, CF-13 empty .b3/home refusal & --force refresh without .cursor/commands leak, .gitignore .b3/ dedup
    let prod = tmp.path.join("prod");
    clone_seeded_git_repo(&prod);
    let prod_s = prod.to_str().unwrap();

    // Cursor coexistence guard against .agents/skills & .claude/skills
    fs::create_dir_all(prod.join(".agents/skills")).unwrap();
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "product",
                "--product-root",
                prod_s,
                "--b3-home",
                root_str,
                "--host",
                "cursor"
            ],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        1
    );
    fs::remove_dir(prod.join(".agents/skills")).unwrap();
    fs::remove_dir(prod.join(".agents")).unwrap();

    // .gitignore .b3/ upgrade + dedup
    write_lf(&prod.join(".gitignore"), ".b3/\n.b3/config.toml\n");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "product",
                "--product-root",
                prod_s,
                "--b3-home",
                root_str,
                "--host",
                "cursor"
            ],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    let gi_lines: Vec<String> = fs::read_to_string(prod.join(".gitignore"))
        .unwrap()
        .lines()
        .map(|l| l.trim().to_string())
        .collect();
    assert_eq!(gi_lines.iter().filter(|l| *l == ".b3/ship/").count(), 1);
    assert_eq!(
        gi_lines.iter().filter(|l| *l == ".b3/config.toml").count(),
        1
    );
    assert_eq!(
        git_in(&prod, &["check-ignore", "-q", ".b3/config.toml"]),
        ""
    );
    for new_cmd in ["b3-research", "b3-audit", "b3-refactor"] {
        assert!(
            prod.join(".cursor/commands")
                .join(format!("{new_cmd}.md"))
                .is_file(),
            "missing Cursor product command {new_cmd}"
        );
    }

    // Customized .cursor/commands/b3-ship.md overwrite protection
    let ship_cmd = prod.join(".cursor/commands/b3-ship.md");
    write_lf(&ship_cmd, "# user customized ship command\n");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "product",
                "--product-root",
                prod_s,
                "--b3-home",
                root_str,
                "--host",
                "cursor"
            ],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        1
    );
    assert!(fs::read_to_string(&ship_cmd)
        .unwrap()
        .contains("user customized"));
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "product",
                "--product-root",
                prod_s,
                "--b3-home",
                root_str,
                "--host",
                "cursor",
                "--force"
            ],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );

    // CF-13: empty .b3/home refusal + --force pointer refresh with --host codex without .cursor/commands leak
    let prod_cf13 = tmp.path.join("prod-cf13");
    clone_seeded_git_repo(&prod_cf13);
    write_lf(&prod_cf13.join(".b3/home"), "\n");
    let (c_emp, out_emp, err_emp) = run_b3_env(
        &[
            "install",
            "product",
            "--product-root",
            prod_cf13.to_str().unwrap(),
            "--b3-home",
            root_str,
            "--host",
            "codex",
        ],
        None,
        &[("B3_SKIP_CONFIG_INIT", "1")],
        &[],
    );
    assert_eq!(c_emp, 1);
    let combined_emp = format!("{out_emp}\n{err_emp}");
    assert!(
        combined_emp.contains("empty or invalid"),
        "out={combined_emp}"
    );
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "product",
                "--product-root",
                prod_cf13.to_str().unwrap(),
                "--b3-home",
                root_str,
                "--host",
                "codex",
                "--force",
            ],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert_eq!(
        fs::read_to_string(prod_cf13.join(".b3/home"))
            .unwrap()
            .trim(),
        root_str
    );
    assert!(
        !prod_cf13.join(".cursor/commands").exists(),
        "codex refresh leaked .cursor/commands"
    );

    // 3. Smart B3_HOME auto-discovery when --b3-home is omitted (B3_HOME env, <cwd>/.b3/home, executable ancestors)
    let snap_env = tmp.path.join("b3-snap-env");
    copy_b3_snapshot(&snap_env, true);
    let unrelated_cwd = tmp.path.join("unrelated-cwd");
    fs::create_dir_all(&unrelated_cwd).unwrap();

    // 3a. Via B3_HOME env var
    let uh_env = tmp.path.join("uh-env");
    let (c_ae, out_ae, _) = run_b3_env(
        &[
            "install",
            "cursor",
            "install",
            "--user-home",
            uh_env.to_str().unwrap(),
        ],
        Some(&unrelated_cwd),
        &[
            ("B3_HOME", snap_env.to_str().unwrap()),
            ("B3_SKIP_CONFIG_INIT", "1"),
        ],
        &[],
    );
    assert_eq!(c_ae, 0, "auto B3_HOME env: {out_ae}");
    assert_eq!(
        fs::read_to_string(uh_env.join(".cursor/b3-home"))
            .unwrap()
            .trim(),
        to_forward_path(&snap_env)
    );

    // 3b. Via <cwd>/.b3/home pointer file (B3_HOME unset!)
    let cwd_ptr = tmp.path.join("cwd-with-ptr");
    fs::create_dir_all(cwd_ptr.join(".b3")).unwrap();
    write_lf(
        &cwd_ptr.join(".b3/home"),
        &format!("{}\n", snap_env.display()),
    );
    let uh_ptr = tmp.path.join("uh-ptr");
    let (c_ap, out_ap, _) = run_b3_env(
        &[
            "install",
            "cursor",
            "install",
            "--user-home",
            uh_ptr.to_str().unwrap(),
        ],
        Some(&cwd_ptr),
        &[("B3_SKIP_CONFIG_INIT", "1")],
        &["B3_HOME"],
    );
    assert_eq!(c_ap, 0, "auto .b3/home pointer: {out_ap}");
    assert_eq!(
        fs::read_to_string(uh_ptr.join(".cursor/b3-home"))
            .unwrap()
            .trim(),
        to_forward_path(&snap_env)
    );

    // 3c. Via executable ancestor when B3_HOME is unset and CWD has no .b3/home
    let snap_exe = tmp.path.join("b3-snap-exe");
    copy_b3_snapshot(&snap_exe, true);
    let exe_dir = snap_exe.join("target/debug");
    fs::create_dir_all(&exe_dir).unwrap();
    let exe_name = if cfg!(windows) { "b3.exe" } else { "b3" };
    let copied_bin = exe_dir.join(exe_name);
    fs::copy(b3_bin(), &copied_bin).unwrap();
    let uh_exe = tmp.path.join("uh-exe");
    let exe_out = Command::new(&copied_bin)
        .current_dir(&unrelated_cwd)
        .env_remove("B3_HOME")
        .env("B3_SKIP_CONFIG_INIT", "1")
        .args([
            "install",
            "cursor",
            "install",
            "--user-home",
            uh_exe.to_str().unwrap(),
        ])
        .output()
        .expect("run copied b3 binary");
    assert_eq!(
        exe_out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&exe_out.stderr)
    );
    assert_eq!(
        fs::read_to_string(uh_exe.join(".cursor/b3-home"))
            .unwrap()
            .trim(),
        to_forward_path(&snap_exe)
    );

    // 4. B3_CONFIG_PERSONAL, B3_SKIP_CONFIG_INIT & legacy B3_SKIP_CONFIG_INIT lifecycle across install product, install global, & sync
    let pers = tmp.path.join("home-pers/.b3/config.toml");
    let pers_s = pers.to_str().unwrap();
    let prod_m = tmp.path.join("prod-m");
    clone_seeded_git_repo(&prod_m);
    let prod_ms = prod_m.to_str().unwrap();

    // --dry-run does not create
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "product",
                "--product-root",
                prod_ms,
                "--b3-home",
                root_str,
                "--host",
                "cursor",
                "--dry-run"
            ],
            None,
            &[("B3_CONFIG_PERSONAL", pers_s)],
            &[
                "B3_SKIP_CONFIG_INIT",
                "B3_SKIP_CONFIG_INIT",
                "B3_CONFIG_PERSONAL"
            ],
        )
        .0,
        0
    );
    assert!(!pers.exists());

    // B3_SKIP_CONFIG_INIT=1 skips creation
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "product",
                "--product-root",
                prod_ms,
                "--b3-home",
                root_str,
                "--host",
                "cursor"
            ],
            None,
            &[("B3_CONFIG_PERSONAL", pers_s), ("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert!(!pers.exists());

    // Normal install product creates B3_CONFIG_PERSONAL from config/config.example.toml (and NOT inside product/.b3/config.toml)
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "product",
                "--product-root",
                prod_ms,
                "--b3-home",
                root_str,
                "--host",
                "cursor"
            ],
            None,
            &[("B3_CONFIG_PERSONAL", pers_s)],
            &[
                "B3_SKIP_CONFIG_INIT",
                "B3_SKIP_CONFIG_INIT",
                "B3_CONFIG_PERSONAL"
            ],
        )
        .0,
        0
    );
    let seeded_pers = fs::read_to_string(&pers).unwrap();
    assert!(seeded_pers.contains("[models]") && seeded_pers.contains("[planning]"));
    assert!(!prod_m.join(".b3/config.toml").exists());

    // Custom edit preserved on subsequent install product & b3 sync
    write_lf(&pers, "[models.roles]\nplanning = [\"custom-reasoner\"]\n");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "product",
                "--product-root",
                prod_ms,
                "--b3-home",
                root_str,
                "--host",
                "cursor"
            ],
            None,
            &[("B3_CONFIG_PERSONAL", pers_s)],
            &[
                "B3_SKIP_CONFIG_INIT",
                "B3_SKIP_CONFIG_INIT",
                "B3_CONFIG_PERSONAL"
            ],
        )
        .0,
        0
    );
    assert!(fs::read_to_string(&pers)
        .unwrap()
        .contains("custom-reasoner"));

    let sync_pers = tmp.path.join("sync-pers/.b3/config.toml");
    let sync_pers_s = sync_pers.to_str().unwrap();
    // --verify-only does not create
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                sync_s,
                "--host",
                "cursor",
                "--verify-only"
            ],
            None,
            &[("B3_CONFIG_PERSONAL", sync_pers_s)],
            &[
                "B3_SKIP_CONFIG_INIT",
                "B3_SKIP_CONFIG_INIT",
                "B3_CONFIG_PERSONAL"
            ],
        )
        .0,
        0
    );
    assert!(!sync_pers.exists());
    // Normal sync seeds, then preserves
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "cursor"],
            None,
            &[("B3_CONFIG_PERSONAL", sync_pers_s)],
            &[
                "B3_SKIP_CONFIG_INIT",
                "B3_SKIP_CONFIG_INIT",
                "B3_CONFIG_PERSONAL"
            ],
        )
        .0,
        0
    );
    assert!(sync_pers.is_file());
    write_lf(
        &sync_pers,
        "[models.roles]\nplanning = [\"keep-sync-custom\"]\n",
    );
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", sync_s, "--host", "cursor"],
            None,
            &[("B3_CONFIG_PERSONAL", sync_pers_s)],
            &[
                "B3_SKIP_CONFIG_INIT",
                "B3_SKIP_CONFIG_INIT",
                "B3_CONFIG_PERSONAL"
            ],
        )
        .0,
        0
    );
    assert!(fs::read_to_string(&sync_pers)
        .unwrap()
        .contains("keep-sync-custom"));

    // install global --host all seeds ~/.b3/config.toml and preserves across update & uninstall
    let uh_gm = tmp.path.join("uh-gm");
    let gm_file = uh_gm.join(".b3/config.toml");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "global",
                "install",
                "--host",
                "all",
                "--b3-home",
                root_str,
                "--user-home",
                uh_gm.to_str().unwrap()
            ],
            None,
            &[],
            &[
                "B3_SKIP_CONFIG_INIT",
                "B3_SKIP_CONFIG_INIT",
                "B3_CONFIG_PERSONAL",
                "B3_CONFIG_PERSONAL"
            ],
        )
        .0,
        0
    );
    assert!(gm_file.is_file());
    write_lf(&gm_file, "# global personal preference - keep\n");
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "global",
                "update",
                "--host",
                "all",
                "--b3-home",
                root_str,
                "--user-home",
                uh_gm.to_str().unwrap()
            ],
            None,
            &[],
            &[
                "B3_SKIP_CONFIG_INIT",
                "B3_SKIP_CONFIG_INIT",
                "B3_CONFIG_PERSONAL",
                "B3_CONFIG_PERSONAL"
            ],
        )
        .0,
        0
    );
    assert_eq!(
        run_b3_env(
            &[
                "install",
                "global",
                "uninstall",
                "--host",
                "all",
                "--user-home",
                uh_gm.to_str().unwrap()
            ],
            None,
            &[],
            &[
                "B3_SKIP_CONFIG_INIT",
                "B3_SKIP_CONFIG_INIT",
                "B3_CONFIG_PERSONAL",
                "B3_CONFIG_PERSONAL"
            ],
        )
        .0,
        0
    );
    assert!(fs::read_to_string(&gm_file)
        .unwrap()
        .contains("global personal preference - keep"));
}

#[test]
fn b3_home_pointer_rejects_unc_and_reparse_parents() {
    let tmp = TempDirGuard::new("b3-home-sec");
    let decoy_snap = tmp.path.join("b3-decoy");
    copy_b3_snapshot(&decoy_snap, true);

    // 1. UNC / network paths inside `.b3/home` must be ignored without failing CLI execution.
    for (idx, unc) in ["\\\\127.0.0.1\\share\\b3", "//127.0.0.1/share/b3"]
        .into_iter()
        .enumerate()
    {
        let cwd_unc = tmp.path.join(format!("cwd-unc-{idx}"));
        let uh_unc = tmp.path.join(format!("uh-unc-{idx}"));
        fs::create_dir_all(cwd_unc.join(".b3")).unwrap();
        write_lf(&cwd_unc.join(".b3/home"), &format!("{unc}\n"));
        let (code, out, err) = run_b3_env(
            &[
                "install",
                "cursor",
                "install",
                "--user-home",
                uh_unc.to_str().unwrap(),
            ],
            Some(&cwd_unc),
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &["B3_HOME"],
        );
        assert_eq!(
            code, 0,
            "auto-discovery should fall back cleanly: {out}\n{err}"
        );
        let recorded = fs::read_to_string(uh_unc.join(".cursor/b3-home")).unwrap();
        let unc_fwd = unc.replace('\\', "/");
        assert!(
            !recorded.trim().replace('\\', "/").starts_with(&unc_fwd),
            "UNC path from .b3/home must be ignored, got {recorded}"
        );
    }

    // 2. `.b3` directory being a symlink/junction must ignore `.b3/home` cleanly.
    let target_b3_dir = tmp.path.join("real-dot-b3");
    fs::create_dir_all(&target_b3_dir).unwrap();
    write_lf(
        &target_b3_dir.join("home"),
        &format!("{}\n", decoy_snap.display()),
    );

    let cwd_junc = tmp.path.join("cwd-junc");
    let uh_junc = tmp.path.join("uh-junc");
    fs::create_dir_all(&cwd_junc).unwrap();
    create_dir_link(&cwd_junc.join(".b3"), &target_b3_dir).unwrap();

    let (code_j, out_j, err_j) = run_b3_env(
        &[
            "install",
            "cursor",
            "install",
            "--user-home",
            uh_junc.to_str().unwrap(),
        ],
        Some(&cwd_junc),
        &[("B3_SKIP_CONFIG_INIT", "1")],
        &["B3_HOME"],
    );
    assert_eq!(
        code_j, 0,
        "junctioned .b3 fallback failed: {out_j}\n{err_j}"
    );
    let recorded_j = fs::read_to_string(uh_junc.join(".cursor/b3-home")).unwrap();
    assert_ne!(
        recorded_j.trim(),
        to_forward_path(&decoy_snap),
        "pointer inside reparse .b3 dir must be ignored"
    );
}

#[test]
fn antigravity_manifest_upgrades_and_security_guards() {
    let tmp = TempDirGuard::new("ag-manifest-upg");
    let fx = tmp.path.join("b3-fx");
    copy_b3_snapshot(&fx, true);
    let fx_s = fx.to_str().unwrap();
    let manifest = fx.join(".agents/skills.json");

    // 1. Dry-run and verify-only without mutation on fresh checkout
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                fx_s,
                "--host",
                "antigravity",
                "--verify-only"
            ],
            None,
            &[],
            &[],
        )
        .0,
        1
    );
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                fx_s,
                "--host",
                "antigravity",
                "--dry-run"
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert!(
        !manifest.exists(),
        "--dry-run must not create .agents/skills.json"
    );

    // 2. Fresh generation + repeated idempotent sync + verify-only
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", fx_s, "--host", "antigravity"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    let initial_raw = fs::read_to_string(&manifest).unwrap();
    assert!(initial_raw.contains("adapters/command-skills"));
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", fx_s, "--host", "antigravity"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert_eq!(fs::read_to_string(&manifest).unwrap(), initial_raw);
    let (vc0, vout0, _) = run_b3_env(
        &[
            "sync",
            "--repo-root",
            fx_s,
            "--host",
            "antigravity",
            "--verify-only",
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(vc0, 0, "{vout0}");

    // 3. Adding a new canonical skill category upgrades manifest WITHOUT --force
    write_lf(
        &fx.join("skills/devops/ci-check/SKILL.md"),
        "---\nname: ci-check\ndescription: ci check\n---\n# ci\n",
    );
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", fx_s, "--host", "antigravity"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert!(fs::read_to_string(&manifest)
        .unwrap()
        .contains("skills/devops"));

    // 4. Removing a canonical skill category upgrades manifest WITHOUT --force
    remove_dir_tree_safely(&fx.join("skills/devops")).unwrap();
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", fx_s, "--host", "antigravity"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert!(!fs::read_to_string(&manifest)
        .unwrap()
        .contains("skills/devops"));

    // 5. B3-looking user-authored manifest & unknown legacy manifest (no sidecar) fail safely with OWNERSHIP_UNKNOWN
    let sidecar = fx.join(".agents/.b3-skills-manifest.sha256");
    assert!(sidecar.is_file(), "B3 sync must record manifest sidecar");
    let before_verify_raw = fs::read_to_string(&manifest).unwrap();
    let before_verify_sc = fs::read_to_string(&sidecar).unwrap();
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                fx_s,
                "--host",
                "antigravity",
                "--dry-run"
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );
    assert_eq!(fs::read_to_string(&manifest).unwrap(), before_verify_raw);
    assert_eq!(fs::read_to_string(&sidecar).unwrap(), before_verify_sc);

    // 5b. Exact-match user manifest WITHOUT sidecar must NOT be silently adopted (sync + verify-only fail; --force adopts)
    let exact_raw = fs::read_to_string(&manifest).unwrap();
    let orig_sidecar = fs::read_to_string(&sidecar).unwrap();
    fs::remove_file(&sidecar).unwrap();
    write_lf(&manifest, &exact_raw);
    let (c_exact_noside, out_exact_noside, err_exact_noside) = run_b3_env(
        &["sync", "--repo-root", fx_s, "--host", "antigravity"],
        None,
        &[("B3_SKIP_CONFIG_INIT", "1")],
        &[],
    );
    assert_eq!(c_exact_noside, 1);
    assert!(format!("{out_exact_noside}\n{err_exact_noside}").contains("OWNERSHIP_UNKNOWN"));
    assert_eq!(fs::read_to_string(&manifest).unwrap(), exact_raw);
    assert!(!sidecar.exists(), "refused sync must not mint sidecar");
    let (cv_exact_noside, outv_exact_noside, errv_exact_noside) = run_b3_env(
        &[
            "sync",
            "--repo-root",
            fx_s,
            "--host",
            "antigravity",
            "--verify-only",
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(cv_exact_noside, 1);
    assert!(format!("{outv_exact_noside}\n{errv_exact_noside}").contains("OWNERSHIP_UNKNOWN"));
    assert!(!sidecar.exists(), "--verify-only must not create sidecar");
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                fx_s,
                "--host",
                "antigravity",
                "--force"
            ],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert!(sidecar.is_file());
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", fx_s, "--host", "antigravity"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                fx_s,
                "--host",
                "antigravity",
                "--verify-only"
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );

    // 5c. Modified manifest retaining ALL expected entries + added top-level metadata + corrupt sidecar fail BOTH sync & verify-only
    let drifted_manifest = format!(
        "{{\n  \"inherits\": true,\n{}",
        exact_raw.strip_prefix("{\n").unwrap()
    );
    write_lf(&manifest, &drifted_manifest);
    let (c_drift_sync, out_drift_sync, err_drift_sync) = run_b3_env(
        &["sync", "--repo-root", fx_s, "--host", "antigravity"],
        None,
        &[("B3_SKIP_CONFIG_INIT", "1")],
        &[],
    );
    assert_eq!(c_drift_sync, 1);
    assert!(format!("{out_drift_sync}\n{err_drift_sync}").contains("OWNERSHIP_MODIFIED"));
    let (c_drift_ver, out_drift_ver, err_drift_ver) = run_b3_env(
        &[
            "sync",
            "--repo-root",
            fx_s,
            "--host",
            "antigravity",
            "--verify-only",
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_drift_ver, 1);
    assert!(format!("{out_drift_ver}\n{err_drift_ver}").contains("OWNERSHIP_MODIFIED"));
    assert_eq!(fs::read_to_string(&manifest).unwrap(), drifted_manifest);

    // Even if sidecar matches drifted top-level metadata manifest, --verify-only still fails on drift without mutating files
    write_lf(
        &sidecar,
        &format!("{}\n", sha256_bytes_hex(drifted_manifest.as_bytes())),
    );
    let (c_drift_ms_ver, out_drift_ms_ver, err_drift_ms_ver) = run_b3_env(
        &[
            "sync",
            "--repo-root",
            fx_s,
            "--host",
            "antigravity",
            "--verify-only",
        ],
        None,
        &[],
        &[],
    );
    assert_eq!(c_drift_ms_ver, 1);
    assert!(format!("{out_drift_ms_ver}\n{err_drift_ms_ver}").contains("drifted"));
    assert_eq!(fs::read_to_string(&manifest).unwrap(), drifted_manifest);

    // Corrupt sidecar with canonical manifest fails both normal sync and --verify-only without mutating files
    write_lf(&manifest, &exact_raw);
    write_lf(&sidecar, "not-a-valid-sha256\n");
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", fx_s, "--host", "antigravity"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        1
    );
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                fx_s,
                "--host",
                "antigravity",
                "--verify-only"
            ],
            None,
            &[],
            &[],
        )
        .0,
        1
    );
    assert_eq!(
        fs::read_to_string(&sidecar).unwrap(),
        "not-a-valid-sha256\n"
    );

    // Restoring original valid sidecar makes both --verify-only and normal sync pass again
    write_lf(&sidecar, &orig_sidecar);
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                fx_s,
                "--host",
                "antigravity",
                "--verify-only"
            ],
            None,
            &[],
            &[],
        )
        .0,
        0
    );

    // Modified generated manifest (sidecar mismatch) -> refused with OWNERSHIP_MODIFIED and preserved
    write_lf(
        &manifest,
        "{\n  \"entries\": [\n    { \"path\": \"skills/engineering\" }\n  ]\n}\n",
    );
    let (c_mod, out_mod, err_mod) = run_b3_env(
        &["sync", "--repo-root", fx_s, "--host", "antigravity"],
        None,
        &[("B3_SKIP_CONFIG_INIT", "1")],
        &[],
    );
    assert_eq!(c_mod, 1);
    assert!(format!("{out_mod}\n{err_mod}").contains("OWNERSHIP_MODIFIED"));
    assert!(!fs::read_to_string(&manifest)
        .unwrap()
        .contains("skills/backend"));

    // B3-looking user-authored manifest without sidecar (e.g. skills/internal) -> refused with OWNERSHIP_UNKNOWN
    fs::remove_file(&sidecar).unwrap();
    write_lf(
        &manifest,
        "{\n  \"entries\": [\n    { \"path\": \"skills/internal\" }\n  ]\n}\n",
    );
    let (c_unk, out_unk, err_unk) = run_b3_env(
        &["sync", "--repo-root", fx_s, "--host", "antigravity"],
        None,
        &[("B3_SKIP_CONFIG_INIT", "1")],
        &[],
    );
    assert_eq!(c_unk, 1);
    assert!(format!("{out_unk}\n{err_unk}").contains("OWNERSHIP_UNKNOWN"));
    assert!(fs::read_to_string(&manifest)
        .unwrap()
        .contains("skills/internal"));

    // Explicit --force overwrites and restores sidecar
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                fx_s,
                "--host",
                "antigravity",
                "--force"
            ],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );
    assert!(fs::read_to_string(&manifest)
        .unwrap()
        .contains("skills/backend"));
    assert!(sidecar.is_file());

    // 6. Customized user manifest refused WITHOUT --force, overwritten WITH --force
    write_lf(
        &manifest,
        "{\n  \"entries\": [\n    { \"path\": \"skills/engineering\" },\n    { \"path\": \"custom/my-skills\" }\n  ]\n}\n",
    );
    assert_eq!(
        run_b3_env(
            &["sync", "--repo-root", fx_s, "--host", "antigravity"],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        1
    );
    assert!(fs::read_to_string(&manifest)
        .unwrap()
        .contains("custom/my-skills"));
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                fx_s,
                "--host",
                "antigravity",
                "--force"
            ],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        0
    );

    // 7. Duplicate JSON keys & unsafe traversal paths rejected by --verify-only and refused without --force
    for bad in [
        "{\"entries\":[{\"path\":\"skills/engineering\"}],\"entries\":[{\"path\":\"skills/backend\"}]}",
        "{\"entries\":[{\"path\":\"skills/engineering\",\"path\":\"skills/backend\"}]}",
        "{\"entries\":[{\"path\":\"../outside\"}]}",
    ] {
        write_lf(&manifest, bad);
        assert_eq!(
            run_b3_env(
                &["sync", "--repo-root", fx_s, "--host", "antigravity", "--verify-only"],
                None,
                &[],
                &[],
            )
            .0,
            1
        );
        assert_eq!(
            run_b3_env(
                &["sync", "--repo-root", fx_s, "--host", "antigravity"],
                None,
                &[("B3_SKIP_CONFIG_INIT", "1")],
                &[],
            )
            .0,
            1
        );
    }

    // 8. Symlink/junction .agents/skills.json refused even with --force
    let decoy_file = tmp.path.join("decoy-skills");
    fs::create_dir_all(&decoy_file).unwrap();
    fs::remove_file(&manifest).unwrap();
    create_dir_link(&manifest, &decoy_file).unwrap();
    assert_eq!(
        run_b3_env(
            &[
                "sync",
                "--repo-root",
                fx_s,
                "--host",
                "antigravity",
                "--force"
            ],
            None,
            &[("B3_SKIP_CONFIG_INIT", "1")],
            &[],
        )
        .0,
        1
    );
}

#[test]
fn legacy_models_md_is_preserved_untouched_and_config_toml_initializes() {
    let root = repo_root();
    let root_str = root.to_str().unwrap();
    let tmp = TempDirGuard::new("toml-init-gi");

    // 1. When legacy ~/.b3/models.md exists and ~/.b3/config.toml does NOT exist:
    //    `b3 install global`, `b3 install product`, and `b3 sync` initialize config.toml
    //    normally and leave existing ~/.b3/models.md untouched.
    let uh = tmp.path.join("user-home");
    let legacy_md = uh.join(".b3/models.md");
    let new_cfg = uh.join(".b3/config.toml");
    let legacy_body = "| `main` | `custom-legacy` |\n";
    write_lf(&legacy_md, legacy_body);

    // 1a. `b3 install global install --host all`
    let (cg, out_g, err_g) = run_b3_env(
        &[
            "install",
            "global",
            "install",
            "--host",
            "all",
            "--b3-home",
            root_str,
            "--user-home",
            uh.to_str().unwrap(),
        ],
        None,
        &[],
        &["B3_SKIP_CONFIG_INIT", "B3_CONFIG_PERSONAL"],
    );
    assert_eq!(cg, 0, "{out_g}\n{err_g}");
    assert!(
        out_g.contains("created from example"),
        "install global must initialize config.toml: {out_g}"
    );
    assert!(new_cfg.is_file(), "must create config.toml");
    assert_eq!(fs::read_to_string(&legacy_md).unwrap(), legacy_body);

    // 1b. `b3 install product` + check .gitignore ignores `.b3/config.toml` and `.b3/ship/`
    //     while leaving `.b3/policy.toml` and `.b3/home` trackable (`!check-ignore`)
    let alt_cfg = tmp.path.join("alt-home/.b3/config.toml");
    let alt_md = tmp.path.join("alt-home/.b3/models.md");
    write_lf(&alt_md, legacy_body);
    let prod = tmp.path.join("prod");
    clone_seeded_git_repo(&prod);
    let (cp, out_p, err_p) = run_b3_env(
        &[
            "install",
            "product",
            "--product-root",
            prod.to_str().unwrap(),
            "--b3-home",
            root_str,
            "--host",
            "cursor",
        ],
        None,
        &[("B3_CONFIG_PERSONAL", alt_cfg.to_str().unwrap())],
        &["B3_SKIP_CONFIG_INIT"],
    );
    assert_eq!(cp, 0, "{out_p}\n{err_p}");
    assert!(
        alt_cfg.is_file(),
        "install product must initialize B3_CONFIG_PERSONAL"
    );
    assert_eq!(fs::read_to_string(&alt_md).unwrap(), legacy_body);

    for ignored_path in [".b3/config.toml", ".b3/ship/x"] {
        let st = Command::new("git")
            .arg("-C")
            .arg(&prod)
            .args(["check-ignore", "-q", ignored_path])
            .status()
            .expect("git check-ignore");
        assert!(st.success(), "{ignored_path} must be gitignored");
    }
    for trackable_path in [".b3/policy.toml", ".b3/home"] {
        let st = Command::new("git")
            .arg("-C")
            .arg(&prod)
            .args(["check-ignore", "-q", trackable_path])
            .status()
            .expect("git check-ignore");
        assert!(
            !st.success(),
            "{trackable_path} must remain trackable (not gitignored)"
        );
    }

    // 1c. `b3 sync`
    let sync_cfg = tmp.path.join("sync-home/.b3/config.toml");
    let sync_md = tmp.path.join("sync-home/.b3/models.md");
    write_lf(&sync_md, legacy_body);
    let sync_fx = tmp.path.join("sync-fx");
    copy_b3_snapshot(&sync_fx, true);
    let (cs, out_s, err_s) = run_b3_env(
        &[
            "sync",
            "--repo-root",
            sync_fx.to_str().unwrap(),
            "--host",
            "antigravity",
        ],
        None,
        &[("B3_CONFIG_PERSONAL", sync_cfg.to_str().unwrap())],
        &["B3_SKIP_CONFIG_INIT"],
    );
    assert_eq!(cs, 0, "{out_s}\n{err_s}");
    assert!(sync_cfg.is_file(), "b3 sync must create config.toml");
    assert_eq!(fs::read_to_string(&sync_md).unwrap(), legacy_body);
}
