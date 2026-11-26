use std::fmt;

/// Canonical error type for B3 native commands, carrying the exact exit code
/// and user-facing diagnostic message expected by callers and workflows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct B3Error {
    pub code: i32,
    pub message: String,
}

impl B3Error {
    pub fn new(message: impl Into<String>, code: i32) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

impl fmt::Display for B3Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for B3Error {}

pub fn fail(message: impl Into<String>, code: i32) -> B3Error {
    B3Error::new(message, code)
}
