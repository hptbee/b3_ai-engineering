use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use crate::adapters::common::resolve_user_home_dir;
use crate::error::{fail, B3Error};
use crate::fs::has_control_chars;

/// Enforcement mode for B3 host-native guard hooks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum HookMode {
    #[default]
    Enforce,
    Audit,
    Off,
}

impl HookMode {
    /// Strictly parses `enforce`, `audit`, or `off`.
    pub fn parse(raw: &str) -> Result<Self, B3Error> {
        match raw.trim() {
            "enforce" => Ok(Self::Enforce),
            "audit" => Ok(Self::Audit),
            "off" => Ok(Self::Off),
            other => Err(fail(
                format!(
                    "HOOK_CONFIG_INVALID: invalid hook mode '{other}'; expected enforce, audit, or off"
                ),
                1,
            )),
        }
    }

    /// Returns the canonical lowercase string form of the mode.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Enforce => "enforce",
            Self::Audit => "audit",
            Self::Off => "off",
        }
    }
}

/// Effective resolved hook configuration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HookConfig {
    pub enabled: bool,
    pub mode: HookMode,
}

impl Default for HookConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            mode: HookMode::Enforce,
        }
    }
}

impl HookConfig {
    /// Returns the effective mode taking `enabled` into account.
    pub fn effective_mode(self) -> HookMode {
        if self.enabled {
            self.mode
        } else {
            HookMode::Off
        }
    }
}

/// Partial hook configuration override loaded from a preferences file, env, or CLI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct HookConfigOverride {
    pub enabled: Option<bool>,
    pub mode: Option<HookMode>,
}

/// Returns the default personal/global preferences path (`B3_MODELS_PERSONAL` if set and valid,
/// otherwise `<user_home>/.b3/models.md`).
pub fn default_global_preferences_path(user_home: Option<&Path>) -> PathBuf {
    if let Ok(val) = std::env::var("B3_MODELS_PERSONAL") {
        let trimmed = val.trim();
        if !trimmed.is_empty() && !has_control_chars(trimmed) {
            return PathBuf::from(trimmed);
        }
    }
    resolve_user_home_dir(user_home)
        .join(".b3")
        .join("models.md")
}

/// Returns `<project_root>/.b3/models.md`.
pub fn default_project_preferences_path(project_root: &Path) -> PathBuf {
    project_root.join(".b3").join("models.md")
}

#[derive(Debug, Clone, Copy)]
struct FenceState {
    marker_char: char,
    marker_len: usize,
    is_yaml_candidate: bool,
}

fn parse_fence_open(trimmed_start: &str) -> Option<FenceState> {
    let first = trimmed_start.chars().next()?;
    if first != '`' && first != '~' {
        return None;
    }
    let marker_len = trimmed_start.chars().take_while(|&c| c == first).count();
    if marker_len < 3 {
        return None;
    }
    let rest = trimmed_start[marker_len..].trim();
    // CommonMark info strings for backtick fences cannot contain backticks.
    if first == '`' && rest.contains('`') {
        return None;
    }
    let lang = rest.split_whitespace().next().unwrap_or("");
    let is_yaml_candidate =
        lang.is_empty() || lang.eq_ignore_ascii_case("yaml") || lang.eq_ignore_ascii_case("yml");
    Some(FenceState {
        marker_char: first,
        marker_len,
        is_yaml_candidate,
    })
}

fn is_fence_close(trimmed: &str, state: FenceState) -> bool {
    let count = trimmed
        .chars()
        .take_while(|&c| c == state.marker_char)
        .count();
    count >= state.marker_len && trimmed[count..].trim().is_empty()
}

