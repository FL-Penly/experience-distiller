"""Tests for scripts/parse_opencode.py — subprocess-based CLI integration tests."""

import json
import subprocess
import sys
from pathlib import Path

SCRIPTS = Path(__file__).parent.parent / "scripts"
FIXTURES = Path(__file__).parent / "fixtures" / "opencode"

# Fixture timestamp 1740052800000 = 2025-02-20T12:00:00Z
# ses_empty001: 1740060000000 = 2025-02-20T14:00:00Z
# ses_old001:   1577836800000 = 2020-01-01T00:00:00Z
FROM_DATE = "2025-02-20"
TO_DATE = "2025-02-21"


def run_parser(*args):
    """Run parse_opencode.py as a subprocess and return CompletedProcess."""
    result = subprocess.run(
        [sys.executable, str(SCRIPTS / "parse_opencode.py"), *args],
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
        "--sessions-dir",
        str(FIXTURES),
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
    assert len(sessions) == 1, f"Expected 1 session, got {len(sessions)}: {sessions}"

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
    assert session["source"] == "opencode"
    assert session["session_id"] == "ses_normal001"
    assert len(session["messages"]) >= 2
    assert session["messages"][0]["role"] == "user"
    assert session["messages"][1]["role"] == "assistant"


def test_normal_session_has_tool_calls():
    result = run_normal()
    assert result.returncode == 0

    sessions = parse_ndjson(result.stdout)
    assert len(sessions) == 1

    assistant_msg = sessions[0]["messages"][1]
    assert assistant_msg["role"] == "assistant"
    assert "tool_calls" in assistant_msg, "Assistant message missing tool_calls"
    assert len(assistant_msg["tool_calls"]) >= 1
    assert assistant_msg["tool_calls"][0]["tool"] == "bash"


def test_empty_session_skipped():
    result = run_normal()
    assert result.returncode == 0

    sessions = parse_ndjson(result.stdout)
    session_ids = [s["session_id"] for s in sessions]
    assert "ses_empty001" not in session_ids, (
        "Empty session (only step-start/finish parts) should be skipped"
    )


def test_time_range_filters_old_session():
    result = run_normal()
    assert result.returncode == 0

    sessions = parse_ndjson(result.stdout)
    session_ids = [s["session_id"] for s in sessions]
    assert "ses_old001" not in session_ids, (
        "Old session (2020) should be filtered out by date range"
    )


def test_no_sessions_in_range():
    result = run_parser(
        "--sessions-dir",
        str(FIXTURES),
        "--from",
        "1999-01-01",
        "--to",
        "1999-01-02",
    )
    assert result.returncode == 0
    assert result.stdout.strip() == "", (
        f"Expected empty stdout for out-of-range query, got: {result.stdout!r}"
    )


def test_nonexistent_sessions_dir():
    result = run_parser(
        "--sessions-dir",
        "/nonexistent/path/xyz",
        "--from",
        FROM_DATE,
        "--to",
        TO_DATE,
    )
    assert result.returncode == 0, "Parser should exit 0 gracefully for nonexistent dir"


def test_missing_from_or_to_errors():
    result = run_parser(
        "--sessions-dir",
        str(FIXTURES),
        "--from",
        FROM_DATE,
    )
    assert result.returncode != 0, "Should fail when --to is missing"
    assert "Both --from and --to required" in result.stderr


def test_project_hash_filter():
    result = run_parser(
        "--sessions-dir",
        str(FIXTURES),
        "--project-hash",
        "abc123",
        "--from",
        FROM_DATE,
        "--to",
        TO_DATE,
    )
    assert result.returncode == 0

    sessions = parse_ndjson(result.stdout)
    assert len(sessions) == 1, (
        f"Expected 1 session with hash abc123, got {len(sessions)}"
    )
    assert sessions[0]["session_id"] == "ses_normal001"


def test_project_hash_wrong():
    result = run_parser(
        "--sessions-dir",
        str(FIXTURES),
        "--project-hash",
        "wronghash",
        "--from",
        FROM_DATE,
        "--to",
        TO_DATE,
    )
    assert result.returncode == 0
    assert result.stdout.strip() == "", "Wrong project hash should return no sessions"


def test_assistant_text_concatenated():
    result = run_normal()
    assert result.returncode == 0

    sessions = parse_ndjson(result.stdout)
    assert len(sessions) == 1

    assistant_msg = sessions[0]["messages"][1]
    content = assistant_msg["content"]

    # prt_002 text (first text part of assistant msg_002)
    assert "JWKS" in content, "Assistant content should include text from prt_002"
    # prt_004 text (second text part of assistant msg_002)
    assert "jwk.Fetch" in content, "Assistant content should include text from prt_004"
    # Both parts concatenated with newline
    assert "\n" in content, "Multiple text parts should be joined with newline"
