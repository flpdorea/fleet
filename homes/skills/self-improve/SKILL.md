---
name: self-improve
description: Change your own Claude Code setup (global instructions, settings, skills) by opening a pull request to the fleet repo, flpdorea/fleet, which installs that setup on every rebuild. Use when the user asks you to change how you behave, remember a rule for every session, add or edit a skill, or change a Claude Code setting; when the user approves turning a repeated instruction into a skill or rule; or when you notice your own setup is missing something or getting in the way. Never edit ~/.claude directly for these changes.
---

# Self-improve

Your global setup is not yours to edit in place. It is declared in the fleet repo (`https://github.com/flpdorea/fleet`) and reinstalled by `fleet-setup-<context>` on every rebuild, which overwrites local edits:

| What | File in fleet | Installed as |
|---|---|---|
| Global instructions | `homes/CLAUDE.md` | `~/.claude/CLAUDE.md` |
| Settings | `homes/claude-settings.json` | merged into `~/.claude/settings.json` |
| Skills | `homes/skills/<name>/` | `~/.claude/skills/<name>/` |

Anthropic's `skill-creator`, Lavish's `lavish` and Orca's `orca-cli` and `orchestration` skills are installed by the same service but not stored in `homes/skills`; don't copy them there.

So every change to yourself is a pull request to fleet. The user reviews and merges it, then runs `fleet-rebuild` as root on the VPS to apply it.

## When to propose a change

- **The user asks for it**: "from now on...", "always...", "never...", "remember to...", "make this a skill". Go ahead and open the PR.
- **A repeated instruction**: the user has given the same instruction, preference or correction more than twice. Suggest turning it into a skill (a procedure with steps) or a line in `homes/CLAUDE.md` (a short always-on rule), say which and why, and wait. Create nothing until the user explicitly approves.
- **You notice a gap**: a missing permission, a rule that keeps causing friction, a skill that triggers wrongly. Suggest it, don't open the PR unasked.

To spot repeats across sessions, keep count in memory: when the user gives an instruction that could become a rule or skill, record it (or bump the count of an existing record) with what they asked and when. On the third occurrence, make the suggestion. If the user declines, record that too and don't suggest it again unless they bring it up.

## Making the change

1. **Get a clean checkout of fleet.** Never work in the main checkout of another session. If the fleet repo is in Orca, create a new worktree for it (see the `orca-cli` skill); otherwise clone it into a new temporary directory with `gh repo clone flpdorea/fleet`. Create a branch from `main`.
2. **Edit the right file.**
   - A rule: add it to `homes/CLAUDE.md`, in the section where it fits, in the same terse style. Keep that file short; anything longer than a few lines belongs in a skill.
   - A skill: load the `skill-creator` skill and follow it to write `homes/skills/<name>/SKILL.md` (plus any scripts or references). Skill names are lowercase with hyphens. The description decides when the skill triggers, so say what it does and when to use it.
   - A setting: add the key to `homes/claude-settings.json` and add a row to the settings table in `docs/configuration.md` saying why.
3. **Update the docs** when the change is visible to someone reading the repo: the skills table in `docs/configuration.md` for a new skill, the README layout if you add a directory.
4. **Commit, push, open a draft PR**, following the global git rules (Conventional Commits such as `feat(claude): ...`, English, no AI attribution). In the body, say what changes in your behavior and why, including the repeated instruction that prompted it, if any.
5. **Tell the user** the PR link, and that the change takes effect after they merge it and run `fleet-rebuild` on the VPS.

## Don'ts

- Don't edit `~/.claude/CLAUDE.md`, `~/.claude/settings.json` or `~/.claude/skills/` directly to make the change stick; the next rebuild reverts it.
- Don't create a skill or rule from a repeated instruction without the user's explicit approval.
- Don't bundle unrelated changes in one PR.
- Don't put secrets, tokens or project-specific details in the fleet repo: it is public.
