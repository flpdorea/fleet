# Configuration

Every change follows the same path: edit, commit, push, wait for CI, then run `fleet rebuild` as root on the VPS.

| I want to change | File |
|---|---|
| A context's harness or Orca port | `homes/contexts.nix` |
| Which Orca skills are installed | `nix/setup-user.sh` |
| Claude Code settings (`work`) | `homes/claude-settings.json` |
| Claude Code global instructions (`work`) | `homes/CLAUDE.md` |
| Claude Code skills | `homes/skills/` |
| Packages, firewall, services | `nix/module.nix` |
| Pinned versions | `flake.lock` (`nix flake update`, or let CI do it) |
| Which contexts this machine runs, SSH keys | `/etc/nixos/fleet.nix` on the VPS |

## Contexts

`homes/contexts.nix` defines each context:

```nix
{
  personal = { primary = "claude"; orcaPort = 6768; };
  work     = { primary = "claude"; orcaPort = 6769; };
}
```

| Field | Meaning |
|---|---|
| attribute name | The context name. Also the Linux user name. |
| `primary` | The harness installed for the context, logged in by `fleet login`, and the one that gets the Orca skills: `pi` or `claude`. |
| `orcaPort` | The port that context's Orca server listens on. Must be unique. |

## Orca skills

`fleet-setup-<ctx>` runs, as the context user:

```bash
orca skills install --skill orca-cli --skill orchestration --agent <harness>
```

That installs Orca's own skills globally for the harness (`~/.claude/skills` for Claude Code, Pi's skills directory for Pi), so every session of that user can use them, not just one project:

| Skill | What it gives the agent |
|---|---|
| `orchestration` | Coordinating supervised Orca workers: task dispatch, threaded messages, blocking ask/reply, `worker_done` and escalation waits, task DAGs and decision gates. |
| `orca-cli` | Orca worktrees, terminals, repos, handoffs and the embedded browser through the `orca` CLI. |

`orca skills list` shows the other bundled skills (Linear, emulators, per-workspace environments). To add one, add another `--skill` to `nix/setup-user.sh`.

Which model and effort an agent gets is chosen when you start it in the Orca app (or by the agent that spawns it through the `orca` CLI). To steer it, say so in your prompt or in the harness's global instructions (`homes/CLAUDE.md`, installed as `~/.claude/CLAUDE.md`, for Claude Code).

## Claude Code settings

For contexts whose harness is `claude`, `fleet-setup-<ctx>` merges `homes/claude-settings.json` into `~/.claude/settings.json`. It merges instead of replacing because Orca writes its hooks and status line to the same file. Keys set in the repo win on every rebuild, so a `/config` change to one of them lasts only until the next rebuild; keys the repo doesn't set stay as the user left them. Removing a key from the repo doesn't remove it from the user's file.

| Key | Why |
|---|---|
| `attribution: false` | No `Co-Authored-By` trailer on commits, no "Generated with Claude Code" line in PR descriptions, no session link. |
| `spinnerTipsEnabled: false` | No feature tips under the spinner while Claude works. |
| `feedbackSurveyRate: 0` | No session quality survey. |
| `cleanupPeriodDays: 365` | Keep transcripts, and so `/resume`, for a year instead of the default 30 days. |

Auto-updates need no setting: the Nix package's wrapper already sets `DISABLE_AUTOUPDATER=1`, and `flake.lock` decides the version.

The same service copies `homes/CLAUDE.md` to `~/.claude/CLAUDE.md`, the instructions every Claude Code session of that user reads: language, style, the git rules (Conventional Commits, when to commit, push and open PRs, no AI attribution) and the self-improvement rules below. That file belongs to the repo and is replaced on every rebuild, so edit it here, not on the VPS.

## Claude Code skills

The same service also installs these skills in `~/.claude/skills`, replacing each one on every rebuild. Removing a skill from the repo doesn't remove it from the user's directory.

| Skill | Source | What it gives the agent |
|---|---|---|
| `self-improve` | `homes/skills/self-improve` | How to change its own setup: a PR to this repo editing `homes/CLAUDE.md`, `homes/claude-settings.json` or `homes/skills/`, never `~/.claude` directly. |
| `skill-creator` | [anthropics/skills](https://github.com/anthropics/skills/tree/main/skills/skill-creator), pinned by the `anthropic-skills` input in `flake.lock` | Anthropic's guide and scripts for writing, testing and tuning skills. `self-improve` uses it for new skills. |

`homes/CLAUDE.md` makes this a loop: when you give the same instruction more than twice, across sessions too (Claude keeps count in its memory), Claude suggests turning it into a skill or a rule, and opens the PR only after you approve. The change takes effect once you merge it and run `fleet-rebuild`.

To add a skill by hand, create `homes/skills/<name>/SKILL.md`.

Every key is documented in the [settings reference](https://code.claude.com/docs/en/settings-reference).

## Adding a context

1. Add an entry to `homes/contexts.nix` with a new name and a unique port.
2. Add the name to the `case` in `install.sh`, which validates context names.
3. On an existing VPS, add it to `fleet.contexts` in `/etc/nixos/fleet.nix`, then run `fleet rebuild`.
4. As the new user: `fleet login`, `fleet pair`.
