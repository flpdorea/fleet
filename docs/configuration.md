# Configuration

Every change follows the same path: edit, commit, push, wait for CI, then run `fleet-rebuild` as root on the VPS.

| I want to change | File |
|---|---|
| Which model and effort handles which kind of task | `homes/<ctx>/config/crew-dispatch.json` |
| A context's harness or Orca port | `homes/contexts.nix` |
| Any other firstmate setting | a new file in `homes/<ctx>/config/` |
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
| attribute name | The context name. Also the Linux user name and the `homes/<name>/` folder. |
| `primary` | The harness for both the first mate and its workers: `pi` or `claude`. |
| `orcaPort` | The port that context's Orca server listens on. Must be unique. |

### firstmate config files

Everything in `homes/<ctx>/config/` is copied into `~/fleet/firstmate/config/` by `fleet-setup-<ctx>`. These are [firstmate's own config files](https://github.com/kunchenguid/firstmate/blob/main/docs/configuration.md):

| File | Value here | Effect |
|---|---|---|
| `backend` | `orca` | Workers get Orca worktrees and terminals. |
| `crew-dispatch.json` | see below | Model and effort per kind of task. |
| `claude-permission-mode` (`work` only) | `auto` | Claude workers use the classifier-reviewed permission mode instead of bypass. |
| `pi-account` (`personal` only) | *generated* | Pins Pi workers to the `openai-codex` provider. Written by the setup service because it needs the machine's absolute home path. |

Files are copied, not linked: firstmate refuses some symlinked config, and the Nix store is read-only.

## Model routing

firstmate reads `crew-dispatch.json` before spawning each worker. The `when` rules are natural language; the first mate picks the best match by judgment and passes the profile's harness, model and effort to the spawn script. Anything that matches no rule uses `default`.

Both contexts use the **same five tiers with the same `when` text**, so a task lands on the same tier in either context:

| Tier | Signal in the task | `personal` | `work` |
|---|---|---|---|
| Trivial | one file, obvious mechanical change | Terra · low | Opus · low |
| **Routine (default)** | clear scope, few files | **Terra · medium** | **Opus · medium** |
| Broad | many files, refactor, code migration, extensive tests | Terra · high | Opus · high |
| Ambiguous | bug with no known cause, investigation, design decision | Sol · medium | Opus · xhigh |
| Sensitive / unattended | security, auth, data migration, hours-long work | Sol · high | Fable · high |
| Escalation | already failed elsewhere on a judgment error | Sol · xhigh | Fable · xhigh |

### Why these choices

- **Raise effort before raising the model.** If a worker understood the task but planned or verified poorly, more effort fixes it. If it misjudged the trade-off, a better model does. ([Agiflow's Codex guide](https://agiflow.io/blog/codex-model-thinking-effort-guide))
- **Medium is the sweet spot.** In 294 Codex runs, GPT-5.6 at medium accepted the same tasks as high, xhigh and max, with less time and fewer tokens. ([Instavar](https://instavar.com/research/agents/gpt-5-6-codex-models-reasoning-levels-benchmark-2026))
- **Opus 5.5 is the work default, not Fable 5.1.** On most current coding benchmarks Opus 5.5 scores higher at 2.5× lower list price; at medium effort, Opus leads Fable on Terminal-Bench (57.6% vs 43.4%) and CursorBench (52.5% vs 46.8%). ([CometAPI](https://www.cometapi.com/claude-opus-5-5-vs-claude-fable-5-1/), [Kingy AI](https://kingy.ai/blog/claude-opus-5-5-vs-fable-5-1/))
- **Fable 5.1 is kept for what it still does best:** getting a deliverable right the first time, security-sensitive code, and long unattended runs where a wrong direction is expensive. On Max plans it can consume up to half of the weekly limit, so it sits at the top. ([The AI Career Lab](https://theaicareerlab.com/blog/claude-opus-5-5-vs-fable-5-1-for-professionals))
- **No Fable at low effort.** Fable low only edges out Opus low (40.2% vs 38.5% on Terminal-Bench) at about 4.4× the cost.
- **Sol stops at xhigh.** GPT-5.6's `ultra` only works in the native Codex harness, and `max`/`ultra` drain the subscription's usage window too fast for parallel workers.

These numbers are third-party and vendor benchmarks, and several gaps are small. Adjust the tiers to what passes your own tests and reviews.

### Model IDs

- `personal`: check the exact IDs with `pi --list-models openai-codex` (as the `personal` user) and update `openai-codex/gpt-5.6-terra` and `openai-codex/gpt-5.6-sol` if they differ.
- `work`: `opus` and `fable` are Claude Code model aliases. If your Claude Code does not accept `fable`, use the full model ID.

If a model does not support an effort level, firstmate records it but launches without the flag, and Pi clamps to the nearest supported level. firstmate reports invalid combinations as `CREW_DISPATCH` lines, which `fleet-setup-<ctx>` prints in its log.

## Adding a context

1. Add an entry to `homes/contexts.nix` with a new name and a unique port.
2. Create `homes/<name>/config/` with at least `backend` (`orca`) and a `crew-dispatch.json`.
3. Add the name to the `case` in `install.sh`, which validates context names.
4. On an existing VPS, add it to `fleet.contexts` in `/etc/nixos/fleet.nix`, then run `fleet-rebuild`.
5. As the new user: `fleet login`, `fleet pair`.