fn strip_yaml_comment(line: &str) -> &str {
    let bytes = line.as_bytes();
    let mut in_single = false;
    let mut in_double = false;
    let mut escaped = false;

    for (idx, &b) in bytes.iter().enumerate() {
        if escaped {
            escaped = false;
            continue;
        }
        if in_double && b == b'\\' {
            escaped = true;
            continue;
        }
        if !in_double && b == b'\'' {
            in_single = !in_single;
            continue;
        }
        if !in_single && b == b'"' {
            in_double = !in_double;
            continue;
        }
        if !in_single
            && !in_double
            && b == b'#'
            && (idx == 0 || bytes[idx - 1].is_ascii_whitespace())
        {
            return &line[..idx];
        }
    }
    line
}

fn count_leading_spaces(line: &str) -> Result<usize, B3Error> {
    let mut spaces = 0usize;
    for ch in line.chars() {
        if ch == ' ' {
            spaces += 1;
        } else if ch == '\t' {
            return Err(fail(
                "HOOK_CONFIG_INVALID: tabs are not allowed in hooks YAML indentation",
                1,
            ));
        } else {
            break;
        }
    }
    Ok(spaces)
}

fn unquote_yaml_scalar(raw: &str) -> &str {
    let t = raw.trim();
    if t.len() >= 2
        && ((t.starts_with('"') && t.ends_with('"')) || (t.starts_with('\'') && t.ends_with('\'')))
    {
        &t[1..t.len() - 1]
    } else {
        t
    }
}

fn is_hooks_header(uncommented: &str) -> Result<Option<usize>, B3Error> {
    let trimmed = uncommented.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    if let Some(after_colon) = trimmed.strip_prefix("hooks:") {
        if after_colon.is_empty() || after_colon.chars().next().is_some_and(char::is_whitespace) {
            let val = after_colon.trim();
            if !val.is_empty() {
                return Err(fail(
                    format!("HOOK_CONFIG_INVALID: 'hooks:' must be a mapping, got '{val}'"),
                    1,
                ));
            }
            let indent = count_leading_spaces(uncommented)?;
            return Ok(Some(indent));
        }
    }
    Ok(None)
}

fn parse_hooks_kv(
    line: &str,
    out: &mut HookConfigOverride,
    seen_enabled: &mut bool,
    seen_mode: &mut bool,
) -> Result<(), B3Error> {
    let Some((key_raw, val_raw)) = line.split_once(':') else {
        return Err(fail(
            format!(
                "HOOK_CONFIG_INVALID: expected 'key: value' inside hooks section, got '{}'",
                line.trim()
            ),
            1,
        ));
    };
    let key = key_raw.trim();
    let val = val_raw.trim();
    match key {
        "enabled" => {
            if *seen_enabled {
                return Err(fail(
                    "HOOK_CONFIG_INVALID: duplicate key 'enabled' in hooks section",
                    1,
                ));
            }
            *seen_enabled = true;
            let parsed = match val {
                "true" => true,
                "false" => false,
                other => {
                    return Err(fail(
                        format!(
                            "HOOK_CONFIG_INVALID: invalid 'enabled' value '{other}'; expected true or false"
                        ),
                        1,
                    ));
                }
            };
            out.enabled = Some(parsed);
            Ok(())
        }
        "mode" => {
            if *seen_mode {
                return Err(fail(
                    "HOOK_CONFIG_INVALID: duplicate key 'mode' in hooks section",
                    1,
                ));
            }
            *seen_mode = true;
            let scalar = unquote_yaml_scalar(val);
            out.mode = Some(HookMode::parse(scalar)?);
            Ok(())
        }
        other => Err(fail(
            format!("HOOK_CONFIG_INVALID: unknown key '{other}' in hooks section"),
            1,
        )),
    }
}

