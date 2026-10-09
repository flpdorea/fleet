# Installation

## Before you start

| You need | Why |
|---|---|
| A fresh Ubuntu or Debian VPS (x86_64 or aarch64) | `install.sh` converts it to NixOS with [nixos-infect](https://github.com/elitak/nixos-infect), which lists Contabo as supported. |
| Enough memory | Contabo's Orca guide recommends 12 GB for one Orca server. Two servers plus workers need more. |
| Your SSH public key on root | NixOS disables password logins. Without a key you would be locked out, so `install.sh` refuses to run. |
| A Tailscale account and auth key | Orca is only reachable through your tailnet. |
| This repo on GitHub, public | The VPS fetches `install.sh` and the flake from it. It contains no secrets. |

### One-time repo setup

1. Push the repo to GitHub.
2. In the repo: **Settings → Actions → General → Workflow permissions → Read and write**. CI needs this to commit `flake.lock`.
3. Wait for the `nix` workflow to pass. It creates `flake.lock` and evaluates the whole NixOS configuration. **Do not install until it is green**, so a Nix error shows up in CI rather than on the VPS.

### Per-VPS preparation

From your computer:

```bash
ssh-copy-id root@VPS_IP
```

Create a Tailscale auth key at **Settings → Keys**: reusable, **not** ephemeral (an ephemeral node disappears from the tailnet when it goes offline).

## Install

On the VPS, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/flpdorea/fleet/main/install.sh | TS_AUTHKEY=tskey-auth-... bash
```

| Variant | Command |
|---|---|
| One context only | add `FLEET_CONTEXTS=personal` before `bash` |
| No confirmation prompt | add `FLEET_YES=1` before `bash` |
| Different hostname | add `FLEET_HOSTNAME=name` before `bash` |
| Without a Tailscale key | omit `TS_AUTHKEY`; run `tailscale up` as root after the reboot |

### What the script does

1. **Checks:** root, Ubuntu/Debian, a supported architecture, at least one SSH key in `/root/.ssh/authorized_keys`, and a valid repo.
2. **Asks you to type `nixos`** to confirm wiping the machine.
3. **Sets the hostname** to `fleet`. Contabo's default (`vmi000000.contaboserver.net`) is not a valid NixOS hostname.
4. **Writes `/etc/nixos`:** the machine's `flake.nix`, `fleet.nix` (contexts and SSH keys), the Tailscale key, and `fleet-bootstrap.nix`. nixos-infect preserves this directory.
5. **Runs nixos-infect** at a pinned commit. It installs NixOS, moves the old system aside and **reboots**.

## First boot

The machine comes back as a minimal NixOS. The `fleet-bootstrap` service then switches it to the full configuration from this repo. SSH host keys are preserved, so you will not get a host key warning.

```bash
ssh root@VPS_IP
journalctl -fu fleet-bootstrap
```

Wait for `fleet: ready`. Most of the time goes to downloading packages from the NixOS and numtide caches. During the switch, the context users are created and both `fleet-setup-<ctx>` services run.

Check that everything is up:

```bash
systemctl status fleet-setup-personal orca-serve-personal
tailscale ip -4
```

If the bootstrap failed, see [operations](operations.md#the-first-boot-did-not-finish).

## Sign in, per context

```bash
ssh personal@VPS_IP
fleet login
```

`fleet login` walks you through:

| Step | How it works over SSH |
|---|---|
| Git identity | Prompts for the commit author name and email of this context. |
| GitHub | `gh auth login --web` prints a one-time code and a URL; open it on any device. Then `gh auth setup-git` makes git use it. |
| Pi (`personal`) | Opens Pi. Run `/login`, choose the ChatGPT subscription (`openai-codex`), open the link in your browser and paste the final redirect URL back. Then `/quit`. |
| Claude (`work`) | Opens Claude Code. Sign in with the work account, then `/exit`. |

Steps that are already done are skipped, so `fleet login` is safe to rerun. Repeat as `work@VPS_IP`.

## Pair the Orca app

```bash
fleet pair
```

It prints that context's pairing link. On your Mac or phone, with Tailscale connected: **Orca → Settings → Remote Orca Servers → Add Server**, name it (`fleet personal`) and paste the link. Repeat for `work`. Treat these links like passwords.

## First run

```bash
fleet
```

The first time, the harness asks you to trust the project directory. Approve it: firstmate's Pi extensions and Claude hooks only load in a trusted project. Then talk to your first mate, for example:

```
> look at my github project xyz, then fix the flaky login test
```

Detach with `Ctrl-b` then `d`. The first mate and its crew keep running; `fleet` reattaches.
