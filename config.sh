# Loads settings.json (edited from the dashboard), .env (API keys) and .install
# (launchd label and port written by install.sh) into shell variables.
# Sourced by every script. Must stay bash 3.2 compatible (macOS /bin/bash).

BOT_DIR="${BOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

SETTINGS_FILE="$BOT_DIR/settings.json"
ENV_FILE="$BOT_DIR/.env"
STATE_FILE="$BOT_DIR/state.json"
HISTORY_FILE="$BOT_DIR/history.jsonl"
LOCK_DIR="$BOT_DIR/.lock"
LOG_DIR="$BOT_DIR/logs"
RUNS_DIR="$BOT_DIR/runs"
WORKTREE_DIR="$BOT_DIR/worktrees"
CLONES_DIR="$BOT_DIR/clones"

ENGINES="claude codex gemini"
KEY_NAMES="ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY"

_settings="$SETTINGS_FILE"
[ -f "$_settings" ] || _settings="$BOT_DIR/settings.example.json"

# One jq call, emitted as NAME<TAB>VALUE lines (values are never eval'd).
while IFS="$(printf '\t')" read -r _k _v; do
  case "$_k" in
    ENGINE) ENGINE="$_v" ;;
    MODEL) MODEL="$_v" ;;
    POST_COMMENTS) POST_COMMENTS="$_v" ;;
    MAX_TURNS) MAX_TURNS="$_v" ;;
    REVIEW_TIMEOUT) REVIEW_TIMEOUT="$_v" ;;
    SKIP_LABEL) SKIP_LABEL="$_v" ;;
    SKIP_DRAFTS) SKIP_DRAFTS="$_v" ;;
    SKIP_BOTS) SKIP_BOTS="$_v" ;;
    SKIP_AUTHORS) SKIP_AUTHORS="$_v" ;;
    LOG_RETENTION_DAYS) LOG_RETENTION_DAYS="$_v" ;;
  esac
done < <(jq -r '
  "ENGINE\t\(.engine // "claude")",
  "MODEL\t\(.models[.engine // "claude"] // "")",
  "POST_COMMENTS\t\(if .post_comments then 1 else 0 end)",
  "MAX_TURNS\t\(.max_turns // 80)",
  "REVIEW_TIMEOUT\t\(.review_timeout // 1200)",
  "SKIP_LABEL\t\(.skip.label // "")",
  "SKIP_DRAFTS\t\(if .skip.drafts == false then 0 else 1 end)",
  "SKIP_BOTS\t\(if .skip.bots == false then 0 else 1 end)",
  "SKIP_AUTHORS\t\((.skip.authors // []) | join(" "))",
  "LOG_RETENTION_DAYS\t\(.log_retention_days // 7)"
' "$_settings")

# REPOS: "owner/repo|local path" (path may be empty: the bot clones it itself)
REPOS=()
while IFS= read -r _line; do
  [ -n "$_line" ] && REPOS+=("$_line")
done < <(jq -r '.repos[]? | "\(.repo)|\(.path // "")"' "$_settings")

TRIVIAL_GLOBS=()
while IFS= read -r _line; do
  [ -n "$_line" ] && TRIVIAL_GLOBS+=("$_line")
done < <(jq -r '.trivial_globs[]?' "$_settings")

# .env: only KEY=VALUE lines for known key names; never sourced as shell.
# Keys are NOT exported: review.sh hands each engine only its own key.
for _k in $KEY_NAMES; do printf -v "$_k" '%s' ""; done
if [ -f "$ENV_FILE" ]; then
  while IFS='=' read -r _k _v; do
    case " $KEY_NAMES " in *" $_k "*) printf -v "$_k" '%s' "$_v" ;; esac
  done < "$ENV_FILE"
fi

LABEL="com.$(id -un).prreviewbot"
PORT=5678
if [ -f "$BOT_DIR/.install" ]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in LABEL) LABEL="$_v" ;; PORT) PORT="$_v" ;; esac
  done < "$BOT_DIR/.install"
fi

unset _settings _k _v _line
