#!/usr/bin/env bash
# Dual-shell behavioral regression suite for PR #30 security fixes (R001, R002, R003).
# Exercises BOTH scripts/b3-guard.sh and scripts/b3-guard.ps1 (when pwsh is available)
# with a test-scoped mock `gh` executable on PATH (zero production mock flags).
# Usage: ./scripts/validate-merge-security.sh [--pwsh /path/to/pwsh] [--allow-incomplete-pwsh]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GUARD_SH="${REPO_ROOT}/scripts/b3-guard.sh"
GUARD_PS="${REPO_ROOT}/scripts/b3-guard.ps1"

PWSH_BIN=""
ALLOW_INCOMPLETE_PWSH=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pwsh) PWSH_BIN="${2:-}"; shift 2 ;;
    --allow-incomplete-pwsh) ALLOW_INCOMPLETE_PWSH=true; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PWSH_BIN" ]]; then
  if command -v pwsh >/dev/null 2>&1; then
    PWSH_BIN="$(command -v pwsh)"
  elif [[ -x "/tmp/pwsh/pwsh" ]]; then
    PWSH_BIN="/tmp/pwsh/pwsh"
  fi
fi
HAS_PWSH=false
if [[ -n "$PWSH_BIN" && -x "$PWSH_BIN" ]]; then
  HAS_PWSH=true
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/b3-merge-sec-XXXXXX")"
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

MOCK_BIN="${SANDBOX}/mock-bin"
NOGH_BIN="${SANDBOX}/nogh-bin"
MOCK_DATA="${SANDBOX}/mock-data"
mkdir -p "$MOCK_BIN" "$NOGH_BIN" "$MOCK_DATA"
for _tool in bash sh git awk mawk gawk sed tr sort paste mktemp cat rm mv cp chmod dirname basename head tail wc grep cut uniq env pwd readlink realpath node python3 python; do
  _tp="$(command -v "$_tool" 2>/dev/null || true)"
  if [[ -n "$_tp" && -x "$_tp" && ! -e "${NOGH_BIN}/${_tool}" ]]; then
    ln -s "$_tp" "${NOGH_BIN}/${_tool}"
  fi
done

# Test-scoped mock `gh` CLI reading fixtures from B3_TEST_GH_DIR
cat > "${MOCK_BIN}/gh" <<'MOCK_GH_EOF'
#!/usr/bin/env bash
set -euo pipefail
dir="${B3_TEST_GH_DIR:-}"
if [[ -z "$dir" || ! -d "$dir" ]]; then
  echo "HTTP 500: mock fixture dir missing" >&2
  exit 1
fi
if [[ "${1:-}" != "api" ]]; then
  echo "unexpected gh subcommand: ${1:-}" >&2
  exit 1
fi
shift
slurp=false
endpoint=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --paginate) shift ;;
    --slurp) slurp=true; shift ;;
    *) endpoint="$1"; shift ;;
  esac
done
# Strip query string
clean="${endpoint%%\?*}"
# Normalize slashes and %2F to __
key="$(printf '%s' "$clean" | sed 's|%2[fF]|__|g; s|/|__|g')"
if [[ -f "${dir}/${key}.err" ]]; then
  cat "${dir}/${key}.err" >&2
  exit 1
fi
if [[ -f "${dir}/${key}.json" ]]; then
  if $slurp; then
    # Wrap page array/object as gh api --paginate --slurp does
    printf '['
    cat "${dir}/${key}.json"
    printf ']\n'
  else
    cat "${dir}/${key}.json"
  fi
  exit 0
fi
echo "HTTP 404 Not Found: ${clean} (key=${key})" >&2
exit 1
MOCK_GH_EOF
chmod +x "${MOCK_BIN}/gh"

PASS_CNT=0
FAIL_CNT=0

pass() {
  PASS_CNT=$((PASS_CNT + 1))
  printf 'PASS %s\n' "$1"
}

fail() {
  FAIL_CNT=$((FAIL_CNT + 1))
  printf 'FAIL %s :: %s\n' "$1" "$2"
}

# Dual-shell invocation helper: runs b3-guard.sh and (if available) b3-guard.ps1 with identical PATH/env
SH_CODE=0; SH_OUT=""
PS_CODE=0; PS_OUT=""

