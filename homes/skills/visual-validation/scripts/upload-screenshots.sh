#!/usr/bin/env bash
# Publish screenshots so a PR body can embed them.
#
# Usage: upload-screenshots.sh <dir> <key>
#
# Run it inside the repository the PR belongs to. It commits every image under
# <dir> to <key>/ on the pr-screenshots branch of origin, without touching the
# working tree, the index or the current branch, and prints the base URL. Embed
# a file as ![alt](<base URL>/<path relative to dir>?raw=true). The URL pins the
# commit, so later uploads never change images already in a PR body. Running it
# again with the same key replaces that key's files in a new commit.
#
# Env: SCREENSHOTS_BRANCH (default pr-screenshots), SCREENSHOTS_REPO
# (owner/name, default from gh).
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <dir> <key>" >&2
  exit 2
fi
dir=$(realpath "$1")
key=${2#/}
key=${key%/}
branch=${SCREENSHOTS_BRANCH:-pr-screenshots}
repo=${SCREENSHOTS_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_INDEX_FILE="$tmp/index"

for _ in 1 2 3; do
  parent=
  # Missing branch: start it as an orphan. A failed fetch for any other reason
  # also lands here, and the push below is then rejected and retried.
  if git fetch -q origin "refs/heads/$branch" 2>/dev/null; then
    parent=$(git rev-parse FETCH_HEAD)
    git read-tree "$parent"
  else
    git read-tree --empty
  fi
  git rm -r -q --cached --ignore-unmatch -- "$key" >/dev/null

  count=0
  while IFS= read -r -d '' f; do
    f=${f#./}
    blob=$(git hash-object -w -- "$dir/$f")
    git update-index --add --cacheinfo 100644 "$blob" "$key/$f"
    count=$((count + 1))
  done < <(cd "$dir" && find . -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.webp' \) -print0)
  if [ "$count" -eq 0 ]; then
    echo "no images found in $dir" >&2
    exit 1
  fi

  tree=$(git write-tree)
  commit=$(git commit-tree "$tree" ${parent:+-p "$parent"} -m "chore: screenshots for $key")
  # A plain push: if someone else pushed to the branch meanwhile it is rejected
  # as non-fast-forward and the loop retries on top of their commit.
  if git push -q origin "$commit:refs/heads/$branch" 2>/dev/null; then
    echo "https://github.com/$repo/blob/$commit/$key"
    exit 0
  fi
done

echo "could not push to $branch after 3 attempts" >&2
exit 1
