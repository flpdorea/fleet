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
# A stack of pull requests (gh stack) is reviewed and merged as a whole, so its
# pull requests notify "Draft ready" and "Ready to merge" once for the whole
# stack, when all its open ones are; their reviews still notify one by one,
# with their place in the stack.
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

prs=$(gh api graphql -f query='
  query {
    viewer { login }
    search(query: "is:pr is:open author:@me archived:false", type: ISSUE, first: 50) {
      nodes {
        ... on PullRequest {
          url number title headRefOid headRefName baseRefName mergeable reviewDecision isDraft
          additions deletions changedFiles
          repository { name nameWithOwner }
          commits(last: 1) { nodes { commit { statusCheckRollup { state
            contexts(first: 100) { nodes { ... on CheckRun { conclusion } ... on StatusContext { state } } } } } } }
          reviewThreads(first: 100) { nodes { isResolved } }
          latestReviews(first: 20) { nodes { id state body author { login } comments { totalCount } } }
          latestOpinionatedReviews(first: 20) { nodes { state author { login } } }
        }
      }
    }
  }') || exit 0

# The stack of each pull request that can be in one, keyed by URL: GraphQL
# does not have it, the REST API does ({number, position, size}). Only pull
# requests chained to another of yours by their branches can be.
stacks=$(
  jq -r '[.data.search.nodes[]] as $all | $all[]
    | . as $pr
    | select(any($all[]; .repository.nameWithOwner == $pr.repository.nameWithOwner
        and (.baseRefName == $pr.headRefName or .headRefName == $pr.baseRefName)))
    | "\(.repository.nameWithOwner) \(.number) \(.url)"' <<<"$prs" |
    while read -r repo number url; do
      gh api "repos/$repo/pulls/$number" --jq "select(.stack) | {\"$url\": .stack}" ||
        printf '{"%s": "unknown"}\n' "$url"
    done | jq -s 'add // {}'
)

# One JSON event per line: each pull request's step (draft or merge), each
# stack's, then each review. Titles stay short and bodies under 200
# characters, what a Xiaomi Smart Band shows of a notification.
# shellcheck disable=SC2016 # $me, $ref and the like are jq variables
events=$(jq -r --argjson stacks "$stacks" '
  def cut($n): if length > $n then .[:$n - 1] + "…" else . end;
  def count($n; $what): "\($n) \($what)\(if $n == 1 then "" else "s" end)";
  .data.viewer.login as $me
  | [ .data.search.nodes[]
      | ($stacks[.url] | if type == "object" then . else null end) as $stack
      | (.commits.nodes[0].commit.statusCheckRollup.state // "SUCCESS") as $checks
      | . + {
          ref: "\(.repository.name)#\(.number)",
          short: (.title | cut(80)),
          stack: $stack,
          group: (if $stack then "\(.repository.nameWithOwner)/stack/\($stack.number)" else null end),
          # Its stack could not be read this run: wait, rather than notify it
          # alone now and with its stack later.
          unsure: ($stacks[.url] == "unknown"),
          checks: [.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?],
          approvers: [.latestOpinionatedReviews.nodes[] | select(.state == "APPROVED")
            | "@\(.author.login // "ghost")"],
          status: (if .mergeable == "CONFLICTING" or ($checks | IN("FAILURE", "ERROR")) then "no"
            elif .mergeable == "UNKNOWN" or ($checks | IN("PENDING", "EXPECTED")) then "pending"
            elif .isDraft then "ready"
            elif (.reviewDecision | IN("CHANGES_REQUESTED", "REVIEW_REQUIRED"))
              or any(.reviewThreads.nodes[]; .isResolved | not) then "no"
            else "ready" end) } ] as $prs
  # Skipped and neutral checks do not count as green.
  | def checktext($checks): ($checks | map(select((.conclusion // .state) == "SUCCESS")) | length) as $green
      | if $checks == [] then "no checks"
        elif $green == ($checks | length) then "\(count($green; "check")) green"
        else "\($green) of \(count($checks | length; "check")) green" end;
  # A pull request in a stack only records its step; the stack notifies.
    ( $prs[]
      | if .isDraft then
          {key: "draft \(.url) \(.headRefOid)", status, url, priority: 3, silent: (.group != null or .unsure),
           title: "Draft ready: \(.ref)",
           body: "\(.short)\n+\(.additions) −\(.deletions) · \(count(.changedFiles; "file")) · \(checktext(.checks))"}
        else
          {key: "merge \(.url) \(.headRefOid)", status, url, priority: 3, silent: (.group != null or .unsure),
           title: "Ready to merge: \(.ref)",
           body: "\(if .approvers == [] then "No review" else "Approved by \(.approvers | join(", "))" end | cut(60)) · \(checktext(.checks))\n\(.short)"}
        end ),
    # A stack notifies once all its open pull requests are drafts, or all are out
    # of draft, and all of them are ready.
    ( $prs | map(select(.group)) | group_by(.group)[]
      | sort_by(.stack.position)
      | select(map(.isDraft) | unique | length == 1)
      | .[0].isDraft as $draft
      | (map(.number)) as $numbers
      | "\(.[0].repository.name) #\(if $numbers == [range($numbers[0]; $numbers[0] + length)]
          then "\($numbers[0])-\($numbers[-1])" else "\($numbers[0]) +\(length - 1)" end)" as $refs
      | map(.checks[]) as $checks
      | ((.[:3] | map("\(.stack.position) \(.title | cut(40))")) + (if length > 3 then ["+\(length - 3) more"] else [] end)
         | join("\n")) as $list
      | {key: "\(if $draft then "stack-draft" else "stack-merge" end) \(.[0].group) \(map(.headRefOid) | join(","))",
         status: (map(.status) | if any(. == "no") then "no" elif all(. == "ready") then "ready" else "pending" end),
         url: .[0].url, urls: map(.url), priority: 3,
         title: (if $draft then "Stack ready: \($refs)" else "Stack ready to merge: \($refs)" end),
         body: (if $draft then "\(count(length; "draft")) · \(checktext($checks))"
           else "\(map(select(.approvers != [])) | length) of \(length) approved · \(checktext($checks))" end) + "\n" + $list} ),
    ( $prs[] | . as $pr
      | .latestReviews.nodes[]
      | (.author.login // "ghost") as $who
      | select($who != $me and (.state | IN("APPROVED", "CHANGES_REQUESTED", "COMMENTED")))
      # The text of the review without headings and markdown emphasis.
      | (.body | split("\n") | map(select(test("^\\s*#") | not)) | join(" ")
         | gsub("\\*\\*|`"; "") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ") | cut(90)) as $text
      # A comment whose text and comments were all deleted says nothing.
      | select(.state != "COMMENTED" or $text != "" or .comments.totalCount > 0)
      | {key: "review \($pr.url) \(.id)", status: "ready", url: $pr.url,
         priority: (if .state == "CHANGES_REQUESTED" then 4 else 3 end),
         quiet: (.state == "APPROVED"),
         title: "\({APPROVED: "Approved", CHANGES_REQUESTED: "Changes asked", COMMENTED: "Comment"}[.state]): \($pr.ref)",
         body: "@\($who)\(if $text != "" then ": \($text)"
           elif .comments.totalCount > 0 then " left \(count(.comments.totalCount; "comment"))" else "" end)\n\(
           if $pr.stack then "\($pr.stack.position)/\($pr.stack.size) · " else "" end)\($pr.short)"} )
  | .body |= cut(199)
  | @json' <<<"$prs") || exit 0

# Forget a step that is no longer ready, so a PR that turns red and then green
# again on the same commit notifies again. GitHub recomputes mergeability after
# the base moves (UNKNOWN for a while) and reruns checks (PENDING); those keep
# what was recorded, so they do not notify twice.
keep=$(mktemp)
merged_now=" "
while IFS= read -r event; do
  [ -n "$event" ] || continue
  IFS=$'\t' read -r key status url priority silent quiet < <(jq -r \
    '[.key, .status, .url, .priority, .silent // false, .quiet // false] | @tsv' <<<"$event")
  if grep -qxsF "$key" "$seen"; then
    [ "$status" = no ] || echo "$key" >>"$keep"
  elif [ "$status" = ready ]; then
    if $first || [ "$silent" = true ] || { [ "$quiet" = true ] && [[ $merged_now == *" $url "* ]]; }; then
      echo "$key" >>"$keep"
    elif fleet notify "$(jq -r .title <<<"$event")" "$(jq -r .body <<<"$event")" --url "$url" --priority "$priority"; then
      echo "$key" >>"$keep"
      if [[ $key == merge* || $key == stack-merge* ]]; then
        merged_now+="$(jq -r '.urls // [.url] | join(" ")' <<<"$event") "
      fi
    fi
  fi
done <<<"$events"
# Keep what this run did not see, so a pull request missing from a degraded or
# truncated search does not notify again once it is back. Keys of closed pull
# requests stay too; they are few.
present=$(jq -r --argjson stacks "$stacks" '.data.search.nodes[]
  | .url, ($stacks[.url] as $s | if ($s | type) == "object"
      then "\(.repository.nameWithOwner)/stack/\($s.number)" else empty end)' <<<"$prs")
if [ -f "$seen" ]; then
  while read -r kind id rest; do
    grep -qxF "$id" <<<"$present" || echo "$kind $id $rest" >>"$keep"
  done <"$seen"
fi
mv "$keep" "$seen"
