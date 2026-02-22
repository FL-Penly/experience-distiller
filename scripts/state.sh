# scripts/state.sh — Per-project evolution state management.
# Source this file; do NOT execute directly.
#
# Functions:
#   state_load    "$project_path"
#   state_save    "$project_path" "$last_run_iso" "$ids_file" "$total" "$rules_count"
#   state_filter_new  "$ndjson_input_file" "$project_path"
#   state_mark_processed  "$project_path" "$new_ids_file" "$rules_count"
#
# State file location: <project>/.claude/evolution-state.json
# Temp IDs file:       $STATE_PROCESSED_IDS_FILE (set by state_load)

# ── Internal helpers ──────────────────────────────────────────────────────────
_state_file() { echo "${1%/}/.claude/evolution-state.json"; }
_state_dir()  { echo "${1%/}/.claude"; }

# ── state_load: read state JSON into shell variables ──────────────────────────
# Sets: STATE_LAST_RUN, STATE_TOTAL, STATE_RULES_COUNT, STATE_PROCESSED_IDS_FILE
# On missing/corrupt file: silent defaults (empty last_run, 0 total, 0 rules).
state_load() {
  local project_path="${1:?state_load: missing project_path}"
  local state_file
  state_file="$(_state_file "$project_path")"

  STATE_PROCESSED_IDS_FILE=$(mktemp /tmp/evolution_ids.XXXXXX)

  eval "$(python3 - "$state_file" "$STATE_PROCESSED_IDS_FILE" << 'PYEOF'
import json, sys

state_file = sys.argv[1]
ids_file   = sys.argv[2]

try:
    with open(state_file) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError, OSError):
    data = {}

last_run    = data.get("last_run") or ""
total       = data.get("total_sessions_processed") or 0
rules_count = data.get("rules_count") or 0
ids         = data.get("processed_session_ids", [])

# Write IDs to temp file (one per line)
with open(ids_file, "w") as f:
    for sid in ids:
        if sid:
            f.write(sid + "\n")

# Output shell-eval-able assignments (single-quote safe)
print("STATE_LAST_RUN='{}'".format(last_run.replace("'", "'\\'''")))
print("STATE_TOTAL={}".format(int(total)))
print("STATE_RULES_COUNT={}".format(int(rules_count)))
PYEOF
)"

  export STATE_LAST_RUN STATE_TOTAL STATE_RULES_COUNT STATE_PROCESSED_IDS_FILE
}

# ── state_save: write state JSON atomically ───────────────────────────────────
# Args: project_path last_run_iso ids_file total rules_count
state_save() {
  local project_path="${1:?state_save: missing project_path}"
  local last_run="${2:-}"
  local ids_file="${3:-/dev/null}"
  local total="${4:-0}"
  local rules_count="${5:-0}"
  local state_file
  state_file="$(_state_file "$project_path")"

  mkdir -p "$(_state_dir "$project_path")"

  python3 - "$state_file" "$last_run" "$ids_file" "$total" "$rules_count" << 'PYEOF'
import json, sys, os

state_file  = sys.argv[1]
last_run    = sys.argv[2]
ids_file    = sys.argv[3]
total       = int(sys.argv[4])
rules_count = int(sys.argv[5])

# Read IDs from file (one per line)
ids = []
try:
    with open(ids_file) as f:
        for line in f:
            sid = line.strip()
            if sid:
                ids.append(sid)
except (FileNotFoundError, OSError):
    ids = []

data = {
    "last_run": last_run,
    "processed_session_ids": sorted(set(ids)),
    "total_sessions_processed": total,
    "rules_count": rules_count,
}

tmp_file = state_file + ".tmp"
with open(tmp_file, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

os.replace(tmp_file, state_file)
PYEOF
}

# ── state_filter_new: emit NDJSON lines whose session_id is not yet processed ─
# Reads STATE_PROCESSED_IDS_FILE (set by state_load).
# Stdout: filtered NDJSON lines.  Stderr: __NEW_SESSION_COUNT__=N
state_filter_new() {
  local ndjson_input="${1:?state_filter_new: missing ndjson_input_file}"
  local project_path="$2"
  local ids_file="${STATE_PROCESSED_IDS_FILE:-/dev/null}"

  python3 - "$ndjson_input" "$ids_file" << 'PYEOF'
import json, sys

ndjson_file = sys.argv[1]
ids_file    = sys.argv[2]

# Load already-processed IDs
processed = set()
try:
    with open(ids_file) as f:
        for line in f:
            sid = line.strip()
            if sid:
                processed.add(sid)
except (FileNotFoundError, OSError):
    pass

new_count = 0
with open(ndjson_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        sid = obj.get("session_id", "")
        if sid not in processed:
            sys.stdout.write(line + "\n")
            new_count += 1

sys.stderr.write("__NEW_SESSION_COUNT__={}\n".format(new_count))
PYEOF
}

# ── state_mark_processed: merge new IDs into state, update counters ───────────
# Args: project_path new_ids_file rules_count
state_mark_processed() {
  local project_path="${1:?state_mark_processed: missing project_path}"
  local new_ids_file="${2:?state_mark_processed: missing new_ids_file}"
  local rules_count="${3:-0}"
  local state_file
  state_file="$(_state_file "$project_path")"

  mkdir -p "$(_state_dir "$project_path")"

  python3 - "$state_file" "$new_ids_file" "$rules_count" << 'PYEOF'
import json, sys, os
from datetime import datetime, timezone

state_file     = sys.argv[1]
new_ids_file   = sys.argv[2]
new_rules_count = int(sys.argv[3])

# Read existing state
try:
    with open(state_file) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError, OSError):
    data = {"processed_session_ids": [], "total_sessions_processed": 0}

# Read new IDs
new_ids = []
try:
    with open(new_ids_file) as f:
        for line in f:
            sid = line.strip()
            if sid:
                new_ids.append(sid)
except (FileNotFoundError, OSError):
    new_ids = []

# Deduplicate and merge
existing_set = set(data.get("processed_session_ids", []))
for sid in new_ids:
    existing_set.add(sid)

data["processed_session_ids"] = sorted(existing_set)
data["last_run"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
data["total_sessions_processed"] = data.get("total_sessions_processed", 0) + len(new_ids)
data["rules_count"] = new_rules_count

# Atomic write
tmp_file = state_file + ".tmp"
with open(tmp_file, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

os.replace(tmp_file, state_file)
PYEOF
}
