#!/bin/bash
# Stops and removes both launchd agents. Keeps settings, keys, state and logs;
# delete the folder yourself if you want those gone too.
BOT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$BOT_DIR/config.sh"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "stopped $LABEL"
launchctl bootout "gui/$(id -u)/$LABEL.dashboard" 2>/dev/null && echo "stopped $LABEL.dashboard"
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/Library/LaunchAgents/$LABEL.dashboard.plist"
rm -f "$BOT_DIR/.install"

# Worktrees are registered in each clone's .git; remove them cleanly.
for wt in "$BOT_DIR"/worktrees/*/; do
  [ -d "$wt" ] || continue
  git -C "$wt" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
done
echo "Uninstalled. Settings, .env, state.json and history.jsonl are still in $BOT_DIR."
