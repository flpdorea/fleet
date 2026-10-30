# Operations

## Daily use

Day to day, you work from the Orca app: start agents in a repo's worktrees, watch and type into their terminals, and follow their GitHub pull requests. Agents keep running on the VPS when the app is closed.

On the VPS, `fleet` lists the commands:

```bash
ssh fleet-personal      # or fleet-work (see installation: SSH key and config)
fleet status            # whether setup ran and whether Orca is ready
```

The `orca-cli` and `orchestration` skills are installed for each harness, so an agent can still drive Orca or other agents when you ask it to. `orca skills list` shows the Orca skills available.

## Updating

### This repo's config (contexts, skills, module)

1. Edit, commit, push a branch and open a pull request. Its title must be a Conventional Commit (it becomes the squash commit on `main`) and its body must fill in the template.
2. Squash-merge it once it is up to date with `main` and its checks pass; the ruleset blocks the merge until then. If `main` moved, rebase the branch (`git rebase origin/main`, or **Update branch → Update with rebase**) and let the checks rerun.
3. On the VPS, as root:
   ```bash
   fleet rebuild
   ```

`fleet rebuild` updates the machine's `fleet` input to the latest commit and switches to it. `fleet-setup-<ctx>` reruns when the repo or Orca changed, so each harness gets fresh Orca skills.

### Versions (NixOS, Orca, Pi, Claude Code)

CI runs `nix flake update` every Monday and commits the new `flake.lock` if the configuration still evaluates. To update now, run the workflow manually (**Actions → nix → Run workflow**), or locally:

```bash
nix flake update             # everything
nix flake update llm-agents  # just one input
```

Then open a pull request, merge it and run `fleet rebuild`.

### Restarting Orca after an update

Rebuilds **never restart** the Orca servers, because a restart kills the workers in flight. After a rebuild that changed Orca, restart each server at a quiet moment:

```bash
systemctl restart orca-serve-personal
systemctl restart orca-serve-work
```

Paired clients should reconnect by themselves. If one stays disconnected, pair it again with the link from `fleet pair`.

### Rolling back

Every rebuild is a NixOS generation:

```bash
nixos-rebuild switch --rollback     # previous generation
nixos-rebuild list-generations
```

You can also pick an older generation from the boot menu.

## Things not to do

- **Do not open the Orca ports in the firewall.** Pair over Tailscale.

## Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| `fleet: this user is not a fleet context` | `systemctl status fleet-setup-<ctx>` | The setup service has not run or failed. `journalctl -u fleet-setup-<ctx>` as root shows why. |
| `fleet status` says Orca `no response` | `systemctl status orca-serve-<ctx>`, `tail -n 50 /var/log/fleet/orca-<ctx>.log` | Usually Tailscale is down: `tailscale status`, then `tailscale up` as root. |
| `fleet pair` prints no link | the log above | The server is still starting or failing. Restart it: `systemctl restart orca-serve-<ctx>`. |
| Orca app shows the server as disconnected | Tailscale on your device | Both devices must be on the same tailnet. Update Orca on both sides if it reports an incompatible protocol. |
| Worker dispatch fails | `fleet status` | Orca must report `ready`. Wait for the server or restart it. |
| `fleet status` says setup `pending` | `journalctl -u fleet-setup-<ctx>` | Installing the Orca skills needs the network (`npx skills`). `systemctl restart fleet-setup-<ctx>` retries. |
| A worker fails on a downloaded binary | | `nix-ld` is enabled for this; if a tool needs an extra library, add it to `programs.nix-ld.libraries` in `nix/module.nix`. |
| `docker`: cannot connect to the daemon | `systemctl --user status docker` as the user | The rootless daemon runs in the user's systemd manager. `systemctl --user restart docker` restarts it. An `orca-serve-<ctx>` started before Docker was added has no `DOCKER_HOST`: restart it. |

### The first boot did not finish

```bash
ssh fleet
journalctl -u fleet-bootstrap
```

- **Build error in the flake:** fix it in the repo (CI should have caught it) and push, then on the VPS run `nix --extra-experimental-features 'nix-command flakes' flake update fleet --flake /etc/nixos`. The service is retrying every 30 seconds and picks up the fix on its next attempt.
- **Network or cache timeout:** nothing to do. It retries every 30 seconds until it succeeds once.
- **Cannot SSH in at all:** use Contabo's VNC console. root's SSH keys come from `/etc/nixos/configuration.nix`.

## Removing a context

1. Remove it from `fleet.contexts` in `/etc/nixos/fleet.nix` and run `fleet rebuild`. Its services stop.
2. `/home/<ctx>` is not deleted, so its logins, harness config and Orca worktrees stay. Remove the directory by hand when you are sure you no longer need it.
