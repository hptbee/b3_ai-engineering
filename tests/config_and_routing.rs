//! Cross-platform integration and security tests for unified TOML configuration,
//! 5-layer precedence, adaptive model routing, bounded escalation, and non-destructive migration.

mod common;

use b3::json::{parse_json, JsonValue};
use common::{clone_seeded_git_repo, create_dir_link, write_lf, TempDirGuard};
use std::fs;
use std::path::Path;

const ALL_CONFIG_ENVS: &[&str] = &[
    "B3_CONFIG_PERSONAL",
    "B3_MODELS_PERSONAL",
    "B3_MODEL_ROUTING",
    "B3_MAX_CONCURRENCY",
    "B3_EXECUTION_MODE",
    "B3_CLARIFICATION_GATE",
    "B3_UNDERSTANDING_THRESHOLD",
];

fn run_cfg(args: &[&str], cwd: Option<&Path>, set_env: &[(&str, &str)]) -> (i32, String, String) {
    common::run_b3_env(args, cwd, set_env, ALL_CONFIG_ENVS)
}

fn parse_json_output(out: &str) -> JsonValue {
    parse_json(out).unwrap_or_else(|e| panic!("invalid JSON ({e}):\n{out}"))
}

#[test]
fn config_loading_defaults_partial_fallback_validate_and_forbidden_policy() {
    let tmp = TempDirGuard::new("cfg-load-val");
    let home = tmp.path.join("home");
    let repo = tmp.path.join("repo");
    fs::create_dir_all(&home).unwrap();
    clone_seeded_git_repo(&repo);

    let h_str = home.to_str().unwrap();
    let r_str = repo.to_str().unwrap();

    // 1. Missing files -> built-in defaults + valid
    let (c_val0, out_val0, err_val0) = run_cfg(
        &[
            "config",
            "validate",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
        ],
        None,
        &[],
    );
    assert_eq!(c_val0, 0, "{out_val0}\n{err_val0}");
    assert!(out_val0.contains("CONFIG_VALID:"), "{out_val0}");

    let (c_show0, out_show0, err_show0) = run_cfg(
        &[
            "config",
            "show",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
            "--sources",
            "--json",
        ],
        None,
        &[],
    );
    assert_eq!(c_show0, 0, "{out_show0}\n{err_show0}");
    let j0 = parse_json_output(&out_show0);
    assert_eq!(j0.get("files_read").and_then(|v| v.as_i64()), Some(0));
    assert_eq!(
        j0.get("values")
            .and_then(|v| v.get("models.routing"))
            .and_then(JsonValue::as_str),
        Some("adaptive")
    );
    assert_eq!(
        j0.get("sources")
            .and_then(|v| v.get("models.routing"))
            .and_then(JsonValue::as_str),
        Some("default")
    );
    assert_eq!(
        j0.get("values")
            .and_then(|v| v.get("review.max_iterations"))
            .and_then(|v| v.as_i64()),
        Some(5)
    );

    // 2. Partial/invalid TOML values warn and fall back per-field across project -> personal -> default
    write_lf(
        &home.join(".b3/config.toml"),
        r#"
[models]
routing = "fixed"
max_escalations = 1

[planning]
understanding_threshold = 91
clarification_gate = true
"#,
    );
    write_lf(
        &repo.join(".b3/config.toml"),
        r#"
[models]
routing = "bogus-mode"
auto_escalate = false

[planning]
understanding_threshold = "not-a-number"

[review.sizing]
xs_max_loc = 500
s_max_loc = 200
"#,
    );

    let (c_show1, out_show1, err_show1) = run_cfg(
        &[
            "config",
            "show",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
            "--sources",
            "--json",
        ],
        None,
        &[],
    );
    assert_eq!(c_show1, 0, "{out_show1}\n{err_show1}");
    let j1 = parse_json_output(&out_show1);
    assert_eq!(j1.get("files_read").and_then(|v| v.as_i64()), Some(2));
    let warnings = j1
        .get("warnings")
        .and_then(JsonValue::as_array)
        .expect("warnings array");
    assert!(warnings.len() >= 3, "expected warnings: {out_show1}");

    let vals1 = j1.get("values").unwrap();
    let srcs1 = j1.get("sources").unwrap();
    // Invalid project routing falls back to personal ("fixed")
    assert_eq!(
        vals1.get("models.routing").and_then(JsonValue::as_str),
        Some("fixed")
    );
    assert_eq!(
        srcs1.get("models.routing").and_then(JsonValue::as_str),
        Some("personal")
    );
    // Valid project auto_escalate overrides default
    assert_eq!(
        vals1
            .get("models.auto_escalate")
            .and_then(JsonValue::as_bool),
        Some(false)
    );
    assert_eq!(
        srcs1
            .get("models.auto_escalate")
            .and_then(JsonValue::as_str),
        Some("project")
    );
    // Invalid project threshold falls back to personal (91)
    assert_eq!(
        vals1
            .get("planning.understanding_threshold")
            .and_then(|v| v.as_i64()),
        Some(91)
    );
    assert_eq!(
        srcs1
            .get("planning.understanding_threshold")
            .and_then(JsonValue::as_str),
        Some("personal")
    );
    // Invalid project review.sizing reverts cleanly to default (xs_max_loc = 100)
    assert_eq!(
        vals1
            .get("review.sizing.xs_max_loc")
            .and_then(|v| v.as_i64()),
        Some(100)
    );
    assert_eq!(
        srcs1
            .get("review.sizing.xs_max_loc")
            .and_then(JsonValue::as_str),
        Some("default")
    );

    // 3. `b3 config validate` rejects invalid values, duplicate keys, duplicate tables, unknown keys, dual-format policy
    for (label, proj_toml) in [
        ("invalid-val", "[models]\nrouting = \"bogus\"\n"),
        (
            "dup-key",
            "[models]\nrouting = \"adaptive\"\nrouting = \"fixed\"\n",
        ),
        (
            "dup-table",
            "[models]\nrouting = \"adaptive\"\n[models]\nfallback = \"next\"\n",
        ),
        ("unknown-key", "[models]\nnonexistent_flag = true\n"),
        ("unknown-section", "[unknown_section]\nfoo = 1\n"),
    ] {
        fs::write(
            home.join(".b3/config.toml"),
            "[models]\nrouting = \"adaptive\"\n",
        )
        .unwrap();
        write_lf(&repo.join(".b3/config.toml"), proj_toml);
        let (cv, out_v, err_v) = run_cfg(
            &[
                "config",
                "validate",
                "--repo-root",
                r_str,
                "--user-home",
                h_str,
            ],
            None,
            &[],
        );
        assert_eq!(cv, 1, "{label} must fail validate: {out_v}\n{err_v}");
        assert!(
            out_v.contains("CONFIG_INVALID:") || err_v.contains("CONFIG_INVALID:"),
            "{label}: {out_v}\n{err_v}"
        );
    }

    // Valid config passes validate, then dual-format policy fails validate
    write_lf(
        &repo.join(".b3/config.toml"),
        "[models]\nrouting = \"adaptive\"\n",
    );
    write_lf(
        &repo.join(".b3/policy.toml"),
        "auto_merge = \"disabled\"\nauto_merge_max_risk = \"LOW\"\n",
    );
    assert_eq!(
        run_cfg(
            &[
                "config",
                "validate",
                "--repo-root",
                r_str,
                "--user-home",
                h_str,
            ],
            None,
            &[],
        )
        .0,
        0
    );
    write_lf(
        &repo.join(".b3/research-policy.json"),
        r#"{"auto_merge":"disabled"}"#,
    );
    let (c_dual, out_dual, err_dual) = run_cfg(
        &[
            "config",
            "validate",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
            "--json",
        ],
        None,
        &[],
    );
    assert_eq!(c_dual, 1, "{out_dual}\n{err_dual}");
    let j_dual = parse_json_output(&out_dual);
    assert_eq!(
        j_dual.get("valid").and_then(JsonValue::as_bool),
        Some(false)
    );

    // 4. `b3 config set --scope policy` and governance keys refused fail-closed with CONFIG_FORBIDDEN
    for args in [
        vec![
            "config",
            "set",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
            "--scope",
            "policy",
            "models.routing",
            "fixed",
        ],
        vec![
            "config",
            "set",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
            "auto_merge",
            "authorized",
        ],
        vec![
            "config",
            "set",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
            "policy.auto_merge_max_risk",
            "CRITICAL",
        ],
    ] {
        let (cf_c, cf_out, cf_err) = run_cfg(&args, None, &[]);
        assert_eq!(cf_c, 1, "{args:?}: {cf_out}\n{cf_err}");
        let msg = format!("{cf_out}\n{cf_err}");
        assert!(msg.contains("CONFIG_FORBIDDEN"), "{args:?}: {msg}");
    }
}

