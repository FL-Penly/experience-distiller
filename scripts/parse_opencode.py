#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Parse OpenCode session storage and output unified JSON to stdout.

Supports two storage backends (auto-detected):
  1. SQLite (new, v1.1+): opencode.db in the opencode data directory
  2. File-based (legacy): session/message/part directories

Usage:
    python3 parse_opencode.py --sessions-dir PATH --from ISO_DATE --to ISO_DATE [OPTIONS]

Options:
    --sessions-dir PATH     Path to OpenCode storage/ directory (legacy) or data dir containing opencode.db
    --from DATE             Start date (ISO 8601: YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DD)
    --to DATE               End date
    --project-path PATH     Filter to sessions from this project directory (recommended)
    --project-hash HASH     Legacy: filter to a single project hash (file-based only)
    --verbose               Print debug info to stderr

Output: newline-delimited JSON (one session object per line).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from glob import glob


def warn(msg):
    print(msg, file=sys.stderr)


def verbose_log(msg, is_verbose):
    if is_verbose:
        print(f"[DEBUG] {msg}", file=sys.stderr)


def parse_iso_date(s):
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            dt = datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
            return int(dt.timestamp() * 1000)
        except ValueError:
            continue
    raise ValueError(
        f"Cannot parse date: {s!r} (expected YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DD)"
    )


def ms_to_iso(ms):
    return datetime.utcfromtimestamp(ms / 1000).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        warn(f"Corrupt JSON file: {path} ({e})")
        return None
    except OSError as e:
        warn(f"Cannot read file: {path} ({e})")
        return None


def truncate(s, max_len=200):
    if not isinstance(s, str):
        s = json.dumps(s, ensure_ascii=False) if s is not None else ""
    if len(s) > max_len:
        return s[: max_len - 3] + "..."
    return s


def get_nested(obj, *keys, default=None):
    cur = obj
    for k in keys:
        if not isinstance(cur, dict):
            return default
        cur = cur.get(k)
        if cur is None:
            return default
    return cur


# ══════════════════════════════════════════════════════════════════════════════
# SHARED: Part processing (same JSON structure in both backends)
# ══════════════════════════════════════════════════════════════════════════════


def process_parts(parts):
    """Convert part objects → (content_str, tool_calls_list)."""
    text_pieces = []
    tool_calls = []

    for part in parts:
        ptype = part.get("type")

        if ptype == "text":
            text = part.get("text", "")
            if text:
                text_pieces.append(text)

        elif ptype == "reasoning":
            reasoning = part.get("reasoning", "")
            if reasoning:
                text_pieces.append(f"[thinking] {reasoning}")

        elif ptype == "tool":
            tool_name = part.get("tool", "")
            state = part.get("state", {})
            if not isinstance(state, dict):
                state = {}
            tool_input = state.get("input", "")
            tool_output = state.get("output", "")
            tool_calls.append(
                {
                    "tool": tool_name,
                    "input": truncate(tool_input),
                    "output": truncate(tool_output),
                }
            )

    content = "\n".join(text_pieces)
    return content, tool_calls


def build_session_result(
    session_id,
    directory,
    title,
    time_created,
    time_updated,
    unified_messages,
    parent_id=None,
):
    """Build the standard NDJSON output object."""
    obj = {
        "source": "opencode",
        "session_id": session_id,
        "project": directory,
        "title": title,
        "time_start": ms_to_iso(time_created)
        if isinstance(time_created, (int, float))
        else "",
        "time_end": ms_to_iso(time_updated)
        if isinstance(time_updated, (int, float))
        else "",
        "messages": unified_messages,
    }
    if parent_id:
        obj["parent_id"] = parent_id
    return obj


# ══════════════════════════════════════════════════════════════════════════════
# BACKEND 1: SQLite (new format, opencode v1.1+)
# ══════════════════════════════════════════════════════════════════════════════


def find_db_path(sessions_dir):
    """Auto-detect opencode.db from sessions_dir or its parent."""
    candidates = [
        os.path.join(sessions_dir, "opencode.db"),
        os.path.join(os.path.dirname(sessions_dir), "opencode.db"),
    ]
    for p in candidates:
        if os.path.isfile(p):
            return p
    return None


