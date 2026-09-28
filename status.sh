#!/bin/bash
# Show whether the launchd agent is loaded, the last run, and recent reviews.
BOT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$BOT_DIR/config.sh"
. "$BOT_DIR/lib.sh"

echo "== Agent"
if out="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null)"; then
  echo "loaded: yes"
  grep -E '^\s*(state|runs|last exit code|run interval) =' <<<"$out" | sed 's/^[[:space:]]*/  /'
else
  echo "loaded: NO   (run ./install.sh)"
fi
if launchctl print "gui/$(id -u)/$LABEL.dashboard" >/dev/null 2>&1; then
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:$PORT/api/status)"
  echo "dashboard: loaded, http://localhost:$PORT ($([ "$code" = 200 ] && echo "responding" || echo "NOT responding: HTTP $code"))"
else
  echo "dashboard: NOT loaded   (./install.sh)"
fi
echo "engine: $ENGINE ${MODEL:-(CLI default model)}"
echo "posting: $([ "$POST_COMMENTS" = 1 ] && echo "ON" || echo "OFF (shadow mode)")"
echo "repos: ${#REPOS[@]} configured"

echo; echo "== Last run"
echo "last tick: $(cat "$BOT_DIR/.last_run" 2>/dev/null || echo never)"
if [ -d "$LOCK_DIR" ] && kill -0 "$(cat "$LOCK_DIR/pid" 2>/dev/null)" 2>/dev/null; then
  echo "running now: yes (pid $(cat "$LOCK_DIR/pid"))"
else
  echo "running now: no"
fi
LOG="$(ls -t "$LOG_DIR"/poll-*.log 2>/dev/null | head -1)"
if [ -n "$LOG" ]; then echo "log: $LOG"; tail -n 8 "$LOG" | sed 's/^/  /'; fi

echo; echo "== Last reviewed PRs"
ensure_state
jq -r 'to_entries
  | map(select(.value.status == "reviewed" or .value.failures > 0))
  | sort_by(.value.reviewed_at // .value.last_failure_at) | reverse | .[:10][]
  | if .value.status == "reviewed" then
      "\(.value.reviewed_at)  \(.key)  \(.value.verdict)  \(.value.issues) issues  \(if .value.cost_usd then "$\(.value.cost_usd * 100 | round / 100)" else (.value.engine // "") end)  \(.value.url)"
    else
      "\(.value.last_failure_at)  \(.key)  FAILED x\(.value.failures) on \(.value.failed_sha[0:12])"
    end' "$STATE_FILE" | sed 's/^/  /'
[ "$(jq '[.[] | select(.status == "reviewed")] | length' "$STATE_FILE")" = 0 ] && echo "  (none yet)"

# Count from today's log, not state.json (which keeps only the latest review per PR).
TODAY_LOG="$LOG_DIR/poll-$(date +%F).log"
grep -h 'review done:' "$TODAY_LOG" 2>/dev/null \
  | awk -F'\\$' '{ n++; c += $NF } END { printf "today: %d reviews, $%.2f\n", n, c }'
