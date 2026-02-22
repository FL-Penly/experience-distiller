#!/usr/bin/env bash
# tests/test_integration.sh — full pipeline integration tests (no real LLM calls)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SCRIPTS="$PROJECT_ROOT/scripts"
FIXTURES="$SCRIPT_DIR/fixtures"

# ── Inline test framework ────────────────────────────────────────────────────
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
  [[ "$1" == *"$2"* ]] || { echo "Expected output to contain '$2'" >&2; return 1; }
}

assert_not_contains() {
  [[ "$1" != *"$2"* ]] || { echo "Expected output to NOT contain '$2'" >&2; return 1; }
}

assert_file_exists() {
  [[ -f "$1" ]] || { echo "File not found: $1" >&2; return 1; }
}

report() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [[ $FAIL -eq 0 ]]
}

# ── consolidate.sh tests ─────────────────────────────────────────────────────

test_consolidate_no_files() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  output=$(bash "$SCRIPTS/consolidate.sh" --output-dir "$tmpdir" 2>&1)
  assert_contains "$output" "No experience files"
}

test_consolidate_dry_run() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  cp "$FIXTURES/daily-mds/"*.md "$tmpdir/"
  output=$(bash "$SCRIPTS/consolidate.sh" --output-dir "$tmpdir" --dry-run 2>&1)
  assert_contains "$output" "DRY RUN"
}

test_consolidate_dry_run_shows_file_count() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  cp "$FIXTURES/daily-mds/"*.md "$tmpdir/"
  output=$(bash "$SCRIPTS/consolidate.sh" --output-dir "$tmpdir" --dry-run 2>&1)
  assert_contains "$output" "3"
}

test_consolidate_unknown_option_fails() {
  local exit_code=0
  bash "$SCRIPTS/consolidate.sh" --invalid-flag 2>/dev/null || exit_code=$?
  [[ $exit_code -ne 0 ]] || { echo "Expected non-zero exit for unknown option" >&2; return 1; }
}

# ── inject.sh tests ──────────────────────────────────────────────────────────

test_inject_stdout() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  cp "$FIXTURES/daily-mds/2026-02-20.md" "$tmpdir/CONSOLIDATED.md"
  output=$(bash "$SCRIPTS/inject.sh" --target stdout --file "$tmpdir/CONSOLIDATED.md" 2>&1)
  assert_contains "$output" "调研成果"
}

test_inject_stdout_contains_full_content() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  cp "$FIXTURES/daily-mds/2026-02-20.md" "$tmpdir/CONSOLIDATED.md"
  output=$(bash "$SCRIPTS/inject.sh" --target stdout --file "$tmpdir/CONSOLIDATED.md" 2>&1)
  assert_contains "$output" "踩坑记录"
  assert_contains "$output" "工具技巧"
}

test_inject_claude_creates_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  cp "$FIXTURES/daily-mds/2026-02-20.md" "$tmpdir/CONSOLIDATED.md"
  bash "$SCRIPTS/inject.sh" --target claude --file "$tmpdir/CONSOLIDATED.md" --project-root "$tmpdir" 2>/dev/null
  assert_file_exists "$tmpdir/CLAUDE.md"
}

test_inject_agents_creates_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  cp "$FIXTURES/daily-mds/2026-02-20.md" "$tmpdir/CONSOLIDATED.md"
  bash "$SCRIPTS/inject.sh" --target agents --file "$tmpdir/CONSOLIDATED.md" --project-root "$tmpdir" 2>/dev/null
  assert_file_exists "$tmpdir/AGENTS.md"
}

test_inject_claude_has_header() {
  local tmpdir content
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  cp "$FIXTURES/daily-mds/2026-02-20.md" "$tmpdir/CONSOLIDATED.md"
  bash "$SCRIPTS/inject.sh" --target claude --file "$tmpdir/CONSOLIDATED.md" --project-root "$tmpdir" 2>/dev/null
  content=$(cat "$tmpdir/CLAUDE.md")
  assert_contains "$content" "Project Instructions"
}

