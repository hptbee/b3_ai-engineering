//! Unified, typed TOML configuration resolver, adaptive model router, CLI, and migrator.

use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::error::{fail, B3Error};
use crate::fs::{
    find_reparse_in_path_hierarchy, has_control_chars, has_reparse_in_path_steps,
    is_reparse_or_symlink, is_unc_or_network_path, normalize_repo_root, resolve_unresolved_path,
    write_atomic_lf,
};
use crate::json::{parse_json, JsonValue};
use crate::toml_lite::{
    format_toml_value, parse_toml_strict, set_toml_key_preserving_comments, TomlDocument, TomlValue,
};

pub const DEFAULT_CONFIG_TEMPLATE: &str = include_str!("../config/config.example.toml");
pub const DEFAULT_POLICY_TEMPLATE: &str = include_str!("../config/policy.example.toml");

const ROLE_NAMES: [&str; 10] = [
    "main",
    "planning",
    "implementation",
    "debugging",
    "research",
    "reviewer",
    "fixer",
    "security_reviewer",
    "architecture_reviewer",
    "performance_reviewer",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigSource {
    Default,
    Personal,
    Project,
    Env,
    Invocation,
}

impl ConfigSource {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::Personal => "personal",
            Self::Project => "project",
            Self::Env => "env",
            Self::Invocation => "invocation",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelRoutingMode {
    Adaptive,
    Fixed,
    Native,
}

impl ModelRoutingMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Adaptive => "adaptive",
            Self::Fixed => "fixed",
            Self::Native => "native",
        }
    }

    fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "adaptive" => Some(Self::Adaptive),
            "fixed" => Some(Self::Fixed),
            "native" => Some(Self::Native),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelFallback {
    Next,
    Native,
}

