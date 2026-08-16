#!/usr/bin/env python3
"""PostToolUse hook for TodoWrite: record completed/total to a state file.
 
The status line reads /tmp/claude-progress-<session_id> to draw its bar.
Exits 0 unconditionally so a failure here never blocks a tool call.
"""
import json
import sys
 
 
def main():
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name") != "TodoWrite":
            return
        todos = data["tool_input"]["todos"]
        done = sum(1 for t in todos if t.get("status") == "completed")
        with open(f"/tmp/claude-progress-{data['session_id']}", "w") as f:
            f.write(f"{done}/{len(todos)}")
    except Exception:
        pass
 
 
if __name__ == "__main__":
    main()
    sys.exit(0)