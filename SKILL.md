---
name: experience-distiller
description: >
  Distill AI agent session logs into structured lessons learned.
  Reads OpenCode and Claude Code sessions, sends to LLM for summarization,
  outputs structured daily experience files in Chinese. Use when asked to
  'distill sessions', 'extract lessons', 'summarize my work', 'what did I
  learn today', or 'consolidate experiences'.
version: 0.1.0
license: MIT
author: experience-distiller contributors
compatibility: Requires python3 (3.7+), jq, curl, bash. Linux/macOS.
---

## When to Use

- After a coding session to extract reusable lessons
- As a daily/weekly cron job to build a knowledge base
- Before starting a new project to review relevant past experiences

## Quick Start

```bash
# Distill last 24 hours of sessions
scripts/distill.sh --last 24h

# Distill a specific date range
scripts/distill.sh --from 2026-02-19 --to 2026-02-20

# Distill and immediately inject into CLAUDE.md
scripts/distill.sh --last 24h --inject claude

# Consolidate all daily files into one knowledge base
scripts/distill.sh --consolidate

# Preview without calling LLM
scripts/distill.sh --last 24h --dry-run
```

## Configuration

Copy `config/default.toml` to `config/local.toml` and edit. Key settings:

- `[llm] provider` — `"anthropic"` or `"openai"`
- `[llm] model` — model name
- `[llm] api_key_env` — env var holding the API key
- `[sources] opencode_path` — path to OpenCode storage
- `[sources] claude_path` — path to Claude Code projects dir

## Output

Writes `experiences/YYYY-MM-DD.md` with 4 categories (always in Chinese):

- **调研成果** — Research findings
- **踩坑记录** — Pitfalls and gotchas
- **工具技巧** — Tool tips
- **模式识别** — Patterns and insights

## Automation (crontab example)

```cron
# Daily at 6 AM: distill yesterday's sessions
0 6 * * * /path/to/experience-distiller/scripts/distill.sh --last 24h
# Weekly Monday: consolidate all experiences
0 7 * * 1 /path/to/experience-distiller/scripts/distill.sh --consolidate
```
