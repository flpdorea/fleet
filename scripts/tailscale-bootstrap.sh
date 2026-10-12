#!/usr/bin/env bash
# One-time Tailscale setup for a tailnet, from your computer:
#   1. applies tailscale/policy.hujson (which defines tag:fleet),
#   2. creates the OAuth client that CI and scripts/tailscale-authkey.sh use,
#   3. stores it in ~/.config/fleet/tailscale.env and in this repo's secrets,
#   4. revokes the access token it was given.
#
# The only browser step: Settings -> Keys -> Generate access token (1 day),
# saved with:
#   mkdir -p ~/.config/fleet && (umask 077; read -rsp 'Access token: ' t; echo; printf '%s' "$t" > ~/.config/fleet/ts-api-token)
#
# The OAuth client is created through the API, not the admin console, because
# it must be scoped to tag:fleet, and that tag only exists once the policy is in.
set -euo pipefail

cd "$(dirname "$0")/.."
token_file="${FLEET_TS_TOKEN:-$HOME/.config/fleet/ts-api-token}"
env_file="${FLEET_TS_ENV:-$HOME/.config/fleet/tailscale.env}"
repo="${FLEET_REPO:-flpdorea/fleet}"
api=https://api.tailscale.com/api/v2/tailnet/-

[ -r "$token_file" ] || { echo "no access token in $token_file (see the header of $0)" >&2; exit 1; }
[ -e "$env_file" ] && { echo "$env_file already exists; delete it to create a new OAuth client" >&2; exit 1; }

# curl reads the Authorization header from a file, so the token stays out of argv.
auth=$(mktemp)
trap 'rm -f "$auth"' EXIT
printf 'Authorization: Bearer %s\n' "$(cat "$token_file")" >"$auth"
ts() { curl -fsS -H @"$auth" "$@"; }

echo "applying tailscale/policy.hujson"
ts -H "Content-Type: application/hujson" --data-binary @tailscale/policy.hujson "$api/acl" >/dev/null

echo "creating the OAuth client"
client=$(printf '%s' '{
  "keyType": "client",
  "description": "fleet CI and install keys",
  "scopes": ["policy_file", "auth_keys"],
  "tags": ["tag:fleet"]
}' | ts -H "Content-Type: application/json" --data @- "$api/keys")
(
  umask 077
  jq -r '"TS_OAUTH_CLIENT_ID=\(.id)\nTS_OAUTH_SECRET=\(.key)"' <<<"$client" >"$env_file"
)

echo "storing it in $env_file and in $repo's secrets"
gh secret set -R "$repo" -f "$env_file"

echo "revoking the access token"
token_id=$(cut -d- -f3 "$token_file")
ts -X DELETE "$api/keys/$token_id" >/dev/null || echo "warning: revoke it in Settings -> Keys" >&2
rm -f "$token_file"
echo "done"
