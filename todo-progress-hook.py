#!/usr/bin/env python3
"""PostToolUse hook: record todo progress, and count tool calls.

Runs for every tool call, not just `TodoWrite`, because it keeps two signals:

- `TodoWrite` calls write "<done>/<total>" to /tmp/claude-progress-<session_id>.
  That is measured progress and the status line prefers it.
- Every call appends one byte to /tmp/claude-activity-<session_id>, whose size
  is the turn's tool-call count. That is the estimate the status line falls
  back to when the turn has no todo list.

One appended byte, rather than a number rewritten in place: `O_APPEND` writes
cannot interleave, so overlapping tool calls each get counted, where a
read-modify-write counter would lose increments.

Exits 0 unconditionally so a failure here never blocks a tool call.
"""
import json
import os
import sys


def write_todo_ratio(session, todos):
    done = sum(1 for t in todos if t.get("status") == "completed")
    # O_NOFOLLOW: /tmp is world-writable, so a symlink pre-planted at this
    # path would otherwise make us truncate whatever it points at.
    path = f"/tmp/claude-progress-{session}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW
    with os.fdopen(os.open(path, flags, 0o600), "w") as f:
        f.write(f"{done}/{len(todos)}")


def count_tool_call(session):
    path = f"/tmp/claude-activity-{session}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW
    with os.fdopen(os.open(path, flags, 0o600), "wb") as f:
        f.write(b"\0")


def main():
    try:
        data = json.load(sys.stdin)
        session = data["session_id"]
    except Exception:
        return

    if data.get("tool_name") == "TodoWrite":
        try:
            write_todo_ratio(session, data["tool_input"]["todos"])
        except Exception:
            pass

    try:
        count_tool_call(session)
    except Exception:
        pass


if __name__ == "__main__":
    main()
    sys.exit(0)