/// Parses optional `hooks:` preferences from markdown (fenced YAML blocks or standalone `hooks:`
/// sections). Returns `Ok(None)` when no `hooks:` section is present.
pub fn parse_hook_config_from_markdown(
    content: &str,
) -> Result<Option<HookConfigOverride>, B3Error> {
    let clean = content.strip_prefix('\u{FEFF}').unwrap_or(content);
    let normalized = clean.replace("\r\n", "\n").replace('\r', "\n");

    let mut fence: Option<FenceState> = None;
    let mut in_hooks_indent: Option<usize> = None;
    let mut found_hooks = false;
    let mut result = HookConfigOverride::default();
    let mut seen_enabled = false;
    let mut seen_mode = false;

    for raw_line in normalized.split('\n') {
        let trimmed_start = raw_line.trim_start();
        let trimmed = raw_line.trim();

        if let Some(state) = fence {
            if is_fence_close(trimmed, state) {
                fence = None;
                in_hooks_indent = None;
                continue;
            }
            if !state.is_yaml_candidate {
                continue;
            }
        } else if let Some(opened) = parse_fence_open(trimmed_start) {
            in_hooks_indent = None;
            fence = Some(opened);
            continue;
        }

        let uncommented = strip_yaml_comment(raw_line);
        if uncommented.trim().is_empty() {
            continue;
        }

        if let Some(hooks_indent) = in_hooks_indent {
            let line_indent = count_leading_spaces(uncommented)?;
            if line_indent > hooks_indent {
                parse_hooks_kv(uncommented, &mut result, &mut seen_enabled, &mut seen_mode)?;
                continue;
            }
            in_hooks_indent = None;
        }

        if let Some(indent) = is_hooks_header(uncommented)? {
            if found_hooks {
                return Err(fail(
                    "HOOK_CONFIG_INVALID: duplicate 'hooks:' section in preferences markdown",
                    1,
                ));
            }
            found_hooks = true;
            in_hooks_indent = Some(indent);
        }
    }

    if found_hooks {
        Ok(Some(result))
    } else {
        Ok(None)
    }
}

fn load_override_file(
    path: &Path,
    label: &str,
    warnings: &mut Vec<String>,
) -> Option<HookConfigOverride> {
    let content = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) if e.kind() == ErrorKind::NotFound => return None,
        Err(e) => {
            warnings.push(format!(
                "HOOK_CONFIG_WARN: unable to read {label} preferences {}: {e}",
                path.display()
            ));
            return None;
        }
    };
    match parse_hook_config_from_markdown(&content) {
        Ok(ov) => ov,
        Err(e) => {
            warnings.push(format!(
                "HOOK_CONFIG_WARN: ignoring malformed {label} preferences {}: {}",
                path.display(),
                e.message
            ));
            None
        }
    }
}

fn apply_override(cfg: &mut HookConfig, ov: HookConfigOverride) {
    if let Some(enabled) = ov.enabled {
        cfg.enabled = enabled;
    }
    if let Some(mode) = ov.mode {
        cfg.mode = mode;
    }
}

