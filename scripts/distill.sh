#!/usr/bin/env bash
# scripts/distill.sh — Main CLI entry point for experience-distiller.
# Orchestrates: parse sessions → format → LLM distillation → write output.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ══════════════════════════════════════════════════════════════════════════════
# USAGE
# ══════════════════════════════════════════════════════════════════════════════

show_help() {
  cat << 'HELPEOF'
Usage: distill.sh [OPTIONS]

Distill AI coding sessions into reusable experience documents.

Options:
  --last DURATION     Time window to look back (e.g. 24h, 7d, 1w) [default: from config]
  --from DATE         Start date (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ)
  --to DATE           End date (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ)
  --consolidate       Run consolidation instead of distillation
  --inject TARGET     Inject into: claude, agents, or stdout
  --config PATH       Custom config file path
  --dry-run           Show what would be processed without calling LLM
  --verbose           Print debug info to stderr
  --help              Show this help message

Time Range:
  --from and --to must both be provided together.
  --last and --from/--to are mutually exclusive.
  If neither is given, defaults to config value (usually 24h).

Examples:
  distill.sh                                 # Distill last 24h (default)
  distill.sh --last 7d                       # Distill last 7 days
  distill.sh --from 2025-01-01 --to 2025-01-07
  distill.sh --consolidate                   # Merge daily MDs → CONSOLIDATED.md
  distill.sh --consolidate --inject claude   # Consolidate then inject
  distill.sh --inject stdout                 # Output existing CONSOLIDATED.md
HELPEOF
}

# ══════════════════════════════════════════════════════════════════════════════
# PARSE CLI ARGS
# ══════════════════════════════════════════════════════════════════════════════

LAST_DURATION=""
FROM_DATE=""
TO_DATE=""
DO_CONSOLIDATE=false
INJECT_TARGET=""
CUSTOM_CONFIG=""
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --last)
      [[ $# -lt 2 ]] && { echo "Error: --last requires a DURATION argument" >&2; exit 1; }
      LAST_DURATION="$2"; shift 2 ;;
    --from)
      [[ $# -lt 2 ]] && { echo "Error: --from requires a DATE argument" >&2; exit 1; }
      FROM_DATE="$2"; shift 2 ;;
    --to)
      [[ $# -lt 2 ]] && { echo "Error: --to requires a DATE argument" >&2; exit 1; }
      TO_DATE="$2"; shift 2 ;;
    --consolidate)
      DO_CONSOLIDATE=true; shift ;;
    --inject)
      [[ $# -lt 2 ]] && { echo "Error: --inject requires TARGET (claude|agents|stdout)" >&2; exit 1; }
      INJECT_TARGET="$2"; shift 2 ;;
    --config)
      [[ $# -lt 2 ]] && { echo "Error: --config requires a PATH argument" >&2; exit 1; }
      CUSTOM_CONFIG="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    --verbose)
      VERBOSE=true; shift ;;
    --help|-h)
      show_help; exit 0 ;;
    *)
      echo "Error: Unknown option '$1'" >&2
      echo "Run 'distill.sh --help' for usage." >&2
      exit 1 ;;
  esac
done

# ══════════════════════════════════════════════════════════════════════════════
# SOURCE CONFIG
# ══════════════════════════════════════════════════════════════════════════════

if [[ -n "$CUSTOM_CONFIG" ]]; then
  if [[ ! -f "$CUSTOM_CONFIG" ]]; then
    echo "Error: Config file not found: $CUSTOM_CONFIG" >&2
    exit 1
  fi
  source "$CUSTOM_CONFIG"
else
  source "$SCRIPT_DIR/config.sh"
fi

# ══════════════════════════════════════════════════════════════════════════════
# VALIDATE
# ══════════════════════════════════════════════════════════════════════════════

# --from and --to must be provided together
if [[ -n "$FROM_DATE" && -z "$TO_DATE" ]] || [[ -z "$FROM_DATE" && -n "$TO_DATE" ]]; then
  echo "Error: --from and --to must be provided together" >&2
  exit 1
fi

# --last and --from/--to are mutually exclusive
if [[ -n "$LAST_DURATION" && -n "$FROM_DATE" ]]; then
  echo "Error: --last and --from/--to are mutually exclusive" >&2
  exit 1
fi

# Validate --inject target
if [[ -n "$INJECT_TARGET" ]]; then
  case "$INJECT_TARGET" in
    claude|agents|stdout) ;;
    *) echo "Error: --inject target must be one of: claude, agents, stdout" >&2; exit 1 ;;
  esac
fi

# ══════════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════

debug() {
  [[ "$VERBOSE" == true ]] && echo "[debug] $*" >&2
  return 0
}

# Convert --last DURATION to FROM_DATE / TO_DATE (sets globals).
compute_time_range() {
  local duration="$1"
  local unit="${duration: -1}"
  local num="${duration%[hdw]}"

  if ! [[ "$num" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid duration '$duration'. Use format: 24h, 7d, 2w" >&2
    return 1
  fi

  local seconds=0
  case "$unit" in
    h) seconds=$((num * 3600)) ;;
    d) seconds=$((num * 86400)) ;;
    w) seconds=$((num * 7 * 86400)) ;;
    *) echo "Error: Invalid duration unit in '$duration'. Use h/d/w." >&2; return 1 ;;
  esac

  local now_epoch
  now_epoch=$(date +%s)
  TO_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Linux: date -d "@epoch"; macOS: date -r epoch
  FROM_DATE=$(date -u -d "@$((now_epoch - seconds))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
              date -u -r "$((now_epoch - seconds))" +%Y-%m-%dT%H:%M:%SZ)
  debug "Computed range: $FROM_DATE → $TO_DATE (from '$duration')"
}