test_inject_claude_has_experiences_section() {
  local tmpdir content
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  cp "$FIXTURES/daily-mds/2026-02-20.md" "$tmpdir/CONSOLIDATED.md"
  bash "$SCRIPTS/inject.sh" --target claude --file "$tmpdir/CONSOLIDATED.md" --project-root "$tmpdir" 2>/dev/null
  content=$(cat "$tmpdir/CLAUDE.md")
  assert_contains "$content" "Distilled Experiences"
}

test_inject_idempotency() {
  local tmpdir count
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  cp "$FIXTURES/daily-mds/2026-02-20.md" "$tmpdir/CONSOLIDATED.md"
  bash "$SCRIPTS/inject.sh" --target claude --file "$tmpdir/CONSOLIDATED.md" --project-root "$tmpdir" 2>/dev/null
  bash "$SCRIPTS/inject.sh" --target claude --file "$tmpdir/CONSOLIDATED.md" --project-root "$tmpdir" 2>/dev/null
  count=$(grep -c "Distilled Experiences" "$tmpdir/CLAUDE.md")
  assert_equals "$count" "1"
}

test_inject_idempotency_message() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  cp "$FIXTURES/daily-mds/2026-02-20.md" "$tmpdir/CONSOLIDATED.md"
  bash "$SCRIPTS/inject.sh" --target claude --file "$tmpdir/CONSOLIDATED.md" --project-root "$tmpdir" 2>/dev/null
  output=$(bash "$SCRIPTS/inject.sh" --target claude --file "$tmpdir/CONSOLIDATED.md" --project-root "$tmpdir" 2>&1)
  assert_contains "$output" "Already injected"
}

test_inject_appends_to_existing_file() {
  local tmpdir content
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  printf '# My Project\n\nSome existing content.\n' > "$tmpdir/CLAUDE.md"
  cp "$FIXTURES/daily-mds/2026-02-20.md" "$tmpdir/CONSOLIDATED.md"
  bash "$SCRIPTS/inject.sh" --target claude --file "$tmpdir/CONSOLIDATED.md" --project-root "$tmpdir" 2>/dev/null
  content=$(cat "$tmpdir/CLAUDE.md")
  assert_contains "$content" "My Project"
  assert_contains "$content" "Distilled Experiences"
}

# ── parse_opencode.py tests ──────────────────────────────────────────────────

test_opencode_parser_produces_json() {
  local output
  output=$(python3 "$SCRIPTS/parse_opencode.py" \
    --sessions-dir "$FIXTURES/opencode" \
    --from 2025-02-20 --to 2025-02-21 2>/dev/null)
  if [[ -n "$output" ]]; then
    echo "$output" | python3 -c "import sys,json; [json.loads(l) for l in sys.stdin if l.strip()]"
  fi
}

test_opencode_parser_has_source_field() {
  local output
  output=$(python3 "$SCRIPTS/parse_opencode.py" \
    --sessions-dir "$FIXTURES/opencode" \
    --from 2025-02-20 --to 2025-02-21 2>/dev/null)
  if [[ -n "$output" ]]; then
    echo "$output" | python3 -c "
import sys, json
for l in sys.stdin:
    l = l.strip()
    if l:
        obj = json.loads(l)
        assert obj['source'] == 'opencode', f'Expected opencode, got {obj[\"source\"]}'
"
  fi
}

test_opencode_parser_exit_zero() {
  local exit_code=0
  python3 "$SCRIPTS/parse_opencode.py" \
    --sessions-dir "$FIXTURES/opencode" \
    --from 2025-02-20 --to 2025-02-21 2>/dev/null || exit_code=$?
  assert_equals "$exit_code" "0"
}

# ── parse_claude.py tests ────────────────────────────────────────────────────