run_dual() {
  local gh_dir="$1"
  local use_mock_path="$2" # "mock" | "nogh"
  local subcmd="$3"
  shift 3
  local sh_args=()
  local ps_args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then shift; break; fi
    sh_args+=("$1")
    shift
  done
  while [[ $# -gt 0 ]]; do
    ps_args+=("$1")
    shift
  done

  local run_path="$PATH"
  if [[ "$use_mock_path" == "mock" ]]; then
    run_path="${MOCK_BIN}:${PATH}"
  elif [[ "$use_mock_path" == "nogh" ]]; then
    run_path="$NOGH_BIN"
  fi

  set +e
  SH_OUT="$(PATH="$run_path" B3_TEST_GH_DIR="$gh_dir" bash "$GUARD_SH" "$subcmd" "${sh_args[@]}" 2>&1)"
  SH_CODE=$?
  SH_OUT="${SH_OUT%$'\r'}"
  if $HAS_PWSH; then
    PS_OUT="$(PATH="$run_path" B3_TEST_GH_DIR="$gh_dir" "$PWSH_BIN" -NoProfile -File "$GUARD_PS" "$subcmd" "${ps_args[@]}" 2>&1)"
    PS_CODE=$?
    PS_OUT="$(printf '%s' "$PS_OUT" | tr -d '\r')"
  else
    PS_CODE=$SH_CODE
    PS_OUT="$SH_OUT"
  fi
  set -e
}

assert_dual() {
  local label="$1" exp_code="$2" exp_regex="$3"
  local ok=true
  if [[ "$SH_CODE" -ne "$exp_code" || "$PS_CODE" -ne "$exp_code" ]]; then
    ok=false
  fi
  if [[ ! "$SH_OUT" =~ $exp_regex ]]; then
    ok=false
  fi
  if [[ "$SH_OUT" != "$PS_OUT" ]]; then
    ok=false
  fi
  if $ok; then
    return 0
  else
    fail "$label" "exp_code=${exp_code} regex='${exp_regex}' sh=(${SH_CODE}:'${SH_OUT}') ps=(${PS_CODE}:'${PS_OUT}')"
    return 1
  fi
}

init_repo() {
  local dir="$1" slug="$2" def_br="${3:-main}"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD "refs/heads/${def_br}"
  git -C "$dir" config user.email "sec-test@example.com"
  git -C "$dir" config user.name "Sec Test"
  git -C "$dir" remote add origin "https://github.com/${slug}.git"
  printf '.b3/ship/\n.b3/research-ship/\n' > "${dir}/.gitignore"
}

write_premerge_fixtures() {
  local dir="$1" slug="$2" pr_num="$3" def_br="$4" def_sha="$5" base_ref="$6" pr_base_sha="$7" live_target_sha="$8"
  local head_ref="$9" head_sha="${10}" pr_author="${11}" reviewer="${12}" rev_commit="${13}" rev_state="${14}"
  local ci_conc="${15}" ci_status="${16}" mergeable_state="${17}" changed_file="${18}"
  local head_repo="${19:-$slug}" req_reviews="${20:-0}" req_check="${21:-}" branch_prot="${22:-false}"
  local rev_user_type="${23:-User}" rev_assoc="${24:-COLLABORATOR}"

  rm -rf "$dir"
  mkdir -p "$dir"
  local s_key="${slug//\//__}"
  local b_key="${base_ref//\//__}"
  local d_key="${def_br//\//__}"

  cat > "${dir}/repos__${s_key}__pulls__${pr_num}.json" <<EOF
{
  "number": ${pr_num},
  "state": "open",
  "draft": false,
  "merged": false,
  "merged_at": null,
  "merge_commit_sha": null,
  "mergeable": true,
  "mergeable_state": "${mergeable_state}",
  "user": { "login": "${pr_author}" },
  "base": {
    "ref": "${base_ref}",
    "sha": "${pr_base_sha}",
    "repo": { "full_name": "${slug}", "default_branch": "${def_br}" }
  },
  "head": {
    "ref": "${head_ref}",
    "sha": "${head_sha}",
    "repo": { "full_name": "${head_repo}" }
  }
}
EOF

  local rsc_json="[]"
  [[ -n "$req_check" ]] && rsc_json="[\"${req_check}\"]"
  cat > "${dir}/repos__${s_key}__branches__${b_key}.json" <<EOF
{
  "name": "${base_ref}",
  "protected": ${branch_prot},
  "commit": { "sha": "${live_target_sha}" },
  "protection": {
    "enabled": ${branch_prot},
    "required_status_checks": { "contexts": ${rsc_json}, "checks": [] }
  }
}
EOF

  if [[ "$def_br" != "$base_ref" ]]; then
    cat > "${dir}/repos__${s_key}__branches__${d_key}.json" <<EOF
{
  "name": "${def_br}",
  "protected": false,
  "commit": { "sha": "${def_sha}" }
}
EOF
  fi

  if [[ "$branch_prot" == "true" ]]; then
    cat > "${dir}/repos__${s_key}__branches__${b_key}__protection.json" <<EOF
{
  "required_status_checks": { "strict": true, "contexts": ${rsc_json}, "checks": [] },
  "required_pull_request_reviews": { "required_approving_review_count": ${req_reviews}, "require_code_owner_reviews": false }
}
EOF
  fi

  if [[ "$req_reviews" -gt 0 || -n "$req_check" ]]; then
    local rules_items=()
    if [[ "$req_reviews" -gt 0 ]]; then
      rules_items+=("{\"type\":\"pull_request\",\"parameters\":{\"required_approving_review_count\":${req_reviews},\"require_code_owner_review\":false}}")
    fi
    if [[ -n "$req_check" ]]; then
      rules_items+=("{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"${req_check}\"}]}}")
    fi
    printf '[%s]\n' "$(IFS=,; echo "${rules_items[*]}")" > "${dir}/repos__${s_key}__rules__branches__${b_key}.json"
  else
    echo "[]" > "${dir}/repos__${s_key}__rules__branches__${b_key}.json"
  fi

  cat > "${dir}/repos__${s_key}__pulls__${pr_num}__files.json" <<EOF
[
  { "filename": "${changed_file}", "status": "modified" }
]
EOF

  if [[ -n "$reviewer" && -n "$rev_state" ]]; then
    cat > "${dir}/repos__${s_key}__pulls__${pr_num}__reviews.json" <<EOF
[
  { "id": 101, "user": { "login": "${reviewer}", "type": "${rev_user_type}" }, "author_association": "${rev_assoc}", "state": "${rev_state}", "commit_id": "${rev_commit}" }
]
EOF
  else
    echo "[]" > "${dir}/repos__${s_key}__pulls__${pr_num}__reviews.json"
  fi

  if [[ "$ci_status" == "none" ]]; then
    cat > "${dir}/repos__${s_key}__commits__${head_sha}__check-runs.json" <<EOF
{ "total_count": 0, "check_runs": [] }
EOF
  else
    local conc_json="\"${ci_conc}\""
    [[ "$ci_conc" == "null" ]] && conc_json="null"
    cat > "${dir}/repos__${s_key}__commits__${head_sha}__check-runs.json" <<EOF
{
  "total_count": 1,
  "check_runs": [
    { "id": 500, "name": "ci/build-test", "app": { "id": 15368 }, "head_sha": "${head_sha}", "status": "${ci_status}", "conclusion": ${conc_json} }
  ]
}
EOF
  fi

  cat > "${dir}/repos__${s_key}__commits__${head_sha}__status.json" <<EOF
{ "sha": "${head_sha}", "state": "pending", "total_count": 0, "statuses": [] }
EOF
}

write_postmerge_fixtures() {
  local dir="$1" slug="$2" pr_num="$3" def_br="$4" base_ref="$5" head_sha="$6"
  local pr_state="$7" pr_merged="$8" merge_sha="$9" live_target_sha="${10}" cmp_status="${11}" cmp_behind="${12}"
  rm -rf "$dir"
  mkdir -p "$dir"
  local s_key="${slug//\//__}"
  local b_key="${base_ref//\//__}"
  local m_sha_json="null" m_at_json="null"
  [[ -n "$merge_sha" ]] && m_sha_json="\"${merge_sha}\""
  [[ "$pr_merged" == "true" ]] && m_at_json="\"2026-11-24T15:00:00Z\""

  cat > "${dir}/repos__${s_key}__pulls__${pr_num}.json" <<EOF
{
  "number": ${pr_num},
  "state": "${pr_state}",
  "merged": ${pr_merged},
  "merged_at": ${m_at_json},
  "merge_commit_sha": ${m_sha_json},
  "commits": 2,
  "base": {
    "ref": "${base_ref}",
    "sha": "${live_target_sha}",
    "repo": { "full_name": "${slug}", "default_branch": "${def_br}" }
  },
  "head": {
    "ref": "feat/work",
    "sha": "${head_sha}",
    "repo": { "full_name": "${slug}" }
  }
}
EOF
  if [[ -n "$live_target_sha" ]]; then
    cat > "${dir}/repos__${s_key}__branches__${b_key}.json" <<EOF
{ "name": "${base_ref}", "protected": false, "commit": { "sha": "${live_target_sha}" } }
EOF
  fi
  if [[ -n "$merge_sha" && -n "$live_target_sha" && -n "$cmp_status" ]]; then
    cat > "${dir}/repos__${s_key}__compare__${merge_sha}...${live_target_sha}.json" <<EOF
{ "status": "${cmp_status}", "behind_by": ${cmp_behind}, "ahead_by": 0 }
EOF
  fi
}

# ============================================================================
# TEST 1 & 2: PR targeting main, develop, release/*, feature/*, and Stacked PR
# ============================================================================
R1="${SANDBOX}/r1-targets"
SLUG="octo/b3-demo"
init_repo "$R1" "$SLUG" "main"
mkdir -p "${R1}/.b3" "${R1}/docs"
cat > "${R1}/.b3/research-policy.json" <<'EOF'
{
  "auto_merge": "authorized",
  "protected_paths": ["releases/"],
  "allow_protected_paths": false,
  "require_ci": true,
  "require_review": true
}
EOF
printf '# Base\n' > "${R1}/docs/notes.md"
git -C "$R1" add . && git -C "$R1" commit -qm "init main with policy"
MAIN_SHA="$(git -C "$R1" rev-parse HEAD)"

# Create develop, release/2026.11, and feature/parent branches from main (without touching policy)
git -C "$R1" checkout -qb develop
printf 'dev line\n' >> "${R1}/docs/dev.md"
git -C "$R1" add . && git -C "$R1" commit -qm "dev commit"
DEV_SHA="$(git -C "$R1" rev-parse HEAD)"

git -C "$R1" checkout -qb "release/2026.11" "$MAIN_SHA"
printf 'rel line\n' >> "${R1}/docs/rel.md"
git -C "$R1" add . && git -C "$R1" commit -qm "release commit"
REL_SHA="$(git -C "$R1" rev-parse HEAD)"

git -C "$R1" checkout -qb "feature/parent" "$MAIN_SHA"
printf 'parent feature\n' >> "${R1}/docs/parent.md"
git -C "$R1" add . && git -C "$R1" commit -qm "parent feature commit"
PARENT_SHA="$(git -C "$R1" rev-parse HEAD)"

t1_ok=true
for pair in "main:${MAIN_SHA}:11:docs/pr-main.md" "develop:${DEV_SHA}:12:docs/pr-dev.md" "release/2026.11:${REL_SHA}:13:docs/pr-rel.md" "feature/parent:${PARENT_SHA}:14:docs/pr-stacked.md"; do
  IFS=':' read -r t_br t_sha pr_id chg_f <<< "$pair"
  h_br="feat/pr-${pr_id}"
  git -C "$R1" checkout -qb "$h_br" "$t_sha"
  printf 'change for %s\n' "$t_br" > "${R1}/${chg_f}"
  git -C "$R1" add . && git -C "$R1" commit -qm "pr targeting ${t_br}"
  h_sha="$(git -C "$R1" rev-parse HEAD)"

  led=".b3/research-ship/runs/pr-${pr_id}/ledger.md"
  bash "$GUARD_SH" review-ledger --repo-root "$R1" --action init --ledger-path "$led" --base-sha "$t_sha" --review-independence INDEPENDENT >/dev/null
  bash "$GUARD_SH" review-ledger --repo-root "$R1" --action update --ledger-path "$led" --unit-id U01 --status REVIEWED >/dev/null

  fx="${MOCK_DATA}/t1-${pr_id}"
  write_premerge_fixtures "$fx" "$SLUG" "$pr_id" "main" "$MAIN_SHA" "$t_br" "$t_sha" "$t_sha" "$h_br" "$h_sha" "alice" "bob" "$h_sha" "APPROVED" "success" "completed" "clean" "$chg_f" "$SLUG" 1 "ci/build-test" "true"

  run_dual "$fx" "mock" "merge-policy-check" \
    --repo-root "$R1" --pr-number "$pr_id" --target-branch "$t_br" --base-sha "$t_sha" --ledger-path "$led" \
    -- \
    -RepoRoot "$R1" -PrNumber "$pr_id" -TargetBranch "$t_br" -BaseSha "$t_sha" -LedgerPath "$led"
  assert_dual "target-${t_br}" 0 "^MERGE_AUTHORIZED: pr=${SLUG}#${pr_id} target_ref=${t_br} target_sha=${t_sha} head_sha=${h_sha} policy_authority=main@${MAIN_SHA} " || t1_ok=false
done
$t1_ok && pass "01-02-arbitrary-targets-and-stacked-pr"

# ============================================================================
# TEST 3: Caller-supplied wrong BaseSha
# ============================================================================
# Currently on feat/pr-14 (targeting feature/parent @ PARENT_SHA); caller lies and passes MAIN_SHA as BaseSha
t3_ok=true
run_dual "${MOCK_DATA}/t1-14" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 14 --base-sha "$MAIN_SHA" --ledger-path ".b3/research-ship/runs/pr-14/ledger.md" \
  -- \
  -RepoRoot "$R1" -PrNumber 14 -BaseSha "$MAIN_SHA" -LedgerPath ".b3/research-ship/runs/pr-14/ledger.md"
assert_dual "03-wrong-base-sha" 1 "^MERGE_BLOCKED: base_sha_mismatch$" || t3_ok=false

# Also caller passes HEAD as BaseSha
run_dual "${MOCK_DATA}/t1-14" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 14 --base-sha HEAD --ledger-path ".b3/research-ship/runs/pr-14/ledger.md" \
  -- \
  -RepoRoot "$R1" -PrNumber 14 -BaseSha HEAD -LedgerPath ".b3/research-ship/runs/pr-14/ledger.md"
assert_dual "03-head-as-base-sha" 1 "^MERGE_BLOCKED: base_sha_equals_head$" || t3_ok=false
$t3_ok && pass "03-caller-wrong-base-sha"

# ============================================================================
# TEST 4: Target branch moved after verification
# ============================================================================
t4_ok=true
# Advance feature/parent to PARENT_SHA2
git -C "$R1" checkout -q "feature/parent"
printf 'parent moved\n' >> "${R1}/docs/parent.md"
git -C "$R1" add . && git -C "$R1" commit -qm "parent advanced"
PARENT_SHA2="$(git -C "$R1" rev-parse HEAD)"
git -C "$R1" checkout -q "feat/pr-14"
H14_SHA="$(git -C "$R1" rev-parse HEAD)"

# 4a: Live target moved ahead of PR snapshot (pr_base_sha=PARENT_SHA, live_target_sha=PARENT_SHA2)
fx4a="${MOCK_DATA}/t4a"
write_premerge_fixtures "$fx4a" "$SLUG" 14 "main" "$MAIN_SHA" "feature/parent" "$PARENT_SHA" "$PARENT_SHA2" "feat/pr-14" "$H14_SHA" "alice" "bob" "$H14_SHA" "APPROVED" "success" "completed" "clean" "docs/pr-stacked.md"
run_dual "$fx4a" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 14 --ledger-path ".b3/research-ship/runs/pr-14/ledger.md" \
  -- \
  -RepoRoot "$R1" -PrNumber 14 -LedgerPath ".b3/research-ship/runs/pr-14/ledger.md"
assert_dual "04a-remote-target-moved" 1 "^MERGE_BLOCKED: target_branch_moved$" || t4_ok=false

# 4b: GitHub updated PR base to PARENT_SHA2, but PR branch hasn't rebased/merged PARENT_SHA2 (not ancestor)
fx4b="${MOCK_DATA}/t4b"
write_premerge_fixtures "$fx4b" "$SLUG" 14 "main" "$MAIN_SHA" "feature/parent" "$PARENT_SHA2" "$PARENT_SHA2" "feat/pr-14" "$H14_SHA" "alice" "bob" "$H14_SHA" "APPROVED" "success" "completed" "clean" "docs/pr-stacked.md"
run_dual "$fx4b" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 14 --ledger-path ".b3/research-ship/runs/pr-14/ledger.md" \
  -- \
  -RepoRoot "$R1" -PrNumber 14 -LedgerPath ".b3/research-ship/runs/pr-14/ledger.md"
assert_dual "04b-pr-not-rebased-onto-moved-target" 1 "^MERGE_BLOCKED: target_branch_moved$" || t4_ok=false
$t4_ok && pass "04-target-branch-moved-detection"

# ============================================================================
# TEST 5: Feature branch attempting to authorize its own merge (and stacked parent tampering policy)
# ============================================================================
t5_ok=true
R5="${SANDBOX}/r5-self-auth"
init_repo "$R5" "$SLUG" "main"
mkdir -p "${R5}/.b3" "${R5}/docs"
printf '{"auto_merge":"disabled","protected_paths":["releases/"],"allow_protected_paths":false,"require_ci":true,"require_review":true}\n' > "${R5}/.b3/research-policy.json"
printf '# Base\n' > "${R5}/docs/a.md"
git -C "$R5" add . && git -C "$R5" commit -qm "main disabled policy"
R5_MAIN="$(git -C "$R5" rev-parse HEAD)"

# 5a: Feature branch edits policy from disabled -> authorized targeting main
git -C "$R5" checkout -qb "feat/self-auth"
printf '{"auto_merge":"authorized","protected_paths":[],"allow_protected_paths":true,"require_ci":false,"require_review":false}\n' > "${R5}/.b3/research-policy.json"
printf 'ok\n' > "${R5}/docs/b.md"
git -C "$R5" add . && git -C "$R5" commit -qm "self-authorize"
R5_HEAD="$(git -C "$R5" rev-parse HEAD)"
fx5a="${MOCK_DATA}/t5a"
write_premerge_fixtures "$fx5a" "$SLUG" 51 "main" "$R5_MAIN" "main" "$R5_MAIN" "$R5_MAIN" "feat/self-auth" "$R5_HEAD" "alice" "bob" "$R5_HEAD" "APPROVED" "success" "completed" "clean" ".b3/research-policy.json"
run_dual "$fx5a" "mock" "merge-policy-check" \
  --repo-root "$R5" --pr-number 51 --ci-status PASS --review-status PASS \
  -- \
  -RepoRoot "$R5" -PrNumber 51 -CiStatus PASS -ReviewStatus PASS
assert_dual "05a-feature-edits-policy" 1 "^MERGE_BLOCKED: policy_modified_in_pr$" || t5_ok=false

# 5b: Stacked parent branch adds auto_merge:authorized while main has disabled; child PR targets stacked parent!
git -C "$R5" checkout -qb "feat/stacked-child" "$R5_HEAD"
printf 'child work\n' > "${R5}/docs/child.md"
git -C "$R5" add . && git -C "$R5" commit -qm "child on tampered parent"
R5_CHILD="$(git -C "$R5" rev-parse HEAD)"
fx5b="${MOCK_DATA}/t5b"
write_premerge_fixtures "$fx5b" "$SLUG" 52 "main" "$R5_MAIN" "feat/self-auth" "$R5_HEAD" "$R5_HEAD" "feat/stacked-child" "$R5_CHILD" "alice" "bob" "$R5_CHILD" "APPROVED" "success" "completed" "clean" "docs/child.md"
run_dual "$fx5b" "mock" "merge-policy-check" \
  --repo-root "$R5" --pr-number 52 --base-sha "$R5_HEAD" \
  -- \
  -RepoRoot "$R5" -PrNumber 52 -BaseSha "$R5_HEAD"
assert_dual "05b-stacked-parent-policy-tamper" 1 "^MERGE_BLOCKED: target_branch_modified_policy$" || t5_ok=false

# 5c: Main has NO policy file at all; feature branch adds .b3/research-policy.json with auto_merge:authorized
R5C="${SANDBOX}/r5c-no-auth-pol"
init_repo "$R5C" "$SLUG" "main"
mkdir -p "${R5C}/docs"
printf '# Main no policy\n' > "${R5C}/docs/a.md"
git -C "$R5C" add . && git -C "$R5C" commit -qm "main without policy"
R5C_MAIN="$(git -C "$R5C" rev-parse HEAD)"
git -C "$R5C" checkout -qb "feat/inject-pol"
mkdir -p "${R5C}/.b3"
printf '{"auto_merge":"authorized"}\n' > "${R5C}/.b3/research-policy.json"
git -C "$R5C" add . && git -C "$R5C" commit -qm "inject authorized policy"
R5C_HEAD="$(git -C "$R5C" rev-parse HEAD)"
fx5c="${MOCK_DATA}/t5c"
write_premerge_fixtures "$fx5c" "$SLUG" 53 "main" "$R5C_MAIN" "main" "$R5C_MAIN" "$R5C_MAIN" "feat/inject-pol" "$R5C_HEAD" "alice" "bob" "$R5C_HEAD" "APPROVED" "success" "completed" "clean" ".b3/research-policy.json"
run_dual "$fx5c" "mock" "merge-policy-check" \
  --repo-root "$R5C" --pr-number 53 \
  -- \
  -RepoRoot "$R5C" -PrNumber 53
assert_dual "05c-policy-not-in-authority" 1 "^MERGE_BLOCKED: policy_not_in_authority$" || t5_ok=false
$t5_ok && pass "05-feature-branch-self-authorization-blocked"

# ============================================================================
# TEST 6: Forged or stale CI/review status + branch protection checks
# ============================================================================
t6_ok=true
git -C "$R1" checkout -q "feat/pr-11"
H11_SHA="$(git -C "$R1" rev-parse HEAD)"
LED11=".b3/research-ship/runs/pr-11/ledger.md"

# 6a: Caller passes --ci-status PASS while GitHub CI is FAIL
fx6a="${MOCK_DATA}/t6a"
write_premerge_fixtures "$fx6a" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "alice" "bob" "$H11_SHA" "APPROVED" "failure" "completed" "clean" "docs/pr-main.md"
run_dual "$fx6a" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ci-status PASS --review-status PASS --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -CiStatus PASS -ReviewStatus PASS -LedgerPath "$LED11"
assert_dual "06a-forged-ci-pass-vs-gh-fail" 1 "^MERGE_BLOCKED: ci_status=FAIL$" || t6_ok=false

# 6b: Caller passes --ci-status PASS while GitHub has 0 checks (UNKNOWN)
fx6b="${MOCK_DATA}/t6b"
write_premerge_fixtures "$fx6b" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "alice" "bob" "$H11_SHA" "APPROVED" "null" "none" "clean" "docs/pr-main.md"
run_dual "$fx6b" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ci-status PASS --review-status PASS --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -CiStatus PASS -ReviewStatus PASS -LedgerPath "$LED11"
assert_dual "06b-zero-ci-checks-unknown" 1 "^MERGE_BLOCKED: ci_status=UNKNOWN$" || t6_ok=false

# 6c: Required branch protection check missing
fx6c="${MOCK_DATA}/t6c"
write_premerge_fixtures "$fx6c" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "alice" "bob" "$H11_SHA" "APPROVED" "success" "completed" "clean" "docs/pr-main.md" "$SLUG" 1 "security-scan" "true"
run_dual "$fx6c" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ci-status PASS --review-status PASS --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -CiStatus PASS -ReviewStatus PASS -LedgerPath "$LED11"
assert_dual "06c-missing-required-check" 1 "^MERGE_BLOCKED: missing_required_checks=security-scan$" || t6_ok=false

# 6d: GitHub branch protection mergeable_state=blocked
fx6d="${MOCK_DATA}/t6d"
write_premerge_fixtures "$fx6d" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "alice" "bob" "$H11_SHA" "APPROVED" "success" "completed" "blocked" "docs/pr-main.md"
run_dual "$fx6d" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ci-status PASS --review-status PASS --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -CiStatus PASS -ReviewStatus PASS -LedgerPath "$LED11"
assert_dual "06d-branch-protection-blocked" 1 "^MERGE_BLOCKED: mergeable_state=blocked$" || t6_ok=false

# 6e: Stale review (approved old commit MAIN_SHA instead of current H11_SHA)
fx6e="${MOCK_DATA}/t6e"
write_premerge_fixtures "$fx6e" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "alice" "bob" "$MAIN_SHA" "APPROVED" "success" "completed" "clean" "docs/pr-main.md"
run_dual "$fx6e" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ci-status PASS --review-status PASS --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -CiStatus PASS -ReviewStatus PASS -LedgerPath "$LED11"
assert_dual "06e-stale-review-old-sha" 1 "^MERGE_BLOCKED: stale_independent_review$" || t6_ok=false

# 6f: CHANGES_REQUESTED blocks even if caller passes --review-status PASS
fx6f="${MOCK_DATA}/t6f"
write_premerge_fixtures "$fx6f" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "alice" "bob" "$H11_SHA" "CHANGES_REQUESTED" "success" "completed" "clean" "docs/pr-main.md"
run_dual "$fx6f" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ci-status PASS --review-status PASS --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -CiStatus PASS -ReviewStatus PASS -LedgerPath "$LED11"
assert_dual "06f-changes-requested" 1 "^MERGE_BLOCKED: changes_requested$" || t6_ok=false
$t6_ok && pass "06-forged-stale-ci-review-and-branch-protection"

# ============================================================================
# TEST 7: Self-review falsely marked INDEPENDENT + review-ledger UNKNOWN default + migration
# ============================================================================
t7_ok=true
# 7a: PR author alice approves own PR while ledger claims INDEPENDENT
fx7a="${MOCK_DATA}/t7a"
write_premerge_fixtures "$fx7a" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "alice" "alice" "$H11_SHA" "APPROVED" "success" "completed" "clean" "docs/pr-main.md"
run_dual "$fx7a" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ci-status PASS --review-status PASS --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -CiStatus PASS -ReviewStatus PASS -LedgerPath "$LED11"
assert_dual "07a-self-review-falsely-independent" 1 "^MERGE_BLOCKED: self_review_not_independent$" || t7_ok=false

# 7b: review-ledger init defaults to UNKNOWN (never INDEPENDENT) and blocks merge-policy-check
LED_UNK=".b3/research-ship/runs/pr-11-unk/ledger.md"
run_dual "" "mock" "review-ledger" \
  --repo-root "$R1" --action init --ledger-path "$LED_UNK" --base-sha "$MAIN_SHA" \
  -- \
  -RepoRoot "$R1" -Action init -LedgerPath "$LED_UNK" -BaseSha "$MAIN_SHA"
assert_dual "07b-ledger-init-default" 0 "^LEDGER_INIT:" || t7_ok=false
if ! grep -qx "review_independence=UNKNOWN" "${R1}/${LED_UNK}"; then
  fail "07b-default-unknown" "expected review_independence=UNKNOWN in ${LED_UNK}"
  t7_ok=false
fi
bash "$GUARD_SH" review-ledger --repo-root "$R1" --action update --ledger-path "$LED_UNK" --unit-id U01 --status REVIEWED >/dev/null
# Local LOW-risk ledger check still works offline and reports review_independence=UNKNOWN
run_dual "" "mock" "review-ledger" \
  --repo-root "$R1" --action check --ledger-path "$LED_UNK" \
  -- \
  -RepoRoot "$R1" -Action check -LedgerPath "$LED_UNK"
assert_dual "07b-local-low-unknown-check" 0 "^LEDGER_GATE_PASS: .*review_independence=UNKNOWN$" || t7_ok=false

# Even with valid GitHub independent approval, UNKNOWN ledger blocks MERGE_AUTHORIZED
run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED_UNK" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED_UNK"
assert_dual "07b-unknown-ledger-blocks-merge" 1 "^MERGE_BLOCKED: review_independence_unknown$" || t7_ok=false

# 7c: UNKNOWN blocks HIGH/CRITICAL risk scopes in review-ledger check
R7H="${SANDBOX}/r7-high"
init_repo "$R7H" "$SLUG" "main"
mkdir -p "${R7H}/auth"
printf 'function login() { return 1; }\n' > "${R7H}/auth/login.ts"
git -C "$R7H" add . && git -C "$R7H" commit -qm "base auth"
R7H_BASE="$(git -C "$R7H" rev-parse HEAD)"
printf 'function login(tok: string) { return tok.length > 0; }\n' > "${R7H}/auth/login.ts"
git -C "$R7H" add . && git -C "$R7H" commit -qm "update auth"
bash "$GUARD_SH" verify-run --repo-root "$R7H" --verify-cmd "echo ok" --receipt-path ".b3/ship/v7.receipt" --task-id T1 --scope auth >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$R7H" --action init --ledger-path ".b3/ship/l7.md" --base-sha "$R7H_BASE" >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$R7H" --action update --ledger-path ".b3/ship/l7.md" --unit-id U01 --status REVIEWED --specialists b3-security-reviewer --receipt-path ".b3/ship/v7.receipt" >/dev/null
run_dual "" "mock" "review-ledger" \
  --repo-root "$R7H" --action check --ledger-path ".b3/ship/l7.md" \
  -- \
  -RepoRoot "$R7H" -Action check -LedgerPath ".b3/ship/l7.md"
assert_dual "07c-unknown-blocks-critical" 2 "^LEDGER_INCOMPLETE: review_independence_unknown_blocks_high_risk$" || t7_ok=false

# 7d: SINGLE_AGENT_LIMIT cannot be cleared to UNKNOWN or upgraded to INDEPENDENT
bash "$GUARD_SH" review-ledger --repo-root "$R7H" --action init --ledger-path ".b3/ship/l7-sal.md" --base-sha "$R7H_BASE" --review-independence SINGLE_AGENT_LIMIT >/dev/null
run_dual "" "mock" "review-ledger" \
  --repo-root "$R7H" --action update --ledger-path ".b3/ship/l7-sal.md" --review-independence UNKNOWN \
  -- \
  -RepoRoot "$R7H" -Action update -LedgerPath ".b3/ship/l7-sal.md" -ReviewIndependence UNKNOWN
assert_dual "07d-sal-cannot-clear-to-unknown" 1 "^LEDGER_FAIL: cannot clear SINGLE_AGENT_LIMIT$" || t7_ok=false

# 7e: Legacy ledger migration via `review-ledger normalize` backfills review_independence=UNKNOWN (never INDEPENDENT)
grep -v '^review_independence=' "${R1}/${LED_UNK}" > "${R1}/.b3/research-ship/runs/pr-11-unk/legacy-sh.md"
cp "${R1}/.b3/research-ship/runs/pr-11-unk/legacy-sh.md" "${R1}/.b3/research-ship/runs/pr-11-unk/legacy-ps.md"
SH_MIG="$(bash "$GUARD_SH" review-ledger --repo-root "$R1" --action normalize --ledger-path ".b3/research-ship/runs/pr-11-unk/legacy-sh.md")"
if [[ "$SH_MIG" != "LEDGER_NORMALIZED: path=.b3/research-ship/runs/pr-11-unk/legacy-sh.md changes=1" ]] || ! grep -qx "review_independence=UNKNOWN" "${R1}/.b3/research-ship/runs/pr-11-unk/legacy-sh.md"; then
  fail "07e-legacy-migrate-sh" "got='$SH_MIG'"
  t7_ok=false
fi
if $HAS_PWSH; then
  PS_MIG="$("$PWSH_BIN" -NoProfile -File "$GUARD_PS" review-ledger -RepoRoot "$R1" -Action normalize -LedgerPath ".b3/research-ship/runs/pr-11-unk/legacy-ps.md" | tr -d '\r')"
  if [[ "$PS_MIG" != "LEDGER_NORMALIZED: path=.b3/research-ship/runs/pr-11-unk/legacy-ps.md changes=1" ]] || ! grep -qx "review_independence=UNKNOWN" "${R1}/.b3/research-ship/runs/pr-11-unk/legacy-ps.md"; then
    fail "07e-legacy-migrate-ps" "got='$PS_MIG'"
    t7_ok=false
  fi
fi
$t7_ok && pass "07-self-review-unknown-default-and-migration"

# ============================================================================
# TEST 8: Review evidence belonging to another PR / commit / repo / fork
# ============================================================================
t8_ok=true
# 8a: Valid target_ref-bound ledger from PR #12 (develop) supplied for PR #11 (main) -> ledger_target_mismatch
LED_PR12_REF=".b3/research-ship/runs/pr-12-ref/ledger.md"
bash "$GUARD_SH" review-ledger --repo-root "$R1" --action init --ledger-path "$LED_PR12_REF" --base-sha "$DEV_SHA" --target-ref "feat/pr-12" --review-independence INDEPENDENT >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$R1" --action update --ledger-path "$LED_PR12_REF" --unit-id U01 --status REVIEWED >/dev/null
run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED_PR12_REF" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED_PR12_REF"
assert_dual "08a-ledger-from-other-pr-target" 1 "^MERGE_BLOCKED: ledger_target_mismatch$" || t8_ok=false

# 8a2: Valid target_ref-bound ledger on same base (main) for a DIFFERENT branch/commit -> ledger_head_mismatch
LED_OTHER_HEAD=".b3/research-ship/runs/pr-other-head/ledger.md"
bash "$GUARD_SH" review-ledger --repo-root "$R1" --action init --ledger-path "$LED_OTHER_HEAD" --base-sha "$MAIN_SHA" --target-ref "develop" --review-independence INDEPENDENT >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$R1" --action update --ledger-path "$LED_OTHER_HEAD" --unit-id U01 --status REVIEWED >/dev/null
run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED_OTHER_HEAD" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED_OTHER_HEAD"
assert_dual "08a2-ledger-from-other-commit" 1 "^MERGE_BLOCKED: ledger_head_mismatch$" || t8_ok=false

# 8b: Cross-repo mismatch (--repo other/repo while origin is octo/b3-demo)
run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --repo "evil/other" --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -Repo "evil/other" -LedgerPath "$LED11"
assert_dual "08b-cross-repo-flag" 1 "^MERGE_BLOCKED: repo_mismatch$" || t8_ok=false

# 8c: Fork PR (head.repo != base.repo)
fx8c="${MOCK_DATA}/t8c"
write_premerge_fixtures "$fx8c" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "alice" "bob" "$H11_SHA" "APPROVED" "success" "completed" "clean" "docs/pr-main.md" "forkuser/b3-demo"
run_dual "$fx8c" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "08c-fork-pr-blocked" 1 "^MERGE_BLOCKED: cross_repo_head_pr$" || t8_ok=false

# 8d: GitHub PR head_sha differs from local HEAD (evidence for another commit)
fx8d="${MOCK_DATA}/t8d"
write_premerge_fixtures "$fx8d" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$DEV_SHA" "alice" "bob" "$DEV_SHA" "APPROVED" "success" "completed" "clean" "docs/pr-main.md"
run_dual "$fx8d" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "08d-head-sha-mismatch" 1 "^MERGE_BLOCKED: head_sha_mismatch$" || t8_ok=false
$t8_ok && pass "08-cross-pr-commit-repo-fork-isolation"

# ============================================================================
# TEST 9 & 10: Post-Merge verification (merge commit, squash, rebase, stacked/non-default targets, negative identity/branch/status)
# ============================================================================
t9_ok=true
R9="${SANDBOX}/r9-postmerge"
init_repo "$R9" "$SLUG" "main"
mkdir -p "${R9}/docs"
printf '# Main v1\n' > "${R9}/docs/main.md"
git -C "$R9" add . && git -C "$R9" commit -qm "main v1"
R9_MAIN0="$(git -C "$R9" rev-parse HEAD)"

# (A) Merge-commit PR #91 into main
git -C "$R9" checkout -qb "feat/mc"
printf 'mc\n' > "${R9}/docs/mc.md"
git -C "$R9" add . && git -C "$R9" commit -qm "mc work"
MC_HEAD="$(git -C "$R9" rev-parse HEAD)"
git -C "$R9" checkout -q main
git -C "$R9" merge --no-ff -qm "Merge PR #91" "feat/mc"
MC_MERGE_SHA="$(git -C "$R9" rev-parse HEAD)"

# (B) Squash-merge PR #92 into develop
git -C "$R9" checkout -qb develop "$R9_MAIN0"
printf 'dev base\n' > "${R9}/docs/dev.md"
git -C "$R9" add . && git -C "$R9" commit -qm "dev base"
DEV_BASE="$(git -C "$R9" rev-parse HEAD)"
git -C "$R9" checkout -qb "feat/sq" "$DEV_BASE"
printf 'sq1\n' > "${R9}/docs/sq.md"
git -C "$R9" add . && git -C "$R9" commit -qm "sq commit 1"
printf 'sq2\n' >> "${R9}/docs/sq.md"
git -C "$R9" add . && git -C "$R9" commit -qm "sq commit 2"
SQ_HEAD="$(git -C "$R9" rev-parse HEAD)"
git -C "$R9" checkout -q develop
git -C "$R9" merge --squash -q "feat/sq"
git -C "$R9" commit -qm "feat: squashed (#92)"
SQ_MERGE_SHA="$(git -C "$R9" rev-parse HEAD)"

# (C) Rebase-merge PR #93 into stacked target feature/parent
git -C "$R9" checkout -qb "feature/parent" "$R9_MAIN0"
printf 'parent 1\n' > "${R9}/docs/p.md"
git -C "$R9" add . && git -C "$R9" commit -qm "parent 1"
P_BASE="$(git -C "$R9" rev-parse HEAD)"
git -C "$R9" checkout -qb "feat/rb-orig" "$P_BASE"
printf 'rb1\n' > "${R9}/docs/rb.md"
git -C "$R9" add . && git -C "$R9" commit -qm "rb commit 1"
RB_ORIG_HEAD="$(git -C "$R9" rev-parse HEAD)"
# Advance feature/parent, then rebase onto it (producing a new commit SHA != RB_ORIG_HEAD)
git -C "$R9" checkout -q "feature/parent"
printf 'parent 2\n' >> "${R9}/docs/p.md"
git -C "$R9" add . && git -C "$R9" commit -qm "parent 2"
git -C "$R9" cherry-pick "$RB_ORIG_HEAD" >/dev/null 2>&1
RB_MERGE_SHA="$(git -C "$R9" rev-parse HEAD)"

# 10a: Merge commit into main -> POST_MERGE_VERIFIED (merge_kind=merge_commit)
fx10a="${MOCK_DATA}/t10a"
write_postmerge_fixtures "$fx10a" "$SLUG" 91 "main" "main" "$MC_HEAD" "closed" "true" "$MC_MERGE_SHA" "$MC_MERGE_SHA" "identical" 0
run_dual "$fx10a" "mock" "merge-policy-check" \
  --repo-root "$R9" --post-merge --pr-number 91 --main-ref main --merged-sha "$MC_MERGE_SHA" \
  -- \
  -RepoRoot "$R9" -PostMerge -PrNumber 91 -MainRef main -MergedSha "$MC_MERGE_SHA"
assert_dual "10a-merge-commit-main" 0 "^POST_MERGE_VERIFIED: pr=${SLUG}#91 pr_status=PR_MERGED sha=${MC_MERGE_SHA} target_ref=main main_ref=main merge_kind=merge_commit runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED$" || t9_ok=false

# 10b: Squash merge into develop -> POST_MERGE_VERIFIED (merge_kind=squash_or_rebase)
fx10b="${MOCK_DATA}/t10b"
write_postmerge_fixtures "$fx10b" "$SLUG" 92 "main" "develop" "$SQ_HEAD" "closed" "true" "$SQ_MERGE_SHA" "$SQ_MERGE_SHA" "identical" 0
run_dual "$fx10b" "mock" "merge-policy-check" \
  --repo-root "$R9" --post-merge --pr-number 92 --main-ref develop \
  -- \
  -RepoRoot "$R9" -PostMerge -PrNumber 92 -MainRef develop
assert_dual "10b-squash-develop" 0 "^POST_MERGE_VERIFIED: pr=${SLUG}#92 pr_status=PR_MERGED sha=${SQ_MERGE_SHA} target_ref=develop main_ref=develop merge_kind=squash_or_rebase runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED$" || t9_ok=false

# 10c: Rebase merge into stacked feature/parent -> POST_MERGE_VERIFIED (merge_kind=squash_or_rebase)
fx10c="${MOCK_DATA}/t10c"
write_postmerge_fixtures "$fx10c" "$SLUG" 93 "main" "feature/parent" "$RB_ORIG_HEAD" "closed" "true" "$RB_MERGE_SHA" "$RB_MERGE_SHA" "ahead" 0
run_dual "$fx10c" "mock" "merge-policy-check" \
  --repo-root "$R9" --post-merge --pr-number 93 --main-ref "feature/parent" \
  -- \
  -RepoRoot "$R9" -PostMerge -PrNumber 93 -MainRef "feature/parent"
assert_dual "10c-rebase-stacked-parent" 0 "^POST_MERGE_VERIFIED: pr=${SLUG}#93 pr_status=PR_MERGED sha=${RB_MERGE_SHA} target_ref=feature/parent main_ref=feature/parent merge_kind=squash_or_rebase runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED$" || t9_ok=false

# 9a: Caller claims --pr-state MERGED on an OPEN PR -> POST_MERGE_FAILED: pr_not_merged
fx9a="${MOCK_DATA}/t9a"
write_postmerge_fixtures "$fx9a" "$SLUG" 94 "main" "main" "$MC_HEAD" "open" "false" "" "$MC_MERGE_SHA" "" -1
run_dual "$fx9a" "mock" "merge-policy-check" \
  --repo-root "$R9" --post-merge --pr-state MERGED --pr-number 94 --main-ref main --merged-sha "$MC_MERGE_SHA" \
  -- \
  -RepoRoot "$R9" -PostMerge -PrState MERGED -PrNumber 94 -MainRef main -MergedSha "$MC_MERGE_SHA"
assert_dual "09a-forged-merged-status" 1 "^POST_MERGE_FAILED: pr_not_merged\(state=OPEN,merged=false\)$" || t9_ok=false

# 9b: Wrong target branch (--main-ref main when PR #92 merged into develop)
run_dual "$fx10b" "mock" "merge-policy-check" \
  --repo-root "$R9" --post-merge --pr-number 92 --main-ref main \
  -- \
  -RepoRoot "$R9" -PostMerge -PrNumber 92 -MainRef main
assert_dual "09b-wrong-target-branch" 1 "^POST_MERGE_FAILED: target_branch_mismatch\(expected=develop,got=main\)$" || t9_ok=false

# 9c: Caller supplies wrong MergedSha (belongs to main, not PR #92)
run_dual "$fx10b" "mock" "merge-policy-check" \
  --repo-root "$R9" --post-merge --pr-number 92 --main-ref develop --merged-sha "$MC_MERGE_SHA" \
  -- \
  -RepoRoot "$R9" -PostMerge -PrNumber 92 -MainRef develop -MergedSha "$MC_MERGE_SHA"
assert_dual "09c-wrong-merged-sha" 1 "^POST_MERGE_FAILED: merge_commit_sha_mismatch" || t9_ok=false

# 9d: Missing --pr-number in --post-merge fails closed (Git ancestry alone insufficient!)
run_dual "$fx10a" "mock" "merge-policy-check" \
  --repo-root "$R9" --post-merge --pr-state MERGED --main-ref main --merged-sha "$MC_MERGE_SHA" \
  -- \
  -RepoRoot "$R9" -PostMerge -PrState MERGED -MainRef main -MergedSha "$MC_MERGE_SHA"
assert_dual "09d-missing-pr-number-postmerge" 1 "^POST_MERGE_FAILED: missing_pr_number$" || t9_ok=false

# 9e: Remote target branch force-pushed / diverged (merge_commit_sha not in remote target)
fx9e="${MOCK_DATA}/t9e"
write_postmerge_fixtures "$fx9e" "$SLUG" 91 "main" "main" "$MC_HEAD" "closed" "true" "$MC_MERGE_SHA" "$R9_MAIN0" "diverged" 1
run_dual "$fx9e" "mock" "merge-policy-check" \
  --repo-root "$R9" --post-merge --pr-number 91 --main-ref main \
  -- \
  -RepoRoot "$R9" -PostMerge -PrNumber 91 -MainRef main
assert_dual "09e-remote-diverged" 1 "^POST_MERGE_FAILED: merge_commit_not_in_remote_target" || t9_ok=false
$t9_ok && pass "09-10-post-merge-identity-and-all-merge-strategies"

# ============================================================================
# TEST 11: Missing GitHub API / provider access (NEVER produces MERGE_AUTHORIZED)
# ============================================================================
t11_ok=true
# 11a: `gh` unavailable on PATH
run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ci-status PASS --review-status PASS --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -CiStatus PASS -ReviewStatus PASS -LedgerPath "$LED11"
assert_dual "11a-missing-gh-cli" 1 "^MERGE_BLOCKED: github_verification_failed\(gh_cli_unavailable\)$" || t11_ok=false

# 11b: GitHub API returns 401 auth failure
fx11b="${MOCK_DATA}/t11b"
mkdir -p "$fx11b"
echo "HTTP 401: Bad credentials" > "${fx11b}/repos__${SLUG//\//__}__pulls__11.err"
run_dual "$fx11b" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ci-status PASS --review-status PASS --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -CiStatus PASS -ReviewStatus PASS -LedgerPath "$LED11"
assert_dual "11b-gh-auth-401" 1 "^MERGE_BLOCKED: github_verification_failed\(github_auth_failed\)$" || t11_ok=false

# 11c: Missing --pr-number with auto_merge:authorized fails closed (never MERGE_AUTHORIZED)
run_dual "" "mock" "merge-policy-check" \
  --repo-root "$R1" --base-sha "$MAIN_SHA" --ledger-path "$LED11" --pr-state OPEN --ci-status PASS --review-status PASS --changed-paths "docs/pr-main.md" \
  -- \
  -RepoRoot "$R1" -BaseSha "$MAIN_SHA" -LedgerPath "$LED11" -PrState OPEN -CiStatus PASS -ReviewStatus PASS -ChangedPaths "docs/pr-main.md"
assert_dual "11c-missing-pr-number-premerge" 1 "^MERGE_BLOCKED: missing_pr_number$" || t11_ok=false

# 11d: Explicit --local-only returns LOCAL_ELIGIBLE_ONLY (exit 2, NEVER MERGE_AUTHORIZED)
run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$R1" --local-only --base-sha "$MAIN_SHA" --ledger-path "$LED11" --pr-state OPEN --ci-status PASS --review-status PASS --changed-paths "docs/pr-main.md" \
  -- \
  -RepoRoot "$R1" -LocalOnly -BaseSha "$MAIN_SHA" -LedgerPath "$LED11" -PrState OPEN -CiStatus PASS -ReviewStatus PASS -ChangedPaths "docs/pr-main.md"
assert_dual "11d-local-only-never-authorizes" 2 "^LOCAL_ELIGIBLE_ONLY: remote_provider_required$" || t11_ok=false
$t11_ok && pass "11-missing-provider-and-offline-separation"

# ============================================================================
# TEST 12: Backward compatibility (offline auto_merge=disabled -> PR_READY exit 2)
# ============================================================================
t12_ok=true
git -C "$R5" checkout -q main
run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$R5" --pr-state OPEN --ci-status PASS --review-status PASS --changed-paths "docs/a.md" \
  -- \
  -RepoRoot "$R5" -PrState OPEN -CiStatus PASS -ReviewStatus PASS -ChangedPaths "docs/a.md"
assert_dual "12a-offline-disabled-pr-ready" 2 "^PR_READY: auto_merge=disabled$" || t12_ok=false

run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$R5" --pr-state OPEN --ci-status PASS --review-status PASS --changed-paths "releases/v1.json" \
  -- \
  -RepoRoot "$R5" -PrState OPEN -CiStatus PASS -ReviewStatus PASS -ChangedPaths "releases/v1.json"
assert_dual "12b-offline-protected-path-blocked" 1 "^MERGE_BLOCKED: protected_paths=releases/v1\.json$" || t12_ok=false
$t12_ok && pass "12-ps-bash-parity-and-backward-compat"

# ============================================================================
# TEST 13: Security Review Hardening Regressions
# ============================================================================
t13_ok=true

# 13a: Policy substitution via --policy-path pointing to committed fixture on default_branch
R13="${SANDBOX}/r13-hardening"
init_repo "$R13" "$SLUG" "main"
mkdir -p "${R13}/.b3" "${R13}/tests" "${R13}/docs"
printf '{"auto_merge":"disabled","protected_paths":[],"allow_protected_paths":false,"require_ci":true,"require_review":true}\n' > "${R13}/.b3/research-policy.json"
printf '{"auto_merge":"authorized","protected_paths":[],"allow_protected_paths":true,"require_ci":false,"require_review":false}\n' > "${R13}/tests/fake-auth-policy.json"
printf '# Base\n' > "${R13}/docs/base.md"
git -C "$R13" add . && git -C "$R13" commit -qm "init r13 with disabled policy and committed fixture"
R13_MAIN="$(git -C "$R13" rev-parse HEAD)"
git -C "$R13" checkout -qb "feat/pol-sub"
printf 'work\n' > "${R13}/docs/work.md"
git -C "$R13" add . && git -C "$R13" commit -qm "feature work"
R13_HEAD="$(git -C "$R13" rev-parse HEAD)"
LED13=".b3/research-ship/runs/r13/ledger.md"
bash "$GUARD_SH" review-ledger --repo-root "$R13" --action init --ledger-path "$LED13" --base-sha "$R13_MAIN" --review-independence INDEPENDENT >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$R13" --action update --ledger-path "$LED13" --unit-id U01 --status REVIEWED >/dev/null
fx13a="${MOCK_DATA}/t13a"
write_premerge_fixtures "$fx13a" "$SLUG" 130 "main" "$R13_MAIN" "main" "$R13_MAIN" "$R13_MAIN" "feat/pol-sub" "$R13_HEAD" "alice" "bob" "$R13_HEAD" "APPROVED" "success" "completed" "clean" "docs/work.md"
run_dual "$fx13a" "mock" "merge-policy-check" \
  --repo-root "$R13" --pr-number 130 --policy-path "tests/fake-auth-policy.json" --ledger-path "$LED13" \
  -- \
  -RepoRoot "$R13" -PrNumber 130 -PolicyPath "tests/fake-auth-policy.json" -LedgerPath "$LED13"
assert_dual "13a-policy-path-substitution-blocked" 1 "^MERGE_BLOCKED: policy_path_override_not_allowed$" || t13_ok=false

# 13b/13c/13d: origin remote binding (non-GitHub blocked, missing origin blocked, credential+mixed-case HTTPS allowed)
git -C "$R1" checkout -q "feat/pr-11"
H11_SHA="$(git -C "$R1" rev-parse HEAD)"
LED11=".b3/research-ship/runs/pr-11/ledger.md"
git -C "$R1" remote set-url origin "https://gitlab.example.com/${SLUG}.git"
run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --repo "$SLUG" --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -Repo "$SLUG" -LedgerPath "$LED11"
assert_dual "13b-non-github-origin-blocked" 1 "^MERGE_BLOCKED: origin_remote_not_github$" || t13_ok=false

git -C "$R1" remote remove origin
run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --repo "$SLUG" --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -Repo "$SLUG" -LedgerPath "$LED11"
assert_dual "13c-missing-origin-blocked" 1 "^MERGE_BLOCKED: origin_remote_missing$" || t13_ok=false

git -C "$R1" remote add origin "https://x-access-token:ghs_test123@GitHub.com/${SLUG}.git"
run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "13d-cred-mixedcase-https-origin-allowed" 0 "^MERGE_AUTHORIZED: pr=${SLUG}#11 " || t13_ok=false
git -C "$R1" remote set-url origin "https://github.com/${SLUG}.git"

# 13e/13f: Unauthorized external reviewer (author_association=NONE) and Bot reviewer rejected
fx13e="${MOCK_DATA}/t13e"
write_premerge_fixtures "$fx13e" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "alice" "driveby" "$H11_SHA" "APPROVED" "success" "completed" "clean" "docs/pr-main.md" "$SLUG" 0 "" "false" "User" "NONE"
run_dual "$fx13e" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "13e-external-user-review-blocked" 1 "^MERGE_BLOCKED: unauthorized_reviewer_not_independent$" || t13_ok=false

fx13f="${MOCK_DATA}/t13f"
write_premerge_fixtures "$fx13f" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "alice" "helper-bot" "$H11_SHA" "APPROVED" "success" "completed" "clean" "docs/pr-main.md" "$SLUG" 0 "" "false" "Bot" "COLLABORATOR"
run_dual "$fx13f" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "13f-bot-review-blocked" 1 "^MERGE_BLOCKED: unauthorized_reviewer_not_independent$" || t13_ok=false

# 13g: Cross-app duplicate check-run name cannot mask failure
fx13g="${MOCK_DATA}/t13g"
write_premerge_fixtures "$fx13g" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "alice" "bob" "$H11_SHA" "APPROVED" "success" "completed" "clean" "docs/pr-main.md"
cat > "${fx13g}/repos__${SLUG//\//__}__commits__${H11_SHA}__check-runs.json" <<EOF
{
  "total_count": 2,
  "check_runs": [
    { "id": 500, "name": "ci/build-test", "app": { "id": 100 }, "head_sha": "${H11_SHA}", "status": "completed", "conclusion": "failure" },
    { "id": 999, "name": "ci/build-test", "app": { "id": 200 }, "head_sha": "${H11_SHA}", "status": "completed", "conclusion": "success" }
  ]
}
EOF
run_dual "$fx13g" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "13g-cross-app-check-failure-not-masked" 1 "^MERGE_BLOCKED: ci_status=FAIL$" || t13_ok=false

# 13h: All-skipped CI checks do not count as PASS
fx13h="${MOCK_DATA}/t13h"
write_premerge_fixtures "$fx13h" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "alice" "bob" "$H11_SHA" "APPROVED" "skipped" "completed" "clean" "docs/pr-main.md"
run_dual "$fx13h" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "13h-all-skipped-ci-unknown" 1 "^MERGE_BLOCKED: ci_status=UNKNOWN$" || t13_ok=false

# 13i: Classic branch protection HTTP 403 enforces >=1 fresh independent review even when policy require_review=false
R13P="${SANDBOX}/r13p-prot"
init_repo "$R13P" "$SLUG" "main"
mkdir -p "${R13P}/.b3" "${R13P}/docs"
printf '{"auto_merge":"authorized","protected_paths":[],"allow_protected_paths":false,"require_ci":true,"require_review":false,"allowed_target_branches":["main","release/*"]}\n' > "${R13P}/.b3/research-policy.json"
printf '# Base\n' > "${R13P}/docs/a.md"
git -C "$R13P" add . && git -C "$R13P" commit -qm "init r13p"
R13P_MAIN="$(git -C "$R13P" rev-parse HEAD)"
git -C "$R13P" checkout -qb "feat/prot-test"
printf 'x\n' > "${R13P}/docs/x.md"
git -C "$R13P" add . && git -C "$R13P" commit -qm "feat work"
R13P_HEAD="$(git -C "$R13P" rev-parse HEAD)"
LED13P=".b3/research-ship/runs/r13p/ledger.md"
bash "$GUARD_SH" review-ledger --repo-root "$R13P" --action init --ledger-path "$LED13P" --base-sha "$R13P_MAIN" --review-independence INDEPENDENT >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$R13P" --action update --ledger-path "$LED13P" --unit-id U01 --status REVIEWED >/dev/null
fx13i="${MOCK_DATA}/t13i"
write_premerge_fixtures "$fx13i" "$SLUG" 131 "main" "$R13P_MAIN" "main" "$R13P_MAIN" "$R13P_MAIN" "feat/prot-test" "$R13P_HEAD" "alice" "" "" "" "success" "completed" "clean" "docs/x.md" "$SLUG" 0 "" "true"
rm -f "${fx13i}/repos__${SLUG//\//__}__branches__main__protection.json"
echo "HTTP 403 Forbidden" > "${fx13i}/repos__${SLUG//\//__}__branches__main__protection.err"
run_dual "$fx13i" "mock" "merge-policy-check" \
  --repo-root "$R13P" --pr-number 131 --ledger-path "$LED13P" \
  -- \
  -RepoRoot "$R13P" -PrNumber 131 -LedgerPath "$LED13P"
assert_dual "13i-unreadable-protection-requires-review" 1 "^MERGE_BLOCKED: insufficient_independent_reviews\(have=0,need=1\)$" || t13_ok=false

# 13j: allowed_target_branches blocks develop and allows release/*
git -C "$R13P" checkout -qb "develop" "$R13P_MAIN"
R13P_DEV="$(git -C "$R13P" rev-parse HEAD)"
git -C "$R13P" checkout -q "feat/prot-test"
fx13j1="${MOCK_DATA}/t13j1"
write_premerge_fixtures "$fx13j1" "$SLUG" 132 "main" "$R13P_MAIN" "develop" "$R13P_DEV" "$R13P_DEV" "feat/prot-test" "$R13P_HEAD" "alice" "bob" "$R13P_HEAD" "APPROVED" "success" "completed" "clean" "docs/x.md"
run_dual "$fx13j1" "mock" "merge-policy-check" \
  --repo-root "$R13P" --pr-number 132 --ledger-path "$LED13P" \
  -- \
  -RepoRoot "$R13P" -PrNumber 132 -LedgerPath "$LED13P"
assert_dual "13j1-disallowed-target-branch-blocked" 1 "^MERGE_BLOCKED: target_branch_not_allowed\(develop\)$" || t13_ok=false

fx13j2="${MOCK_DATA}/t13j2"
write_premerge_fixtures "$fx13j2" "$SLUG" 133 "main" "$R13P_MAIN" "release/2026.11" "$R13P_MAIN" "$R13P_MAIN" "feat/prot-test" "$R13P_HEAD" "alice" "bob" "$R13P_HEAD" "APPROVED" "success" "completed" "clean" "docs/x.md"
run_dual "$fx13j2" "mock" "merge-policy-check" \
  --repo-root "$R13P" --pr-number 133 --ledger-path "$LED13P" \
  -- \
  -RepoRoot "$R13P" -PrNumber 133 -LedgerPath "$LED13P"
assert_dual "13j2-allowed-wildcard-target-branch-passes" 0 "^MERGE_AUTHORIZED: pr=${SLUG}#133 target_ref=release/2026\.11 " || t13_ok=false

# 13k: review-ledger update advancing head_sha without --review-independence resets INDEPENDENT -> UNKNOWN
printf 'second commit\n' >> "${R13P}/docs/x.md"
git -C "$R13P" add . && git -C "$R13P" commit -qm "advance head"
LED13K_SH=".b3/research-ship/runs/r13k-sh/ledger.md"
LED13K_PS=".b3/research-ship/runs/r13k-ps/ledger.md"
mkdir -p "${R13P}/$(dirname "$LED13K_SH")" "${R13P}/$(dirname "$LED13K_PS")"
cp "${R13P}/${LED13P}" "${R13P}/${LED13K_SH}"
cp "${R13P}/${LED13P}" "${R13P}/${LED13K_PS}"
set +e
U_SH="$(bash "$GUARD_SH" review-ledger --repo-root "$R13P" --action update --ledger-path "$LED13K_SH" --unit-id U01 --status REVIEWED 2>&1)"
U_SH_RC=$?
if $HAS_PWSH; then
  U_PS="$("$PWSH_BIN" -NoProfile -File "$GUARD_PS" review-ledger -RepoRoot "$R13P" -Action update -LedgerPath "$LED13K_PS" -UnitId U01 -Status REVIEWED 2>&1)"
  U_PS_RC=$?
else
  U_PS="$U_SH"; U_PS_RC=$U_SH_RC
fi
C_SH="$(bash "$GUARD_SH" review-ledger --repo-root "$R13P" --action check --ledger-path "$LED13K_SH" 2>&1)"
C_SH_RC=$?
if $HAS_PWSH; then
  C_PS="$("$PWSH_BIN" -NoProfile -File "$GUARD_PS" review-ledger -RepoRoot "$R13P" -Action check -LedgerPath "$LED13K_PS" 2>&1)"
  C_PS_RC=$?
else
  C_PS="$C_SH"; C_PS_RC=$C_SH_RC
fi
set -e
if [[ "$U_SH_RC" -ne 0 || "$U_PS_RC" -ne 0 || "$C_SH_RC" -ne 0 || "$C_PS_RC" -ne 0 || ! "$C_SH" =~ review_independence=UNKNOWN || ! "$C_PS" =~ review_independence=UNKNOWN ]]; then
  fail "13k-head-advance-resets-independence-to-unknown" "u=($U_SH_RC/$U_PS_RC) c_sh=($C_SH_RC:'$C_SH') c_ps=($C_PS_RC:'$C_PS')"
  t13_ok=false
fi
$t13_ok && pass "13-security-review-hardening-regressions"

printf '\nSummary: passed=%d failed=%d pwsh=%s\n' "$PASS_CNT" "$FAIL_CNT" "$HAS_PWSH"
if [[ "$FAIL_CNT" -gt 0 ]]; then
  exit 1
fi
if ! $HAS_PWSH; then
  if $ALLOW_INCOMPLETE_PWSH; then
    echo "ok (bash-only; pwsh skipped - --allow-incomplete-pwsh)"
    exit 0
  fi
  echo "INCOMPLETE: pwsh unavailable (use --allow-incomplete-pwsh to accept bash-only)"
  exit 2
fi
echo "ok"
exit 0
