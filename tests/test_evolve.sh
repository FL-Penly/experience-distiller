#!/usr/bin/env bash
# tests/test_evolve.sh — evolve.sh + state.sh + inject-rules.sh tests (no LLM calls)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

PASS=0; FAIL=0

run_test() {
  local name="$1"; shift
  if "$@" > /tmp/test_output 2>&1; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name"; cat /tmp/test_output; FAIL=$((FAIL+1))
  fi
}

assert_equals() {
  [[ "$1" == "$2" ]] || { echo "Expected: '$2', Got: '$1'" >&2; return 1; }
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || { echo "Expected '$1' to contain '$2'" >&2; return 1; }
}

assert_file_exists() {
  [[ -f "$1" ]] || { echo "Expected file to exist: $1" >&2; return 1; }
}

report() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [[ $FAIL -eq 0 ]]
}

TMPDIR_TEST=$(mktemp -d /tmp/test_evolve.XXXXXX)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ══════════════════════════════════════════════════════════════════════════════
# state.sh tests
# ══════════════════════════════════════════════════════════════════════════════

source "$PROJECT_ROOT/scripts/state.sh"

run_test "state_load: nonexistent project → silent defaults" bash -c "
source '$PROJECT_ROOT/scripts/state.sh'
state_load '$TMPDIR_TEST/nonexistent'
[[ -z \"\$STATE_LAST_RUN\" ]] || { echo \"Expected empty STATE_LAST_RUN, got: \$STATE_LAST_RUN\"; exit 1; }
[[ \"\$STATE_TOTAL\" == 0 ]] || { echo \"Expected STATE_TOTAL=0, got: \$STATE_TOTAL\"; exit 1; }
[[ \"\$STATE_RULES_COUNT\" == 0 ]] || { echo \"Expected STATE_RULES_COUNT=0, got: \$STATE_RULES_COUNT\"; exit 1; }
"

STATE_PROJ="$TMPDIR_TEST/state_proj"
mkdir -p "$STATE_PROJ"

run_test "state_save + state_load: round-trip" bash -c "
source '$PROJECT_ROOT/scripts/state.sh'
ids_file=\$(mktemp)
printf 'id-aaa\nid-bbb\n' > \"\$ids_file\"
state_save '$STATE_PROJ' '2026-02-01T00:00:00Z' \"\$ids_file\" 2 5
rm -f \"\$ids_file\"
state_load '$STATE_PROJ'
[[ \"\$STATE_LAST_RUN\" == '2026-02-01T00:00:00Z' ]] || { echo \"STATE_LAST_RUN: \$STATE_LAST_RUN\"; exit 1; }
[[ \"\$STATE_TOTAL\" == 2 ]] || { echo \"STATE_TOTAL: \$STATE_TOTAL\"; exit 1; }
[[ \"\$STATE_RULES_COUNT\" == 5 ]] || { echo \"STATE_RULES_COUNT: \$STATE_RULES_COUNT\"; exit 1; }
ids=\$(cat \"\$STATE_PROCESSED_IDS_FILE\")
[[ \"\$ids\" == *'id-aaa'* ]] || { echo \"Missing id-aaa in: \$ids\"; exit 1; }
[[ \"\$ids\" == *'id-bbb'* ]] || { echo \"Missing id-bbb in: \$ids\"; exit 1; }
"

run_test "state_filter_new: filters already-processed IDs" bash -c "
source '$PROJECT_ROOT/scripts/state.sh'
proj='$TMPDIR_TEST/filter_proj'
mkdir -p \"\$proj\"
ids_file=\$(mktemp)
printf 'old-id-1\nold-id-2\n' > \"\$ids_file\"
state_save \"\$proj\" '2026-01-01T00:00:00Z' \"\$ids_file\" 2 0
rm \"\$ids_file\"
state_load \"\$proj\"

ndjson=\$(mktemp)
printf '{\"session_id\":\"old-id-1\",\"messages\":[]}\n' >> \"\$ndjson\"
printf '{\"session_id\":\"old-id-2\",\"messages\":[]}\n' >> \"\$ndjson\"
printf '{\"session_id\":\"new-id-3\",\"messages\":[]}\n' >> \"\$ndjson\"
printf '{\"session_id\":\"new-id-4\",\"messages\":[]}\n' >> \"\$ndjson\"

filtered=\$(state_filter_new \"\$ndjson\" \"\$proj\" 2>/dev/null)
count=\$(echo \"\$filtered\" | grep -c '.' || echo 0)
[[ \"\$count\" == 2 ]] || { echo \"Expected 2 new, got \$count: \$filtered\"; exit 1; }
[[ \"\$filtered\" != *'old-id-1'* ]] || { echo 'old-id-1 should be filtered'; exit 1; }
[[ \"\$filtered\" == *'new-id-3'* ]] || { echo 'new-id-3 should pass through'; exit 1; }
rm \"\$ndjson\"
"

run_test "state_mark_processed: merges IDs and updates counters" bash -c "
source '$PROJECT_ROOT/scripts/state.sh'
proj='$TMPDIR_TEST/mark_proj'
mkdir -p \"\$proj\"

ids1=\$(mktemp); printf 'id-A\nid-B\n' > \"\$ids1\"
state_save \"\$proj\" '2026-01-01T00:00:00Z' \"\$ids1\" 2 3
rm \"\$ids1\"

ids2=\$(mktemp); printf 'id-C\nid-D\n' > \"\$ids2\"
state_mark_processed \"\$proj\" \"\$ids2\" 7
rm \"\$ids2\"

state_load \"\$proj\"
[[ \"\$STATE_TOTAL\" == 4 ]] || { echo \"Expected STATE_TOTAL=4, got \$STATE_TOTAL\"; exit 1; }
[[ \"\$STATE_RULES_COUNT\" == 7 ]] || { echo \"Expected STATE_RULES_COUNT=7, got \$STATE_RULES_COUNT\"; exit 1; }
ids=\$(cat \"\$STATE_PROCESSED_IDS_FILE\")
for id in id-A id-B id-C id-D; do
  [[ \"\$ids\" == *\"\$id\"* ]] || { echo \"Missing \$id in merged state\"; exit 1; }
done
"

# ══════════════════════════════════════════════════════════════════════════════
# inject-rules.sh tests
# ══════════════════════════════════════════════════════════════════════════════

INJECT_PROJ="$TMPDIR_TEST/inject_proj"
mkdir -p "$INJECT_PROJ"

RULES_FILE1="$TMPDIR_TEST/rules1.md"
cat > "$RULES_FILE1" << 'MDEOF'
## 错误预防规则
- NEVER use fmt.Errorf for external errors — use errno.From() instead (来源: 2个session)
- MUST validate request params before DB query — prevents SQL injection (来源: 1个session)

## 代码规范
- ALWAYS run go vet ./... before committing (来源: 3个session)

## 架构模式
（本次分析无相关规则）

## 工具与工作流
- ALWAYS check .claude/rules/ before starting a task (来源: 1个session)
MDEOF

run_test "inject-rules.sh: first run creates file with correct rules" bash -c "
'$PROJECT_ROOT/scripts/inject-rules.sh' \
  --project '$INJECT_PROJ' \
  --rules-file '$RULES_FILE1' \
  --session-count 3
target='$INJECT_PROJ/.claude/rules/learned-rules.md'
[[ -f \"\$target\" ]] || { echo 'File not created'; exit 1; }
content=\$(cat \"\$target\")
[[ \"\$content\" == *'NEVER use fmt.Errorf'* ]] || { echo 'Missing rule 1'; exit 1; }
[[ \"\$content\" == *'ALWAYS run go vet'* ]] || { echo 'Missing rule 2'; exit 1; }
[[ \"\$content\" == *'session_count: 3'* ]] || { echo 'Missing session_count'; exit 1; }
"

run_test "inject-rules.sh: second run deduplicates existing rules" bash -c "
output=\$('$PROJECT_ROOT/scripts/inject-rules.sh' \
  --project '$INJECT_PROJ' \
  --rules-file '$RULES_FILE1' \
  --session-count 2)
[[ \"\$output\" == *'+0 added'* ]] || { echo \"Expected +0 added, got: \$output\"; exit 1; }
[[ \"\$output\" == *'duplicates skipped'* ]] || { echo \"Expected skipped, got: \$output\"; exit 1; }
content=\$(cat '$INJECT_PROJ/.claude/rules/learned-rules.md')
[[ \"\$content\" == *'session_count: 5'* ]] || { echo 'Expected session_count: 5 (3+2)'; exit 1; }
"

RULES_FILE2="$TMPDIR_TEST/rules2.md"
cat > "$RULES_FILE2" << 'MDEOF'
## 错误预防规则
- NEVER ignore error returns — always handle or propagate (来源: 2个session)

## 代码规范
（本次分析无相关规则）

## 架构模式
（本次分析无相关规则）

## 工具与工作流
（本次分析无相关规则）
MDEOF

run_test "inject-rules.sh: new rule from second file is added" bash -c "
output=\$('$PROJECT_ROOT/scripts/inject-rules.sh' \
  --project '$INJECT_PROJ' \
  --rules-file '$RULES_FILE2' \
  --session-count 1)
[[ \"\$output\" == *'+1 added'* ]] || { echo \"Expected +1 added, got: \$output\"; exit 1; }
content=\$(cat '$INJECT_PROJ/.claude/rules/learned-rules.md')
[[ \"\$content\" == *'NEVER ignore error returns'* ]] || { echo 'New rule not found'; exit 1; }
"

run_test "inject-rules.sh: --dry-run makes no changes" bash -c "
before=\$(cat '$INJECT_PROJ/.claude/rules/learned-rules.md')
'$PROJECT_ROOT/scripts/inject-rules.sh' \
  --project '$INJECT_PROJ' \
  --rules-file '$RULES_FILE1' \
  --session-count 99 \
  --dry-run > /dev/null
after=\$(cat '$INJECT_PROJ/.claude/rules/learned-rules.md')
[[ \"\$before\" == \"\$after\" ]] || { echo 'File changed during dry-run!'; exit 1; }
"

# ══════════════════════════════════════════════════════════════════════════════
# evolve.sh integration tests (dry-run only, no LLM)
# ══════════════════════════════════════════════════════════════════════════════

run_test "evolve.sh: --help exits 0" bash -c "
'$PROJECT_ROOT/scripts/evolve.sh' --help > /dev/null
"

run_test "evolve.sh: missing --project exits with error" bash -c "
'$PROJECT_ROOT/scripts/evolve.sh' 2>/dev/null && exit 1 || exit 0
"

run_test "evolve.sh: nonexistent project dir is skipped (not fatal)" bash -c "
output=\$('$PROJECT_ROOT/scripts/evolve.sh' \
  --project '$TMPDIR_TEST/no_such_dir' \
  --last 1h \
  --dry-run 2>&1)
[[ \"\$output\" == *'skipping'* || \"\$output\" == *'not found'* ]] || { echo \"Unexpected output: \$output\"; exit 1; }
"

run_test "evolve.sh: --from without --to exits with error" bash -c "
'$PROJECT_ROOT/scripts/evolve.sh' \
  --project '$TMPDIR_TEST' \
  --from 2026-01-01 2>/dev/null && exit 1 || exit 0
"

run_test "evolve.sh: --last and --from are mutually exclusive" bash -c "
'$PROJECT_ROOT/scripts/evolve.sh' \
  --project '$TMPDIR_TEST' \
  --last 7d \
  --from 2026-01-01 2>/dev/null && exit 1 || exit 0
"

run_test "evolve.sh: dry-run on empty project skips gracefully" bash -c "
proj=\$(mktemp -d '$TMPDIR_TEST/fake_proj.XXXXXX')
output=\$('$PROJECT_ROOT/scripts/evolve.sh' \
  --project \"\$proj\" \
  --last 24h \
  --dry-run 2>&1)
[[ \"\$output\" == *'DRY RUN'* || \"\$output\" == *'No sessions'* ]] \
  || { echo \"Unexpected: \$output\"; exit 1; }
"

run_test "config.sh: CFG_EVOLUTION vars are exported" bash -c "
source '$PROJECT_ROOT/scripts/config.sh'
[[ -n \"\${CFG_EVOLUTION_DEFAULT_RANGE:-}\" ]] || { echo 'CFG_EVOLUTION_DEFAULT_RANGE not set'; exit 1; }
[[ -n \"\${CFG_EVOLUTION_MAX_RULES:-}\" ]] || { echo 'CFG_EVOLUTION_MAX_RULES not set'; exit 1; }
[[ -n \"\${CFG_EVOLUTION_COMPACT_MAX_CHARS:-}\" ]] || { echo 'CFG_EVOLUTION_COMPACT_MAX_CHARS not set'; exit 1; }
"

run_test "config.sh: existing CFG vars still load after evolution extension" bash -c "
source '$PROJECT_ROOT/scripts/config.sh'
[[ -n \"\${CFG_LLM_MODEL:-}\" ]] || { echo 'CFG_LLM_MODEL missing'; exit 1; }
[[ -n \"\${CFG_CLAUDE_PATH:-}\" ]] || { echo 'CFG_CLAUDE_PATH missing'; exit 1; }
"

run_test "distill.sh: still works after config.sh changes (regression)" bash -c "
output=\$('$PROJECT_ROOT/scripts/distill.sh' --last 1h --dry-run 2>&1 || true)
[[ \"\$output\" != *'Error'* ]] || { echo \"distill.sh errored: \$output\"; exit 1; }
"

report
