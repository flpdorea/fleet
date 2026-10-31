# fleet-pr-ready - notifies the phone when one of this context's open pull
# requests is ready to merge: checks green (or none), no changes requested or review
# missing, no unresolved thread and no conflict. Drafts count, since agents
# open drafts and you mark them ready when you merge. Each PR notifies once
# per head commit. Run as the context user by the fleet-pr-ready-<ctx> timer.
# Packaged by the Nix module with writeShellApplication.

state="$HOME/.cache/fleet/notify"
seen="$state/ready"
mkdir -p "$state"
# The first run only records what is ready already, so installing this
# does not notify the whole backlog at once.
first=false
[ -f "$seen" ] || first=true

gh auth status >/dev/null 2>&1 || exit 0

ready=$(gh api graphql -f query='
  query {
    search(query: "is:pr is:open author:@me archived:false", type: ISSUE, first: 50) {
      nodes {
        ... on PullRequest {
          url title headRefOid mergeable reviewDecision
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          reviewThreads(first: 100) { nodes { isResolved } }
        }
      }
    }
  }' --jq '
  .data.search.nodes[]
  | (.commits.nodes[0].commit.statusCheckRollup.state // "SUCCESS") as $checks
  | (if .mergeable == "CONFLICTING" or ($checks | IN("FAILURE", "ERROR"))
        or (.reviewDecision | IN("CHANGES_REQUESTED", "REVIEW_REQUIRED"))
        or any(.reviewThreads.nodes[]; .isResolved | not) then "no"
     elif .mergeable == "UNKNOWN" or ($checks | IN("PENDING", "EXPECTED")) then "pending"
     else "ready" end) as $status
  | [.url, .headRefOid, $status, .title] | @tsv') || exit 0

# Forget PRs that are no longer ready, so a PR that turns red and then
# green again on the same commit notifies again. GitHub recomputes
# mergeability after the base moves (UNKNOWN for a while) and reruns checks
# (PENDING); those keep what was recorded, so they do not notify twice.
keep=$(mktemp)
while IFS=$'\t' read -r url sha status title; do
  [ -n "$url" ] || continue
  if grep -qxsF "$url $sha" "$seen"; then
    [ "$status" = no ] || printf '%s %s\n' "$url" "$sha" >>"$keep"
  elif [ "$status" = ready ] && { $first ||
    fleet notify "Ready to merge: $title" "${url#https://github.com/}" --url "$url"; }; then
    printf '%s %s\n' "$url" "$sha" >>"$keep"
  fi
done <<<"$ready"
mv "$keep" "$seen"