impl ModelFallback {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Next => "next",
            Self::Native => "native",
        }
    }

    fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "next" => Some(Self::Next),
            "native" => Some(Self::Native),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ModelTiers {
    pub economy: String,
    pub balanced: String,
    pub advanced: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HostModelOverrides {
    pub tiers: BTreeMap<String, String>,
    pub roles: BTreeMap<String, Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelsConfig {
    pub routing: ModelRoutingMode,
    pub auto_escalate: bool,
    pub max_escalations: u8,
    pub fallback: ModelFallback,
    pub tiers: ModelTiers,
    pub roles: BTreeMap<String, Vec<String>>,
    pub hosts: BTreeMap<String, HostModelOverrides>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanningConfig {
    pub clarification_gate: bool,
    pub understanding_threshold: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MaxConcurrency {
    Auto,
    Fixed(usize),
}

impl MaxConcurrency {
    pub fn as_display_string(&self) -> String {
        match self {
            Self::Auto => "auto".to_string(),
            Self::Fixed(n) => n.to_string(),
        }
    }

    fn parse_str(s: &str) -> Option<Self> {
        let trimmed = s.trim();
        if trimmed.eq_ignore_ascii_case("auto") {
            return Some(Self::Auto);
        }
        let n = trimmed.parse::<usize>().ok()?;
        if (1..=64).contains(&n) {
            Some(Self::Fixed(n))
        } else {
            None
        }
    }

    fn parse_toml(v: &TomlValue) -> Option<Self> {
        match v {
            TomlValue::Str(s) => Self::parse_str(s),
            TomlValue::Int(n) if (1..=64).contains(n) => Some(Self::Fixed(*n as usize)),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExecutionMode {
    Auto,
    Sequential,
    Isolated,
}

impl ExecutionMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Sequential => "sequential",
            Self::Isolated => "isolated",
        }
    }

    fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "auto" => Some(Self::Auto),
            "sequential" => Some(Self::Sequential),
            "isolated" => Some(Self::Isolated),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParallelConfig {
    pub max_concurrency: MaxConcurrency,
    pub execution_mode: ExecutionMode,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewSizingConfig {
    pub xs_max_loc: usize,
    pub xs_max_files: usize,
    pub s_max_loc: usize,
    pub s_max_files: usize,
    pub m_max_loc: usize,
    pub m_max_files: usize,
    pub l_max_loc: usize,
    pub l_max_files: usize,
    pub xl_max_loc: usize,
    pub xl_max_files: usize,
}

impl Default for ReviewSizingConfig {
    fn default() -> Self {
        Self {
            xs_max_loc: 100,
            xs_max_files: 3,
            s_max_loc: 300,
            s_max_files: 8,
            m_max_loc: 800,
            m_max_files: 20,
            l_max_loc: 1999,
            l_max_files: 49,
            xl_max_loc: 5000,
            xl_max_files: 100,
        }
    }
}

impl ReviewSizingConfig {
    pub fn validate(&self) -> Result<(), String> {
        let locs = [
            self.xs_max_loc,
            self.s_max_loc,
            self.m_max_loc,
            self.l_max_loc,
            self.xl_max_loc,
        ];
        let files = [
            self.xs_max_files,
            self.s_max_files,
            self.m_max_files,
            self.l_max_files,
            self.xl_max_files,
        ];
        if locs.contains(&0) || files.contains(&0) {
            return Err("review.sizing thresholds must be positive".to_string());
        }
        for w in locs.windows(2) {
            if w[0] >= w[1] {
                return Err(
                    "review.sizing *_max_loc thresholds must be strictly increasing (xs < s < m < l < xl)"
                        .to_string(),
                );
            }
        }
        for w in files.windows(2) {
            if w[0] >= w[1] {
                return Err(
                    "review.sizing *_max_files thresholds must be strictly increasing (xs < s < m < l < xl)"
                        .to_string(),
                );
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewConfig {
    pub max_iterations: u32,
    pub max_loc_per_unit: usize,
    pub max_files_per_unit: usize,
    pub sizing: ReviewSizingConfig,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct B3Config {
    pub models: ModelsConfig,
    pub planning: PlanningConfig,
    pub parallel: ParallelConfig,
    pub review: ReviewConfig,
}

impl Default for B3Config {
    fn default() -> Self {
        let mut roles = BTreeMap::new();
        roles.insert(
            "main".to_string(),
            vec!["balanced".to_string(), "advanced".to_string()],
        );
        for r in [
            "planning",
            "implementation",
            "research",
            "reviewer",
            "fixer",
        ] {
            roles.insert(
                r.to_string(),
                vec![
                    "economy".to_string(),
                    "balanced".to_string(),
                    "advanced".to_string(),
                ],
            );
        }
        roles.insert(
            "security_reviewer".to_string(),
            vec!["advanced".to_string()],
        );
        for r in ["debugging", "architecture_reviewer", "performance_reviewer"] {
            roles.insert(
                r.to_string(),
                vec!["balanced".to_string(), "advanced".to_string()],
            );
        }

        Self {
            models: ModelsConfig {
                routing: ModelRoutingMode::Adaptive,
                auto_escalate: true,
                max_escalations: 2,
                fallback: ModelFallback::Next,
                tiers: ModelTiers {
                    economy: "auto".to_string(),
                    balanced: "auto".to_string(),
                    advanced: "auto".to_string(),
                },
                roles,
                hosts: BTreeMap::new(),
            },
            planning: PlanningConfig {
                clarification_gate: true,
                understanding_threshold: 96,
            },
            parallel: ParallelConfig {
                max_concurrency: MaxConcurrency::Auto,
                execution_mode: ExecutionMode::Auto,
            },
            review: ReviewConfig {
                max_iterations: 5,
                max_loc_per_unit: 5000,
                max_files_per_unit: 100,
                sizing: ReviewSizingConfig::default(),
            },
        }
    }
}

#[derive(Debug, Clone)]
pub struct ResolvedConfig {
    pub config: B3Config,
    pub sources: BTreeMap<String, ConfigSource>,
    pub warnings: Vec<String>,
    pub personal_path: PathBuf,
    pub project_path: Option<PathBuf>,
    pub files_read: usize,
}

fn default_sources() -> BTreeMap<String, ConfigSource> {
    let mut s = BTreeMap::new();
    for k in [
        "models.routing",
        "models.auto_escalate",
        "models.max_escalations",
        "models.fallback",
        "models.tiers.economy",
        "models.tiers.balanced",
        "models.tiers.advanced",
        "planning.clarification_gate",
        "planning.understanding_threshold",
        "parallel.max_concurrency",
        "parallel.execution_mode",
        "review.max_iterations",
        "review.max_loc_per_unit",
        "review.max_files_per_unit",
        "review.sizing.xs_max_loc",
        "review.sizing.xs_max_files",
        "review.sizing.s_max_loc",
        "review.sizing.s_max_files",
        "review.sizing.m_max_loc",
        "review.sizing.m_max_files",
        "review.sizing.l_max_loc",
        "review.sizing.l_max_files",
        "review.sizing.xl_max_loc",
        "review.sizing.xl_max_files",
    ] {
        s.insert(k.to_string(), ConfigSource::Default);
    }
    for r in ROLE_NAMES {
        s.insert(format!("models.roles.{r}"), ConfigSource::Default);
    }
    s
}

fn is_unc_or_control(raw: &str) -> bool {
    let trimmed = raw.trim();
    has_control_chars(trimmed) || is_unc_or_network_path(trimmed, Path::new(trimmed))
}

pub fn resolve_user_home_for_config(user_home: Option<&Path>) -> PathBuf {
    resolve_user_home_checked(user_home).unwrap_or_else(|_| PathBuf::from("."))
}

fn resolve_user_home_checked(user_home: Option<&Path>) -> Result<PathBuf, String> {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    if let Some(h) = user_home {
        let s = h.to_string_lossy();
        let trimmed = s.trim();
        if !trimmed.is_empty() {
            if is_unc_or_control(trimmed) {
                return Err(
                    "ignoring unsafe --user-home path (UNC/network or control chars)".to_string(),
                );
            }
            let cand = PathBuf::from(trimmed);
            if has_reparse_in_path_steps(&cwd, &cand) {
                return Err(
                    "ignoring unsafe --user-home path (symlink or reparse point)".to_string(),
                );
            }
            return Ok(resolve_unresolved_path(&cwd, trimmed));
        }
    }
    for env_key in ["USERPROFILE", "HOME"] {
        if let Ok(raw) = std::env::var(env_key) {
            let trimmed = raw.trim();
            if trimmed.is_empty() {
                continue;
            }
            if is_unc_or_control(trimmed) {
                return Err(format!(
                    "ignoring unsafe {env_key} home path (UNC/network or control chars)"
                ));
            }
            let cand = PathBuf::from(trimmed);
            if has_reparse_in_path_steps(&cwd, &cand) {
                return Err(format!(
                    "ignoring unsafe {env_key} home path (symlink or reparse point)"
                ));
            }
            return Ok(resolve_unresolved_path(&cwd, trimmed));
        }
    }
    Ok(PathBuf::from("."))
}

pub fn resolve_personal_config_path(user_home: Option<&Path>) -> Result<PathBuf, String> {
    if let Ok(env_p) = std::env::var("B3_CONFIG_PERSONAL") {
        let trimmed = env_p.trim();
        if !trimmed.is_empty() {
            if is_unc_or_control(trimmed) {
                return Err(
                    "ignoring unsafe B3_CONFIG_PERSONAL path (UNC/network or control chars)"
                        .to_string(),
                );
            }
            let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
            let cand = PathBuf::from(trimmed);
            if has_reparse_in_path_steps(&cwd, &cand) {
                return Err(
                    "ignoring unsafe B3_CONFIG_PERSONAL path (symlink or reparse point)"
                        .to_string(),
                );
            }
            return Ok(resolve_unresolved_path(&cwd, trimmed));
        }
    }
    Ok(resolve_user_home_checked(user_home)?
        .join(".b3")
        .join("config.toml"))
}

fn path_has_reparse(path: &Path) -> bool {
    if let Ok(cwd) = std::env::current_dir() {
        has_reparse_in_path_steps(&cwd, path)
    } else {
        is_reparse_or_symlink(path) || find_reparse_in_path_hierarchy(path).is_some()
    }
}

fn read_toml_if_safe(path: &Path, label: &str) -> Option<Result<TomlDocument, String>> {
    if !path.exists() && !is_reparse_or_symlink(path) {
        return None;
    }
    if path_has_reparse(path) {
        return Some(Err(format!(
            "ignoring {label} at {} (symlink or reparse point rejected)",
            path.display()
        )));
    }
    if !path.is_file() {
        return Some(Err(format!(
            "ignoring {label} at {} (not a regular file)",
            path.display()
        )));
    }
    match fs::read_to_string(path) {
        Ok(raw) => match parse_toml_strict(&raw) {
            Ok(doc) => Some(Ok(doc)),
            Err(e) => Some(Err(format!(
                "invalid TOML in {label} ({}): {e}",
                path.display()
            ))),
        },
        Err(e) => Some(Err(format!(
            "cannot read {label} ({}): {e}",
            path.display()
        ))),
    }
}

fn validate_role_list(arr: &[TomlValue]) -> Result<Vec<String>, String> {
    if arr.is_empty() || arr.len() > 3 {
        return Err("role preference array must have 1 to 3 entries".to_string());
    }
    let mut out = Vec::with_capacity(arr.len());
    for item in arr {
        let Some(s) = item.as_str() else {
            return Err("role preference entries must be strings".to_string());
        };
        let t = s.trim();
        if t.is_empty() || has_control_chars(t) {
            return Err(
                "role preference entry must be a non-empty string without control chars"
                    .to_string(),
            );
        }
        out.push(t.to_string());
    }
    Ok(out)
}

fn validate_tier_value(s: &str) -> Result<String, String> {
    let t = s.trim();
    if t.is_empty() || has_control_chars(t) {
        return Err("tier model identifier must be non-empty without control chars".to_string());
    }
    Ok(t.to_string())
}

fn canonical_role_key(raw: &str) -> Option<&'static str> {
    let k = raw.trim();
    match k {
        "main" => Some("main"),
        "planning" => Some("planning"),
        "implementation" => Some("implementation"),
        "debugging" => Some("debugging"),
        "research" => Some("research"),
        "reviewer" | "b3-reviewer" => Some("reviewer"),
        "fixer" | "b3-fixer" => Some("fixer"),
        "security_reviewer" | "b3-security-reviewer" => Some("security_reviewer"),
        "architecture_reviewer" | "b3-architecture-reviewer" => Some("architecture_reviewer"),
        "performance_reviewer" | "b3-performance-reviewer" => Some("performance_reviewer"),
        _ => None,
    }
}

fn apply_doc(
    doc: &TomlDocument,
    layer: ConfigSource,
    label: &str,
    cfg: &mut B3Config,
    sources: &mut BTreeMap<String, ConfigSource>,
    warnings: &mut Vec<String>,
) {
    for (tbl_name, tbl) in &doc.tables {
        match tbl_name.as_str() {
            "models" => {
                for (k, v) in tbl {
                    match k.as_str() {
                        "routing" => {
                            if let Some(mode) = v.as_str().and_then(ModelRoutingMode::parse) {
                                cfg.models.routing = mode;
                                sources.insert("models.routing".to_string(), layer);
                            } else {
                                warnings.push(format!(
                                    "{label}: invalid models.routing; keeping previous value"
                                ));
                            }
                        }
                        "auto_escalate" => {
                            if let Some(b) = v.as_bool() {
                                cfg.models.auto_escalate = b;
                                sources.insert("models.auto_escalate".to_string(), layer);
                            } else {
                                warnings.push(format!(
                                    "{label}: invalid models.auto_escalate; keeping previous value"
                                ));
                            }
                        }
                        "max_escalations" => {
                            if let Some(n) = v.as_i64().filter(|n| (0..=2).contains(n)) {
                                cfg.models.max_escalations = n as u8;
                                sources.insert("models.max_escalations".to_string(), layer);
                            } else {
                                warnings.push(format!("{label}: invalid models.max_escalations (expected 0-2); keeping previous value"));
                            }
                        }
                        "fallback" => {
                            if let Some(fb) = v.as_str().and_then(ModelFallback::parse) {
                                cfg.models.fallback = fb;
                                sources.insert("models.fallback".to_string(), layer);
                            } else {
                                warnings.push(format!(
                                    "{label}: invalid models.fallback; keeping previous value"
                                ));
                            }
                        }
                        other => warnings.push(format!("{label}: unknown key models.{other}")),
                    }
                }
            }
            "models.tiers" => {
                for (k, v) in tbl {
                    match k.as_str() {
                        "economy" | "balanced" | "advanced" => {
                            if let Some(Ok(val)) = v.as_str().map(validate_tier_value) {
                                match k.as_str() {
                                    "economy" => cfg.models.tiers.economy = val,
                                    "balanced" => cfg.models.tiers.balanced = val,
                                    "advanced" => cfg.models.tiers.advanced = val,
                                    _ => {}
                                }
                                sources.insert(format!("models.tiers.{k}"), layer);
                            } else {
                                warnings.push(format!(
                                    "{label}: invalid models.tiers.{k}; keeping previous value"
                                ));
                            }
                        }
                        other => {
                            warnings.push(format!("{label}: unknown key models.tiers.{other}"))
                        }
                    }
                }
            }
            "models.roles" => {
                for (k, v) in tbl {
                    let Some(role_k) = canonical_role_key(k) else {
                        warnings.push(format!("{label}: unknown key models.roles.{k}"));
                        continue;
                    };
                    match v {
                        TomlValue::Array(arr) => match validate_role_list(arr) {
                            Ok(list) => {
                                cfg.models.roles.insert(role_k.to_string(), list);
                                sources.insert(format!("models.roles.{role_k}"), layer);
                            }
                            Err(e) => warnings.push(format!("{label}: models.roles.{role_k}: {e}")),
                        },
                        TomlValue::Str(s) => match validate_tier_value(s) {
                            Ok(single) => {
                                cfg.models.roles.insert(role_k.to_string(), vec![single]);
                                sources.insert(format!("models.roles.{role_k}"), layer);
                            }
                            Err(e) => warnings.push(format!("{label}: models.roles.{role_k}: {e}")),
                        },
                        _ => warnings.push(format!("{label}: invalid models.roles.{role_k}; expected 1-3 entry string array")),
                    }
                }
            }
            t if t.starts_with("models.hosts.") => {
                let rest = &t["models.hosts.".len()..];
                if let Some((host_raw, sub)) = rest.split_once('.') {
                    let host = canonical_host_key(host_raw);
                    if host_raw.trim().is_empty() || sub != "roles" {
                        warnings.push(format!("{label}: unknown table [{t}]"));
                        continue;
                    }
                    for (k, v) in tbl {
                        let Some(role_k) = canonical_role_key(k) else {
                            warnings.push(format!("{label}: unknown key {t}.{k}"));
                            continue;
                        };
                        let parsed = match v {
                            TomlValue::Array(arr) => validate_role_list(arr),
                            TomlValue::Str(s) => validate_tier_value(s).map(|x| vec![x]),
                            _ => Err("expected string array".to_string()),
                        };
                        match parsed {
                            Ok(list) => {
                                cfg.models
                                    .hosts
                                    .entry(host.clone())
                                    .or_default()
                                    .roles
                                    .insert(role_k.to_string(), list);
                                sources
                                    .insert(format!("models.hosts.{host}.roles.{role_k}"), layer);
                            }
                            Err(e) => warnings.push(format!("{label}: {t}.{role_k}: {e}")),
                        }
                    }
                } else {
                    if rest.trim().is_empty() {
                        warnings.push(format!("{label}: invalid empty host table [{t}]"));
                        continue;
                    }
                    let host = canonical_host_key(rest);
                    for (k, v) in tbl {
                        if matches!(k.as_str(), "economy" | "balanced" | "advanced") {
                            if let Some(Ok(val)) = v.as_str().map(validate_tier_value) {
                                cfg.models
                                    .hosts
                                    .entry(host.clone())
                                    .or_default()
                                    .tiers
                                    .insert(k.clone(), val);
                                sources.insert(format!("models.hosts.{host}.{k}"), layer);
                            } else {
                                warnings.push(format!("{label}: invalid {t}.{k}"));
                            }
                        } else {
                            warnings.push(format!("{label}: unknown key {t}.{k}"));
                        }
                    }
                }
            }
            "planning" => {
                for (k, v) in tbl {
                    match k.as_str() {
                        "clarification_gate" => {
                            if let Some(b) = v.as_bool() {
                                cfg.planning.clarification_gate = b;
                                sources.insert("planning.clarification_gate".to_string(), layer);
                            } else {
                                warnings.push(format!("{label}: invalid planning.clarification_gate; keeping previous value"));
                            }
                        }
                        "understanding_threshold" => {
                            if let Some(n) = v.as_i64().filter(|n| (1..=100).contains(n)) {
                                cfg.planning.understanding_threshold = n as u8;
                                sources
                                    .insert("planning.understanding_threshold".to_string(), layer);
                            } else {
                                warnings.push(format!("{label}: invalid planning.understanding_threshold (expected 1-100); keeping previous value"));
                            }
                        }
                        other => warnings.push(format!("{label}: unknown key planning.{other}")),
                    }
                }
            }
            "parallel" => {
                for (k, v) in tbl {
                    match k.as_str() {
                        "max_concurrency" => {
                            if let Some(mc) = MaxConcurrency::parse_toml(v) {
                                cfg.parallel.max_concurrency = mc;
                                sources.insert("parallel.max_concurrency".to_string(), layer);
                            } else {
                                warnings.push(format!("{label}: invalid parallel.max_concurrency (expected \"auto\" or 1-64); keeping previous value"));
                            }
                        }
                        "execution_mode" => {
                            if let Some(em) = v.as_str().and_then(ExecutionMode::parse) {
                                cfg.parallel.execution_mode = em;
                                sources.insert("parallel.execution_mode".to_string(), layer);
                            } else {
                                warnings.push(format!("{label}: invalid parallel.execution_mode; keeping previous value"));
                            }
                        }
                        other => warnings.push(format!("{label}: unknown key parallel.{other}")),
                    }
                }
            }
            "review" => {
                for (k, v) in tbl {
                    match k.as_str() {
                        "max_iterations" => {
                            if let Some(n) = v.as_i64().filter(|n| (1..=20).contains(n)) {
                                cfg.review.max_iterations = n as u32;
                                sources.insert("review.max_iterations".to_string(), layer);
                            } else {
                                warnings.push(format!("{label}: invalid review.max_iterations (expected 1-20); keeping previous value"));
                            }
                        }
                        "max_loc_per_unit" => {
                            if let Some(n) = v.as_i64().filter(|n| (100..=50_000).contains(n)) {
                                cfg.review.max_loc_per_unit = n as usize;
                                sources.insert("review.max_loc_per_unit".to_string(), layer);
                            } else {
                                warnings.push(format!("{label}: invalid review.max_loc_per_unit (expected 100-50000); keeping previous value"));
                            }
                        }
                        "max_files_per_unit" => {
                            if let Some(n) = v.as_i64().filter(|n| (5..=1000).contains(n)) {
                                cfg.review.max_files_per_unit = n as usize;
                                sources.insert("review.max_files_per_unit".to_string(), layer);
                            } else {
                                warnings.push(format!("{label}: invalid review.max_files_per_unit (expected 5-1000); keeping previous value"));
                            }
                        }
                        other => warnings.push(format!("{label}: unknown key review.{other}")),
                    }
                }
            }
            "review.sizing" => {
                let mut candidate = cfg.review.sizing.clone();
                let mut updated_keys = Vec::new();
                for (k, v) in tbl {
                    let Some(n) = v.as_i64().filter(|n| *n > 0) else {
                        warnings.push(format!(
                            "{label}: invalid positive integer for review.sizing.{k}"
                        ));
                        continue;
                    };
                    let val = n as usize;
                    match k.as_str() {
                        "xs_max_loc" => candidate.xs_max_loc = val,
                        "xs_max_files" => candidate.xs_max_files = val,
                        "s_max_loc" => candidate.s_max_loc = val,
                        "s_max_files" => candidate.s_max_files = val,
                        "m_max_loc" => candidate.m_max_loc = val,
                        "m_max_files" => candidate.m_max_files = val,
                        "l_max_loc" => candidate.l_max_loc = val,
                        "l_max_files" => candidate.l_max_files = val,
                        "xl_max_loc" => candidate.xl_max_loc = val,
                        "xl_max_files" => candidate.xl_max_files = val,
                        other => {
                            warnings.push(format!("{label}: unknown key review.sizing.{other}"));
                            continue;
                        }
                    }
                    updated_keys.push(k.clone());
                }
                if !updated_keys.is_empty() {
                    if let Err(e) = candidate.validate() {
                        warnings.push(format!(
                            "{label}: {e}; reverting review.sizing to previous valid layer"
                        ));
                    } else {
                        cfg.review.sizing = candidate;
                        for k in updated_keys {
                            sources.insert(format!("review.sizing.{k}"), layer);
                        }
                    }
                }
            }
            other => {
                let disp = if other.is_empty() { "<root>" } else { other };
                warnings.push(format!("{label}: unknown section [{disp}]"));
            }
        }
    }
}

fn apply_string_override(
    key: &str,
    raw_val: &str,
    layer: ConfigSource,
    label: &str,
    cfg: &mut B3Config,
    sources: &mut BTreeMap<String, ConfigSource>,
    warnings: &mut Vec<String>,
) {
    let k = key.trim();
    let v = raw_val.trim();
    match k {
        "models.routing" => {
            if let Some(m) = ModelRoutingMode::parse(v) {
                cfg.models.routing = m;
                sources.insert(k.to_string(), layer);
            } else {
                warnings.push(format!("{label}: invalid {k}='{v}'"));
            }
        }
        "models.auto_escalate" => {
            if let Ok(b) = v.to_ascii_lowercase().parse::<bool>() {
                cfg.models.auto_escalate = b;
                sources.insert(k.to_string(), layer);
            } else {
                warnings.push(format!("{label}: invalid {k}='{v}'"));
            }
        }
        "models.max_escalations" => {
            if let Some(n) = v.parse::<u8>().ok().filter(|n| *n <= 2) {
                cfg.models.max_escalations = n;
                sources.insert(k.to_string(), layer);
            } else {
                warnings.push(format!("{label}: invalid {k}='{v}'"));
            }
        }
        "models.fallback" => {
            if let Some(f) = ModelFallback::parse(v) {
                cfg.models.fallback = f;
                sources.insert(k.to_string(), layer);
            } else {
                warnings.push(format!("{label}: invalid {k}='{v}'"));
            }
        }
        "planning.clarification_gate" => {
            if let Ok(b) = v.to_ascii_lowercase().parse::<bool>() {
                cfg.planning.clarification_gate = b;
                sources.insert(k.to_string(), layer);
            } else {
                warnings.push(format!("{label}: invalid {k}='{v}'"));
            }
        }
        "planning.understanding_threshold" => {
            if let Some(n) = v.parse::<u8>().ok().filter(|n| (1..=100).contains(n)) {
                cfg.planning.understanding_threshold = n;
                sources.insert(k.to_string(), layer);
            } else {
                warnings.push(format!("{label}: invalid {k}='{v}'"));
            }
        }
        "parallel.max_concurrency" => {
            if let Some(mc) = MaxConcurrency::parse_str(v) {
                cfg.parallel.max_concurrency = mc;
                sources.insert(k.to_string(), layer);
            } else {
                warnings.push(format!("{label}: invalid {k}='{v}'"));
            }
        }
        "parallel.execution_mode" => {
            if let Some(em) = ExecutionMode::parse(v) {
                cfg.parallel.execution_mode = em;
                sources.insert(k.to_string(), layer);
            } else {
                warnings.push(format!("{label}: invalid {k}='{v}'"));
            }
        }
        "review.max_iterations" => {
            if let Some(n) = v.parse::<u32>().ok().filter(|n| (1..=20).contains(n)) {
                cfg.review.max_iterations = n;
                sources.insert(k.to_string(), layer);
            } else {
                warnings.push(format!("{label}: invalid {k}='{v}'"));
            }
        }
        "review.max_loc_per_unit" => {
            if let Some(n) = v
                .parse::<usize>()
                .ok()
                .filter(|n| (100..=50_000).contains(n))
            {
                cfg.review.max_loc_per_unit = n;
                sources.insert(k.to_string(), layer);
            } else {
                warnings.push(format!("{label}: invalid {k}='{v}'"));
            }
        }
        "review.max_files_per_unit" => {
            if let Some(n) = v.parse::<usize>().ok().filter(|n| (5..=1000).contains(n)) {
                cfg.review.max_files_per_unit = n;
                sources.insert(k.to_string(), layer);
            } else {
                warnings.push(format!("{label}: invalid {k}='{v}'"));
            }
        }
        _ => {
            if let Ok(toml_val) = parse_cli_value_for_key(k, v) {
                let mut mini_doc = TomlDocument::default();
                let (tbl, fld) = k.rsplit_once('.').unwrap_or(("", k));
                mini_doc
                    .tables
                    .entry(tbl.to_string())
                    .or_default()
                    .insert(fld.to_string(), toml_val);
                apply_doc(&mini_doc, layer, label, cfg, sources, warnings);
            } else {
                warnings.push(format!("{label}: invalid override {k}='{v}'"));
            }
        }
    }
}

/// Resolves effective preferences once per invocation using the strict 5-layer precedence:
/// `invocation > env > project config > personal config > built-in defaults`.
pub fn resolve_config(
    repo_root: Option<&Path>,
    user_home: Option<&Path>,
    invocation_overrides: &[(String, String)],
) -> ResolvedConfig {
    let mut cfg = B3Config::default();
    let mut sources = default_sources();
    let mut warnings = Vec::new();
    let mut files_read = 0usize;

    let personal_path = match resolve_personal_config_path(user_home) {
        Ok(p) => p,
        Err(msg) => {
            warnings.push(msg);
            resolve_user_home_for_config(user_home)
                .join(".b3")
                .join("config.toml")
        }
    };

    if let Some(res) = read_toml_if_safe(&personal_path, "personal config") {
        files_read += 1;
        match res {
            Ok(doc) => apply_doc(
                &doc,
                ConfigSource::Personal,
                "personal",
                &mut cfg,
                &mut sources,
                &mut warnings,
            ),
            Err(e) => warnings.push(e),
        }
    }

    let project_path = repo_root.map(|r| r.join(".b3").join("config.toml"));
    if let Some(ref proj_p) = project_path {
        if let Some(res) = read_toml_if_safe(proj_p, "project config") {
            files_read += 1;
            match res {
                Ok(doc) => apply_doc(
                    &doc,
                    ConfigSource::Project,
                    "project",
                    &mut cfg,
                    &mut sources,
                    &mut warnings,
                ),
                Err(e) => warnings.push(e),
            }
        }
    }

    for (env_name, dot_key) in [
        ("B3_MODEL_ROUTING", "models.routing"),
        ("B3_MAX_CONCURRENCY", "parallel.max_concurrency"),
        ("B3_EXECUTION_MODE", "parallel.execution_mode"),
        ("B3_CLARIFICATION_GATE", "planning.clarification_gate"),
        (
            "B3_UNDERSTANDING_THRESHOLD",
            "planning.understanding_threshold",
        ),
    ] {
        if let Ok(val) = std::env::var(env_name) {
            let trimmed = val.trim();
            if !trimmed.is_empty() {
                apply_string_override(
                    dot_key,
                    trimmed,
                    ConfigSource::Env,
                    env_name,
                    &mut cfg,
                    &mut sources,
                    &mut warnings,
                );
            }
        }
    }

    for (k, v) in invocation_overrides {
        apply_string_override(
            k,
            v,
            ConfigSource::Invocation,
            "invocation",
            &mut cfg,
            &mut sources,
            &mut warnings,
        );
    }

    ResolvedConfig {
        config: cfg,
        sources,
        warnings,
        personal_path,
        project_path,
        files_read,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ComplexityLevel {
    Low,
    Medium,
    High,
}

impl ComplexityLevel {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
        }
    }

    pub fn parse(s: &str) -> Result<Self, String> {
        match s.trim().to_ascii_lowercase().as_str() {
            "low" | "l1" => Ok(Self::Low),
            "medium" | "med" | "l2" => Ok(Self::Medium),
            "high" | "l3" => Ok(Self::High),
            other => Err(format!(
                "invalid complexity '{other}'; expected low|medium|high"
            )),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum RiskTier {
    Low = 1,
    Medium = 2,
    High = 3,
    Critical = 4,
}

impl RiskTier {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Low => "LOW",
            Self::Medium => "MEDIUM",
            Self::High => "HIGH",
            Self::Critical => "CRITICAL",
        }
    }

    pub fn parse(s: &str) -> Result<Self, String> {
        match s.trim().to_ascii_uppercase().as_str() {
            "LOW" => Ok(Self::Low),
            "MEDIUM" => Ok(Self::Medium),
            "HIGH" => Ok(Self::High),
            "CRITICAL" => Ok(Self::Critical),
            other => Err(format!(
                "invalid risk '{other}'; expected LOW|MEDIUM|HIGH|CRITICAL"
            )),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EscalationTrigger {
    RepeatedReasoningFailure,
    DesignContradiction,
    SystemicReviewFinding,
    ComplexityIncrease,
    RiskIncrease,
    HypothesesExhausted,
    OrdinaryTestFailure,
    MissingDependency,
    EnvironmentSetup,
    FlakyInfra,
    NetworkFailure,
    BaselineFailure,
}

impl EscalationTrigger {
    pub fn parse(s: &str) -> Result<Self, String> {
        match s.trim().to_ascii_lowercase().as_str() {
            "repeated_reasoning_failure" => Ok(Self::RepeatedReasoningFailure),
            "design_contradiction" => Ok(Self::DesignContradiction),
            "systemic_review_finding" => Ok(Self::SystemicReviewFinding),
            "complexity_increase" => Ok(Self::ComplexityIncrease),
            "risk_increase" => Ok(Self::RiskIncrease),
            "hypotheses_exhausted" => Ok(Self::HypothesesExhausted),
            "ordinary_test_failure" => Ok(Self::OrdinaryTestFailure),
            "missing_dependency" => Ok(Self::MissingDependency),
            "environment_setup" => Ok(Self::EnvironmentSetup),
            "flaky_infra" => Ok(Self::FlakyInfra),
            "network_failure" => Ok(Self::NetworkFailure),
            "baseline_failure" => Ok(Self::BaselineFailure),
            other => Err(format!("unknown escalation trigger '{other}'")),
        }
    }

    pub fn is_valid_reasoning_trigger(&self) -> bool {
        matches!(
            self,
            Self::RepeatedReasoningFailure
                | Self::DesignContradiction
                | Self::SystemicReviewFinding
                | Self::ComplexityIncrease
                | Self::RiskIncrease
                | Self::HypothesesExhausted
        )
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::RepeatedReasoningFailure => "repeated_reasoning_failure",
            Self::DesignContradiction => "design_contradiction",
            Self::SystemicReviewFinding => "systemic_review_finding",
            Self::ComplexityIncrease => "complexity_increase",
            Self::RiskIncrease => "risk_increase",
            Self::HypothesesExhausted => "hypotheses_exhausted",
            Self::OrdinaryTestFailure => "ordinary_test_failure",
            Self::MissingDependency => "missing_dependency",
            Self::EnvironmentSetup => "environment_setup",
            Self::FlakyInfra => "flaky_infra",
            Self::NetworkFailure => "network_failure",
            Self::BaselineFailure => "baseline_failure",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostCapability {
    pub host: String,
    pub main_select: bool,
    pub subagent_select: bool,
}

fn canonical_host_key(host_raw: &str) -> String {
    let h = host_raw.trim().to_ascii_lowercase();
    match h.as_str() {
        "cursor-cli" | "cursor_cli" => "cursor_cli".to_string(),
        "claude-code" | "claude_code" | "claude" => "claude_code".to_string(),
        "" => "generic".to_string(),
        _ => h,
    }
}

pub fn host_capabilities(host_raw: &str) -> HostCapability {
    let host = canonical_host_key(host_raw);
    match host.as_str() {
        "cursor" | "codex" | "claude_code" | "antigravity" => HostCapability {
            host,
            main_select: true,
            subagent_select: true,
        },
        _ => HostCapability {
            host,
            main_select: true,
            subagent_select: false,
        },
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelRouteDecision {
    pub role: String,
    pub complexity: String,
    pub risk: String,
    pub selected_tier: String,
    pub requested_model: String,
    pub actual_model: String,
    pub selection_reason: String,
    pub fallback_reason: Option<String>,
    pub escalation_count: u8,
    pub capability_warning: Option<String>,
}

fn resolve_entry_model(cfg: &ModelsConfig, host: &str, entry: &str) -> (String, String) {
    let trimmed = entry.trim();
    if let Some(escaped) = trimmed.strip_prefix("model:") {
        let id = escaped.trim();
        return ("direct".to_string(), id.to_string());
    }
    let host_canon = canonical_host_key(host);
    match trimmed {
        "economy" | "balanced" | "advanced" => {
            let host_override = cfg
                .hosts
                .get(&host_canon)
                .and_then(|h| h.tiers.get(trimmed));
            let resolved = host_override
                .map(|s| s.as_str())
                .unwrap_or_else(|| match trimmed {
                    "economy" => cfg.tiers.economy.as_str(),
                    "balanced" => cfg.tiers.balanced.as_str(),
                    _ => cfg.tiers.advanced.as_str(),
                });
            (trimmed.to_string(), resolved.to_string())
        }
        "auto" => ("inherited".to_string(), "auto".to_string()),
        other => ("direct".to_string(), other.to_string()),
    }
}

/// Evaluates whether bounded escalation is permitted for a given trigger and current count.
pub fn evaluate_escalation(
    cfg: &ModelsConfig,
    role_raw: &str,
    host: &str,
    current_escalations: u8,
    trigger: EscalationTrigger,
) -> (bool, &'static str) {
    if !trigger.is_valid_reasoning_trigger() {
        return (false, "ignored_non_reasoning_trigger");
    }
    if !cfg.auto_escalate {
        return (false, "auto_escalate_disabled");
    }
    if current_escalations >= cfg.max_escalations {
        return (false, "max_escalations_reached");
    }
    let Some(role_k) = canonical_role_key(role_raw) else {
        return (false, "unknown_role");
    };
    let host_canon = canonical_host_key(host);
    let entries = cfg
        .hosts
        .get(&host_canon)
        .and_then(|h| h.roles.get(role_k))
        .or_else(|| cfg.roles.get(role_k));
    let len = entries.map(|v| v.len()).unwrap_or(0);
    if len <= 1 {
        return (false, "single_model_role_no_escalation_target");
    }
    (true, "escalated")
}

/// Deterministic adaptive model selection for a role, complexity, risk tier, and host.
#[allow(clippy::too_many_arguments)]
pub fn route_model(
    cfg: &B3Config,
    role_raw: &str,
    complexity: ComplexityLevel,
    risk: RiskTier,
    host: &str,
    requested_escalations: u8,
    available_models: Option<&[String]>,
    confirmed_model: Option<&str>,
) -> Result<ModelRouteDecision, String> {
    let role_k =
        canonical_role_key(role_raw).ok_or_else(|| format!("unknown model role '{role_raw}'"))?;
    let caps = host_capabilities(host);
    let escalation_count = if cfg.models.auto_escalate {
        requested_escalations.min(cfg.models.max_escalations)
    } else {
        0
    };

    if cfg.models.routing == ModelRoutingMode::Native {
        let actual = confirmed_model
            .filter(|s| !s.trim().is_empty())
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|| "INHERITED".to_string());
        return Ok(ModelRouteDecision {
            role: role_k.to_string(),
            complexity: complexity.as_str().to_string(),
            risk: risk.as_str().to_string(),
            selected_tier: "inherited".to_string(),
            requested_model: "auto".to_string(),
            actual_model: actual,
            selection_reason: "routing=native".to_string(),
            fallback_reason: None,
            escalation_count: 0,
            capability_warning: None,
        });
    }

    let entries = cfg
        .models
        .hosts
        .get(&caps.host)
        .and_then(|h| h.roles.get(role_k))
        .or_else(|| cfg.models.roles.get(role_k))
        .cloned()
        .unwrap_or_else(|| vec!["auto".to_string()]);

    let effective_band = if risk >= RiskTier::High {
        ComplexityLevel::High
    } else {
        complexity
    };

    let base_idx = match cfg.models.routing {
        ModelRoutingMode::Fixed => 0,
        ModelRoutingMode::Adaptive => match (entries.len(), effective_band) {
            (0 | 1, _) => 0,
            (2, ComplexityLevel::Low | ComplexityLevel::Medium) => 0,
            (2, ComplexityLevel::High) => 1,
            (_, ComplexityLevel::Low) => 0,
            (_, ComplexityLevel::Medium) => 1,
            (_, ComplexityLevel::High) => entries.len() - 1,
        },
        ModelRoutingMode::Native => 0,
    };

    let target_idx = if entries.len() > 1 {
        (base_idx + escalation_count as usize).min(entries.len() - 1)
    } else {
        0
    };

    let (mut selected_tier, mut requested_model) =
        resolve_entry_model(&cfg.models, host, &entries[target_idx]);
    let mut selection_reason = if cfg.models.routing == ModelRoutingMode::Fixed {
        format!("routing=fixed;entry={}", target_idx + 1)
    } else if risk >= RiskTier::High {
        format!(
            "routing=adaptive;risk={};complexity={};entry={}/{}",
            risk.as_str(),
            complexity.as_str(),
            target_idx + 1,
            entries.len()
        )
    } else {
        format!(
            "routing=adaptive;complexity={};entry={}/{}",
            complexity.as_str(),
            target_idx + 1,
            entries.len()
        )
    };
    if escalation_count > 0 && entries.len() > 1 {
        selection_reason.push_str(&format!(";escalated={escalation_count}"));
    }

    let mut fallback_reason = None;
    let mut capability_warning = None;

    if risk >= RiskTier::High && selected_tier == "economy" {
        capability_warning = Some(
            "HIGH/CRITICAL task mapped to single/economy entry; verify model capability before relying on result"
                .to_string(),
        );
    }

    if let Some(avail) = available_models {
        if requested_model != "auto" && !avail.iter().any(|m| m == &requested_model) {
            match cfg.models.fallback {
                ModelFallback::Next => {
                    let mut found = None;
                    for alt_idx in (target_idx + 1..entries.len()).chain(0..target_idx) {
                        let (alt_tier, alt_model) =
                            resolve_entry_model(&cfg.models, host, &entries[alt_idx]);
                        if alt_model == "auto" || avail.iter().any(|m| m == &alt_model) {
                            found = Some((alt_idx, alt_tier, alt_model));
                            break;
                        }
                    }
                    if let Some((alt_idx, alt_tier, alt_model)) = found {
                        if risk >= RiskTier::High && alt_tier == "economy" {
                            capability_warning = Some(format!(
                                "CAPABILITY_WARNING: fallback to lower tier '{}' on {} risk task because '{}' was unavailable",
                                alt_tier, risk.as_str(), requested_model
                            ));
                        }
                        fallback_reason = Some(format!(
                            "requested '{}' unavailable; used next entry {}",
                            requested_model,
                            alt_idx + 1
                        ));
                        selected_tier = alt_tier;
                        requested_model = alt_model;
                    } else {
                        if risk >= RiskTier::High {
                            capability_warning = Some(format!(
                                "CAPABILITY_WARNING: '{}' unavailable for {} risk task; falling back to native selection",
                                requested_model, risk.as_str()
                            ));
                        }
                        fallback_reason = Some(format!(
                            "requested '{}' unavailable; fell back to native auto",
                            requested_model
                        ));
                        selected_tier = "inherited".to_string();
                        requested_model = "auto".to_string();
                    }
                }
                ModelFallback::Native => {
                    if risk >= RiskTier::High {
                        capability_warning = Some(format!(
                            "CAPABILITY_WARNING: '{}' unavailable for {} risk task; native fallback used",
                            requested_model, risk.as_str()
                        ));
                    }
                    fallback_reason = Some(format!(
                        "requested '{}' unavailable; fallback=native",
                        requested_model
                    ));
                    selected_tier = "inherited".to_string();
                    requested_model = "auto".to_string();
                }
            }
        }
    }

    let can_switch_role = if role_k == "main" {
        caps.main_select
    } else {
        caps.subagent_select
    };
    if !can_switch_role && requested_model != "auto" {
        fallback_reason.get_or_insert_with(|| {
            format!(
                "host '{}' does not support switching role '{}' directly; native host inheritance applies",
                caps.host, role_k
            )
        });
    }

    let actual_model = if let Some(c) = confirmed_model.filter(|s| !s.trim().is_empty()) {
        c.trim().to_string()
    } else if requested_model == "auto" || !can_switch_role {
        "INHERITED".to_string()
    } else {
        "UNKNOWN".to_string()
    };

    Ok(ModelRouteDecision {
        role: role_k.to_string(),
        complexity: complexity.as_str().to_string(),
        risk: risk.as_str().to_string(),
        selected_tier,
        requested_model,
        actual_model,
        selection_reason,
        fallback_reason,
        escalation_count,
        capability_warning,
    })
}

fn is_forbidden_governance_key(key: &str) -> bool {
    let low = key.trim().to_ascii_lowercase();
    low.starts_with("policy.")
        || matches!(
            low.as_str(),
            "auto_merge"
                | "auto_merge_max_risk"
                | "protected_paths"
                | "allow_protected_paths"
                | "allowed_target_branches"
                | "require_ci"
                | "require_review"
        )
}

fn parse_cli_value_for_key(key: &str, raw: &str) -> Result<TomlValue, String> {
    let k = key.trim();
    let v = raw.trim();
    if is_forbidden_governance_key(k) {
        return Err(format!(
            "CONFIG_FORBIDDEN: '{k}' belongs to governance policy (.b3/policy.toml) and cannot be modified via b3 config set"
        ));
    }
    match k {
        "models.routing" => {
            ModelRoutingMode::parse(v).ok_or_else(|| format!("invalid models.routing '{v}'"))?;
            Ok(TomlValue::Str(v.to_ascii_lowercase()))
        }
        "models.fallback" => {
            ModelFallback::parse(v).ok_or_else(|| format!("invalid models.fallback '{v}'"))?;
            Ok(TomlValue::Str(v.to_ascii_lowercase()))
        }
        "models.auto_escalate" | "planning.clarification_gate" => {
            let b = v
                .to_ascii_lowercase()
                .parse::<bool>()
                .map_err(|_| format!("invalid boolean '{v}' for {k}"))?;
            Ok(TomlValue::Bool(b))
        }
        "models.max_escalations" => {
            let n = v
                .parse::<i64>()
                .ok()
                .filter(|n| (0..=2).contains(n))
                .ok_or_else(|| format!("invalid integer (0-2) '{v}' for {k}"))?;
            Ok(TomlValue::Int(n))
        }
        "planning.understanding_threshold" => {
            let n = v
                .parse::<i64>()
                .ok()
                .filter(|n| (1..=100).contains(n))
                .ok_or_else(|| format!("invalid integer (1-100) '{v}' for {k}"))?;
            Ok(TomlValue::Int(n))
        }
        "parallel.max_concurrency" => {
            if v.eq_ignore_ascii_case("auto") {
                Ok(TomlValue::Str("auto".to_string()))
            } else {
                let n = v
                    .parse::<i64>()
                    .ok()
                    .filter(|n| (1..=64).contains(n))
                    .ok_or_else(|| {
                        format!("invalid max_concurrency '{v}' (expected auto or 1-64)")
                    })?;
                Ok(TomlValue::Int(n))
            }
        }
        "parallel.execution_mode" => {
            ExecutionMode::parse(v)
                .ok_or_else(|| format!("invalid parallel.execution_mode '{v}'"))?;
            Ok(TomlValue::Str(v.to_ascii_lowercase()))
        }
        "review.max_iterations" => {
            let n = v
                .parse::<i64>()
                .ok()
                .filter(|n| (1..=20).contains(n))
                .ok_or_else(|| format!("invalid integer (1-20) '{v}' for {k}"))?;
            Ok(TomlValue::Int(n))
        }
        "review.max_loc_per_unit" => {
            let n = v
                .parse::<i64>()
                .ok()
                .filter(|n| (100..=50_000).contains(n))
                .ok_or_else(|| format!("invalid integer (100-50000) '{v}' for {k}"))?;
            Ok(TomlValue::Int(n))
        }
        "review.max_files_per_unit" => {
            let n = v
                .parse::<i64>()
                .ok()
                .filter(|n| (5..=1000).contains(n))
                .ok_or_else(|| format!("invalid integer (5-1000) '{v}' for {k}"))?;
            Ok(TomlValue::Int(n))
        }
        s if s.starts_with("review.sizing.")
            && matches!(
                s.strip_prefix("review.sizing."),
                Some(
                    "xs_max_loc"
                        | "xs_max_files"
                        | "s_max_loc"
                        | "s_max_files"
                        | "m_max_loc"
                        | "m_max_files"
                        | "l_max_loc"
                        | "l_max_files"
                        | "xl_max_loc"
                        | "xl_max_files"
                )
            ) =>
        {
            let n = v
                .parse::<i64>()
                .ok()
                .filter(|n| *n > 0)
                .ok_or_else(|| format!("invalid positive integer '{v}' for {k}"))?;
            Ok(TomlValue::Int(n))
        }
        "models.tiers.economy" | "models.tiers.balanced" | "models.tiers.advanced" => {
            let clean = validate_tier_value(v)?;
            Ok(TomlValue::Str(clean))
        }
        s if s.starts_with("models.roles.") => {
            let r = &s["models.roles.".len()..];
            if canonical_role_key(r) != Some(r) {
                return Err(format!("unknown role key '{k}'"));
            }
            parse_role_array_arg(v)
        }
        s if s.starts_with("models.hosts.") => {
            let rest = &s["models.hosts.".len()..];
            if let Some((host, sub)) = rest.split_once(".roles.") {
                if host.is_empty() || canonical_role_key(sub) != Some(sub) {
                    return Err(format!("invalid host role key '{k}'"));
                }
                parse_role_array_arg(v)
            } else if let Some((host, tier)) = rest.split_once('.') {
                if host.is_empty() || !matches!(tier, "economy" | "balanced" | "advanced") {
                    return Err(format!("invalid host tier key '{k}'"));
                }
                Ok(TomlValue::Str(validate_tier_value(v)?))
            } else {
                Err(format!("invalid config key '{k}'"))
            }
        }
        _ => Err(format!("unknown config key '{k}'")),
    }
}

fn parse_role_array_arg(v: &str) -> Result<TomlValue, String> {
    let trimmed = v.trim();
    if trimmed.starts_with('[') {
        let doc = parse_toml_strict(&format!("items = {trimmed}\n"))
            .map_err(|e| format!("invalid TOML array '{trimmed}': {e}"))?;
        let Some(TomlValue::Array(arr)) = doc.get("", "items").cloned() else {
            return Err("expected string array".to_string());
        };
        let list = validate_role_list(&arr)?;
        return Ok(TomlValue::Array(
            list.into_iter().map(TomlValue::Str).collect(),
        ));
    }
    let parts: Vec<String> = trimmed
        .split(',')
        .map(|p| p.trim().trim_matches('"').trim_matches('\'').to_string())
        .filter(|p| !p.is_empty())
        .collect();
    if parts.is_empty() || parts.len() > 3 {
        return Err("role preference must contain 1 to 3 entries".to_string());
    }
    for p in &parts {
        validate_tier_value(p)?;
    }
    Ok(TomlValue::Array(
        parts.into_iter().map(TomlValue::Str).collect(),
    ))
}

fn get_effective_key_value(cfg: &B3Config, key: &str) -> Option<TomlValue> {
    match key.trim() {
        "models.routing" => Some(TomlValue::Str(cfg.models.routing.as_str().to_string())),
        "models.auto_escalate" => Some(TomlValue::Bool(cfg.models.auto_escalate)),
        "models.max_escalations" => Some(TomlValue::Int(cfg.models.max_escalations as i64)),
        "models.fallback" => Some(TomlValue::Str(cfg.models.fallback.as_str().to_string())),
        "models.tiers.economy" => Some(TomlValue::Str(cfg.models.tiers.economy.clone())),
        "models.tiers.balanced" => Some(TomlValue::Str(cfg.models.tiers.balanced.clone())),
        "models.tiers.advanced" => Some(TomlValue::Str(cfg.models.tiers.advanced.clone())),
        "planning.clarification_gate" => Some(TomlValue::Bool(cfg.planning.clarification_gate)),
        "planning.understanding_threshold" => {
            Some(TomlValue::Int(cfg.planning.understanding_threshold as i64))
        }
        "parallel.max_concurrency" => match cfg.parallel.max_concurrency {
            MaxConcurrency::Auto => Some(TomlValue::Str("auto".to_string())),
            MaxConcurrency::Fixed(n) => Some(TomlValue::Int(n as i64)),
        },
        "parallel.execution_mode" => Some(TomlValue::Str(
            cfg.parallel.execution_mode.as_str().to_string(),
        )),
        "review.max_iterations" => Some(TomlValue::Int(cfg.review.max_iterations as i64)),
        "review.max_loc_per_unit" => Some(TomlValue::Int(cfg.review.max_loc_per_unit as i64)),
        "review.max_files_per_unit" => Some(TomlValue::Int(cfg.review.max_files_per_unit as i64)),
        "review.sizing.xs_max_loc" => Some(TomlValue::Int(cfg.review.sizing.xs_max_loc as i64)),
        "review.sizing.xs_max_files" => Some(TomlValue::Int(cfg.review.sizing.xs_max_files as i64)),
        "review.sizing.s_max_loc" => Some(TomlValue::Int(cfg.review.sizing.s_max_loc as i64)),
        "review.sizing.s_max_files" => Some(TomlValue::Int(cfg.review.sizing.s_max_files as i64)),
        "review.sizing.m_max_loc" => Some(TomlValue::Int(cfg.review.sizing.m_max_loc as i64)),
        "review.sizing.m_max_files" => Some(TomlValue::Int(cfg.review.sizing.m_max_files as i64)),
        "review.sizing.l_max_loc" => Some(TomlValue::Int(cfg.review.sizing.l_max_loc as i64)),
        "review.sizing.l_max_files" => Some(TomlValue::Int(cfg.review.sizing.l_max_files as i64)),
        "review.sizing.xl_max_loc" => Some(TomlValue::Int(cfg.review.sizing.xl_max_loc as i64)),
        "review.sizing.xl_max_files" => Some(TomlValue::Int(cfg.review.sizing.xl_max_files as i64)),
        k if k.starts_with("models.roles.") => {
            let role = &k["models.roles.".len()..];
            cfg.models
                .roles
                .get(role)
                .map(|list| TomlValue::Array(list.iter().cloned().map(TomlValue::Str).collect()))
        }
        k if k.starts_with("models.hosts.") => {
            let rest = &k["models.hosts.".len()..];
            if let Some((host, sub)) = rest.split_once(".roles.") {
                cfg.models
                    .hosts
                    .get(&canonical_host_key(host))
                    .and_then(|h| h.roles.get(sub))
                    .map(|list| {
                        TomlValue::Array(list.iter().cloned().map(TomlValue::Str).collect())
                    })
            } else if let Some((host, tier)) = rest.split_once('.') {
                cfg.models
                    .hosts
                    .get(&canonical_host_key(host))
                    .and_then(|h| h.tiers.get(tier))
                    .map(|s| TomlValue::Str(s.clone()))
            } else {
                None
            }
        }
        _ => None,
    }
}

fn canonical_dot_keys(cfg: &B3Config) -> Vec<String> {
    let mut keys = vec![
        "models.routing".to_string(),
        "models.auto_escalate".to_string(),
        "models.max_escalations".to_string(),
        "models.fallback".to_string(),
        "models.tiers.economy".to_string(),
        "models.tiers.balanced".to_string(),
        "models.tiers.advanced".to_string(),
    ];
    for r in cfg.models.roles.keys() {
        keys.push(format!("models.roles.{r}"));
    }
    for (h, ov) in &cfg.models.hosts {
        for t in ov.tiers.keys() {
            keys.push(format!("models.hosts.{h}.{t}"));
        }
        for r in ov.roles.keys() {
            keys.push(format!("models.hosts.{h}.roles.{r}"));
        }
    }
    keys.extend([
        "planning.clarification_gate".to_string(),
        "planning.understanding_threshold".to_string(),
        "parallel.max_concurrency".to_string(),
        "parallel.execution_mode".to_string(),
        "review.max_iterations".to_string(),
        "review.max_loc_per_unit".to_string(),
        "review.max_files_per_unit".to_string(),
        "review.sizing.xs_max_loc".to_string(),
        "review.sizing.xs_max_files".to_string(),
        "review.sizing.s_max_loc".to_string(),
        "review.sizing.s_max_files".to_string(),
        "review.sizing.m_max_loc".to_string(),
        "review.sizing.m_max_files".to_string(),
        "review.sizing.l_max_loc".to_string(),
        "review.sizing.l_max_files".to_string(),
        "review.sizing.xl_max_loc".to_string(),
        "review.sizing.xl_max_files".to_string(),
    ]);
    keys
}

fn split_dot_key_for_toml(key: &str) -> Result<(String, String), String> {
    let trimmed = key.trim();
    if trimmed.starts_with("models.hosts.") {
        if let Some((tbl, field)) = trimmed.rsplit_once('.') {
            return Ok((tbl.to_string(), field.to_string()));
        }
    }
    let Some((tbl, field)) = trimmed.rsplit_once('.') else {
        return Err(format!(
            "expected dotted key <section>.<field>, got '{key}'"
        ));
    };
    Ok((tbl.to_string(), field.to_string()))
}

fn toml_val_to_json(val: &TomlValue) -> JsonValue {
    match val {
        TomlValue::Str(s) => JsonValue::String(s.clone()),
        TomlValue::Bool(b) => JsonValue::Bool(*b),
        TomlValue::Int(n) => JsonValue::num_i64(*n),
        TomlValue::Array(arr) => JsonValue::Array(arr.iter().map(toml_val_to_json).collect()),
    }
}

fn load_config_template(repo_root: Option<&Path>) -> String {
    if let Some(root) = repo_root {
        let p = root.join("config").join("config.example.toml");
        if p.is_file() && !path_has_reparse(&p) {
            if let Ok(raw) = fs::read_to_string(&p) {
                return raw.replace("\r\n", "\n");
            }
        }
    }
    DEFAULT_CONFIG_TEMPLATE.replace("\r\n", "\n")
}

/// Parses legacy `models.md` (`Role | Preferred Model` table + optional `planning:` YAML block).
struct ParsedLegacyModelsMd {
    roles: BTreeMap<String, String>,
    clarification_gate: Option<bool>,
    understanding_threshold: Option<u8>,
}

fn parse_legacy_models_md(raw: &str) -> ParsedLegacyModelsMd {
    let mut roles = BTreeMap::new();
    let mut clarification_gate = None;
    let mut understanding_threshold = None;
    let mut in_planning_yaml = false;

    for line in raw.replace("\r\n", "\n").lines() {
        let t = line.trim();
        if t.starts_with('|') {
            let cols: Vec<&str> = t.trim_matches('|').split('|').map(str::trim).collect();
            if cols.len() >= 2 {
                let raw_role = cols[0].trim_matches('`').trim();
                let raw_val = cols[1].trim_matches('`').trim();
                if let Some(canon) = canonical_role_key(raw_role) {
                    if !raw_val.is_empty() && raw_val != "---" {
                        roles.insert(canon.to_string(), raw_val.to_string());
                    }
                }
            }
        } else if t == "planning:" {
            in_planning_yaml = true;
        } else if in_planning_yaml {
            if t.starts_with("```")
                || (!line.starts_with(' ') && !line.starts_with('\t') && !t.is_empty())
            {
                in_planning_yaml = false;
                continue;
            }
            if let Some((k, v)) = t.split_once(':') {
                let val_clean = v.split('#').next().unwrap_or("").trim();
                match k.trim() {
                    "clarification_gate" => {
                        if let Ok(b) = val_clean.to_ascii_lowercase().parse::<bool>() {
                            clarification_gate = Some(b);
                        }
                    }
                    "understanding_threshold" => {
                        if let Some(n) = val_clean
                            .parse::<u8>()
                            .ok()
                            .filter(|n| (1..=100).contains(n))
                        {
                            understanding_threshold = Some(n);
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    ParsedLegacyModelsMd {
        roles,
        clarification_gate,
        understanding_threshold,
    }
}

fn write_config_new_safe(dest: &Path, body: &str, force: bool) -> Result<(), B3Error> {
    if path_has_reparse(dest) {
        return Err(fail(
            format!(
                "CONFIG_FAIL: refusing symlink/reparse path at {}",
                dest.display()
            ),
            1,
        ));
    }
    if let Some(parent) = dest.parent() {
        if path_has_reparse(parent) {
            return Err(fail(
                format!(
                    "CONFIG_FAIL: refusing symlink/reparse parent directory at {}",
                    parent.display()
                ),
                1,
            ));
        }
        fs::create_dir_all(parent).map_err(|e| {
            fail(
                format!("CONFIG_FAIL: cannot create {}: {e}", parent.display()),
                1,
            )
        })?;
    }
    let lf = body.replace("\r\n", "\n");
    if force {
        return write_atomic_lf(dest, &lf);
    }
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(dest)
        .map_err(|e| {
            fail(
                format!("CONFIG_FAIL: cannot create {}: {e}", dest.display()),
                1,
            )
        })?;
    file.write_all(lf.as_bytes()).map_err(|e| {
        fail(
            format!("CONFIG_FAIL: write failed for {}: {e}", dest.display()),
            1,
        )
    })?;
    file.sync_all().map_err(|e| {
        fail(
            format!("CONFIG_FAIL: flush failed for {}: {e}", dest.display()),
            1,
        )
    })?;
    Ok(())
}

/// CLI entrypoint for `b3 config <show|get|set|validate|init|migrate>`.
#[allow(clippy::too_many_arguments)]
pub fn run_config_cli(
    action: &str,
    repo_root_raw: Option<&str>,
    user_home_raw: Option<&str>,
    scope: Option<&str>,
    key: Option<&str>,
    value: Option<&str>,
    sources_flag: bool,
    json_flag: bool,
    dry_run: bool,
    force: bool,
    overrides: &[(String, String)],
    route_role: Option<&str>,
    route_complexity: Option<&str>,
    route_risk: Option<&str>,
    route_host: Option<&str>,
    route_escalations: u8,
    route_trigger: Option<&str>,
    route_available: Option<&str>,
    route_confirmed: Option<&str>,
) -> Result<(String, i32), B3Error> {
    let repo_root = match repo_root_raw {
        Some(r) if !r.trim().is_empty() => Some(normalize_repo_root(r)?),
        _ => std::env::current_dir()
            .ok()
            .and_then(|d| normalize_repo_root(&d.to_string_lossy()).ok())
            .filter(|d| {
                d.join(".b3").is_dir() || d.join(".git").exists() || d.join("AGENTS.md").is_file()
            }),
    };
    let user_home_pb = user_home_raw
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(PathBuf::from);
    let user_home_ref = user_home_pb.as_deref();

    match action {
        "show" => {
            let resolved = resolve_config(repo_root.as_deref(), user_home_ref, overrides);
            let keys = canonical_dot_keys(&resolved.config);
            if json_flag {
                let mut pairs = vec![
                    (
                        "personal_path".to_string(),
                        JsonValue::String(resolved.personal_path.display().to_string()),
                    ),
                    (
                        "project_path".to_string(),
                        resolved
                            .project_path
                            .as_ref()
                            .map(|p| JsonValue::String(p.display().to_string()))
                            .unwrap_or(JsonValue::Null),
                    ),
                    (
                        "files_read".to_string(),
                        JsonValue::num_u64(resolved.files_read as u64),
                    ),
                    (
                        "warnings".to_string(),
                        JsonValue::Array(
                            resolved
                                .warnings
                                .iter()
                                .cloned()
                                .map(JsonValue::String)
                                .collect(),
                        ),
                    ),
                ];
                let mut values_obj = Vec::new();
                let mut sources_obj = Vec::new();
                for k in &keys {
                    if let Some(v) = get_effective_key_value(&resolved.config, k) {
                        values_obj.push((k.clone(), toml_val_to_json(&v)));
                    }
                    let src = resolved
                        .sources
                        .get(k)
                        .copied()
                        .unwrap_or(ConfigSource::Default);
                    sources_obj.push((k.clone(), JsonValue::String(src.as_str().to_string())));
                }
                pairs.push(("values".to_string(), JsonValue::Object(values_obj)));
                if sources_flag {
                    pairs.push(("sources".to_string(), JsonValue::Object(sources_obj)));
                }
                return Ok((JsonValue::Object(pairs).to_json_pretty(), 0));
            }
            let mut out = Vec::new();
            out.push(format!(
                "personal_config: {}",
                resolved.personal_path.display()
            ));
            if let Some(ref pp) = resolved.project_path {
                out.push(format!("project_config: {}", pp.display()));
            }
            for w in &resolved.warnings {
                out.push(format!("warning: {w}"));
            }
            for k in &keys {
                if let Some(v) = get_effective_key_value(&resolved.config, k) {
                    let rendered = format_toml_value(&v);
                    if sources_flag {
                        let src = resolved
                            .sources
                            .get(k)
                            .copied()
                            .unwrap_or(ConfigSource::Default);
                        out.push(format!("{k} = {rendered}  # source={}", src.as_str()));
                    } else {
                        out.push(format!("{k} = {rendered}"));
                    }
                }
            }
            Ok((out.join("\n"), 0))
        }
        "get" => {
            let resolved = resolve_config(repo_root.as_deref(), user_home_ref, overrides);
            if let Some(role) = route_role {
                let comp = ComplexityLevel::parse(route_complexity.unwrap_or("medium"))
                    .map_err(|e| fail(format!("CONFIG_FAIL: {e}"), 1))?;
                let risk = RiskTier::parse(route_risk.unwrap_or("LOW"))
                    .map_err(|e| fail(format!("CONFIG_FAIL: {e}"), 1))?;
                let host = route_host.unwrap_or("generic");
                let eff_escalations = if let Some(tr_raw) = route_trigger {
                    let tr = EscalationTrigger::parse(tr_raw)
                        .map_err(|e| fail(format!("CONFIG_FAIL: {e}"), 1))?;
                    let (ok, _) = evaluate_escalation(&resolved.config.models, role, host, 0, tr);
                    if ok {
                        route_escalations.max(1)
                    } else {
                        0
                    }
                } else {
                    route_escalations
                };
                let avail_vec: Option<Vec<String>> = route_available.map(|csv| {
                    csv.split(',')
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect()
                });
                let dec = route_model(
                    &resolved.config,
                    role,
                    comp,
                    risk,
                    host,
                    eff_escalations,
                    avail_vec.as_deref(),
                    route_confirmed,
                )
                .map_err(|e| fail(format!("CONFIG_FAIL: {e}"), 1))?;
                if json_flag {
                    let obj = JsonValue::Object(vec![
                        ("role".into(), JsonValue::String(dec.role)),
                        ("complexity".into(), JsonValue::String(dec.complexity)),
                        ("risk".into(), JsonValue::String(dec.risk)),
                        ("selected_tier".into(), JsonValue::String(dec.selected_tier)),
                        (
                            "requested_model".into(),
                            JsonValue::String(dec.requested_model),
                        ),
                        ("actual_model".into(), JsonValue::String(dec.actual_model)),
                        (
                            "selection_reason".into(),
                            JsonValue::String(dec.selection_reason),
                        ),
                        (
                            "fallback_reason".into(),
                            dec.fallback_reason
                                .map(JsonValue::String)
                                .unwrap_or(JsonValue::Null),
                        ),
                        (
                            "escalation_count".into(),
                            JsonValue::num_u64(dec.escalation_count as u64),
                        ),
                        (
                            "capability_warning".into(),
                            dec.capability_warning
                                .map(JsonValue::String)
                                .unwrap_or(JsonValue::Null),
                        ),
                    ]);
                    return Ok((obj.to_json_pretty(), 0));
                }
                let mut lines = vec![
                    format!("role={}", dec.role),
                    format!("complexity={}", dec.complexity),
                    format!("risk={}", dec.risk),
                    format!("selected_tier={}", dec.selected_tier),
                    format!("requested_model={}", dec.requested_model),
                    format!("actual_model={}", dec.actual_model),
                    format!("selection_reason={}", dec.selection_reason),
                    format!("escalation_count={}", dec.escalation_count),
                ];
                if let Some(fb) = dec.fallback_reason {
                    lines.push(format!("fallback_reason={fb}"));
                }
                if let Some(cw) = dec.capability_warning {
                    lines.push(format!("capability_warning={cw}"));
                }
                return Ok((lines.join("\n"), 0));
            }

            let Some(k) = key.map(str::trim).filter(|s| !s.is_empty()) else {
                return Err(fail("CONFIG_FAIL: missing <key> (or --route <role>)", 1));
            };
            let Some(val) = get_effective_key_value(&resolved.config, k) else {
                return Err(fail(format!("CONFIG_FAIL: unknown config key '{k}'"), 1));
            };
            let src = resolved
                .sources
                .get(k)
                .copied()
                .unwrap_or(ConfigSource::Default);
            if json_flag {
                let obj = JsonValue::Object(vec![
                    ("key".into(), JsonValue::String(k.to_string())),
                    ("value".into(), toml_val_to_json(&val)),
                    ("source".into(), JsonValue::String(src.as_str().to_string())),
                ]);
                return Ok((obj.to_json_pretty(), 0));
            }
            if sources_flag {
                Ok((
                    format!("{}  # source={}", format_toml_value(&val), src.as_str()),
                    0,
                ))
            } else {
                Ok((format_toml_value(&val), 0))
            }
        }
        "set" => {
            let Some(k) = key.map(str::trim).filter(|s| !s.is_empty()) else {
                return Err(fail("CONFIG_FAIL: usage: b3 config set <key> <value>", 1));
            };
            let Some(raw_v) = value else {
                return Err(fail("CONFIG_FAIL: usage: b3 config set <key> <value>", 1));
            };
            let parsed_val = parse_cli_value_for_key(k, raw_v)
                .map_err(|e| fail(format!("CONFIG_FAIL: {e}"), 1))?;
            let (table, field) =
                split_dot_key_for_toml(k).map_err(|e| fail(format!("CONFIG_FAIL: {e}"), 1))?;

            let target_scope = scope.unwrap_or("personal");
            let target_path = match target_scope {
                "personal" => resolve_personal_config_path(user_home_ref)
                    .map_err(|e| fail(format!("CONFIG_FAIL: {e}"), 1))?,
                "project" => {
                    let root = repo_root.as_deref().ok_or_else(|| {
                        fail(
                            "CONFIG_FAIL: --scope project requires a repository root (--repo-root)",
                            1,
                        )
                    })?;
                    root.join(".b3").join("config.toml")
                }
                "policy" => {
                    return Err(fail(
                        "CONFIG_FORBIDDEN: governance policy (.b3/policy.toml) cannot be modified via b3 config set",
                        1,
                    ));
                }
                other => {
                    return Err(fail(
                        format!(
                            "CONFIG_FAIL: invalid --scope '{other}'; expected personal|project"
                        ),
                        1,
                    ));
                }
            };

            if path_has_reparse(&target_path) {
                return Err(fail(
                    format!(
                        "CONFIG_FAIL: refusing symlink/reparse config path at {}",
                        target_path.display()
                    ),
                    1,
                ));
            }
            let existing = if target_path.is_file() {
                fs::read_to_string(&target_path).map_err(|e| {
                    fail(
                        format!("CONFIG_FAIL: cannot read {}: {e}", target_path.display()),
                        1,
                    )
                })?
            } else if target_scope == "personal" {
                load_config_template(repo_root.as_deref())
            } else {
                "# Project-local B3 preference overrides (Git-ignored)\n".to_string()
            };

            let updated = set_toml_key_preserving_comments(&existing, &table, &field, &parsed_val)
                .map_err(|e| fail(format!("CONFIG_FAIL: {e}"), 1))?;

            // Validate resulting config semantics (e.g. review.sizing threshold ordering) before writing.
            let check_doc =
                parse_toml_strict(&updated).map_err(|e| fail(format!("CONFIG_FAIL: {e}"), 1))?;
            let mut probe_cfg = B3Config::default();
            let mut probe_src = default_sources();
            let mut probe_warn = Vec::new();
            apply_doc(
                &check_doc,
                ConfigSource::Project,
                target_scope,
                &mut probe_cfg,
                &mut probe_src,
                &mut probe_warn,
            );
            if !probe_warn.is_empty() {
                return Err(fail(format!("CONFIG_FAIL: {}", probe_warn.join("; ")), 1));
            }

            if dry_run {
                return Ok((
                    format!(
                        "dry-run: set {k} = {} in {}",
                        format_toml_value(&parsed_val),
                        target_path.display()
                    ),
                    0,
                ));
            }
            write_atomic_lf(&target_path, &updated)?;
            Ok((
                format!(
                    "updated {} ({} = {})",
                    target_path.display(),
                    k,
                    format_toml_value(&parsed_val)
                ),
                0,
            ))
        }
        "validate" => {
            let mut errors = Vec::new();
            let mut checked = Vec::new();

            let personal_path = resolve_personal_config_path(user_home_ref)
                .map_err(|e| fail(format!("CONFIG_INVALID: {e}"), 1))?;
            if let Some(res) = read_toml_if_safe(&personal_path, "personal config") {
                match res {
                    Ok(doc) => {
                        let mut c = B3Config::default();
                        let mut s = default_sources();
                        let mut w = Vec::new();
                        apply_doc(
                            &doc,
                            ConfigSource::Personal,
                            "personal",
                            &mut c,
                            &mut s,
                            &mut w,
                        );
                        errors.extend(w);
                        checked.push(format!("personal:{}", personal_path.display()));
                    }
                    Err(e) => errors.push(e),
                }
            }

            if let Some(ref root) = repo_root {
                let proj_path = root.join(".b3").join("config.toml");
                if let Some(res) = read_toml_if_safe(&proj_path, "project config") {
                    match res {
                        Ok(doc) => {
                            let mut c = B3Config::default();
                            let mut s = default_sources();
                            let mut w = Vec::new();
                            apply_doc(
                                &doc,
                                ConfigSource::Project,
                                "project",
                                &mut c,
                                &mut s,
                                &mut w,
                            );
                            errors.extend(w);
                            checked.push(format!("project:{}", proj_path.display()));
                        }
                        Err(e) => errors.push(e),
                    }
                }
                let pol_toml = root.join(".b3").join("policy.toml");
                let pol_json = root.join(".b3").join("research-policy.json");
                let has_toml = pol_toml.exists() || is_reparse_or_symlink(&pol_toml);
                let has_json = pol_json.exists() || is_reparse_or_symlink(&pol_json);
                if has_toml && has_json {
                    errors.push(
                        "policy conflict: both .b3/policy.toml and .b3/research-policy.json exist"
                            .to_string(),
                    );
                } else if has_toml {
                    if path_has_reparse(&pol_toml) || !pol_toml.is_file() {
                        errors.push(format!("invalid policy path {}", pol_toml.display()));
                    } else {
                        match fs::read_to_string(&pol_toml) {
                            Ok(raw) => {
                                match crate::guard::merge_policy::validate_policy_toml_text(&raw) {
                                    Ok(()) => {
                                        checked.push(format!("policy:{}", pol_toml.display()))
                                    }
                                    Err(e) => errors.push(format!("policy.toml: {e}")),
                                }
                            }
                            Err(e) => errors.push(format!("cannot read policy.toml: {e}")),
                        }
                    }
                }
            }

            if json_flag {
                let obj = JsonValue::Object(vec![
                    ("valid".into(), JsonValue::Bool(errors.is_empty())),
                    (
                        "checked".into(),
                        JsonValue::Array(checked.into_iter().map(JsonValue::String).collect()),
                    ),
                    (
                        "errors".into(),
                        JsonValue::Array(errors.iter().cloned().map(JsonValue::String).collect()),
                    ),
                ]);
                return Ok((obj.to_json_pretty(), if errors.is_empty() { 0 } else { 1 }));
            }
            if !errors.is_empty() {
                return Err(fail(format!("CONFIG_INVALID: {}", errors.join("; ")), 1));
            }
            if checked.is_empty() {
                Ok((
                    "CONFIG_VALID: using built-in defaults (no config files present)".to_string(),
                    0,
                ))
            } else {
                Ok((format!("CONFIG_VALID: {}", checked.join(", ")), 0))
            }
        }
        "init" => {
            let target_scope = scope.unwrap_or("personal");
            match target_scope {
                "personal" => {
                    let dest = resolve_personal_config_path(user_home_ref)
                        .map_err(|e| fail(format!("CONFIG_FAIL: {e}"), 1))?;
                    if path_has_reparse(&dest) {
                        return Err(fail(
                            format!(
                                "CONFIG_FAIL: refusing symlink/reparse at {}",
                                dest.display()
                            ),
                            1,
                        ));
                    }
                    if dest.exists() && !force {
                        return Ok((format!("kept: {} (already exists)", dest.display()), 0));
                    }
                    if dry_run {
                        return Ok((format!("dry-run: would initialize {}", dest.display()), 0));
                    }
                    let tpl = load_config_template(repo_root.as_deref());
                    write_config_new_safe(&dest, &tpl, force)?;
                    Ok((format!("initialized: {}", dest.display()), 0))
                }
                "project" => {
                    let root = repo_root.as_deref().ok_or_else(|| {
                        fail(
                            "CONFIG_FAIL: --scope project requires a repository root (--repo-root)",
                            1,
                        )
                    })?;
                    let dest = root.join(".b3").join("config.toml");
                    if path_has_reparse(&dest) {
                        return Err(fail(
                            format!(
                                "CONFIG_FAIL: refusing symlink/reparse at {}",
                                dest.display()
                            ),
                            1,
                        ));
                    }
                    if dest.exists() && !force {
                        return Ok((format!("kept: {} (already exists)", dest.display()), 0));
                    }
                    if dry_run {
                        return Ok((format!("dry-run: would initialize {}", dest.display()), 0));
                    }
                    let tpl = load_config_template(Some(root));
                    write_config_new_safe(&dest, &tpl, force)?;
                    Ok((format!("initialized: {}", dest.display()), 0))
                }
                other => Err(fail(
                    format!("CONFIG_FAIL: invalid --scope '{other}'; expected personal|project"),
                    1,
                )),
            }
        }
        "migrate" => {
            let target_scope = scope.unwrap_or("all");
            if !matches!(target_scope, "personal" | "project" | "policy" | "all") {
                return Err(fail(
                    format!("CONFIG_FAIL: invalid --scope '{target_scope}'; expected personal|project|policy|all"),
                    1,
                ));
            }

            let mut actions = Vec::new();
            let tpl = load_config_template(repo_root.as_deref());
            let home_dir = resolve_user_home_checked(user_home_ref)
                .map_err(|e| fail(format!("CONFIG_FAIL: {e}"), 1))?;

            if matches!(target_scope, "personal" | "all") {
                let legacy_models = std::env::var("B3_MODELS_PERSONAL")
                    .ok()
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty() && !is_unc_or_control(s))
                    .map(PathBuf::from)
                    .unwrap_or_else(|| home_dir.join(".b3").join("models.md"));
                let dest_toml = resolve_personal_config_path(user_home_ref)
                    .map_err(|e| fail(format!("CONFIG_FAIL: {e}"), 1))?;

                if legacy_models.exists() || is_reparse_or_symlink(&legacy_models) {
                    if path_has_reparse(&legacy_models) || !legacy_models.is_file() {
                        return Err(fail(
                            format!(
                                "MIGRATE_FAIL: unsafe legacy path {}",
                                legacy_models.display()
                            ),
                            1,
                        ));
                    }
                    if dest_toml.exists() || is_reparse_or_symlink(&dest_toml) {
                        return Err(fail(
                            format!(
                                "MIGRATE_CONFLICT: both {} and {} exist; review differences and migrate manually without silent overwrite",
                                legacy_models.display(),
                                dest_toml.display()
                            ),
                            1,
                        ));
                    }
                    let raw = fs::read_to_string(&legacy_models).map_err(|e| {
                        fail(
                            format!("MIGRATE_FAIL: cannot read {}: {e}", legacy_models.display()),
                            1,
                        )
                    })?;
                    let parsed = parse_legacy_models_md(&raw);
                    let mut out_toml = tpl.clone();
                    for (r, m) in parsed.roles {
                        out_toml = set_toml_key_preserving_comments(
                            &out_toml,
                            "models.roles",
                            &r,
                            &TomlValue::Array(vec![TomlValue::Str(m)]),
                        )
                        .map_err(|e| fail(format!("MIGRATE_FAIL: {e}"), 1))?;
                    }
                    if let Some(cg) = parsed.clarification_gate {
                        out_toml = set_toml_key_preserving_comments(
                            &out_toml,
                            "planning",
                            "clarification_gate",
                            &TomlValue::Bool(cg),
                        )
                        .map_err(|e| fail(format!("MIGRATE_FAIL: {e}"), 1))?;
                    }
                    if let Some(th) = parsed.understanding_threshold {
                        out_toml = set_toml_key_preserving_comments(
                            &out_toml,
                            "planning",
                            "understanding_threshold",
                            &TomlValue::Int(th as i64),
                        )
                        .map_err(|e| fail(format!("MIGRATE_FAIL: {e}"), 1))?;
                    }
                    if dry_run {
                        actions.push(format!(
                            "dry-run: migrate {} -> {}",
                            legacy_models.display(),
                            dest_toml.display()
                        ));
                    } else {
                        write_config_new_safe(&dest_toml, &out_toml, false)?;
                        actions.push(format!(
                            "migrated: {} -> {} (legacy file preserved)",
                            legacy_models.display(),
                            dest_toml.display()
                        ));
                    }
                } else {
                    actions.push("personal: nothing to migrate".to_string());
                }
            }

            if matches!(target_scope, "project" | "all") {
                if let Some(ref root) = repo_root {
                    let leg_proj = root.join(".b3").join("models.md");
                    let dest_proj = root.join(".b3").join("config.toml");
                    if leg_proj.exists() || is_reparse_or_symlink(&leg_proj) {
                        if path_has_reparse(&leg_proj) || !leg_proj.is_file() {
                            return Err(fail(
                                format!("MIGRATE_FAIL: unsafe legacy path {}", leg_proj.display()),
                                1,
                            ));
                        }
                        if dest_proj.exists() || is_reparse_or_symlink(&dest_proj) {
                            return Err(fail(
                                format!(
                                    "MIGRATE_CONFLICT: both {} and {} exist; resolve manually without silent overwrite",
                                    leg_proj.display(),
                                    dest_proj.display()
                                ),
                                1,
                            ));
                        }
                        let raw = fs::read_to_string(&leg_proj).map_err(|e| {
                            fail(
                                format!("MIGRATE_FAIL: cannot read {}: {e}", leg_proj.display()),
                                1,
                            )
                        })?;
                        let parsed = parse_legacy_models_md(&raw);
                        let mut out_toml =
                            "# Project-local B3 preference overrides (Git-ignored)\n".to_string();
                        for (r, m) in parsed.roles {
                            out_toml = set_toml_key_preserving_comments(
                                &out_toml,
                                "models.roles",
                                &r,
                                &TomlValue::Array(vec![TomlValue::Str(m)]),
                            )
                            .map_err(|e| fail(format!("MIGRATE_FAIL: {e}"), 1))?;
                        }
                        if let Some(cg) = parsed.clarification_gate {
                            out_toml = set_toml_key_preserving_comments(
                                &out_toml,
                                "planning",
                                "clarification_gate",
                                &TomlValue::Bool(cg),
                            )
                            .map_err(|e| fail(format!("MIGRATE_FAIL: {e}"), 1))?;
                        }
                        if let Some(th) = parsed.understanding_threshold {
                            out_toml = set_toml_key_preserving_comments(
                                &out_toml,
                                "planning",
                                "understanding_threshold",
                                &TomlValue::Int(th as i64),
                            )
                            .map_err(|e| fail(format!("MIGRATE_FAIL: {e}"), 1))?;
                        }
                        if dry_run {
                            actions.push(format!(
                                "dry-run: migrate {} -> {}",
                                leg_proj.display(),
                                dest_proj.display()
                            ));
                        } else {
                            write_config_new_safe(&dest_proj, &out_toml, false)?;
                            actions.push(format!(
                                "migrated: {} -> {} (legacy file preserved)",
                                leg_proj.display(),
                                dest_proj.display()
                            ));
                        }
                    } else {
                        actions.push("project: nothing to migrate".to_string());
                    }
                }
            }

            if matches!(target_scope, "policy" | "all") {
                if let Some(ref root) = repo_root {
                    let leg_pol = root.join(".b3").join("research-policy.json");
                    let dest_pol = root.join(".b3").join("policy.toml");
                    if leg_pol.exists() || is_reparse_or_symlink(&leg_pol) {
                        if path_has_reparse(&leg_pol) || !leg_pol.is_file() {
                            return Err(fail(
                                format!(
                                    "MIGRATE_FAIL: unsafe legacy policy path {}",
                                    leg_pol.display()
                                ),
                                1,
                            ));
                        }
                        if dest_pol.exists() || is_reparse_or_symlink(&dest_pol) {
                            return Err(fail(
                                format!(
                                    "MIGRATE_CONFLICT: both {} and {} exist; reconcile and remove legacy JSON manually before committing",
                                    leg_pol.display(),
                                    dest_pol.display()
                                ),
                                1,
                            ));
                        }
                        let raw_json = fs::read_to_string(&leg_pol).map_err(|e| {
                            fail(
                                format!("MIGRATE_FAIL: cannot read {}: {e}", leg_pol.display()),
                                1,
                            )
                        })?;
                        let pol_toml_text = convert_legacy_policy_json_to_toml(&raw_json, root)?;
                        if dry_run {
                            actions.push(format!(
                                "dry-run: migrate {} -> {}",
                                leg_pol.display(),
                                dest_pol.display()
                            ));
                        } else {
                            write_config_new_safe(&dest_pol, &pol_toml_text, false)?;
                            actions.push(format!(
                                "migrated: {} -> {} (verify and remove legacy JSON in governance commit)",
                                leg_pol.display(),
                                dest_pol.display()
                            ));
                        }
                    } else {
                        actions.push("policy: nothing to migrate".to_string());
                    }
                }
            }

            Ok((actions.join("\n"), 0))
        }
        other => Err(fail(
            format!("CONFIG_FAIL: unknown subcommand '{other}'"),
            1,
        )),
    }
}

fn convert_legacy_policy_json_to_toml(raw_json: &str, repo_root: &Path) -> Result<String, B3Error> {
    let parsed = parse_json(raw_json)
        .map_err(|_| fail("MIGRATE_FAIL: invalid legacy .b3/research-policy.json", 1))?;
    if !matches!(parsed, JsonValue::Object(_)) {
        return Err(fail(
            "MIGRATE_FAIL: legacy .b3/research-policy.json must be a JSON object",
            1,
        ));
    }

    let pol_tpl_path = repo_root.join("config").join("policy.example.toml");
    let mut out = if pol_tpl_path.is_file() && !path_has_reparse(&pol_tpl_path) {
        fs::read_to_string(&pol_tpl_path)
            .unwrap_or_else(|_| DEFAULT_POLICY_TEMPLATE.to_string())
            .replace("\r\n", "\n")
    } else {
        DEFAULT_POLICY_TEMPLATE.replace("\r\n", "\n")
    };

    let auto_merge = match parsed
        .get_exact_unique("auto_merge")
        .map_err(|_| fail("MIGRATE_FAIL: duplicate auto_merge", 1))?
    {
        None => "disabled".to_string(),
        Some(JsonValue::String(s)) => s.trim().to_string(),
        Some(_) => return Err(fail("MIGRATE_FAIL: auto_merge must be a string", 1)),
    };
    if auto_merge != "disabled" && auto_merge != "authorized" {
        return Err(fail(
            format!("MIGRATE_FAIL: invalid auto_merge '{auto_merge}'"),
            1,
        ));
    }

    let explicit_max_risk = match parsed
        .get_exact_unique("auto_merge_max_risk")
        .map_err(|_| fail("MIGRATE_FAIL: duplicate auto_merge_max_risk", 1))?
    {
        None => None,
        Some(JsonValue::String(s)) => Some(s.trim().to_ascii_uppercase()),
        Some(_) => {
            return Err(fail(
                "MIGRATE_FAIL: auto_merge_max_risk must be a string",
                1,
            ));
        }
    };

    // Preserve legacy semantics faithfully: previously-authorized legacy policies had no risk ceiling
    // ("CRITICAL"), whereas disabled policies default safely to "LOW".
    let max_risk = if let Some(r) = explicit_max_risk {
        RiskTier::parse(&r).map_err(|e| fail(format!("MIGRATE_FAIL: {e}"), 1))?;
        r
    } else if auto_merge == "authorized" {
        "CRITICAL".to_string()
    } else {
        "LOW".to_string()
    };

    let parse_opt_bool = |key: &str, default_val: bool| -> Result<bool, B3Error> {
        match parsed
            .get_exact_unique(key)
            .map_err(|_| fail(format!("MIGRATE_FAIL: duplicate {key}"), 1))?
        {
            None => Ok(default_val),
            Some(JsonValue::Bool(b)) => Ok(*b),
            Some(_) => Err(fail(format!("MIGRATE_FAIL: {key} must be a boolean"), 1)),
        }
    };
    let allow_protected = parse_opt_bool("allow_protected_paths", false)?;
    let require_ci = parse_opt_bool("require_ci", true)?;
    let require_review = parse_opt_bool("require_review", true)?;

    let mut prot_paths = Vec::new();
    match parsed
        .get_exact_unique("protected_paths")
        .map_err(|_| fail("MIGRATE_FAIL: duplicate protected_paths", 1))?
    {
        None => {}
        Some(JsonValue::Array(arr)) => {
            for item in arr {
                let s = item
                    .as_str()
                    .ok_or_else(|| fail("MIGRATE_FAIL: invalid protected_paths item", 1))?;
                prot_paths.push(TomlValue::Str(s.to_string()));
            }
        }
        Some(_) => {
            return Err(fail("MIGRATE_FAIL: protected_paths must be an array", 1));
        }
    }

    let mut target_branches = Vec::new();
    match parsed
        .get_exact_unique("allowed_target_branches")
        .map_err(|_| fail("MIGRATE_FAIL: duplicate allowed_target_branches", 1))?
    {
        None => {}
        Some(JsonValue::Array(arr)) => {
            for item in arr {
                let s = item
                    .as_str()
                    .ok_or_else(|| fail("MIGRATE_FAIL: invalid allowed_target_branches item", 1))?;
                target_branches.push(TomlValue::Str(s.to_string()));
            }
        }
        Some(_) => {
            return Err(fail(
                "MIGRATE_FAIL: allowed_target_branches must be an array",
                1,
            ));
        }
    }

    for (k, val) in [
        ("auto_merge", TomlValue::Str(auto_merge)),
        ("auto_merge_max_risk", TomlValue::Str(max_risk)),
        ("protected_paths", TomlValue::Array(prot_paths)),
        ("allow_protected_paths", TomlValue::Bool(allow_protected)),
        ("allowed_target_branches", TomlValue::Array(target_branches)),
        ("require_ci", TomlValue::Bool(require_ci)),
        ("require_review", TomlValue::Bool(require_review)),
    ] {
        out = set_toml_key_preserving_comments(&out, "", k, &val)
            .map_err(|e| fail(format!("MIGRATE_FAIL: {e}"), 1))?;
    }

    crate::guard::merge_policy::validate_policy_toml_text(&out)
        .map_err(|e| fail(format!("MIGRATE_FAIL: converted policy invalid: {e}"), 1))?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_precedence_and_partial_fallback() {
        let tmp = std::env::temp_dir().join(format!("b3-cfg-unit-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        let home = tmp.join("home");
        let repo = tmp.join("repo");
        fs::create_dir_all(home.join(".b3")).unwrap();
        fs::create_dir_all(repo.join(".b3")).unwrap();

        fs::write(
            home.join(".b3/config.toml"),
            "[planning]\nunderstanding_threshold = 90\nclarification_gate = true\n[models.roles]\nplanning = [\"economy\", \"advanced\"]\n",
        )
        .unwrap();
        fs::write(
            repo.join(".b3/config.toml"),
            "[planning]\nunderstanding_threshold = \"bad\"\nclarification_gate = false\n[review.sizing]\nxs_max_loc = 500\nxs_max_files = 3\ns_max_loc = 200\n",
        )
        .unwrap();

        let res = resolve_config(
            Some(&repo),
            Some(&home),
            &[("review.max_iterations".to_string(), "8".to_string())],
        );
        assert!(!res.config.planning.clarification_gate);
        assert_eq!(
            res.sources.get("planning.clarification_gate"),
            Some(&ConfigSource::Project)
        );
        // Bad project threshold falls back cleanly to personal 90
        assert_eq!(res.config.planning.understanding_threshold, 90);
        assert_eq!(
            res.sources.get("planning.understanding_threshold"),
            Some(&ConfigSource::Personal)
        );
        // Invalid project review.sizing reverts cleanly without corrupting xs<s invariant
        assert_eq!(res.config.review.sizing, ReviewSizingConfig::default());
        assert_eq!(res.config.review.max_iterations, 8);
        assert_eq!(
            res.sources.get("review.max_iterations"),
            Some(&ConfigSource::Invocation)
        );
        assert!(res.files_read <= 2);
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn adaptive_routing_and_bounded_escalation() {
        let mut cfg = B3Config::default();
        cfg.models.tiers.economy = "model-l1".to_string();
        cfg.models.tiers.balanced = "model-l2".to_string();
        cfg.models.tiers.advanced = "model-l3".to_string();

        // Low complexity, low risk -> L1
        let d_low = route_model(
            &cfg,
            "implementation",
            ComplexityLevel::Low,
            RiskTier::Low,
            "codex",
            0,
            None,
            None,
        )
        .unwrap();
        assert_eq!(d_low.requested_model, "model-l1");
        assert_eq!(d_low.actual_model, "UNKNOWN");

        // Low complexity, HIGH risk -> L3 (never downgraded to economy!)
        let d_risk = route_model(
            &cfg,
            "implementation",
            ComplexityLevel::Low,
            RiskTier::High,
            "codex",
            0,
            None,
            Some("model-l3"),
        )
        .unwrap();
        assert_eq!(d_risk.requested_model, "model-l3");
        assert_eq!(d_risk.actual_model, "model-l3");

        // Escalation allowed for reasoning failure, denied for ordinary test failure
        assert!(
            evaluate_escalation(
                &cfg.models,
                "implementation",
                "codex",
                0,
                EscalationTrigger::RepeatedReasoningFailure
            )
            .0
        );
        assert!(
            !evaluate_escalation(
                &cfg.models,
                "implementation",
                "codex",
                0,
                EscalationTrigger::OrdinaryTestFailure
            )
            .0
        );
        // Single-entry role does not invent escalation targets
        assert!(
            !evaluate_escalation(
                &cfg.models,
                "security_reviewer",
                "codex",
                0,
                EscalationTrigger::DesignContradiction
            )
            .0
        );
    }
}
