#!/usr/bin/env bash
# scripts/evolve.sh — Daily per-project rule extraction (claude-evolution).
# Reads Claude Code sessions for each configured project, compacts them via LLM,
# extracts ALWAYS/NEVER/PREFER rules, and merges into <project>/.claude/rules/learned-rules.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ══════════════════════════════════════════════════════════════════════════════
# USAGE
# ══════════════════════════════════════════════════════════════════════════════

show_help() {
  cat << 'HELPEOF'
Usage: evolve.sh [OPTIONS]

Extract actionable coding rules from Claude Code sessions and write them to
<project>/.claude/rules/learned-rules.md (auto-loaded by Claude Code).

Options:
  --project PATH      Add a project path to process (repeatable)
  --all               Process all projects from config/evolution.toml
  --last DURATION     Time window: e.g. 24h, 7d, 2w [default: from config]
  --from DATE         Start date (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ)
  --to DATE           End date (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ)
  --dry-run           Show what would be processed, no LLM calls, no writes
  --verbose           Print debug info to stderr
  --help              Show this help message

Time Range:
  --from and --to must both be provided together.
  --last and --from/--to are mutually exclusive.
  If neither is given, uses config evolution.default_range (default: 24h).

Examples:
  evolve.sh --project ~/project/admin_server --last 7d
  evolve.sh --all
  evolve.sh --project ~/project/admin_server --dry-run
  evolve.sh --project ~/project/admin_server --from 2026-01-01 --to 2026-01-07
HELPEOF
}

# ══════════════════════════════════════════════════════════════════════════════
# PARSE CLI ARGS
# ══════════════════════════════════════════════════════════════════════════════

EXPLICIT_PROJECTS=()
USE_ALL_PROJECTS=false
LAST_DURATION=""
FROM_DATE=""
TO_DATE=""
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -lt 2 ]] && { echo "Error: --project requires a PATH argument" >&2; exit 1; }
      EXPLICIT_PROJECTS+=("$2"); shift 2 ;;
    --all)
      USE_ALL_PROJECTS=true; shift ;;
    --last)
      [[ $# -lt 2 ]] && { echo "Error: --last requires a DURATION argument" >&2; exit 1; }
      LAST_DURATION="$2"; shift 2 ;;
    --from)
      [[ $# -lt 2 ]] && { echo "Error: --from requires a DATE argument" >&2; exit 1; }
      FROM_DATE="$2"; shift 2 ;;
    --to)
      [[ $# -lt 2 ]] && { echo "Error: --to requires a DATE argument" >&2; exit 1; }
      TO_DATE="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    --verbose)
      VERBOSE=true; shift ;;
    --help|-h)
      show_help; exit 0 ;;
    *)
      echo "Error: Unknown option '$1'" >&2
      echo "Run 'evolve.sh --help' for usage." >&2
      exit 1 ;;
  esac
done

# ══════════════════════════════════════════════════════════════════════════════
# SOURCE CONFIG + STATE LIB
# ══════════════════════════════════════════════════════════════════════════════

source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/state.sh"

# ══════════════════════════════════════════════════════════════════════════════
# VALIDATE
# ══════════════════════════════════════════════════════════════════════════════

if [[ -n "$FROM_DATE" && -z "$TO_DATE" ]] || [[ -z "$FROM_DATE" && -n "$TO_DATE" ]]; then
  echo "Error: --from and --to must be provided together" >&2; exit 1
fi
if [[ -n "$LAST_DURATION" && -n "$FROM_DATE" ]]; then
  echo "Error: --last and --from/--to are mutually exclusive" >&2; exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════

debug() { [[ "$VERBOSE" == true ]] && echo "[debug] $*" >&2; return 0; }

# Copied from distill.sh
compute_time_range() {
  local duration="$1"
  local unit="${duration: -1}"
  local num="${duration%[hdw]}"
  if ! [[ "$num" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid duration '$duration'. Use format: 24h, 7d, 2w" >&2; return 1
  fi
  local seconds=0
  case "$unit" in
    h) seconds=$((num * 3600)) ;;
    d) seconds=$((num * 86400)) ;;
    w) seconds=$((num * 7 * 86400)) ;;
    *) echo "Error: Invalid duration unit '$duration'. Use h/d/w." >&2; return 1 ;;
  esac
  local now_epoch
  now_epoch=$(date +%s)
  TO_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  FROM_DATE=$(date -u -d "@$((now_epoch - seconds))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
              date -u -r "$((now_epoch - seconds))" +%Y-%m-%dT%H:%M:%SZ)
  debug "Computed range: $FROM_DATE → $TO_DATE (from '$duration')"
}

