# fleet

Two [firstmate](https://github.com/kunchenguid/firstmate) fleets on one **NixOS** VPS, with [Orca](https://github.com/stablyai/orca) running headless. You talk to one agent per context (the first mate), it runs a crew of coding agents, and you watch the crew from the Orca app on your Mac or phone.

| Context | Linux user | First mate and crew | Models | Orca port |
|---|---|---|---|---|
| `personal` | `personal` | Pi | GPT-5.6 Terra / Sol through the ChatGPT subscription | 6768 |
| `work` | `work` | Claude Code | Claude Opus 5.5 / Fable 5.1 | 6769 |

The whole machine is declared in this flake: users, firewall, Tailscale, both Orca servers, and every version (pinned in `flake.lock`). Orca, Pi and Claude Code come from numtide's [llm-agents.nix](https://github.com/numtide/llm-agents.nix), prebuilt in their binary cache.

## Quick start

1. Let root accept your SSH key (NixOS disables password logins):
   ```bash
   ssh-copy-id root@VPS_IP
   ```
2. Create a reusable, non-ephemeral [Tailscale auth key](https://login.tailscale.com/admin/settings/keys).
3. On the VPS, as root:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/flpdorea/fleet/main/install.sh | TS_AUTHKEY=tskey-auth-... bash
   ```
   This **wipes the VPS** (it asks you to type `nixos` first), installs NixOS and reboots. On first boot, the machine applies this flake by itself.
4. For each context:
   ```bash
   ssh personal@VPS_IP
   fleet login    # git identity, GitHub, and the Pi (or Claude) login
   fleet pair     # link for the Orca app
   fleet          # talk to the first mate
   ```

The full walkthrough, including what to watch during the first boot, is in [docs/installation.md](docs/installation.md).

## Everyday commands

| Command | Run as | What it does |
|---|---|---|
| `fleet` | context user | open (or reattach to) the first mate in tmux |
| `Ctrl-b` then `d` | | detach, leaving everything running |
| `fleet status` | context user | setup, Orca server and first mate state |
| `fleet pair` | context user | link that connects the Orca app to this server |
| `fleet login` | context user | git identity, GitHub and the agent's login |
| `fleet-rebuild` | root | pull the latest version of this repo and apply it |

## Repository layout

```
fleet/
├── flake.nix                 inputs: nixpkgs 26.05, llm-agents.nix, firstmate
├── flake.lock                every pinned version (maintained by CI)
├── install.sh                Ubuntu/Debian → NixOS, via nixos-infect
├── nix/
│   ├── module.nix            the machine: users, Orca, Tailscale, firewall, services
│   ├── fleet.sh              the fleet command (packaged by Nix)
│   └── setup-user.sh         prepares each user's firstmate
├── homes/
│   ├── contexts.nix          personal = pi :6768 · work = claude :6769
│   ├── personal/config/      firstmate config: backend, crew-dispatch.json
│   └── work/config/          firstmate config: backend, crew-dispatch.json, claude-permission-mode
├── .github/workflows/nix.yml lock, lint and evaluate on every push
└── docs/
```

## Documentation

| Guide | Covers |
|---|---|
| [Architecture](docs/architecture.md) | How the pieces fit, why one Linux user per context, the security model |
| [Installation](docs/installation.md) | Prerequisites, the install command, first boot, logins, pairing |
| [Configuration](docs/configuration.md) | Contexts, model routing tiers, adding a context |
| [Operations](docs/operations.md) | Daily use, updates, restarts, troubleshooting |

## Known limits

- firstmate's Orca backend is experimental: it cannot send Escape and does not support secondmates.
- `no-mistakes` and the `*-axi` tools have no Nix package; firstmate installs them per user at runtime. They are the only part not pinned by `flake.lock`.
- Each Orca server uses a fair amount of memory. Contabo's guide recommends 12 GB for one; with two servers and several workers, size up.
