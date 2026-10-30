---
name: auto-review
description: After finishing a worthwhile implementation, start a second Claude agent through Orca orchestration to review the change, wait for its findings, fix the valid ones, then report. Use automatically, without being asked, once a non-trivial code change is done and before telling the user it is finished or marking its PR ready; also when the user asks for an automatic, independent or second-agent review. Skip for docs-only, config-only or trivial changes.
---

# Auto review

A fresh agent that did not write the code reads it without your assumptions. Run it through Orca orchestration so the review is a real, supervised Orca worker the user can see, not an in-process subagent.

## When it is worth it

Run it when the change adds or changes behavior: new features, bug fixes, refactors, scripts, Nix modules, anything with logic that can be wrong. Skip it, and say nothing about it, for docs-only changes, comment or formatting fixes, version bumps, one-line config tweaks, or when the user said not to review. Skip it too when the work is not in an Orca workspace (`orca status --json` fails or shows no Orca runtime); mention in one line that the review was skipped and why.

Run it once per implementation, not after every fix it triggers.

## Steps

1. **Commit first.** Commit the finished work on its branch (the global git rules allow it), so the reviewer sees a stable diff. Note the base: usually `origin/<default branch>`.
2. **Load the guide.** Follow the `orchestration` skill: resolve the CLI and run `ORCA skills get orchestration`. Use that guide's commands and flags over anything here if they differ.
3. **Start the reviewer.** Create a Run and one worker in the current worktree:

   ```text
   ORCA orchestration run-create --objective "Review <branch>" --json
   ORCA orchestration worker-start --worktree current --agent claude --task-title "Review <branch>" --spec "<spec>" --json
   ```

   Don't pass `--model` or `--effort` unless the user named them. The spec must be self-contained:
   - **Target:** the repository path, branch, and the diff `git diff <base>...HEAD`.
   - **Change:** review it for correctness bugs, security problems, missed edge cases and conventions of the surrounding code; a short note on what the change is meant to do, but not your opinion of it.
   - **Constraints:** read-only. Do not edit, commit, push, or touch the PR. Ignore style nits a formatter would catch.
   - **Acceptance:** write the findings to `/tmp/review-<branch>.md`, each with file:line, the problem, a concrete failure scenario, and severity; write "No findings" if there are none. Then send `worker_done` with `--report-path` pointing to that file.
4. **Wait.** Use the guide's `check --wait` loop for `worker_done`, `escalation` and `question`. Answer questions; a timeout is a checkpoint, not a failure. Don't start other edits in the same files while waiting.
5. **Settle.** Read the report, then `worker-release` the reviewer and acknowledge the delivery, as the guide's completion accounting says.
6. **Act on findings.** Verify each one against the code yourself; the reviewer can be wrong. Fix the real ones in a new commit and push it. Don't run a second review for those fixes unless they were large.
7. **Report.** In your final reply, say in a line or two what the review found and what you fixed or rejected, with a reason for each rejection.
