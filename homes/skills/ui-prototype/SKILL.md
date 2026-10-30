---
name: ui-prototype
description: Prototype and iterate on web UI in Lavish before implementing it. Renders React components (the project's real ones or quick sketches) as an HTML artifact with alternatives side by side, their states and viewports, and screenshots of the current app, which the user annotates in the browser until a direction is chosen. Use during frontend work whenever the look or behavior of a screen or component is still open, the user asks to prototype, mock up, sketch, explore options or "try a few versions" of some UI, or wants to see a component before it is built; also to iterate on an existing component's design. Not for checking a finished change for regressions: that is `visual-validation`.
---

# UI prototype

Iterating on UI through prose and code diffs is slow: the user can't judge a layout they haven't seen. Instead, render the options as an HTML artifact, open it in Lavish (the `lavish` skill), and let the user point at what to change. Code the real thing only once the direction is settled.

The artifact is a thinking tool, not the deliverable. It can cut corners (fake data, no routing, no API) as long as what the user is judging looks and behaves like the real thing.

## 1. Gather what the prototype must match

- **Design system.** Find the project's tokens, Tailwind config, component library and global CSS before writing any markup. A prototype in a different style can't be judged, and the user will annotate the wrong things.
- **Current state.** If the UI already exists, run the app and take screenshots of the relevant screens and states with `agent-browser` (Orca's embedded browser captures unreliably on the headless VPS; see `visual-validation`). Save them next to the artifact so it can show "today" beside the options.
- **Constraints.** The data the component really gets, the viewports that matter, light and dark mode if the app has both.

## 2. Build the artifact

Put it in the project under `.lavish/<topic>/` (one directory per topic, so assets stay together) and keep it out of git: add `.lavish/` to `.git/info/exclude` if the repo doesn't ignore it.

Before writing it, load Lavish's current guidance with `npx -y lavish-axi --help`, then the `comparison` and `input` playbooks (`npx -y lavish-axi playbook <id>`). Then lay it out like this:

- **The question at the top**: what is being decided ("Empty state for the projects list").
- **Today**: the screenshot of the current UI, if there is one.
- **2 to 4 alternatives side by side**, genuinely different rather than variations of one idea, each labeled with its trade-off. Render each in the states that matter: default, hover and focus, empty, loading, error, long or missing text. Show them at the viewports that matter (a fixed-width frame per viewport works) and in both color schemes when the app has them.
- **Controls for tunable values**, such as spacing, radius, density or animation timing, as sliders or toggles, and a control that queues the chosen option and values back to you as feedback (the `input` playbook covers this).

## 3. Render React in Lavish

Lavish serves the artifact in a sandboxed iframe without same-origin access. Two approaches are verified to work there:

- **The project's real components**, best when they exist or the prototype should become the real component. Write a small `entry.tsx` that renders the alternatives with the real components and fixture props, and bundle it as a classic script:

  ```sh
  npx esbuild entry.tsx --bundle --format=iife --jsx=automatic \
    --define:process.env.NODE_ENV='"development"' --outfile=.lavish/<topic>/proto.js
  ```

  Load it with `<script src="proto.js"></script>` (no `type="module"`). Build the project's CSS to a sibling file too (for Tailwind, its CLI with the project's config) and link it with a relative path.
- **Quick sketches**: React from esm.sh, written with `htm` instead of JSX, in an inline `<script type="module">`:

  ```js
  import React, { useState } from "https://esm.sh/react@19";
  import { createRoot } from "https://esm.sh/react-dom@19/client";
  import htm from "https://esm.sh/htm@3";
  const html = htm.bind(React.createElement);
  ```

These render a blank iframe in Lavish, so don't use them: a sibling `<script type="module" src="...">` (blocked by CORS from the sandboxed origin), in-browser Babel and `esm.sh/tsx`.

Before handing the artifact to the user, open the session URL in `agent-browser`, take a screenshot and look at it: a blank or broken frame wastes a review round.

## 4. Iterate

Open the artifact and wait for feedback as the `lavish` skill and the global instructions describe, giving the user the session URLs. Apply each round of annotations and reply with `lavish-axi poll <file> --agent-reply "..."` so the user sees what changed. When an option is dropped, collapse it rather than delete it, unless the user wants it gone; it helps to see what was rejected.

## 5. Implement

Once the user picks a direction, end the Lavish session and build it in the real codebase, using the artifact as the reference for every state and viewport it showed. Then the change goes through `visual-validation` like any visual change. Screenshots from the prototype can go in the PR body with `gh pr edit --attach` when they explain the decision.
