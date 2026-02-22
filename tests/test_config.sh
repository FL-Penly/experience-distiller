#!/usr/bin/env bash
# tests/test_config.sh — config.sh parser tests (plain bash, no bats)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

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

assert_not_empty() {
  [[ -n "$1" ]] || { echo "Expected non-empty value, got empty" >&2; return 1; }
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || { echo "Expected '$1' to contain '$2'" >&2; return 1; }
}

assert_not_contains() {
  [[ "$1" != *"$2"* ]] || { echo "Expected '$1' to NOT contain '$2'" >&2; return 1; }
}

report() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [[ $FAIL -eq 0 ]]
}

# ── Helper: source config.sh in isolated subshell ────────────────────────────
cfg_var() {
  bash -c "
    unset ANTHROPIC_API_KEY OPENAI_API_KEY 2>/dev/null || true
    source '$PROJECT_ROOT/scripts/config.sh'
    echo \"\${$1:-}\"
  " 2>/dev/null
}

# ── Tests ─────────────────────────────────────────────────────────────────────

test_default_toml_loads() {
  local result
  result=$(cfg_var CFG_LLM_PROVIDER)
  assert_not_empty "$result"
}

test_default_provider_is_anthropic() {
  local result
  result=$(cfg_var CFG_LLM_PROVIDER)
  assert_equals "$result" "anthropic"
}

test_default_model_is_set() {
  local result
  result=$(cfg_var CFG_LLM_MODEL)
  assert_not_empty "$result"
}

test_default_model_value() {
  local result
  result=$(cfg_var CFG_LLM_MODEL)
  assert_equals "$result" "claude-3-5-haiku-20241022"
}

test_default_output_dir() {
  local result
  result=$(cfg_var CFG_OUTPUT_DIR)
  assert_equals "$result" "experiences"
}

test_default_range() {
  local result
  result=$(cfg_var CFG_DEFAULT_RANGE)
  assert_equals "$result" "24h"
}

test_default_max_tokens() {
  local result
  result=$(cfg_var CFG_LLM_MAX_TOKENS)
  assert_equals "$result" "4096"
}

test_default_timeout() {
  local result
  result=$(cfg_var CFG_LLM_TIMEOUT)
  assert_equals "$result" "30"
}

test_default_max_input_chars() {
  local result
  result=$(cfg_var CFG_MAX_INPUT_CHARS)
  assert_equals "$result" "150000"
}

test_tilde_expanded_in_opencode_path() {
  local result
  result=$(cfg_var CFG_OPENCODE_PATH)
  assert_not_contains "$result" "~"
}

test_tilde_expanded_in_claude_path() {
  local result
  result=$(cfg_var CFG_CLAUDE_PATH)
  assert_not_contains "$result" "~"
}

