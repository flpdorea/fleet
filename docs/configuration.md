# Configuration

Every change follows the same path: edit, commit, push, wait for CI, then run `fleet-rebuild` as root on the VPS.

| I want to change | File |
|---|---|
| A context's harness or Orca port | `homes/contexts.nix` |
| Which Orca skills are installed | `nix/setup-user.sh` |
| Packages, firewall, services | `nix/module.nix` |
| Pinned versions | `flake.lock` (`nix flake update`, or let CI do it) |
| Which contexts this machine runs, SSH keys | `/etc/nixos/fleet.nix` on the VPS |

## Contexts

`homes/contexts.nix` defines each context:

```nix
{
  personal = { primary = "pi";     orcaPort = 6768; };
  work     = { primary = "claude"; orcaPort = 6769; };
}
```

| Field | Meaning |
|---|---|
| attribute name | The context name. Also the Linux user name. |
| `primary` | The harness `fleet` opens as the coordinator, and the one that gets the Orca skills: `pi` or `claude`. |
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

Which model and effort a worker gets is the coordinator's call when it spawns it through the `orca` CLI. To steer it, say so in your request or in the harness's global instructions (`~/.claude/CLAUDE.md` for Claude Code).

## Adding a context

1. Add an entry to `homes/contexts.nix` with a new name and a unique port.
2. Add the name to the `case` in `install.sh`, which validates context names.
3. On an existing VPS, add it to `fleet.contexts` in `/etc/nixos/fleet.nix`, then run `fleet-rebuild`.
4. As the new user: `fleet login`, `fleet pair`.
