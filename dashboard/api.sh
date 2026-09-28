#!/bin/bash
# Dashboard backend. Subcommands:
#   status         agent state, current review, totals, savings, history, log tail
#   settings       settings.json + masked keys + installed engines
#   save-settings  validate JSON on stdin and write settings.json
#   save-keys      {"OPENAI_API_KEY": "..."} on stdin; "" removes, missing keeps
#   test           {"engine": "codex"} on stdin; runs a one-line prompt to check auth
DIR="$(cd "$(dirname "$0")" && pwd)"
BOT_DIR="$(dirname "$DIR")"
. "$BOT_DIR/config.sh"
. "$BOT_DIR/lib.sh"

ok_json() { jq -cn --arg m "$1" '{ok: true, message: $m}'; }
err_json() { jq -cn --arg e "$1" '{ok: false, error: $e}'; exit 0; }
settings_src() { [ -f "$SETTINGS_FILE" ] && echo "$SETTINGS_FILE" || echo "$BOT_DIR/settings.example.json"; }

cmd_status() {
  local agent loaded=false runs last_exit current=null line today_log
  agent="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null)"
  [ -n "$agent" ] && loaded=true
  runs="$(awk -F' = ' '/^\truns = /{print $2; exit}' <<<"$agent")"
  last_exit="$(awk -F' = ' '/last exit code = /{print $2; exit}' <<<"$agent")"
  today_log="$LOG_DIR/poll-$(date +%F).log"
  if [ -d "$LOCK_DIR" ] && kill -0 "$(cat "$LOCK_DIR/pid" 2>/dev/null)" 2>/dev/null; then
    line="$(grep -h '\[poll\] reviewing ' "$today_log" 2>/dev/null | tail -1)"
    [ -n "$line" ] && current="$(jq -cn --arg since "${line:0:19}" \
      --arg key "$(awk '{print $5}' <<<"$line")" --arg sha "$(awk '{print $7}' <<<"$line")" \
      '{since: $since, key: $key, sha: $sha}')"
  fi
  [ -f "$HISTORY_FILE" ] || : > "$HISTORY_FILE"
  ensure_state
  jq -n \
    --argjson loaded "$loaded" --arg runs "${runs:-0}" --arg last_exit "${last_exit:-}" \
    --argjson current "$current" --arg last_tick "$(cat "$BOT_DIR/.last_run" 2>/dev/null)" \
    --arg now "$(date '+%Y-%m-%d %H:%M:%S')" \
    --arg today "$(date -u +%F)" --arg week "$(date -u -v-6d +%F)" --arg month "$(date -u +%Y-%m)" \
    --rawfile log "$( [ -f "$today_log" ] && echo "$today_log" || echo /dev/null )" \
    --slurpfile hist "$HISTORY_FILE" --slurpfile state "$STATE_FILE" \
    --slurpfile cfg "$(settings_src)" '
    ($cfg[0]) as $s
    | ($hist | map(select(.status == "posted"))) as $posted
    | def totals(d): ($posted | map(select(.at[0:10] >= d))) as $x
        | {reviews: ($x | length), cost_usd: ($x | map(.cost_usd // 0) | add // 0),
           blocking: ($x | map(select(.verdict == "BLOCKING")) | length),
           needs_changes: ($x | map(select(.verdict == "NEEDS_CHANGES")) | length),
           lgtm: ($x | map(select(.verdict == "LGTM")) | length)};
    {
      now: $now, engine: ($s.engine // "claude"), model: ($s.models[$s.engine // "claude"] // ""),
      posting: ($s.post_comments == true),
      repos: [$s.repos[]?.repo],
      agent: {loaded: $loaded, runs: ($runs | tonumber? // 0), last_exit: $last_exit, last_tick: $last_tick},
      current: $current,
      today: totals($today), week: totals($week), all: totals("0000"),
      seen: ($state[0] | length),
      month: (($posted | map(select(.at[0:7] == $month))) as $m
        | ($m | map(.author // empty) | unique) as $devs
        | ($m | map(.cost_usd // 0) | add // 0) as $ours
        | {month: $month, reviews: ($m | length), devs: $devs, our_cost_usd: $ours,
           compare: [($s.compare // [])[] | {name, seat_usd}
             | . + {their_cost_usd: (.seat_usd * ($devs | length))}
             | . + {saved_usd: (.their_cost_usd - $ours)}]}),
      history: ($hist | sort_by(.at) | reverse | .[:200]),
      log: ($log | split("\n") | map(select(length > 0 and (test("seeded ") | not))) | .[-40:])
    }'
}

cmd_settings() {
  local e path ver engines="{}" keys="{}" k v
  for e in $ENGINES; do
    path="$(command -v "$e" 2>/dev/null)"; ver=""
    [ -n "$path" ] && ver="$("$e" --version 2>/dev/null | head -1)"
    engines="$(jq -c --arg e "$e" --arg p "$path" --arg v "$ver" '. + {($e): {installed: ($p != ""), path: $p, version: $v}}' <<<"$engines")"
  done
  for k in $KEY_NAMES; do
    v="${!k}"
    keys="$(jq -c --arg k "$k" --arg m "$(mask_key "$v")" '. + {($k): {set: ($m != ""), masked: $m}}' <<<"$keys")"
  done
  jq -c --argjson engines "$engines" --argjson keys "$keys" --arg label "$LABEL" --arg port "$PORT" \
    '{settings: ., engines: $engines, keys: $keys, install: {label: $label, port: $port}}' "$(settings_src)"
}

cmd_save_settings() {
  local body normalized path repo tmp
  body="$(cat)"
  normalized="$(jq -c '
    def str(max): type == "string" and length <= max and (test("[\n\r]") | not);
    def fail(m): error(m);
    . as $in
    | if (.engine | IN("claude","codex","gemini")) | not then fail("engine must be claude, codex or gemini") else . end
    | if ((.models // {}) | to_entries | all(.value | str(80) and test("^[A-Za-z0-9._:/-]*$"))) | not
        then fail("model names may only contain letters, digits and . _ : / -") else . end
    | if ((.repos // []) | length) > 20 then fail("at most 20 repos") else . end
    | if ((.repos // []) | all(.repo | type == "string" and test("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$"))) | not
        then fail("each repo must look like owner/repo") else . end
    | if ((.repos // []) | all((.path // "") | str(300))) | not then fail("bad repo path") else . end
    | if ((.repos // []) | all((.rules // "") | type == "string" and length <= 4000)) | not then fail("repo rules are limited to 4000 characters") else . end
    | if (.max_turns | type == "number" and . >= 5 and . <= 300) | not then fail("max turns must be 5-300") else . end
    | if (.review_timeout | type == "number" and . >= 120 and . <= 3600) | not then fail("timeout must be 120-3600 seconds") else . end
    | if ((.skip.label // "") | str(50)) | not then fail("bad skip label") else . end
    | if ((.skip.authors // []) | all(type == "string" and test("^[A-Za-z0-9\\[\\]/_-]{1,60}$"))) | not then fail("bad author login") else . end
    | if ((.trivial_globs // []) | all(str(100))) | not then fail("bad file pattern") else . end
    | if (.log_retention_days | type == "number" and . >= 1 and . <= 90) | not then fail("log retention must be 1-90 days") else . end
    | if ((.compare // []) | length <= 8 and all((.name | str(40)) and (.seat_usd | type == "number" and . >= 0 and . <= 10000))) | not
        then fail("bad price comparison entry") else . end
    | {
        repos: [(.repos // [])[] | {repo, path: (.path // ""), rules: (.rules // "")}],
        engine,
        models: {claude: (.models.claude // ""), codex: (.models.codex // ""), gemini: (.models.gemini // "")},
        post_comments: (.post_comments == true),
        max_turns: (.max_turns | floor), review_timeout: (.review_timeout | floor),
        skip: {label: (.skip.label // ""), drafts: (.skip.drafts != false), bots: (.skip.bots != false),
               authors: (.skip.authors // [])},
        trivial_globs: (.trivial_globs // []),
        log_retention_days: (.log_retention_days | floor),
        compare: [(.compare // [])[] | {name, seat_usd}]
      }' <<<"$body" 2>&1)" || err_json "$(sed -e 's/^jq: error ([^)]*): //' <<<"$normalized" | head -1)"
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    path="${path/#\~/$HOME}"
    [ -d "$path/.git" ] || err_json "not a git clone: $path"
  done < <(jq -r '.repos[].path' <<<"$normalized")
  tmp="$SETTINGS_FILE.tmp.$$"
  jq . <<<"$normalized" > "$tmp" && mv "$tmp" "$SETTINGS_FILE" || err_json "could not write settings.json"
  ok_json "Saved. The next tick (within 30s) uses the new settings."
}

cmd_save_keys() {
  local body k v out="" tmp
  body="$(cat)"
  jq -e 'type == "object"' <<<"$body" >/dev/null 2>&1 || err_json "expected a JSON object"
  for k in $KEY_NAMES; do
    if jq -e --arg k "$k" 'has($k)' <<<"$body" >/dev/null; then
      v="$(jq -r --arg k "$k" '.[$k] // ""' <<<"$body")"
      case "$v" in *[!A-Za-z0-9._-]*) err_json "$k contains characters an API key never has" ;; esac
      [ "${#v}" -le 400 ] || err_json "$k is too long"
    else
      v="${!k}"
    fi
    out="$out$k=$v
"
  done
  tmp="$ENV_FILE.tmp.$$"
  ( umask 077; printf '# Written by the dashboard. Keep this file private (chmod 600).\n%s' "$out" > "$tmp" ) \
    && mv "$tmp" "$ENV_FILE" && chmod 600 "$ENV_FILE" || err_json "could not write .env"
  ok_json "Keys saved."
}

cmd_test() {
  local engine model out rc tmpd
  engine="$(jq -r '.engine // empty' 2>/dev/null)"
  case " $ENGINES " in *" $engine "*) ;; *) err_json "unknown engine" ;; esac
  command -v "$engine" >/dev/null || err_json "$engine CLI is not installed (or not on the agent's PATH)"
  model="$(jq -r --arg e "$engine" '.models[$e] // ""' "$(settings_src)")"
  tmpd="$(mktemp -d)"
  local margs=()
  case "$engine" in
    claude)
      [ -n "$model" ] && margs=(--model "$model")
      ( cd "$tmpd" && { [ -n "$ANTHROPIC_API_KEY" ] && export ANTHROPIC_API_KEY; }
        run_with_timeout 90 claude -p "Reply with exactly: OK" ${margs[@]+"${margs[@]}"} --max-turns 1 \
          --output-format json --setting-sources user --strict-mcp-config --no-session-persistence ) \
        > "$tmpd/out" 2> "$tmpd/err" < /dev/null
      rc=$?; out="$(jq -r '.result // empty' "$tmpd/out" 2>/dev/null)" ;;
    codex)
      [ -n "$model" ] && margs=(-m "$model")
      ( [ -n "$OPENAI_API_KEY" ] && export CODEX_API_KEY="$OPENAI_API_KEY"
        run_with_timeout 90 codex exec ${margs[@]+"${margs[@]}"} \
          --sandbox read-only --skip-git-repo-check --ephemeral -C "$tmpd" -o "$tmpd/out" "Reply with exactly: OK" ) \
        > /dev/null 2> "$tmpd/err" < /dev/null
      rc=$?; out="$(cat "$tmpd/out" 2>/dev/null)" ;;
    gemini)
      [ -n "$model" ] && margs=(-m "$model")
      ( cd "$tmpd" && { [ -n "$GEMINI_API_KEY" ] && export GEMINI_API_KEY; }
        run_with_timeout 90 gemini ${margs[@]+"${margs[@]}"} --approval-mode plan --skip-trust -o json -p "Reply with exactly: OK" ) \
        > "$tmpd/out" 2> "$tmpd/err" < /dev/null
      rc=$?; out="$(jq -r '.response // empty' "$tmpd/out" 2>/dev/null)" ;;
  esac
  local errtail
  errtail="$(tail -c 400 "$tmpd/err" 2>/dev/null; [ -z "$out" ] && tail -c 300 "$tmpd/out" 2>/dev/null)"
  rm -rf "$tmpd"
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    jq -cn --arg e "$engine" --arg o "$out" --arg m "${model:-default}" '{ok: true, message: "\($e) (\($m)) answered: \($o | .[0:80])"}'
  else
    jq -cn --arg e "$engine" --arg t "$errtail" --argjson rc "$rc" \
      '{ok: false, error: "\($e) failed (exit \($rc)\(if $rc == 143 then ", timed out" else "" end)): \($t | gsub("\\s+"; " ") | .[-300:])"}'
  fi
}

case "${1:-}" in
  status) cmd_status ;;
  settings) cmd_settings ;;
  save-settings) cmd_save_settings ;;
  save-keys) cmd_save_keys ;;
  test) cmd_test ;;
  *) echo "usage: api.sh status|settings|save-settings|save-keys|test" >&2; exit 2 ;;
esac
