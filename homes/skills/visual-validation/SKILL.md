---
name: visual-validation
description: After any change that can alter what users see in a web UI (CSS, markup, components, layout, theming, assets, UI copy), start a second Claude agent through Orca orchestration that runs the app before and after the change in a headless browser (agent-browser), checks the change and hunts for regressions across viewports, color schemes and states, and takes before/after screenshots; then fix what fails and embed the screenshots in the PR body. Use automatically, without being asked, before calling a visual change done or marking its PR ready; also when the user asks to validate, screenshot or visually check a UI change. Skip for changes with no visual effect.
---

# Visual validation

A visual change is not done until someone looked at it, in more than one configuration, next to how it looked before. A fresh agent that did not write the change does that through Orca orchestration, so it is a supervised worker the user can see, and its screenshots go into the PR so the reviewer sees the same evidence.

## When it applies

Run it for any change that can alter rendered output in a browser: styles, templates and components, layout, design tokens and themes, icons and images, fonts, UI copy, and refactors of UI code that should look the same (there, "no visible difference" is what it proves). Skip it, and say nothing about it, when nothing rendered can change: backend-only code, tests, docs, CI.

Native mobile apps are out of scope; use Orca's emulator skills (`orca skills list`) for those.

If the work is not in an Orca workspace (`orca status --json` fails or shows no runtime), run the same spec through an in-process subagent instead, telling it to return the report path in its final message rather than send `worker_done`, and say so in one line.

## The browser

Use `agent-browser` (installed system-wide, wrapped with its own Chromium from Nix). Don't use Orca's embedded browser (`orca goto`, `orca screenshot`, `orca exec`) for screenshots: on the headless VPS its tabs are not painted reliably, and captures come back blank, tiled or one frame stale. `agent-browser skills get core --full` prints the version-matched command reference.

## Steps

1. **Commit first.** Commit the finished work on its branch and push it, so the worker sees a stable diff. Note the base, usually `origin/<default branch>`, and the branch's slug (`/` replaced by `-`). The validator works in `~/.cache/visual-validation/<slug>/`: `base/` for the base worktree, `shots/` for screenshots and the report. It is per user, since contexts share `/tmp`.
2. **Work out how to run the app.** From the project's README, scripts, `run` skill or your own session: the install command, the dev or preview server command, its port flag, required env, seed data or a test login. Screenshots end up in the repository, so plan on seed or fake data, never production data. If the app needs secrets you don't have, ask the user before going further.
3. **Load the orchestration guide.** Follow the `orchestration` skill: resolve the CLI and run `ORCA skills get orchestration`. Its commands and flags win over anything here.
4. **Start the validator.**

   ```text
   ORCA orchestration run-create --objective "Visual validation <branch>" --json
   ORCA orchestration worker-start --worktree current --agent claude --task-title "Visual validation <branch>" --spec "<spec>" --json
   ```

   Don't pass `--model` or `--effort` unless the user named them. The spec below must be self-contained; fill in every `<...>`.
5. **Wait.** Use the guide's `check --wait` loop for `worker_done`, `escalation` and `question`. Answer questions; a timeout is a checkpoint, not a failure. Don't edit UI files while it runs.
6. **Settle.** Read the report and look at the screenshots it flags yourself; then `worker-release` the validator and acknowledge the delivery as the guide says.
7. **Fix and re-run.** Verify each failure against the code and the screenshots; the validator can be wrong. Fix the real ones in a new commit, push, and run steps 4 to 6 again, since a visual fix needs a new look. Stop after three rounds and report what is still failing instead of looping.
8. **Publish the screenshots.** First check `gh repo view --json visibility`: if the repository is public, ask the user before publishing, since the images stay in its history for good. Look at what you publish; leave out any shot that shows secrets or personal data. Then, from the repository:

   ```bash
   bash ~/.claude/skills/visual-validation/scripts/upload-screenshots.sh ~/.cache/visual-validation/<slug>/shots <slug>
   ```

   It commits the images to the `pr-screenshots` branch of the same repository (never to the PR branch, so the diff stays clean) and prints a base URL pinned to that commit. Embed each file as `![<alt>](<base URL>/<path>?raw=true)`. File names are limited to `[a-z0-9-]` so they need no URL encoding. GitHub renders these in PR bodies, private repositories included, for anyone who can read the repo. The branch grows with every PR's images and a full clone fetches it; that is the trade-off for keeping the PR diff clean.