def parse_sqlite(db_path, from_ms, to_ms, project_path_filter, verbose):
    """Read sessions from SQLite opencode.db and yield NDJSON objects."""
    try:
        import sqlite3
    except ImportError:
        warn("sqlite3 module not available")
        return

    verbose_log(f"Using SQLite backend: {db_path}", verbose)

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    try:
        if project_path_filter:
            proj = project_path_filter.rstrip("/")
            rows = conn.execute(
                """
                SELECT id, parent_id, directory, title, time_created, time_updated
                FROM session
                WHERE directory = ?
                  AND time_created >= ?
                  AND time_created <= ?
                  AND time_archived IS NULL
                ORDER BY time_created ASC
                """,
                (proj, from_ms, to_ms),
            ).fetchall()
        else:
            rows = conn.execute(
                """
                SELECT id, parent_id, directory, title, time_created, time_updated
                FROM session
                WHERE time_created >= ?
                  AND time_created <= ?
                  AND time_archived IS NULL
                ORDER BY time_created ASC
                """,
                (from_ms, to_ms),
            ).fetchall()

        verbose_log(f"SQLite: found {len(rows)} sessions in range", verbose)

        for row in rows:
            sid = row["id"]
            parent_id = row["parent_id"] or None
            directory = row["directory"] or ""
            title = row["title"] or ""
            time_created = row["time_created"]
            time_updated = row["time_updated"]

            msg_rows = conn.execute(
                """
                SELECT id, data, time_created
                FROM message
                WHERE session_id = ?
                ORDER BY time_created ASC
                """,
                (sid,),
            ).fetchall()

            if not msg_rows:
                verbose_log(f"Session {sid} has no messages, skipping", verbose)
                continue

            unified_messages = []
            for msg_row in msg_rows:
                mid = msg_row["id"]
                try:
                    msg_data = json.loads(msg_row["data"])
                except (json.JSONDecodeError, TypeError):
                    verbose_log(f"Corrupt message data for {mid}, skipping", verbose)
                    continue

                role = msg_data.get("role", "")
                msg_time = get_nested(msg_data, "time", "created")

                part_rows = conn.execute(
                    """
                    SELECT data
                    FROM part
                    WHERE message_id = ?
                    ORDER BY time_created ASC
                    """,
                    (mid,),
                ).fetchall()

                parts = []
                for pr in part_rows:
                    try:
                        parts.append(json.loads(pr["data"]))
                    except (json.JSONDecodeError, TypeError):
                        continue

                content, tool_calls = process_parts(parts)

                if not content and not tool_calls:
                    verbose_log(f"Empty message {mid}, skipping", verbose)
                    continue

                entry = {
                    "role": role,
                    "content": content,
                    "timestamp": ms_to_iso(msg_time)
                    if isinstance(msg_time, (int, float))
                    else "",
                }
                if tool_calls:
                    entry["tool_calls"] = tool_calls

                unified_messages.append(entry)

            if not unified_messages:
                verbose_log(f"Session {sid} has no text content, skipping", verbose)
                continue

            yield build_session_result(
                sid,
                directory,
                title,
                time_created,
                time_updated,
                unified_messages,
                parent_id=parent_id,
            )

    finally:
        conn.close()


# ══════════════════════════════════════════════════════════════════════════════
# BACKEND 2: File-based (legacy format)
# ══════════════════════════════════════════════════════════════════════════════


def discover_project_hashes(session_dir, project_hash_filter, verbose):
    session_base = os.path.join(session_dir, "session")
    if not os.path.isdir(session_base):
        verbose_log(f"No session/ directory at {session_base}", verbose)
        return []

    if project_hash_filter:
        target = os.path.join(session_base, project_hash_filter)
        if os.path.isdir(target):
            return [project_hash_filter]
        else:
            verbose_log(f"Project hash dir not found: {target}", verbose)
            return []

    hashes = []
    try:
        for entry in os.listdir(session_base):
            full = os.path.join(session_base, entry)
            if os.path.isdir(full):
                hashes.append(entry)
    except OSError as e:
        warn(f"Cannot list {session_base}: {e}")
    return hashes


def load_sessions(session_dir, project_hash, from_ms, to_ms, verbose):
    pattern = os.path.join(session_dir, "session", project_hash, "ses_*.json")
    files = glob(pattern)
    verbose_log(f"Found {len(files)} session files for hash {project_hash}", verbose)

    sessions = []
    for fpath in files:
        data = load_json(fpath)
        if data is None:
            continue

        time_created = get_nested(data, "time", "created")
        if time_created is None:
            warn(f"Missing time.created in session: {fpath}")
            continue

        if not isinstance(time_created, (int, float)):
            warn(
                f"Invalid time.created in session: {fpath} (got {type(time_created).__name__})"
            )
            continue

        time_created = int(time_created)
        if time_created < from_ms or time_created > to_ms:
            verbose_log(
                f"Session {data.get('id', '?')} outside date range, skipping", verbose
            )
            continue

        sessions.append(data)

    return sessions


def load_messages(session_dir, session_id, verbose):
    msg_dir = os.path.join(session_dir, "message", session_id)
    if not os.path.isdir(msg_dir):
        verbose_log(f"No message directory for {session_id}", verbose)
        return []

    pattern = os.path.join(msg_dir, "msg_*.json")
    files = glob(pattern)
    verbose_log(f"Found {len(files)} message files for {session_id}", verbose)

    messages = []
    for fpath in files:
        data = load_json(fpath)
        if data is None:
            continue
        messages.append(data)

    messages.sort(key=lambda m: get_nested(m, "time", "created", default=0))
    return messages


