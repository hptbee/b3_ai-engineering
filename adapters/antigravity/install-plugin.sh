#!/usr/bin/env bash
# Global Antigravity plugin lifecycle manager for B3 AI Engineering (macOS / Linux / Git Bash).
# Installs, updates, verifies, or uninstalls the canonical B3 plugin bundle under ~/.gemini/config/plugins/b3-ai-engineering and B3 skill entries in ~/.gemini/config/skills.json.
# Usage: ./adapters/antigravity/install-plugin.sh [install|update|verify|uninstall] [--plugin-root PATH] [--b3-home PATH] [--user-home PATH] [--dry-run] [--force]
set -euo pipefail

ACTION="install"
ACTION_SET=false
PLUGIN_ROOT=""
B3_HOME=""
USER_HOME=""
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|update|verify|uninstall)
      if $ACTION_SET; then echo "error: duplicate action '$1'" >&2; exit 1; fi
      ACTION="$1"; ACTION_SET=true; shift ;;
    --action)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      if $ACTION_SET; then echo "error: duplicate action '$2'" >&2; exit 1; fi
      case "$2" in
        install|update|verify|uninstall) ACTION="$2"; ACTION_SET=true ;;
        *) echo "error: invalid action '$2'" >&2; exit 1 ;;
      esac
      shift 2 ;;
    --plugin-root)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      PLUGIN_ROOT="$2"; shift 2 ;;
    --b3-home)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      B3_HOME="$2"; shift 2 ;;
    --user-home)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      USER_HOME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [install|update|verify|uninstall] [--plugin-root PATH] [--b3-home PATH] [--user-home PATH] [--dry-run] [--force]"
      exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/global-common.sh
source "${SCRIPT_DIR}/../lib/global-common.sh"

render_agent() {
  local file="$1" b3_home="$2" base="${1##*/}"
  awk -v file_path="$file" -v b3_home="$b3_home" -v base="$base" '
    BEGIN { in_fm = 0; done_fm = 0; cur = ""; desc_n = 0; body_n = 0; readonly_val = ""; name_val = "" }
    { sub(/\r$/, "") }
    NR == 1 {
      if ($0 != "---") { print "error: agent missing YAML frontmatter: " file_path > "/dev/stderr"; exit 2 }
      in_fm = 1; next
    }
    in_fm && $0 == "---" { in_fm = 0; done_fm = 1; next }
    in_fm {
      if ($0 ~ /^[a-zA-Z0-9_-]+:[[:space:]]*/) {
        split($0, parts, ":"); cur = parts[1]
        val = substr($0, length(cur) + 2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        if (cur == "name") name_val = val
        else if (cur == "readonly") readonly_val = tolower(val)
        else if (cur == "description") desc[++desc_n] = $0
      } else if (cur == "description" && ($0 ~ /^[[:space:]]+[^[:space:]]/ || $0 ~ /^[[:space:]]*$/)) {
        desc[++desc_n] = $0
      }
      next
    }
    done_fm {
      if (body_n == 0 && $0 == "") next
      body[++body_n] = $0
    }
    END {
      if (!done_fm) { print "error: agent frontmatter not closed: " file_path > "/dev/stderr"; exit 2 }
      while (desc_n > 0 && desc[desc_n] ~ /^[[:space:]]*$/) desc_n--
      while (body_n > 0 && body[body_n] ~ /^[[:space:]]*$/) body_n--
      if (name_val == "") { print "error: agent missing name in frontmatter: " file_path > "/dev/stderr"; exit 2 }
      if (desc_n == 0) { print "error: agent missing description in frontmatter: " file_path > "/dev/stderr"; exit 2 }
      if (readonly_val != "true" && readonly_val != "false") { print "error: agent missing boolean readonly in frontmatter: " file_path > "/dev/stderr"; exit 2 }
      tools = (readonly_val == "true") ? "tools: [read_file]" : "tools: [read_file, edit_file, write_file, run_command, manage_task]"
      print "---"; print "name: " name_val
      for (i = 1; i <= desc_n; i++) print desc[i]
      print "subagent: true"; print "mainAgent: false"; print tools; print "---"
      print ""; print "<!-- Generated from " b3_home "/agents/" base " - do not edit here -->"
      if (body_n > 0) { print ""; for (i = 1; i <= body_n; i++) print body[i] }
    }
  ' "$file"
}

is_b3_plugin_json() {
  local pj="$1"
  [[ -f "$pj" ]] || return 1
  awk '
    BEGIN { bad = 0; seen_name = 0; txt = "" }
    {
      gsub(/\r/, ""); txt = txt $0 "\n"; rest = $0
      while (match(rest, /"[^"]*"[[:space:]]*:/)) {
        tok = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        sub(/^"/, "", tok); sub(/"[[:space:]]*:$/, "", tok)
        if (tok == "name") seen_name = 1
        if (tok != "name" && tok != "displayName" && tok != "version" && tok != "description" && tok != "suggestedPrompts") bad = 1
      }
    }
    END {
      if (bad || !seen_name) exit 1
      if (txt !~ /^[[:space:]]*\{/) exit 1
      if (txt !~ /\}[[:space:]]*$/) exit 1
      if (txt !~ /"name"[[:space:]]*:[[:space:]]*"b3-ai-engineering"/) exit 1
    }
  ' "$pj"
}

check_coexistence() {
  local user_home="$1" plugin_root="$2"
  shift 2
  local plugin_norm
  plugin_norm="$(norm_cmp_path "$plugin_root")"

  count_skill_overlaps "${user_home}/.gemini/config/skills" "$@"
  if [[ $OVERLAP_COUNT -gt 0 ]]; then
    echo "COEXISTENCE_WARNING: ~/.gemini/config/skills contains ${OVERLAP_COUNT} overlapping B3 skill(s) (${OVERLAP_FIRST}...); remove loose copies to prevent duplicate discovery."
  fi

  local plugins_dir="${user_home}/.gemini/config/plugins"
  if [[ -d "$plugins_dir" ]]; then
    local cand cand_existing
    for cand in "${plugins_dir}"/*; do
      [[ -d "$cand" ]] || continue
      if ! cand_existing="$(canon_existing_dir "$cand")"; then continue; fi
      [[ "$(norm_cmp_path "$cand_existing")" == "$plugin_norm" ]] && continue
      if [[ -f "${cand}/plugin.json" ]] && grep -qE '"name"[[:space:]]*:[[:space:]]*"b3-ai-engineering"' "${cand}/plugin.json"; then
        echo "COEXISTENCE_WARNING: duplicate b3-ai-engineering plugin found at ${cand}; only one plugin directory with name 'b3-ai-engineering' should exist."
      fi
    done
  fi

  count_skill_overlaps "${user_home}/.agents/skills" "$@"
  if [[ $OVERLAP_COUNT -gt 0 ]]; then
    echo "COEXISTENCE_WARNING: ~/.agents/skills contains ${OVERLAP_COUNT} overlapping B3 skill(s); global Antigravity discovery may duplicate bundled plugin skills."
  fi
}

_B3_JSON_RT=""
detect_json_runtime() {
  if [[ -n "$_B3_JSON_RT" ]]; then return 0; fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import json,os,sys' >/dev/null 2>&1; then
    _B3_JSON_RT="python3"
  elif command -v python >/dev/null 2>&1 && python -c 'import json,os,sys' >/dev/null 2>&1; then
    _B3_JSON_RT="python"
  elif command -v node >/dev/null 2>&1 && node -e 'process.exit(0)' >/dev/null 2>&1; then
    _B3_JSON_RT="node"
  else
    _B3_JSON_RT="none"
  fi
}

norm_skill_json_path() {
  local p="$1"
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  p="$(upper_drive "$p")"
  while [[ "$p" == */ && "$p" != "/" && ! "$p" =~ ^[A-Za-z]:/$ ]]; do
    p="${p%/}"
  done
  printf '%s' "$p"
}

