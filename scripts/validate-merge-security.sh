#!/usr/bin/env bash
# Dual-shell behavioral regression suite for provider-neutral merge-policy-check & thin b3-github-verify (v2).
# Exercises BOTH scripts/b3-guard.sh and scripts/b3-guard.ps1 (pwsh or Windows PowerShell)
# with a test-scoped mock `gh` executable on PATH (zero production mock flags).
# Usage: ./scripts/validate-merge-security.sh [--pwsh /path/to/pwsh] [--allow-incomplete-pwsh]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GUARD_SH="${REPO_ROOT}/scripts/b3-guard.sh"
GUARD_PS="${REPO_ROOT}/scripts/b3-guard.ps1"
GH_VERIFY_SH="${REPO_ROOT}/scripts/b3-github-verify.sh"
GH_VERIFY_PS="${REPO_ROOT}/scripts/b3-github-verify.ps1"

PWSH_BIN=""
ALLOW_INCOMPLETE_PWSH=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pwsh) PWSH_BIN="${2:-}"; shift 2 ;;
    --allow-incomplete-pwsh) ALLOW_INCOMPLETE_PWSH=true; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

is_winapps_stub() {
  local p="${1//\\//}"
  [[ "$p" == */[Mm]icrosoft/[Ww]indows[Aa]pps/* ]]
}

find_non_stub_bin() {
  local name="$1" cand=""
  cand="$(command -v "$name" 2>/dev/null || true)"
  if [[ -n "$cand" ]] && ! is_winapps_stub "$cand" && [[ -x "$cand" || -f "$cand" ]]; then
    printf '%s' "$cand"
    return 0
  fi
  return 1
}

if [[ -z "$PWSH_BIN" ]]; then
  if PWSH_BIN="$(find_non_stub_bin pwsh)"; then
    :
  elif [[ -x "/tmp/pwsh/pwsh" ]]; then
    PWSH_BIN="/tmp/pwsh/pwsh"
  elif PWSH_BIN="$(find_non_stub_bin pwsh.exe)"; then
    :
  elif PWSH_BIN="$(find_non_stub_bin powershell.exe)"; then
    :
  elif PWSH_BIN="$(find_non_stub_bin powershell)"; then
    :
  elif [[ -f "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]]; then
    PWSH_BIN="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  fi
fi

HAS_PWSH=false
if [[ -n "$PWSH_BIN" && ( -x "$PWSH_BIN" || -f "$PWSH_BIN" ) ]] && ! is_winapps_stub "$PWSH_BIN"; then
  HAS_PWSH=true
fi

HAS_CYGPATH=false
if command -v cygpath >/dev/null 2>&1; then
  HAS_CYGPATH=true
fi

to_win_path() {
  local p="$1"
  if [[ -z "$p" ]]; then
    printf ''
    return 0
  fi
  if $HAS_CYGPATH; then
    cygpath -w "$p"
  else
    printf '%s' "$p"
  fi
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/b3-merge-sec-XXXXXX")"
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

MOCK_BIN="${SANDBOX}/mock-bin"
NOGH_BIN="${SANDBOX}/nogh-bin"
NOGH_WIN_SHIMS="${SANDBOX}/nogh-win-shims"
MOCK_DATA="${SANDBOX}/mock-data"
SEED_REPO="${SANDBOX}/_seed-repo"
mkdir -p "$MOCK_BIN" "$NOGH_BIN" "$NOGH_WIN_SHIMS" "$MOCK_DATA" "$SEED_REPO"

REAL_BASH="$(command -v bash)"
SHIM_SHEBANG="#!/usr/bin/env bash"
if [[ -n "$REAL_BASH" && "$REAL_BASH" != *" "* ]]; then
  SHIM_SHEBANG="#!${REAL_BASH}"
fi

for _tool in bash sh git awk mawk gawk sed tr sort paste mktemp cat rm mv cp chmod dirname basename head tail wc grep cut uniq env pwd readlink realpath node python3 python cygpath; do
  _tp="$(command -v "$_tool" 2>/dev/null || true)"
  if [[ -n "$_tp" && -x "$_tp" ]] && ! is_winapps_stub "$_tp" && [[ ! -e "${NOGH_BIN}/${_tool}" ]]; then
    if [[ "$_tool" == "bash" || "$_tool" == "env" ]]; then
      printf '%s\nexec "%s" "$@"\n' "$SHIM_SHEBANG" "$_tp" > "${NOGH_BIN}/${_tool}"
    else
      printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$_tp" > "${NOGH_BIN}/${_tool}"
    fi
    chmod +x "${NOGH_BIN}/${_tool}"
  fi
done

dir_has_gh() {
  local d="$1"
  [[ -n "$d" && -d "$d" ]] || return 1
  local n
  for n in gh gh.exe gh.cmd gh.bat gh.com; do
    if [[ -f "${d}/${n}" ]]; then
      return 0
    fi
  done
  return 1
}

GUARD_PS_WIN="$(to_win_path "$GUARD_PS")"
GH_VERIFY_PS_WIN="$(to_win_path "$GH_VERIFY_PS")"

# Build a clean PATH for PowerShell `nogh` runs (preserving System32, Git cmd/bin, and Node without any real `gh`)
PS_NOGH_PATH="$NOGH_BIN"
if $HAS_PWSH && $HAS_CYGPATH; then
  _ps_dirs=("$NOGH_WIN_SHIMS")
  _sysroot_u="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}" 2>/dev/null || printf '/c/Windows')"
  for _sd in "${_sysroot_u}/System32" "${_sysroot_u}" "$(dirname "$PWSH_BIN")"; do
    if [[ -d "$_sd" ]] && ! dir_has_gh "$_sd"; then
      _ps_dirs+=("$_sd")
    fi
  done
  for _git_cmd_cand in "/cmd" "$(cygpath -u "${PROGRAMFILES:-C:\\Program Files}\\Git\\cmd" 2>/dev/null || true)"; do
    if [[ -n "$_git_cmd_cand" && -d "$_git_cmd_cand" && -f "${_git_cmd_cand}/git.exe" ]] && ! dir_has_gh "$_git_cmd_cand"; then
      _ps_dirs+=("$_git_cmd_cand")
      break
    fi
  done
  for _bin_name in git node; do
    _bp="$(find_non_stub_bin "$_bin_name" || true)"
    if [[ -n "$_bp" ]]; then
      _bd="$(dirname "$_bp")"
      if ! dir_has_gh "$_bd"; then
        _ps_dirs+=("$_bd")
      else
        _bp_w="$(cygpath -w "$_bp")"
        printf '@echo off\r\n"%s" %%*\r\n' "$_bp_w" > "${NOGH_WIN_SHIMS}/${_bin_name}.cmd"
      fi
    fi
  done
  PS_NOGH_PATH="$(IFS=:; printf '%s' "${_ps_dirs[*]}")"
fi

# Cache a seed `.git` directory once to avoid repeated `git init` / `git config` spawns
git -C "$SEED_REPO" init -q
git -C "$SEED_REPO" symbolic-ref HEAD "refs/heads/main"
git -C "$SEED_REPO" config user.email "sec-test@example.com"
git -C "$SEED_REPO" config user.name "Sec Test"
git -C "$SEED_REPO" config core.autocrlf false

# Test-scoped extensionless POSIX mock `gh` CLI reading fixtures from B3_TEST_GH_DIR
cat > "${MOCK_BIN}/gh" <<'MOCK_GH_EOF'
#!/usr/bin/env bash
set -euo pipefail
dir="${B3_TEST_GH_DIR:-}"
dir="${dir//\\//}"
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
    -H|--header|-X|--method|-f|-F|--field|--raw-field|--jq|-q) shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
clean="${endpoint%%\?*}"
clean="${clean#/}"
key="${clean//%2F/__}"
key="${key//%2f/__}"
key="${key//\//__}"
if [[ -f "${dir}/${key}.err" ]]; then
  printf '%s\n' "$(<"${dir}/${key}.err")" >&2
  exit 1
fi
if [[ -f "${dir}/${key}.json" ]]; then
  body="$(<"${dir}/${key}.json")"
  if $slurp; then
    printf '[%s]\n' "$body"
  else
    printf '%s\n' "$body"
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

# Dual-shell invocation helper: runs b3-guard.sh and (if available) b3-guard.ps1 with equivalent PATH/env
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
  local conv_next=false
  while [[ $# -gt 0 ]]; do
    if $conv_next; then
      ps_args+=("$(to_win_path "$1")")
      conv_next=false
    else
      ps_args+=("$1")
      if [[ "$1" == "-RepoRoot" || "$1" == "--repo-root" ]]; then
        conv_next=true
      fi
    fi
    shift
  done

  local sh_path="$PATH"
  local ps_path="$PATH"
  if [[ "$use_mock_path" == "mock" ]]; then
    sh_path="${MOCK_BIN}:${PATH}"
    ps_path="${MOCK_BIN}:${PATH}"
  elif [[ "$use_mock_path" == "nogh" ]]; then
    sh_path="$NOGH_BIN"
    ps_path="$PS_NOGH_PATH"
  fi

  local gh_dir_ps=""
  [[ -n "$gh_dir" ]] && gh_dir_ps="$(to_win_path "$gh_dir")"

  set +e
  SH_OUT="$(PATH="$sh_path" B3_TEST_GH_DIR="$gh_dir" bash "$GUARD_SH" "$subcmd" "${sh_args[@]}" 2>&1)"
  SH_CODE=$?
  SH_OUT="${SH_OUT%$'\r'}"
  if $HAS_PWSH; then
    PS_OUT="$(MSYS2_ARG_CONV_EXCL="*" PATH="$ps_path" B3_TEST_GH_DIR="$gh_dir_ps" "$PWSH_BIN" -NoProfile -ExecutionPolicy Bypass -File "$GUARD_PS_WIN" "$subcmd" "${ps_args[@]}" 2>&1)"
    PS_CODE=$?
    PS_OUT="${PS_OUT//$'\r'/}"
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
  local dir="$1" slug="${2:-}" def_br="${3:-main}"
  mkdir -p "$dir"
  cp -R "${SEED_REPO}/.git" "${dir}/.git"
  if [[ "$def_br" != "main" ]]; then
    git -C "$dir" symbolic-ref HEAD "refs/heads/${def_br}"
  fi
  if [[ -n "$slug" ]]; then
    if [[ "$slug" == *"://"* || "$slug" == "git@"* ]]; then
      git -C "$dir" remote add origin "$slug"
    else
      git -C "$dir" remote add origin "https://github.com/${slug}.git"
    fi
  fi
  printf '.b3/ship/\n.b3/research-ship/\n' > "${dir}/.gitignore"
}

write_premerge_fixtures() {
  local dir="$1" slug="$2" pr_num="$3" def_br="$4" def_sha="$5" base_ref="$6" pr_base_sha="$7" live_target_sha="$8"
  local head_ref="$9" head_sha="${10}" ci_conc="${11}" ci_status="${12}" mergeable_state="${13}" changed_file="${14}"
  local head_repo="${15:-$slug}" mergeable_bool="${16:-true}" status_state="${17:-pending}" status_cnt="${18:-0}"

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
  "mergeable": ${mergeable_bool},
  "mergeable_state": "${mergeable_state}",
  "user": { "login": "alice" },
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

  cat > "${dir}/repos__${s_key}__branches__${b_key}.json" <<EOF
{
  "name": "${base_ref}",
  "protected": false,
  "commit": { "sha": "${live_target_sha}" }
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

  cat > "${dir}/repos__${s_key}__pulls__${pr_num}__files.json" <<EOF
[
  { "filename": "${changed_file}", "status": "modified" }
]
EOF

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

  local statuses_json="[]"
  if [[ "$status_cnt" -gt 0 ]]; then
    statuses_json="[{\"context\":\"ci/ext-status\",\"state\":\"${status_state}\"}]"
  fi
  cat > "${dir}/repos__${s_key}__commits__${head_sha}__status.json" <<EOF
{ "sha": "${head_sha}", "state": "${status_state}", "total_count": ${status_cnt}, "statuses": ${statuses_json} }
EOF
}

write_postmerge_fixtures() {
  local dir="$1" slug="$2" pr_num="$3" def_br="$4" base_ref="$5" head_sha="$6"
  local pr_state="$7" pr_merged="$8" merge_sha="$9" live_target_sha="${10}" cmp_status="${11}" cmp_behind="${12}"
  local def_sha="${13:-$live_target_sha}"
  rm -rf "$dir"
  mkdir -p "$dir"
  local s_key="${slug//\//__}"
  local b_key="${base_ref//\//__}"
  local d_key="${def_br//\//__}"
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
  if [[ "$def_br" != "$base_ref" && -n "$def_sha" ]]; then
    cat > "${dir}/repos__${s_key}__branches__${d_key}.json" <<EOF
{ "name": "${def_br}", "protected": false, "commit": { "sha": "${def_sha}" } }
EOF
  fi
  if [[ -n "$merge_sha" && -n "$live_target_sha" && -n "$cmp_status" ]]; then
    cat > "${dir}/repos__${s_key}__compare__${merge_sha}...${live_target_sha}.json" <<EOF
{ "status": "${cmp_status}", "behind_by": ${cmp_behind}, "ahead_by": 0 }
EOF
  fi
}

# ============================================================================
# TEST 1 & 2: PR targeting main, develop, release/*, feature/*, and Stacked PR (mode=github)
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
  write_premerge_fixtures "$fx" "$SLUG" "$pr_id" "main" "$MAIN_SHA" "$t_br" "$t_sha" "$t_sha" "$h_br" "$h_sha" "success" "completed" "clean" "$chg_f"

  run_dual "$fx" "mock" "merge-policy-check" \
    --repo-root "$R1" --pr-number "$pr_id" --target-branch "$t_br" --base-sha "$t_sha" --ledger-path "$led" \
    -- \
    -RepoRoot "$R1" -PrNumber "$pr_id" -TargetBranch "$t_br" -BaseSha "$t_sha" -LedgerPath "$led"
  assert_dual "target-${t_br}" 0 "^MERGE_AUTHORIZED: mode=github pr=${SLUG}#${pr_id} target_ref=${t_br} target_sha=${t_sha} head_sha=${h_sha} policy_authority=main@${MAIN_SHA} auto_merge=authorized ci=PASS governance=CLEAR$" || t1_ok=false
done
$t1_ok && pass "01-02-arbitrary-targets-and-stacked-pr"

# ============================================================================
# TEST 3: Caller-supplied wrong BaseSha
# ============================================================================
t3_ok=true
run_dual "${MOCK_DATA}/t1-14" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 14 --base-sha "$MAIN_SHA" --ledger-path ".b3/research-ship/runs/pr-14/ledger.md" \
  -- \
  -RepoRoot "$R1" -PrNumber 14 -BaseSha "$MAIN_SHA" -LedgerPath ".b3/research-ship/runs/pr-14/ledger.md"
assert_dual "03-wrong-base-sha" 1 "^MERGE_BLOCKED: base_sha_mismatch$" || t3_ok=false

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
git -C "$R1" checkout -q "feature/parent"
printf 'parent moved\n' >> "${R1}/docs/parent.md"
git -C "$R1" add . && git -C "$R1" commit -qm "parent advanced"
PARENT_SHA2="$(git -C "$R1" rev-parse HEAD)"
git -C "$R1" checkout -q "feat/pr-14"
H14_SHA="$(git -C "$R1" rev-parse HEAD)"

fx4a="${MOCK_DATA}/t4a"
write_premerge_fixtures "$fx4a" "$SLUG" 14 "main" "$MAIN_SHA" "feature/parent" "$PARENT_SHA" "$PARENT_SHA2" "feat/pr-14" "$H14_SHA" "success" "completed" "clean" "docs/pr-stacked.md"
run_dual "$fx4a" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 14 --ledger-path ".b3/research-ship/runs/pr-14/ledger.md" \
  -- \
  -RepoRoot "$R1" -PrNumber 14 -LedgerPath ".b3/research-ship/runs/pr-14/ledger.md"
assert_dual "04a-remote-target-moved" 1 "^MERGE_BLOCKED: target_branch_moved$" || t4_ok=false

fx4b="${MOCK_DATA}/t4b"
write_premerge_fixtures "$fx4b" "$SLUG" 14 "main" "$MAIN_SHA" "feature/parent" "$PARENT_SHA2" "$PARENT_SHA2" "feat/pr-14" "$H14_SHA" "success" "completed" "clean" "docs/pr-stacked.md"
run_dual "$fx4b" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 14 --ledger-path ".b3/research-ship/runs/pr-14/ledger.md" \
  -- \
  -RepoRoot "$R1" -PrNumber 14 -LedgerPath ".b3/research-ship/runs/pr-14/ledger.md"
assert_dual "04b-pr-not-rebased-onto-moved-target" 1 "^MERGE_BLOCKED: target_branch_moved$" || t4_ok=false
$t4_ok && pass "04-target-branch-moved-detection"

# ============================================================================
# TEST 5: Canonical trunk authority-ref tamper (S001 — both GitHub & Local modes)
# ============================================================================
t5_ok=true
R5="${SANDBOX}/r5-self-auth"
init_repo "$R5" "$SLUG" "main"
mkdir -p "${R5}/.b3" "${R5}/docs"
printf '{"auto_merge":"disabled","protected_paths":["releases/"],"allow_protected_paths":false,"require_ci":true,"require_review":true}\n' > "${R5}/.b3/research-policy.json"
printf '# Base\n' > "${R5}/docs/a.md"
git -C "$R5" add . && git -C "$R5" commit -qm "main disabled policy"
R5_MAIN="$(git -C "$R5" rev-parse HEAD)"

# 5a: Feature branch edits policy from disabled -> authorized targeting main (GitHub mode)
git -C "$R5" checkout -qb "feat/self-auth"
printf '{"auto_merge":"authorized","protected_paths":[],"allow_protected_paths":true,"require_ci":false,"require_review":false}\n' > "${R5}/.b3/research-policy.json"
printf 'ok\n' > "${R5}/docs/b.md"
git -C "$R5" add . && git -C "$R5" commit -qm "self-authorize"
R5_HEAD="$(git -C "$R5" rev-parse HEAD)"
fx5a="${MOCK_DATA}/t5a"
write_premerge_fixtures "$fx5a" "$SLUG" 51 "main" "$R5_MAIN" "main" "$R5_MAIN" "$R5_MAIN" "feat/self-auth" "$R5_HEAD" "success" "completed" "clean" ".b3/research-policy.json"
run_dual "$fx5a" "mock" "merge-policy-check" \
  --repo-root "$R5" --pr-number 51 --ci-status PASS --review-status PASS \
  -- \
  -RepoRoot "$R5" -PrNumber 51 -CiStatus PASS -ReviewStatus PASS
assert_dual "05a-feature-edits-policy-gh" 1 "^MERGE_BLOCKED: policy_modified_in_pr$" || t5_ok=false

# 5b: Stacked parent branch adds auto_merge:authorized while main has disabled
git -C "$R5" checkout -qb "feat/stacked-child" "$R5_HEAD"
printf 'child work\n' > "${R5}/docs/child.md"
git -C "$R5" add . && git -C "$R5" commit -qm "child on tampered parent"
R5_CHILD="$(git -C "$R5" rev-parse HEAD)"
fx5b="${MOCK_DATA}/t5b"
write_premerge_fixtures "$fx5b" "$SLUG" 52 "main" "$R5_MAIN" "feat/self-auth" "$R5_HEAD" "$R5_HEAD" "feat/stacked-child" "$R5_CHILD" "success" "completed" "clean" "docs/child.md"
run_dual "$fx5b" "mock" "merge-policy-check" \
  --repo-root "$R5" --pr-number 52 --base-sha "$R5_HEAD" \
  -- \
  -RepoRoot "$R5" -PrNumber 52 -BaseSha "$R5_HEAD"
assert_dual "05b-stacked-parent-policy-tamper" 1 "^MERGE_BLOCKED: target_branch_modified_policy$" || t5_ok=false

# 5c: Main has NO policy file; feature branch injects .b3/research-policy.json with auto_merge:authorized
R5C="${SANDBOX}/r5c-no-auth-pol"
init_repo "$R5C" "" "main"
mkdir -p "${R5C}/docs"
printf '# Main no policy\n' > "${R5C}/docs/a.md"
git -C "$R5C" add . && git -C "$R5C" commit -qm "main without policy"
R5C_MAIN="$(git -C "$R5C" rev-parse HEAD)"
git -C "$R5C" checkout -qb "feat/inject-pol"
mkdir -p "${R5C}/.b3"
printf '{"auto_merge":"authorized","require_ci":false}\n' > "${R5C}/.b3/research-policy.json"
git -C "$R5C" add . && git -C "$R5C" commit -qm "inject authorized policy"
LED5C=".b3/ship/l5c.md"
bash "$GUARD_SH" review-ledger --repo-root "$R5C" --action init --ledger-path "$LED5C" --base-sha "$R5C_MAIN" --review-independence INDEPENDENT >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$R5C" --action update --ledger-path "$LED5C" --unit-id U01 --status REVIEWED >/dev/null
run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$R5C" --authority-ref main --target-ref main --ledger-path "$LED5C" \
  -- \
  -RepoRoot "$R5C" -AuthorityRef main -TargetRef main -LedgerPath "$LED5C"
assert_dual "05c-local-policy-not-in-authority" 1 "^MERGE_BLOCKED: policy_not_in_authority$" || t5_ok=false

# 5d: Local zero-remote repo where main (-AuthorityRef main) has auto_merge=disabled while feature branch edits it to authorized (S001)
R5D="${SANDBOX}/r5d-local-tamper"
init_repo "$R5D" "" "main"
mkdir -p "${R5D}/.b3" "${R5D}/docs"
printf '{"auto_merge":"disabled","protected_paths":["releases/"],"allow_protected_paths":false,"require_ci":false,"require_review":true}\n' > "${R5D}/.b3/research-policy.json"
printf '# Base\n' > "${R5D}/docs/a.md"
git -C "$R5D" add . && git -C "$R5D" commit -qm "main disabled"
R5D_MAIN="$(git -C "$R5D" rev-parse HEAD)"
git -C "$R5D" checkout -qb "feat/tamper-local"
printf '{"auto_merge":"authorized","protected_paths":[],"allow_protected_paths":true,"require_ci":false,"require_review":false}\n' > "${R5D}/.b3/research-policy.json"
printf 'work\n' > "${R5D}/docs/w.md"
git -C "$R5D" add . && git -C "$R5D" commit -qm "tamper policy locally"
LED5D=".b3/ship/l5d.md"
bash "$GUARD_SH" review-ledger --repo-root "$R5D" --action init --ledger-path "$LED5D" --base-sha "$R5D_MAIN" --review-independence INDEPENDENT >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$R5D" --action update --ledger-path "$LED5D" --unit-id U01 --status REVIEWED >/dev/null
run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$R5D" --authority-ref main --target-ref main --ledger-path "$LED5D" \
  -- \
  -RepoRoot "$R5D" -AuthorityRef main -TargetRef main -LedgerPath "$LED5D"
assert_dual "05d-local-authority-ref-tamper-blocked" 1 "^MERGE_BLOCKED: policy_modified_in_pr$" || t5_ok=false
$t5_ok && pass "05-canonical-trunk-authority-policy-tamper-blocked"

# ============================================================================
# TEST 6: Thin GitHub adapter CI, -RequireRemoteCi, and merge-conflict gates
# ============================================================================
t6_ok=true
git -C "$R1" checkout -q "feat/pr-11"
H11_SHA="$(git -C "$R1" rev-parse HEAD)"
LED11=".b3/research-ship/runs/pr-11/ledger.md"

# 6a: Caller passes --ci-status PASS while GitHub check-run is failure
fx6a="${MOCK_DATA}/t6a"
write_premerge_fixtures "$fx6a" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "failure" "completed" "clean" "docs/pr-main.md"
run_dual "$fx6a" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ci-status PASS --review-status PASS --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -CiStatus PASS -ReviewStatus PASS -LedgerPath "$LED11"
assert_dual "06a-forged-ci-pass-vs-gh-fail" 1 "^MERGE_BLOCKED: ci_status=FAIL$" || t6_ok=false

# 6b: Caller passes --ci-status PASS while GitHub has 0 checks (UNKNOWN) and policy require_ci=true
fx6b="${MOCK_DATA}/t6b"
write_premerge_fixtures "$fx6b" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "null" "none" "clean" "docs/pr-main.md"
run_dual "$fx6b" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ci-status PASS --review-status PASS --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -CiStatus PASS -ReviewStatus PASS -LedgerPath "$LED11"
assert_dual "06b-zero-ci-checks-unknown" 1 "^MERGE_BLOCKED: ci_status=UNKNOWN$" || t6_ok=false

# 6c: Commit status API failure blocks even when check-runs succeed
fx6c="${MOCK_DATA}/t6c"
write_premerge_fixtures "$fx6c" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "success" "completed" "clean" "docs/pr-main.md" "$SLUG" "true" "failure" "1"
run_dual "$fx6c" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "06c-commit-status-failure" 1 "^MERGE_BLOCKED: ci_status=FAIL$" || t6_ok=false

# 6d: Cross-app duplicate check-run name cannot mask failure + all-skipped check-runs stay UNKNOWN
fx6d="${MOCK_DATA}/t6d"
write_premerge_fixtures "$fx6d" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "success" "completed" "clean" "docs/pr-main.md"
cat > "${fx6d}/repos__${SLUG//\//__}__commits__${H11_SHA}__check-runs.json" <<EOF
{
  "total_count": 2,
  "check_runs": [
    { "id": 500, "name": "ci/build-test", "app": { "id": 100 }, "head_sha": "${H11_SHA}", "status": "completed", "conclusion": "failure" },
    { "id": 999, "name": "ci/build-test", "app": { "id": 200 }, "head_sha": "${H11_SHA}", "status": "completed", "conclusion": "success" }
  ]
}
EOF
run_dual "$fx6d" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "06d-cross-app-check-failure-not-masked" 1 "^MERGE_BLOCKED: ci_status=FAIL$" || t6_ok=false

fx6d2="${MOCK_DATA}/t6d2"
write_premerge_fixtures "$fx6d2" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "skipped" "completed" "clean" "docs/pr-main.md"
run_dual "$fx6d2" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "06d2-all-skipped-ci-unknown" 1 "^MERGE_BLOCKED: ci_status=UNKNOWN$" || t6_ok=false

# 6e: Merge conflicts (mergeable=false CONFLICTING & mergeable_state=dirty) fail closed
fx6e1="${MOCK_DATA}/t6e1"
write_premerge_fixtures "$fx6e1" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "success" "completed" "dirty" "docs/pr-main.md" "$SLUG" "false"
run_dual "$fx6e1" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "06e1-pr-unmergeable-conflicting" 1 "^MERGE_BLOCKED: pr_not_mergeable\(mergeable=false,state=dirty\)$" || t6_ok=false

fx6e2="${MOCK_DATA}/t6e2"
write_premerge_fixtures "$fx6e2" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "success" "completed" "dirty" "docs/pr-main.md" "$SLUG" "true"
run_dual "$fx6e2" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "06e2-mergeable-state-dirty" 1 "^MERGE_BLOCKED: mergeable_state=dirty$" || t6_ok=false

# 6f: -RequireRemoteCi enforces remote CI PASS even when policy has require_ci=false
R6F="${SANDBOX}/r6f-reqci"
init_repo "$R6F" "$SLUG" "main"
mkdir -p "${R6F}/.b3" "${R6F}/docs"
printf '{"auto_merge":"authorized","protected_paths":[],"allow_protected_paths":false,"require_ci":false,"require_review":true}\n' > "${R6F}/.b3/research-policy.json"
printf 'base\n' > "${R6F}/docs/a.md"
git -C "$R6F" add . && git -C "$R6F" commit -qm "main require_ci=false"
R6F_MAIN="$(git -C "$R6F" rev-parse HEAD)"
git -C "$R6F" checkout -qb "feat/r6f"
printf 'chg\n' > "${R6F}/docs/b.md"
git -C "$R6F" add . && git -C "$R6F" commit -qm "feat"
R6F_HEAD="$(git -C "$R6F" rev-parse HEAD)"
LED6F=".b3/ship/l6f.md"
bash "$GUARD_SH" review-ledger --repo-root "$R6F" --action init --ledger-path "$LED6F" --base-sha "$R6F_MAIN" --review-independence INDEPENDENT >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$R6F" --action update --ledger-path "$LED6F" --unit-id U01 --status REVIEWED >/dev/null
fx6f="${MOCK_DATA}/t6f"
write_premerge_fixtures "$fx6f" "$SLUG" 66 "main" "$R6F_MAIN" "main" "$R6F_MAIN" "$R6F_MAIN" "feat/r6f" "$R6F_HEAD" "null" "none" "clean" "docs/b.md"
run_dual "$fx6f" "mock" "merge-policy-check" \
  --repo-root "$R6F" --pr-number 66 --require-remote-ci --ledger-path "$LED6F" \
  -- \
  -RepoRoot "$R6F" -PrNumber 66 -RequireRemoteCi -LedgerPath "$LED6F"
assert_dual "06f-require-remote-ci-blocks-unknown" 1 "^MERGE_BLOCKED: ci_status=UNKNOWN$" || t6_ok=false
$t6_ok && pass "06-remote-ci-and-merge-conflict-gates"

# ============================================================================
# TEST 7: Review-ledger SINGLE_AGENT_LIMIT + UNKNOWN default + migration
# ============================================================================
t7_ok=true
# 7a: SINGLE_AGENT_LIMIT blocks merge-policy-check in GitHub mode
LED_SAL=".b3/research-ship/runs/pr-11-sal/ledger.md"
bash "$GUARD_SH" review-ledger --repo-root "$R1" --action init --ledger-path "$LED_SAL" --base-sha "$MAIN_SHA" --review-independence SINGLE_AGENT_LIMIT >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$R1" --action update --ledger-path "$LED_SAL" --unit-id U01 --status REVIEWED >/dev/null
run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED_SAL" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED_SAL"
assert_dual "07a-single-agent-limit-blocks-merge" 1 "^MERGE_BLOCKED: single_agent_limit$" || t7_ok=false

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
run_dual "" "mock" "review-ledger" \
  --repo-root "$R1" --action check --ledger-path "$LED_UNK" \
  -- \
  -RepoRoot "$R1" -Action check -LedgerPath "$LED_UNK"
assert_dual "07b-local-low-unknown-check" 0 "^LEDGER_GATE_PASS: .*review_independence=UNKNOWN$" || t7_ok=false

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

# 7e: Legacy ledger migration via `review-ledger normalize` backfills review_independence=UNKNOWN
grep -v '^review_independence=' "${R1}/${LED_UNK}" > "${R1}/.b3/research-ship/runs/pr-11-unk/legacy-sh.md"
cp "${R1}/.b3/research-ship/runs/pr-11-unk/legacy-sh.md" "${R1}/.b3/research-ship/runs/pr-11-unk/legacy-ps.md"
SH_MIG="$(bash "$GUARD_SH" review-ledger --repo-root "$R1" --action normalize --ledger-path ".b3/research-ship/runs/pr-11-unk/legacy-sh.md")"
if [[ "$SH_MIG" != "LEDGER_NORMALIZED: path=.b3/research-ship/runs/pr-11-unk/legacy-sh.md changes=1" ]] || ! grep -qx "review_independence=UNKNOWN" "${R1}/.b3/research-ship/runs/pr-11-unk/legacy-sh.md"; then
  fail "07e-legacy-migrate-sh" "got='$SH_MIG'"
  t7_ok=false
fi
if $HAS_PWSH; then
  PS_MIG="$(MSYS2_ARG_CONV_EXCL="*" "$PWSH_BIN" -NoProfile -ExecutionPolicy Bypass -File "$GUARD_PS_WIN" review-ledger -RepoRoot "$(to_win_path "$R1")" -Action normalize -LedgerPath ".b3/research-ship/runs/pr-11-unk/legacy-ps.md")"
  PS_MIG="${PS_MIG//$'\r'/}"
  if [[ "$PS_MIG" != "LEDGER_NORMALIZED: path=.b3/research-ship/runs/pr-11-unk/legacy-ps.md changes=1" ]] || ! grep -qx "review_independence=UNKNOWN" "${R1}/.b3/research-ship/runs/pr-11-unk/legacy-ps.md"; then
    fail "07e-legacy-migrate-ps" "got='$PS_MIG'"
    t7_ok=false
  fi
fi
$t7_ok && pass "07-review-ledger-independence-unknown-and-migration"

# ============================================================================
# TEST 8: Review evidence belonging to another PR / commit / repo / fork
# ============================================================================
t8_ok=true
LED_PR12_REF=".b3/research-ship/runs/pr-12-ref/ledger.md"
bash "$GUARD_SH" review-ledger --repo-root "$R1" --action init --ledger-path "$LED_PR12_REF" --base-sha "$DEV_SHA" --target-ref "feat/pr-12" --review-independence INDEPENDENT >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$R1" --action update --ledger-path "$LED_PR12_REF" --unit-id U01 --status REVIEWED >/dev/null
run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED_PR12_REF" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED_PR12_REF"
assert_dual "08a-ledger-from-other-pr-target" 1 "^MERGE_BLOCKED: ledger_target_mismatch$" || t8_ok=false

LED_OTHER_HEAD=".b3/research-ship/runs/pr-other-head/ledger.md"
bash "$GUARD_SH" review-ledger --repo-root "$R1" --action init --ledger-path "$LED_OTHER_HEAD" --base-sha "$MAIN_SHA" --target-ref "develop" --review-independence INDEPENDENT >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$R1" --action update --ledger-path "$LED_OTHER_HEAD" --unit-id U01 --status REVIEWED >/dev/null
run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED_OTHER_HEAD" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED_OTHER_HEAD"
assert_dual "08a2-ledger-from-other-commit" 1 "^MERGE_BLOCKED: ledger_head_mismatch$" || t8_ok=false

run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --repo "evil/other" --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -Repo "evil/other" -LedgerPath "$LED11"
assert_dual "08b-cross-repo-flag" 1 "^MERGE_BLOCKED: repo_mismatch$" || t8_ok=false

fx8c="${MOCK_DATA}/t8c"
write_premerge_fixtures "$fx8c" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$H11_SHA" "success" "completed" "clean" "docs/pr-main.md" "forkuser/b3-demo"
run_dual "$fx8c" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "08c-fork-pr-blocked" 1 "^MERGE_BLOCKED: cross_repo_head_pr$" || t8_ok=false

fx8d="${MOCK_DATA}/t8d"
write_premerge_fixtures "$fx8d" "$SLUG" 11 "main" "$MAIN_SHA" "main" "$MAIN_SHA" "$MAIN_SHA" "feat/pr-11" "$DEV_SHA" "success" "completed" "clean" "docs/pr-main.md"
run_dual "$fx8d" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "08d-head-sha-mismatch" 1 "^MERGE_BLOCKED: head_sha_mismatch$" || t8_ok=false
$t8_ok && pass "08-cross-pr-commit-repo-fork-isolation"

# ============================================================================
# TEST 9 & 10: Post-Merge verification — GitHub mode + Local ancestry (S002)
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
git -C "$R9" checkout -q "feature/parent"
printf 'parent 2\n' >> "${R9}/docs/p.md"
git -C "$R9" add . && git -C "$R9" commit -qm "parent 2"
git -C "$R9" cherry-pick "$RB_ORIG_HEAD" >/dev/null 2>&1
RB_MERGE_SHA="$(git -C "$R9" rev-parse HEAD)"

# 10a: GitHub Merge commit into main
fx10a="${MOCK_DATA}/t10a"
write_postmerge_fixtures "$fx10a" "$SLUG" 91 "main" "main" "$MC_HEAD" "closed" "true" "$MC_MERGE_SHA" "$MC_MERGE_SHA" "identical" 0 "$MC_MERGE_SHA"
run_dual "$fx10a" "mock" "merge-policy-check" \
  --repo-root "$R9" --post-merge --pr-number 91 --main-ref main --merged-sha "$MC_MERGE_SHA" \
  -- \
  -RepoRoot "$R9" -PostMerge -PrNumber 91 -MainRef main -MergedSha "$MC_MERGE_SHA"
assert_dual "10a-merge-commit-main" 0 "^POST_MERGE_VERIFIED: mode=github pr=${SLUG}#91 pr_status=PR_MERGED sha=${MC_MERGE_SHA} target_ref=main main_ref=main merge_kind=merge_commit runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED$" || t9_ok=false

# 10b: GitHub Squash merge into develop
fx10b="${MOCK_DATA}/t10b"
write_postmerge_fixtures "$fx10b" "$SLUG" 92 "main" "develop" "$SQ_HEAD" "closed" "true" "$SQ_MERGE_SHA" "$SQ_MERGE_SHA" "identical" 0 "$MC_MERGE_SHA"
run_dual "$fx10b" "mock" "merge-policy-check" \
  --repo-root "$R9" --post-merge --pr-number 92 --main-ref develop \
  -- \
  -RepoRoot "$R9" -PostMerge -PrNumber 92 -MainRef develop
assert_dual "10b-squash-develop" 0 "^POST_MERGE_VERIFIED: mode=github pr=${SLUG}#92 pr_status=PR_MERGED sha=${SQ_MERGE_SHA} target_ref=develop main_ref=develop merge_kind=squash_or_rebase runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED$" || t9_ok=false

# 10c: GitHub Rebase merge into stacked feature/parent
fx10c="${MOCK_DATA}/t10c"
write_postmerge_fixtures "$fx10c" "$SLUG" 93 "main" "feature/parent" "$RB_ORIG_HEAD" "closed" "true" "$RB_MERGE_SHA" "$RB_MERGE_SHA" "ahead" 0 "$MC_MERGE_SHA"
run_dual "$fx10c" "mock" "merge-policy-check" \
  --repo-root "$R9" --post-merge --pr-number 93 --main-ref "feature/parent" \
  -- \
  -RepoRoot "$R9" -PostMerge -PrNumber 93 -MainRef "feature/parent"
assert_dual "10c-rebase-stacked-parent" 0 "^POST_MERGE_VERIFIED: mode=github pr=${SLUG}#93 pr_status=PR_MERGED sha=${RB_MERGE_SHA} target_ref=feature/parent main_ref=feature/parent merge_kind=squash_or_rebase runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED$" || t9_ok=false

# 9a: Caller claims --pr-state MERGED on an OPEN PR
fx9a="${MOCK_DATA}/t9a"
write_postmerge_fixtures "$fx9a" "$SLUG" 94 "main" "main" "$MC_HEAD" "open" "false" "" "$MC_MERGE_SHA" "" -1 "$MC_MERGE_SHA"
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

# 9c: Caller supplies wrong MergedSha
run_dual "$fx10b" "mock" "merge-policy-check" \
  --repo-root "$R9" --post-merge --pr-number 92 --main-ref develop --merged-sha "$MC_MERGE_SHA" \
  -- \
  -RepoRoot "$R9" -PostMerge -PrNumber 92 -MainRef develop -MergedSha "$MC_MERGE_SHA"
assert_dual "09c-wrong-merged-sha" 1 "^POST_MERGE_FAILED: merge_commit_sha_mismatch" || t9_ok=false

# 9d: Local post-merge missing --head-sha fails closed
run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$R9" --post-merge --target-ref main --merged-sha "$MC_MERGE_SHA" \
  -- \
  -RepoRoot "$R9" -PostMerge -TargetRef main -MergedSha "$MC_MERGE_SHA"
assert_dual "09d-missing-head-sha-postmerge" 1 "^POST_MERGE_FAILED: missing_head_sha$" || t9_ok=false

# 9e: Remote target branch diverged
fx9e="${MOCK_DATA}/t9e"
write_postmerge_fixtures "$fx9e" "$SLUG" 91 "main" "main" "$MC_HEAD" "closed" "true" "$MC_MERGE_SHA" "$R9_MAIN0" "diverged" 1 "$R9_MAIN0"
run_dual "$fx9e" "mock" "merge-policy-check" \
  --repo-root "$R9" --post-merge --pr-number 91 --main-ref main \
  -- \
  -RepoRoot "$R9" -PostMerge -PrNumber 91 -MainRef main
assert_dual "09e-remote-diverged" 1 "^POST_MERGE_FAILED: merge_commit_not_in_remote_target" || t9_ok=false

# 10d-10f: Provider-neutral local -PostMerge ancestry (S002: merge_commit, fast_forward, and unmerged HeadSha rejection)
R9L="${SANDBOX}/r9l-local-pm"
init_repo "$R9L" "" "main"
mkdir -p "${R9L}/docs"
printf 'v0\n' > "${R9L}/docs/a.md"
git -C "$R9L" add . && git -C "$R9L" commit -qm "v0"
git -C "$R9L" checkout -qb "feat/loc-mc"
printf 'mc\n' > "${R9L}/docs/mc.md"
git -C "$R9L" add . && git -C "$R9L" commit -qm "loc mc"
L_MC_HEAD="$(git -C "$R9L" rev-parse HEAD)"
git -C "$R9L" checkout -q main
git -C "$R9L" merge --no-ff -qm "local merge commit" "feat/loc-mc"
L_MC_MERGE="$(git -C "$R9L" rev-parse HEAD)"

run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$R9L" --post-merge --target-ref main --head-sha "$L_MC_HEAD" --merged-sha "$L_MC_MERGE" \
  -- \
  -RepoRoot "$R9L" -PostMerge -TargetRef main -HeadSha "$L_MC_HEAD" -MergedSha "$L_MC_MERGE"
assert_dual "10d-local-postmerge-merge-commit" 0 "^POST_MERGE_VERIFIED: mode=local sha=${L_MC_MERGE} target_ref=main main_ref=main merge_kind=merge_commit runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED$" || t9_ok=false

git -C "$R9L" checkout -qb "feat/loc-ff"
printf 'ff\n' > "${R9L}/docs/ff.md"
git -C "$R9L" add . && git -C "$R9L" commit -qm "loc ff"
L_FF_HEAD="$(git -C "$R9L" rev-parse HEAD)"
git -C "$R9L" checkout -q main
git -C "$R9L" merge --ff-only -q "feat/loc-ff"

run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$R9L" --post-merge --target-ref main --head-sha "$L_FF_HEAD" --merged-sha "$L_FF_HEAD" \
  -- \
  -RepoRoot "$R9L" -PostMerge -TargetRef main -HeadSha "$L_FF_HEAD" -MergedSha "$L_FF_HEAD"
assert_dual "10e-local-postmerge-fast-forward" 0 "^POST_MERGE_VERIFIED: mode=local sha=${L_FF_HEAD} target_ref=main main_ref=main merge_kind=fast_forward runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED$" || t9_ok=false

git -C "$R9L" checkout -qb "feat/unmerged"
printf 'unmerged\n' > "${R9L}/docs/unmerged.md"
git -C "$R9L" add . && git -C "$R9L" commit -qm "unmerged feat"
L_UNMERGED="$(git -C "$R9L" rev-parse HEAD)"
git -C "$R9L" checkout -q main

run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$R9L" --post-merge --target-ref main --head-sha "$L_UNMERGED" --merged-sha "$L_UNMERGED" \
  -- \
  -RepoRoot "$R9L" -PostMerge -TargetRef main -HeadSha "$L_UNMERGED" -MergedSha "$L_UNMERGED"
assert_dual "10f1-local-postmerge-unmerged-not-in-target" 1 "^POST_MERGE_FAILED: sha_not_in_target" || t9_ok=false

run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$R9L" --post-merge --target-ref main --head-sha "$L_UNMERGED" --merged-sha "$L_MC_MERGE" \
  -- \
  -RepoRoot "$R9L" -PostMerge -TargetRef main -HeadSha "$L_UNMERGED" -MergedSha "$L_MC_MERGE"
assert_dual "10f2-local-postmerge-unmerged-head-mismatch" 1 "^POST_MERGE_FAILED: merge_commit_head_mismatch$" || t9_ok=false
$t9_ok && pass "09-10-post-merge-github-and-local-ancestry"

# ============================================================================
# TEST 11: Provider unavailability (AR-03) & -LocalOnly separation
# ============================================================================
t11_ok=true
git -C "$R1" checkout -q "feat/pr-11"
# 11a: `gh` unavailable on PATH returns PROVIDER_UNAVAILABLE (exit 2, NEVER 0 or 1!)
run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ci-status PASS --review-status PASS --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -CiStatus PASS -ReviewStatus PASS -LedgerPath "$LED11"
assert_dual "11a-missing-gh-cli-provider-unavailable" 2 "^PROVIDER_UNAVAILABLE: .*gh_cli_unavailable" || t11_ok=false

# 11b: GitHub API returns 401 auth failure -> PROVIDER_UNAVAILABLE (exit 2)
fx11b="${MOCK_DATA}/t11b"
mkdir -p "$fx11b"
echo "HTTP 401: Bad credentials" > "${fx11b}/repos__${SLUG//\//__}__pulls__11.err"
run_dual "$fx11b" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ci-status PASS --review-status PASS --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -CiStatus PASS -ReviewStatus PASS -LedgerPath "$LED11"
assert_dual "11b-gh-auth-401-provider-unavailable" 2 "^PROVIDER_UNAVAILABLE: .*github_auth_failed" || t11_ok=false

# 11c: Missing --pr-number when --require-remote-ci is requested fails closed
git -C "$R1" update-ref refs/remotes/origin/main "$MAIN_SHA"
run_dual "" "mock" "merge-policy-check" \
  --repo-root "$R1" --require-remote-ci --base-sha "$MAIN_SHA" --ledger-path "$LED11" --ci-status PASS --review-status PASS --changed-paths "docs/pr-main.md" \
  -- \
  -RepoRoot "$R1" -RequireRemoteCi -BaseSha "$MAIN_SHA" -LedgerPath "$LED11" -CiStatus PASS -ReviewStatus PASS -ChangedPaths "docs/pr-main.md"
assert_dual "11c-missing-pr-number-require-remote-ci" 1 "^MERGE_BLOCKED: missing_pr_number$" || t11_ok=false

# 11d: Explicit --local-only with auto_merge=authorized returns LOCAL_ELIGIBLE_ONLY (exit 2)
run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$R1" --local-only --base-sha "$MAIN_SHA" --ledger-path "$LED11" --pr-state OPEN --ci-status PASS --review-status PASS --changed-paths "docs/pr-main.md" \
  -- \
  -RepoRoot "$R1" -LocalOnly -BaseSha "$MAIN_SHA" -LedgerPath "$LED11" -PrState OPEN -CiStatus PASS -ReviewStatus PASS -ChangedPaths "docs/pr-main.md"
assert_dual "11d-local-only-authorized-never-merges" 2 "^LOCAL_ELIGIBLE_ONLY: engineering_ready=true auto_merge=authorized$" || t11_ok=false
git -C "$R1" update-ref -d refs/remotes/origin/main
$t11_ok && pass "11-provider-unavailability-and-local-only-separation"

# ============================================================================
# TEST 12: Provider-neutral local zero-remote & GitLab/Bitbucket remotes (CF-09)
# ============================================================================
t12_ok=true
# 12a: Zero-remote local repo (default disabled -> PR_READY exit 2; trunk authorized -> LOCAL_ELIGIBLE_ONLY exit 2 & MERGE_AUTHORIZED mode=local exit 0)
RLOC="${SANDBOX}/r12-zero-remote"
init_repo "$RLOC" "" "main"
mkdir -p "${RLOC}/docs"
printf 'local base\n' > "${RLOC}/docs/a.md"
git -C "$RLOC" add . && git -C "$RLOC" commit -qm "init local no policy"
git -C "$RLOC" checkout -qb "feat/loc-default"
printf 'local change\n' > "${RLOC}/docs/b.md"
git -C "$RLOC" add . && git -C "$RLOC" commit -qm "local work"
run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$RLOC" --ci-status PASS --review-status PASS \
  -- \
  -RepoRoot "$RLOC" -CiStatus PASS -ReviewStatus PASS
assert_dual "12a1-zero-remote-default-pr-ready" 2 "^PR_READY: auto_merge=disabled$" || t12_ok=false

git -C "$RLOC" checkout -q main
mkdir -p "${RLOC}/.b3"
printf '{"auto_merge":"authorized","protected_paths":["releases/"],"allow_protected_paths":false,"require_ci":false,"require_review":true}\n' > "${RLOC}/.b3/research-policy.json"
git -C "$RLOC" add . && git -C "$RLOC" commit -qm "authorize local policy on main"
RLOC_MAIN="$(git -C "$RLOC" rev-parse HEAD)"
git -C "$RLOC" checkout -qb "feat/loc-auth" "$RLOC_MAIN"
printf 'local authorized work\n' > "${RLOC}/docs/c.md"
git -C "$RLOC" add . && git -C "$RLOC" commit -qm "feat on authorized local main"
RLOC_HEAD="$(git -C "$RLOC" rev-parse HEAD)"
LED_LOC=".b3/ship/l-loc.md"
bash "$GUARD_SH" review-ledger --repo-root "$RLOC" --action init --ledger-path "$LED_LOC" --base-sha "$RLOC_MAIN" --review-independence INDEPENDENT >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$RLOC" --action update --ledger-path "$LED_LOC" --unit-id U01 --status REVIEWED >/dev/null

run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$RLOC" --local-only --ledger-path "$LED_LOC" \
  -- \
  -RepoRoot "$RLOC" -LocalOnly -LedgerPath "$LED_LOC"
assert_dual "12a2-zero-remote-local-only" 2 "^LOCAL_ELIGIBLE_ONLY: engineering_ready=true auto_merge=authorized$" || t12_ok=false

run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$RLOC" --ledger-path "$LED_LOC" \
  -- \
  -RepoRoot "$RLOC" -LedgerPath "$LED_LOC"
assert_dual "12a3-zero-remote-merge-authorized" 0 "^MERGE_AUTHORIZED: mode=local target_ref=refs/heads/main target_sha=${RLOC_MAIN} head_sha=${RLOC_HEAD} policy_authority=refs/heads/main@${RLOC_MAIN} auto_merge=authorized governance=CLEAR$" || t12_ok=false

# 12b: GitLab remote (https://gitlab.com/org/repo.git) operates 100% locally without GitHub lock-in
RGL="${SANDBOX}/r12-gitlab"
init_repo "$RGL" "https://gitlab.com/org/repo.git" "main"
mkdir -p "${RGL}/.b3" "${RGL}/docs"
printf '{"auto_merge":"disabled","protected_paths":["releases/"],"allow_protected_paths":false,"require_ci":true,"require_review":true}\n' > "${RGL}/.b3/research-policy.json"
printf 'gl base\n' > "${RGL}/docs/a.md"
git -C "$RGL" add . && git -C "$RGL" commit -qm "gitlab main disabled"
RGL_MAIN0="$(git -C "$RGL" rev-parse HEAD)"
git -C "$RGL" update-ref refs/remotes/origin/main "$RGL_MAIN0"
git -C "$RGL" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$RGL" --ci-status PASS --review-status PASS --changed-paths "docs/a.md" \
  -- \
  -RepoRoot "$RGL" -CiStatus PASS -ReviewStatus PASS -ChangedPaths "docs/a.md"
assert_dual "12b1-gitlab-disabled-pr-ready" 2 "^PR_READY: auto_merge=disabled$" || t12_ok=false

run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$RGL" --ci-status PASS --review-status PASS --changed-paths "releases/v1.json" \
  -- \
  -RepoRoot "$RGL" -CiStatus PASS -ReviewStatus PASS -ChangedPaths "releases/v1.json"
assert_dual "12b2-gitlab-protected-path-blocked" 1 "^MERGE_BLOCKED: protected_paths=releases/v1\.json$" || t12_ok=false

printf '{"auto_merge":"authorized","protected_paths":["releases/"],"allow_protected_paths":false,"require_ci":false,"require_review":true}\n' > "${RGL}/.b3/research-policy.json"
git -C "$RGL" add . && git -C "$RGL" commit -qm "gitlab main authorized"
RGL_MAIN="$(git -C "$RGL" rev-parse HEAD)"
git -C "$RGL" update-ref refs/remotes/origin/main "$RGL_MAIN"
git -C "$RGL" checkout -qb "feat/gl-work" "$RGL_MAIN"
printf 'gl feat\n' > "${RGL}/docs/gl.md"
git -C "$RGL" add . && git -C "$RGL" commit -qm "gitlab feature"
RGL_HEAD="$(git -C "$RGL" rev-parse HEAD)"
LED_GL=".b3/ship/l-gl.md"
bash "$GUARD_SH" review-ledger --repo-root "$RGL" --action init --ledger-path "$LED_GL" --base-sha "$RGL_MAIN" --review-independence INDEPENDENT >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$RGL" --action update --ledger-path "$LED_GL" --unit-id U01 --status REVIEWED >/dev/null

run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$RGL" --local-only --ledger-path "$LED_GL" \
  -- \
  -RepoRoot "$RGL" -LocalOnly -LedgerPath "$LED_GL"
assert_dual "12b3-gitlab-local-only" 2 "^LOCAL_ELIGIBLE_ONLY: engineering_ready=true auto_merge=authorized$" || t12_ok=false

run_dual "" "nogh" "merge-policy-check" \
  --repo-root "$RGL" --ledger-path "$LED_GL" \
  -- \
  -RepoRoot "$RGL" -LedgerPath "$LED_GL"
assert_dual "12b4-gitlab-merge-authorized-local" 0 "^MERGE_AUTHORIZED: mode=local target_ref=refs/remotes/origin/main target_sha=${RGL_MAIN} head_sha=${RGL_HEAD} policy_authority=refs/remotes/origin/main@${RGL_MAIN} auto_merge=authorized governance=CLEAR$" || t12_ok=false
$t12_ok && pass "12-provider-neutral-zero-remote-and-gitlab-parity"

# ============================================================================
# TEST 13: Security Hardening Regressions (policy substitution, remotes, dirty WT, symlinks, tamper)
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
write_premerge_fixtures "$fx13a" "$SLUG" 130 "main" "$R13_MAIN" "main" "$R13_MAIN" "$R13_MAIN" "feat/pol-sub" "$R13_HEAD" "success" "completed" "clean" "docs/work.md"
run_dual "$fx13a" "mock" "merge-policy-check" \
  --repo-root "$R13" --pr-number 130 --policy-path "tests/fake-auth-policy.json" --ledger-path "$LED13" \
  -- \
  -RepoRoot "$R13" -PrNumber 130 -PolicyPath "tests/fake-auth-policy.json" -LedgerPath "$LED13"
assert_dual "13a-policy-path-substitution-blocked" 1 "^MERGE_BLOCKED: policy_path_override_not_allowed$" || t13_ok=false

# 13b: Non-origin `upstream` remote + -PrNumber fails closed without origin; b3-github-verify succeeds with explicit -Repo
git -C "$R1" checkout -q "feat/pr-11"
H11_SHA="$(git -C "$R1" rev-parse HEAD)"
LED11=".b3/research-ship/runs/pr-11/ledger.md"
git -C "$R1" remote remove origin
git -C "$R1" remote add upstream "https://github.com/${SLUG}.git"
run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "13b1-upstream-only-without-repo-blocked" 1 "^MERGE_BLOCKED: origin_remote_missing$" || t13_ok=false

set +e
GHV_NO_REPO_SH="$(cd "$R1" && PATH="${MOCK_BIN}:${PATH}" B3_TEST_GH_DIR="${MOCK_DATA}/t1-11" bash "$GH_VERIFY_SH" --mode pre-merge --pr-number 11 2>&1)"
GHV_NO_REPO_SH_RC=$?
GHV_WITH_REPO_SH="$(cd "$R1" && PATH="${MOCK_BIN}:${PATH}" B3_TEST_GH_DIR="${MOCK_DATA}/t1-11" bash "$GH_VERIFY_SH" --mode pre-merge --repo "$SLUG" --pr-number 11 2>&1)"
GHV_WITH_REPO_SH_RC=$?
if $HAS_PWSH; then
  GHV_WITH_REPO_PS="$(cd "$R1" && MSYS2_ARG_CONV_EXCL="*" PATH="${MOCK_BIN}:${PATH}" B3_TEST_GH_DIR="$(to_win_path "${MOCK_DATA}/t1-11")" "$PWSH_BIN" -NoProfile -ExecutionPolicy Bypass -File "$GH_VERIFY_PS_WIN" -Mode pre-merge -Repo "$SLUG" -PrNumber 11 2>&1)"
  GHV_WITH_REPO_PS_RC=$?
  GHV_WITH_REPO_PS="${GHV_WITH_REPO_PS//$'\r'/}"
else
  GHV_WITH_REPO_PS="$GHV_WITH_REPO_SH"
  GHV_WITH_REPO_PS_RC=$GHV_WITH_REPO_SH_RC
fi
set -e
if [[ "$GHV_NO_REPO_SH_RC" -ne 1 || "$GHV_WITH_REPO_SH_RC" -ne 0 || "$GHV_WITH_REPO_PS_RC" -ne 0 || ! "$GHV_WITH_REPO_SH" =~ ^schema=b3-gh-verify-v2 || "$GHV_WITH_REPO_SH" != "$GHV_WITH_REPO_PS" ]]; then
  fail "13b2-gh-verify-upstream-explicit-repo" "no_repo=($GHV_NO_REPO_SH_RC:'$GHV_NO_REPO_SH') sh=($GHV_WITH_REPO_SH_RC) ps=($GHV_WITH_REPO_PS_RC)"
  t13_ok=false
fi
git -C "$R1" remote remove upstream

# 13c: Credential + mixed-case HTTPS GitHub origin allowed
git -C "$R1" remote add origin "https://x-access-token:ghs_test123@GitHub.com/${SLUG}.git"
run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "13c-cred-mixedcase-https-origin-allowed" 0 "^MERGE_AUTHORIZED: mode=github pr=${SLUG}#11 " || t13_ok=false
git -C "$R1" remote set-url origin "https://github.com/${SLUG}.git"

# 13d: Dirty working tree & path-traversal / symlink escapes fail closed
printf 'dirty\n' > "${R1}/docs/uncommitted.md"
run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "$LED11" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "$LED11"
assert_dual "13d1-dirty-worktree-blocked" 1 "^MERGE_BLOCKED: dirty_worktree$" || t13_ok=false
rm -f "${R1}/docs/uncommitted.md"

run_dual "${MOCK_DATA}/t1-11" "mock" "merge-policy-check" \
  --repo-root "$R1" --pr-number 11 --ledger-path "../escape-ledger.md" \
  -- \
  -RepoRoot "$R1" -PrNumber 11 -LedgerPath "../escape-ledger.md"
assert_dual "13d2-ledger-traversal-blocked" 1 "^MERGE_BLOCKED: invalid_ledger_path$" || t13_ok=false

# 13e: allowed_target_branches blocks develop and allows release/*
R13P="${SANDBOX}/r13p-prot"
init_repo "$R13P" "$SLUG" "main"
mkdir -p "${R13P}/.b3" "${R13P}/docs"
printf '{"auto_merge":"authorized","protected_paths":[],"allow_protected_paths":false,"require_ci":true,"require_review":false,"allowed_target_branches":["main","release/*"]}\n' > "${R13P}/.b3/research-policy.json"
printf '# Base\n' > "${R13P}/docs/a.md"
git -C "$R13P" add . && git -C "$R13P" commit -qm "init r13p"
R13P_MAIN="$(git -C "$R13P" rev-parse HEAD)"
git -C "$R13P" checkout -qb "develop" "$R13P_MAIN"
R13P_DEV="$(git -C "$R13P" rev-parse HEAD)"
git -C "$R13P" checkout -qb "feat/prot-test" "$R13P_MAIN"
printf 'x\n' > "${R13P}/docs/x.md"
git -C "$R13P" add . && git -C "$R13P" commit -qm "feat work"
R13P_HEAD="$(git -C "$R13P" rev-parse HEAD)"
LED13P=".b3/research-ship/runs/r13p/ledger.md"
bash "$GUARD_SH" review-ledger --repo-root "$R13P" --action init --ledger-path "$LED13P" --base-sha "$R13P_MAIN" --review-independence INDEPENDENT >/dev/null
bash "$GUARD_SH" review-ledger --repo-root "$R13P" --action update --ledger-path "$LED13P" --unit-id U01 --status REVIEWED >/dev/null

fx13e1="${MOCK_DATA}/t13e1"
write_premerge_fixtures "$fx13e1" "$SLUG" 132 "main" "$R13P_MAIN" "develop" "$R13P_DEV" "$R13P_DEV" "feat/prot-test" "$R13P_HEAD" "success" "completed" "clean" "docs/x.md"
run_dual "$fx13e1" "mock" "merge-policy-check" \
  --repo-root "$R13P" --pr-number 132 --ledger-path "$LED13P" \
  -- \
  -RepoRoot "$R13P" -PrNumber 132 -LedgerPath "$LED13P"
assert_dual "13e1-disallowed-target-branch-blocked" 1 "^MERGE_BLOCKED: target_branch_not_allowed\(develop\)$" || t13_ok=false

fx13e2="${MOCK_DATA}/t13e2"
write_premerge_fixtures "$fx13e2" "$SLUG" 133 "main" "$R13P_MAIN" "release/2026.11" "$R13P_MAIN" "$R13P_MAIN" "feat/prot-test" "$R13P_HEAD" "success" "completed" "clean" "docs/x.md"
run_dual "$fx13e2" "mock" "merge-policy-check" \
  --repo-root "$R13P" --pr-number 133 --ledger-path "$LED13P" \
  -- \
  -RepoRoot "$R13P" -PrNumber 133 -LedgerPath "$LED13P"
assert_dual "13e2-allowed-wildcard-target-branch-passes" 0 "^MERGE_AUTHORIZED: mode=github pr=${SLUG}#133 target_ref=release/2026\.11 " || t13_ok=false

# 13f: review-ledger tamper detection & head_sha advance resetting INDEPENDENT -> UNKNOWN
LED13T=".b3/research-ship/runs/r13p/tampered.md"
sed 's/^passes_used=.*/passes_used=99/' "${R13P}/${LED13P}" > "${R13P}/${LED13T}"
run_dual "$fx13e2" "mock" "merge-policy-check" \
  --repo-root "$R13P" --pr-number 133 --ledger-path "$LED13T" \
  -- \
  -RepoRoot "$R13P" -PrNumber 133 -LedgerPath "$LED13T"
assert_dual "13f1-ledger-tamper-blocked" 1 "^MERGE_BLOCKED: ledger_check_failed " || t13_ok=false

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
  U_PS="$(MSYS2_ARG_CONV_EXCL="*" "$PWSH_BIN" -NoProfile -ExecutionPolicy Bypass -File "$GUARD_PS_WIN" review-ledger -RepoRoot "$(to_win_path "$R13P")" -Action update -LedgerPath "$LED13K_PS" -UnitId U01 -Status REVIEWED 2>&1)"
  U_PS_RC=$?
else
  U_PS="$U_SH"; U_PS_RC=$U_SH_RC
fi
C_SH="$(bash "$GUARD_SH" review-ledger --repo-root "$R13P" --action check --ledger-path "$LED13K_SH" 2>&1)"
C_SH_RC=$?
if $HAS_PWSH; then
  C_PS="$(MSYS2_ARG_CONV_EXCL="*" "$PWSH_BIN" -NoProfile -ExecutionPolicy Bypass -File "$GUARD_PS_WIN" review-ledger -RepoRoot "$(to_win_path "$R13P")" -Action check -LedgerPath "$LED13K_PS" 2>&1)"
  C_PS_RC=$?
else
  C_PS="$C_SH"; C_PS_RC=$C_SH_RC
fi
set -e
if [[ "$U_SH_RC" -ne 0 || "$U_PS_RC" -ne 0 || "$C_SH_RC" -ne 0 || "$C_PS_RC" -ne 0 || ! "$C_SH" =~ review_independence=UNKNOWN || ! "$C_PS" =~ review_independence=UNKNOWN ]]; then
  fail "13f2-head-advance-resets-independence-to-unknown" "u=($U_SH_RC/$U_PS_RC) c_sh=($C_SH_RC:'$C_SH') c_ps=($C_PS_RC:'$C_PS')"
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
