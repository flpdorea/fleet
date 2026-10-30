#!/usr/bin/env bash
# Pushes to this repo over SSH with the deploy key in $DEPLOY_KEY, the only
# actor the rulesets let through (scripts/github-settings.sh). The key exists
# in a temporary file only for this push, and GitHub's host keys come from its
# API over HTTPS instead of being trusted on first connection.
#
#   DEPLOY_KEY=... .github/scripts/deploy-push.sh <refspec>...
set -euo pipefail

: "${DEPLOY_KEY:?not set}"
: "${GITHUB_REPOSITORY:?not set}"

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
(
  umask 077
  printf '%s\n' "$DEPLOY_KEY" >"$dir/key"
)
curl -fsS https://api.github.com/meta | jq -r '.ssh_keys[] | "github.com " + .' >"$dir/known_hosts"
git -c core.sshCommand="ssh -i $dir/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$dir/known_hosts" \
  push "git@github.com:$GITHUB_REPOSITORY.git" "$@"
