---
name: pr-babysit
description: After opening a pull request or pushing to one, watch its CI checks, reviews and merge state until it is green, fix what the change broke, and escalate to a human what an agent shouldn't decide. Use automatically, without being asked, every time you open a PR or push commits to an open one; also when the user asks to watch, babysit, monitor or get a PR green.
---

# PR babysit

A PR is not done when it is opened; it is done when its checks pass and nothing on it is waiting for you. Stay with it until then, fix what is yours to fix, and hand the rest to a human with enough context to decide.

## Watch

1. Find the PR: `gh pr view --json number,url,state,isDraft,mergeable,mergeStateStatus,reviewDecision,headRefName`.
2. Wait for checks without polling by hand: run `gh pr checks <number> --watch --fail-fast` as a background command, so you are re-invoked when it exits. If checks have not started yet, wait a moment and retry before concluding there are none. If the repository has no checks at all, say so and skip to step 4.
3. When it exits, read the result with `gh pr checks <number> --json name,state,link,workflow`.
4. Also read what humans and bots left: `gh pr view <number> --comments` and `gh api repos/{owner}/{repo}/pulls/<number>/comments` for inline review comments, plus `mergeable` / `mergeStateStatus` for conflicts.

## Act

| Situation | What to do |
|---|---|
| A check fails because of the change (test, lint, type, build) | Read the log (`gh run view <run-id> --log-failed`), reproduce locally when you can, fix it in a new commit, push, and watch again. |
| A check looks flaky (passes locally, unrelated to the diff, known-flaky test, network timeout) | Rerun the failed jobs once with `gh run rerun <run-id> --failed`. A second failure is not flaky: treat it as real or escalate. |
| Merge conflict with the base branch | Merge the base into the branch (`git merge origin/<base>`), resolve, commit, push. Never rebase a pushed branch or force-push. If resolving needs a judgment about someone else's code, escalate. |
| Actionable review comment (bug, missing case, convention) | Verify it, fix it in a new commit, and reply on the thread saying what changed. |
| Review comment you disagree with, or that changes scope | Don't silently ignore it or silently comply: escalate with your view. |
| All checks green, no open comments | Stop and report. |

Each fix push restarts the loop. Stay on the PR's branch and scope: don't fix unrelated breakage in the same PR.

## Escalate to a human

Stop working the PR and escalate when the next step is not an agent's call:

- The failure is not caused by the change: broken `main`, CI infrastructure, expired or missing secrets, permissions, quota, an outage.
- The fix needs something you must not do: force-push, rewrite history, change protected settings, disable or skip a check, lower coverage or lint thresholds, bump a major dependency.
- The fix changes behavior, an API, a schema or security-relevant code beyond what the PR set out to do, or there are several reasonable fixes with different tradeoffs.
- A reviewer asks a question only the user can answer, requests a design change, or reviewers disagree.
- A workflow is waiting for manual approval or a protected environment.
- Three fix attempts for the same failure did not make it pass.

How to escalate:

- As a supervised Orca worker, send an `escalation` through the `orchestration` skill.
- Otherwise, stop and tell the user in your reply. If the session is unattended and a push notification tool is available, also send one.

Either way, state the PR link, the failing check or comment, what you found, what you tried, and the decision you need. Leave a short PR comment with the same summary only when the people who will act on it read the PR rather than this session.

## Don't

- Don't merge the PR or mark a draft ready for review unless the user asked.
- Don't mark someone else's review thread resolved without having addressed it.
- Don't bypass checks: no `[skip ci]`, no disabling tests, no `--admin` merges.
- Don't keep polling once there is nothing left to wait for; reviews that arrive after you finish are the user's to bring back.

## Report

In one or two lines: final check state, what you fixed, what you reran, and anything escalated.
