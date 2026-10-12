#!/usr/bin/env bash
# Prints a Tailscale auth key for one fleet VPS: single-use, pre-approved,
# tagged tag:fleet, valid for one hour. Run it on your computer, inline in
# the install command, so the key never sits in a file or a chat:
#
#   ssh -t fleet "curl -fsSL .../install.sh | TS_AUTHKEY=$(scripts/tailscale-authkey.sh) bash"
#
# Uses the OAuth client described in docs/installation.md, read from
# ~/.config/fleet/tailscale.env unless TS_OAUTH_CLIENT_ID is already set.
set -euo pipefail

env_file="${FLEET_TS_ENV:-$HOME/.config/fleet/tailscale.env}"
if [ -z "${TS_OAUTH_CLIENT_ID:-}" ] && [ -r "$env_file" ]; then
  # shellcheck disable=SC1090
  . "$env_file"
fi
: "${TS_OAUTH_CLIENT_ID:?not set and not found in $env_file (see docs/installation.md)}"
: "${TS_OAUTH_SECRET:?not set and not found in $env_file (see docs/installation.md)}"

# The secret goes through stdin, not argv, so it never shows up in ps.
token=$(printf 'client_id=%s&client_secret=%s' "$TS_OAUTH_CLIENT_ID" "$TS_OAUTH_SECRET" \
  | curl -fsS --data @- https://api.tailscale.com/api/v2/oauth/token \
  | jq -r .access_token)

# Tagged nodes never hit key expiry, and the tag is what the policy uses to
# keep the VPS from opening connections to your other devices.
printf '%s' '{
  "capabilities": { "devices": { "create": {
    "reusable": false, "ephemeral": false, "preauthorized": true, "tags": ["tag:fleet"]
  } } },
  "expirySeconds": 3600,
  "description": "fleet install"
}' | curl -fsS -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
  --data @- https://api.tailscale.com/api/v2/tailnet/-/keys \
  | jq -r .key
