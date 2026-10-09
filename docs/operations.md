# Operations

## Daily use

```bash
ssh personal@VPS_IP     # or work@
fleet                   # attach to the first mate
```

- Detach with `Ctrl-b` then `d`. Nothing stops.
- Watch and type into any worker's terminal from the Orca app.
- `fleet status` shows whether setup ran, whether Orca is ready, and whether the first mate is running.

firstmate's own commands work inside the session, for example `/bearings` for a fleet digest or `/afk` before you step away. See the [firstmate README](https://github.com/kunchenguid/firstmate#built-in-skills).

## Updating

### This repo's config (routing, contexts, module)

1. Edit, commit and push.
2. Wait for the `nix` workflow to pass.
3. On the VPS, as root:
   ```bash
   fleet-rebuild
   ```

`fleet-rebuild` updates the machine's `fleet` input to the latest commit and switches to it. `fleet-setup-<ctx>` reruns when the repo or the firstmate pin changed, so new config lands in each firstmate checkout.

### Versions (NixOS, Orca, Pi, Claude Code, firstmate)

CI runs `nix flake update` every Monday and commits the new `flake.lock` if the configuration still evaluates. To update now, run the workflow manually (**Actions → nix → Run workflow**), or locally:

```bash
nix flake update            # everything
nix flake update firstmate  # just one input
```

Then push and run `fleet-rebuild`.

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

- **Do not run `/updatefirstmate`** inside a fleet. It moves firstmate past the commit pinned in `flake.lock`, and the next `fleet-setup` run would move it back. Update the `firstmate` input instead.
- **Do not edit `~/fleet/firstmate/config/` by hand** for anything that also exists in `homes/<ctx>/config/`. The setup service overwrites those files. Files that exist only on the machine (for example `/supervision-model` choices) are left alone.
- **Do not open the Orca ports in the firewall.** Pair over Tailscale.

## Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| `fleet: this user is not a fleet context` | `systemctl status fleet-setup-<ctx>` | The setup service has not run or failed. `journalctl -u fleet-setup-<ctx>` as root shows why. |
| `fleet status` says Orca `no response` | `systemctl status orca-serve-<ctx>`, `tail -n 50 /var/log/fleet/orca-<ctx>.log` | Usually Tailscale is down: `tailscale status`, then `tailscale up` as root. |
| `fleet pair` prints no link | the log above | The server is still starting or failing. Restart it: `systemctl restart orca-serve-<ctx>`. |
| Orca app shows the server as disconnected | Tailscale on your device | Both devices must be on the same tailnet. Update Orca on both sides if it reports an incompatible protocol. |
| Spawns fail with a `backend=orca` error | `fleet status` | firstmate requires Orca to report `reachable=true` and `state=ready`. Wait for the server or restart it. |
| `fleet-setup` lists `MISSING: ...` | the setup log | A runtime tool failed to install (often a network hiccup). `systemctl restart fleet-setup-<ctx>` retries. |
| A worker fails on a downloaded binary | | `nix-ld` is enabled for this; if a tool needs an extra library, add it to `programs.nix-ld.libraries` in `nix/module.nix`. |
| Pi worker spawns are refused | `pi auth check --provider openai-codex` as `personal` | The `pi-account` pin refuses launches when the subscription is not signed in. Run `fleet login`. |
| `CREW_DISPATCH: invalid ...` | the setup log | A model, harness or effort in `crew-dispatch.json` is not accepted. See [model IDs](configuration.md#model-ids). |

### The first boot did not finish

```bash
ssh root@VPS_IP
journalctl -u fleet-bootstrap
```

- **Build error in the flake:** fix it in the repo (CI should have caught it), push, then run `nixos-rebuild switch --flake /etc/nixos#fleet` as root. Once that succeeds, run `mkdir -p /var/lib/fleet && touch /var/lib/fleet/bootstrapped` so the bootstrap does not run again.
- **Network or cache timeout:** `systemctl restart fleet-bootstrap`. It keeps retrying until it succeeds once.
- **Cannot SSH in at all:** use Contabo's VNC console. root's SSH keys come from `/etc/nixos/configuration.nix`.

## Removing a context

1. Remove it from `fleet.contexts` in `/etc/nixos/fleet.nix` and run `fleet-rebuild`. Its services stop.
2. `/home/<ctx>` is not deleted, so its logins, firstmate state and project clones stay. Remove the directory by hand when you are sure you no longer need it.
