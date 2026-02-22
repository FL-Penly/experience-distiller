#!/usr/bin/env bash
# tests/test_edge_cases.sh — edge case and boundary condition tests
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

assert_file_exists() {
  [[ -f "$1" ]] || { echo "File not found: $1" >&2; return 1; }
}

report() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [[ $FAIL -eq 0 ]]
}

# ── parse_opencode.py edge cases ─────────────────────────────────────────────

test_opencode_missing_dir() {
  local exit_code=0
  python3 "$SCRIPTS/parse_opencode.py" \
    --sessions-dir /nonexistent/xyz_does_not_exist \
    --from 2026-01-01 --to 2026-12-31 2>/dev/null || exit_code=$?
  assert_equals "$exit_code" "0"
}

test_opencode_no_sessions_in_range() {
  # Use a date range that has no sessions (far future)
  local output exit_code=0
  output=$(python3 "$SCRIPTS/parse_opencode.py" \
    --sessions-dir "$FIXTURES/opencode" \
    --from 2099-01-01 --to 2099-12-31 2>/dev/null) || exit_code=$?
  assert_equals "$exit_code" "0"
  # stdout should be empty (no sessions matched)
  [[ -z "$output" ]] || { echo "Expected empty stdout for no-match range, got: $output" >&2; return 1; }
}

test_opencode_requires_both_dates() {
  local exit_code=0
  python3 "$SCRIPTS/parse_opencode.py" \
    --sessions-dir "$FIXTURES/opencode" \
    --from 2026-01-01 2>/dev/null || exit_code=$?
  [[ $exit_code -ne 0 ]] || { echo "Expected failure when --to is missing" >&2; return 1; }
}

test_opencode_empty_sessions_dir() {
  local tmpdir exit_code=0
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  python3 "$SCRIPTS/parse_opencode.py" \
    --sessions-dir "$tmpdir" \
    --from 2026-01-01 --to 2026-12-31 2>/dev/null || exit_code=$?
  assert_equals "$exit_code" "0"
}

# ── parse_claude.py edge cases ───────────────────────────────────────────────

test_claude_missing_dir() {
  local exit_code=0
  python3 "$SCRIPTS/parse_claude.py" \
    --claude-dir /nonexistent/xyz_does_not_exist \
    --from 2026-01-01 --to 2026-12-31 2>/dev/null || exit_code=$?
  assert_equals "$exit_code" "0"
}

test_claude_no_sessions_in_range() {
  local output exit_code=0
  output=$(python3 "$SCRIPTS/parse_claude.py" \
    --claude-dir "$FIXTURES/claude-code" \
    --from 2099-01-01 --to 2099-12-31 2>/dev/null) || exit_code=$?
  assert_equals "$exit_code" "0"
  [[ -z "$output" ]] || { echo "Expected empty stdout for no-match range, got: $output" >&2; return 1; }
}

test_claude_requires_both_dates() {
  local exit_code=0
  python3 "$SCRIPTS/parse_claude.py" \
    --claude-dir "$FIXTURES/claude-code" \
    --from 2026-01-01 2>/dev/null || exit_code=$?
  [[ $exit_code -ne 0 ]] || { echo "Expected failure when --to is missing" >&2; return 1; }
}

test_claude_empty_dir() {
  local tmpdir exit_code=0
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  python3 "$SCRIPTS/parse_claude.py" \
    --claude-dir "$tmpdir" \
    --from 2026-01-01 --to 2026-12-31 2>/dev/null || exit_code=$?
  assert_equals "$exit_code" "0"
}

test_claude_corrupt_jsonl_handled() {
  # The fixture session-corrupt.jsonl should not crash the parser
  local exit_code=0
  python3 "$SCRIPTS/parse_claude.py" \
    --claude-dir "$FIXTURES/claude-code" \
    --from 2026-01-01 --to 2026-12-31 2>/dev/null || exit_code=$?
  assert_equals "$exit_code" "0"
}

# ── inject.sh edge cases ─────────────────────────────────────────────────────

test_inject_missing_source_file() {
  local exit_code=0
  bash "$SCRIPTS/inject.sh" --target stdout --file /nonexistent/file.md 2>/dev/null || exit_code=$?
  [[ $exit_code -ne 0 ]] || { echo "Expected non-zero exit for missing source file" >&2; return 1; }
}

test_inject_missing_source_file_error_message() {
  local result
  result=$(bash "$SCRIPTS/inject.sh" --target stdout --file /nonexistent/file.md 2>&1) || true
  assert_contains "$result" "not found"
}

test_inject_invalid_target() {
  local tmpdir exit_code=0
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  printf 'test content\n' > "$tmpdir/test.md"
  bash "$SCRIPTS/inject.sh" --target invalid_target --file "$tmpdir/test.md" 2>/dev/null || exit_code=$?
  [[ $exit_code -ne 0 ]] || { echo "Expected non-zero exit for invalid target" >&2; return 1; }
}

test_inject_invalid_target_error_message() {
  local tmpdir result
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  printf 'test content\n' > "$tmpdir/test.md"
  result=$(bash "$SCRIPTS/inject.sh" --target invalid_target --file "$tmpdir/test.md" 2>&1) || true
  assert_contains "$result" "must be one of"
}

test_inject_missing_target_flag() {
  local exit_code=0
  bash "$SCRIPTS/inject.sh" --file /tmp/any.md 2>/dev/null || exit_code=$?
  [[ $exit_code -ne 0 ]] || { echo "Expected non-zero exit when --target is missing" >&2; return 1; }
}

test_inject_unknown_option() {
  local exit_code=0
  bash "$SCRIPTS/inject.sh" --unknown-flag 2>/dev/null || exit_code=$?
  [[ $exit_code -ne 0 ]] || { echo "Expected non-zero exit for unknown option" >&2; return 1; }
}

