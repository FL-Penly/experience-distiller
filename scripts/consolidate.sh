#!/usr/bin/env bash
# scripts/consolidate.sh — Merges daily experience MDs into CONSOLIDATED.md
# Usage: scripts/consolidate.sh [--output-dir DIR] [--config PATH] [--dry-run] [--verbose]

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Defaults ──────────────────────────────────────────────────────────────────
DRY_RUN=false
VERBOSE=false
CUSTOM_CONFIG=""
OUTPUT_DIR_OVERRIDE=""

# ── Parse CLI args ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR_OVERRIDE="$2"
      shift 2
      ;;
    --config)
      CUSTOM_CONFIG="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: consolidate.sh [--output-dir DIR] [--config PATH] [--dry-run] [--verbose]" >&2
      exit 1
      ;;
  esac
done

# ── Source config ─────────────────────────────────────────────────────────────
if [[ -n "$CUSTOM_CONFIG" ]]; then
  if [[ ! -f "$CUSTOM_CONFIG" ]]; then
    echo "Error: Config file not found: $CUSTOM_CONFIG" >&2
    exit 1
  fi
  source "$CUSTOM_CONFIG"
else
  source "$SCRIPT_DIR/config.sh"
fi

# ── Resolve output dir (CLI override > config) ───────────────────────────────
if [[ -n "$OUTPUT_DIR_OVERRIDE" ]]; then
  OUTPUT_DIR="$OUTPUT_DIR_OVERRIDE"
else
  OUTPUT_DIR="$PROJECT_ROOT/$CFG_OUTPUT_DIR"
fi

if [[ "$VERBOSE" == true ]]; then
  echo "PROJECT_ROOT: $PROJECT_ROOT" >&2
  echo "OUTPUT_DIR:   $OUTPUT_DIR" >&2
fi

# ── Find daily experience files ──────────────────────────────────────────────
shopt -s nullglob
daily_files=("$OUTPUT_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md)
shopt -u nullglob

if [[ ${#daily_files[@]} -eq 0 ]]; then
  echo "No experience files found to consolidate in $OUTPUT_DIR"
  exit 0
fi

file_count=${#daily_files[@]}

if [[ "$VERBOSE" == true ]]; then
  echo "Found $file_count daily experience file(s)" >&2
fi

# ── Dry run check ────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: Would consolidate $file_count files"
  exit 0
fi

# ── Concatenate daily MDs with date headers ──────────────────────────────────
experiences_tempfile=$(mktemp /tmp/consolidate_exp.XXXXXX)
trap 'rm -f "$experiences_tempfile"' EXIT

for file in $(printf '%s\n' "${daily_files[@]}" | sort); do
  {
    echo "=== $(basename "$file" .md) ==="
    cat "$file"
    echo ""
  } >> "$experiences_tempfile"
done

if [[ "$VERBOSE" == true ]]; then
  echo "Concatenated experiences size: $(wc -c < "$experiences_tempfile") bytes" >&2
fi

# ── Load prompt template and substitute {{EXPERIENCES}} via Python ────────────
prompt_file="$PROJECT_ROOT/prompts/consolidate.md"
if [[ ! -f "$prompt_file" ]]; then
  echo "Error: Prompt template not found: $prompt_file" >&2
  exit 1
fi

llm_output=$(python3 -c "
import sys
template = open(sys.argv[1]).read()
experiences = sys.stdin.read()
print(template.replace('{{EXPERIENCES}}', experiences))
" "$prompt_file" < "$experiences_tempfile" | "$SCRIPT_DIR/llm_call.sh")

if [[ -z "$llm_output" ]]; then
  echo "Error: LLM returned empty output" >&2
  exit 1
fi

# ── Add YAML frontmatter ─────────────────────────────────────────────────────
today=$(date +%Y-%m-%d)
consolidated_file="$OUTPUT_DIR/CONSOLIDATED.md"

{
  printf '%s\n' "---"
  printf 'consolidated_at: %s\n' "$today"
  printf 'source_files: %s\n' "$file_count"
  printf '%s\n' "---"
  printf '\n'
  printf '%s\n' "$llm_output"
} > "$consolidated_file"

echo "Consolidated $file_count daily files → $consolidated_file"
