pub mod cache;
pub mod evidence;
pub mod fingerprint;
pub mod freshness;
pub mod inventory;
pub mod ledger;
pub mod mechanical;
pub mod merge_policy;
pub mod precommit;
pub mod runs;
pub mod scope;
pub mod snapshot;
pub mod symbol;
pub mod verify;
pub mod wave;
pub mod worktree;

pub(crate) fn push_unique_str(vec: &mut Vec<String>, val: String) {
    if !vec.iter().any(|x| x == &val) {
        vec.push(val);
    }
}
