# experience-distiller

Distill AI agent session logs into structured, reusable lessons learned — and evolve per-project coding rules automatically.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Python: 3.7+](https://img.shields.io/badge/python-3.7%2B-blue.svg)](https://www.python.org/)

## What it Does

experience-distiller reads session logs from OpenCode and Claude Code, sends the transcripts to an LLM with a structured prompt, and writes categorized lessons learned to `experiences/YYYY-MM-DD.md` in Chinese. The daily files can be consolidated into a single `CONSOLIDATED.md` and injected into `CLAUDE.md` or `AGENTS.md`, making past lessons available as context in future sessions.

**Evolution Mode** (`evolve.sh`) goes further: it extracts project-specific `ALWAYS`/`NEVER`/`PREFER` rules from sessions and writes them directly to `<project>/.claude/rules/learned-rules.md` — a file Claude Code auto-loads on every session start. Rules accumulate incrementally; already-processed sessions are never re-processed.

## Architecture

```
distill.sh (orchestrator)
├── parse_opencode.py  → OpenCode sessions (SQLite or legacy file format) → unified NDJSON
├── parse_claude.py    → Claude Code JSONL projects → unified NDJSON
├── llm_call.sh        → Anthropic/OpenAI/GCP Vertex AI API with retry
├── config.sh          → TOML config parser (source-able)
├── consolidate.sh     → Merge daily MDs → CONSOLIDATED.md
└── inject.sh          → Append to CLAUDE.md / AGENTS.md

evolve.sh (per-project rule evolution)
├── parse_opencode.py  → sessions filtered by --project-path, subagents excluded
├── parse_claude.py    → sessions filtered by --project-path
├── state.sh           → read/write <project>/.claude/evolution-state.json
├── llm_call.sh        → compact each session (concurrent), then extract rules
├── inject-rules.sh    → write LLM-merged rules to <project>/.claude/rules/learned-rules.md
└── config.sh          → reads [evolution] section + [projects] paths
```

**Storage layouts parsed:**

- OpenCode v1.1+ (SQLite): `~/.local/share/opencode/opencode.db` — sessions, messages, and parts in a single database. Auto-detected when `opencode.db` is present.
- OpenCode legacy (file-based): `storage/session/<project-hash>/ses_*.json` → `message/<session-id>/msg_*.json` → `part/<message-id>/prt_*.json`
- Claude Code: `~/.claude/projects/<hash>/` JSONL files with a `sessions-index.json`

Both parsers emit unified NDJSON (one session object per line) consumed by `distill.sh`. Subagent sessions (spawned by the main agent) are automatically excluded from Evolution Mode to avoid noise.

## Requirements

- Python 3.7+
- `jq`
- `curl`
- `bash` 4+
- API key for Anthropic or OpenAI

## Installation

```bash
git clone <repo> experience-distiller
cd experience-distiller
cp config/default.toml config/local.toml
# Edit config/local.toml — set provider and api_key_env
export ANTHROPIC_API_KEY="your-key-here"
```

## Usage

```bash
# Distill last 24 hours of sessions
scripts/distill.sh --last 24h

# Distill a specific date range
scripts/distill.sh --from 2026-02-19 --to 2026-02-20

# Distill and immediately inject into CLAUDE.md
scripts/distill.sh --last 24h --inject claude

# Inject into AGENTS.md instead
scripts/distill.sh --last 24h --inject agents

# Consolidate all daily files into CONSOLIDATED.md
scripts/distill.sh --consolidate

# Preview what would be processed without calling LLM
scripts/distill.sh --last 24h --dry-run

# Verbose output for debugging
scripts/distill.sh --last 24h --verbose
```

**Flag reference:**

| Flag | Description |
|------|-------------|
| `--last <N>h\|d\|w` | Time window relative to now (e.g. `24h`, `7d`, `2w`) |
| `--from <date>` | Start of date range (ISO 8601: `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM:SSZ`) |
| `--to <date>` | End of date range (same format) |
| `--inject claude\|agents` | Append consolidated output to `CLAUDE.md` or `AGENTS.md` after distilling |
| `--consolidate` | Run consolidation only (no new distillation) |
| `--dry-run` | Print what would be processed; skip LLM call and file writes |
| `--verbose` | Print debug info to stderr |

## Testing

```bash
# Python parser tests (requires pytest)
pip install pytest
pytest tests/test_parse_opencode.py tests/test_parse_claude.py -v

# Bash tests (requires bats-core)
bats tests/test_llm_call.sh
bats tests/test_config.sh
bats tests/test_integration.sh
```

Test fixtures live in `tests/fixtures/`:

- `opencode/` — synthetic 3-level OpenCode storage tree
- `claude-code/` — synthetic JSONL session files
- `daily-mds/` — pre-built daily experience files for consolidation tests
- `expected/` — expected NDJSON output for parser assertions
- `llm-responses/` — canned API responses for offline testing

## Output Format

`experiences/2026-02-20.md`:

```markdown
---
date: 2026-02-20
sessions: 3
sources: opencode, claude-code
---

## 调研成果
1. Redis 的 `SETNX` 命令可以实现分布式锁，但需要配合 `EXPIRE` 防止死锁

## 踩坑记录
1. Redis 连接池默认大小可能不足，高并发时需要明确配置 `max_connections`

## 工具技巧
1. `redis-cli --scan --pattern "user:*"` 可以安全扫描大型 Redis 实例（不阻塞）

## 模式识别
1. 分布式系统中，锁的获取和释放应该是原子操作，防止竞态条件
```

`experiences/CONSOLIDATED.md` (produced by `--consolidate`) adds a YAML frontmatter block and a "Top Insights" section synthesized across all daily files.

## Configuration Reference

All settings live in `config/default.toml`. Override any key in `config/local.toml` (gitignored).

| Key | Default | Description |
|-----|---------|-------------|
| `[sources] opencode_path` | `~/.local/share/opencode/storage` | OpenCode storage directory |
| `[sources] claude_path` | `~/.claude/projects` | Claude Code projects directory |
| `[sources] enabled` | `["opencode", "claude-code"]` | Which sources to read |
| `[llm] provider` | `"anthropic"` | LLM provider: `"anthropic"` or `"openai"` |
| `[llm] model` | `"claude-3-5-haiku-20241022"` | Model name passed to the API |
| `[llm] api_key_env` | `"ANTHROPIC_API_KEY"` | Env var name holding the API key |
| `[llm] max_tokens` | `4096` | Maximum tokens in LLM response |
| `[llm] timeout` | `30` | HTTP timeout in seconds |
| `[output] output_dir` | `"experiences"` | Directory for daily MD files |
| `[output] default_range` | `"24h"` | Default window when `--last` has no argument |
| `[distill] max_input_chars` | `150000` | Input truncation limit (~37K tokens) |
| `[distill] tool_output_truncate` | `200` | Characters kept per tool call output |
| `[consolidate] max_items_per_category` | `50` | Item cap per category in consolidated output |
| `[consolidate] top_insights_count` | `10` | Number of top insights in consolidated header |
| `[evolution] compact_workers` | `1` | Parallel workers for session compaction (increase to speed up large backlogs) |
| `[evolution] rules_model` | `""` (same as `[llm] model`) | Override model for the single rule-extraction call (e.g. a larger model for better quality) |

Environment variables take precedence over config file values. `config.sh` resolves the API key via bash indirection (`${!CFG_LLM_API_KEY_ENV}`) so you never store keys in config files.

## Evolution Mode

Extract per-project coding rules from Claude Code sessions and write them to `<project>/.claude/rules/learned-rules.md` — auto-loaded by Claude Code on every session start.

**Quick start:**

```bash
# Edit config/evolution.toml — add your project paths under [projects] paths
# Then run:
scripts/evolve.sh --project /path/to/my-project --last 7d

# Or process all configured projects:
scripts/evolve.sh --all

# Preview without LLM calls:
scripts/evolve.sh --all --dry-run
```

**Config (`config/evolution.toml`):**

```toml
[projects]
paths = [
  "/data00/home/user/project/admin_server",
  "/data00/home/user/project/backend",
]

[evolution]
default_range = "24h"
max_rules_per_category = 20
compact_max_chars = 30000
compact_workers = 2     # parallel session compaction
rules_model = ""        # override model for rule extraction (e.g. a larger model)
```

**Output format (`<project>/.claude/rules/learned-rules.md`):**

```markdown
---
last_updated: 2026-02-22
session_count: 12
---

## 错误预防规则
- NEVER use fmt.Errorf for external errors — use errno.From(errcode.ErrXxx, err) instead (来源: 3个session)

## 代码规范
- ALWAYS run go vet ./... before committing — catches nil pointer issues (来源: 2个session)

## 架构模式
- PREFER stateless handlers — avoid storing request-scoped state in struct fields (来源: 4个session)

## 工具与工作流
- ALWAYS check ~/.claude/rules/ for project-specific rules before starting (来源: 1个session)
```

**Evolution flag reference:**

| Flag | Description |
|------|-------------|
| `--project PATH` | Add one project to process (repeatable) |
| `--all` | Process all projects from `config/evolution.toml` |
| `--last <N>h\|d\|w` | Time window (e.g. `24h`, `7d`, `14d`) |
| `--from / --to` | Explicit ISO 8601 date range |
| `--dry-run` | Show sessions that would be processed, no LLM calls |
| `--verbose` | Debug output to stderr |

**Incremental processing:** `evolve.sh` tracks processed session IDs in `<project>/.claude/evolution-state.json`. Re-running never re-processes the same session.

**Rule merging:** Each run passes the existing `learned-rules.md` to the LLM together with the new session summaries. The LLM produces the complete merged ruleset — updating source counts, consolidating near-duplicates, and removing outdated rules — so the file never grows unboundedly.

## Automation

```cron
# Daily at 6 AM: distill yesterday's sessions
0 6 * * * /path/to/experience-distiller/scripts/distill.sh --last 24h
# Daily at 6:30 AM: evolve project rules
30 6 * * * /path/to/experience-distiller/scripts/evolve.sh --all
# Weekly Monday: consolidate all experiences
0 7 * * 1 /path/to/experience-distiller/scripts/distill.sh --consolidate
```

## License

MIT
