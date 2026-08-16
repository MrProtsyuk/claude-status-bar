#!/usr/bin/env bash
# Test battery for the status line and its hooks.
# Every case in DESIGN.md section 8, plus the busy-state hint row and the
# symlink guards. Run from the repo root: ./test.sh
set -u

PASS=0
FAIL=0
S=test-$$

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n' "$1"
    printf '       expected: %s\n' "$2"
    printf '       actual:   %s\n' "$3"
}

# assert_contains <name> <needle> <haystack>
assert_contains() {
    case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "contains '$2'" "$3" ;;
    esac
}

# assert_equals <name> <expected> <actual>
assert_equals() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

# Strip ANSI escapes so assertions match on visible text.
plain() { sed $'s/\033\\[[0-9;]*m//g'; }

todo_json() { printf '{"session_id":"%s","tool_name":"TodoWrite","tool_input":{"todos":[%s]}}' "$1" "$2"; }
status_json() { printf '{"session_id":"%s","model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/x/demo"},"context_window":{"used_percentage":%s}}' "$1" "$2"; }
hook_json() { printf '{"session_id":"%s","hook_event_name":"%s"}' "$1" "$2"; }

cleanup() { rm -f "/tmp/claude-progress-$S" "/tmp/claude-busy-$S"; }
trap cleanup EXIT
cleanup

echo "== todo progress hook =="

out=$(todo_json "$S" '{"status":"completed"},{"status":"completed"},{"status":"in_progress"},{"status":"pending"},{"status":"pending"}' | ./todo-progress-hook.py)
assert_equals "hook exits 0" "0" "$?"
assert_equals "hook writes done/total" "2/5" "$(cat "/tmp/claude-progress-$S")"
assert_equals "state file is 0600" "-rw-------" "$(stat -f '%Sp' "/tmp/claude-progress-$S")"
assert_equals "hook prints nothing" "" "$out"

echo 'not json' | ./todo-progress-hook.py >/dev/null 2>&1
assert_equals "hook survives non-JSON stdin" "0" "$?"

printf '{"session_id":"%s","tool_name":"Read","tool_input":{}}' "$S" | ./todo-progress-hook.py
assert_equals "non-TodoWrite tool leaves state intact" "2/5" "$(cat "/tmp/claude-progress-$S")"

echo "== status line: progress bar =="

line1=$(status_json "$S" 42 | ./statusline-progress.py | head -1 | plain)
assert_contains "todo mode shows ratio" "40% (2/5 tasks)" "$line1"
assert_contains "todo mode fills 5 of 12 cells" "█████░░░░░░░" "$line1"

line1=$(status_json "no-such-session" 42 | ./statusline-progress.py | head -1 | plain)
assert_contains "falls back to context" "42% context" "$line1"

line1=$(printf '{"session_id":"none","model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/x/demo"},"context_window":{"used_percentage":null}}' | ./statusline-progress.py | head -1 | plain)
assert_contains "null used_percentage renders 0%" "0% context" "$line1"

todo_json "$S" '' | ./todo-progress-hook.py
line1=$(status_json "$S" 7 | ./statusline-progress.py | head -1 | plain)
assert_contains "empty todo list does not divide by zero" "7% context" "$line1"

echo "== status line: hint row =="

rm -f "/tmp/claude-busy-$S"
out=$(status_json "$S" 7 | ./statusline-progress.py | plain)
assert_equals "idle prints two rows" "2" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_equals "idle hint row omits interrupt" "? for shortcuts" "$(printf '%s\n' "$out" | tail -1)"

hook_json "$S" UserPromptSubmit | ./busy-state-hook.py
out=$(status_json "$S" 7 | ./statusline-progress.py | plain)
assert_equals "busy hint row offers interrupt" "esc to interrupt · ? for shortcuts" "$(printf '%s\n' "$out" | tail -1)"

hook_json "$S" Stop | ./busy-state-hook.py
assert_equals "Stop clears busy flag" "? for shortcuts" "$(status_json "$S" 7 | ./statusline-progress.py | plain | tail -1)"

hook_json "$S" UserPromptSubmit | ./busy-state-hook.py
hook_json "$S" StopFailure | ./busy-state-hook.py
assert_equals "StopFailure clears busy flag" "? for shortcuts" "$(status_json "$S" 7 | ./statusline-progress.py | plain | tail -1)"

echo "== busy-state hook contract =="

out=$(hook_json "$S" UserPromptSubmit | ./busy-state-hook.py)
assert_equals "hook exits 0" "0" "$?"
# UserPromptSubmit stdout is injected into the conversation as context.
assert_equals "hook prints nothing on stdout" "" "$out"
assert_equals "busy file is 0600" "-rw-------" "$(stat -f '%Sp' "/tmp/claude-busy-$S")"

hook_json "$S" Stop | ./busy-state-hook.py
hook_json "$S" Stop | ./busy-state-hook.py
assert_equals "clearing an already-clear flag exits 0" "0" "$?"

echo 'not json' | ./busy-state-hook.py >/dev/null 2>&1
assert_equals "busy hook survives non-JSON stdin" "0" "$?"

hook_json "$S" PostToolUse | ./busy-state-hook.py
assert_equals "unrelated event is a no-op" "? for shortcuts" "$(status_json "$S" 7 | ./statusline-progress.py | plain | tail -1)"

echo "== symlink guards (/tmp is world-writable) =="

D=$(mktemp -d)

echo "IMPORTANT DATA" >"$D/victim"
rm -f "/tmp/claude-progress-$S"
ln -s "$D/victim" "/tmp/claude-progress-$S"
todo_json "$S" '{"status":"completed"},{"status":"pending"}' | ./todo-progress-hook.py
assert_equals "todo hook will not write through a symlink" "IMPORTANT DATA" "$(cat "$D/victim")"

echo "9/9" >"$D/fake"
rm -f "/tmp/claude-progress-$S"
ln -s "$D/fake" "/tmp/claude-progress-$S"
line1=$(status_json "$S" 42 | ./statusline-progress.py | head -1 | plain)
assert_contains "status line will not read through a symlink" "42% context" "$line1"

echo "IMPORTANT DATA" >"$D/victim2"
rm -f "/tmp/claude-busy-$S"
ln -s "$D/victim2" "/tmp/claude-busy-$S"
hook_json "$S" UserPromptSubmit | ./busy-state-hook.py
assert_equals "busy hook will not write through a symlink" "IMPORTANT DATA" "$(cat "$D/victim2")"
assert_equals "symlinked busy flag does not read as busy" "? for shortcuts" "$(status_json "$S" 7 | ./statusline-progress.py | plain | tail -1)"

rm -rf "$D"
cleanup

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
