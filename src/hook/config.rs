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
            other => Err(fail(format!("HOOK_CONFIG_INVALID: invalid hook mode '{other}'; expected enforce, audit, or off"), 1)),
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

#[derive(Clone, Copy)]
struct FenceState {
    marker_char: char,
    marker_len: usize,
    is_yaml_candidate: bool,
}

fn parse_fence_open(trimmed_start: &str) -> Option<FenceState> {
    let first = trimmed_start
        .chars()
        .next()
        .filter(|&c| c == '`' || c == '~')?;
    let marker_len = trimmed_start.chars().take_while(|&c| c == first).count();
    let rest = (marker_len >= 3).then(|| trimmed_start[marker_len..].trim())?;
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
    let (mut in_single, mut in_double, mut escaped) = (false, false, false);
    for (idx, &b) in bytes.iter().enumerate() {
        if escaped {
            escaped = false;
        } else if in_double && b == b'\\' {
            escaped = true;
        } else if !in_double && b == b'\'' {
            in_single = !in_single;
        } else if !in_single && b == b'"' {
            in_double = !in_double;
        } else if !in_single
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
        match ch {
            ' ' => spaces += 1,
            '\t' => {
                return Err(fail(
                    "HOOK_CONFIG_INVALID: tabs are not allowed in hooks YAML indentation",
                    1,
                ))
            }
            _ => break,
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

fn parse_hooks_header(uncommented: &str) -> Result<Option<usize>, B3Error> {
    let Some(after) = uncommented.trim().strip_prefix("hooks:") else {
        return Ok(None);
    };
    if !after.is_empty() && !after.chars().next().is_some_and(char::is_whitespace) {
        return Ok(None);
    }
    let val = after.trim();
    if !val.is_empty() {
        return Err(fail(
            format!("HOOK_CONFIG_INVALID: 'hooks:' must be a mapping, got '{val}'"),
            1,
        ));
    }
    count_leading_spaces(uncommented).map(Some)
}

fn parse_hooks_kv(line: &str, out: &mut HookConfigOverride) -> Result<(), B3Error> {
    let Some((key_raw, val_raw)) = line.split_once(':') else {
        return Err(fail(
            format!(
                "HOOK_CONFIG_INVALID: expected 'key: value' inside hooks section, got '{}'",
                line.trim()
            ),
            1,
        ));
    };
    match (key_raw.trim(), val_raw.trim()) {
        ("enabled", _) if out.enabled.is_some() => Err(fail(
            "HOOK_CONFIG_INVALID: duplicate key 'enabled' in hooks section",
            1,
        )),
        ("enabled", "true") => {
            out.enabled = Some(true);
            Ok(())
        }
        ("enabled", "false") => {
            out.enabled = Some(false);
            Ok(())
        }
        ("enabled", other) => Err(fail(
            format!(
                "HOOK_CONFIG_INVALID: invalid 'enabled' value '{other}'; expected true or false"
            ),
            1,
        )),
        ("mode", _) if out.mode.is_some() => Err(fail(
            "HOOK_CONFIG_INVALID: duplicate key 'mode' in hooks section",
            1,
        )),
        ("mode", val) => {
            out.mode = Some(HookMode::parse(unquote_yaml_scalar(val))?);
            Ok(())
        }
        (other, _) => Err(fail(
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
    let (mut fence, mut in_hooks_indent, mut found_hooks) = (None, None, false);
    let mut result = HookConfigOverride::default();

    for raw_line in normalized.split('\n') {
        if let Some(state) = fence {
            if is_fence_close(raw_line.trim(), state) {
                fence = None;
                in_hooks_indent = None;
                continue;
            }
            if !state.is_yaml_candidate {
                continue;
            }
        } else if let Some(opened) = parse_fence_open(raw_line.trim_start()) {
            in_hooks_indent = None;
            fence = Some(opened);
            continue;
        }

        let uncommented = strip_yaml_comment(raw_line);
        if uncommented.trim().is_empty() {
            continue;
        }
        if let Some(hooks_indent) = in_hooks_indent {
            if count_leading_spaces(uncommented)? > hooks_indent {
                parse_hooks_kv(uncommented, &mut result)?;
                continue;
            }
            in_hooks_indent = None;
        }
        if let Some(indent) = parse_hooks_header(uncommented)? {
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
    Ok(found_hooks.then_some(result))
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
    parse_hook_config_from_markdown(&content).unwrap_or_else(|e| {
        warnings.push(format!(
            "HOOK_CONFIG_WARN: ignoring malformed {label} preferences {}: {}",
            path.display(),
            e.message
        ));
        None
    })
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

    for (path, label) in [(global_path, "global"), (project_path, "project")] {
        if let Some(ov) = path.and_then(|p| load_override_file(p, label, &mut warnings)) {
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
                        "HOOK_CONFIG_WARN: ignoring invalid B3_HOOK_MODE '{trimmed}': {}",
                        e.message
                    )),
                }
            }
        }
    }

    if let Some(ov) = cli_override {
        apply_override(&mut cfg, ov);
        if ov.enabled.is_none() {
            if let Some(m) = ov.mode {
                cfg.enabled = m != HookMode::Off;
            }
        }
    }

    (cfg, warnings)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct EnvGuard(&'static str, Option<String>);
    impl EnvGuard {
        fn set(key: &'static str, val: Option<&str>) -> Self {
            let prev = std::env::var(key).ok();
            match val {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
            Self(key, prev)
        }
    }
    impl Drop for EnvGuard {
        fn drop(&mut self) {
            match &self.1 {
                Some(v) => std::env::set_var(self.0, v),
                None => std::env::remove_var(self.0),
            }
        }
    }

    #[test]
    fn hook_mode_and_config_basics() {
        assert_eq!(HookMode::default(), HookMode::Enforce);
        assert_eq!(HookMode::parse(" audit ").unwrap(), HookMode::Audit);
        assert_eq!(HookMode::Off.as_str(), "off");
        assert!(HookMode::parse("Enforce").is_err());
        assert_eq!(
            HookConfig {
                enabled: false,
                mode: HookMode::Enforce
            }
            .effective_mode(),
            HookMode::Off
        );
    }

    #[test]
    fn parse_fenced_standalone_and_rejects_invalid() {
        let fenced = "```yaml\nhooks:\n  enabled: true # comment\n  mode: audit\n```\n";
        assert_eq!(
            parse_hook_config_from_markdown(fenced).unwrap(),
            Some(HookConfigOverride {
                enabled: Some(true),
                mode: Some(HookMode::Audit)
            })
        );

        let standalone =
            "\u{FEFF}# Title\r\nhooks:\r\n  enabled: false\r\n  mode: \"off\"\r\n\r\n## Next\r\n";
        assert_eq!(
            parse_hook_config_from_markdown(standalone).unwrap(),
            Some(HookConfigOverride {
                enabled: Some(false),
                mode: Some(HookMode::Off)
            })
        );
        assert_eq!(
            parse_hook_config_from_markdown("```bash\nhooks:\n  enabled: bogus\n```\n").unwrap(),
            None
        );

        for invalid in [
            "```yaml\nhooks:\n  enabled: yes\n```\n",
            "```yaml\nhooks:\n  enabled: \"true\"\n```\n",
            "```yaml\nhooks:\n\tenabled: true\n```\n",
            "```yaml\nhooks:\n  mode: warn\n```\n",
            "```yaml\nhooks:\n  extra: 1\n```\n",
            "```yaml\nhooks:\n  mode: audit\n  mode: off\n```\n",
            "```yaml\nhooks: inline\n```\n",
            "```yaml\nhooks:\n  mode: audit\n```\nhooks:\n  mode: off\n",
        ] {
            assert!(
                parse_hook_config_from_markdown(invalid).is_err(),
                "expected err: {invalid}"
            );
        }
    }

    #[test]
    fn resolve_precedence_paths_and_example() {
        let _lock = crate::hook::HOOK_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (_eh, _ep) = (
            EnvGuard::set("B3_HOOK_MODE", None),
            EnvGuard::set("B3_MODELS_PERSONAL", None),
        );

        let dir = std::env::temp_dir().join(format!(
            "b3_hook_cfg_{}_{}",
            std::process::id(),
            crate::fs::next_tmp_suffix()
        ));
        fs::create_dir_all(&dir).unwrap();
        let (global, project) = (dir.join("global.md"), dir.join("project.md"));
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
                mode: HookMode::Audit
            }
        );

        {
            let _env = EnvGuard::set("B3_HOOK_MODE", Some("off"));
            assert_eq!(
                resolve_hook_config(Some(&project), Some(&global), None)
                    .0
                    .mode,
                HookMode::Off
            );
            let cli = HookConfigOverride {
                enabled: Some(false),
                mode: Some(HookMode::Enforce),
            };
            assert_eq!(
                resolve_hook_config(Some(&project), Some(&global), Some(cli)).0,
                HookConfig {
                    enabled: false,
                    mode: HookMode::Enforce
                }
            );
        }

        fs::write(&project, "```yaml\nhooks:\n  mode: invalid\n```\n").unwrap();
        let _bad = EnvGuard::set("B3_HOOK_MODE", Some("bogus"));
        let (cfg_fb, w_fb) = resolve_hook_config(Some(&project), Some(&global), None);
        assert_eq!(w_fb.len(), 2);
        assert_eq!(
            cfg_fb,
            HookConfig {
                enabled: false,
                mode: HookMode::Off
            }
        );

        let _re = EnvGuard::set("B3_HOOK_MODE", Some("enforce"));
        assert_eq!(
            resolve_hook_config(None, Some(&global), None).0,
            HookConfig {
                enabled: true,
                mode: HookMode::Enforce
            }
        );
        let cli_re = HookConfigOverride {
            enabled: None,
            mode: Some(HookMode::Audit),
        };
        assert_eq!(
            resolve_hook_config(None, Some(&global), Some(cli_re)).0,
            HookConfig {
                enabled: true,
                mode: HookMode::Audit
            }
        );

        let home = dir.join("home");
        assert_eq!(
            default_global_preferences_path(Some(&home)),
            resolve_user_home_dir(Some(&home))
                .join(".b3")
                .join("models.md")
        );
        assert_eq!(
            default_project_preferences_path(&dir),
            dir.join(".b3").join("models.md")
        );
        let _p = EnvGuard::set("B3_MODELS_PERSONAL", Some("/custom/models.md"));
        assert_eq!(
            default_global_preferences_path(Some(&home)),
            PathBuf::from("/custom/models.md")
        );

        let example =
            parse_hook_config_from_markdown(include_str!("../../config/models.example.md"))
                .unwrap()
                .unwrap();
        assert_eq!(
            example,
            HookConfigOverride {
                enabled: Some(true),
                mode: Some(HookMode::Enforce)
            }
        );

        let _ = fs::remove_dir_all(&dir);
    }
}
