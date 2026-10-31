#!/usr/bin/env bash
# Applies the repo's merge settings, the ruleset that protects main, the
# environments that hold the secrets workflows on main use, and the deploy key.
# Safe to rerun: it overwrites what it manages and leaves the rest alone.
#
#   scripts/github-settings.sh [--environments] [owner/repo]
#
# --environments only creates the environments and the deploy key. It changes
# nothing the workflows on main use today, so it can run before the pull
# requests that start using them are merged.
#
# Needs gh logged in as a repo admin.
set -euo pipefail

envs_only=
if [ "${1:-}" = --environments ]; then
  envs_only=1
  shift
fi
repo="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
actions_app=15368 # GitHub Actions

# Environments hold the secrets that can change things: the deploy key
# (deploy) and Tailscale's read-write OAuth client (tailscale, filled by
# scripts/tailscale-bootstrap.sh). Only workflow runs on main can use them,
# so a pull request, even from a branch of this repo, never sees them.
for env in deploy tailscale; do
  gh api -X PUT "repos/$repo/environments/$env" --input - --silent <<<'{
    "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}
  }'
  if ! gh api "repos/$repo/environments/$env/deployment-branch-policies" \
    --jq '.branch_policies[].name' | grep -qxF main; then
    gh api -X POST "repos/$repo/environments/$env/deployment-branch-policies" \
      -f name=main -f type=branch --silent
  fi
done

# Workflows on main push to it with this deploy key: flake.lock updates and
# release tags. A ruleset on a personal repo cannot let GitHub Actions bypass
# it, but it can let deploy keys bypass it, so this key is the only way around
# the PR requirement. The private half lives only in the deploy environment's
# DEPLOY_KEY secret; when that secret is missing, a new key replaces the old one.
key_title="deploy (workflows on main)"
if ! gh secret list --repo "$repo" --env deploy --json name --jq '.[].name' | grep -qxF DEPLOY_KEY; then
  gh api "repos/$repo/keys" --jq '.[] | select(.title == "'"$key_title"'") | .id' |
    while read -r id; do gh api -X DELETE "repos/$repo/keys/$id" --silent; done
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  ssh-keygen -q -t ed25519 -N '' -C "$key_title" -f "$tmp/key"
  gh secret set DEPLOY_KEY --repo "$repo" --env deploy <"$tmp/key"
  gh repo deploy-key add "$tmp/key.pub" --repo "$repo" --allow-write --title "$key_title" >/dev/null
fi

if [ -n "$envs_only" ]; then
  echo "Applied the environments and the deploy key to $repo."
  exit 0
fi

# Left over from before the environments existed, when the deploy key and
# Tailscale's read-write client were repo secrets that any pull request from
# a branch of this repo could read. The Tailscale ones go only once
# scripts/tailscale-bootstrap.sh has copied them into the environment.
gh api "repos/$repo/keys" --jq '.[] | select(.title == "flake.lock (nix workflow)") | .id' |
  while read -r id; do gh api -X DELETE "repos/$repo/keys/$id" --silent; done
repo_secrets=$(gh secret list --repo "$repo" --json name --jq '.[].name')
env_secrets=$(gh secret list --repo "$repo" --env tailscale --json name --jq '.[].name')
for name in FLAKE_LOCK_DEPLOY_KEY TS_OAUTH_CLIENT_ID TS_OAUTH_SECRET; do
  grep -qxF "$name" <<<"$repo_secrets" || continue
  case "$name" in TS_*) grep -qxF "$name" <<<"$env_secrets" || continue ;; esac
  gh secret delete "$name" --repo "$repo"
done

# Squash only; the squash commit is the pull request title (checked to be a
# Conventional Commit by the pr workflow) with the pull request body as its body.
# Merged branches are deleted, and the "Update branch" button is shown (it can rebase).
gh api -X PATCH "repos/$repo" --silent \
  -F allow_squash_merge=true \
  -F allow_merge_commit=false \
  -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true \
  -F allow_update_branch=true \
  -f squash_merge_commit_title=PR_TITLE \
  -f squash_merge_commit_message=PR_BODY

# main only changes through a squash-merged pull request whose required
# checks pass on a branch up to date with main (so the merge cannot
# conflict), or through a deploy key.
ruleset=$(cat <<JSON
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [
    {"actor_type": "DeployKey", "bypass_mode": "always"}
  ],
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": false,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": false,
      "allowed_merge_methods": ["squash"]
    }},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": true,
      "required_status_checks": [
        {"context": "check", "integration_id": $actions_app},
        {"context": "policy", "integration_id": $actions_app},
        {"context": "pr-title", "integration_id": $actions_app},
        {"context": "pr-template", "integration_id": $actions_app}
      ]
    }}
  ]
}
JSON
)

id=$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name == "main") | .id')
if [ -n "$id" ]; then
  gh api -X PUT "repos/$repo/rulesets/$id" --input - --silent <<<"$ruleset"
else
  gh api -X POST "repos/$repo/rulesets" --input - --silent <<<"$ruleset"
fi
echo "Applied merge settings and the main ruleset to $repo."