# Run parsers in parallel, combine NDJSON output into output_file.
run_parsers() {
  local from="$1" to="$2" output_file="$3"
  local opencode_out="$DISTILL_TMPDIR/opencode.ndjson"
  local claude_out="$DISTILL_TMPDIR/claude.ndjson"
  local opencode_pid="" claude_pid=""

  touch "$opencode_out" "$claude_out"

  # OpenCode parser
  if [[ -d "${CFG_OPENCODE_PATH:-}" ]]; then
    if [[ ! -f "$SCRIPT_DIR/parse_opencode.py" ]]; then
      echo "Error: parse_opencode.py not found in $SCRIPT_DIR" >&2
      return 1
    fi
    debug "Parsing OpenCode sessions from $CFG_OPENCODE_PATH"
    local -a oc_args=(--sessions-dir "$CFG_OPENCODE_PATH" --from "$from" --to "$to")
    [[ "$VERBOSE" == true ]] && oc_args+=(--verbose)
    python3 "$SCRIPT_DIR/parse_opencode.py" "${oc_args[@]}" > "$opencode_out" &
    opencode_pid=$!
  else
    debug "Skipping OpenCode (dir not found: ${CFG_OPENCODE_PATH:-<unset>})"
  fi

  # Claude Code parser
  if [[ -d "${CFG_CLAUDE_PATH:-}" ]]; then
    if [[ ! -f "$SCRIPT_DIR/parse_claude.py" ]]; then
      echo "Error: parse_claude.py not found in $SCRIPT_DIR" >&2
      return 1
    fi
    debug "Parsing Claude Code sessions from $CFG_CLAUDE_PATH"
    local -a cc_args=(--claude-dir "$CFG_CLAUDE_PATH" --from "$from" --to "$to")
    [[ "$VERBOSE" == true ]] && cc_args+=(--verbose)
    python3 "$SCRIPT_DIR/parse_claude.py" "${cc_args[@]}" > "$claude_out" &
    claude_pid=$!
  else
    debug "Skipping Claude Code (dir not found: ${CFG_CLAUDE_PATH:-<unset>})"
  fi

  # Wait for both parsers
  if [[ -n "$opencode_pid" ]]; then
    wait "$opencode_pid" || echo "Warning: OpenCode parser exited with error" >&2
  fi
  if [[ -n "$claude_pid" ]]; then
    wait "$claude_pid" || echo "Warning: Claude Code parser exited with error" >&2
  fi

  # Combine results
  cat "$opencode_out" "$claude_out" > "$output_file" 2>/dev/null
  local line_count
  line_count=$(grep -c '[^[:space:]]' "$output_file" 2>/dev/null || echo 0)
  debug "Parsers produced $line_count NDJSON lines"
}

