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
  -f squash_merge_commit_message=PR_BODY \
  -F has_wiki=false \
  -F has_projects=false

# Security reports arrive privately (SECURITY.md), and Dependabot raises
# alerts and opens fixes for vulnerable actions.
gh api -X PUT "repos/$repo/private-vulnerability-reporting" --silent
gh api -X PUT "repos/$repo/vulnerability-alerts" --silent
gh api -X PUT "repos/$repo/automated-security-fixes" --silent

# Secret scanning and push protection are on for every public repo; these
# also catch generic secrets (passwords, private keys) and check whether a
# leaked token still works. They may need a paid plan, so a refusal only warns.
gh api -X PATCH "repos/$repo" --input - --silent <<<'{"security_and_analysis": {
  "secret_scanning_non_provider_patterns": {"status": "enabled"},
  "secret_scanning_validity_checks": {"status": "enabled"}
}}' || echo "warning: could not enable generic secret patterns and validity checks" >&2

# Workflows from anyone without write access wait for a maintainer's
# approval, not only those from first-time contributors.
gh api -X PUT "repos/$repo/actions/permissions/fork-pr-contributor-approval" \
  -f approval_policy=all_external_contributors --silent

# Workflows may only use actions pinned to a full commit SHA, from GitHub or
# from this list. Adding an action to a workflow means adding it here.
gh api -X PUT "repos/$repo/actions/permissions" --silent \
  -F enabled=true -f allowed_actions=selected -F sha_pinning_required=true
gh api -X PUT "repos/$repo/actions/permissions/selected-actions" --input - --silent <<<'{
  "github_owned_allowed": true,
  "verified_allowed": false,
  "patterns_allowed": [
    "amannn/action-semantic-pull-request@*",
    "DeterminateSystems/nix-installer-action@*",
    "tailscale/gitops-acl-action@*"
  ]
}'

# Creates the ruleset named $1, or replaces it, with the JSON on stdin.
apply_ruleset() {
  local id
  id=$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$1\") | .id")
  if [ -n "$id" ]; then
    gh api -X PUT "repos/$repo/rulesets/$id" --input - --silent
  else
    gh api -X POST "repos/$repo/rulesets" --input - --silent
  fi
}

# main only changes through a squash-merged pull request whose required
# checks pass on a branch up to date with main (so the merge cannot
# conflict), with every review thread resolved, or through a deploy key.
# Its history stays linear and signed: GitHub signs the squash commits.
apply_ruleset main <<JSON
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
    {"type": "required_linear_history"},
    {"type": "required_signatures"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": false,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": true,
      "allowed_merge_methods": ["squash"]
    }},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": true,
      "required_status_checks": [
        {"context": "check", "integration_id": $actions_app},
        {"context": "policy", "integration_id": $actions_app},
        {"context": "pr-title", "integration_id": $actions_app},
        {"context": "pr-template", "integration_id": $actions_app},
        {"context": "pr-base", "integration_id": $actions_app},
        {"context": "pr-issue", "integration_id": $actions_app}
      ]
    }}
  ]
}
JSON

# Branches follow a few name patterns: the Orca worktree prefix (the owner's
# login), a Conventional Commit type, Dependabot's, or GitHub's Revert button's
# (revert-123-...). A branch named like a release tag (v1.2.3) cannot exist.
# People outside the repo push to their forks, so this only binds the
# maintainer, the agents and the bots.
apply_ruleset branch-names <<JSON
{
  "name": "branch-names",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {
    "include": ["~ALL"],
    "exclude": [
      "~DEFAULT_BRANCH",
      "refs/heads/${repo%%/*}/**",
      "refs/heads/feat/**", "refs/heads/fix/**", "refs/heads/docs/**", "refs/heads/chore/**",
      "refs/heads/perf/**", "refs/heads/build/**", "refs/heads/style/**", "refs/heads/revert/**",
      "refs/heads/ci/**", "refs/heads/refactor/**", "refs/heads/test/**",
      "refs/heads/dependabot/**", "refs/heads/revert-*"
    ]
  }},
  "rules": [{"type": "creation"}]
}
JSON

# Only the release workflow creates tags, with the deploy key, and a tag never
# moves or disappears once pushed. A release cannot change after it is
# published either, so a version always means the same code and install.sh.
apply_ruleset tags <<'JSON'
{
  "name": "tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~ALL"], "exclude": []}},
  "bypass_actors": [
    {"actor_type": "DeployKey", "bypass_mode": "always"}
  ],
  "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}]
}
JSON
gh api -X PUT "repos/$repo/immutable-releases" --silent

echo "Applied the repository settings and rulesets to $repo."
