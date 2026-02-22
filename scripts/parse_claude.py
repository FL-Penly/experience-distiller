#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Parse Claude Code session storage and output unified JSON to stdout.

Usage:
    python3 parse_claude.py --claude-dir PATH --from ISO_DATE --to ISO_DATE [--project-path PATH] [--verbose]

Output: newline-delimited JSON (one session object per line).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone


def warn(msg):
    print(msg, file=sys.stderr)


def verbose_log(msg, is_verbose):
    if is_verbose:
        print("[DEBUG] {}".format(msg), file=sys.stderr)


def parse_iso_date(s):
    """Parse ISO date string to aware datetime.

    Accepts YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DD.
    """
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            dt = datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue
    raise ValueError(
        "Cannot parse date: {!r} (expected YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DD)".format(
            s
        )
    )


def parse_timestamp(ts):
    """Parse a Claude Code ISO 8601 timestamp string to aware datetime.

    Handles formats like '2026-02-12T03:52:07.396Z' with fractional seconds.
    Returns None on failure.
    """
    if not ts or not isinstance(ts, str):
        return None
    try:
        cleaned = ts.replace("Z", "+00:00")
        return datetime.fromisoformat(cleaned)
    except (ValueError, AttributeError):
        return None


def dt_to_iso(dt):
    """Convert datetime to ISO 8601 string (UTC, no fractional seconds)."""
    if dt is None:
        return ""
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def truncate(s, max_len=200):
    """Truncate string to max_len chars, adding '...' if truncated."""
    if not isinstance(s, str):
        s = json.dumps(s, ensure_ascii=False) if s is not None else ""
    if len(s) > max_len:
        return s[: max_len - 3] + "..."
    return s


def encode_project_path(project_path):
    """Encode a project path to Claude Code's directory name format.

    /data00/home/user.name/project_x -> -data00-home-user-name-project-x
    Leading slash becomes leading dash; slashes, dots, underscores → dashes.
    """
    import re as _re

    expanded = os.path.expanduser(project_path)
    expanded = expanded.rstrip("/")
    if expanded.startswith("/"):
        body = _re.sub(r"[/._]", "-", expanded[1:])
        return "-" + body
    return _re.sub(r"[/._]", "-", expanded)


def discover_project_dirs(claude_dir, project_path_filter, verbose):
    """List project subdirectories under claude_dir.

    If project_path_filter is given, encode it and look for that specific subdir.
    Returns list of (dir_path, project_path_decoded) tuples.
    """
    if not os.path.isdir(claude_dir):
        verbose_log("Claude dir not found: {}".format(claude_dir), verbose)
        return []

    if project_path_filter:
        encoded = encode_project_path(project_path_filter)
        target = os.path.join(claude_dir, encoded)
        if os.path.isdir(target):
            verbose_log("Found project dir: {}".format(target), verbose)
            return [(target, project_path_filter)]
        else:
            verbose_log("Project dir not found: {}".format(target), verbose)
            return []

    result = []
    try:
        for entry in sorted(os.listdir(claude_dir)):
            full = os.path.join(claude_dir, entry)
            if os.path.isdir(full):
                if entry.startswith("-"):
                    decoded = "/" + entry[1:].replace("-", "/")
                else:
                    decoded = entry
                result.append((full, decoded))
    except OSError as e:
        warn("Cannot list {}: {}".format(claude_dir, e))
    return result