#[test]
fn config_five_layer_precedence_and_sources_json() {
    let tmp = TempDirGuard::new("cfg-5layer");
    let home = tmp.path.join("home");
    let repo = tmp.path.join("repo");
    fs::create_dir_all(&home).unwrap();
    clone_seeded_git_repo(&repo);
    let h_str = home.to_str().unwrap();
    let r_str = repo.to_str().unwrap();

    // Personal sets 4 keys
    write_lf(
        &home.join(".b3/config.toml"),
        r#"
[models]
routing = "fixed"
max_escalations = 1

[planning]
understanding_threshold = 80
clarification_gate = false
"#,
    );
    // Project overrides 2 of them
    write_lf(
        &repo.join(".b3/config.toml"),
        r#"
[models]
routing = "native"

[planning]
understanding_threshold = 90

[parallel]
max_concurrency = 4
execution_mode = "sequential"
"#,
    );

    // Env overrides B3_MODEL_ROUTING, B3_MAX_CONCURRENCY, B3_EXECUTION_MODE
    // Invocation --override overrides models.routing and review.max_iterations
    let (c, out, err) = run_cfg(
        &[
            "config",
            "show",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
            "--sources",
            "--json",
            "--override",
            "models.routing=adaptive",
            "--override",
            "review.max_iterations=9",
        ],
        None,
        &[
            ("B3_MODEL_ROUTING", "fixed"),
            ("B3_MAX_CONCURRENCY", "7"),
            ("B3_EXECUTION_MODE", "isolated"),
        ],
    );
    assert_eq!(c, 0, "{out}\n{err}");
    let j = parse_json_output(&out);
    let vals = j.get("values").unwrap();
    let srcs = j.get("sources").unwrap();

    // Layer 5: default
    assert_eq!(
        vals.get("review.max_loc_per_unit").and_then(|v| v.as_i64()),
        Some(5000)
    );
    assert_eq!(
        srcs.get("review.max_loc_per_unit")
            .and_then(JsonValue::as_str),
        Some("default")
    );

    // Layer 4: personal
    assert_eq!(
        vals.get("models.max_escalations").and_then(|v| v.as_i64()),
        Some(1)
    );
    assert_eq!(
        srcs.get("models.max_escalations")
            .and_then(JsonValue::as_str),
        Some("personal")
    );
    assert_eq!(
        vals.get("planning.clarification_gate")
            .and_then(JsonValue::as_bool),
        Some(false)
    );
    assert_eq!(
        srcs.get("planning.clarification_gate")
            .and_then(JsonValue::as_str),
        Some("personal")
    );

    // Layer 3: project
    assert_eq!(
        vals.get("planning.understanding_threshold")
            .and_then(|v| v.as_i64()),
        Some(90)
    );
    assert_eq!(
        srcs.get("planning.understanding_threshold")
            .and_then(JsonValue::as_str),
        Some("project")
    );

    // Layer 2: env
    assert_eq!(
        vals.get("parallel.max_concurrency")
            .and_then(|v| v.as_i64()),
        Some(7)
    );
    assert_eq!(
        srcs.get("parallel.max_concurrency")
            .and_then(JsonValue::as_str),
        Some("env")
    );
    assert_eq!(
        vals.get("parallel.execution_mode")
            .and_then(JsonValue::as_str),
        Some("isolated")
    );
    assert_eq!(
        srcs.get("parallel.execution_mode")
            .and_then(JsonValue::as_str),
        Some("env")
    );

    // Layer 1: invocation --override
    assert_eq!(
        vals.get("models.routing").and_then(JsonValue::as_str),
        Some("adaptive")
    );
    assert_eq!(
        srcs.get("models.routing").and_then(JsonValue::as_str),
        Some("invocation")
    );
    assert_eq!(
        vals.get("review.max_iterations").and_then(|v| v.as_i64()),
        Some(9)
    );
    assert_eq!(
        srcs.get("review.max_iterations")
            .and_then(JsonValue::as_str),
        Some("invocation")
    );
}

