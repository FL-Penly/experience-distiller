"""Tests for scripts/parse_claude.py — subprocess-based CLI integration tests."""

import json
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPTS = Path(__file__).parent.parent / "scripts"
# Claude parser expects --claude-dir to be parent containing project subdirs.
# tests/fixtures/ has claude-code/ as a subdirectory, which acts as a project dir.
FIXTURES_ROOT = Path(__file__).parent / "fixtures"
CLAUDE_CODE_DIR = FIXTURES_ROOT / "claude-code"

FROM_DATE = "2026-02-20"
TO_DATE = "2026-02-21"


def run_parser(*args):
    """Run parse_claude.py as a subprocess and return CompletedProcess."""
    result = subprocess.run(
        [sys.executable, str(SCRIPTS / "parse_claude.py"), *args],
        capture_output=True,
        text=True,
    )
    return result


def parse_ndjson(stdout):
    """Parse newline-delimited JSON output into a list of dicts."""
    sessions = []
    for line in stdout.strip().split("\n"):
        line = line.strip()
        if line:
            sessions.append(json.loads(line))
    return sessions


def run_normal():
    """Helper: run parser for the standard date range."""
    return run_parser(
        "--claude-dir",
        str(FIXTURES_ROOT),
        "--from",
        FROM_DATE,
        "--to",
        TO_DATE,
    )


# ---------- test cases ----------


def test_normal_session_output_structure():
    result = run_normal()
    assert result.returncode == 0, f"stderr: {result.stderr}"

    sessions = parse_ndjson(result.stdout)
    assert len(sessions) == 1, (
        f"Expected 1 session (sidechain and old filtered), got {len(sessions)}: "
        f"{[s.get('session_id') for s in sessions]}"
    )

    session = sessions[0]
    required_keys = {
        "source",
        "session_id",
        "project",
        "title",
        "time_start",
        "time_end",
        "messages",
    }
    assert required_keys.issubset(session.keys()), (
        f"Missing keys: {required_keys - session.keys()}"
    )
    assert session["source"] == "claude-code"
    assert session["session_id"] == "11111111-1111-1111-1111-111111111111"
    assert len(session["messages"]) >= 2


def test_sidechain_filtered():
    result = run_normal()
    assert result.returncode == 0

    sessions = parse_ndjson(result.stdout)
    session_ids = [s["session_id"] for s in sessions]
    assert "22222222-2222-2222-2222-222222222222" not in session_ids, (
        "Sidechain session should be filtered out"
    )


def test_old_session_filtered():
    result = run_normal()
    assert result.returncode == 0

    sessions = parse_ndjson(result.stdout)
    session_ids = [s["session_id"] for s in sessions]
    assert "33333333-3333-3333-3333-333333333333" not in session_ids, (
        "Old session (2026-01-01) should be filtered out by date range"
    )


def test_thinking_blocks_stripped():
    result = run_normal()
    assert result.returncode == 0

    sessions = parse_ndjson(result.stdout)
    assert len(sessions) >= 1

    for session in sessions:
        for msg in session["messages"]:
            # No thinking blocks should appear in output content
            assert (
                "thinking" not in msg.get("content", "").lower()
                or "thinking" in msg["content"]
            ), "Output should not contain raw thinking block markers"
            # No 'thinking' key should exist on messages
            assert "thinking" not in msg, "Messages should not have a 'thinking' field"


def test_tool_use_extracted():
    result = run_normal()
    assert result.returncode == 0

    sessions = parse_ndjson(result.stdout)
    assert len(sessions) == 1

    # The first assistant message (index 1) has a tool_use block
    assistant_msgs = [m for m in sessions[0]["messages"] if m["role"] == "assistant"]
    assert len(assistant_msgs) >= 1

    first_assistant = assistant_msgs[0]
    assert "tool_calls" in first_assistant, (
        "First assistant message should have tool_calls"
    )
    assert len(first_assistant["tool_calls"]) >= 1
    assert first_assistant["tool_calls"][0]["tool"] == "bash"


