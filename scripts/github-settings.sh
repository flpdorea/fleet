#!/usr/bin/env bash
# Applies the repo's merge settings and the ruleset that protects main.
# Safe to rerun: it overwrites what it manages and leaves the rest alone.
#
#   scripts/github-settings.sh [owner/repo]
#
# Needs gh logged in as a repo admin.
set -euo pipefail

repo="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
actions_app=15368 # GitHub Actions

# Squash only; the squash commit is the pull request title (checked to be a
# Conventional Commit by the pr workflow) with the commit messages as the body.
# Merged branches are deleted, and the "Update branch" button is shown (it can rebase).
gh api -X PATCH "repos/$repo" --silent \
  -F allow_squash_merge=true \
  -F allow_merge_commit=false \
  -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true \
  -F allow_update_branch=true \
  -f squash_merge_commit_title=PR_TITLE \
  -f squash_merge_commit_message=COMMIT_MESSAGES

# The nix workflow pushes flake.lock updates to main with this deploy key.
# A ruleset on a personal repo cannot let GitHub Actions bypass it, but it
# can let deploy keys bypass it, so this key is the only way around the PR
# requirement. The private half lives only in the FLAKE_LOCK_DEPLOY_KEY secret.
key_title="flake.lock (nix workflow)"
if ! gh api "repos/$repo/keys" --jq '.[].title' | grep -qxF "$key_title"; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  ssh-keygen -q -t ed25519 -N '' -C "$key_title" -f "$tmp/key"
  gh secret set FLAKE_LOCK_DEPLOY_KEY --repo "$repo" <"$tmp/key"
  gh repo deploy-key add "$tmp/key.pub" --repo "$repo" --allow-write --title "$key_title" >/dev/null
fi

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
