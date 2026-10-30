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
2. **Work out how to run the app.** From the project's README, scripts, `run` skill or your own session: the install command, the dev or preview server command, its port flag, required env, seed data or a test login. Screenshots end up in the PR, so plan on seed or fake data, never production data. If the app needs secrets you don't have, ask the user before going further.
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
8. **Put them in the PR body.** Open the draft PR if there is none. Look at what you publish; leave out any shot that shows secrets or personal data. Write the body to a file inside `~/.cache/visual-validation/<slug>/shots/`, with a `### Visual validation` subsection inside the section where the template asks how the change was tested (or a `## Visual validation` section at the end when there is no template), following the layout below. Reference each screenshot by its path relative to that file, then let `gh` upload them:

   ```bash
   cd ~/.cache/visual-validation/<slug>/shots
   gh pr edit <number> -R <owner/repo> --body-file body.md --attach ./before/<name>.png --attach ./after/<name>.png ...
   ```

   `--attach` (gh 2.103 or later) uploads each file to GitHub's attachment storage, like dragging it into the web editor, and rewrites every `![alt](./before/<name>.png)` that matches into the uploaded URL. Nothing is committed, so the diff stays clean, and the images follow the repository's visibility. The same flag works on `gh pr create`, `gh pr comment` and the `gh issue` commands. Rules it imposes:
   - At most 50 files per command. With more, attach the first 50, read the body back (`gh pr view <number> --json body -q .body > body.md`, in the same directory), and edit again with the next 50; references already rewritten stay as they are.
   - gh parses the body as Markdown and only rewrites references Markdown sees as images. A line glued to an HTML tag (`<details>`, `<summary>`, `</details>`) is part of the HTML block, so its references are not rewritten and the file is appended at the end of the body instead. Keep a blank line after `<summary>...</summary>` and before and after `</details>`, and never put the images in HTML (`<img>`, `<table>`).
   - An attached file the body doesn't reference is appended at the end. Attach only what the body references.

   Then check the result: `gh pr view <number> --json body -q .body` must have no `](./` left and no images appended after the last section. Re-runs replace the section, not append to it.
9. **Report.** In a line or two: the verdict, what failed and what you fixed, and anything you rejected with a reason.

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
Use seed or fake data only; screenshots get published in the PR.

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

Lead with the verdict and the matrix that was covered, then one collapsible block per page so the body stays readable. Mind the blank lines around the HTML tags; without them `--attach` can't rewrite the references. Keep the body under GitHub's 65,536-character limit, and if the matrix needs more than 50 screenshots, attach in batches as step 8 describes.

```markdown
### Visual validation

PASS: <n> views across desktop, tablet and mobile, light and dark. No regressions in <pages checked for regressions>.

<details>
<summary>Checkout form, error state</summary>

| Config | Before | After |
|---|---|---|
| Desktop, light | ![Checkout error, desktop light, before](./before/checkout-error-desktop-light.png) | ![Checkout error, desktop light, after](./after/checkout-error-desktop-light.png) |
| Mobile, dark | ![Checkout error, mobile dark, before](./before/checkout-error-mobile-dark.png) | ![Checkout error, mobile dark, after](./after/checkout-error-mobile-dark.png) |

</details>
```

A new page gets a single `After` column. Mention failures that are still open above the tables, each with its after screenshot and, when it helps, the pixel diff from `diff/`.
