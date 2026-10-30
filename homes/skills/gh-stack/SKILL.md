---
name: gh-stack
description: Split work into small stacked pull requests and manage them with `gh stack` (the github/gh-stack extension to the GitHub CLI). Use whenever a change would make a large PR, touches several concerns or layers, or the user mentions stacked PRs, a stack, splitting or breaking up a PR, or `gh stack`; also when working on, rebasing, syncing or merging a branch or PR that belongs to a stack. Use it instead of hand-chaining branches with `git` and `gh pr create --base`.
---

# gh stack

A stack is a chain of small PRs, each building on the one below it. GitHub has native support for it: a stack is an object on GitHub, shown in the PR UI, rebased as a unit and merged atomically. `gh stack` is the CLI for it.

## The common mistake

Pointing each branch's PR at the branch below (`gh pr create --base feat/api`) is necessary, but it is not a stack. Without `gh stack`:

- GitHub has no stack object: reviewers don't see the PRs as one chain, and nothing keeps the bases right when a lower PR changes or merges.
- Rebasing is manual, branch by branch, and easy to get wrong.
- Merging is one PR at a time, with retargeting in between, instead of one atomic merge.

So never build a stack by hand. Create and update it with `gh stack init`, `gh stack add` and `gh stack submit`. If branches or PRs were already chained by hand, adopt them with `gh stack init <bottom> ... <top>` (then `submit`) or `gh stack link <pr> <pr> ...`.

## Setup

`gh stack --version` checks it is installed. If not: `gh extension install github/gh-stack`. It needs `gh auth status` to pass.

Most commands open a TUI or prompt in an interactive terminal. Agents run non-interactively, so always pass the flags that skip prompts (`--auto`, `--yes`, explicit arguments) and never run `gh stack modify` or `gh stack switch` without arguments; ask the user to run those.

## Planning the split

Before writing code for anything bigger than a small fix, plan the stack: an ordered list of PRs, bottom to top, each one:

- one reviewable concern (a refactor, a schema change, an API, the UI on top), ideally under a few hundred changed lines;
- building and passing tests on its own, with everything below it;
- free of changes that belong in another layer.

Typical order: preparatory refactors and renames, then data/schema, then backend logic, then API, then UI, then docs and cleanup. A change that is small and single-concern stays a single PR; don't stack for the sake of it.

## Building a stack

```sh
gh stack init feat/auth-model                 # first branch, based on the default branch
# ...edit, then commit the layer:
git add -A && git commit -m "feat(auth): add user model"
gh stack add -Am "feat(auth): add login API" feat/auth-api    # new branch on top, commits staged changes
gh stack add feat/auth-ui                     # new empty branch on top; commit into it afterwards
gh stack view --short                         # check the order
gh stack submit --auto                        # push all branches, open draft PRs, create the stack on GitHub
```

- `gh stack init a b c` creates (or adopts) several branches at once, bottom to top. `--base develop` for a trunk other than the default branch.
- `gh stack submit --auto` creates new PRs as drafts with generated titles. Then set each PR's title and body with `gh pr edit <branch> --title ... --body ...` (Conventional Commit titles, the repo's PR template filled in, one PR per layer describing only that layer and naming its place in the stack).
- `gh stack submit --open` marks the PRs ready for review, when the work is done.

## Changing a stack

- **Fix something in a lower layer**: `gh stack checkout <branch>` (or `gh stack down`/`up`/`bottom`/`top`), commit the fix there, then `gh stack rebase --upstack` to carry it into the branches above, then `gh stack push`. Don't fix it in the top branch.
- **Trunk moved**: `gh stack sync` fetches, rebases the whole stack onto the trunk, pushes and syncs PR state. On conflict it restores everything; run `gh stack rebase`, resolve, `git add`, `gh stack rebase --continue` (or `--abort`).
- **Add a layer on top**: `gh stack top`, then `gh stack add <branch>`, commit, `gh stack submit --auto`.
- **Reorder, fold, drop or insert layers**: `gh stack modify` is an interactive TUI; ask the user to run it, then `gh stack submit`.
- **Inspect**: `gh stack view --json` for machine-readable state (branches, PRs, which need a rebase).

`gh stack push`, `sync` and `rebase` push with `--force-with-lease` after a rebase. That is how stacks work and is allowed for stack branches managed by `gh stack`, despite the general no-force-push rule. Never force-push stack branches with plain `git push --force`; let `gh stack` do it.

## Worktrees

Navigation (`checkout`, `up`, `down`, `top`, `bottom`, `trunk`) never switches a branch that is checked out in another worktree. In an Orca worktree, use `--print-path` to get the worktree that holds a branch and work there, or keep the whole stack in your own worktree.

## Merging

Stacks are almost always merged as a whole, once every PR in it is approved and green:

```sh
gh stack merge --yes --squash      # atomic: all PRs merge, or none do
gh stack sync --prune              # afterwards: update trunk, drop merged local branches
```

Use the merge method the repository requires (check its settings or CONTRIBUTING; fleet requires squash). `gh stack merge <pr>` merges only up to that PR, for the rare case where the lower part must land first; only do that if the user asks. Merging is the user's call like any merge: don't run it unasked. Draft PRs can't be merged, so `gh stack submit --open` first.

Never merge stack PRs one by one with `gh pr merge`.

## Other commands

- `gh stack checkout <stack-number|pr|branch>`: pull a stack someone else made into local tracking.
- `gh stack unstack [--local]`: dissolve the stack (the PRs stay open).
- `gh stack <command> --help` for the rest; the docs are at https://gh.io/stacks.
