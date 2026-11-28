mod common;

use std::sync::Mutex;

use b3::planning_config::{
    default_global_preferences_path, default_project_preferences_path,
    parse_planning_config_from_markdown, resolve_planning_config, resolve_planning_config_graceful,
    validate_override, validate_threshold, PlanningConfig, PlanningConfigOverride,
    DEFAULT_CLARIFICATION_GATE, DEFAULT_UNDERSTANDING_THRESHOLD, MAX_UNDERSTANDING_THRESHOLD,
    MIN_UNDERSTANDING_THRESHOLD,
};
use common::{repo_root, write_lf, TempDirGuard};

static ENV_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn defaults_match_canonical_values() {
    const _: () = {
        assert!(DEFAULT_CLARIFICATION_GATE);
        assert!(DEFAULT_UNDERSTANDING_THRESHOLD == 96);
        assert!(MIN_UNDERSTANDING_THRESHOLD == 1);
        assert!(MAX_UNDERSTANDING_THRESHOLD == 100);
    };

    let cfg = PlanningConfig::default();
    assert_eq!(cfg.clarification_gate, DEFAULT_CLARIFICATION_GATE);
    assert_eq!(cfg.understanding_threshold, DEFAULT_UNDERSTANDING_THRESHOLD);
}

#[test]
fn threshold_validation_accepts_boundaries_and_rejects_out_of_range() {
    assert_eq!(validate_threshold(1).unwrap(), 1);
    assert_eq!(validate_threshold(96).unwrap(), 96);
    assert_eq!(validate_threshold(100).unwrap(), 100);

    assert!(validate_threshold(0).is_err());
    assert!(validate_threshold(101).is_err());
    assert!(validate_threshold(-5).is_err());

    assert!(validate_override(&PlanningConfigOverride {
        clarification_gate: Some(false),
        understanding_threshold: Some(1),
    })
    .is_ok());
    assert!(validate_override(&PlanningConfigOverride {
        clarification_gate: None,
        understanding_threshold: Some(0),
    })
    .is_err());
    assert!(validate_override(&PlanningConfigOverride {
        clarification_gate: None,
        understanding_threshold: Some(101),
    })
    .is_err());
}

#[test]
fn parses_models_example_md_canonical_planning_section() {
    let example_path = repo_root().join("config").join("models.example.md");
    let content = std::fs::read_to_string(&example_path).expect("read config/models.example.md");
    let parsed = parse_planning_config_from_markdown(&content)
        .expect("parse config/models.example.md")
        .expect("models.example.md must define planning preferences");

    assert_eq!(
        parsed,
        PlanningConfigOverride {
            clarification_gate: Some(true),
            understanding_threshold: Some(96),
        }
    );
}

#[test]
fn parses_fenced_and_standalone_planning_blocks_with_inline_comments() {
    let fenced = r#"# Model Preferences

```yaml
planning:
  clarification_gate: false # skip interactive gate
  understanding_threshold: 88 # strict threshold
```
"#;
    assert_eq!(
        parse_planning_config_from_markdown(fenced).unwrap(),
        Some(PlanningConfigOverride {
            clarification_gate: Some(false),
            understanding_threshold: Some(88),
        })
    );

    let standalone = "planning:\n  clarification_gate: true\n  understanding_threshold: 100\n\n# Following markdown heading\n";
    assert_eq!(
        parse_planning_config_from_markdown(standalone).unwrap(),
        Some(PlanningConfigOverride {
            clarification_gate: Some(true),
            understanding_threshold: Some(100),
        })
    );

    let without_planning =
        "# B3 Model Preferences\n\n| Role | Preferred Model |\n| --- | --- |\n| `main` | auto |\n";
    assert_eq!(
        parse_planning_config_from_markdown(without_planning).unwrap(),
        None
    );

    let non_yaml_fence = "```bash\nplanning:\n  clarification_gate: yes\n```\n";
    assert_eq!(
        parse_planning_config_from_markdown(non_yaml_fence).unwrap(),
        None
    );

    let nested_under_other_key = "```yaml\nmodels:\n  planning: auto\n```\n";
    assert_eq!(
        parse_planning_config_from_markdown(nested_under_other_key).unwrap(),
        None
    );
}