# Copied from distill.sh
format_sessions_to_text() {
  local input_file="$1"
  python3 - "$input_file" << 'PYEOF'
import json, sys

input_path = sys.argv[1]
count = 0

with open(input_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            session = json.loads(line)
        except json.JSONDecodeError:
            continue
        count += 1
        title = session.get('title') or session.get('session_id', 'Unknown')
        time_start = session.get('time_start', '')
        project = session.get('project', '')

        print("=== 会话 {}: {} ===".format(count, title))
        print("时间: {}".format(time_start))
        if project:
            print("项目: {}".format(project))
        print()

        for msg in session.get('messages', []):
            role = '用户' if msg.get('role') == 'user' else 'AI助手'
            content = (msg.get('content') or '').strip()
            if content:
                print("[{}]".format(role))
                if len(content) > 3000:
                    print(content[:3000])
                    print("... (truncated, {} chars total)".format(len(content)))
                else:
                    print(content)
            for tc in msg.get('tool_calls', []):
                tool = tc.get('tool', '?')
                inp = str(tc.get('input', ''))[:200]
                out = str(tc.get('output', ''))[:200]
                parts = ["  [Tool: {}]".format(tool)]
                if inp:
                    parts.append("  input: {}".format(inp))
                if out:
                    parts.append("  output: {}".format(out))
                print('\n'.join(parts))
            print()
        print()

sys.stderr.write("__SESSION_COUNT__={}\n".format(count))
PYEOF
}

# Copied from distill.sh
build_compact_prompt() {
  local session_text_file="$1"
  local template_file="$PROJECT_ROOT/prompts/compact.md"
  [[ ! -f "$template_file" ]] && { echo "Error: $template_file not found" >&2; return 1; }
  python3 - "$template_file" "$session_text_file" << 'PYEOF'
import sys
with open(sys.argv[1]) as f:
    template = f.read()
with open(sys.argv[2]) as f:
    session_text = f.read()
print(template.replace('{{SESSION}}', session_text))
PYEOF
}

build_rules_prompt() {
  local summaries_file="$1"
  local existing_rules_file="${2:-}"
  local max_rules="${3:-${CFG_EVOLUTION_MAX_RULES:-20}}"
  local template_file="$PROJECT_ROOT/prompts/extract-rules.md"
  [[ ! -f "$template_file" ]] && { echo "Error: $template_file not found" >&2; return 1; }
  python3 - "$template_file" "$summaries_file" "$existing_rules_file" "$max_rules" << 'PYEOF'
import sys, os
with open(sys.argv[1]) as f:
    template = f.read()
with open(sys.argv[2]) as f:
    summaries = f.read()
existing_file = sys.argv[3]
max_rules = sys.argv[4]
if existing_file and os.path.isfile(existing_file) and os.path.getsize(existing_file) > 0:
    with open(existing_file) as f:
        existing_rules = f.read().strip()
else:
    existing_rules = "（暂无已有规则，这是首次提炼）"
result = template.replace('{{SUMMARIES}}', summaries)
result = result.replace('{{EXISTING_RULES}}', existing_rules)
result = result.replace('{{MAX_RULES}}', max_rules)
print(result)
PYEOF
}

# ══════════════════════════════════════════════════════════════════════════════
# SETUP: TMPDIR + LOCKFILE
# ══════════════════════════════════════════════════════════════════════════════

EVOLVE_TMPDIR=$(mktemp -d /tmp/claude-evolution.XXXXXX)
trap 'rm -rf "$EVOLVE_TMPDIR"' EXIT

LOCKFILE="/tmp/claude-evolution.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    echo "Error: Another evolve instance is running (lockfile: $LOCKFILE)" >&2
    exit 1
  fi
  debug "Acquired lock: $LOCKFILE"
fi

# ══════════════════════════════════════════════════════════════════════════════
# RESOLVE TIME RANGE (once, shared across all projects)
# ══════════════════════════════════════════════════════════════════════════════

if [[ -n "$LAST_DURATION" ]]; then
  compute_time_range "$LAST_DURATION" || exit 1
elif [[ -n "$FROM_DATE" ]]; then
  : # already set
else
  compute_time_range "${CFG_EVOLUTION_DEFAULT_RANGE:-24h}" || exit 1
fi
debug "Time range: $FROM_DATE → $TO_DATE"

# ══════════════════════════════════════════════════════════════════════════════
# RESOLVE PROJECT LIST
# ══════════════════════════════════════════════════════════════════════════════

PROJECTS=("${EXPLICIT_PROJECTS[@]+"${EXPLICIT_PROJECTS[@]}"}")

if [[ "$USE_ALL_PROJECTS" == true ]]; then
  evo_toml="$PROJECT_ROOT/config/evolution.toml"
  if [[ -f "$evo_toml" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && PROJECTS+=("$p")
    done < <(_parse_toml_array "$evo_toml" "projects" "paths" 2>/dev/null)
  fi
  home_toml="${HOME}/.claude-evolution.toml"
  if [[ -f "$home_toml" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && PROJECTS+=("$p")
    done < <(_parse_toml_array "$home_toml" "projects" "paths" 2>/dev/null)
  fi
fi

if [[ "${#PROJECTS[@]}" -eq 0 ]]; then
  echo "Error: No projects specified. Use --project PATH or --all (with projects in config/evolution.toml)" >&2
  exit 1
fi

debug "Projects to evolve (${#PROJECTS[@]}): ${PROJECTS[*]}"

# ══════════════════════════════════════════════════════════════════════════════
# PER-PROJECT LOOP
# ══════════════════════════════════════════════════════════════════════════════

succeeded=0
skipped=0
failed=0

process_project() {
  local project_path="$1"
  local project_name
  project_name=$(basename "$project_path")

  echo "──────────────────────────────────────────────────"
  echo "Project: $project_path"

  # ── Validate project dir ────────────────────────────────────────────────────
  if [[ ! -d "$project_path" ]]; then
    echo "  Warning: project directory not found, skipping" >&2
    return 2
  fi

  local proj_tmpdir="$EVOLVE_TMPDIR/$project_name"
  mkdir -p "$proj_tmpdir"

  # ── Load state ──────────────────────────────────────────────────────────────
  state_load "$project_path"
  debug "  State: last_run=${STATE_LAST_RUN:-<never>} total=${STATE_TOTAL} rules=${STATE_RULES_COUNT}"

  # ── Parse Claude Code + OpenCode sessions for this project ──────────────────
  local ndjson_all="$proj_tmpdir/sessions_all.ndjson"
  local ndjson_claude="$proj_tmpdir/sessions_claude.ndjson"
  local ndjson_opencode="$proj_tmpdir/sessions_opencode.ndjson"

  local claude_args=(
    --claude-dir "$CFG_CLAUDE_PATH"
    --project-path "$project_path"
    --from "$FROM_DATE"
    --to "$TO_DATE"
  )
  [[ "$VERBOSE" == true ]] && claude_args+=(--verbose)

  local opencode_args=(
    --sessions-dir "$CFG_OPENCODE_PATH"
    --project-path "$project_path"
    --from "$FROM_DATE"
    --to "$TO_DATE"
  )
  [[ "$VERBOSE" == true ]] && opencode_args+=(--verbose)

  python3 "$SCRIPT_DIR/parse_claude.py" "${claude_args[@]}" > "$ndjson_claude" 2>/dev/null || true
  python3 "$SCRIPT_DIR/parse_opencode.py" "${opencode_args[@]}" > "$ndjson_opencode" 2>/dev/null || true
  cat "$ndjson_claude" "$ndjson_opencode" > "$ndjson_all"

  local claude_count opencode_count total_sessions
  claude_count=$(python3 -c "import sys; print(sum(1 for l in open(sys.argv[1]) if l.strip()))" "$ndjson_claude" 2>/dev/null || echo 0)
  opencode_count=$(python3 -c "import sys; print(sum(1 for l in open(sys.argv[1]) if l.strip()))" "$ndjson_opencode" 2>/dev/null || echo 0)
  total_sessions=$((claude_count + opencode_count))
  debug "  Raw sessions in range: $total_sessions (claude=$claude_count opencode=$opencode_count)"

  if [[ "${total_sessions:-0}" -eq 0 ]]; then
    echo "  No sessions found in range $FROM_DATE → $TO_DATE, skipping"
    rm -f "${STATE_PROCESSED_IDS_FILE:-}"
    return 3
  fi

  # ── Filter out already-processed sessions ───────────────────────────────────
  local ndjson_new="$proj_tmpdir/sessions_new.ndjson"
  local new_count_stderr
  new_count_stderr=$(mktemp "$EVOLVE_TMPDIR/nc.XXXXXX")
  state_filter_new "$ndjson_all" "$project_path" > "$ndjson_new" 2>"$new_count_stderr"
  local new_count=0
  new_count=$(python3 -c "
import re, sys
m = re.search(r'__NEW_SESSION_COUNT__=(\d+)', open(sys.argv[1]).read())
print(m.group(1) if m else '0')
" "$new_count_stderr" 2>/dev/null || echo 0)
  rm -f "$new_count_stderr"

  if [[ "${new_count:-0}" -eq 0 ]]; then
    echo "  No new sessions (all $total_sessions already processed), skipping"
    rm -f "${STATE_PROCESSED_IDS_FILE:-}"
    return 3
  fi

  # ── Filter out subagent sessions (parent_id set, or title pattern) ──────────
  local ndjson_main="$proj_tmpdir/sessions_main.ndjson"
  local main_count
  main_count=$(python3 - "$ndjson_new" "$ndjson_main" << 'FILTER_PY'
import json, re, sys

src, dst = sys.argv[1], sys.argv[2]
kept = 0
SUBAGENT_RE = re.compile(r'\(@\S+ subagent\)\s*$')

with open(src) as inf, open(dst, 'w') as outf:
    for line in inf:
        line = line.strip()
        if not line:
            continue
        try:
            s = json.loads(line)
        except json.JSONDecodeError:
            continue
        title = s.get('title', '')
        is_subagent = bool(s.get('parent_id')) or bool(SUBAGENT_RE.search(title))
        if not is_subagent:
            outf.write(json.dumps(s) + '\n')
            kept += 1

print(kept)
FILTER_PY
  )
  new_count="${main_count:-0}"
  ndjson_new="$ndjson_main"

  if [[ "${new_count:-0}" -eq 0 ]]; then
    echo "  No main sessions after filtering subagents, skipping"
    rm -f "${STATE_PROCESSED_IDS_FILE:-}"
    return 3
  fi

  echo "  New sessions: $new_count (of $total_sessions in range, subagents excluded)"

  # ── Dry-run: show sessions and exit ────────────────────────────────────────
  if [[ "$DRY_RUN" == true ]]; then
    echo "  DRY RUN: Would compact $new_count session(s) and extract rules"
    python3 - "$ndjson_new" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    for i, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        try:
            s = json.loads(line)
            title = s.get('title') or s.get('session_id', '?')
            t0 = s.get('time_start', '?')
            msgs = len(s.get('messages', []))
            print("    {}. {}  ({}, {} messages)".format(i, title, t0, msgs))
        except json.JSONDecodeError:
            print("    {}. (malformed JSON)".format(i))
PYEOF
    rm -f "${STATE_PROCESSED_IDS_FILE:-}"
    return 0
  fi

  # ── Compact each new session (concurrent via ThreadPoolExecutor) ────────────
  local summaries_file="$proj_tmpdir/summaries.txt"
  local new_ids_file="$proj_tmpdir/new_session_ids.txt"
  local max_chars="${CFG_EVOLUTION_COMPACT_MAX_CHARS:-30000}"
  local max_workers="${CFG_EVOLUTION_COMPACT_WORKERS:-1}"

  local compact_results
  compact_results=$(python3 - \
      "$ndjson_new" \
      "$proj_tmpdir" \
      "$max_chars" \
      "$max_workers" \
      "$SCRIPT_DIR" \
      "$new_count" \
      << 'COMPACT_PY'
import json, os, sys, subprocess, tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed

ndjson_file  = sys.argv[1]
tmpdir       = sys.argv[2]
max_chars    = int(sys.argv[3])
max_workers  = int(sys.argv[4])
script_dir   = sys.argv[5]
total        = sys.argv[6]

# ── Phase 1: read sessions, format text, build prompt files (serial) ─────────
sessions = []
with open(ndjson_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            s = json.loads(line)
        except json.JSONDecodeError:
            continue
        sessions.append(s)

manifest = []
for idx, s in enumerate(sessions, 1):
    session_id = s.get('session_id', '')
    title = s.get('title') or session_id or 'Unknown'
    t0    = s.get('time_start', '?')
    meta  = '{title}  ({t0})'.format(title=title, t0=t0)

    # write single-session ndjson
    single_ndjson = os.path.join(tmpdir, 's{}.ndjson'.format(idx))
    with open(single_ndjson, 'w') as f:
        f.write(json.dumps(s) + '\n')

    # format to text via format_sessions_to_text (reuse same logic)
    session_text_file = os.path.join(tmpdir, 's{}.txt'.format(idx))
    try:
        text_lines = []
        msgs = s.get('messages', [])
        for m in msgs:
            role = m.get('role', 'unknown')
            content = m.get('content', '')
            if isinstance(content, list):
                parts = []
                for c in content:
                    if isinstance(c, dict):
                        if c.get('type') == 'text':
                            parts.append(c.get('text', ''))
                        elif c.get('type') == 'tool_use':
                            parts.append('[Tool: {}]'.format(c.get('name', '')))
                        elif c.get('type') == 'tool_result':
                            out = str(c.get('content', ''))
                            parts.append('[Result: {}]'.format(out[:200]))
                    else:
                        parts.append(str(c))
                content = '\n'.join(parts)
            text_lines.append('[{}] {}'.format(role.upper(), content))
        text = '\n\n'.join(text_lines)
    except Exception:
        text = json.dumps(s)

    if len(text) > max_chars:
        text = text[:max_chars]

    with open(session_text_file, 'w') as f:
        f.write(text)

    # build prompt file
    prompt_tmpl_path = os.path.join(os.path.dirname(script_dir), 'prompts', 'compact.md')
    try:
        with open(prompt_tmpl_path) as f:
            tmpl = f.read()
        prompt = tmpl.replace('{{SESSION}}', text)
    except Exception:
        prompt = text

    prompt_file = os.path.join(tmpdir, 'cp{}.txt'.format(idx))
    with open(prompt_file, 'w') as f:
        f.write(prompt)

    manifest.append({
        'idx': idx,
        'session_id': session_id,
        'meta': meta,
        'prompt_file': prompt_file,
        'sum_file': os.path.join(tmpdir, 'sum{}.txt'.format(idx)),
    })
    print('  [{}/{}] {}'.format(idx, total, meta), file=sys.stderr)

# ── Phase 2: concurrent LLM calls ─────────────────────────────────────────────
def compact_one(item):
    idx         = item['idx']
    prompt_file = item['prompt_file']
    sum_file    = item['sum_file']
    env         = os.environ.copy()
    try:
        with open(prompt_file) as pf:
            result = subprocess.run(
                ['bash', os.path.join(script_dir, 'llm_call.sh')],
                stdin=pf,
                capture_output=True,
                text=True,
                env=env,
            )
        if result.returncode == 0 and result.stdout.strip():
            with open(sum_file, 'w') as sf:
                sf.write(result.stdout)
            return dict(item, ok=True, size=len(result.stdout))
        else:
            return dict(item, ok=False, error=result.stderr[:200])
    except Exception as e:
        return dict(item, ok=False, error=str(e))

results = []
if max_workers <= 1:
    for item in manifest:
        results.append(compact_one(item))
else:
    futures_map = {}
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        for item in manifest:
            fut = pool.submit(compact_one, item)
            futures_map[fut] = item
        for fut in as_completed(futures_map):
            results.append(fut.result())

# Sort by idx to preserve order
results.sort(key=lambda r: r['idx'])

# ── Phase 3: assemble summaries.txt and new_session_ids.txt (serial) ──────────
compact_ok = 0
compact_fail = 0
summaries_file = os.path.join(tmpdir, 'summaries.txt')
new_ids_file   = os.path.join(tmpdir, 'new_session_ids.txt')

with open(summaries_file, 'w') as sf, open(new_ids_file, 'w') as idf:
    for r in results:
        if r.get('ok'):
            sf.write('=== 会话 {}: {} ===\n'.format(r['idx'], r['meta']))
            try:
                with open(r['sum_file']) as sumf:
                    sf.write(sumf.read())
            except Exception:
                pass
            sf.write('\n')
            compact_ok += 1
            sid = r.get('session_id', '')
            if sid:
                idf.write(sid + '\n')
        else:
            compact_fail += 1
            print('    Warning: compact failed for session {}: {}'.format(
                r['idx'], r.get('error', 'unknown')), file=sys.stderr)

print('__COMPACT_OK__={}'.format(compact_ok))
print('__COMPACT_FAIL__={}'.format(compact_fail))
COMPACT_PY
  )

  local compact_ok compact_fail
  compact_ok=$(printf '%s' "$compact_results" | grep '__COMPACT_OK__=' | head -1 | cut -d= -f2 | tr -d '[:space:]')
  compact_fail=$(printf '%s' "$compact_results" | grep '__COMPACT_FAIL__=' | head -1 | cut -d= -f2 | tr -d '[:space:]')
  compact_ok="${compact_ok:-0}"
  compact_fail="${compact_fail:-0}"

  if [[ "$compact_ok" -eq 0 ]]; then
    echo "  Error: All $new_count session compactions failed" >&2
    rm -f "${STATE_PROCESSED_IDS_FILE:-}"
    return 1
  fi
  echo "  Compacted $compact_ok/$new_count session(s)" >&2

  # ── Extract rules via LLM ───────────────────────────────────────────────────
  local rules_prompt_file="$proj_tmpdir/rules_prompt.txt"
  local existing_rules_file="$project_path/.claude/rules/learned-rules.md"
  if ! build_rules_prompt "$summaries_file" "$existing_rules_file" > "$rules_prompt_file"; then
    echo "  Error: Failed to build rules prompt" >&2
    rm -f "${STATE_PROCESSED_IDS_FILE:-}"
    return 1
  fi

  local raw_rules_file="$proj_tmpdir/raw_rules.md"
  local rules_model="${CFG_EVOLUTION_RULES_MODEL:-}"
  echo "  Extracting rules via LLM${rules_model:+ (model: $rules_model)}..." >&2
  if ! LLM_MODEL="${rules_model:-$LLM_MODEL}" "$SCRIPT_DIR/llm_call.sh" < "$rules_prompt_file" > "$raw_rules_file"; then
    echo "  Error: Rule extraction LLM call failed" >&2
    rm -f "${STATE_PROCESSED_IDS_FILE:-}"
    return 1
  fi
  if [[ ! -s "$raw_rules_file" ]]; then
    echo "  Error: LLM returned empty rules response" >&2
    rm -f "${STATE_PROCESSED_IDS_FILE:-}"
    return 1
  fi
  debug "  Raw rules: $(wc -c < "$raw_rules_file" | tr -d ' ') chars"

  # ── Inject rules into project ───────────────────────────────────────────────
  local inject_args=(
    --project "$project_path"
    --rules-file "$raw_rules_file"
    --session-count "$compact_ok"
  )
  [[ "$VERBOSE" == true ]] && inject_args+=(--verbose)

  local inject_output
  if inject_output=$("$SCRIPT_DIR/inject-rules.sh" "${inject_args[@]}" 2>&1); then
    echo "  $inject_output"
  else
    echo "  Error: inject-rules.sh failed: $inject_output" >&2
    rm -f "${STATE_PROCESSED_IDS_FILE:-}"
    return 1
  fi

  # ── Count final rules for state ─────────────────────────────────────────────
  local rules_count
  rules_count=$(python3 -c "
import sys, os
f = sys.argv[1]
if os.path.exists(f):
    print(sum(1 for l in open(f) if l.startswith('- ')))
else:
    print(0)
" "$project_path/.claude/rules/learned-rules.md" 2>/dev/null || echo 0)

  # ── Persist state ───────────────────────────────────────────────────────────
  state_mark_processed "$project_path" "$new_ids_file" "${rules_count:-0}"
  debug "  State updated: +$compact_ok sessions, ${rules_count:-0} total rules"

  rm -f "${STATE_PROCESSED_IDS_FILE:-}"
  echo "  ✓ Done ($project_name)"
  return 0
}

# ── Run per-project loop ────────────────────────────────────────────────────
for proj in "${PROJECTS[@]}"; do
  proj="${proj/#\~/$HOME}"

  (process_project "$proj")
  rc=$?

  case "$rc" in
    0) succeeded=$((succeeded + 1)) ;;
    3) skipped=$((skipped + 1)) ;;   # no new sessions
    *) failed=$((failed + 1)) ;;
  esac
done

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════

echo "══════════════════════════════════════════════════"
total="${#PROJECTS[@]}"
if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN complete: $total project(s) analyzed"
else
  echo "Evolution complete: $succeeded succeeded, $skipped skipped (no new sessions), $failed failed / $total projects"
fi

[[ "$failed" -gt 0 ]] && exit 1 || exit 0
