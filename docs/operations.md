# Operations

## Daily use

Day to day, you work from the Orca app: start agents in a repo's worktrees, watch and type into their terminals, and follow their GitHub pull requests. Agents keep running on the VPS when the app is closed.

On the VPS, `fleet` lists the commands:

```bash
ssh fleet-personal      # or fleet-work (see installation: SSH key and config)
fleet status            # whether setup ran and whether Orca is ready
fleet services          # the context's services, and when the polled ones run next
```

### Managing the services

Each context runs four services, which `fleet` names `orca` (the Orca server), `setup` (`fleet-setup-<ctx>`), `pr-ready` and `agent-comments` (the last two poll GitHub on a timer). A context user manages its own context's services, without sudo; root manages every context's, or one with `--context <ctx>`:

```bash
fleet restart orca            # asks first: it kills the agents running in Orca
fleet restart setup           # rerun the setup
fleet stop agent-comments     # pause the polling until the next boot or rebuild
fleet start agent-comments    # resume it
fleet run pr-ready            # poll once, now
fleet logs agent-comments -f  # its log, following what it writes next
```

A polkit rule in `nix/module.nix` allows each context user to start, stop and restart its own context's units and nothing else. Each service logs to `/var/log/fleet/<service>-<ctx>.log`, readable by its context user, which `fleet logs` shows. All but Orca's are rotated weekly; Orca's keeps the pairing link that `fleet pair` reads.

The `orca-cli` and `orchestration` skills are installed for each harness, so an agent can still drive Orca or other agents when you ask it to. `orca skills list` shows the Orca skills available.

### Starting an agent from an issue

Comment on an issue, in a repo added to the context's Orca, with a comment that starts with `/agent`, for example:

```text
/agent fix it --effort high
Keep the old flag working for one more release.
```

Within a minute, `fleet-agent-comments-<ctx>` starts the context's agent in a new worktree named after the issue, reacts to the comment with eyes and replies with the worktree and branch; the worktree shows up in the Orca app. The first line may set `--effort` (`low` to `max`) and `--model`; the rest is instructions. With none, the agent plans the work in Lavish and waits for your approval. Only comments written by the context's GitHub account (the one `fleet login` signed in) count, and each comment starts one agent: editing it, or an older comment, starts nothing. A comment posted while Orca or GitHub was unreachable for more than an hour is dropped. If the agent cannot start, the reply says so; the details are in `fleet logs agent-comments`.

## Updating

### This repo's config (contexts, skills, module)

1. Edit, commit, push a branch and open a pull request. Its title must be a Conventional Commit (it becomes the squash commit on `main`) and its body must fill in the template.
2. Squash-merge it once it is up to date with `main` and its checks pass; the ruleset blocks the merge until then. If `main` moved, rebase the branch (`git rebase origin/main`, or **Update branch → Update with rebase**) and let the checks rerun.
3. On the VPS, as root:
   ```bash
   fleet rebuild
   ```

`fleet rebuild` updates the machine's `fleet` input and switches to it: to the latest release, or to the latest commit when the machine follows a branch (see [Releases](#releases)). `fleet-setup-<ctx>` reruns when the repo or Orca changed, so each harness gets fresh Orca skills. When it ends, every context's phone gets a notification: the release or branch and commit now live, or that the rebuild failed and with which exit code (see [Notifications on the phone](installation.md#notifications-on-the-phone)).

### Versions (NixOS, Orca, Pi, Claude Code)

CI runs `nix flake update` every Monday and commits the new `flake.lock` if the configuration still evaluates. To update now, run the workflow manually (**Actions → nix → Run workflow**), or locally:

```bash
nix flake update             # everything
nix flake update llm-agents  # just one input
```

Then open a pull request, merge it and run `fleet rebuild`.

### Releases

A machine follows one of two tracks, set by `inputs.fleet.url` in its `/etc/nixos/flake.nix`:

| Track | `inputs.fleet.url` | `fleet rebuild` moves to |
|---|---|---|
| Releases (what `install.sh` from a release sets up) | `github:flpdorea/fleet/v0.3.1` | the latest release |
| A branch, usually `main` | `github:flpdorea/fleet/main` | the latest commit on it |

The maintainer's VPS follows `main`, so every change runs there before it is released. To switch tracks, or pin or roll back to a release:

```bash
fleet rebuild --ref main      # follow main
fleet rebuild --ref v0.3.1    # that release; later rebuilds follow releases again
```

On releases, `fleet rebuild` asks before moving to a release that may need manual steps: a new minor version below 1.0, a new major version after. Read its notes first.

To publish a release, run **Actions → release → Run workflow** on `main`. It computes the version from the Conventional Commit titles since the last release (`feat` bumps the minor version, anything else the patch; see `cliff.toml`), tags it, and publishes the notes with a copy of `install.sh` that installs that release. The weekly `flake.lock` update counts as a patch. Tags and releases are immutable, and only the workflow can create them. Anyone can check that an `install.sh` came from this workflow:

```bash
gh attestation verify install.sh -R flpdorea/fleet
```

### Restarting Orca after an update

Rebuilds **never restart** the Orca servers, because a restart kills the workers in flight. After a rebuild that changed Orca, restart the servers at a quiet moment, every context's as root or each one as its user:

```bash
fleet restart orca
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

- **Do not open the Orca or ntfy ports in the firewall.** Pair and subscribe over Tailscale.

## Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| `fleet: this user is not a fleet context` | `systemctl status fleet-setup-<ctx>` | The setup service has not run or failed. `fleet logs setup --context <ctx>` as root shows what the setup printed; `journalctl -u fleet-setup-<ctx>` shows why systemd did not run it. |
| `fleet status` says Orca `no response` | `fleet services`, `fleet logs orca` | Usually Tailscale is down: `tailscale status`, then `tailscale up` as root. |
| `fleet pair` prints no link | the log above | The server is still starting or failing. Restart it: `fleet restart orca`. |
| Orca app shows the server as disconnected | Tailscale on your device | Both devices must be on the same tailnet. Update Orca on both sides if it reports an incompatible protocol. |
| Worker dispatch fails | `fleet status` | Orca must report `ready`. Wait for the server or restart it. |
| `fleet status` says setup `pending` | `fleet logs setup` | Installing the Orca skills needs the network (`npx skills`). `fleet restart setup` retries. |
| A worker fails on a downloaded binary | | `nix-ld` is enabled for this; if a tool needs an extra library, add it to `programs.nix-ld.libraries` in `nix/module.nix`. |
| `docker`: cannot connect to the daemon | `systemctl --user status docker` as the user | The rootless daemon runs in the user's systemd manager. `systemctl --user restart docker` restarts it. An `orca-serve-<ctx>` started before Docker was added has no `DOCKER_HOST`: restart it (`fleet restart orca`). |

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