/// Resolves effective hook preferences according to precedence:
/// `cli_override > B3_HOOK_MODE env > project > global > defaults`,
/// falling back gracefully with warnings on malformed files or invalid env values.
pub fn resolve_hook_config(
    project_path: Option<&Path>,
    global_path: Option<&Path>,
    cli_override: Option<HookConfigOverride>,
) -> (HookConfig, Vec<String>) {
    let mut cfg = HookConfig::default();
    let mut warnings = Vec::new();

    if let Some(g_path) = global_path {
        if let Some(ov) = load_override_file(g_path, "global", &mut warnings) {
            apply_override(&mut cfg, ov);
        }
    }

    if let Some(p_path) = project_path {
        if let Some(ov) = load_override_file(p_path, "project", &mut warnings) {
            apply_override(&mut cfg, ov);
        }
    }

    if let Ok(raw_env) = std::env::var("B3_HOOK_MODE") {
        let trimmed = raw_env.trim();
        if !trimmed.is_empty() {
            if has_control_chars(trimmed) {
                warnings.push(
                    "HOOK_CONFIG_WARN: ignoring B3_HOOK_MODE containing control characters"
                        .to_string(),
                );
            } else {
                match HookMode::parse(trimmed) {
                    Ok(mode) => {
                        cfg.mode = mode;
                        cfg.enabled = mode != HookMode::Off;
                    }
                    Err(e) => warnings.push(format!(
                        "HOOK_CONFIG_WARN: ignoring invalid B3_HOOK_MODE '{}': {}",
                        trimmed, e.message
                    )),
                }
            }
        }
    }

    if let Some(ov) = cli_override {
        let explicit_enabled = ov.enabled;
        let explicit_mode = ov.mode;
        apply_override(&mut cfg, ov);
        if explicit_enabled.is_none() {
            if let Some(m) = explicit_mode {
                cfg.enabled = m != HookMode::Off;
            }
        }
    }

    (cfg, warnings)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct EnvGuard {
        key: &'static str,
        prev: Option<String>,
    }

    impl EnvGuard {
        fn set(key: &'static str, val: Option<&str>) -> Self {
            let prev = std::env::var(key).ok();
            match val {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
            Self { key, prev }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            match &self.prev {
                Some(v) => std::env::set_var(self.key, v),
                None => std::env::remove_var(self.key),
            }
        }
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "b3_hook_cfg_test_{}_{}_{}",
            name,
            std::process::id(),
            crate::fs::next_tmp_suffix()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn hook_mode_parse_and_default() {
        assert_eq!(HookMode::default(), HookMode::Enforce);
        assert_eq!(HookMode::parse("enforce").unwrap(), HookMode::Enforce);
        assert_eq!(HookMode::parse(" audit ").unwrap(), HookMode::Audit);
        assert_eq!(HookMode::parse("off").unwrap(), HookMode::Off);
        assert_eq!(HookMode::Audit.as_str(), "audit");
        assert!(HookMode::parse("Enforce").is_err());
        assert!(HookMode::parse("invalid").is_err());
    }

    #[test]
    fn parse_fenced_and_standalone_yaml_blocks() {
        let md_fenced = r#"# Model Preferences

```yaml
hooks:
  enabled: true # inline comment
  mode: audit   # another comment
```
"#;
        let parsed = parse_hook_config_from_markdown(md_fenced)
            .unwrap()
            .expect("should find hooks");
        assert_eq!(parsed.enabled, Some(true));
        assert_eq!(parsed.mode, Some(HookMode::Audit));

        let md_standalone =
            "\u{FEFF}# Title\n\nhooks:\n  enabled: false\n  mode: \"off\"\n\n## Next\n";
        let parsed2 = parse_hook_config_from_markdown(md_standalone)
            .unwrap()
            .expect("should find standalone hooks");
        assert_eq!(parsed2.enabled, Some(false));
        assert_eq!(parsed2.mode, Some(HookMode::Off));

        let md_absent = "# Only models\n\n```bash\nhooks:\n  enabled: bogus\n```\n";
        assert_eq!(parse_hook_config_from_markdown(md_absent).unwrap(), None);
    }

    #[test]
    fn parse_rejects_invalid_and_duplicate_keys() {
        let bad_bool = "```yaml\nhooks:\n  enabled: yes\n```\n";
        assert!(parse_hook_config_from_markdown(bad_bool).is_err());

        let quoted_bool = "```yaml\nhooks:\n  enabled: \"true\"\n```\n";
        assert!(parse_hook_config_from_markdown(quoted_bool).is_err());

        let bad_mode = "```yaml\nhooks:\n  mode: warn\n```\n";
        assert!(parse_hook_config_from_markdown(bad_mode).is_err());

        let unknown_key = "```yaml\nhooks:\n  extra: 1\n```\n";
        assert!(parse_hook_config_from_markdown(unknown_key).is_err());

        let dup_key = "```yaml\nhooks:\n  mode: audit\n  mode: off\n```\n";
        assert!(parse_hook_config_from_markdown(dup_key).is_err());

        let dup_section = "```yaml\nhooks:\n  mode: audit\n```\n\nhooks:\n  mode: off\n";
        assert!(parse_hook_config_from_markdown(dup_section).is_err());
    }

    #[test]
    fn resolve_precedence_and_fallbacks() {
        let _lock = crate::hook::HOOK_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _env_hook = EnvGuard::set("B3_HOOK_MODE", None);

        let dir = temp_dir("precedence");
        let global = dir.join("global.md");
        let project = dir.join("project.md");
        fs::write(
            &global,
            "```yaml\nhooks:\n  enabled: false\n  mode: off\n```\n",
        )
        .unwrap();
        fs::write(
            &project,
            "```yaml\nhooks:\n  enabled: true\n  mode: audit\n```\n",
        )
        .unwrap();

        let (cfg, warnings) = resolve_hook_config(Some(&project), Some(&global), None);
        assert!(warnings.is_empty());
        assert_eq!(
            cfg,
            HookConfig {
                enabled: true,
                mode: HookMode::Audit,
            }
        );

        {
            let _env = EnvGuard::set("B3_HOOK_MODE", Some("off"));
            let (cfg_env, w_env) = resolve_hook_config(Some(&project), Some(&global), None);
            assert!(w_env.is_empty());
            assert_eq!(cfg_env.mode, HookMode::Off);

            let (cfg_cli, w_cli) = resolve_hook_config(
                Some(&project),
                Some(&global),
                Some(HookConfigOverride {
                    enabled: Some(false),
                    mode: Some(HookMode::Enforce),
                }),
            );
            assert!(w_cli.is_empty());
            assert_eq!(
                cfg_cli,
                HookConfig {
                    enabled: false,
                    mode: HookMode::Enforce,
                }
            );
        }

        // Malformed project file + invalid env -> warns and falls back gracefully to global/default.
        fs::write(&project, "```yaml\nhooks:\n  mode: invalid\n```\n").unwrap();
        let _bad_env = EnvGuard::set("B3_HOOK_MODE", Some("bogus"));
        let (cfg_fb, w_fb) = resolve_hook_config(Some(&project), Some(&global), None);
        assert_eq!(w_fb.len(), 2);
        assert_eq!(
            cfg_fb,
            HookConfig {
                enabled: false,
                mode: HookMode::Off,
            }
        );

        // Explicit B3_HOOK_MODE=enforce or CLI --mode audit re-enables disabled file config.
        let _reenable = EnvGuard::set("B3_HOOK_MODE", Some("enforce"));
        let (cfg_re, _) = resolve_hook_config(None, Some(&global), None);
        assert_eq!(
            cfg_re,
            HookConfig {
                enabled: true,
                mode: HookMode::Enforce,
            }
        );
        let (cfg_cli_re, _) = resolve_hook_config(
            None,
            Some(&global),
            Some(HookConfigOverride {
                enabled: None,
                mode: Some(HookMode::Audit),
            }),
        );
        assert_eq!(
            cfg_cli_re,
            HookConfig {
                enabled: true,
                mode: HookMode::Audit,
            }
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn default_preference_paths_respect_env_and_home() {
        let _lock = crate::hook::HOOK_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _g = EnvGuard::set("B3_MODELS_PERSONAL", None);

        let home = std::env::temp_dir().join("b3-user-home");
        let expected_global = resolve_user_home_dir(Some(&home))
            .join(".b3")
            .join("models.md");
        assert_eq!(
            default_global_preferences_path(Some(&home)),
            expected_global
        );

        let proj = std::env::temp_dir().join("b3-proj");
        assert_eq!(
            default_project_preferences_path(&proj),
            proj.join(".b3").join("models.md")
        );

        let _g2 = EnvGuard::set("B3_MODELS_PERSONAL", Some("/custom/models.md"));
        assert_eq!(
            default_global_preferences_path(Some(&home)),
            PathBuf::from("/custom/models.md")
        );
    }

    #[test]
    fn parses_models_example_md() {
        let content = include_str!("../../config/models.example.md");
        let parsed = parse_hook_config_from_markdown(content)
            .unwrap()
            .expect("models.example.md must include hooks section");
        assert_eq!(parsed.enabled, Some(true));
        assert_eq!(parsed.mode, Some(HookMode::Enforce));
    }
}