def load_sessions_index(project_dir, verbose):
    """Load sessions-index.json from a project directory.

    Returns the parsed dict or None if not found/corrupt.
    """
    index_path = os.path.join(project_dir, "sessions-index.json")
    if not os.path.isfile(index_path):
        verbose_log("No sessions-index.json in {}".format(project_dir), verbose)
        return None
    try:
        with open(index_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        warn("Corrupt sessions-index.json: {} ({})".format(index_path, e))
        return None
    except OSError as e:
        warn("Cannot read: {} ({})".format(index_path, e))
        return None


def filter_sessions_by_index(index_data, from_dt, to_dt, verbose):
    """Filter session entries from index by time range.

    Returns list of matching index entries.
    Skips isSidechain sessions.
    """
    entries = index_data.get("entries", [])
    if not isinstance(entries, list):
        return []

    matched = []
    for entry in entries:
        session_id = entry.get("sessionId", "")

        if entry.get("isSidechain", False):
            verbose_log("Skipping sidechain session: {}".format(session_id), verbose)
            continue

        if entry.get("isMeta", False):
            verbose_log("Skipping meta session: {}".format(session_id), verbose)
            continue

        created_str = entry.get("created", "")
        modified_str = entry.get("modified", "")

        created_dt = parse_timestamp(created_str)
        modified_dt = parse_timestamp(modified_str)

        if created_dt and created_dt > to_dt:
            verbose_log(
                "Session {} created after range, skipping".format(session_id), verbose
            )
            continue
        if modified_dt and modified_dt < from_dt:
            verbose_log(
                "Session {} modified before range, skipping".format(session_id), verbose
            )
            continue
        if not created_dt and not modified_dt:
            verbose_log(
                "Session {} has no timestamps, including".format(session_id), verbose
            )

        matched.append(entry)

    return matched


def discover_jsonl_sessions(project_dir, from_dt, to_dt, verbose):
    """Fallback: discover sessions from .jsonl files when no index is available.

    Uses file mtime for filtering. Returns list of pseudo-index entries.
    """
    entries = []
    try:
        for fname in os.listdir(project_dir):
            if not fname.endswith(".jsonl"):
                continue
            fpath = os.path.join(project_dir, fname)
            if not os.path.isfile(fpath):
                continue

            session_id = fname[: -len(".jsonl")]
            mtime = os.path.getmtime(fpath)
            mtime_dt = datetime.utcfromtimestamp(mtime).replace(tzinfo=timezone.utc)

            if mtime_dt < from_dt:
                verbose_log(
                    "JSONL {} mtime before range, skipping".format(fname), verbose
                )
                continue

            entries.append(
                {
                    "sessionId": session_id,
                    "created": "",
                    "modified": dt_to_iso(mtime_dt),
                    "firstPrompt": "",
                    "summary": "",
                    "projectPath": "",
                    "isSidechain": False,
                }
            )
    except OSError as e:
        warn("Cannot list {}: {}".format(project_dir, e))
    return entries


def extract_user_content(message):
    """Extract text content from a user message.

    message.content can be a string or array of content blocks.
    """
    content = (
        message.get("message", {}).get("content")
        if isinstance(message.get("message"), dict)
        else None
    )
    if content is None:
        return ""

    if isinstance(content, str):
        return content

    if isinstance(content, list):
        pieces = []
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type", "")
            if btype == "text":
                text = block.get("text", "")
                if text:
                    pieces.append(text)
            elif btype == "tool_result":
                inner = block.get("content", "")
                if isinstance(inner, str):
                    pieces.append("[Tool result: {}]".format(truncate(inner)))
                elif isinstance(inner, list):
                    inner_texts = []
                    for ib in inner:
                        if isinstance(ib, dict) and ib.get("type") == "text":
                            inner_texts.append(ib.get("text", ""))
                    if inner_texts:
                        pieces.append(
                            "[Tool result: {}]".format(truncate("\n".join(inner_texts)))
                        )
        return "\n".join(pieces)

    return ""


def extract_assistant_content(message):
    """Extract text and tool_calls from an assistant message.

    message.content is always an array of blocks.
    Returns (text, tool_calls_list).
    """
    msg_obj = message.get("message", {})
    if not isinstance(msg_obj, dict):
        return "", []

    content = msg_obj.get("content")
    if content is None or not isinstance(content, list):
        return "", []

    text_pieces = []
    tool_calls = []

    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type", "")

        if btype == "text":
            text = block.get("text", "")
            if text:
                text_pieces.append(text)
        elif btype == "tool_use":
            tool_name = block.get("name", "")
            tool_input = block.get("input", {})
            tool_calls.append(
                {
                    "tool": tool_name,
                    "input": truncate(
                        json.dumps(tool_input, ensure_ascii=False)
                        if isinstance(tool_input, dict)
                        else str(tool_input)
                    ),
                    "output": "",
                }
            )
        elif btype == "thinking":
            continue

    return "\n".join(text_pieces), tool_calls


def process_jsonl_session(jsonl_path, index_entry, project_path, verbose):
    """Process a single .jsonl session file into unified output format.

    Returns the unified dict or None if the session should be skipped.
    """
    session_id = index_entry.get("sessionId", "")
    verbose_log("Processing JSONL: {}".format(jsonl_path), verbose)

    messages = []
    line_num = 0

    try:
        with open(jsonl_path, "r", encoding="utf-8") as f:
            for raw_line in f:
                line_num += 1
                raw_line = raw_line.strip()
                if not raw_line:
                    continue

                try:
                    record = json.loads(raw_line)
                except json.JSONDecodeError as e:
                    warn(
                        "Corrupt JSONL line {} in {}: {}".format(
                            line_num, jsonl_path, e
                        )
                    )
                    continue

                if not isinstance(record, dict):
                    continue

                rtype = record.get("type", "")
                timestamp_str = record.get("timestamp", "")
                ts_dt = parse_timestamp(timestamp_str)
                ts_iso = dt_to_iso(ts_dt)

                if rtype == "user":
                    content = extract_user_content(record)
                    if content:
                        messages.append(
                            {
                                "role": "user",
                                "content": content,
                                "timestamp": ts_iso,
                            }
                        )

                elif rtype == "assistant":
                    text, tool_calls = extract_assistant_content(record)
                    if text or tool_calls:
                        msg_entry = {
                            "role": "assistant",
                            "content": text,
                            "timestamp": ts_iso,
                        }  # type: dict[str, object]
                        if tool_calls:
                            msg_entry["tool_calls"] = tool_calls
                        messages.append(msg_entry)

    except OSError as e:
        warn("Cannot read JSONL: {} ({})".format(jsonl_path, e))
        return None

    if not messages:
        verbose_log(
            "Session {} has no user/assistant messages, skipping".format(session_id),
            verbose,
        )
        return None

    title = (
        index_entry.get("firstPrompt", "")
        or index_entry.get("summary", "")
        or session_id
    )

    created_str = index_entry.get("created", "")
    modified_str = index_entry.get("modified", "")
    time_start = dt_to_iso(parse_timestamp(created_str))
    time_end = dt_to_iso(parse_timestamp(modified_str))

    if not time_start and messages:
        time_start = messages[0].get("timestamp", "")
    if not time_end and messages:
        time_end = messages[-1].get("timestamp", "")

    effective_project = index_entry.get("projectPath", "") or project_path

    return {
        "source": "claude-code",
        "session_id": session_id,
        "project": effective_project,
        "title": title,
        "time_start": time_start,
        "time_end": time_end,
        "messages": messages,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Parse Claude Code session storage and output unified JSON."
    )
    parser.add_argument(
        "--claude-dir",
        required=True,
        help="Path to ~/.claude/projects/ directory",
    )
    parser.add_argument(
        "--from",
        dest="from_date",
        help="Start date (ISO 8601: YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DD)",
    )
    parser.add_argument(
        "--to",
        dest="to_date",
        help="End date (ISO 8601: YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DD)",
    )
    parser.add_argument(
        "--project-path",
        help="Optional: filter to a specific project path (e.g. /data00/home/user/myproject)",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print debug info to stderr",
    )

    args = parser.parse_args()

    has_from = args.from_date is not None
    has_to = args.to_date is not None
    if has_from != has_to:
        warn("Both --from and --to required")
        sys.exit(1)
    if not has_from:
        warn("Both --from and --to required")
        sys.exit(1)

    try:
        from_dt = parse_iso_date(args.from_date)
        to_dt = parse_iso_date(args.to_date)
    except ValueError as e:
        warn("Date parse error: {}".format(e))
        sys.exit(1)

    claude_dir = os.path.expanduser(args.claude_dir)
    if not os.path.isdir(claude_dir):
        warn("Claude directory does not exist: {}".format(claude_dir))
        sys.exit(0)

    verbose = args.verbose
    verbose_log("Claude dir: {}".format(claude_dir), verbose)
    verbose_log("Date range: {} -> {}".format(args.from_date, args.to_date), verbose)

    project_dirs = discover_project_dirs(claude_dir, args.project_path, verbose)
    verbose_log("Found {} project directories".format(len(project_dirs)), verbose)

    session_count = 0

    for project_dir_path, project_path_decoded in project_dirs:
        verbose_log("Scanning project dir: {}".format(project_dir_path), verbose)

        index_data = load_sessions_index(project_dir_path, verbose)

        if index_data is not None:
            matched_entries = filter_sessions_by_index(
                index_data, from_dt, to_dt, verbose
            )
            verbose_log(
                "Index has {} matching sessions".format(len(matched_entries)), verbose
            )
        else:
            matched_entries = discover_jsonl_sessions(
                project_dir_path, from_dt, to_dt, verbose
            )
            verbose_log(
                "Fallback: found {} .jsonl files".format(len(matched_entries)), verbose
            )

        for entry in matched_entries:
            session_id = entry.get("sessionId", "")
            if not session_id:
                continue

            jsonl_path = os.path.join(project_dir_path, session_id + ".jsonl")
            if not os.path.isfile(jsonl_path):
                full_path = entry.get("fullPath", "")
                if full_path and os.path.isfile(full_path):
                    jsonl_path = full_path
                else:
                    warn(
                        "JSONL file not found for session {}: {}".format(
                            session_id, jsonl_path
                        )
                    )
                    continue

            result = process_jsonl_session(
                jsonl_path, entry, project_path_decoded, verbose
            )
            if result is not None:
                sys.stdout.write(json.dumps(result, ensure_ascii=False))
                sys.stdout.write("\n")
                session_count += 1

    if session_count == 0:
        warn("No sessions found for [{} .. {}]".format(args.from_date, args.to_date))


if __name__ == "__main__":
    main()