# Format NDJSON sessions into readable text for LLM prompt.
# Outputs formatted text to stdout.
# Writes __SESSION_COUNT__=N marker to stderr.
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
            print("Warning: skipping malformed JSON line", file=sys.stderr)
            continue
        count += 1
        title = session.get('title') or session.get('session_id', 'Unknown')
        time_start = session.get('time_start', '')
        time_end = session.get('time_end', '')
        project = session.get('project', '')

        print(f"=== 会话 {count}: {title} ===")
        print(f"时间: {time_start} → {time_end}")
        if project:
            print(f"项目: {project}")
        print()

        for msg in session.get('messages', []):
            role = '用户' if msg.get('role') == 'user' else 'AI助手'
            content = (msg.get('content') or '').strip()
            if content:
                print(f"[{role}]")
                if len(content) > 3000:
                    print(content[:3000])
                    print(f"... (truncated, {len(content)} chars total)")
                else:
                    print(content)

            for tc in msg.get('tool_calls', []):
                tool = tc.get('tool', '?')
                inp = str(tc.get('input', ''))[:200]
                out = str(tc.get('output', ''))[:200]
                parts = [f"  [Tool: {tool}]"]
                if inp:
                    parts.append(f"  input: {inp}")
                if out:
                    parts.append(f"  output: {out}")
                print('\n'.join(parts))
            print()
        print()

print(f"__SESSION_COUNT__={count}", file=sys.stderr)
PYEOF
}

# Load prompt template and substitute {{TRANSCRIPT}}.
build_prompt() {
  local transcript_file="$1"
  local template_file="$PROJECT_ROOT/prompts/distill.md"

  if [[ ! -f "$template_file" ]]; then
    echo "Error: Prompt template not found: $template_file" >&2
    return 1
  fi

  python3 - "$template_file" "$transcript_file" << 'PYEOF'
import sys

with open(sys.argv[1]) as f:
    template = f.read()
with open(sys.argv[2]) as f:
    transcript = f.read()

print(template.replace('{{TRANSCRIPT}}', transcript))
PYEOF
}

build_compact_prompt() {
  local session_text_file="$1"
  local template_file="$PROJECT_ROOT/prompts/compact.md"

  if [[ ! -f "$template_file" ]]; then
    echo "Error: Compact prompt template not found: $template_file" >&2
    return 1
  fi

  python3 - "$template_file" "$session_text_file" << 'PYEOF'
import sys

with open(sys.argv[1]) as f:
    template = f.read()
with open(sys.argv[2]) as f:
    session_text = f.read()

print(template.replace('{{SESSION}}', session_text))
PYEOF
}

