#!/usr/bin/env bash
# Dependabot for the flake inputs: compares each tool pinned in flake.lock
# with the latest version its input offers, keeps one open issue per tool
# that is behind (retitled when a newer version comes out), and closes the
# issue once flake.lock catches up. Run daily by .github/workflows/versions.yml.
#
#   scripts/versions.sh            # print pinned and latest versions
#   scripts/versions.sh --issues   # also open, update and close the issues
#
# Needs nix and jq; --issues also needs gh, logged in or with GH_TOKEN set.
set -euo pipefail

cd "$(dirname "$0")/.."

issues=false
[ "${1:-}" = "--issues" ] && issues=true
label=versions
system=x86_64-linux

# name|flake input|package in llm-agents (empty: the input's commit is the version)
tools=(
  "Claude Code|llm-agents|claude-code"
  "Orca|llm-agents|orca"
  "Pi|llm-agents|pi"
  "firstmate|firstmate|"
  "nixpkgs|nixpkgs|"
)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
nix flake update --refresh --output-lock-file "$tmp/latest.lock" 2>/dev/null

# locked <lock file> <input> <field>
locked() {
  jq -r --arg i "$2" --arg f "$3" '.nodes[.nodes.root.inputs[$i]].locked[$f]' "$1"
}

# Versions of the llm-agents packages at a commit, fetched once per commit.
agent_version() {
  local rev=$1 pkg=$2 cache="$tmp/agents-$1.json"
  if [ ! -f "$cache" ]; then
    nix eval --json "github:numtide/llm-agents.nix/$rev#packages.$system" \
      --apply 'p: builtins.mapAttrs (_: v: v.version or null) { inherit (p) claude-code orca pi; }' >"$cache"
  fi
  jq -r --arg p "$pkg" '.[$p]' "$cache"
}

# "2026-10-28 (45dd50a)" for inputs without a version of their own.
commit_version() {
  printf '%s (%s)' "$(date -u -d "@$(locked "$1" "$2" lastModified)" +%F)" "$(locked "$1" "$2" rev | cut -c1-7)"
}

version() {
  local lock=$1 input=$2 pkg=$3
  if [ -n "$pkg" ]; then
    agent_version "$(locked "$lock" "$input" rev)" "$pkg"
  else
    commit_version "$lock" "$input"
  fi
}

if $issues; then
  gh label create "$label" --color 0366d6 --description "A pinned tool has a newer version" --force >/dev/null
  open=$(gh issue list --label "$label" --state open --limit 100 --json number,title,body)
fi

for t in "${tools[@]}"; do
  IFS='|' read -r name input pkg <<<"$t"
  slug=$(tr 'A-Z ' 'a-z-' <<<"$name")
  pinned=$(version flake.lock "$input" "$pkg")
  latest=$(version "$tmp/latest.lock" "$input" "$pkg")
  printf '%-12s %-24s %s\n' "$name" "$pinned" "$latest"
  $issues || continue

  marker="<!-- versions: tool=$slug input=$input -->"
  number=$(jq -r --arg m "$marker" '[.[] | select(.body | contains($m))][0].number // empty' <<<"$open")

  if [ "$pinned" = "$latest" ]; then
    if [ -n "$number" ]; then
      gh issue close "$number" --comment "\`flake.lock\` now pins $name \`$pinned\`."
    fi
    continue
  fi

  owner=$(locked flake.lock "$input" owner)
  repo=$(locked flake.lock "$input" repo)
  changes="https://github.com/$owner/$repo/compare/$(locked flake.lock "$input" rev)...$(locked "$tmp/latest.lock" "$input" rev)"
  also=""
  if [ "$input" = llm-agents ]; then
    also=" Updating it also brings whatever is new in the other tools it packages (Claude Code, Orca, Pi)."
  fi
  title="$name: $pinned → $latest"
  body="$marker
**$name** has a new version: \`$pinned\` → \`$latest\`.

It comes from the \`$input\` flake input ([changes since the pinned commit]($changes)).$also

To update, run **Actions → versions → Run workflow** with \`$input\`. It opens a pull request; merging it deploys to the VPS.

This issue is retitled when a newer version comes out and closes itself once \`flake.lock\` pins it."

  if [ -z "$number" ]; then
    gh issue create --title "$title" --body "$body" --label "$label"
  elif [ "$(jq -r --argjson n "$number" '.[] | select(.number == $n) | .title' <<<"$open")" != "$title" ]; then
    gh issue edit "$number" --title "$title" --body "$body"
  fi
done