#[test]
fn rejects_invalid_booleans_thresholds_and_unknown_keys() {
    let bad_bools = [
        "```yaml\nplanning:\n  clarification_gate: \"yes\"\n```",
        "```yaml\nplanning:\n  clarification_gate: yes\n```",
        "```yaml\nplanning:\n  clarification_gate: 1\n```",
        "```yaml\nplanning:\n  clarification_gate: TRUE\n```",
        "```yaml\nplanning:\n  clarification_gate:\n```",
    ];
    for case in bad_bools {
        assert!(
            parse_planning_config_from_markdown(case).is_err(),
            "expected error for boolean case:\n{case}"
        );
    }

    let bad_thresholds = [
        "```yaml\nplanning:\n  understanding_threshold: 0\n```",
        "```yaml\nplanning:\n  understanding_threshold: 101\n```",
        "```yaml\nplanning:\n  understanding_threshold: -5\n```",
        "```yaml\nplanning:\n  understanding_threshold: 96.5\n```",
        "```yaml\nplanning:\n  understanding_threshold: \"high\"\n```",
        "```yaml\nplanning:\n  understanding_threshold:\n```",
        "```yaml\nplanning:\n  understanding_threshold: +96\n```",
    ];
    for case in bad_thresholds {
        assert!(
            parse_planning_config_from_markdown(case).is_err(),
            "expected error for threshold case:\n{case}"
        );
    }

    let unknown_key = "```yaml\nplanning:\n  clarification_gate: true\n  extra_field: 123\n```";
    let err = parse_planning_config_from_markdown(unknown_key).unwrap_err();
    assert!(err.message.contains("unknown key 'extra_field'"));

    let duplicate_key =
        "```yaml\nplanning:\n  understanding_threshold: 90\n  understanding_threshold: 95\n```";
    assert!(parse_planning_config_from_markdown(duplicate_key).is_err());

    let scalar_planning = "```yaml\nplanning: disabled\n```";
    assert!(parse_planning_config_from_markdown(scalar_planning).is_err());
}

#[test]
fn resolves_precedence_and_partial_field_overrides() {
    let tmp = TempDirGuard::new("planning-precedence");
    let global_path = tmp.path.join("global/models.md");
    let project_path = tmp.path.join("project/.b3/models.md");

    write_lf(
        &global_path,
        "```yaml\nplanning:\n  clarification_gate: false\n  understanding_threshold: 85\n```\n",
    );
    write_lf(
        &project_path,
        "```yaml\nplanning:\n  understanding_threshold: 92\n```\n",
    );

    // Missing files -> defaults
    let missing = tmp.path.join("does-not-exist/models.md");
    assert_eq!(
        resolve_planning_config(Some(&missing), Some(&missing), None).unwrap(),
        PlanningConfig::default()
    );

    // Global only
    assert_eq!(
        resolve_planning_config(None, Some(&global_path), None).unwrap(),
        PlanningConfig {
            clarification_gate: false,
            understanding_threshold: 85,
        }
    );

    // Project overrides threshold only; clarification_gate inherits from global
    assert_eq!(
        resolve_planning_config(Some(&project_path), Some(&global_path), None).unwrap(),
        PlanningConfig {
            clarification_gate: false,
            understanding_threshold: 92,
        }
    );

    // Per-invocation overrides clarification_gate only; threshold stays from project
    let inv = PlanningConfigOverride {
        clarification_gate: Some(true),
        understanding_threshold: None,
    };
    assert_eq!(
        resolve_planning_config(Some(&project_path), Some(&global_path), Some(inv)).unwrap(),
        PlanningConfig {
            clarification_gate: true,
            understanding_threshold: 92,
        }
    );

    // Full per-invocation override wins over both project and global
    let full_inv = PlanningConfigOverride {
        clarification_gate: Some(true),
        understanding_threshold: Some(100),
    };
    assert_eq!(
        resolve_planning_config(Some(&project_path), Some(&global_path), Some(full_inv)).unwrap(),
        PlanningConfig {
            clarification_gate: true,
            understanding_threshold: 100,
        }
    );
}

