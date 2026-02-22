# scripts/config.sh — Source-able TOML config parser for experience-distiller
# Usage: source scripts/config.sh
# No shebang — this file is sourced, not executed directly.
# Do NOT use set -e here (would kill parent shell on error).

# ── Hardcoded Defaults ────────────────────────────────────────────────────────
CFG_OPENCODE_PATH="$HOME/.local/share/opencode/storage"
CFG_CLAUDE_PATH="$HOME/.claude/projects"
CFG_LLM_PROVIDER="anthropic"
CFG_LLM_MODEL="claude-3-5-haiku-20241022"
CFG_LLM_API_KEY_ENV="ANTHROPIC_API_KEY"
CFG_LLM_MAX_TOKENS=4096
CFG_LLM_TIMEOUT=30
CFG_OUTPUT_DIR="experiences"
CFG_DEFAULT_RANGE="24h"
CFG_MAX_INPUT_CHARS=150000
CFG_TOOL_OUTPUT_TRUNCATE=200
CFG_GCP_PROJECT=""
CFG_GCP_REGION="global"
CFG_GCP_USE_ADC="false"

CFG_EVOLUTION_DEFAULT_RANGE="24h"
CFG_EVOLUTION_MAX_RULES=20
CFG_EVOLUTION_COMPACT_MAX_CHARS=30000
CFG_EVOLUTION_COMPACT_WORKERS=1
CFG_EVOLUTION_RULES_MODEL=""

# ── Internal: map section+key → CFG_ variable ────────────────────────────────
_config_set() {
  local section="$1" key="$2" val="$3"
  case "${section}_${key}" in
    sources_opencode_path)    CFG_OPENCODE_PATH="$val" ;;
    sources_claude_path)      CFG_CLAUDE_PATH="$val" ;;
    llm_provider)             CFG_LLM_PROVIDER="$val" ;;
    llm_model)                CFG_LLM_MODEL="$val" ;;
    llm_api_key_env)          CFG_LLM_API_KEY_ENV="$val" ;;
    llm_max_tokens)           CFG_LLM_MAX_TOKENS="$val" ;;
    llm_timeout)              CFG_LLM_TIMEOUT="$val" ;;
    output_output_dir)        CFG_OUTPUT_DIR="$val" ;;
    output_default_range)     CFG_DEFAULT_RANGE="$val" ;;
    distill_max_input_chars)  CFG_MAX_INPUT_CHARS="$val" ;;
    distill_tool_output_truncate) CFG_TOOL_OUTPUT_TRUNCATE="$val" ;;
    gcp_project_id)           CFG_GCP_PROJECT="$val" ;;
    gcp_region)               CFG_GCP_REGION="$val" ;;
    gcp_use_application_default) CFG_GCP_USE_ADC="$val" ;;
    evolution_default_range)  CFG_EVOLUTION_DEFAULT_RANGE="$val" ;;
    evolution_max_rules_per_category) CFG_EVOLUTION_MAX_RULES="$val" ;;
    evolution_compact_max_chars)      CFG_EVOLUTION_COMPACT_MAX_CHARS="$val" ;;
    evolution_compact_workers)        CFG_EVOLUTION_COMPACT_WORKERS="$val" ;;
    evolution_rules_model)            CFG_EVOLUTION_RULES_MODEL="$val" ;;
  esac
}

_parse_toml_array() {
  local file="$1" section="$2" key="$3"
  python3 -c "
import re, sys
content = open(sys.argv[1]).read()
sec_match = re.search(r'\[' + sys.argv[2] + r'\](.+?)(?=\n\[|\Z)', content, re.DOTALL)
if not sec_match: sys.exit(0)
block = sec_match.group(1)
arr_match = re.search(sys.argv[3] + r'\s*=\s*\[(.*?)\]', block, re.DOTALL)
if arr_match:
    for path in re.findall(r'\"([^\"]+)\"', arr_match.group(1)):
        print(path)
" "$file" "$section" "$key"
}

# ── Internal: parse a single TOML file ────────────────────────────────────────
_parse_toml() {
  local file="$1"
  local section=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    # Section header
    if [[ "$line" =~ ^\[([a-z_]+)\] ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    # key = "quoted value"
    if [[ "$line" =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
      local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
    # key = unquoted value (number, bare word)
    elif [[ "$line" =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*([^#[:space:]]+) ]]; then
      local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
    else
      continue
    fi
    _config_set "$section" "$key" "$val"
  done < "$file"
}

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Load config files (precedence: local.toml overrides default.toml) ─────────
if [[ -f "$PROJECT_ROOT/config/default.toml" ]]; then
  _parse_toml "$PROJECT_ROOT/config/default.toml"
fi

if [[ -f "$PROJECT_ROOT/config/local.toml" ]]; then
  _parse_toml "$PROJECT_ROOT/config/local.toml"
fi

if [[ -f "$PROJECT_ROOT/config/evolution.toml" ]]; then
  _parse_toml "$PROJECT_ROOT/config/evolution.toml"
fi

if [[ -f "${HOME}/.claude-evolution.toml" ]]; then
  _parse_toml "${HOME}/.claude-evolution.toml"
fi

# ── Env var overrides: API keys take precedence ──────────────────────────────
# If the user has ANTHROPIC_API_KEY or OPENAI_API_KEY set and the config
# references the matching env var, the key is already accessible via indirection.
# But if user explicitly sets these, auto-detect provider preference:
if [[ -n "${ANTHROPIC_API_KEY:-}" && "$CFG_LLM_API_KEY_ENV" == "ANTHROPIC_API_KEY" ]]; then
  :
elif [[ -n "${OPENAI_API_KEY:-}" && "$CFG_LLM_API_KEY_ENV" == "OPENAI_API_KEY" ]]; then
  :
fi

# ── Expand ~ in path values ──────────────────────────────────────────────────
CFG_OPENCODE_PATH="${CFG_OPENCODE_PATH/#\~/$HOME}"
CFG_CLAUDE_PATH="${CFG_CLAUDE_PATH/#\~/$HOME}"

# ── Resolve the actual API key via indirection and export LLM_ vars ──────────
export LLM_API_KEY="${!CFG_LLM_API_KEY_ENV:-}"
export LLM_PROVIDER="$CFG_LLM_PROVIDER"
export LLM_MODEL="$CFG_LLM_MODEL"
export LLM_MAX_TOKENS="$CFG_LLM_MAX_TOKENS"
export LLM_TIMEOUT="$CFG_LLM_TIMEOUT"

# ── Export all CFG_ vars ─────────────────────────────────────────────────────
export CFG_OPENCODE_PATH CFG_CLAUDE_PATH
export CFG_LLM_PROVIDER CFG_LLM_MODEL CFG_LLM_API_KEY_ENV
export CFG_LLM_MAX_TOKENS CFG_LLM_TIMEOUT
export CFG_OUTPUT_DIR CFG_DEFAULT_RANGE
export CFG_MAX_INPUT_CHARS CFG_TOOL_OUTPUT_TRUNCATE
export CFG_GCP_PROJECT CFG_GCP_REGION CFG_GCP_USE_ADC
export CFG_EVOLUTION_DEFAULT_RANGE CFG_EVOLUTION_MAX_RULES CFG_EVOLUTION_COMPACT_MAX_CHARS CFG_EVOLUTION_COMPACT_WORKERS CFG_EVOLUTION_RULES_MODEL

# ── Cleanup internal functions ────────────────────────────────────────────────
unset -f _config_set _parse_toml
