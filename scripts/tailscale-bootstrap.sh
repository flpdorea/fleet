#!/usr/bin/env bash
# One-time Tailscale setup for a tailnet, from your computer:
#   1. applies tailscale/policy.hujson (which defines tag:fleet),
#   2. creates two OAuth clients: a read-write one that CI applies the policy
#      with and scripts/tailscale-authkey.sh mints install keys with, and a
#      read-only one that CI tests pull requests with,
#   3. stores them in ~/.config/fleet/tailscale.env and in this repo's secrets:
#      the read-write client in the tailscale environment, which only main can
#      use, the read-only one at repo level and for Dependabot,
#   4. revokes the access token it was given.
#
# Run scripts/github-settings.sh first (--environments is enough): it creates
# the tailscale environment. Its next full run deletes the old repo-level copy
# of the read-write client.
# Safe to rerun: it only creates the clients missing from tailscale.env.
#
# The only browser step: Settings -> Keys -> Generate access token (1 day),
# saved with:
#   mkdir -p ~/.config/fleet && (umask 077; read -rsp 'Access token: ' t; echo; printf '%s' "$t" > ~/.config/fleet/ts-api-token)
#
# The OAuth clients are created through the API, not the admin console,
# because the read-write one must be scoped to tag:fleet, and that tag only
# exists once the policy is in.
set -euo pipefail

cd "$(dirname "$0")/.."
token_file="${FLEET_TS_TOKEN:-$HOME/.config/fleet/ts-api-token}"
env_file="${FLEET_TS_ENV:-$HOME/.config/fleet/tailscale.env}"
repo="${FLEET_REPO:-flpdorea/fleet}"
api=https://api.tailscale.com/api/v2/tailnet/-

[ -r "$token_file" ] || { echo "no access token in $token_file (see the header of $0)" >&2; exit 1; }
gh api "repos/$repo/environments/tailscale" --silent 2>/dev/null ||
  { echo "$repo has no tailscale environment; run scripts/github-settings.sh first" >&2; exit 1; }

# curl reads the Authorization header from a file, so the token stays out of argv.
auth=$(mktemp)
trap 'rm -f "$auth"' EXIT
printf 'Authorization: Bearer %s\n' "$(cat "$token_file")" >"$auth"
ts() { curl -fsS -H @"$auth" "$@"; }

# Prints the value of $1 in tailscale.env, empty if it is not there.
env_get() { sed -n "s/^$1=//p" "$env_file" 2>/dev/null; }

# Creates an OAuth client from the JSON spec on stdin and appends its id and
# secret to tailscale.env, as the variables named by $1 and $2.
create_client() {
  local client
  client=$(ts -H "Content-Type: application/json" --data @- "$api/keys")
  (
    umask 077
    jq -r --arg id "$1" --arg key "$2" '"\($id)=\(.id)\n\($key)=\(.key)"' <<<"$client" >>"$env_file"
  )
}

if [ -z "$(env_get TS_OAUTH_CLIENT_ID)" ]; then
  echo "applying tailscale/policy.hujson"
  ts -H "Content-Type: application/hujson" --data-binary @tailscale/policy.hujson "$api/acl" >/dev/null

  echo "creating the read-write OAuth client"
  create_client TS_OAUTH_CLIENT_ID TS_OAUTH_SECRET <<<'{
    "keyType": "client",
    "description": "fleet CI apply and install keys",
    "scopes": ["policy_file", "auth_keys"],
    "tags": ["tag:fleet"]
  }'
fi

if [ -z "$(env_get TS_POLICY_TEST_CLIENT_ID)" ]; then
  echo "creating the read-only OAuth client"
  create_client TS_POLICY_TEST_CLIENT_ID TS_POLICY_TEST_SECRET <<<'{
    "keyType": "client",
    "description": "fleet CI policy test",
    "scopes": ["policy_file:read"]
  }'
fi

echo "storing them in $env_file and in $repo's secrets"
for name in TS_OAUTH_CLIENT_ID TS_OAUTH_SECRET; do
  printf "%s" "$(env_get "$name")" | gh secret set "$name" --repo "$repo" --env tailscale
done
# Dependabot's pull requests get Dependabot secrets, not Actions secrets, so
# the read-only client goes to both.
for name in TS_POLICY_TEST_CLIENT_ID TS_POLICY_TEST_SECRET; do
  printf "%s" "$(env_get "$name")" | gh secret set "$name" --repo "$repo"
  printf "%s" "$(env_get "$name")" | gh secret set "$name" --repo "$repo" --app dependabot
done

echo "revoking the access token"
token_id=$(cut -d- -f3 "$token_file")
ts -X DELETE "$api/keys/$token_id" >/dev/null || echo "warning: revoke it in Settings -> Keys" >&2
rm -f "$token_file"
echo "done"
