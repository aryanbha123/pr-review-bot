#!/bin/bash
# Entry point, run by launchd every 30s. Reviews at most one PR per tick.
#   ./poll.sh           normal tick
#   ./poll.sh --seed    mark every currently open PR as already seen (no reviews),
#                       so going live does not comment on the whole backlog
set -uo pipefail

BOT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$BOT_DIR/config.sh"
. "$BOT_DIR/lib.sh"
LOG_TAG="poll"
SEED=0; [ "${1:-}" = "--seed" ] && SEED=1

mkdir -p "$LOG_DIR/reviews" "$RUNS_DIR" "$WORKTREE_DIR"
[ "${#REPOS[@]}" -eq 0 ] && exit 0   # nothing configured yet (add repos in the dashboard)
exec >> "$LOG_DIR/poll-$(date +%F).log" 2>&1

# --- Lock: a running review makes every later tick exit immediately -----------
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then exit 0; fi
  log "removing stale lock (pid ${holder:-unknown} is gone)"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT
date '+%Y-%m-%d %H:%M:%S' > "$BOT_DIR/.last_run"

# --- Log rotation --------------------------------------------------------------
find "$LOG_DIR" -maxdepth 1 -name 'poll-*.log' -mtime +"$LOG_RETENTION_DAYS" -delete
find "$LOG_DIR/reviews" -type f -mtime +"$LOG_RETENTION_DAYS" -delete
find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -mtime +"$LOG_RETENTION_DAYS" -exec rm -rf {} +
for f in "$LOG_DIR/launchd.out" "$LOG_DIR/launchd.err"; do
  [ -f "$f" ] && [ "$(stat -f %z "$f")" -gt 5242880 ] && : > "$f"
done

is_trivial() {  # reads changed file paths on stdin; true if all match TRIVIAL_GLOBS
  local path g hit any=0
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    any=1; hit=0
    for g in ${TRIVIAL_GLOBS[@]+"${TRIVIAL_GLOBS[@]}"}; do
      # shellcheck disable=SC2053
      case "$path" in $g) hit=1; break ;; esac
    done
    [ "$hit" -eq 0 ] && return 1
  done
  [ "$any" -eq 1 ]
}

# --- Find the first PR that needs a review -------------------------------------
CANDIDATE_FILTER='
    sort_by(.number)[]
    | select(($drafts == 0) or (.isDraft | not))
    | select(($bots == 0) or ((.author.is_bot // false) | not)
             and ((.author.login | test("\\[bot\\]$|^app/")) | not))
    | select(any(.labels[]?; .name == $label) | not)
    | .author.login as $login | select(($authors | contains(" " + $login + " ")) | not)
    | "\(.number) \(.headRefOid)"'

for entry in "${REPOS[@]}"; do
  REPO="${entry%%|*}"
  LIST="$(gh pr list -R "$REPO" --state open --limit 100 \
    --json number,headRefOid,isDraft,author,labels 2>&1)" \
    || { log "gh pr list failed for $REPO: $(head -c 200 <<<"$LIST")"; continue; }

  # Draft/bot/label/author filters cost no API calls, so they are re-checked each tick
  # (a draft marked ready or a removed label gets picked up).
  CANDIDATES="$(jq -r --argjson drafts "$SKIP_DRAFTS" --argjson bots "$SKIP_BOTS" \
    --arg label "$SKIP_LABEL" --arg authors " $SKIP_AUTHORS " "$CANDIDATE_FILTER" <<<"$LIST")"

  while read -r N SHA; do
    [ -z "${N:-}" ] && continue
    KEY="$REPO#$N"
    [ "$(state_get "$KEY")" = "$SHA" ] && continue
    if [ "$(state_field "$KEY" failed_sha)" = "$SHA" ] \
       && [ "$(state_field "$KEY" failures)" -ge 3 ] 2>/dev/null; then
      continue   # gave up on this head after 3 failures; a new push retries
    fi

    if [ "$SEED" -eq 1 ]; then
      state_put "$KEY" "$(jq -n --arg s "$SHA" --arg t "$(now_iso)" '{sha: $s, status: "seeded", reviewed_at: $t}')"
      log "seeded $KEY @ ${SHA:0:12}"
      continue
    fi

    if gh pr diff "$N" -R "$REPO" --name-only 2>/dev/null | is_trivial; then
      state_put "$KEY" "$(jq -n --arg s "$SHA" --arg t "$(now_iso)" '{sha: $s, status: "skipped-trivial", reviewed_at: $t}')"
      log "skip $KEY @ ${SHA:0:12}: docs/lockfile-only"
      continue
    fi

    if [ "$POST_COMMENTS" != "1" ]; then
      # Shadow mode: without posting, state never advances, so reviewing here would
      # re-review the same PR every tick. Report it and stop.
      log "would review $KEY @ ${SHA:0:12} (posting is off; run ./review.sh $REPO $N --dry-run to preview)"
      exit 0
    fi

    log "reviewing $KEY @ ${SHA:0:12}"
    if "$BOT_DIR/review.sh" "$REPO" "$N" </dev/null; then
      log "done $KEY"
    else
      prev="$(state_field "$KEY" failed_sha)"; count="$(state_field "$KEY" failures)"
      [ "$prev" = "$SHA" ] && count=$(( ${count:-0} + 1 )) || count=1
      state_put "$KEY" "$(jq -n --arg s "$SHA" --argjson c "$count" --arg t "$(now_iso)" \
        '{failed_sha: $s, failures: $c, last_failure_at: $t}')"
      history_failed "$REPO" "$N" "$SHA" "$count" >> "$HISTORY_FILE"
      log "review failed for $KEY (attempt $count/3)"
    fi
    exit 0   # one PR per tick
  done <<<"$CANDIDATES"
done