test_claude_parser_produces_json() {
  local output
  output=$(python3 "$SCRIPTS/parse_claude.py" \
    --claude-dir "$FIXTURES/claude-code" \
    --from 2026-02-20 --to 2026-02-21 2>/dev/null) || true
  if [[ -n "$output" ]]; then
    echo "$output" | python3 -c "import sys,json; [json.loads(l) for l in sys.stdin if l.strip()]"
  fi
}

test_claude_parser_has_source_field() {
  local output
  output=$(python3 "$SCRIPTS/parse_claude.py" \
    --claude-dir "$FIXTURES/claude-code" \
    --from 2026-02-20 --to 2026-02-21 2>/dev/null) || true
  if [[ -n "$output" ]]; then
    echo "$output" | python3 -c "
import sys, json
for l in sys.stdin:
    l = l.strip()
    if l:
        obj = json.loads(l)
        assert obj['source'] == 'claude-code', f'Expected claude-code, got {obj[\"source\"]}'
"
  fi
}

test_claude_parser_skips_sidechain() {
  local output
  output=$(python3 "$SCRIPTS/parse_claude.py" \
    --claude-dir "$FIXTURES/claude-code" \
    --from 2026-02-20 --to 2026-02-21 2>/dev/null) || true
  if [[ -n "$output" ]]; then
    # Session 22222222 is marked isSidechain=true, should not appear
    if echo "$output" | grep -q "22222222"; then
      echo "Sidechain session should be filtered out" >&2
      return 1
    fi
  fi
}

test_claude_parser_filters_by_date() {
  local output
  output=$(python3 "$SCRIPTS/parse_claude.py" \
    --claude-dir "$FIXTURES/claude-code" \
    --from 2026-02-20 --to 2026-02-21 2>/dev/null) || true
  # Session 33333333 has dates in 2026-01-01, should be filtered out
  if [[ -n "$output" ]] && echo "$output" | grep -q "33333333"; then
    echo "Out-of-range session should be filtered out" >&2
    return 1
  fi
}

test_claude_parser_exit_zero() {
  local exit_code=0
  python3 "$SCRIPTS/parse_claude.py" \
    --claude-dir "$FIXTURES/claude-code" \
    --from 2026-02-20 --to 2026-02-21 2>/dev/null || exit_code=$?
  assert_equals "$exit_code" "0"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "=== test_integration.sh ==="

run_test "consolidate_no_files"               test_consolidate_no_files
run_test "consolidate_dry_run"                test_consolidate_dry_run
run_test "consolidate_dry_run_shows_count"    test_consolidate_dry_run_shows_file_count
run_test "consolidate_unknown_option_fails"   test_consolidate_unknown_option_fails
run_test "inject_stdout"                      test_inject_stdout
run_test "inject_stdout_contains_full"        test_inject_stdout_contains_full_content
run_test "inject_claude_creates_file"         test_inject_claude_creates_file
run_test "inject_agents_creates_file"         test_inject_agents_creates_file
run_test "inject_claude_has_header"           test_inject_claude_has_header
run_test "inject_claude_has_experiences"      test_inject_claude_has_experiences_section
run_test "inject_idempotency"                 test_inject_idempotency
run_test "inject_idempotency_message"         test_inject_idempotency_message
run_test "inject_appends_to_existing"         test_inject_appends_to_existing_file
run_test "opencode_parser_produces_json"      test_opencode_parser_produces_json
run_test "opencode_parser_has_source_field"   test_opencode_parser_has_source_field
run_test "opencode_parser_exit_zero"          test_opencode_parser_exit_zero
run_test "claude_parser_produces_json"        test_claude_parser_produces_json
run_test "claude_parser_has_source_field"     test_claude_parser_has_source_field
run_test "claude_parser_skips_sidechain"      test_claude_parser_skips_sidechain
run_test "claude_parser_filters_by_date"      test_claude_parser_filters_by_date
run_test "claude_parser_exit_zero"            test_claude_parser_exit_zero

report; exit $?
