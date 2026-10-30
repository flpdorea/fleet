# Global instructions

## Language

- Reply in English by default. When I write in another language, reply in that language.
- Everything that goes into a repository is in English, whatever language we talk in: code, comments, docs, commit messages, PR titles and bodies.

## Style

- Be concise: get to the point, and skip long recaps at the end of a reply.
- No emojis anywhere: replies, code, commits, PRs.

## Git

- Commit messages follow Conventional Commits: `type(scope): summary`, such as `fix(nix): ...` or `docs: ...`.
- You may commit, push and open a draft PR without asking once a task is done. Never commit to the default branch: create a branch first.
- Never amend a pushed commit, rewrite published history or force-push. Fix things with a new commit.
- PR bodies: when the repository has a pull request template (such as `.github/pull_request_template.md`), fill it in. Otherwise keep the body short: what changed and why.
- No AI attribution in commits or PRs: no `Co-Authored-By` trailer and no "Generated with" line.

## Self-improvement

- Your global setup (this file, settings, skills) lives in the fleet repo (`flpdorea/fleet`). To change it, use the `self-improve` skill: it opens a PR there. Never edit `~/.claude` directly for that; the next rebuild reverts it.
- When I give the same instruction, preference or correction more than twice, across sessions too (keep count in memory), suggest turning it into a skill or a rule here. Only create it after I explicitly approve.