#[test]
fn config_set_comment_preserving_atomic_lf_and_security_rejections() {
    let tmp = TempDirGuard::new("cfg-sec");
    let home = tmp.path.join("home");
    let repo = tmp.path.join("repo");
    fs::create_dir_all(home.join(".b3")).unwrap();
    clone_seeded_git_repo(&repo);
    let h_str = home.to_str().unwrap();
    let r_str = repo.to_str().unwrap();

    // 1. Comment-preserving `b3 config set` + atomic LF write
    let pers_cfg = home.join(".b3/config.toml");
    // Seed with CRLF, comments, and blank line before next table
    fs::write(
        &pers_cfg,
        "# Top personal comment\r\n[models]\r\n# keep routing note\r\nrouting = \"adaptive\" # inline note\r\nmax_escalations = 2\r\n\r\n[planning]\r\nclarification_gate = true\r\n",
    )
    .unwrap();

    let (c_set, out_set, err_set) = run_cfg(
        &[
            "config",
            "set",
            "--user-home",
            h_str,
            "--scope",
            "personal",
            "models.routing",
            "fixed",
        ],
        None,
        &[],
    );
    assert_eq!(c_set, 0, "{out_set}\n{err_set}");
    // Insert a missing key into [models] and confirm the blank separator line before [planning] survives
    let (c_set2, out_set2, err_set2) = run_cfg(
        &[
            "config",
            "set",
            "--user-home",
            h_str,
            "--scope",
            "personal",
            "models.auto_escalate",
            "false",
        ],
        None,
        &[],
    );
    assert_eq!(c_set2, 0, "{out_set2}\n{err_set2}");
    let raw_bytes = fs::read(&pers_cfg).unwrap();
    assert!(!raw_bytes.contains(&b'\r'), "config set must write LF only");
    let raw_txt = String::from_utf8(raw_bytes).unwrap();
    assert!(raw_txt.contains("# Top personal comment"), "{raw_txt}");
    assert!(raw_txt.contains("# keep routing note"), "{raw_txt}");
    assert!(
        raw_txt.contains("routing = \"fixed\" # inline note"),
        "{raw_txt}"
    );
    assert!(raw_txt.contains("max_escalations = 2"), "{raw_txt}");
    assert!(
        raw_txt.contains("auto_escalate = false\n\n[planning]"),
        "blank separator line before [planning] must be preserved:\n{raw_txt}"
    );

    // 2. UNC / NT / network paths and control chars in B3_CONFIG_PERSONAL rejected
    for bad_env in [
        "\\\\server\\share\\config.toml",
        "//server/share/config.toml",
        "\\/server\\share\\config.toml",
        "/\\server\\share\\config.toml",
        "\\??\\UNC\\server\\share\\config.toml",
        "C:\\temp\\bad\nconfig.toml",
        "C:\\temp\\bad\x07config.toml",
    ] {
        let (c_bad_set, out_bs, err_bs) = run_cfg(
            &[
                "config",
                "set",
                "--user-home",
                h_str,
                "--scope",
                "personal",
                "models.routing",
                "adaptive",
            ],
            None,
            &[("B3_CONFIG_PERSONAL", bad_env)],
        );
        assert_eq!(
            c_bad_set, 1,
            "bad B3_CONFIG_PERSONAL must fail set: {bad_env:?}"
        );
        let msg_bs = format!("{out_bs}\n{err_bs}");
        assert!(msg_bs.contains("CONFIG_FAIL"), "{msg_bs}");

        let (c_bad_val, out_bv, err_bv) = run_cfg(
            &["config", "validate", "--user-home", h_str],
            None,
            &[("B3_CONFIG_PERSONAL", bad_env)],
        );
        assert_eq!(
            c_bad_val, 1,
            "bad B3_CONFIG_PERSONAL must fail validate: {bad_env:?}"
        );
        let msg_bv = format!("{out_bv}\n{err_bv}");
        assert!(msg_bv.contains("CONFIG_INVALID"), "{msg_bv}");

        let (c_bad_show, out_sh, err_sh) = run_cfg(
            &["config", "show", "--user-home", h_str, "--json"],
            None,
            &[("B3_CONFIG_PERSONAL", bad_env)],
        );
        assert_eq!(c_bad_show, 0, "{out_sh}\n{err_sh}");
        let j_sh = parse_json_output(&out_sh);
        let warns = j_sh.get("warnings").and_then(JsonValue::as_array).unwrap();
        assert!(
            warns.iter().any(|w| w
                .as_str()
                .is_some_and(|s| s.contains("ignoring unsafe B3_CONFIG_PERSONAL"))),
            "expected UNC/control-char warning in {out_sh}"
        );
    }

    // Control char in CLI `set` value rejected
    let (c_ctrl, out_ctrl, err_ctrl) = run_cfg(
        &[
            "config",
            "set",
            "--user-home",
            h_str,
            "--scope",
            "personal",
            "models.tiers.economy",
            "bad\x07model",
        ],
        None,
        &[],
    );
    assert_eq!(c_ctrl, 1, "{out_ctrl}\n{err_ctrl}");

    // 3. Symlink / junction config target rejected across set / init / validate / show (including relative `..` path)
    let decoy = tmp.path.join("decoy-b3");
    write_lf(
        &decoy.join("config.toml"),
        "[models]\nrouting = \"native\"\nmax_escalations = 0\n",
    );
    let linked_repo = tmp.path.join("linked-repo");
    clone_seeded_git_repo(&linked_repo);
    create_dir_link(&linked_repo.join(".b3"), &decoy);
    let lr_str = linked_repo.to_str().unwrap();

    // SEC-2: both leading `..` and interior `sym/../target` traversal through symlink/junction must be rejected
    let sibling_cwd = tmp.path.join("sibling-cwd");
    fs::create_dir_all(&sibling_cwd).unwrap();
    for rel_sym in [
        "../linked-repo/.b3/config.toml",
        "../linked-repo/.b3/../decoy-b3/config.toml",
    ] {
        let (c_rel_j, out_rj, err_rj) = run_cfg(
            &["config", "validate", "--user-home", h_str],
            Some(&sibling_cwd),
            &[("B3_CONFIG_PERSONAL", rel_sym)],
        );
        assert_eq!(
            c_rel_j, 1,
            "traversal through junction ({rel_sym}) must fail validate: {out_rj}\n{err_rj}"
        );
        assert!(
            format!("{out_rj}\n{err_rj}").contains("symlink")
                || format!("{out_rj}\n{err_rj}").contains("reparse"),
            "{out_rj}\n{err_rj}"
        );
    }

    for sub in [
        vec![
            "config",
            "set",
            "--repo-root",
            lr_str,
            "--user-home",
            h_str,
            "--scope",
            "project",
            "models.routing",
            "fixed",
        ],
        vec![
            "config",
            "init",
            "--repo-root",
            lr_str,
            "--user-home",
            h_str,
            "--scope",
            "project",
        ],
        vec![
            "config",
            "validate",
            "--repo-root",
            lr_str,
            "--user-home",
            h_str,
        ],
    ] {
        let (cj, outj, errj) = run_cfg(&sub, None, &[]);
        assert_eq!(cj, 1, "junctioned .b3 must fail {sub:?}: {outj}\n{errj}");
        let msgj = format!("{outj}\n{errj}");
        assert!(
            msgj.contains("symlink") || msgj.contains("reparse"),
            "{sub:?}: {msgj}"
        );
    }

    // show ignores junctioned project config and warns cleanly
    let (c_sh_j, out_sh_j, _) = run_cfg(
        &[
            "config",
            "show",
            "--repo-root",
            lr_str,
            "--user-home",
            h_str,
            "--json",
        ],
        None,
        &[],
    );
    assert_eq!(c_sh_j, 0);
    let j_junc = parse_json_output(&out_sh_j);
    assert_eq!(
        j_junc
            .get("values")
            .and_then(|v| v.get("models.max_escalations"))
            .and_then(|v| v.as_i64()),
        Some(2),
        "decoy junctioned config must NOT be applied"
    );
    let j_warns = j_junc
        .get("warnings")
        .and_then(JsonValue::as_array)
        .unwrap();
    assert!(
        j_warns
            .iter()
            .any(|w| w.as_str().is_some_and(|s| s.contains("symlink or reparse"))),
        "expected reparse warning: {out_sh_j}"
    );
    // Keep r_str referenced cleanly
    assert!(Path::new(r_str).is_dir());
}

