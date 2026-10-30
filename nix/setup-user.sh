# Prepares one context user. Runs as that user, from the
# fleet-setup-<context> service. Variables set by the Nix module:
#   FLEET_CONTEXT, FLEET_PRIMARY, FLEET_CLAUDE_SETTINGS, FLEET_CLAUDE_MD,
#   FLEET_CLAUDE_SKILLS
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

# Our Claude Code settings (homes/claude-settings.json), merged over the
# user's: Orca writes its hooks and status line to the same file, so it
# is never replaced. Keys set here win on every run, even over /config.
# The global instructions (homes/CLAUDE.md) belong to the repo and are
# replaced on every run.
if [ "$FLEET_PRIMARY" = claude ]; then
  echo "applying Claude Code settings and instructions"
  mkdir -p "$HOME/.claude"
  install -m 644 "$FLEET_CLAUDE_MD" "$HOME/.claude/CLAUDE.md"
  settings="$HOME/.claude/settings.json"
  [ -s "$settings" ] || echo '{}' >"$settings"
  tmp=$(mktemp)
  jq -s '.[0] * .[1]' "$settings" "$FLEET_CLAUDE_SETTINGS" >"$tmp" && cat "$tmp" >"$settings"
  rm -f "$tmp"

  # Our skills (homes/skills) and Anthropic's skill-creator, replaced on
  # every run. Store copies are read-only, so make them writable again.
  echo "installing Claude Code skills"
  mkdir -p "$HOME/.claude/skills"
  for skill in "$FLEET_CLAUDE_SKILLS"/*/; do
    dest="$HOME/.claude/skills/$(basename "$skill")"
    rm -rf "$dest"
    cp -r "${skill%/}" "$dest"
    chmod -R u+w "$dest"
  done
fi

# The gh-stack extension for stacked PRs (homes/skills/gh-stack). Needs the
# network, and usually `gh auth login` for rate limits; a failure must not
# block the rest of the setup, and the next rebuild retries.
if gh extension list 2>/dev/null | grep -q 'github/gh-stack'; then
  gh extension upgrade gh-stack >/dev/null 2>&1 || true
else
  echo "installing the gh-stack extension"
  gh extension install github/gh-stack || echo "gh-stack install failed; run 'gh extension install github/gh-stack' as $FLEET_CONTEXT" >&2
fi

# Default language runtimes from /etc/mise/config.toml (homes/mise.toml).
# Already installed versions are skipped. A failed download must not block
# the rest of the setup; the next rebuild or a manual `mise install` retries.
echo "installing default runtimes with mise"
cd "$HOME"
MISE_YES=1 mise install || echo "mise install failed; run it again as $FLEET_CONTEXT" >&2

touch "$FLEET/.ready"
echo "fleet ready"