#[test]
fn graceful_resolution_falls_back_with_warnings_on_malformed_files() {
    let tmp = TempDirGuard::new("planning-graceful");
    let global_path = tmp.path.join("global/models.md");
    let project_path = tmp.path.join("project/.b3/models.md");

    write_lf(
        &global_path,
        "```yaml\nplanning:\n  clarification_gate: false\n  understanding_threshold: 90\n```\n",
    );
    write_lf(
        &project_path,
        "```yaml\nplanning:\n  understanding_threshold: 999\n```\n",
    );

    // Strict mode rejects malformed project file
    assert!(resolve_planning_config(Some(&project_path), Some(&global_path), None).is_err());

    // Graceful mode warns and falls back to valid global layer
    let (cfg, warnings) =
        resolve_planning_config_graceful(Some(&project_path), Some(&global_path), None);
    assert_eq!(
        cfg,
        PlanningConfig {
            clarification_gate: false,
            understanding_threshold: 90,
        }
    );
    assert_eq!(warnings.len(), 1);

    // Both malformed -> falls back to built-in defaults with 2 warnings
    write_lf(&global_path, "```yaml\nplanning:\n  unknown: true\n```\n");
    let (cfg_both_bad, warnings_both_bad) =
        resolve_planning_config_graceful(Some(&project_path), Some(&global_path), None);
    assert_eq!(cfg_both_bad, PlanningConfig::default());
    assert_eq!(warnings_both_bad.len(), 2);

    // Invalid invocation override in strict vs graceful mode
    let bad_inv = PlanningConfigOverride {
        clarification_gate: Some(false),
        understanding_threshold: Some(0),
    };
    assert!(resolve_planning_config(None, None, Some(bad_inv)).is_err());
    let (cfg_inv_graceful, inv_warnings) =
        resolve_planning_config_graceful(None, None, Some(bad_inv));
    assert_eq!(
        cfg_inv_graceful,
        PlanningConfig {
            clarification_gate: false,
            understanding_threshold: DEFAULT_UNDERSTANDING_THRESHOLD,
        }
    );
    assert_eq!(inv_warnings.len(), 1);
}

#[test]
fn resolves_default_global_and_project_preference_paths() {
    let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let prev = std::env::var_os("B3_MODELS_PERSONAL");

    let tmp = TempDirGuard::new("planning-paths");
    let custom_global = tmp.path.join("custom/personal-models.md");

    std::env::set_var("B3_MODELS_PERSONAL", &custom_global);
    assert_eq!(
        default_global_preferences_path(Some(&tmp.path)),
        custom_global
    );

    std::env::remove_var("B3_MODELS_PERSONAL");
    assert_eq!(
        default_global_preferences_path(Some(&tmp.path)),
        tmp.path.join(".b3").join("models.md")
    );

    // Control characters in B3_MODELS_PERSONAL fall back to user_home/.b3/models.md
    std::env::set_var("B3_MODELS_PERSONAL", "bad\x07path.md");
    assert_eq!(
        default_global_preferences_path(Some(&tmp.path)),
        tmp.path.join(".b3").join("models.md")
    );

    match prev {
        Some(val) => std::env::set_var("B3_MODELS_PERSONAL", val),
        None => std::env::remove_var("B3_MODELS_PERSONAL"),
    }

    assert_eq!(
        default_project_preferences_path(&tmp.path),
        tmp.path.join(".b3").join("models.md")
    );
}
