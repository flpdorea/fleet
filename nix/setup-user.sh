# Prepares one user's firstmate. Runs as that user, from the
# fleet-setup-<context> service. Variables set by the Nix module:
#   FLEET_CONTEXT, FLEET_PRIMARY, FLEET_CONFIG_SRC, FIRSTMATE_REV
set -euo pipefail

FLEET="$HOME/fleet"
FM="$FLEET/firstmate"
mkdir -p "$HOME/.local/bin" "$HOME/.npm-global" "$FLEET"
printf '%s\n' "$FLEET_CONTEXT" >"$FLEET/.context"

echo "firstmate @ ${FIRSTMATE_REV:0:12}"
[ -d "$FM/.git" ] || git clone -q https://github.com/kunchenguid/firstmate "$FM"
if [ "$(git -C "$FM" rev-parse HEAD)" != "$FIRSTMATE_REV" ]; then
  git -C "$FM" fetch -q origin
  git -C "$FM" checkout -q --detach "$FIRSTMATE_REV"
fi

# The firstmate home is the clone itself. Config from this repo is copied,
# not linked: firstmate refuses some symlinks, and the Nix store is read-only.
mkdir -p "$FM/config"
for f in "$FLEET_CONFIG_SRC"/*; do
  install -m 644 "$f" "$FM/config/$(basename "$f")"
done
if [ "$FLEET_PRIMARY" = pi ]; then
  # Pin Pi workers to the ChatGPT subscription (the openai-codex provider).
  mkdir -p "$HOME/.pi/agent"
  printf '%s\nopenai-codex\n' "$HOME/.pi/agent" >"$FM/config/pi-account"
fi

# firstmate reports what its own toolchain is missing (no-mistakes, *-axi...).
detect() { FM_BOOTSTRAP_DETECT_ONLY=1 "$FM/bin/fm-bootstrap.sh" 2>/dev/null || true; }
for tool in $(detect | sed -n 's/^MISSING: \([^ ]*\) .*/\1/p' | sort -u); do
  echo "installing $tool"
  "$FM/bin/fm-bootstrap.sh" install "$tool" || echo "warning: $tool failed to install" >&2
done

leftover=$(detect | grep -E '^(MISSING|MISSING_MANUAL|CREW_DISPATCH|BACKEND_INVALID)' | sort -u || true)
if [ -n "$leftover" ]; then
  echo "firstmate still reports:"
  printf '%s\n' "$leftover" | sed 's/^/  /'
else
  echo "firstmate ready"
fi
