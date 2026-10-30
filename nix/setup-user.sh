# Prepares one context user. Runs as that user, from the
# fleet-setup-<context> service. Variables set by the Nix module:
#   FLEET_CONTEXT, FLEET_PRIMARY
set -euo pipefail

FLEET="$HOME/fleet"
mkdir -p "$HOME/.local/bin" "$HOME/.npm-global" "$FLEET"
printf '%s\n' "$FLEET_CONTEXT" >"$FLEET/.context"
rm -f "$FLEET/.ready"

# Orca's own orchestration skills, installed globally for this context's
# harness (~/.claude/skills for Claude Code). The skills CLI fetches
# them from the Orca repo, so they are not pinned; reinstalling just refreshes them.
case "$FLEET_PRIMARY" in
  claude) agent=claude-code ;;
  *)      agent="$FLEET_PRIMARY" ;;
esac
echo "installing Orca skills for $agent"
orca skills install --skill orca-cli --skill orchestration --agent "$agent"

touch "$FLEET/.ready"
echo "fleet ready"