# Write LLM response to dated output file with YAML frontmatter.
# Prints the output file path to stdout.
write_output() {
  local llm_response_file="$1"
  local session_count="$2"
  local from_date="$3"
  local to_date="$4"

  local today
  today=$(date +%Y-%m-%d)

  local outdir="${CFG_OUTPUT_DIR:-experiences}"
  [[ "$outdir" != /* ]] && outdir="$PROJECT_ROOT/$outdir"
  mkdir -p "$outdir"

  local output_file="$outdir/$today.md"

  {
    printf '%s\n' "---"
    printf 'date: %s\n' "$today"
    printf 'sessions: %s\n' "$session_count"
    printf 'range_from: %s\n' "$from_date"
    printf 'range_to: %s\n' "$to_date"
    printf '%s\n' "---"
    printf '\n'
    cat "$llm_response_file"
  } > "$output_file"

  echo "$output_file"
}

# ══════════════════════════════════════════════════════════════════════════════
# SETUP
# ══════════════════════════════════════════════════════════════════════════════

debug "SCRIPT_DIR=$SCRIPT_DIR"
debug "PROJECT_ROOT=$PROJECT_ROOT"
debug "CFG_OPENCODE_PATH=${CFG_OPENCODE_PATH:-<unset>}"
debug "CFG_CLAUDE_PATH=${CFG_CLAUDE_PATH:-<unset>}"
debug "CFG_OUTPUT_DIR=${CFG_OUTPUT_DIR:-<unset>}"
debug "CFG_DEFAULT_RANGE=${CFG_DEFAULT_RANGE:-<unset>}"

# ── Lockfile (flock on Linux; skipped if flock unavailable e.g. macOS) ────────
LOCKFILE="/tmp/experience-distiller.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    echo "Error: Another instance is running (lockfile: $LOCKFILE)" >&2
    exit 1
  fi
  debug "Acquired lock: $LOCKFILE"
fi

# ── Tmpdir + cleanup trap ────────────────────────────────────────────────────
DISTILL_TMPDIR=$(mktemp -d /tmp/experience-distiller.XXXXXX)
trap 'rm -rf "$DISTILL_TMPDIR"' EXIT
debug "TMPDIR=$DISTILL_TMPDIR"

# ══════════════════════════════════════════════════════════════════════════════
# MAIN FLOW
# ══════════════════════════════════════════════════════════════════════════════

HAS_EXPLICIT_RANGE=false
[[ -n "$LAST_DURATION" || -n "$FROM_DATE" ]] && HAS_EXPLICIT_RANGE=true

# ── Mode 1: --inject only (no consolidation, no time range) ──────────────────
if [[ -n "$INJECT_TARGET" && "$DO_CONSOLIDATE" == false && "$HAS_EXPLICIT_RANGE" == false ]]; then
  debug "Mode: inject-only → $INJECT_TARGET"
  "$SCRIPT_DIR/inject.sh" --target "$INJECT_TARGET"
  exit $?
fi

# ── Mode 2: --consolidate without time range (consolidation only) ────────────
if [[ "$DO_CONSOLIDATE" == true && "$HAS_EXPLICIT_RANGE" == false ]]; then
  debug "Mode: consolidate-only"
  consolidate_flags=""
  [[ "$DRY_RUN" == true ]] && consolidate_flags="$consolidate_flags --dry-run"
  [[ "$VERBOSE" == true ]] && consolidate_flags="$consolidate_flags --verbose"
  # shellcheck disable=SC2086
  "$SCRIPT_DIR/consolidate.sh" $consolidate_flags
  consolidate_rc=$?
  if [[ $consolidate_rc -ne 0 ]]; then
    echo "Error: Consolidation failed (exit $consolidate_rc)" >&2
    exit $consolidate_rc
  fi
  # Optionally inject after consolidation
  if [[ -n "$INJECT_TARGET" ]]; then
    "$SCRIPT_DIR/inject.sh" --target "$INJECT_TARGET"
    exit $?
  fi
  exit 0
fi

# ── Mode 3: Distillation (default path) ──────────────────────────────────────
debug "Mode: distillation"

# Step 1: Compute time range
if [[ -n "$LAST_DURATION" ]]; then
  compute_time_range "$LAST_DURATION" || exit 1
elif [[ -n "$FROM_DATE" ]]; then
  : # Already set from CLI args
else
  # Use default range from config
  debug "Using default range: ${CFG_DEFAULT_RANGE:-24h}"
  compute_time_range "${CFG_DEFAULT_RANGE:-24h}" || exit 1
fi
debug "Time range: $FROM_DATE → $TO_DATE"

# Step 2: Run parsers → NDJSON
ndjson_file="$DISTILL_TMPDIR/sessions.ndjson"
run_parsers "$FROM_DATE" "$TO_DATE" "$ndjson_file"

# Step 3: Check session count (early exit if none)
session_count=0
if [[ -f "$ndjson_file" && -s "$ndjson_file" ]]; then
  session_count=$(grep -c '[^[:space:]]' "$ndjson_file" 2>/dev/null || echo 0)
fi
if [[ "$session_count" -eq 0 ]]; then
  echo "No sessions found for $FROM_DATE → $TO_DATE"
  exit 0
fi
debug "Found $session_count session line(s) in NDJSON"

# Step 4: Dry-run → print summary and exit (before any LLM calls)
if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: Would process $session_count session(s)"
  echo "Time range: $FROM_DATE → $TO_DATE"
  echo "Pipeline: compact each session individually → 1 final distillation call"
  echo "Total LLM calls: $((session_count + 1))"
  echo ""
  echo "Sessions:"
  python3 - "$ndjson_file" << 'PYEOF'
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
            t1 = s.get('time_end', '?')
            msgs = len(s.get('messages', []))
            print(f"  {i}. {title}  ({t0} → {t1}, {msgs} messages)")
        except json.JSONDecodeError:
            print(f"  {i}. (malformed JSON)")
PYEOF
  exit 0
fi

# Step 5: Compact each session individually → summaries file
summaries_file="$DISTILL_TMPDIR/summaries.txt"
touch "$summaries_file"
compact_ok=0
compact_fail=0
max_session_chars=30000
session_idx=0

while IFS= read -r session_line; do
  [[ -z "${session_line// }" ]] && continue
  session_idx=$((session_idx + 1))

  session_meta=$(printf '%s' "$session_line" | python3 -c "import sys, json
s = json.loads(sys.stdin.read())
title = s.get('title') or s.get('session_id', 'Unknown')
t0 = s.get('time_start', '?')
print(title + '  (' + t0 + ')')
" 2>/dev/null || echo "Unknown")

  echo "[$session_idx/$session_count] $session_meta" >&2

  single_ndjson="$DISTILL_TMPDIR/s${session_idx}.ndjson"
  printf '%s\n' "$session_line" > "$single_ndjson"

  session_text="$DISTILL_TMPDIR/s${session_idx}.txt"
  format_sessions_to_text "$single_ndjson" > "$session_text" 2>/dev/null

  text_size=$(wc -c < "$session_text" | tr -d ' ')
  if [[ "$text_size" -gt "$max_session_chars" ]]; then
    head -c "$max_session_chars" "$session_text" > "$DISTILL_TMPDIR/s${session_idx}_t.txt"
    mv "$DISTILL_TMPDIR/s${session_idx}_t.txt" "$session_text"
    debug "  session truncated from $text_size to $max_session_chars chars"
  fi

  compact_prompt_file="$DISTILL_TMPDIR/cp${session_idx}.txt"
  if ! build_compact_prompt "$session_text" > "$compact_prompt_file"; then
    echo "  Warning: could not build compact prompt for session $session_idx, skipping" >&2
    compact_fail=$((compact_fail + 1))
    continue
  fi

  session_summary="$DISTILL_TMPDIR/sum${session_idx}.txt"
  if "$SCRIPT_DIR/llm_call.sh" < "$compact_prompt_file" > "$session_summary" 2>/dev/null; then
    {
      printf '=== 会话 %d: %s ===\n' "$session_idx" "$session_meta"
      cat "$session_summary"
      printf '\n'
    } >> "$summaries_file"
    compact_ok=$((compact_ok + 1))
    debug "  → $(wc -c < "$session_summary" | tr -d ' ') chars"
  else
    echo "  Warning: compact failed for session $session_idx, skipping" >&2
    compact_fail=$((compact_fail + 1))
  fi
done < "$ndjson_file"

if [[ "$compact_ok" -eq 0 ]]; then
  echo "Error: All $session_count session compactions failed" >&2
  exit 1
fi
echo "Compacted $compact_ok/$session_count sessions" >&2

# Step 6: Build distill prompt from summaries
prompt_file="$DISTILL_TMPDIR/prompt.txt"
build_prompt "$summaries_file" > "$prompt_file" || { echo "Error: Failed to build distill prompt" >&2; exit 1; }
prompt_chars=$(wc -c < "$prompt_file" | tr -d ' ')
debug "Distill prompt: $prompt_chars chars"

# Step 7: Final LLM distillation
debug "Running final distillation (${LLM_PROVIDER:-gcp}/${LLM_MODEL:-unknown})..."
llm_response="$DISTILL_TMPDIR/llm_response.md"
if ! "$SCRIPT_DIR/llm_call.sh" < "$prompt_file" > "$llm_response"; then
  echo "Error: Final distillation failed" >&2
  exit 1
fi
if [[ ! -s "$llm_response" ]]; then
  echo "Error: LLM returned empty response" >&2
  exit 1
fi
debug "LLM response: $(wc -c < "$llm_response" | tr -d ' ') chars"

# Step 8: Write output file
output_path=$(write_output "$llm_response" "$compact_ok" "$FROM_DATE" "$TO_DATE")
echo "✓ Wrote $output_path ($compact_ok session(s) distilled)"

# Step 10: Post-distillation consolidation (optional)
if [[ "$DO_CONSOLIDATE" == true ]]; then
  debug "Running post-distillation consolidation"
  consolidate_flags=""
  [[ "$VERBOSE" == true ]] && consolidate_flags="--verbose"
  # shellcheck disable=SC2086
  "$SCRIPT_DIR/consolidate.sh" $consolidate_flags || {
    echo "Warning: Post-distillation consolidation failed" >&2
  }
fi

# Step 11: Post-distillation injection (optional)
if [[ -n "$INJECT_TARGET" ]]; then
  debug "Injecting into $INJECT_TARGET"
  "$SCRIPT_DIR/inject.sh" --target "$INJECT_TARGET" || {
    echo "Warning: Injection into $INJECT_TARGET failed" >&2
  }
fi

debug "Done"
