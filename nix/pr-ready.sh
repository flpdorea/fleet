# fleet-pr-ready - notifies the phone when one of this context's open pull
# requests is ready to merge: checks green, no changes requested or review
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
  | select(.mergeable == "MERGEABLE"
      and (.reviewDecision // "APPROVED") == "APPROVED"
      and .commits.nodes[0].commit.statusCheckRollup.state == "SUCCESS"
      and all(.reviewThreads.nodes[]; .isResolved))
  | [.url, .headRefOid, .title] | @tsv')

# Forget PRs that are no longer ready, so a PR that turns red and then
# green again on the same commit notifies again.
keep=$(mktemp)
while IFS=$'\t' read -r url sha title; do
  [ -n "$url" ] || continue
  if $first || grep -qxF "$url $sha" "$seen" ||
    fleet notify "Ready to merge: $title" "${url#https://github.com/}" --url "$url"; then
    printf '%s %s\n' "$url" "$sha" >>"$keep"
  fi
done <<<"$ready"
mv "$keep" "$seen"
