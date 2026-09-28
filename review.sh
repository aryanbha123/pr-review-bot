#!/bin/bash
# Review one PR. Called by poll.sh; also usable by hand:
#   ./review.sh owner/repo 1234                  # posts if post_comments is on in settings
#   ./review.sh owner/repo 1234 --dry-run        # never posts, never touches state.json
#   ./review.sh owner/repo 1234 --post           # posts even if post_comments is off
#   PRBOT_ENGINE=codex PRBOT_MODEL=... ./review.sh owner/repo 1234 --dry-run
set -uo pipefail

BOT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$BOT_DIR/config.sh"
. "$BOT_DIR/lib.sh"
LOG_TAG="review"

REPO="${1:?usage: review.sh owner/repo PR [--dry-run|--post]}"
PR="${2:?usage: review.sh owner/repo PR [--dry-run|--post]}"
POST="$POST_COMMENTS"
case "${3:-}" in
  --dry-run) POST=0 ;;
  --post) POST=1 ;;
  "") ;;
  *) die "unknown flag: $3" ;;
esac
ENGINE="${PRBOT_ENGINE:-$ENGINE}"
[ -n "${PRBOT_ENGINE:-}" ] && MODEL="$(jq -r --arg e "$ENGINE" '.models[$e] // ""' "$SETTINGS_FILE" 2>/dev/null)"
MODEL="${PRBOT_MODEL:-$MODEL}"
RULES_FILE="${PRBOT_RULES:-$BOT_DIR/REVIEW_RULES.md}"
case " $ENGINES " in *" $ENGINE "*) ;; *) die "unknown engine: $ENGINE" ;; esac
command -v "$ENGINE" >/dev/null || die "$ENGINE CLI not found on PATH ($PATH)"

CLONE="$(repo_path "$REPO")" || die "$REPO is not in the configured repos"
if [ ! -d "$CLONE/.git" ]; then
  # No local clone configured: keep a blobless, checkout-free clone of our own.
  log "cloning $REPO into $CLONE"
  mkdir -p "$(dirname "$CLONE")"
  gh repo clone "$REPO" "$CLONE" -- --quiet --filter=blob:none --no-checkout \
    || die "gh repo clone $REPO failed"
fi

# --- PR metadata and diff -----------------------------------------------------
PR_JSON="$(gh pr view "$PR" -R "$REPO" \
  --json number,title,body,url,author,baseRefName,headRefName,headRefOid,files)" \
  || die "gh pr view failed for $REPO#$PR"
SHA="$(jq -r .headRefOid <<<"$PR_JSON")"
TITLE="$(jq -r .title <<<"$PR_JSON")"
URL="$(jq -r .url <<<"$PR_JSON")"

SLUG="${REPO//\//_}-$PR-${SHA:0:12}"
[ "$POST" != "1" ] && SLUG="$SLUG-dry-$$"
RUN_DIR="$RUNS_DIR/$SLUG"
rm -rf "$RUN_DIR" && mkdir -p "$RUN_DIR" "$LOG_DIR/reviews"
printf '%s\n' "$PR_JSON" > "$RUN_DIR/pr.json"
gh pr diff "$PR" -R "$REPO" > "$RUN_DIR/pr.diff" || die "gh pr diff failed"

log "$REPO#$PR @ ${SHA:0:12} \"$TITLE\" (engine=$ENGINE model=${MODEL:-default} post=$POST)"

