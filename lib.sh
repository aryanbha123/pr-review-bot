# Shared helpers. Sourced after config.sh. Must stay bash 3.2 compatible
# (macOS /bin/bash): no associative arrays, no mapfile.

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${LOG_TAG:-bot}" "$*"; }

die() { log "ERROR: $*"; exit 1; }

now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# repo_path owner/repo -> local clone path (configured, or the bot's own clone)
repo_path() {
  local entry path
  for entry in "${REPOS[@]}"; do
    if [ "${entry%%|*}" = "$1" ]; then
      path="${entry#*|}"
      path="${path/#\~/$HOME}"
      [ -n "$path" ] || path="$CLONES_DIR/${1//\//__}"
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

ensure_state() { [ -s "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"; }

# state_get "owner/repo#123" -> last recorded head SHA (empty if none)
state_get() {
  ensure_state
  jq -r --arg k "$1" '.[$k].sha // empty' "$STATE_FILE"
}

# state_field "owner/repo#123" field -> value of that field (empty if none)
state_field() {
  ensure_state
  jq -r --arg k "$1" --arg f "$2" '.[$k][$f] // empty' "$STATE_FILE"
}

# state_put "owner/repo#123" '<json object>'  (merges into that key, atomic write)
state_put() {
  ensure_state
  local tmp="$STATE_FILE.tmp.$$"
  jq --arg k "$1" --argjson v "$2" '.[$k] = ((.[$k] // {}) + $v)' "$STATE_FILE" > "$tmp" \
    && mv "$tmp" "$STATE_FILE"
}

# history_posted RUN_DIR -> one JSON line describing a posted review (from its run files)
history_posted() {
  jq -cn --slurpfile pr "$1/pr.json" --slurpfile rv "$1/review.json" \
    --slurpfile meta "$1/meta.json" --slurpfile po "$1/post.out" '
    ($pr[0]) as $p | ($rv[0]) as $r | ($meta[0]) as $m | ($po[0]) as $o
    | ($p.url | split("/")) as $u
    | {
        at: ($o.submitted_at // (now | todate)), status: "posted",
        repo: "\($u[3])/\($u[4])", pr: $p.number, sha: $p.headRefOid,
        title: $p.title, author: $p.author.login, pr_url: $p.url, review_url: $o.html_url,
        verdict: $r.verdict, summary: $r.summary,
        issues: [$r.issues[] | {severity, category, file, line, title}],
        engine: $m.engine, model: $m.model, cost_usd: $m.cost_usd, turns: $m.turns,
        duration_ms: $m.duration_ms, tokens: $m.tokens
      }'
}

# history_failed owner/repo PR SHA attempt
history_failed() {
  jq -cn --arg repo "$1" --argjson pr "$2" --arg sha "$3" --argjson n "$4" --arg at "$(now_iso)" \
    '{at: $at, status: "failed", repo: $repo, pr: $pr, sha: $sha, attempt: $n}'
}

# run_with_timeout SECONDS cmd...  (macOS has no `timeout`); returns cmd's status, 143 on kill
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  (
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 2; waited=$((waited + 2))
      if [ "$waited" -ge "$secs" ]; then kill -TERM "$pid" 2>/dev/null; break; fi
    done
  ) &
  wait "$pid"
}

# mask_key VALUE -> "sk-a…1b2c" (never the full key)
mask_key() {
  local v="$1"
  [ -z "$v" ] && return 0
  if [ "${#v}" -le 10 ]; then printf '…%s\n' "${v: -2}"; else printf '%s…%s\n' "${v:0:4}" "${v: -4}"; fi
}