json_escape_str() {
  local s="$1" out="" i ch
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:$i:1}"
    case "$ch" in
      '\') out="${out}\\\\" ;;
      '"')  out="${out}\\\"" ;;
      $'\t') out="${out}\\t" ;;
      $'\r') out="${out}\\r" ;;
      $'\n') out="${out}\\n" ;;
      *) out="${out}${ch}" ;;
    esac
  done
  printf '%s' "$out"
}

build_desired_skills_json_entries() {
  DESIRED_SKILLS_JSON_ENTRIES=()
  local raw_list="" dir p
  if [[ ${#CORE_SKILL_DIRS[@]} -gt 0 ]]; then
    raw_list="$(
      for dir in "${CORE_SKILL_DIRS[@]}"; do
        p="$(norm_skill_json_path "${dir%/*}")"
        [[ -n "$p" ]] && printf '%s\n' "$p"
      done | LC_ALL=C sort -u
    )"
    while IFS= read -r p; do
      [[ -n "$p" ]] && DESIRED_SKILLS_JSON_ENTRIES+=("$p")
    done <<< "$raw_list"
  fi
  if [[ ${#CMD_SKILL_DIRS[@]} -gt 0 ]]; then
    raw_list="$(
      for dir in "${CMD_SKILL_DIRS[@]}"; do
        p="$(norm_skill_json_path "${dir%/*}")"
        [[ -n "$p" ]] && printf '%s\n' "$p"
      done | LC_ALL=C sort -u
    )"
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      if [[ ${#DESIRED_SKILLS_JSON_ENTRIES[@]} -eq 0 ]] || ! array_contains "$p" "${DESIRED_SKILLS_JSON_ENTRIES[@]}"; then
        DESIRED_SKILLS_JSON_ENTRIES+=("$p")
      fi
    done <<< "$raw_list"
  fi
}

collect_uninstall_b3_prefixes() {
  UNINSTALL_B3_PREFIXES=()
  local cand
  if $M_EXISTS && [[ -n "${M_B3_HOME:-}" ]]; then
    cand="$(norm_skill_json_path "$M_B3_HOME")"
    [[ -n "$cand" ]] && UNINSTALL_B3_PREFIXES+=("$cand")
  fi
  local rfile="${PLUGIN_ROOT}/rules/AGENTS.md"
  if [[ -f "$rfile" ]] && ! is_link_entry "$rfile"; then
    cand="$(sed -n 's/.*Generated from B3_HOME:[[:space:]]*`\([^`]*\)`.*/\1/p' "$rfile" | head -n 1 || true)"
    cand="$(norm_skill_json_path "$cand")"
    if [[ -n "$cand" ]] && { [[ ${#UNINSTALL_B3_PREFIXES[@]} -eq 0 ]] || ! array_contains "$cand" "${UNINSTALL_B3_PREFIXES[@]}"; }; then
      UNINSTALL_B3_PREFIXES+=("$cand")
    fi
  fi
  if command -v readlink >/dev/null 2>&1 && [[ -d "${PLUGIN_ROOT}/skills" ]] && ! is_link_entry "${PLUGIN_ROOT}/skills"; then
    local sk tgt tgt_parent
    for sk in "${PLUGIN_ROOT}/skills"/*; do
      [[ -L "$sk" ]] || continue
      tgt="$(readlink "$sk" 2>/dev/null || true)"
      if $IS_WINDOWS && command -v cygpath >/dev/null 2>&1; then
        tgt="$(cygpath -m "$tgt" 2>/dev/null || printf '%s' "$tgt")"
      elif [[ -n "$tgt" && "$tgt" != /* && ! "$tgt" =~ ^[A-Za-z]: ]]; then
        tgt_parent="$(canon_path_allow_missing "$(dirname "$sk")")"
        tgt="${tgt_parent%/}/${tgt}"
      fi
      tgt="$(norm_skill_json_path "$tgt")"
      if [[ "$tgt" =~ ^(.+)/(skills/[^/]+|adapters/command-skills)/[^/]+$ ]]; then
        cand="$(norm_skill_json_path "${BASH_REMATCH[1]}")"
        if [[ -n "$cand" ]] && { [[ ${#UNINSTALL_B3_PREFIXES[@]} -eq 0 ]] || ! array_contains "$cand" "${UNINSTALL_B3_PREFIXES[@]}"; }; then
          UNINSTALL_B3_PREFIXES+=("$cand")
        fi
      fi
    done
  fi
}

skills_json_op() {
  local mode="$1" sj_path="$2" desired_nl="$3" prefixes_nl="$4"
  detect_json_runtime
  local is_win_flag="0" force_flag="0" dry_flag="0"
  $IS_WINDOWS && is_win_flag="1"
  $FORCE && force_flag="1"
  $DRY_RUN && dry_flag="1"

  if [[ "$_B3_JSON_RT" == "python3" || "$_B3_JSON_RT" == "python" ]]; then
    B3_SJ_MODE="$mode" B3_SJ_PATH="$sj_path" B3_SJ_FORCE="$force_flag" \
    B3_SJ_DRY_RUN="$dry_flag" B3_SJ_IS_WIN="$is_win_flag" \
    B3_SJ_DESIRED="$desired_nl" B3_SJ_PREFIXES="$prefixes_nl" \
    "$_B3_JSON_RT" - <<'PYEOF'
import json, os, re, sys

mode = os.environ["B3_SJ_MODE"]
sj_path = os.environ["B3_SJ_PATH"]
force = os.environ.get("B3_SJ_FORCE") == "1"
dry_run = os.environ.get("B3_SJ_DRY_RUN") == "1"
is_win = os.environ.get("B3_SJ_IS_WIN") == "1"
desired = [ln for ln in os.environ.get("B3_SJ_DESIRED", "").splitlines() if ln]
prefixes = [ln for ln in os.environ.get("B3_SJ_PREFIXES", "").splitlines() if ln]

def norm_p(val):
    if not isinstance(val, str):
        return ""
    p = val.strip().replace("\\", "/")
    if is_win and re.match(r"^[a-z]:", p):
        p = p[0].upper() + p[1:]
    if len(p) > 1 and not re.match(r"^[A-Za-z]:/$", p):
        p = p.rstrip("/")
    return p

def cmp_k(val):
    n = norm_p(val)
    return n.lower() if is_win else n

def is_b3(val):
    ck = cmp_k(val)
    if not ck:
        return False
    for raw_px in prefixes:
        pk = cmp_k(raw_px)
        if not pk:
            continue
        cmd_p = "/adapters/command-skills" if pk == "/" else pk + "/adapters/command-skills"
        sk_exact = "/skills" if pk == "/" else pk + "/skills"
        sk_pref = "/skills/" if pk == "/" else pk + "/skills/"
        if ck == cmd_p or ck == sk_exact or ck.startswith(sk_pref):
            return True
    return False

exists = os.path.isfile(sj_path)
parsed = None
parse_err = ""
if exists:
    try:
        with open(sj_path, "r", encoding="utf-8") as f:
            parsed = json.load(f)
        if not isinstance(parsed, dict):
            parse_err = "global skills.json root must be a JSON object"
        elif "entries" in parsed and not isinstance(parsed["entries"], list):
            parse_err = 'global skills.json "entries" must be a JSON array'
    except Exception as e:
        parse_err = f"invalid JSON in global skills.json: {e}"

if mode == "preflight":
    if exists and parse_err and not force:
        sys.stderr.write(f"error: UPDATE_CONFLICT: invalid global skills.json at {sj_path} ({parse_err}) (preserved; backup before --force)\n")
        sys.exit(1)
    sys.exit(0)

if mode == "verify":
    if not exists:
        print(f"missing global skills.json at {sj_path}")
        sys.exit(1)
    if parse_err:
        print(f"invalid global skills.json at {sj_path} : {parse_err}")
        sys.exit(1)
    if "entries" not in parsed:
        print(f"global skills.json missing entries array at {sj_path}")
        sys.exit(1)
    errs = []
    entries = parsed["entries"]
    found_keys = set()
    for it in entries:
        if isinstance(it, dict) and isinstance(it.get("path"), str):
            ck = cmp_k(it["path"])
            if ck:
                found_keys.add(ck)
    desired_keys = {cmp_k(d) for d in desired}
    for d in desired:
        if cmp_k(d) not in found_keys:
            errs.append(f"global skills.json missing B3 entry: {d}")
    for it in entries:
        if isinstance(it, dict) and isinstance(it.get("path"), str):
            ck = cmp_k(it["path"])
            if ck and is_b3(it["path"]) and ck not in desired_keys:
                errs.append(f"stale B3 entry in global skills.json: {it['path']}")
    for e in errs:
        print(e)
    sys.exit(1 if errs else 0)

if mode == "merge":
    base = parsed if (exists and not parse_err) else {}
    out = {}
    for k, v in base.items():
        if k != "entries":
            out[k] = v
    desired_keys = {cmp_k(d) for d in desired}
    kept = []
    for it in base.get("entries", []):
        p = it.get("path") if isinstance(it, dict) else None
        if isinstance(p, str):
            ck = cmp_k(p)
            if ck and (is_b3(p) or ck in desired_keys):
                continue
        kept.append(it)
    for d in desired:
        kept.append({"path": norm_p(d)})
    out["entries"] = kept
    parent = os.path.dirname(sj_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(sj_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
    sys.exit(0)

if mode == "uninstall":
    if not exists:
        print("NONE")
        sys.exit(0)
    if parse_err:
        sys.stderr.write(f"warning: skipping invalid global skills.json: {sj_path} ({parse_err})\n")
        sys.exit(2)
    entries = parsed.get("entries", [])
    kept = []
    removed_n = 0
    for it in entries:
        p = it.get("path") if isinstance(it, dict) else None
        if isinstance(p, str) and is_b3(p):
            removed_n += 1
        else:
            kept.append(it)
    if removed_n == 0:
        print("UNCHANGED")
        sys.exit(0)
    other_keys = [k for k in parsed.keys() if k != "entries"]
    if len(kept) == 0 and len(other_keys) == 0:
        if not dry_run:
            os.remove(sj_path)
        print(f"REMOVE:{removed_n}")
        sys.exit(0)
    out = {}
    for k, v in parsed.items():
        if k != "entries":
            out[k] = v
    out["entries"] = kept
    if not dry_run:
        with open(sj_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
    print(f"UPDATE:{removed_n}")
    sys.exit(0)
PYEOF
    return $?
  fi

  if [[ "$_B3_JSON_RT" == "node" ]]; then
    B3_SJ_MODE="$mode" B3_SJ_PATH="$sj_path" B3_SJ_FORCE="$force_flag" \
    B3_SJ_DRY_RUN="$dry_flag" B3_SJ_IS_WIN="$is_win_flag" \
    B3_SJ_DESIRED="$desired_nl" B3_SJ_PREFIXES="$prefixes_nl" \
    node - <<'JSEOF'
const fs = require("fs");
const path = require("path");
const mode = process.env.B3_SJ_MODE;
const sjPath = process.env.B3_SJ_PATH;
const force = process.env.B3_SJ_FORCE === "1";
const dryRun = process.env.B3_SJ_DRY_RUN === "1";
const isWin = process.env.B3_SJ_IS_WIN === "1";
const desired = (process.env.B3_SJ_DESIRED || "").split(/\r?\n/).filter(Boolean);
const prefixes = (process.env.B3_SJ_PREFIXES || "").split(/\r?\n/).filter(Boolean);

function normP(val) {
  if (typeof val !== "string") return "";
  let p = val.trim().replace(/\\/g, "/");
  if (isWin && /^[a-z]:/.test(p)) p = p[0].toUpperCase() + p.slice(1);
  if (p.length > 1 && !/^[A-Za-z]:\/$/.test(p)) p = p.replace(/\/+$/, "");
  return p;
}
function cmpK(val) {
  const n = normP(val);
  return isWin ? n.toLowerCase() : n;
}
function isB3(val) {
  const ck = cmpK(val);
  if (!ck) return false;
  for (const rawPx of prefixes) {
    const pk = cmpK(rawPx);
    if (!pk) continue;
    const cmdP = pk === "/" ? "/adapters/command-skills" : `${pk}/adapters/command-skills`;
    const skExact = pk === "/" ? "/skills" : `${pk}/skills`;
    const skPref = pk === "/" ? "/skills/" : `${pk}/skills/`;
    if (ck === cmdP || ck === skExact || ck.startsWith(skPref)) return true;
  }
  return false;
}

const exists = fs.existsSync(sjPath) && fs.statSync(sjPath).isFile();
let parsed = null;
let parseErr = "";
if (exists) {
  try {
    parsed = JSON.parse(fs.readFileSync(sjPath, "utf8"));
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      parseErr = "global skills.json root must be a JSON object";
    } else if ("entries" in parsed && !Array.isArray(parsed.entries)) {
      parseErr = 'global skills.json "entries" must be a JSON array';
    }
  } catch (e) {
    parseErr = `invalid JSON in global skills.json: ${e.message}`;
  }
}

if (mode === "preflight") {
  if (exists && parseErr && !force) {
    process.stderr.write(`error: UPDATE_CONFLICT: invalid global skills.json at ${sjPath} (${parseErr}) (preserved; backup before --force)\n`);
    process.exit(1);
  }
  process.exit(0);
}
if (mode === "verify") {
  if (!exists) { console.log(`missing global skills.json at ${sjPath}`); process.exit(1); }
  if (parseErr) { console.log(`invalid global skills.json at ${sjPath} : ${parseErr}`); process.exit(1); }
  if (!("entries" in parsed)) { console.log(`global skills.json missing entries array at ${sjPath}`); process.exit(1); }
  const errs = [];
  const found = new Set();
  for (const it of parsed.entries) {
    if (it && typeof it === "object" && typeof it.path === "string") {
      const ck = cmpK(it.path);
      if (ck) found.add(ck);
    }
  }
  const desiredKeys = new Set(desired.map(cmpK));
  for (const d of desired) {
    if (!found.has(cmpK(d))) errs.push(`global skills.json missing B3 entry: ${d}`);
  }
  for (const it of parsed.entries) {
    if (it && typeof it === "object" && typeof it.path === "string") {
      const ck = cmpK(it.path);
      if (ck && isB3(it.path) && !desiredKeys.has(ck)) errs.push(`stale B3 entry in global skills.json: ${it.path}`);
    }
  }
  for (const e of errs) console.log(e);
  process.exit(errs.length ? 1 : 0);
}
if (mode === "merge") {
  const base = (exists && !parseErr) ? parsed : {};
  const out = {};
  for (const k of Object.keys(base)) {
    if (k !== "entries") out[k] = base[k];
  }
  const desiredKeys = new Set(desired.map(cmpK));
  const kept = [];
  for (const it of (base.entries || [])) {
    const p = (it && typeof it === "object") ? it.path : null;
    if (typeof p === "string") {
      const ck = cmpK(p);
      if (ck && (isB3(p) || desiredKeys.has(ck))) continue;
    }
    kept.push(it);
  }
  for (const d of desired) kept.push({ path: normP(d) });
  out.entries = kept;
  const parent = path.dirname(sjPath);
  if (parent) fs.mkdirSync(parent, { recursive: true });
  fs.writeFileSync(sjPath, JSON.stringify(out, null, 2) + "\n", "utf8");
  process.exit(0);
}
if (mode === "uninstall") {
  if (!exists) { console.log("NONE"); process.exit(0); }
  if (parseErr) {
    process.stderr.write(`warning: skipping invalid global skills.json: ${sjPath} (${parseErr})\n`);
    process.exit(2);
  }
  const entries = parsed.entries || [];
  const kept = [];
  let removedN = 0;
  for (const it of entries) {
    const p = (it && typeof it === "object") ? it.path : null;
    if (typeof p === "string" && isB3(p)) removedN++;
    else kept.push(it);
  }
  if (removedN === 0) { console.log("UNCHANGED"); process.exit(0); }
  const otherKeys = Object.keys(parsed).filter((k) => k !== "entries");
  if (kept.length === 0 && otherKeys.length === 0) {
    if (!dryRun) fs.unlinkSync(sjPath);
    console.log(`REMOVE:${removedN}`);
    process.exit(0);
  }
  const out = {};
  for (const k of Object.keys(parsed)) {
    if (k !== "entries") out[k] = parsed[k];
  }
  out.entries = kept;
  if (!dryRun) fs.writeFileSync(sjPath, JSON.stringify(out, null, 2) + "\n", "utf8");
  console.log(`UPDATE:${removedN}`);
  process.exit(0);
}
JSEOF
    return $?
  fi

  # Minimal pure-Bash fallback when neither python nor node is available
  if [[ ! -f "$sj_path" ]]; then
    case "$mode" in
      preflight) return 0 ;;
      verify) echo "missing global skills.json at $sj_path"; return 1 ;;
      uninstall) echo "NONE"; return 0 ;;
      merge)
        local json_body="{"$'\n'"  \"entries\": ["$'\n' first=true line esc
        while IFS= read -r line; do
          [[ -n "$line" ]] || continue
          esc="$(json_escape_str "$(norm_skill_json_path "$line")")"
          if $first; then first=false; else json_body="${json_body},"$'\n'; fi
          json_body="${json_body}    { \"path\": \"${esc}\" }"
        done <<< "$desired_nl"
        json_body="${json_body}"$'\n'"  ]"$'\n'"}"$'\n'
        write_lf_file "$sj_path" "$json_body"
        return 0
        ;;
    esac
  fi
  echo "error: python3, python, or node is required to manage existing skills.json at $sj_path" >&2
  return 1
}

USER_HOME="$(resolve_user_home "$USER_HOME")"
if [[ -z "$PLUGIN_ROOT" ]]; then PLUGIN_ROOT="${USER_HOME}/.gemini/config/plugins/b3-ai-engineering"; fi
PLUGIN_ROOT="$(canon_path_allow_missing "$PLUGIN_ROOT")"
MANIFEST_FILE="${PLUGIN_ROOT}/.b3-plugin-manifest"
GEMINI_DIR="${USER_HOME}/.gemini"
GEMINI_CONFIG_DIR="${GEMINI_DIR}/config"
SKILLS_JSON_PATH="${GEMINI_CONFIG_DIR}/skills.json"

# --- Uninstall action ---
if [[ "$ACTION" == "uninstall" ]]; then
  if is_link_entry "$PLUGIN_ROOT"; then
    echo "error: refusing to uninstall link-based PluginRoot: $PLUGIN_ROOT" >&2; exit 1
  fi
  if is_link_entry "$MANIFEST_FILE"; then
    echo "error: refusing to read link-based manifest: $MANIFEST_FILE" >&2; exit 1
  fi
  manifest_load "$MANIFEST_FILE"
  if $M_EXISTS && { $M_CORRUPT || [[ "$M_SCHEMA" != "b3-antigravity-plugin-v1" ]]; }; then
    echo "error: refusing to uninstall invalid or corrupt B3 manifest at $MANIFEST_FILE" >&2; exit 1
  fi
  HAS_PJ=false
  is_b3_plugin_json "${PLUGIN_ROOT}/plugin.json" && HAS_PJ=true
  if ! $M_EXISTS && ! $HAS_PJ; then
    if [[ -e "$PLUGIN_ROOT" || -L "$PLUGIN_ROOT" ]]; then
      echo "error: refusing to uninstall unrecognized directory (missing B3 manifest or plugin.json): $PLUGIN_ROOT" >&2; exit 1
    fi
    echo "nothing installed (no B3 plugin at $PLUGIN_ROOT)"
    exit 0
  fi

  collect_uninstall_b3_prefixes
  TRACKED_FILES=()
  TRACKED_LINKS=()
  if $M_EXISTS; then
    if [[ ${#M_KINDS[@]} -gt 0 ]]; then
      for ((i = 0; i < ${#M_KINDS[@]}; i++)); do
        if [[ "${M_KINDS[$i]}" == "file" ]]; then TRACKED_FILES+=("${M_KEYS[$i]}")
        elif [[ "${M_KINDS[$i]}" == "link" ]]; then TRACKED_LINKS+=("${M_KEYS[$i]}")
        fi
      done
    fi
  else
    [[ -f "${PLUGIN_ROOT}/plugin.json" ]] && TRACKED_FILES+=("plugin.json")
    if [[ -f "${PLUGIN_ROOT}/rules/AGENTS.md" ]] && grep -q 'Generated from B3_HOME:' "${PLUGIN_ROOT}/rules/AGENTS.md"; then
      TRACKED_FILES+=("rules/AGENTS.md")
    fi
    if [[ -d "${PLUGIN_ROOT}/agents" ]] && ! is_link_entry "${PLUGIN_ROOT}/agents"; then
      for af in "${PLUGIN_ROOT}/agents"/*.md; do
        [[ -f "$af" ]] || continue
        if grep -Eq '<!-- Generated from .*/(\.cursor/)?agents/' "$af"; then
          TRACKED_FILES+=("agents/${af##*/}")
        fi
      done
    fi
    if [[ -d "${PLUGIN_ROOT}/skills" ]] && ! is_link_entry "${PLUGIN_ROOT}/skills"; then
      for sk in "${PLUGIN_ROOT}/skills"/*; do
        [[ -e "$sk" || -L "$sk" ]] || continue
        is_link_entry "$sk" && TRACKED_LINKS+=("skills/${sk##*/}")
      done
    fi
  fi

  REMOVED=0
  SKIPPED=0
  if is_link_entry "${PLUGIN_ROOT}/skills"; then
    echo "warning: skipping symlinked skills directory: ${PLUGIN_ROOT}/skills" >&2
    SKIPPED=$((SKIPPED + 1))
  elif [[ ${#TRACKED_LINKS[@]} -gt 0 ]]; then
    for lk in "${TRACKED_LINKS[@]}"; do
      exp_target=""
      if $M_EXISTS; then exp_target="$(manifest_get "link" "$lk" 2>/dev/null || true)"; fi
      uninstall_managed_link "$PLUGIN_ROOT" "PluginRoot" "${PLUGIN_ROOT}/${lk}" "$exp_target" "$M_EXISTS" "$FORCE" "$DRY_RUN" "unmanaged non-link entry"
    done
  fi
  _B3_WARNED_CONTAINERS=""
  if [[ ${#TRACKED_FILES[@]} -gt 0 ]]; then
    for fk in "${TRACKED_FILES[@]}"; do
      exp_sha=""
      if $M_EXISTS; then exp_sha="$(manifest_get "file" "$fk" 2>/dev/null || true)"; fi
      uninstall_managed_file "$PLUGIN_ROOT" "PluginRoot" "${PLUGIN_ROOT}/${fk}" "$exp_sha" "$M_EXISTS" "" "file path" "modified managed file" "true" "$FORCE" "$DRY_RUN"
    done
  fi
  removed=$REMOVED
  skipped=$SKIPPED
  if ! $DRY_RUN; then
    for sd in "${PLUGIN_ROOT}/skills" "${PLUGIN_ROOT}/rules" "${PLUGIN_ROOT}/agents"; do
      if [[ -d "$sd" && ! -L "$sd" ]]; then rmdir "$sd" 2>/dev/null || true; fi
    done
  fi
  if [[ -e "$SKILLS_JSON_PATH" || -L "$SKILLS_JSON_PATH" ]]; then
    if is_link_entry "$GEMINI_DIR" || is_link_entry "$GEMINI_CONFIG_DIR" || is_link_entry "$SKILLS_JSON_PATH"; then
      echo "warning: skipping symlinked global skills.json path: $SKILLS_JSON_PATH" >&2
      skipped=$((skipped + 1))
    elif [[ ! -f "$SKILLS_JSON_PATH" ]]; then
      echo "warning: skipping non-file global skills.json path: $SKILLS_JSON_PATH" >&2
      skipped=$((skipped + 1))
    elif [[ ${#UNINSTALL_B3_PREFIXES[@]} -gt 0 ]]; then
      prefixes_nl="$(printf '%s\n' "${UNINSTALL_B3_PREFIXES[@]}")"
      set +e
      sj_un_out="$(skills_json_op "uninstall" "$SKILLS_JSON_PATH" "" "$prefixes_nl")"
      sj_un_rc=$?
      set -e
      if [[ $sj_un_rc -eq 2 || $sj_un_rc -ne 0 ]]; then
        skipped=$((skipped + 1))
      elif [[ "$sj_un_out" == REMOVE:* ]]; then
        if $DRY_RUN; then echo "dry-run: remove $SKILLS_JSON_PATH"; fi
        removed=$((removed + 1))
      elif [[ "$sj_un_out" == UPDATE:* ]]; then
        cnt="${sj_un_out#UPDATE:}"
        if $DRY_RUN; then echo "dry-run: update $SKILLS_JSON_PATH (remove ${cnt} B3 entries)"; fi
        removed=$((removed + 1))
      fi
    fi
  fi
  if [[ $skipped -gt 0 ]]; then
    echo "UNINSTALL_CONFLICT: removed=${removed} skipped=${skipped} plugin_root=${PLUGIN_ROOT} (re-run with --force to remove modified managed entries)"
    exit 1
  fi
  if $M_EXISTS && [[ -f "$MANIFEST_FILE" && ! -L "$MANIFEST_FILE" ]]; then
    if $DRY_RUN; then echo "dry-run: remove manifest $MANIFEST_FILE"; else rm -f "$MANIFEST_FILE"; fi
    removed=$((removed + 1))
  fi
  if ! $DRY_RUN; then
    for sd in "${PLUGIN_ROOT}/skills" "${PLUGIN_ROOT}/rules" "${PLUGIN_ROOT}/agents"; do
      if [[ -d "$sd" && ! -L "$sd" ]]; then rmdir "$sd" 2>/dev/null || true; fi
    done
    if [[ -d "$PLUGIN_ROOT" && ! -L "$PLUGIN_ROOT" ]]; then rmdir "$PLUGIN_ROOT" 2>/dev/null || true; fi
  fi
  echo "UNINSTALL_OK: removed=${removed} plugin_root=${PLUGIN_ROOT}"
  exit 0
fi

# --- Resolve and validate B3Home ---
B3_HOME="$(resolve_b3_home "$B3_HOME" "${SCRIPT_DIR}/../..")"

WORKFLOW="${B3_HOME}/workflows/ship.md"
SKILLS_SRC="${B3_HOME}/skills"
CMD_SKILLS_SRC="${B3_HOME}/adapters/command-skills"
RULES_DIR="${B3_HOME}/rules"
AGENTS_DIR="${B3_HOME}/agents"

[[ -f "$WORKFLOW" ]] || { echo "error: B3_HOME missing workflow: $WORKFLOW" >&2; exit 1; }
[[ -d "$SKILLS_SRC" ]] || { echo "error: B3_HOME missing skills: $SKILLS_SRC" >&2; exit 1; }

CORE_SKILL_NAMES=()
CORE_SKILL_DIRS=()
CMD_SKILL_NAMES=()
CMD_SKILL_DIRS=()
ALL_SKILL_NAMES=()
ALL_SKILL_DIRS=()

while IFS=$'\t' read -r sname sdir; do
  [[ -n "$sname" ]] || continue
  if [[ ${#ALL_SKILL_NAMES[@]} -gt 0 ]] && array_contains "$sname" "${ALL_SKILL_NAMES[@]}"; then
    echo "error: duplicate skill name '$sname' at $sdir" >&2; exit 1
  fi
  CORE_SKILL_NAMES+=("$sname"); CORE_SKILL_DIRS+=("$sdir")
  ALL_SKILL_NAMES+=("$sname"); ALL_SKILL_DIRS+=("$sdir")
done < <(discover_skills_tsv "$SKILLS_SRC")
[[ ${#CORE_SKILL_NAMES[@]} -ge 1 ]] || { echo "error: B3_HOME has no SKILL.md under skills: $SKILLS_SRC" >&2; exit 1; }

if [[ -d "$CMD_SKILLS_SRC" ]]; then
  while IFS=$'\t' read -r sname sdir; do
    [[ -n "$sname" ]] || continue
    if [[ ${#ALL_SKILL_NAMES[@]} -gt 0 ]] && array_contains "$sname" "${ALL_SKILL_NAMES[@]}"; then
      echo "error: duplicate skill name '$sname' at $sdir" >&2; exit 1
    fi
    CMD_SKILL_NAMES+=("$sname"); CMD_SKILL_DIRS+=("$sdir")
    ALL_SKILL_NAMES+=("$sname"); ALL_SKILL_DIRS+=("$sdir")
  done < <(discover_skills_tsv "$CMD_SKILLS_SRC")
fi
[[ ${#CMD_SKILL_NAMES[@]} -ge 1 ]] || { echo "error: B3_HOME has no command skills under: $CMD_SKILLS_SRC" >&2; exit 1; }

build_desired_skills_json_entries
DESIRED_SKILLS_JSON_NL="$(printf '%s\n' "${DESIRED_SKILLS_JSON_ENTRIES[@]}")"

RULE_FILES=()
while IFS= read -r rf; do
  [[ -n "$rf" ]] && RULE_FILES+=("$rf")
done < <(find "$RULES_DIR" -maxdepth 1 -name '*.md' -type f | LC_ALL=C sort)
[[ ${#RULE_FILES[@]} -ge 1 ]] || { echo "error: B3_HOME has no rules under $RULES_DIR" >&2; exit 1; }

RULES_CONTENT="# B3 AI Engineering Rules

Generated from B3_HOME: \`${B3_HOME}\` (do not edit here).
Resolve B3_HOME from \`B3_HOME\` env, product \`.b3/home\`, or \`${B3_HOME}\`.
Precedence: \`${B3_HOME}/docs/precedence.md\`. Ship: \`${B3_HOME}/workflows/ship.md\`. Review loop: \`${B3_HOME}/review-loop/strategy.md\`.
Project-level AGENTS.md, GEMINI.md, .agents/rules/, and .agents/skills/ override this global baseline within their project scope; per-project install-product is optional.
B3 commands (\`/b3-plan\`, \`/b3-implement\`, \`/b3-debug\`, \`/b3-review\`, \`/b3-verify\`, \`/b3-review-loop\`, \`/b3-ship\`, \`/b3-research-ship\`, \`/b3-pr-resolve\`, \`/b3-pr-reply\`, \`/b3-pr-comment\`) and workflows remain available across local projects via bundled skills using the fallback B3_HOME above."

for rf in "${RULE_FILES[@]}"; do
  stripped="$(strip_yaml_frontmatter "$rf")"
  if [[ -n "$stripped" ]]; then
    RULES_CONTENT="${RULES_CONTENT}

---

${stripped}"
  fi
done
RULES_CONTENT="${RULES_CONTENT}
"
RULES_BYTES="$(printf '%s' "$RULES_CONTENT" | LC_ALL=C wc -c | tr -d ' ')"
if [[ "$RULES_BYTES" -ge 24000 ]]; then
  echo "error: generated rules/AGENTS.md is $RULES_BYTES bytes (must stay under 24000 bytes)" >&2; exit 1
fi

AGENT_FILES=()
while IFS= read -r af; do
  [[ -n "$af" ]] && AGENT_FILES+=("${AGENTS_DIR}/${af}")
done < <(list_canonical_md_names "$AGENTS_DIR")
[[ ${#AGENT_FILES[@]} -ge 1 ]] || { echo "error: B3_HOME has no agent definitions under $AGENTS_DIR" >&2; exit 1; }

AGENT_BASES=()
AGENT_CONTENTS=()
for af in "${AGENT_FILES[@]}"; do
  rendered="$(render_agent "$af" "$B3_HOME")"
  AGENT_BASES+=("${af##*/}")
  AGENT_CONTENTS+=("${rendered}
")
done

PLUGIN_JSON='{
  "name": "b3-ai-engineering",
  "displayName": "B3 AI Engineering",
  "version": "1.0.0",
  "description": "Personal AI engineering system: portable rules, engineering and domain skills, independent review-loop roles, and autonomous development lifecycle.",
  "suggestedPrompts": [
    "Run /b3-ship for a new feature or plan in this repository",
    "Run an independent review-loop on the current git diff",
    "Create an implementation plan without editing code yet"
  ]
}
'

# --- Verify action ---
if [[ "$ACTION" == "verify" ]]; then
  ERRORS=()
  PLUGIN_OK=true; RULES_OK=true; SKILLS_OK=true; COMMANDS_OK=true; AGENTS_OK=true; SKILLS_JSON_OK=true

  if [[ ! -d "$PLUGIN_ROOT" || -L "$PLUGIN_ROOT" ]]; then
    PLUGIN_OK=false; RULES_OK=false; SKILLS_OK=false; COMMANDS_OK=false; AGENTS_OK=false
    ERRORS+=("plugin directory missing or invalid: $PLUGIN_ROOT")
  else
    if is_link_entry "$MANIFEST_FILE"; then
      PLUGIN_OK=false
      ERRORS+=("missing or invalid .b3-plugin-manifest at $MANIFEST_FILE")
      M_EXISTS=false; M_CORRUPT=false; M_SCHEMA=""; M_KINDS=(); M_KEYS=(); M_VALS=()
    else
      manifest_load "$MANIFEST_FILE"
      if ! $M_EXISTS || $M_CORRUPT || [[ "$M_SCHEMA" != "b3-antigravity-plugin-v1" ]]; then
        PLUGIN_OK=false
        ERRORS+=("missing or invalid .b3-plugin-manifest at $MANIFEST_FILE")
      fi
    fi

    PJ_PATH="${PLUGIN_ROOT}/plugin.json"
    if is_link_entry "$PJ_PATH"; then
      PLUGIN_OK=false; ERRORS+=("plugin.json is a link (expected regular file): $PJ_PATH")
    elif ! is_b3_plugin_json "$PJ_PATH"; then
      PLUGIN_OK=false; ERRORS+=("missing or invalid plugin.json at $PJ_PATH")
    elif [[ "$(sha256_file "$PJ_PATH")" != "$(sha256_text "$PLUGIN_JSON")" ]]; then
      PLUGIN_OK=false; ERRORS+=("stale or modified plugin.json at $PJ_PATH")
    fi

    RULES_DIR_OUT="${PLUGIN_ROOT}/rules"
    RULES_OUT="${RULES_DIR_OUT}/AGENTS.md"
    if is_link_entry "$RULES_DIR_OUT"; then
      RULES_OK=false; ERRORS+=("rules directory is a link (expected regular directory): $RULES_DIR_OUT")
    elif is_link_entry "$RULES_OUT"; then
      RULES_OK=false; ERRORS+=("rules/AGENTS.md is a link (expected regular file): $RULES_OUT")
    elif [[ ! -f "$RULES_OUT" ]]; then
      RULES_OK=false; ERRORS+=("missing rules/AGENTS.md at $RULES_OUT")
    else
      r_bytes="$(wc -c < "$RULES_OUT" | tr -d ' ')"
      first_non_empty="$(awk 'NF{gsub(/\r$/,""); print $0; exit}' "$RULES_OUT")"
      if [[ "$r_bytes" -ge 24000 || "$first_non_empty" == "---" ]]; then
        RULES_OK=false; ERRORS+=("invalid rules/AGENTS.md format or size (${r_bytes} B)")
      elif [[ "$(sha256_file "$RULES_OUT")" != "$(sha256_text "$RULES_CONTENT")" ]]; then
        RULES_OK=false; ERRORS+=("stale or modified rules/AGENTS.md at $RULES_OUT")
      fi
    fi

    SKILLS_OUT="${PLUGIN_ROOT}/skills"
    if is_link_entry "$SKILLS_OUT"; then
      SKILLS_OK=false; COMMANDS_OK=false
      ERRORS+=("skills directory is a link (expected container of 1-level skill links): $SKILLS_OUT")
    else
      for i in "${!CORE_SKILL_NAMES[@]}"; do
        sn="${CORE_SKILL_NAMES[$i]}"; sd="${CORE_SKILL_DIRS[$i]}"; dest="${SKILLS_OUT}/${sn}"
        if ! link_target_ok "$dest" "$sd" || [[ ! -f "${dest}/SKILL.md" ]]; then
          SKILLS_OK=false; ERRORS+=("missing or broken skill link: $dest -> $sd")
        fi
      done
      if [[ -d "$SKILLS_OUT" ]]; then
        for entry in "${SKILLS_OUT}"/*; do
          [[ -e "$entry" || -L "$entry" ]] || continue
          if is_link_entry "$entry"; then
            ename="${entry##*/}"
            if ! array_contains "$ename" "${ALL_SKILL_NAMES[@]}" && manifest_has "link" "skills/${ename}"; then
              SKILLS_OK=false; ERRORS+=("stale managed skill link present: $entry")
            fi
          fi
        done
      fi
      for i in "${!CMD_SKILL_NAMES[@]}"; do
        cn="${CMD_SKILL_NAMES[$i]}"; cd_dir="${CMD_SKILL_DIRS[$i]}"; dest="${SKILLS_OUT}/${cn}"
        if ! link_target_ok "$dest" "$cd_dir" || [[ ! -f "${dest}/SKILL.md" ]]; then
          COMMANDS_OK=false; ERRORS+=("missing or broken command-skill link: $dest -> $cd_dir")
        fi
      done
    fi
    while IFS= read -r cmd_md; do
      [[ -n "$cmd_md" ]] || continue
      core_cmd="${cmd_md%.md}"
      if ! array_contains "$core_cmd" "${CMD_SKILL_NAMES[@]}"; then
        COMMANDS_OK=false; ERRORS+=("missing expected command skill in B3_HOME: $core_cmd")
      fi
    done < <(list_canonical_md_names "${B3_HOME}/commands")

    AGENTS_OUT="${PLUGIN_ROOT}/agents"
    if is_link_entry "$AGENTS_OUT"; then
      AGENTS_OK=false; ERRORS+=("agents directory is a link (expected regular directory): $AGENTS_OUT")
    else
      for i in "${!AGENT_BASES[@]}"; do
        ab="${AGENT_BASES[$i]}"; ac="${AGENT_CONTENTS[$i]}"; dest="${AGENTS_OUT}/${ab}"
        if is_link_entry "$dest"; then
          AGENTS_OK=false; ERRORS+=("agent file is a link (expected regular file): $dest")
        elif [[ ! -f "$dest" ]]; then
          AGENTS_OK=false; ERRORS+=("missing agent file: $dest")
        elif [[ "$(sha256_file "$dest")" != "$(sha256_text "$ac")" ]]; then
          AGENTS_OK=false; ERRORS+=("stale or modified agent file: $dest")
        elif ! grep -Eq '^subagent:[[:space:]]*true[[:space:]]*$' "$dest" || ! grep -Eq '^mainAgent:[[:space:]]*false[[:space:]]*$' "$dest" || ! grep -Eq '^tools:[[:space:]]*\[' "$dest"; then
          AGENTS_OK=false; ERRORS+=("invalid subagent frontmatter in: $dest")
        fi
      done
      if [[ -d "$AGENTS_OUT" ]]; then
        for existing in "${AGENTS_OUT}"/*.md; do
          [[ -f "$existing" ]] || continue
          ebase="${existing##*/}"
          if ! array_contains "$ebase" "${AGENT_BASES[@]}" && manifest_has "file" "agents/${ebase}"; then
            AGENTS_OK=false; ERRORS+=("stale generated agent file present: $existing")
          fi
        done
      fi
    fi
  fi

  if is_link_entry "$GEMINI_DIR" || is_link_entry "$GEMINI_CONFIG_DIR" || is_link_entry "$SKILLS_JSON_PATH"; then
    SKILLS_JSON_OK=false
    ERRORS+=("global skills.json path uses symlink or junction: $SKILLS_JSON_PATH")
  elif [[ -e "$SKILLS_JSON_PATH" && ! -f "$SKILLS_JSON_PATH" ]]; then
    SKILLS_JSON_OK=false
    ERRORS+=("global skills.json path is not a regular file: $SKILLS_JSON_PATH")
  else
    set +e
    sj_ver_out="$(skills_json_op "verify" "$SKILLS_JSON_PATH" "$DESIRED_SKILLS_JSON_NL" "$B3_HOME")"
    sj_ver_rc=$?
    set -e
    if [[ $sj_ver_rc -ne 0 ]]; then
      SKILLS_JSON_OK=false
      while IFS= read -r vline; do
        [[ -n "$vline" ]] && ERRORS+=("$vline")
      done <<< "$sj_ver_out"
    fi
  fi

  $PLUGIN_OK && echo "check.plugin=OK" || echo "check.plugin=FAIL"
  $RULES_OK && echo "check.rules=OK" || echo "check.rules=FAIL"
  $SKILLS_OK && echo "check.skills=OK" || echo "check.skills=FAIL"
  $COMMANDS_OK && echo "check.commands=OK" || echo "check.commands=FAIL"
  $AGENTS_OK && echo "check.agents=OK" || echo "check.agents=FAIL"
  $SKILLS_JSON_OK && echo "check.skills_json=OK" || echo "check.skills_json=FAIL"

  check_coexistence "$USER_HOME" "$PLUGIN_ROOT" "${ALL_SKILL_NAMES[@]}"

  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    for e in "${ERRORS[@]}"; do echo "VERIFY_ERROR: $e"; done
    echo "VERIFY_FAIL: errors=${#ERRORS[@]} plugin_root=${PLUGIN_ROOT}"
    echo "note: filesystem verification only -- Antigravity runtime discovery is UNKNOWN / INCOMPLETE until verified in a live session"
    exit 1
  fi
  echo "VERIFY_OK: skills=${#CORE_SKILL_NAMES[@]} commands=${#CMD_SKILL_NAMES[@]} agents=${#AGENT_BASES[@]} rules_bytes=${RULES_BYTES} plugin_root=${PLUGIN_ROOT} b3_home=${B3_HOME}"
  echo "note: filesystem verification only -- Antigravity runtime discovery is UNKNOWN / INCOMPLETE until verified in a live session"
  exit 0
fi

# --- Preflight before any write (install / update) ---
assert_regular_file_or_missing "$MANIFEST_FILE" "managed file"
manifest_load "$MANIFEST_FILE"
if $M_EXISTS && { $M_CORRUPT || [[ "$M_SCHEMA" != "b3-antigravity-plugin-v1" ]]; }; then
  echo "error: invalid B3 manifest at $MANIFEST_FILE" >&2; exit 1
fi

assert_regular_dir_or_missing "$GEMINI_DIR" ".gemini"
assert_regular_dir_or_missing "$GEMINI_CONFIG_DIR" ".gemini/config"
assert_regular_file_or_missing "$SKILLS_JSON_PATH" "global skills.json"
skills_json_op "preflight" "$SKILLS_JSON_PATH" "$DESIRED_SKILLS_JSON_NL" "$B3_HOME" || exit 1

if [[ -e "$PLUGIN_ROOT" || -L "$PLUGIN_ROOT" ]]; then
  if [[ ! -d "$PLUGIN_ROOT" || -L "$PLUGIN_ROOT" ]]; then
    echo "error: refusing to replace existing non-directory path: $PLUGIN_ROOT" >&2; exit 1
  fi
  IS_B3_PLUGIN=false
  if $M_EXISTS || is_b3_plugin_json "${PLUGIN_ROOT}/plugin.json"; then IS_B3_PLUGIN=true; fi
  if ! $IS_B3_PLUGIN && ! $FORCE; then
    echo "error: refusing to overwrite existing non-B3 directory without --force: $PLUGIN_ROOT" >&2; exit 1
  fi
  for sub_name in rules skills agents; do
    assert_regular_dir_or_missing "${PLUGIN_ROOT}/${sub_name}" "$sub_name"
  done
  MANAGED_FILES=("${PLUGIN_ROOT}/plugin.json" "${PLUGIN_ROOT}/rules/AGENTS.md")
  for ab in "${AGENT_BASES[@]}"; do MANAGED_FILES+=("${PLUGIN_ROOT}/agents/${ab}"); done
  for mp in "${MANAGED_FILES[@]}"; do
    [[ -e "$mp" || -L "$mp" ]] || continue
    assert_regular_file_or_missing "$mp" "managed file"
    key="${mp#${PLUGIN_ROOT}/}"
    exp_sha="$(manifest_get "file" "$key" 2>/dev/null || true)"
    if ! $FORCE && { [[ -z "$exp_sha" ]] || [[ "$(sha256_file "$mp")" != "$exp_sha" ]]; }; then
      echo "error: UPDATE_CONFLICT: unmanaged or modified file: $mp (preserved; backup before --force)" >&2; exit 1
    fi
  done
  if [[ -d "${PLUGIN_ROOT}/skills" ]]; then
    for entry in "${PLUGIN_ROOT}/skills"/* "${PLUGIN_ROOT}/skills"/.[!.]* "${PLUGIN_ROOT}/skills"/..?*; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      ename="${entry##*/}"
      prior="$(manifest_get "link" "skills/${ename}" 2>/dev/null || true)"
      if is_link_entry "$entry"; then
        if [[ -n "$prior" ]]; then
          if ! $FORCE && ! link_matches_expected_or_dangling "$entry" "$prior"; then
            echo "error: UPDATE_CONFLICT: modified managed skill link: $entry" >&2; exit 1
          fi
        elif array_contains "$ename" "${ALL_SKILL_NAMES[@]}"; then
          echo "error: UPDATE_CONFLICT: untracked skill link: $entry (move manually; --force cannot delete)" >&2; exit 1
        fi
      elif array_contains "$ename" "${ALL_SKILL_NAMES[@]}"; then
        if ! $FORCE || [[ ! -f "${entry}/SKILL.md" ]]; then
          echo "error: UPDATE_CONFLICT: existing skill directory: $entry (explicit --force requires SKILL.md)" >&2; exit 1
        fi
      fi
    done
  fi
  if [[ -d "${PLUGIN_ROOT}/agents" ]]; then
    for existing in "${PLUGIN_ROOT}/agents"/*.md; do
      [[ -f "$existing" ]] || continue
      ebase="${existing##*/}"
      array_contains "$ebase" "${AGENT_BASES[@]}" && continue
      exp_sha="$(manifest_get "file" "agents/${ebase}" 2>/dev/null || true)"
      if [[ -n "$exp_sha" ]] && ! $FORCE && [[ "$(sha256_file "$existing")" != "$exp_sha" ]]; then
        echo "error: UPDATE_CONFLICT: modified stale B3 agent: $existing" >&2; exit 1
      fi
    done
  fi
fi

if $DRY_RUN; then
  echo "dry-run: action=${ACTION} plugin_root=${PLUGIN_ROOT}"
  echo "dry-run: B3_HOME=${B3_HOME}"
  echo "dry-run: write ${PLUGIN_ROOT}/plugin.json"
  echo "dry-run: write ${PLUGIN_ROOT}/rules/AGENTS.md (${RULES_BYTES} bytes)"
  echo "dry-run: link ${#ALL_SKILL_NAMES[@]} skills (${#CORE_SKILL_NAMES[@]} skills + ${#CMD_SKILL_NAMES[@]} command-skills) into ${PLUGIN_ROOT}/skills"
  echo "dry-run: write ${#AGENT_BASES[@]} agents into ${PLUGIN_ROOT}/agents"
  echo "dry-run: update ${SKILLS_JSON_PATH} (${#DESIRED_SKILLS_JSON_ENTRIES[@]} skill category entries)"
  check_coexistence "$USER_HOME" "$PLUGIN_ROOT" "${ALL_SKILL_NAMES[@]}"
  echo "DRY_RUN_OK: action=${ACTION} plugin_root=${PLUGIN_ROOT}"
  exit 0
fi

mkdir -p "$PLUGIN_ROOT" "${PLUGIN_ROOT}/rules" "${PLUGIN_ROOT}/skills" "${PLUGIN_ROOT}/agents"

MANIFEST_LINES=""

write_lf_file "${PLUGIN_ROOT}/plugin.json" "$PLUGIN_JSON"
MANIFEST_LINES="${MANIFEST_LINES}file|plugin.json|$(sha256_text "$PLUGIN_JSON")
"
write_lf_file "${PLUGIN_ROOT}/rules/AGENTS.md" "$RULES_CONTENT"
MANIFEST_LINES="${MANIFEST_LINES}file|rules/AGENTS.md|$(sha256_text "$RULES_CONTENT")
"

for entry in "${PLUGIN_ROOT}/skills"/* "${PLUGIN_ROOT}/skills"/.[!.]* "${PLUGIN_ROOT}/skills"/..?*; do
  [[ -e "$entry" || -L "$entry" ]] || continue
  ename="${entry##*/}"
  if is_link_entry "$entry"; then
    if manifest_has "link" "skills/${ename}" && ! array_contains "$ename" "${ALL_SKILL_NAMES[@]}"; then
      remove_link_only "$entry"
    fi
  elif $FORCE && array_contains "$ename" "${ALL_SKILL_NAMES[@]}"; then
    remove_dir_tree_safely "$entry"
  fi
done

SORTED_SKILL_IDX=()
while IFS= read -r idx_line; do
  [[ -n "$idx_line" ]] && SORTED_SKILL_IDX+=("${idx_line%% *}")
done < <(
  for i in "${!ALL_SKILL_NAMES[@]}"; do printf '%s %s\n' "$i" "${ALL_SKILL_NAMES[$i]}"; done | LC_ALL=C sort -k2,2
)

for i in "${SORTED_SKILL_IDX[@]}"; do
  sname="${ALL_SKILL_NAMES[$i]}"
  sdir="${ALL_SKILL_DIRS[$i]}"
  dest="${PLUGIN_ROOT}/skills/${sname}"
  if ! link_target_ok "$dest" "$sdir"; then
    if is_link_entry "$dest"; then
      if ! manifest_has "link" "skills/${sname}"; then
        echo "error: UPDATE_CONFLICT: untracked skill link: $dest" >&2; exit 1
      fi
      remove_link_only "$dest"
    fi
    create_dir_link "$dest" "$sdir"
  fi
  MANIFEST_LINES="${MANIFEST_LINES}link|skills/${sname}|${sdir}
"
done

for existing in "${PLUGIN_ROOT}/agents"/*.md; do
  [[ -f "$existing" ]] || continue
  ebase="${existing##*/}"
  if ! array_contains "$ebase" "${AGENT_BASES[@]}" && manifest_has "file" "agents/${ebase}"; then
    rm -f "$existing"
  fi
done

for i in "${!AGENT_BASES[@]}"; do
  ab="${AGENT_BASES[$i]}"; ac="${AGENT_CONTENTS[$i]}"
  write_lf_file "${PLUGIN_ROOT}/agents/${ab}" "$ac"
  MANIFEST_LINES="${MANIFEST_LINES}file|agents/${ab}|$(sha256_text "$ac")
"
done

manifest_write "$MANIFEST_FILE" "b3-antigravity-plugin-v1" "$B3_HOME" "$PLUGIN_ROOT" "$MANIFEST_LINES"

MERGE_PREFIXES_NL="$B3_HOME"
if $M_EXISTS && [[ -n "${M_B3_HOME:-}" ]]; then
  m_b3_norm="$(norm_skill_json_path "$M_B3_HOME")"
  if [[ -n "$m_b3_norm" ]] && [[ "$m_b3_norm" != "$B3_HOME" ]]; then
    MERGE_PREFIXES_NL="${MERGE_PREFIXES_NL}"$'\n'"${m_b3_norm}"
  fi
fi
skills_json_op "merge" "$SKILLS_JSON_PATH" "$DESIRED_SKILLS_JSON_NL" "$MERGE_PREFIXES_NL"

check_coexistence "$USER_HOME" "$PLUGIN_ROOT" "${ALL_SKILL_NAMES[@]}"

PLUGIN_DIR_NAME="${PLUGIN_ROOT##*/}"
ACTION_UPPER="$(to_upper "$ACTION")"
echo "${ACTION_UPPER}_OK: skills=${#CORE_SKILL_NAMES[@]} commands=${#CMD_SKILL_NAMES[@]} agents=${#AGENT_BASES[@]} rules_bytes=${RULES_BYTES} plugin_root=${PLUGIN_ROOT} b3_home=${B3_HOME}"
echo "installed Antigravity plugin at $PLUGIN_ROOT"
echo "B3_HOME=$B3_HOME"
echo "skills=${#ALL_SKILL_NAMES[@]}"
echo "skills_json=${SKILLS_JSON_PATH} (${#DESIRED_SKILLS_JSON_ENTRIES[@]} entries)"
echo "agents=${#AGENT_BASES[@]}"
echo "rules_bytes=$RULES_BYTES"
echo "manage=customization://$PLUGIN_DIR_NAME"
echo "note: this proves plugin files were generated, not Antigravity runtime discovery"
