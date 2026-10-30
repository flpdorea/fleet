# Prepares one context user. Runs as that user, from the
# fleet-setup-<context> service. Variables set by the Nix module:
#   FLEET_CONTEXT, FLEET_PRIMARY
set -euo pipefail

FLEET="$HOME/fleet"
mkdir -p "$HOME/.local/bin" "$HOME/.npm-global" "$FLEET"
printf '%s\n' "$FLEET_CONTEXT" >"$FLEET/.context"
rm -f "$FLEET/.ready"

# Remove what firstmate left behind on machines set up before Orca's own
# skills replaced it: its clone, Kun Chen's tools it installed (no-mistakes,
# treehouse, the *-axi family) and the hooks and skills those tools added.
# Each step is a no-op once the user is clean.
if [ -d "$HOME/.no-mistakes" ]; then
  echo "removing no-mistakes"
  no-mistakes daemon stop >/dev/null 2>&1 || true
  pkill -u "$(id -u)" -f "$HOME/.no-mistakes/bin/no-mistakes" || true
fi
rm -rf "$FLEET/firstmate" "$HOME/.no-mistakes" \
  "$HOME/.local/bin/no-mistakes" "$HOME/.local/bin/treehouse" \
  "$HOME/.claude/skills/no-mistakes" "$HOME/.agents/skills/no-mistakes" \
  "$HOME/.pi/agent/skills/no-mistakes"
rm -f "$HOME"/.config/systemd/user/no-mistakes-daemon-*.service \
  "$HOME"/.config/systemd/user/*.wants/no-mistakes-daemon-*.service \
  "$HOME"/.config/opencode/plugins/axi-*.js

mapfile -t axi < <(npm ls -g --depth=0 --parseable 2>/dev/null \
  | sed -n 's|.*/node_modules/||p' | grep -E -- '-axi$' || true)
if [ ${#axi[@]} -gt 0 ]; then
  echo "removing ${axi[*]}"
  npm uninstall -g "${axi[@]}" >/dev/null
fi

# The *-axi tools register themselves as SessionStart hooks; drop those
# entries and keep every other hook (Orca's among them).
drop_axi_hooks() {
  local f=$1 tmp
  [ -f "$f" ] || return 0
  tmp=$(mktemp)
  jq '
    if (.hooks.SessionStart | type) == "array" then
      .hooks.SessionStart |= map(select(any(.hooks[]?; (.command // "") | test("^[a-z-]+-axi$")) | not))
    else . end' "$f" >"$tmp" && cat "$tmp" >"$f"
  rm -f "$tmp"
}
drop_axi_hooks "$HOME/.claude/settings.json"
drop_axi_hooks "$HOME/.codex/hooks.json"

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
