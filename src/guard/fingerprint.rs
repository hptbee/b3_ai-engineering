use crate::error::{fail, B3Error};
use crate::fs::{sort_ordinal, split_csv_list};

/// Generates canonical task fingerprint string:
/// `depends_on=<sorted csv or []>|scope=<trimmed>|acceptance_criteria=<c1; c2>`
pub fn run(depends_on: &str, scope: &str, criteria: &[String]) -> Result<String, B3Error> {
    let trimmed_scope = scope.trim();
    if trimmed_scope.is_empty() {
        return Err(fail("FINGERPRINT_FAIL: missing --scope", 1));
    }

    let mut crit_list = Vec::new();
    for entry in criteria {
        for piece in entry.split(';') {
            let t = piece.trim();
            if !t.is_empty() {
                crit_list.push(t.to_string());
            }
        }
    }
    if crit_list.is_empty() {
        return Err(fail("FINGERPRINT_FAIL: missing --criteria", 1));
    }

    let dep_items = sort_ordinal(split_csv_list(depends_on), false);
    let dep_text = if dep_items.is_empty() {
        "[]".to_string()
    } else {
        dep_items.join(",")
    };
    let crit_text = crit_list.join("; ");

    Ok(format!(
        "depends_on={dep_text}|scope={trimmed_scope}|acceptance_criteria={crit_text}"
    ))
}
