# fleet-pr-ready - notifies the phone at each step of this context's open pull
# requests where you act next, as they go from a draft an agent opened to a
# merge:
#   Draft ready     a draft's checks are green (or none) and it has no
#                   conflict: the agent is done, review it.
#   Changes asked,  a reviewer other than you submitted a review. An approval
#   Comment,        that makes the PR ready to merge in the same run only
#   Approved        notifies "Ready to merge".
#   Ready to merge  out of draft, checks green (or none), approved or no
#                   review required, no unresolved thread and no conflict.
# A step notifies once per head commit, a review once. Run as the context user
# by the fleet-pr-ready-<ctx> timer.
# Packaged by the Nix module with writeShellApplication.

state="$HOME/.cache/fleet/notify"
seen="$state/pr-events"
mkdir -p "$state"
# The first run only records what is there already, so installing this does
# not notify the whole backlog at once.
first=false
[ -f "$seen" ] || first=true
# Replaced by pr-events, which also records drafts and reviews.
rm -f "$state/ready"

gh auth status >/dev/null 2>&1 || exit 0

# One JSON event per line: a PR's step (draft or merge) and each review on it.
# Titles stay short and bodies under 200 characters, what a Xiaomi Smart Band
# shows of a notification.
# shellcheck disable=SC2016 # $me, $ref and the like are jq variables
events=$(gh api graphql -f query='
  query {
    viewer { login }
    search(query: "is:pr is:open author:@me archived:false", type: ISSUE, first: 50) {
      nodes {
        ... on PullRequest {
          url number title headRefOid mergeable reviewDecision isDraft additions deletions changedFiles
          repository { name }
          commits(last: 1) { nodes { commit { statusCheckRollup { state
            contexts(first: 100) { nodes { ... on CheckRun { conclusion } ... on StatusContext { state } } } } } } }
          reviewThreads(first: 100) { nodes { isResolved } }
          latestReviews(first: 20) { nodes { id state body author { login } comments { totalCount } } }
        }
      }
    }
  }' --jq '
  def cut($n): if length > $n then .[:$n - 1] + "…" else . end;
  def count($n; $what): "\($n) \($what)\(if $n == 1 then "" else "s" end)";
  .data.viewer.login as $me
  | .data.search.nodes[]
  | . as $pr
  | "\(.repository.name)#\(.number)" as $ref
  | (.title | cut(80)) as $title
  | (.commits.nodes[0].commit.statusCheckRollup.state // "SUCCESS") as $checks
  # Skipped and neutral checks do not count as green.
  | ([.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
      | select((.conclusion // .state) == "SUCCESS")] | length) as $green
  | (if $green == 0 then "no checks" else "\(count($green; "check")) green" end) as $checktext
  | (if .mergeable == "CONFLICTING" or ($checks | IN("FAILURE", "ERROR")) then "no"
     elif .mergeable == "UNKNOWN" or ($checks | IN("PENDING", "EXPECTED")) then "pending"
     elif .isDraft then "ready"
     elif (.reviewDecision | IN("CHANGES_REQUESTED", "REVIEW_REQUIRED"))
       or any(.reviewThreads.nodes[]; .isResolved | not) then "no"
     else "ready" end) as $status
  | ([.latestReviews.nodes[] | select(.state == "APPROVED") | "@\(.author.login)"] | join(", ")) as $approvers
  | if .isDraft then
      {key: "draft \(.url) \(.headRefOid)", status: $status, url, priority: 3,
       title: "Draft ready: \($ref)",
       body: "\($title)\n+\(.additions) −\(.deletions) · \(count(.changedFiles; "file")) · \($checktext)"}
    else
      {key: "merge \(.url) \(.headRefOid)", status: $status, url, priority: 3,
       title: "Ready to merge: \($ref)",
       body: "\(if $approvers == "" then "No review" else "Approved by \($approvers)" end | cut(60)) · \($checktext)\n\($title)"}
    end,
    ( .latestReviews.nodes[]
      | select(.author.login != $me and (.state | IN("APPROVED", "CHANGES_REQUESTED", "COMMENTED")))
      # The text of the review without headings and markdown emphasis.
      | (.body | split("\n") | map(select(test("^\\s*#") | not)) | join(" ")
         | gsub("\\*\\*|`"; "") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ") | cut(90)) as $text
      | {key: "review \(.id)", status: "ready", url: $pr.url,
         priority: (if .state == "CHANGES_REQUESTED" then 4 else 3 end),
         quiet: (.state == "APPROVED"),
         title: "\({APPROVED: "Approved", CHANGES_REQUESTED: "Changes asked", COMMENTED: "Comment"}[.state]): \($ref)",
         body: "@\(.author.login)\(if $text != "" then ": \($text)"
           elif .comments.totalCount > 0 then " left \(count(.comments.totalCount; "comment"))" else "" end)\n\($title)"} )
  | @json') || exit 0

# Forget a step that is no longer ready, so a PR that turns red and then green
# again on the same commit notifies again. GitHub recomputes mergeability after
# the base moves (UNKNOWN for a while) and reruns checks (PENDING); those keep
# what was recorded, so they do not notify twice.
keep=$(mktemp)
merged_now=" "
while IFS= read -r event; do
  [ -n "$event" ] || continue
  IFS=$'\t' read -r key status url priority quiet < <(jq -r '[.key, .status, .url, .priority, .quiet // false] | @tsv' <<<"$event")
  if grep -qxsF "$key" "$seen"; then
    [ "$status" = no ] || echo "$key" >>"$keep"
  elif [ "$status" = ready ]; then
    if $first || { [ "$quiet" = true ] && [[ $merged_now == *" $url "* ]]; }; then
      echo "$key" >>"$keep"
    elif fleet notify "$(jq -r .title <<<"$event")" "$(jq -r .body <<<"$event")" --url "$url" --priority "$priority"; then
      echo "$key" >>"$keep"
      [[ $key == merge* ]] && merged_now+="$url "
    fi
  fi
done <<<"$events"
mv "$keep" "$seen"