# Lines that exist on the new side of the diff; only these accept inline comments.
awk '
  /^diff --git / { in_hunk = 0; file = ""; next }
  !in_hunk && /^\+\+\+ / { file = substr($0, 5); sub(/^b\//, "", file); next }
  /^@@ / { match($0, /\+[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1) + 0; in_hunk = 1; next }
  in_hunk && /^\+/ { print file ":" n; n++; next }
  in_hunk && /^ /  { print file ":" n; n++; next }
' "$RUN_DIR/pr.diff" > "$RUN_DIR/commentable.txt"

# --- Dedicated worktree at the PR head (never the user's checkout) ------------
WT="$WORKTREE_DIR/${REPO//\//__}"
if [ "$POST" != "1" ]; then
  # Dry runs can happen while the bot is reviewing; give them their own worktree.
  WT="$WORKTREE_DIR/${REPO//\//__}-dry-$PR-$$"
  trap 'git -C "$CLONE" worktree remove --force "$WT" >/dev/null 2>&1' EXIT
fi
# Fetch the exact head commit; refs/pull/N/head can lag a push by a few seconds.
git -C "$CLONE" fetch --quiet --no-tags --no-write-fetch-head origin "$SHA" 2>/dev/null \
  || git -C "$CLONE" fetch --quiet --no-tags --no-write-fetch-head origin "pull/$PR/head" \
  || die "git fetch of $SHA failed"
git -C "$CLONE" cat-file -e "$SHA^{commit}" 2>/dev/null \
  || die "commit $SHA not available after fetch (GitHub may still be updating the PR ref)"
if [ ! -e "$WT/.git" ]; then
  git -C "$CLONE" worktree prune
  git -C "$CLONE" -c core.hooksPath=/dev/null worktree add --quiet --detach "$WT" "$SHA" \
    || die "git worktree add failed"
else
  git -C "$WT" -c core.hooksPath=/dev/null checkout --quiet --force --detach "$SHA" \
    || die "git checkout $SHA in worktree failed"
  git -C "$WT" clean -fdq
fi

# --- Prompt -------------------------------------------------------------------
EXTRA_RULES="$(jq -r --arg r "$REPO" '.repos[]? | select(.repo == $r) | .rules // empty' "$SETTINGS_FILE" 2>/dev/null)"
TASK="Review pull request #$PR in $REPO: \"$TITLE\".
The current directory is a read-only checkout of the PR head (${SHA}), base branch $(jq -r .baseRefName <<<"$PR_JSON").
- $RUN_DIR/pr.diff is the full unified diff. Read it first (in chunks if it is large).
- $RUN_DIR/pr.json has the PR description and the changed file list.
Then follow the method in the review rules: trace callers, entry points, sibling copies and state
lifecycles in the surrounding code, and verify each finding before reporting it.
File paths in issues must be repo-relative, exactly as they appear in the diff."
[ -n "$EXTRA_RULES" ] && TASK="$TASK

Repository-specific rules for $REPO:
$EXTRA_RULES"

# --- Engines --------------------------------------------------------------------
# Each engine writes $RUN_DIR/review.json (matching review-schema.json) and
# $RUN_DIR/meta.json ({engine, model, cost_usd, turns, tokens}). Each gets only its own key.

run_claude() {
  local env_args=()
  [ -n "$ANTHROPIC_API_KEY" ] && env_args=("ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
  local model_args=()
  [ -n "$MODEL" ] && model_args=(--model "$MODEL")
  env ${env_args[@]+"${env_args[@]}"} claude -p "$TASK" \
    ${model_args[@]+"${model_args[@]}"} \
    --max-turns "$MAX_TURNS" \
    --output-format json \
    --json-schema "$(cat "$BOT_DIR/review-schema.json")" \
    --append-system-prompt-file "$RULES_FILE" \
    --add-dir "$RUN_DIR" \
    --allowedTools "Read" "Grep" "Glob" \
      "Bash(git log *)" "Bash(git show *)" "Bash(git diff *)" "Bash(git blame *)" \
      "Bash(gh pr view *)" "Bash(gh pr diff *)" \
    --disallowedTools "Edit" "Write" "NotebookEdit" "WebFetch" "WebSearch" "Agent" \
    --permission-mode dontAsk \
    --permission-prompts none \
    --setting-sources user \
    --strict-mcp-config \
    --no-session-persistence \
    > "$RUN_DIR/engine.out" 2> "$RUN_DIR/engine.err" < /dev/null
  local rc=$?
  jq -e '.structured_output.verdict' "$RUN_DIR/engine.out" >/dev/null 2>&1 || return "${rc/#0/1}"
  jq '.structured_output' "$RUN_DIR/engine.out" > "$RUN_DIR/review.json"
  jq --arg m "$MODEL" '{engine: "claude", model: ((.modelUsage // {} | keys[0]) // $m),
      cost_usd: .total_cost_usd, turns: .num_turns,
      tokens: {input: (.usage.input_tokens + (.usage.cache_read_input_tokens // 0) + (.usage.cache_creation_input_tokens // 0)),
               output: .usage.output_tokens}}' "$RUN_DIR/engine.out" > "$RUN_DIR/meta.json"
}

run_codex() {
  local env_args=()
  [ -n "$OPENAI_API_KEY" ] && env_args=("CODEX_API_KEY=$OPENAI_API_KEY")
  local model_args=()
  [ -n "$MODEL" ] && model_args=(-m "$MODEL")
  # read-only sandbox: shell commands can read anything but write nothing, no network.
  env ${env_args[@]+"${env_args[@]}"} codex exec \
    ${model_args[@]+"${model_args[@]}"} \
    --sandbox read-only \
    --skip-git-repo-check \
    --ephemeral \
    --json \
    -C "$WT" \
    --output-schema "$BOT_DIR/review-schema.json" \
    -o "$RUN_DIR/review.json" \
    "$(cat "$RULES_FILE")

---

$TASK" \
    > "$RUN_DIR/engine.out" 2> "$RUN_DIR/engine.err" < /dev/null
  local rc=$?
  jq -e '.verdict' "$RUN_DIR/review.json" >/dev/null 2>&1 || return "${rc/#0/1}"
  jq -s --arg m "$MODEL" '{engine: "codex", model: (if $m == "" then "codex default" else $m end), cost_usd: null,
      turns: ([.[] | select(.type == "item.completed")] | length),
      tokens: ([.[] | select(.type == "turn.completed") | .usage]
               | {input: (map(.input_tokens // 0) | add // 0), output: (map((.output_tokens // 0) + (.reasoning_output_tokens // 0)) | add // 0)})}' \
    "$RUN_DIR/engine.out" > "$RUN_DIR/meta.json" 2>/dev/null \
    || echo '{"engine":"codex","cost_usd":null}' > "$RUN_DIR/meta.json"
}

run_gemini() {
  local env_args=()
  [ -n "$GEMINI_API_KEY" ] && env_args=("GEMINI_API_KEY=$GEMINI_API_KEY")
  local model_args=()
  [ -n "$MODEL" ] && model_args=(-m "$MODEL")
  # approval-mode plan = Gemini CLI's read-only mode (no edits, no mutating shell).
  ( cd "$WT" && env ${env_args[@]+"${env_args[@]}"} gemini \
      ${model_args[@]+"${model_args[@]}"} \
      --approval-mode plan \
      --skip-trust \
      --include-directories "$RUN_DIR" \
      -o json \
      -p "$(cat "$RULES_FILE")

---

$TASK

Your final answer must be ONLY a JSON object (no prose, no code fences) matching this JSON Schema:
$(cat "$BOT_DIR/review-schema.json")" ) \
    > "$RUN_DIR/engine.out" 2> "$RUN_DIR/engine.err" < /dev/null
  local rc=$?
  # .response is text; strip any code fences, take the outermost {...}, validate the shape.
  jq -r '.response // empty' "$RUN_DIR/engine.out" 2>/dev/null \
    | sed -e '/^```/d' | awk 'BEGIN{p=0} /\{/{p=1} p' > "$RUN_DIR/review.raw"
  jq -e 'select((.verdict | IN("LGTM","NEEDS_CHANGES","BLOCKING")) and (.summary | type == "string") and (.issues | type == "array"))
         | .issues |= map(select(.severity | IN("critical","major","minor")) | .line = ((.line // 0) | tonumber? // 0))' \
    "$RUN_DIR/review.raw" > "$RUN_DIR/review.json" 2>/dev/null || return "${rc/#0/1}"
  jq --arg m "$MODEL" '{engine: "gemini", model: ((.stats.models // {} | keys[0]) // (if $m == "" then "gemini default" else $m end)),
      cost_usd: null, turns: null,
      tokens: ((.stats.models // {}) | [.[] | .tokens // {}] | {input: (map(.prompt // .input // 0) | add // 0), output: (map(.candidates // .output // 0) | add // 0)})}' \
    "$RUN_DIR/engine.out" > "$RUN_DIR/meta.json" 2>/dev/null \
    || echo '{"engine":"gemini","cost_usd":null}' > "$RUN_DIR/meta.json"
}

START_MS=$(( $(date +%s) * 1000 ))
cd "$WT" || die "cannot cd to $WT"
run_with_timeout "$REVIEW_TIMEOUT" "run_$ENGINE"; RC=$?
cd "$BOT_DIR"
cp "$RUN_DIR/engine.out" "$LOG_DIR/reviews/$SLUG.$ENGINE.out" 2>/dev/null

[ "$RC" -eq 143 ] && die "$ENGINE timed out after ${REVIEW_TIMEOUT}s (see $RUN_DIR/engine.err)"
[ -s "$RUN_DIR/review.json" ] && jq -e .verdict "$RUN_DIR/review.json" >/dev/null 2>&1 \
  || die "$ENGINE returned no review (rc=$RC): $(tail -c 400 "$RUN_DIR/engine.err" 2>/dev/null | tr '\n' ' ')"

DURATION_MS=$(( $(date +%s) * 1000 - START_MS ))
jq --argjson d "$DURATION_MS" '. + {duration_ms: (.duration_ms // $d)}' "$RUN_DIR/meta.json" > "$RUN_DIR/meta.tmp" \
  && mv "$RUN_DIR/meta.tmp" "$RUN_DIR/meta.json"
VERDICT="$(jq -r .verdict "$RUN_DIR/review.json")"
NISSUES="$(jq '.issues | length' "$RUN_DIR/review.json")"
COST="$(jq -r '.cost_usd // "n/a"' "$RUN_DIR/meta.json")"
MODEL_USED="$(jq -r '.model // "default"' "$RUN_DIR/meta.json")"
log "review done: $VERDICT, $NISSUES issues, $(jq -r '.turns // "?"' "$RUN_DIR/meta.json") turns, \$$COST ($ENGINE $MODEL_USED)"

# --- Render: summary body + inline comments -----------------------------------
jq -n --slurpfile r "$RUN_DIR/review.json" --rawfile ok "$RUN_DIR/commentable.txt" \
  --arg sha "$SHA" --arg model "$MODEL_USED" --arg engine "$ENGINE" '
  ($r[0]) as $rev
  | ($ok | split("\n") | map(select(length > 0)) | map({(.): true}) | add // {}) as $valid
  | {critical: "🔴", major: "🟠", minor: "🟡"} as $icon
  | {critical: "Critical", major: "Major", minor: "Minor"} as $label
  | {LGTM: "✅ **LGTM**", NEEDS_CHANGES: "🟠 **Needs changes**", BLOCKING: "🔴 **Blocking issues**"} as $v
  | def loc: if .line > 0 then "\(.file):\(.line)" else .file end;
    def inline_ok: .line > 0 and ($valid["\(.file):\(.line)"] // false);
  {
    body: (
      [ "## 🤖 AI review: \($v[$rev.verdict])", "", $rev.summary, "" ]
      + ( ["critical", "major", "minor"] | map(. as $s
          | [$rev.issues[] | select(.severity == $s)] as $list
          | if ($list | length) == 0 then empty else
              ( ["### \($icon[$s]) \($label[$s]) (\($list | length))"]
                + ($list | map("- **\(.title)** · `\(loc)` · _\(.category)_\n  \(.detail)\n  **Fix:** \(.fix)"))
                + [""] )
            end) | add // [] )
      + ( if ($rev.issues | length) == 0 then ["No issues found."] else [] end )
      + [ "", "<sub>Reviewed commit `\($sha[0:12])` · \($engine) · \($model) · PR review bot</sub>",
          "<!-- pr-review-bot sha=\($sha) -->" ]
      | join("\n")
    ),
    comments: [ $rev.issues[] | select(inline_ok)
      | { path: .file, line: .line, side: "RIGHT",
          body: "\($icon[.severity]) **\(.title)** (_\(.category)_)\n\n\(.detail)\n\n**Fix:** \(.fix)" } ]
  }' > "$RUN_DIR/render.json" || die "failed to render review"

NINLINE="$(jq '.comments | length' "$RUN_DIR/render.json")"

if [ "$POST" != "1" ]; then
  log "DRY RUN: nothing posted, state.json unchanged ($NINLINE of $NISSUES issues would be inline comments)"
  echo "----- review body -----"
  jq -r .body "$RUN_DIR/render.json"
  echo "----- inline comments -----"
  jq -r '.comments[] | "[\(.path):\(.line)]\n\(.body)\n"' "$RUN_DIR/render.json"
  echo "----- files: $RUN_DIR -----"
  exit 0
fi

# --- Post, then record state only on success ----------------------------------
post_review() {
  gh api -X POST "repos/$REPO/pulls/$PR/reviews" --input "$1" > "$RUN_DIR/post.out" 2> "$RUN_DIR/post.err"
}
jq --arg sha "$SHA" '{commit_id: $sha, event: "COMMENT", body, comments}' \
  "$RUN_DIR/render.json" > "$RUN_DIR/payload.json"
if ! post_review "$RUN_DIR/payload.json"; then
  # A single bad inline position fails the whole review (422); fall back to body only.
  log "post with inline comments failed: $(head -c 300 "$RUN_DIR/post.err"); retrying body-only"
  jq --arg sha "$SHA" '{commit_id: $sha, event: "COMMENT", body}' \
    "$RUN_DIR/render.json" > "$RUN_DIR/payload.json"
  post_review "$RUN_DIR/payload.json" || die "posting review failed: $(head -c 300 "$RUN_DIR/post.err")"
  NINLINE=0
fi

REVIEW_URL="$(jq -r '.html_url // empty' "$RUN_DIR/post.out")"
state_put "$REPO#$PR" "$(jq -n --arg sha "$SHA" --arg v "$VERDICT" --arg t "$(now_iso)" \
  --arg url "${REVIEW_URL:-$URL}" --arg title "$TITLE" --arg engine "$ENGINE" \
  --argjson n "$NISSUES" --slurpfile m "$RUN_DIR/meta.json" \
  '{sha: $sha, status: "reviewed", verdict: $v, issues: $n, cost_usd: $m[0].cost_usd, engine: $engine,
    reviewed_at: $t, url: $url, title: $title, failed_sha: null, failures: 0}')"
history_posted "$RUN_DIR" >> "$HISTORY_FILE"
log "posted: ${REVIEW_URL:-$URL} ($NINLINE inline comments)"
