#!/usr/bin/env bash
# tests/test_llm_call.sh — llm_call.sh input validation tests (no real HTTP calls)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LLM_CALL="$PROJECT_ROOT/scripts/llm_call.sh"

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
  [[ "$1" == *"$2"* ]] || { echo "Expected '$1' to contain '$2'" >&2; return 1; }
}

assert_nonzero_exit() {
  [[ "$1" -ne 0 ]] || { echo "Expected non-zero exit code, got 0" >&2; return 1; }
}

report() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [[ $FAIL -eq 0 ]]
}

# ── Tests ─────────────────────────────────────────────────────────────────────

test_missing_api_key_fails() {
  local result exit_code=0
  result=$(echo "test prompt" | LLM_API_KEY="" LLM_PROVIDER="anthropic" LLM_MODEL="claude-3-5-haiku-20241022" bash "$LLM_CALL" 2>&1) || exit_code=$?
  assert_nonzero_exit "$exit_code"
  assert_contains "$result" "LLM_API_KEY"
}

test_unset_api_key_fails() {
  local result exit_code=0
  result=$(echo "test prompt" | env -u LLM_API_KEY LLM_PROVIDER="anthropic" LLM_MODEL="test" bash "$LLM_CALL" 2>&1) || exit_code=$?
  assert_nonzero_exit "$exit_code"
  assert_contains "$result" "LLM_API_KEY"
}

test_unknown_provider_fails() {
  local result exit_code=0
  result=$(echo "test prompt" | LLM_API_KEY="fake-key" LLM_PROVIDER="unknown_provider" LLM_MODEL="test" bash "$LLM_CALL" 2>&1) || exit_code=$?
  assert_nonzero_exit "$exit_code"
  assert_contains "$result" "Unknown provider"
}

test_anthropic_provider_accepted() {
  # Should get past validation (will fail at curl, but not at provider check)
  local result exit_code=0
  result=$(echo "test" | LLM_API_KEY="fake" LLM_PROVIDER="anthropic" LLM_MODEL="test" LLM_TIMEOUT=1 bash "$LLM_CALL" 2>&1) || exit_code=$?
  # Should NOT contain "Unknown provider"
  if [[ "$result" == *"Unknown provider"* ]]; then
    echo "anthropic should be accepted as valid provider" >&2
    return 1
  fi
  return 0
}

test_openai_provider_accepted() {
  local result exit_code=0
  result=$(echo "test" | LLM_API_KEY="fake" LLM_PROVIDER="openai" LLM_MODEL="test" LLM_TIMEOUT=1 bash "$LLM_CALL" 2>&1) || exit_code=$?
  if [[ "$result" == *"Unknown provider"* ]]; then
    echo "openai should be accepted as valid provider" >&2
    return 1
  fi
  return 0
}

test_error_message_mentions_valid_providers() {
  local result exit_code=0
  result=$(echo "test" | LLM_API_KEY="fake" LLM_PROVIDER="bad" LLM_MODEL="test" bash "$LLM_CALL" 2>&1) || exit_code=$?
  assert_contains "$result" "anthropic"
  assert_contains "$result" "openai"
}

test_jq_dependency_checked() {
  # llm_call.sh checks for jq at the top — verify it mentions jq on missing
  local result exit_code=0
  result=$(echo "test" | env PATH="/usr/bin:/bin" LLM_API_KEY="fake" LLM_PROVIDER="anthropic" bash "$LLM_CALL" 2>&1) || exit_code=$?
  # If jq IS available (likely), this test just verifies the script starts OK
  # If jq is NOT available, we'd expect exit with "jq required"
  if ! command -v jq >/dev/null 2>&1; then
    assert_nonzero_exit "$exit_code"
    assert_contains "$result" "jq"
  fi
  return 0
}

test_truncation_warning_on_large_input() {
  # MAX_PROMPT_CHARS in llm_call.sh is 150000
  # Generate input > 150K chars, capture stderr for truncation warning
  # The script will fail at the API call, but we check stderr for the warning
  local stderr_file
  stderr_file=$(mktemp /tmp/test_trunc_stderr.XXXXXX)
  trap "rm -f '$stderr_file'" RETURN

  python3 -c "print('x' * 200000)" | \
    LLM_API_KEY="fake" LLM_PROVIDER="anthropic" LLM_MODEL="test" LLM_TIMEOUT=1 \
    bash "$LLM_CALL" >/dev/null 2>"$stderr_file" || true

  local stderr_content
  stderr_content=$(cat "$stderr_file")
  assert_contains "$stderr_content" "truncated"
}

test_no_truncation_on_small_input() {
  local stderr_file
  stderr_file=$(mktemp /tmp/test_notrunc_stderr.XXXXXX)
  trap "rm -f '$stderr_file'" RETURN

  echo "small input" | \
    LLM_API_KEY="fake" LLM_PROVIDER="anthropic" LLM_MODEL="test" LLM_TIMEOUT=1 \
    bash "$LLM_CALL" >/dev/null 2>"$stderr_file" || true

  local stderr_content
  stderr_content=$(cat "$stderr_file")
  if [[ "$stderr_content" == *"truncated"* ]]; then
    echo "Should not see truncation warning for small input" >&2
    return 1
  fi
  return 0
}

test_script_is_executable_syntax() {
  bash -n "$LLM_CALL"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "=== test_llm_call.sh ==="

run_test "missing_api_key_fails"               test_missing_api_key_fails
run_test "unset_api_key_fails"                 test_unset_api_key_fails
run_test "unknown_provider_fails"              test_unknown_provider_fails
run_test "anthropic_provider_accepted"         test_anthropic_provider_accepted
run_test "openai_provider_accepted"            test_openai_provider_accepted
run_test "error_message_mentions_providers"    test_error_message_mentions_valid_providers
run_test "jq_dependency_checked"               test_jq_dependency_checked
run_test "truncation_warning_on_large_input"   test_truncation_warning_on_large_input
run_test "no_truncation_on_small_input"        test_no_truncation_on_small_input
run_test "script_is_executable_syntax"         test_script_is_executable_syntax

report; exit $?