# ── consolidate.sh edge cases ────────────────────────────────────────────────

test_consolidate_empty_dir_exits_zero() {
  local tmpdir exit_code=0
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  bash "$SCRIPTS/consolidate.sh" --output-dir "$tmpdir" 2>/dev/null || exit_code=$?
  assert_equals "$exit_code" "0"
}

test_consolidate_empty_dir_friendly_message() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  output=$(bash "$SCRIPTS/consolidate.sh" --output-dir "$tmpdir" 2>&1)
  assert_contains "$output" "No experience files"
}

test_consolidate_nonexistent_dir() {
  local tmpdir output exit_code=0
  tmpdir="/tmp/nonexistent_consolidate_test_$(date +%s)"
  mkdir -p "$tmpdir"
  trap "rm -rf '$tmpdir'" RETURN
  output=$(bash "$SCRIPTS/consolidate.sh" --output-dir "$tmpdir" 2>&1) || exit_code=$?
  assert_equals "$exit_code" "0"
}

# ── Unicode handling ─────────────────────────────────────────────────────────

test_unicode_in_markdown() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  printf '## 调研成果\n1. 测试 🎉\n' > "$tmpdir/test.md"
  output=$(cat "$tmpdir/test.md")
  assert_contains "$output" "调研成果"
}

test_unicode_through_inject_stdout() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  printf '## 调研成果\n1. Redis测试 🎉\n2. 分布式锁实现\n' > "$tmpdir/CONSOLIDATED.md"
  output=$(bash "$SCRIPTS/inject.sh" --target stdout --file "$tmpdir/CONSOLIDATED.md" 2>&1)
  assert_contains "$output" "调研成果"
  assert_contains "$output" "Redis测试"
}

test_unicode_preserved_in_claude_md() {
  local tmpdir content
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  printf '## 踩坑记录\n1. 连接池配置\n' > "$tmpdir/CONSOLIDATED.md"
  bash "$SCRIPTS/inject.sh" --target claude --file "$tmpdir/CONSOLIDATED.md" --project-root "$tmpdir" 2>/dev/null
  content=$(cat "$tmpdir/CLAUDE.md")
  assert_contains "$content" "踩坑记录"
  assert_contains "$content" "连接池配置"
}

test_emoji_preserved() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  printf '## Test\n1. 🎉 emoji test 🚀\n' > "$tmpdir/CONSOLIDATED.md"
  output=$(bash "$SCRIPTS/inject.sh" --target stdout --file "$tmpdir/CONSOLIDATED.md" 2>&1)
  assert_contains "$output" "🎉"
  assert_contains "$output" "🚀"
}

# ── Script syntax checks ────────────────────────────────────────────────────

test_config_sh_syntax() {
  bash -n "$SCRIPTS/config.sh"
}

test_llm_call_sh_syntax() {
  bash -n "$SCRIPTS/llm_call.sh"
}

test_consolidate_sh_syntax() {
  bash -n "$SCRIPTS/consolidate.sh"
}

test_inject_sh_syntax() {
  bash -n "$SCRIPTS/inject.sh"
}

test_parse_opencode_py_syntax() {
  python3 -m py_compile "$SCRIPTS/parse_opencode.py"
}

test_parse_claude_py_syntax() {
  python3 -m py_compile "$SCRIPTS/parse_claude.py"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "=== test_edge_cases.sh ==="

run_test "opencode_missing_dir"               test_opencode_missing_dir
run_test "opencode_no_sessions_in_range"      test_opencode_no_sessions_in_range
run_test "opencode_requires_both_dates"       test_opencode_requires_both_dates
run_test "opencode_empty_sessions_dir"        test_opencode_empty_sessions_dir
run_test "claude_missing_dir"                 test_claude_missing_dir
run_test "claude_no_sessions_in_range"        test_claude_no_sessions_in_range
run_test "claude_requires_both_dates"         test_claude_requires_both_dates
run_test "claude_empty_dir"                   test_claude_empty_dir
run_test "claude_corrupt_jsonl_handled"       test_claude_corrupt_jsonl_handled
run_test "inject_missing_source_file"         test_inject_missing_source_file
run_test "inject_missing_source_file_msg"     test_inject_missing_source_file_error_message
run_test "inject_invalid_target"              test_inject_invalid_target
run_test "inject_invalid_target_msg"          test_inject_invalid_target_error_message
run_test "inject_missing_target_flag"         test_inject_missing_target_flag
run_test "inject_unknown_option"              test_inject_unknown_option
run_test "consolidate_empty_dir_exits_zero"   test_consolidate_empty_dir_exits_zero
run_test "consolidate_empty_dir_message"      test_consolidate_empty_dir_friendly_message
run_test "consolidate_nonexistent_dir"        test_consolidate_nonexistent_dir
run_test "unicode_in_markdown"                test_unicode_in_markdown
run_test "unicode_through_inject_stdout"      test_unicode_through_inject_stdout
run_test "unicode_preserved_in_claude_md"     test_unicode_preserved_in_claude_md
run_test "emoji_preserved"                    test_emoji_preserved
run_test "config_sh_syntax"                   test_config_sh_syntax
run_test "llm_call_sh_syntax"                 test_llm_call_sh_syntax
run_test "consolidate_sh_syntax"              test_consolidate_sh_syntax
run_test "inject_sh_syntax"                   test_inject_sh_syntax
run_test "parse_opencode_py_syntax"           test_parse_opencode_py_syntax
run_test "parse_claude_py_syntax"             test_parse_claude_py_syntax

report; exit $?