#[test]
fn adaptive_routing_tiers_aliases_hosts_risk_floor_fallback_and_honesty() {
    let tmp = TempDirGuard::new("cfg-route");
    let home = tmp.path.join("home");
    let repo = tmp.path.join("repo");
    fs::create_dir_all(&home).unwrap();
    clone_seeded_git_repo(&repo);
    let h_str = home.to_str().unwrap();
    let r_str = repo.to_str().unwrap();

    write_lf(
        &repo.join(".b3/config.toml"),
        r#"
[models]
routing = "adaptive"
auto_escalate = true
max_escalations = 2
fallback = "next"

[models.tiers]
economy = "m-l1"
balanced = "m-l2"
advanced = "m-l3"

[models.roles]
main = ["balanced", "advanced"]
implementation = ["economy", "balanced", "advanced"]
reviewer = ["economy", "balanced", "advanced"]
security_reviewer = ["advanced"]
research = ["m-direct"]
fixer = ["model:economy"]

[models.hosts.codex]
balanced = "codex-l2"
advanced = "codex-l3"

[models.hosts.claude_code.roles]
reviewer = ["economy", "codex-alt-l3"]
"#,
    );

    let route = |extra: &[&str]| -> JsonValue {
        let mut args = vec![
            "config",
            "get",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
            "--json",
        ];
        args.extend_from_slice(extra);
        let (c, out, err) = run_cfg(&args, None, &[]);
        assert_eq!(c, 0, "route {extra:?} failed: {out}\n{err}");
        parse_json_output(&out)
    };

    // 1. 3-entry role (implementation / b3-reviewer): low->economy, medium->balanced, high->advanced
    let r3_low = route(&[
        "--route",
        "implementation",
        "--complexity",
        "low",
        "--risk",
        "LOW",
        "--host",
        "antigravity",
    ]);
    assert_eq!(
        r3_low.get("selected_tier").and_then(JsonValue::as_str),
        Some("economy")
    );
    assert_eq!(
        r3_low.get("requested_model").and_then(JsonValue::as_str),
        Some("m-l1")
    );
    assert_eq!(
        r3_low.get("actual_model").and_then(JsonValue::as_str),
        Some("UNKNOWN")
    );

    let r3_med = route(&[
        "--route",
        "b3-reviewer",
        "--complexity",
        "medium",
        "--risk",
        "LOW",
        "--host",
        "antigravity",
    ]);
    assert_eq!(
        r3_med.get("role").and_then(JsonValue::as_str),
        Some("reviewer")
    );
    assert_eq!(
        r3_med.get("selected_tier").and_then(JsonValue::as_str),
        Some("balanced")
    );
    assert_eq!(
        r3_med.get("requested_model").and_then(JsonValue::as_str),
        Some("m-l2")
    );

    let r3_high = route(&[
        "--route",
        "b3-reviewer",
        "--complexity",
        "high",
        "--risk",
        "LOW",
        "--host",
        "antigravity",
    ]);
    assert_eq!(
        r3_high.get("selected_tier").and_then(JsonValue::as_str),
        Some("advanced")
    );
    assert_eq!(
        r3_high.get("requested_model").and_then(JsonValue::as_str),
        Some("m-l3")
    );

    // 2. 2-entry role (main): low & medium -> entry 0 (balanced), high -> entry 1 (advanced)
    let r2_low = route(&[
        "--route",
        "main",
        "--complexity",
        "low",
        "--risk",
        "LOW",
        "--host",
        "codex",
    ]);
    assert_eq!(
        r2_low.get("requested_model").and_then(JsonValue::as_str),
        Some("codex-l2")
    );
    let r2_med = route(&[
        "--route",
        "main",
        "--complexity",
        "medium",
        "--risk",
        "LOW",
        "--host",
        "codex",
    ]);
    assert_eq!(
        r2_med.get("requested_model").and_then(JsonValue::as_str),
        Some("codex-l2")
    );
    let r2_high = route(&[
        "--route",
        "main",
        "--complexity",
        "high",
        "--risk",
        "LOW",
        "--host",
        "codex",
    ]);
    assert_eq!(
        r2_high.get("requested_model").and_then(JsonValue::as_str),
        Some("codex-l3")
    );

    // 3. 1-entry role (b3-security-reviewer) + direct model ID + `model:` prefix escaping
    let r1_sec = route(&[
        "--route",
        "b3-security-reviewer",
        "--complexity",
        "low",
        "--risk",
        "LOW",
        "--host",
        "codex",
    ]);
    assert_eq!(
        r1_sec.get("role").and_then(JsonValue::as_str),
        Some("security_reviewer")
    );
    assert_eq!(
        r1_sec.get("requested_model").and_then(JsonValue::as_str),
        Some("codex-l3")
    );

    let r_direct = route(&[
        "--route",
        "research",
        "--complexity",
        "high",
        "--risk",
        "LOW",
        "--host",
        "codex",
    ]);
    assert_eq!(
        r_direct.get("selected_tier").and_then(JsonValue::as_str),
        Some("direct")
    );
    assert_eq!(
        r_direct.get("requested_model").and_then(JsonValue::as_str),
        Some("m-direct")
    );

    let r_escaped = route(&[
        "--route",
        "b3-fixer",
        "--complexity",
        "low",
        "--risk",
        "LOW",
        "--host",
        "codex",
    ]);
    assert_eq!(
        r_escaped.get("selected_tier").and_then(JsonValue::as_str),
        Some("direct")
    );
    assert_eq!(
        r_escaped.get("requested_model").and_then(JsonValue::as_str),
        Some("economy")
    );

    // 4. Host overrides & capability awareness across cursor, codex, claude, antigravity, generic
    // Verify BOTH canonical `claude_code` AND alias `claude` / `claude-code` resolve `[models.hosts.claude_code]`!
    for host_alias in ["claude_code", "claude", "claude-code"] {
        let r_claude = route(&[
            "--route",
            "reviewer",
            "--complexity",
            "high",
            "--risk",
            "LOW",
            "--host",
            host_alias,
        ]);
        assert_eq!(
            r_claude.get("requested_model").and_then(JsonValue::as_str),
            Some("codex-alt-l3"),
            "host alias {host_alias} must resolve [models.hosts.claude_code]"
        );
    }

    // Incompatible CLI routing flag on `config set` rejected cleanly
    let (c_bad_flag, out_bf, err_bf) = run_cfg(
        &[
            "config",
            "set",
            "--user-home",
            h_str,
            "--scope",
            "personal",
            "--route",
            "reviewer",
            "models.routing",
            "fixed",
        ],
        None,
        &[],
    );
    assert_eq!(c_bad_flag, 1, "{out_bf}\n{err_bf}");
    assert!(
        format!("{out_bf}\n{err_bf}").contains("CONFIG_FAIL"),
        "{out_bf}\n{err_bf}"
    );

    for switchable_host in ["cursor", "codex", "claude", "antigravity"] {
        let rh = route(&[
            "--route",
            "b3-reviewer",
            "--complexity",
            "medium",
            "--risk",
            "LOW",
            "--host",
            switchable_host,
        ]);
        assert_eq!(
            rh.get("actual_model").and_then(JsonValue::as_str),
            Some("UNKNOWN"),
            "host {switchable_host} without --confirmed-model must report UNKNOWN"
        );
    }

    let r_generic = route(&[
        "--route",
        "b3-reviewer",
        "--complexity",
        "medium",
        "--risk",
        "LOW",
        "--host",
        "generic",
    ]);
    assert_eq!(
        r_generic.get("actual_model").and_then(JsonValue::as_str),
        Some("INHERITED")
    );
    assert!(
        r_generic
            .get("fallback_reason")
            .and_then(JsonValue::as_str)
            .is_some_and(|s| s.contains("does not support switching role")),
        "{r_generic:?}"
    );

    // 5. HIGH / CRITICAL risk floor: b3-reviewer & b3-security-reviewer never downgrade onto economy
    for risk in ["HIGH", "CRITICAL"] {
        let rf_rev = route(&[
            "--route",
            "b3-reviewer",
            "--complexity",
            "low",
            "--risk",
            risk,
            "--host",
            "codex",
        ]);
        assert_eq!(
            rf_rev.get("selected_tier").and_then(JsonValue::as_str),
            Some("advanced"),
            "risk={risk} must floor b3-reviewer onto advanced"
        );
        assert_eq!(
            rf_rev.get("requested_model").and_then(JsonValue::as_str),
            Some("codex-l3")
        );

        let rf_sec = route(&[
            "--route",
            "b3-security-reviewer",
            "--complexity",
            "low",
            "--risk",
            risk,
            "--host",
            "codex",
        ]);
        assert_eq!(
            rf_sec.get("selected_tier").and_then(JsonValue::as_str),
            Some("advanced")
        );
    }

    // 6. Fallback behavior (`next` vs `native`) and `actual_model` identity honesty
    let fb_next = route(&[
        "--route",
        "implementation",
        "--complexity",
        "low",
        "--risk",
        "LOW",
        "--host",
        "codex",
        "--available-models",
        "codex-l2,codex-l3",
    ]);
    assert_eq!(
        fb_next.get("requested_model").and_then(JsonValue::as_str),
        Some("codex-l2")
    );
    assert!(
        fb_next
            .get("fallback_reason")
            .and_then(JsonValue::as_str)
            .is_some_and(|s| s.contains("used next entry 2")),
        "{fb_next:?}"
    );

    let fb_next_none = route(&[
        "--route",
        "implementation",
        "--complexity",
        "low",
        "--risk",
        "LOW",
        "--host",
        "codex",
        "--available-models",
        "unrelated-model",
    ]);
    assert_eq!(
        fb_next_none
            .get("requested_model")
            .and_then(JsonValue::as_str),
        Some("auto")
    );
    assert_eq!(
        fb_next_none.get("actual_model").and_then(JsonValue::as_str),
        Some("INHERITED")
    );

    let fb_native = route(&[
        "--route",
        "implementation",
        "--complexity",
        "medium",
        "--risk",
        "LOW",
        "--host",
        "codex",
        "--override",
        "models.fallback=native",
        "--available-models",
        "codex-l3",
    ]);
    assert_eq!(
        fb_native.get("selected_tier").and_then(JsonValue::as_str),
        Some("inherited")
    );
    assert_eq!(
        fb_native.get("requested_model").and_then(JsonValue::as_str),
        Some("auto")
    );
    assert_eq!(
        fb_native.get("actual_model").and_then(JsonValue::as_str),
        Some("INHERITED")
    );
    assert!(
        fb_native
            .get("fallback_reason")
            .and_then(JsonValue::as_str)
            .is_some_and(|s| s.contains("fallback=native")),
        "{fb_native:?}"
    );

    // Confirmed model honesty & routing=native honesty
    let confirmed = route(&[
        "--route",
        "implementation",
        "--complexity",
        "medium",
        "--risk",
        "LOW",
        "--host",
        "codex",
        "--confirmed-model",
        "codex-l2-confirmed",
    ]);
    assert_eq!(
        confirmed.get("actual_model").and_then(JsonValue::as_str),
        Some("codex-l2-confirmed")
    );

    let native_mode = route(&[
        "--route",
        "implementation",
        "--complexity",
        "high",
        "--risk",
        "HIGH",
        "--host",
        "codex",
        "--override",
        "models.routing=native",
    ]);
    assert_eq!(
        native_mode.get("actual_model").and_then(JsonValue::as_str),
        Some("INHERITED")
    );
    assert_eq!(
        native_mode
            .get("requested_model")
            .and_then(JsonValue::as_str),
        Some("auto")
    );
}

