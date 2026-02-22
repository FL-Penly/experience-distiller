#!/usr/bin/env bash
# scripts/inject.sh — Appends CONSOLIDATED.md into CLAUDE.md / AGENTS.md
# Usage: scripts/inject.sh --target claude|agents|stdout [--file PATH] [--project-root PATH]

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Defaults ──────────────────────────────────────────────────────────────────
TARGET=""
SOURCE_FILE=""
PROJECT_ROOT_OVERRIDE=""

# ── Parse CLI args ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"
      shift 2
      ;;
    --file)
      SOURCE_FILE="$2"
      shift 2
      ;;
    --project-root)
      PROJECT_ROOT_OVERRIDE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: inject.sh --target claude|agents|stdout [--file PATH] [--project-root PATH]" >&2
      exit 1
      ;;
  esac
done

# ── Validate target ──────────────────────────────────────────────────────────
if [[ -z "$TARGET" ]]; then
  echo "Error: --target is required (claude|agents|stdout)" >&2
  exit 1
fi

case "$TARGET" in
  claude|agents|stdout) ;;
  *)
    echo "Error: --target must be one of: claude, agents, stdout" >&2
    exit 1
    ;;
esac

# ── Apply project root override ──────────────────────────────────────────────
if [[ -n "$PROJECT_ROOT_OVERRIDE" ]]; then
  PROJECT_ROOT="$PROJECT_ROOT_OVERRIDE"
fi

# ── Resolve source file ──────────────────────────────────────────────────────
if [[ -z "$SOURCE_FILE" ]]; then
  SOURCE_FILE="$PROJECT_ROOT/experiences/CONSOLIDATED.md"
fi

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "Error: Source file not found: $SOURCE_FILE" >&2
  exit 1
fi

# ── stdout target: just cat and exit ──────────────────────────────────────────
if [[ "$TARGET" == "stdout" ]]; then
  cat "$SOURCE_FILE"
  exit 0
fi

# ── Determine target file path ───────────────────────────────────────────────
TODAY=$(date +%Y-%m-%d)

case "$TARGET" in
  claude) target_file="$PROJECT_ROOT/CLAUDE.md" ;;
  agents) target_file="$PROJECT_ROOT/AGENTS.md" ;;
esac

# ── Idempotency check ────────────────────────────────────────────────────────
if grep -qF "## Distilled Experiences ($TODAY)" "$target_file" 2>/dev/null; then
  echo "Already injected for $TODAY into $target_file, skipping"
  exit 0
fi

# ── Create target file if it doesn't exist ────────────────────────────────────
if [[ ! -f "$target_file" ]]; then
  case "$TARGET" in
    claude) printf '# Project Instructions\n\n' > "$target_file" ;;
    agents) printf '# Agent Instructions\n\n' > "$target_file" ;;
  esac
fi

# ── Append separator + consolidated content ───────────────────────────────────
{
  printf '\n\n---\n## Distilled Experiences (%s)\n\n' "$TODAY"
  cat "$SOURCE_FILE"
} >> "$target_file"

echo "Injected experiences into $target_file"