def load_parts(session_dir, message_id, verbose):
    part_dir = os.path.join(session_dir, "part", message_id)
    if not os.path.isdir(part_dir):
        verbose_log(f"No parts directory for {message_id}", verbose)
        return []

    pattern = os.path.join(part_dir, "prt_*.json")
    files = sorted(glob(pattern))
    verbose_log(f"Found {len(files)} part files for {message_id}", verbose)

    parts = []
    for fpath in files:
        data = load_json(fpath)
        if data is None:
            continue
        parts.append(data)

    return parts


def process_session_file(session_dir, session_data, project_path_filter, verbose):
    session_id = session_data.get("id", "")
    directory = session_data.get("directory", "")

    if project_path_filter and directory.rstrip("/") != project_path_filter.rstrip("/"):
        verbose_log(
            f"Session {session_id} dir {directory!r} != filter, skipping", verbose
        )
        return None

    verbose_log(f"Processing session {session_id}", verbose)

    raw_messages = load_messages(session_dir, session_id, verbose)
    if not raw_messages:
        verbose_log(f"No messages for session {session_id}, skipping", verbose)
        return None

    unified_messages = []
    for msg in raw_messages:
        msg_id = msg.get("id", "")
        role = msg.get("role", "")
        msg_time = get_nested(msg, "time", "created")

        parts = load_parts(session_dir, msg_id, verbose)
        content, tool_calls = process_parts(parts)

        if not content and not tool_calls:
            verbose_log(f"Empty message {msg_id}, skipping", verbose)
            continue

        entry = {
            "role": role,
            "content": content,
            "timestamp": ms_to_iso(msg_time)
            if isinstance(msg_time, (int, float))
            else "",
        }
        if tool_calls:
            entry["tool_calls"] = tool_calls

        unified_messages.append(entry)

    if not unified_messages:
        verbose_log(f"Session {session_id} has no text content, skipping", verbose)
        return None

    time_created = get_nested(session_data, "time", "created")
    time_updated = get_nested(session_data, "time", "updated")
    title = session_data.get("title") or session_data.get("slug") or ""

    return build_session_result(
        session_id, directory, title, time_created, time_updated, unified_messages
    )


def parse_file_based(
    session_dir, from_ms, to_ms, project_hash_filter, project_path_filter, verbose
):
    verbose_log(f"Using file-based backend: {session_dir}", verbose)
    project_hashes = discover_project_hashes(session_dir, project_hash_filter, verbose)
    verbose_log(f"Found {len(project_hashes)} project hashes", verbose)

    for phash in project_hashes:
        sessions = load_sessions(session_dir, phash, from_ms, to_ms, verbose)
        verbose_log(f"Hash {phash}: {len(sessions)} sessions in range", verbose)

        for session_data in sessions:
            result = process_session_file(
                session_dir, session_data, project_path_filter, verbose
            )
            if result is not None:
                yield result


def main():
    parser = argparse.ArgumentParser(
        description="Parse OpenCode session storage and output unified JSON."
    )
    parser.add_argument(
        "--sessions-dir",
        required=True,
        help="Path to OpenCode storage/ or data directory containing opencode.db",
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
        help="Filter to sessions from this project directory path",
    )
    parser.add_argument(
        "--project-hash",
        help="Legacy: filter to a single project hash (file-based backend only)",
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
        print("Both --from and --to required", file=sys.stderr)
        sys.exit(1)

    if not has_from:
        print("Both --from and --to required", file=sys.stderr)
        sys.exit(1)

    try:
        from_ms = parse_iso_date(args.from_date)
        to_ms = parse_iso_date(args.to_date)
    except ValueError as e:
        print(f"Date parse error: {e}", file=sys.stderr)
        sys.exit(1)

    sessions_dir = os.path.expanduser(args.sessions_dir)
    project_path = (
        os.path.expanduser(args.project_path).rstrip("/") if args.project_path else None
    )
    verbose = args.verbose

    verbose_log(f"Sessions dir: {sessions_dir}", verbose)
    verbose_log(f"Date range: {args.from_date} -> {args.to_date}", verbose)
    if project_path:
        verbose_log(f"Project path filter: {project_path}", verbose)

    db_path = find_db_path(sessions_dir)

    session_count = 0

    if db_path:
        for result in parse_sqlite(db_path, from_ms, to_ms, project_path, verbose):
            print(json.dumps(result, ensure_ascii=False))
            session_count += 1
    else:
        if not os.path.isdir(sessions_dir):
            warn(f"Sessions directory does not exist: {sessions_dir}")
            sys.exit(0)
        for result in parse_file_based(
            sessions_dir, from_ms, to_ms, args.project_hash, project_path, verbose
        ):
            print(json.dumps(result, ensure_ascii=False))
            session_count += 1

    if session_count == 0:
        warn(f"No sessions found for [{args.from_date} .. {args.to_date}]")


if __name__ == "__main__":
    main()