#[test]
fn bounded_escalation_triggers_and_caps() {
    let tmp = TempDirGuard::new("cfg-esc");
    let home = tmp.path.join("home");
    let repo = tmp.path.join("repo");
    fs::create_dir_all(&home).unwrap();
    clone_seeded_git_repo(&repo);
    let h_str = home.to_str().unwrap();
    let r_str = repo.to_str().unwrap();

    write_lf(
        &repo.join(".b3/config.toml"),
        r#"
[models]
routing = "adaptive"
auto_escalate = true
max_escalations = 2

[models.tiers]
economy = "m-l1"
balanced = "m-l2"
advanced = "m-l3"

[models.roles]
implementation = ["economy", "balanced", "advanced"]
security_reviewer = ["advanced"]
"#,
    );

    let run_route = |extra: &[&str]| -> JsonValue {
        let mut args = vec![
            "config",
            "get",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
            "--route",
            "implementation",
            "--complexity",
            "low",
            "--risk",
            "LOW",
            "--host",
            "codex",
            "--json",
        ];
        args.extend_from_slice(extra);
        let (c, out, err) = run_cfg(&args, None, &[]);
        assert_eq!(c, 0, "{extra:?}: {out}\n{err}");
        parse_json_output(&out)
    };

    // Valid reasoning triggers escalate
    for trig in [
        "complexity_increase",
        "repeated_reasoning_failure",
        "design_contradiction",
        "systemic_review_finding",
    ] {
        let j = run_route(&["--trigger", trig]);
        assert_eq!(
            j.get("escalation_count").and_then(|v| v.as_i64()),
            Some(1),
            "trigger {trig} must escalate"
        );
        assert_eq!(
            j.get("requested_model").and_then(JsonValue::as_str),
            Some("m-l2"),
            "trigger {trig} must step economy -> balanced"
        );
    }

    // Non-reasoning / infra triggers NEVER trigger escalation
    for trig in [
        "ordinary_test_failure",
        "missing_dependency",
        "environment_setup",
        "flaky_infra",
        "network_failure",
        "baseline_failure",
    ] {
        let j = run_route(&["--trigger", trig]);
        assert_eq!(
            j.get("escalation_count").and_then(|v| v.as_i64()),
            Some(0),
            "trigger {trig} must NOT escalate"
        );
        assert_eq!(
            j.get("requested_model").and_then(JsonValue::as_str),
            Some("m-l1"),
            "trigger {trig} must stay at economy"
        );
    }

    // Max escalations cap (2 by default, 1 via override, 0 when auto_escalate=false)
    let j_cap2 = run_route(&["--escalations", "5"]);
    assert_eq!(
        j_cap2.get("escalation_count").and_then(|v| v.as_i64()),
        Some(2)
    );
    assert_eq!(
        j_cap2.get("requested_model").and_then(JsonValue::as_str),
        Some("m-l3")
    );

    let j_cap1 = run_route(&[
        "--escalations",
        "5",
        "--override",
        "models.max_escalations=1",
    ]);
    assert_eq!(
        j_cap1.get("escalation_count").and_then(|v| v.as_i64()),
        Some(1)
    );
    assert_eq!(
        j_cap1.get("requested_model").and_then(JsonValue::as_str),
        Some("m-l2")
    );

    let j_off = run_route(&[
        "--trigger",
        "design_contradiction",
        "--override",
        "models.auto_escalate=false",
    ]);
    assert_eq!(
        j_off.get("escalation_count").and_then(|v| v.as_i64()),
        Some(0)
    );
    assert_eq!(
        j_off.get("requested_model").and_then(JsonValue::as_str),
        Some("m-l1")
    );

    // Single-entry role never invents an escalation target
    let (c_sec, out_sec, err_sec) = run_cfg(
        &[
            "config",
            "get",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
            "--route",
            "security_reviewer",
            "--complexity",
            "low",
            "--risk",
            "LOW",
            "--host",
            "codex",
            "--trigger",
            "design_contradiction",
            "--json",
        ],
        None,
        &[],
    );
    assert_eq!(c_sec, 0, "{out_sec}\n{err_sec}");
    let j_sec = parse_json_output(&out_sec);
    assert_eq!(
        j_sec.get("escalation_count").and_then(|v| v.as_i64()),
        Some(0)
    );
}