9. **Write it into the PR body.** Open the draft PR if there is none. Put a `### Visual validation` subsection inside the section where the template asks how the change was tested (or a `## Visual validation` section at the end when there is no template), following the layout below, then update the body with `gh pr edit --body-file`. Re-runs replace the section, not append to it.
10. **Report.** In a line or two: the verdict, what failed and what you fixed, and anything you rejected with a reason.

## Validator spec

```text
Validate the visual change on branch <branch> of <repo path> against <base>. Read-only:
do not edit, commit or push in the repository, and do not touch the PR.

What changed and what it is meant to look like: <short intent, no opinion on quality>.
Diff: git diff <base>...HEAD

Work in ~/.cache/visual-validation/<slug>/. Start clean: remove base/ (git worktree
remove --force, then rm -rf) and shots/ left by an earlier round.

Run the app twice, side by side:
- before: git worktree add --detach ~/.cache/visual-validation/<slug>/base <base>;
  install and start it on port <port A>.
- after: in <repo path>, start it on port <port B>.
How to run it: <install command, server command, port flag, env, seed data, login>.
Use seed or fake data only; screenshots get published in the repository.

Browser: agent-browser only, never Orca's embedded browser. Read
`agent-browser skills get core --full` first. Use one session per app and
configuration (--session v-<slug>-<before|after>-<config>), so device emulation such as
the iPhone user agent never leaks into another configuration. Set the configuration
before opening the first page in that session.

Cover:
- Pages and states: every page or component the diff touches, in each state the change
  affects (hover, focus, open menus and dialogs, empty, loading, error, long text,
  validation messages), plus pages that reuse the changed components or styles, to catch
  regressions.
- Configurations, for each of those: desktop (set viewport 1440 900), tablet (set
  viewport 768 1024), mobile (set device "iPhone 12"); each in light and dark (set media)
  when the app supports dark mode; add reduced motion when the change animates.

For each page, state and configuration, capture the same view in both apps as
shots/before/<page>-<state>-<config>.png and shots/after/<page>-<state>-<config>.png,
then run `diff screenshot --baseline <before> -o shots/diff/<same name>.png` in the
matching after session. File names use only [a-z0-9-] plus the extension. New pages have
no before.

Check, and look at every after screenshot yourself:
- The change does what it is meant to, in every configuration.
- Every difference the pixel diff shows is intended; any other one is a regression.
- No overlap, clipping, cut-off or overflowing text, horizontal scroll
  (document.documentElement.scrollWidth > innerWidth), broken images or icons,
  unreadable contrast (dark mode especially), misalignment, or layout jumps.
- No new console or page errors (`console`, `errors`) compared with before.
- Interactive elements still reachable and labelled (`snapshot -i`); focus visible.
- Nothing secret or personal on screen (tokens, keys, real emails); flag any shot that
  shows some.

When done: close each agent-browser session you opened (--session <name> close), stop both
servers, and remove the base worktree. Keep shots/.

Acceptance: write shots/report.md with a verdict (PASS or FAIL) on the first line, then
one row per page, state and configuration (before file, after file, diff file, pass or
fail), then each failure with the screenshot, what is wrong and the likely file:line.
Delete screenshots the report doesn't reference. Then send worker_done with
--report-path pointing to the report.
```

## PR body layout

Lead with the verdict and the matrix that was covered, then one collapsible block per page so the body stays readable. Keep the body under GitHub's 65,536-character limit; if it would not fit, embed the failing and most relevant shots and link the rest by their folder URL.

```markdown
### Visual validation

PASS: <n> views across desktop, tablet and mobile, light and dark. No regressions in <pages checked for regressions>.

<details><summary>Checkout form, error state</summary>

| Config | Before | After |
|---|---|---|
| Desktop, light | ![before](<url>?raw=true) | ![after](<url>?raw=true) |
| Mobile, dark | ![before](<url>?raw=true) | ![after](<url>?raw=true) |

</details>
```

A new page gets a single `After` column. Mention failures that are still open above the tables, each with its screenshot.
