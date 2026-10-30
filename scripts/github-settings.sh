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
# Conventional Commit by the pr workflow) with an empty body. Merged branches
# are deleted.
gh api -X PATCH "repos/$repo" --silent \
  -F allow_squash_merge=true \
  -F allow_merge_commit=false \
  -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true \
  -f squash_merge_commit_title=PR_TITLE \
  -f squash_merge_commit_message=BLANK

# main only changes through a squash-merged pull request whose required
# checks pass. GitHub Actions bypasses it to push flake.lock updates.
ruleset=$(cat <<JSON
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [
    {"actor_id": $actions_app, "actor_type": "Integration", "bypass_mode": "always"}
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
      "strict_required_status_checks_policy": false,
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