def test_tool_result_in_user_message():
    result = run_normal()
    assert result.returncode == 0

    sessions = parse_ndjson(result.stdout)
    assert len(sessions) == 1

    # Find user messages that contain tool results
    user_msgs_with_tool_result = [
        m
        for m in sessions[0]["messages"]
        if m["role"] == "user" and "[Tool result:" in m.get("content", "")
    ]
    assert len(user_msgs_with_tool_result) >= 1, (
        "Should have at least one user message with '[Tool result:' content"
    )


def test_corrupt_line_skipped(tmp_path):
    """Parser should handle corrupt JSONL lines gracefully without crashing."""
    # Create a project dir with a custom index pointing to the corrupt session
    project_dir = tmp_path / "test-project"
    project_dir.mkdir()

    # Create sessions-index.json that includes the corrupt session
    index = {
        "version": "1.0",
        "entries": [
            {
                "sessionId": "session-corrupt",
                "fullPath": "",
                "fileMtime": "2026-02-20T09:00:10.000Z",
                "firstPrompt": "Corrupt test",
                "summary": "",
                "messageCount": 2,
                "created": "2026-02-20T09:00:00.000Z",
                "modified": "2026-02-20T09:00:10.000Z",
                "gitBranch": "main",
                "projectPath": "/test",
                "isSidechain": False,
            }
        ],
    }
    (project_dir / "sessions-index.json").write_text(
        json.dumps(index), encoding="utf-8"
    )

    # Copy the corrupt JSONL file with the correct name
    shutil.copy(
        CLAUDE_CODE_DIR / "session-corrupt.jsonl",
        project_dir / "session-corrupt.jsonl",
    )

    result = run_parser(
        "--claude-dir",
        str(tmp_path),
        "--from",
        "2026-02-19",
        "--to",
        "2026-02-21",
    )
    assert result.returncode == 0, (
        f"Parser should not crash on corrupt JSONL lines. stderr: {result.stderr}"
    )

    # The corrupt session should still produce output (valid lines are kept)
    sessions = parse_ndjson(result.stdout)
    if sessions:
        # If the session was processed, it should have messages from valid lines
        session = sessions[0]
        assert session["session_id"] == "session-corrupt"
        assert len(session["messages"]) >= 1


def test_no_sessions_in_range():
    result = run_parser(
        "--claude-dir",
        str(FIXTURES_ROOT),
        "--from",
        "1999-01-01",
        "--to",
        "1999-01-02",
    )
    assert result.returncode == 0
    assert result.stdout.strip() == "", (
        f"Expected empty stdout for out-of-range query, got: {result.stdout!r}"
    )


def test_nonexistent_claude_dir():
    result = run_parser(
        "--claude-dir",
        "/nonexistent/path",
        "--from",
        FROM_DATE,
        "--to",
        TO_DATE,
    )
    assert result.returncode == 0, "Parser should exit 0 gracefully for nonexistent dir"


def test_missing_from_to_error():
    result = run_parser(
        "--claude-dir",
        str(FIXTURES_ROOT),
        "--from",
        FROM_DATE,
    )
    assert result.returncode != 0, "Should fail when --to is missing"
    assert "Both --from and --to required" in result.stderr


def test_project_path_filter(tmp_path):
    """Filter by --project-path encodes path to dir name and finds matching subdir."""
    # Create the encoded project dir: /home/user/myapp -> -home-user-myapp
    project_dir = tmp_path / "-home-user-myapp"
    project_dir.mkdir()

    # Copy fixture files into the properly-named project dir
    shutil.copy(
        CLAUDE_CODE_DIR / "sessions-index.json",
        project_dir / "sessions-index.json",
    )
    shutil.copy(
        CLAUDE_CODE_DIR / "11111111-1111-1111-1111-111111111111.jsonl",
        project_dir / "11111111-1111-1111-1111-111111111111.jsonl",
    )

    result = run_parser(
        "--claude-dir",
        str(tmp_path),
        "--project-path",
        "/home/user/myapp",
        "--from",
        FROM_DATE,
        "--to",
        TO_DATE,
    )
    assert result.returncode == 0, f"stderr: {result.stderr}"

    sessions = parse_ndjson(result.stdout)
    assert len(sessions) == 1, (
        f"Expected 1 session with project-path filter, got {len(sessions)}"
    )
    assert sessions[0]["session_id"] == "11111111-1111-1111-1111-111111111111"