#[test]
fn config_init_and_non_destructive_migration() {
    let tmp = TempDirGuard::new("cfg-migrate");
    let home = tmp.path.join("home");
    let repo = tmp.path.join("repo");
    fs::create_dir_all(&home).unwrap();
    clone_seeded_git_repo(&repo);
    let h_str = home.to_str().unwrap();
    let r_str = repo.to_str().unwrap();

    // 1. `b3 config init` dry-run, create, keep-existing, and --force
    let init_home = tmp.path.join("init-home");
    fs::create_dir_all(&init_home).unwrap();
    let ih_str = init_home.to_str().unwrap();
    let ih_cfg = init_home.join(".b3/config.toml");

    let (c_dr, out_dr, _) = run_cfg(
        &[
            "config",
            "init",
            "--scope",
            "personal",
            "--user-home",
            ih_str,
            "--dry-run",
        ],
        None,
        &[],
    );
    assert_eq!(c_dr, 0);
    assert!(out_dr.contains("dry-run:"), "{out_dr}");
    assert!(!ih_cfg.exists());

    let (c_in, out_in, _) = run_cfg(
        &[
            "config",
            "init",
            "--scope",
            "personal",
            "--user-home",
            ih_str,
        ],
        None,
        &[],
    );
    assert_eq!(c_in, 0);
    assert!(out_in.contains("initialized:"), "{out_in}");
    assert!(ih_cfg.is_file());
    assert!(!fs::read(&ih_cfg).unwrap().contains(&b'\r'));

    write_lf(&ih_cfg, "# custom kept\n[models]\nrouting = \"fixed\"\n");
    let (c_keep, out_keep, _) = run_cfg(
        &[
            "config",
            "init",
            "--scope",
            "personal",
            "--user-home",
            ih_str,
        ],
        None,
        &[],
    );
    assert_eq!(c_keep, 0);
    assert!(out_keep.contains("kept:"), "{out_keep}");
    assert!(fs::read_to_string(&ih_cfg)
        .unwrap()
        .contains("# custom kept"));

    let (c_force, _, _) = run_cfg(
        &[
            "config",
            "init",
            "--scope",
            "personal",
            "--user-home",
            ih_str,
            "--force",
        ],
        None,
        &[],
    );
    assert_eq!(c_force, 0);
    assert!(fs::read_to_string(&ih_cfg).unwrap().contains("[planning]"));

    // 2. Non-destructive `b3 config migrate --scope personal`
    let leg_models = home.join(".b3/models.md");
    let leg_models_body = r#"# Model Preferences

| Role | Preferred Model |
| --- | --- |
| `main` | `claude-sonnet-4` |
| `b3-reviewer` | `gpt-5.4` |
| `planning` | `auto` |

```yaml
planning:
  clarification_gate: false
  understanding_threshold: 88
```
"#;
    write_lf(&leg_models, leg_models_body);

    let (c_mp, out_mp, err_mp) = run_cfg(
        &[
            "config",
            "migrate",
            "--scope",
            "personal",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
        ],
        None,
        &[],
    );
    assert_eq!(c_mp, 0, "{out_mp}\n{err_mp}");
    assert!(out_mp.contains("migrated:"), "{out_mp}");
    assert!(leg_models.is_file(), "legacy models.md must be preserved");
    assert_eq!(fs::read_to_string(&leg_models).unwrap(), leg_models_body);

    let dest_pers = home.join(".b3/config.toml");
    assert!(dest_pers.is_file());
    assert!(!fs::read(&dest_pers).unwrap().contains(&b'\r'));

    let (c_get_main, out_gm, _) = run_cfg(
        &["config", "get", "--user-home", h_str, "models.roles.main"],
        None,
        &[],
    );
    assert_eq!(c_get_main, 0);
    assert_eq!(out_gm.trim(), "[\"claude-sonnet-4\"]");

    let (c_get_rev, out_gr, _) = run_cfg(
        &[
            "config",
            "get",
            "--user-home",
            h_str,
            "models.roles.reviewer",
        ],
        None,
        &[],
    );
    assert_eq!(c_get_rev, 0);
    assert_eq!(out_gr.trim(), "[\"gpt-5.4\"]");

    let (c_get_th, out_th, _) = run_cfg(
        &[
            "config",
            "get",
            "--user-home",
            h_str,
            "planning.understanding_threshold",
        ],
        None,
        &[],
    );
    assert_eq!(c_get_th, 0);
    assert_eq!(out_th.trim(), "88");

    // Re-running migrate when destination exists fails closed with MIGRATE_CONFLICT
    let (c_conf_p, out_cp, err_cp) = run_cfg(
        &[
            "config",
            "migrate",
            "--scope",
            "personal",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
        ],
        None,
        &[],
    );
    assert_eq!(c_conf_p, 1, "{out_cp}\n{err_cp}");
    assert!(
        format!("{out_cp}\n{err_cp}").contains("MIGRATE_CONFLICT"),
        "{out_cp}\n{err_cp}"
    );

    // 3. Non-destructive `b3 config migrate --scope policy`
    let leg_pol = repo.join(".b3/research-policy.json");
    let leg_pol_body = r#"{"auto_merge":"authorized","protected_paths":["releases/","secrets/"],"allow_protected_paths":false,"allowed_target_branches":["main","release/*"],"require_ci":true,"require_review":true}"#;
    write_lf(&leg_pol, leg_pol_body);

    let (c_mpol, out_mpol, err_mpol) = run_cfg(
        &[
            "config",
            "migrate",
            "--scope",
            "policy",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
        ],
        None,
        &[],
    );
    assert_eq!(c_mpol, 0, "{out_mpol}\n{err_mpol}");
    assert!(out_mpol.contains("migrated:"), "{out_mpol}");
    assert!(
        leg_pol.is_file(),
        "legacy research-policy.json must be preserved"
    );
    assert_eq!(fs::read_to_string(&leg_pol).unwrap(), leg_pol_body);

    let dest_pol = repo.join(".b3/policy.toml");
    assert!(dest_pol.is_file());
    let pol_txt = fs::read_to_string(&dest_pol).unwrap();
    assert!(!pol_txt.contains('\r'));
    assert!(pol_txt.contains("auto_merge = \"authorized\""), "{pol_txt}");
    assert!(
        pol_txt.contains("auto_merge_max_risk = \"CRITICAL\""),
        "{pol_txt}"
    );
    assert!(pol_txt.contains("\"releases/\""), "{pol_txt}");
    assert!(pol_txt.contains("\"release/*\""), "{pol_txt}");

    // Re-running migrate --scope policy fails closed with MIGRATE_CONFLICT without overwriting
    let (c_conf_pol, out_cpol, err_cpol) = run_cfg(
        &[
            "config",
            "migrate",
            "--scope",
            "policy",
            "--repo-root",
            r_str,
            "--user-home",
            h_str,
        ],
        None,
        &[],
    );
    assert_eq!(c_conf_pol, 1, "{out_cpol}\n{err_cpol}");
    assert!(
        format!("{out_cpol}\n{err_cpol}").contains("MIGRATE_CONFLICT"),
        "{out_cpol}\n{err_cpol}"
    );
    assert_eq!(fs::read_to_string(&dest_pol).unwrap(), pol_txt);

    // 4. `b3 config migrate --scope all` cleanly migrates a fresh pair without deleting originals
    let home_all = tmp.path.join("home-all");
    let repo_all = tmp.path.join("repo-all");
    fs::create_dir_all(&home_all).unwrap();
    clone_seeded_git_repo(&repo_all);
    write_lf(&home_all.join(".b3/models.md"), "| `main` | `balanced` |\n");
    write_lf(
        &repo_all.join(".b3/research-policy.json"),
        r#"{"auto_merge":"disabled","require_ci":true,"require_review":true}"#,
    );
    let (c_all, out_all, err_all) = run_cfg(
        &[
            "config",
            "migrate",
            "--scope",
            "all",
            "--repo-root",
            repo_all.to_str().unwrap(),
            "--user-home",
            home_all.to_str().unwrap(),
        ],
        None,
        &[],
    );
    assert_eq!(c_all, 0, "{out_all}\n{err_all}");
    assert!(home_all.join(".b3/config.toml").is_file());
    assert!(home_all.join(".b3/models.md").is_file());
    assert!(repo_all.join(".b3/policy.toml").is_file());
    assert!(repo_all.join(".b3/research-policy.json").is_file());
    let pol_all = fs::read_to_string(repo_all.join(".b3/policy.toml")).unwrap();
    assert!(
        pol_all.contains("auto_merge_max_risk = \"LOW\""),
        "{pol_all}"
    );

    // 5. Strict legacy policy migration failure on mistyped JSON fields (#2) & `auto` preservation in project models.md (#5)
    let bad_pol_repo = tmp.path.join("bad-pol-repo");
    clone_seeded_git_repo(&bad_pol_repo);
    write_lf(
        &bad_pol_repo.join(".b3/research-policy.json"),
        r#"{"auto_merge":"disabled","protected_paths":"Cargo.lock"}"#,
    );
    let (c_bad_pol, out_bp, err_bp) = run_cfg(
        &[
            "config",
            "migrate",
            "--scope",
            "policy",
            "--repo-root",
            bad_pol_repo.to_str().unwrap(),
            "--user-home",
            home_all.to_str().unwrap(),
        ],
        None,
        &[],
    );
    assert_eq!(
        c_bad_pol, 1,
        "mistyped research-policy.json must fail cleanly: {out_bp}\n{err_bp}"
    );
    assert!(
        format!("{out_bp}\n{err_bp}").contains("MIGRATE_FAIL"),
        "{out_bp}\n{err_bp}"
    );

    let auto_proj_repo = tmp.path.join("auto-proj-repo");
    clone_seeded_git_repo(&auto_proj_repo);
    write_lf(
        &auto_proj_repo.join(".b3/models.md"),
        "| `planning` | `auto` |\n",
    );
    let (c_ap, out_ap, err_ap) = run_cfg(
        &[
            "config",
            "migrate",
            "--scope",
            "project",
            "--repo-root",
            auto_proj_repo.to_str().unwrap(),
            "--user-home",
            home_all.to_str().unwrap(),
        ],
        None,
        &[],
    );
    assert_eq!(c_ap, 0, "{out_ap}\n{err_ap}");
    let proj_toml = fs::read_to_string(auto_proj_repo.join(".b3/config.toml")).unwrap();
    assert!(
        proj_toml.contains("planning = [\"auto\"]"),
        "project models.md explicit `auto` must be preserved:\n{proj_toml}"
    );
}