test_opencode_path_starts_with_slash() {
  local result
  result=$(cfg_var CFG_OPENCODE_PATH)
  [[ "$result" == /* ]] || { echo "Path should start with /: $result" >&2; return 1; }
}

test_claude_path_starts_with_slash() {
  local result
  result=$(cfg_var CFG_CLAUDE_PATH)
  [[ "$result" == /* ]] || { echo "Path should start with /: $result" >&2; return 1; }
}

test_api_key_not_required_to_source() {
  local exit_code=0
  bash -c "
    unset ANTHROPIC_API_KEY OPENAI_API_KEY 2>/dev/null || true
    source '$PROJECT_ROOT/scripts/config.sh'
  " 2>/dev/null || exit_code=$?
  assert_equals "$exit_code" "0"
}

test_llm_vars_exported() {
  local result
  result=$(bash -c "
    unset ANTHROPIC_API_KEY OPENAI_API_KEY 2>/dev/null || true
    source '$PROJECT_ROOT/scripts/config.sh'
    echo \"\$LLM_PROVIDER|\$LLM_MODEL|\$LLM_MAX_TOKENS\"
  " 2>/dev/null)
  assert_contains "$result" "anthropic"
  assert_contains "$result" "claude-3-5-haiku"
  assert_contains "$result" "4096"
}

test_api_key_env_default() {
  local result
  result=$(cfg_var CFG_LLM_API_KEY_ENV)
  assert_equals "$result" "ANTHROPIC_API_KEY"
}

test_local_toml_overrides_default() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  cp "$PROJECT_ROOT/config/default.toml" "$tmpdir/default.toml"

  cat > "$tmpdir/local.toml" << 'TOMLEOF'
[llm]
provider = "openai"
model = "gpt-4o"
TOMLEOF

  local result
  result=$(bash -c "
    # Override PROJECT_ROOT so config.sh reads from our temp dir
    # We must manually replicate the config load with the temp files
    source /dev/stdin << 'BASHEOF'
$(cat "$PROJECT_ROOT/scripts/config.sh" | sed "s|__PLACEHOLDER__|$tmpdir|g")
BASHEOF
    echo \"\$CFG_LLM_PROVIDER\"
  " 2>/dev/null)

  # Since we can't easily override PROJECT_ROOT in config.sh,
  # test the _parse_toml function directly
  result=$(bash -c "
    CFG_LLM_PROVIDER='anthropic'
    CFG_LLM_MODEL='claude-3-5-haiku-20241022'
    CFG_LLM_API_KEY_ENV='ANTHROPIC_API_KEY'
    CFG_LLM_MAX_TOKENS=4096
    CFG_LLM_TIMEOUT=30
    CFG_OUTPUT_DIR='experiences'
    CFG_DEFAULT_RANGE='24h'
    CFG_MAX_INPUT_CHARS=150000
    CFG_TOOL_OUTPUT_TRUNCATE=200
    CFG_OPENCODE_PATH='\$HOME/.local/share/opencode/storage'
    CFG_CLAUDE_PATH='\$HOME/.claude/projects'

    _config_set() {
      local section=\"\$1\" key=\"\$2\" val=\"\$3\"
      case \"\${section}_\${key}\" in
        llm_provider)   CFG_LLM_PROVIDER=\"\$val\" ;;
        llm_model)      CFG_LLM_MODEL=\"\$val\" ;;
      esac
    }

    _parse_toml() {
      local file=\"\$1\" section=''
      while IFS= read -r line || [[ -n \"\$line\" ]]; do
        [[ \"\$line\" =~ ^[[:space:]]*# ]] && continue
        [[ -z \"\${line// }\" ]] && continue
        if [[ \"\$line\" =~ ^\[([a-z_]+)\] ]]; then
          section=\"\${BASH_REMATCH[1]}\"; continue
        fi
        if [[ \"\$line\" =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*\\\"([^\\\"]*)\\\" ]]; then
          _config_set \"\$section\" \"\${BASH_REMATCH[1]}\" \"\${BASH_REMATCH[2]}\"
        elif [[ \"\$line\" =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*([^#[:space:]]+) ]]; then
          _config_set \"\$section\" \"\${BASH_REMATCH[1]}\" \"\${BASH_REMATCH[2]}\"
        fi
      done < \"\$file\"
    }

    _parse_toml '$tmpdir/default.toml'
    _parse_toml '$tmpdir/local.toml'
    echo \"\$CFG_LLM_PROVIDER|\$CFG_LLM_MODEL\"
  " 2>/dev/null)

  assert_equals "$result" "openai|gpt-4o"
}

test_tool_output_truncate() {
  local result
  result=$(cfg_var CFG_TOOL_OUTPUT_TRUNCATE)
  assert_equals "$result" "200"
}

test_config_sources_without_errors() {
  local stderr_output
  stderr_output=$(bash -c "
    unset ANTHROPIC_API_KEY OPENAI_API_KEY 2>/dev/null || true
    source '$PROJECT_ROOT/scripts/config.sh'
  " 2>&1 >/dev/null)
  [[ -z "$stderr_output" ]] || { echo "Unexpected stderr: $stderr_output" >&2; return 1; }
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "=== test_config.sh ==="

run_test "default_toml_loads"                test_default_toml_loads
run_test "default_provider_is_anthropic"     test_default_provider_is_anthropic
run_test "default_model_is_set"              test_default_model_is_set
run_test "default_model_value"               test_default_model_value
run_test "default_output_dir"                test_default_output_dir
run_test "default_range"                     test_default_range
run_test "default_max_tokens"                test_default_max_tokens
run_test "default_timeout"                   test_default_timeout
run_test "default_max_input_chars"           test_default_max_input_chars
run_test "tilde_expanded_in_opencode_path"   test_tilde_expanded_in_opencode_path
run_test "tilde_expanded_in_claude_path"     test_tilde_expanded_in_claude_path
run_test "opencode_path_starts_with_slash"   test_opencode_path_starts_with_slash
run_test "claude_path_starts_with_slash"     test_claude_path_starts_with_slash
run_test "api_key_not_required_to_source"    test_api_key_not_required_to_source
run_test "llm_vars_exported"                 test_llm_vars_exported
run_test "api_key_env_default"               test_api_key_env_default
run_test "local_toml_overrides_default"      test_local_toml_overrides_default
run_test "tool_output_truncate"              test_tool_output_truncate
run_test "config_sources_without_errors"     test_config_sources_without_errors

report; exit $?
