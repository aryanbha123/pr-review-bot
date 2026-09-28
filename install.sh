#!/bin/bash
# Installs the bot as two launchd agents for the current user (macOS only):
#   <label>            runs poll.sh every 30s
#   <label>.dashboard  serves the dashboard on 127.0.0.1:<port>, started on demand
# Safe to re-run: it rewrites the plists and reloads both agents.
#   PRBOT_LABEL=com.me.prreviewbot PRBOT_PORT=5678 ./install.sh
set -euo pipefail

BOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BOT_DIR"
[ "$(uname)" = "Darwin" ] || { echo "install.sh uses launchd and only supports macOS." >&2; exit 1; }

# Keep an existing install's label/port unless overridden.
OLD_LABEL=""; OLD_PORT=""
if [ -f .install ]; then
  OLD_LABEL="$(sed -n 's/^LABEL=//p' .install)"; OLD_PORT="$(sed -n 's/^PORT=//p' .install)"
fi
LABEL="${PRBOT_LABEL:-${OLD_LABEL:-com.$(id -un).prreviewbot}}"
PORT="${PRBOT_PORT:-${OLD_PORT:-5678}}"
case "$LABEL" in *[!A-Za-z0-9._-]*) echo "bad label: $LABEL" >&2; exit 1 ;; esac
case "$PORT" in ''|*[!0-9]*) echo "bad port: $PORT" >&2; exit 1 ;; esac

echo "== Checking requirements"
missing=0
for t in git jq gh curl; do
  if p="$(command -v "$t")"; then echo "  ok      $t ($p)"; else echo "  MISSING $t"; missing=1; fi
done
engines=0
for t in claude codex gemini; do
  if p="$(command -v "$t")"; then echo "  ok      $t ($p)"; engines=$((engines + 1)); else echo "  -       $t (optional)"; fi
done
[ "$missing" -eq 0 ] || { echo "Install the missing tools and re-run." >&2; exit 1; }
[ "$engines" -gt 0 ] || { echo "Install at least one engine: claude, codex or gemini." >&2; exit 1; }
if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not logged in. Run: gh auth login   (or: pbpaste | gh auth login --with-token)" >&2
  exit 1
fi
echo "  gh logged in as $(gh api user --jq .login)"

echo "== Config"
[ -f settings.json ] || { cp settings.example.json settings.json; echo "  created settings.json (posting is OFF until you enable it)"; }
if [ ! -f .env ]; then ( umask 077; cp .env.example .env ); echo "  created .env"; fi
chmod 600 .env
mkdir -p logs runs worktrees
chmod +x poll.sh review.sh status.sh uninstall.sh dashboard/*.sh
printf 'LABEL=%s\nPORT=%s\n' "$LABEL" "$PORT" > .install

# launchd does not read shell profiles: record where every tool lives right now.
path_dirs=""
for t in git jq gh curl node claude codex gemini; do
  p="$(command -v "$t" 2>/dev/null)" || continue
  d="$(dirname "$p")"
  case ":$path_dirs:" in *":$d:"*) ;; *) path_dirs="${path_dirs:+$path_dirs:}$d" ;; esac
done
AGENT_PATH="$path_dirs:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

AGENTS="$HOME/Library/LaunchAgents"
mkdir -p "$AGENTS"
render() {  # template -> plist
  sed -e "s|@LABEL@|$LABEL|g" -e "s|@PORT@|$PORT|g" -e "s|@BOT_DIR@|$BOT_DIR|g" \
      -e "s|@HOME@|$HOME|g" -e "s|@PATH@|$AGENT_PATH|g" "$1" > "$2"
  plutil -lint "$2" >/dev/null
}

echo "== launchd agents"
for old in "$OLD_LABEL" "$LABEL"; do
  [ -n "$old" ] || continue
  launchctl bootout "gui/$(id -u)/$old" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/$old.dashboard" 2>/dev/null || true
done
if [ -n "$OLD_LABEL" ] && [ "$OLD_LABEL" != "$LABEL" ]; then
  rm -f "$AGENTS/$OLD_LABEL.plist" "$AGENTS/$OLD_LABEL.dashboard.plist"
fi
render templates/poll.plist.in "$AGENTS/$LABEL.plist"
render templates/dashboard.plist.in "$AGENTS/$LABEL.dashboard.plist"
launchctl bootstrap "gui/$(id -u)" "$AGENTS/$LABEL.dashboard.plist"
launchctl bootstrap "gui/$(id -u)" "$AGENTS/$LABEL.plist"
echo "  loaded $LABEL (every 30s) and $LABEL.dashboard (port $PORT)"

sleep 1
if curl -s -o /dev/null -m 5 "http://127.0.0.1:$PORT/api/status"; then
  echo
  echo "Dashboard: http://localhost:$PORT"
  echo "Next: open it, go to Settings, add repositories, pick an engine, and turn posting on when ready."
else
  echo "Dashboard did not answer on port $PORT; see logs/dashboard.err" >&2
fi
