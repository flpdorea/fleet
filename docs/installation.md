# Installation

## Before you start

| You need | Why |
|---|---|
| A fresh Ubuntu or Debian VPS (x86_64 or aarch64) | `install.sh` converts it to NixOS with [nixos-infect](https://github.com/elitak/nixos-infect), which lists Contabo as supported. |
| Enough memory | Contabo's Orca guide recommends 12 GB for one Orca server. Two servers plus workers need more. |
| Your SSH public key on root | NixOS disables password logins. Without a key you would be locked out, so `install.sh` refuses to run. Every key on root is copied to root and to the context users on NixOS, so copy only your own. |
| A Tailscale account and an OAuth client | Orca is only reachable through your tailnet. The OAuth client lets CI apply the access policy and lets you mint the install key. |
| This repo on GitHub, public | The VPS fetches `install.sh` and the flake from it. It contains no secrets. |

### One-time repo setup

1. Push the repo to GitHub.
2. In the repo: **Settings → Actions → General → Workflow permissions → Read and write**. CI needs this to commit `flake.lock`.
3. Set up Tailscale (see [Tailscale access](#tailscale-access) below).
4. Wait for the `nix` workflow to pass. It creates `flake.lock` and evaluates the whole NixOS configuration. **Do not install until it is green**, so a Nix error shows up in CI rather than on the VPS.

### Tailscale access

The agents on the VPS run code from repos and prompts you do not fully control, so the VPS joins the tailnet as `tag:fleet`. `tailscale/policy.hujson` lets your own devices reach it but gives tagged devices no rule as a source, so the VPS cannot open a connection to your laptop or phone. The `tailscale` workflow tests that file on every pull request and applies it on merge, overwriting edits made in the admin console.

Once per tailnet, with a single browser step:

1. **Settings → Keys → Generate access token**, expiring in 1 day. Save it without echoing it:
   ```bash
   mkdir -p ~/.config/fleet && (umask 077; read -rsp 'Access token: ' t; echo; printf '%s' "$t" > ~/.config/fleet/ts-api-token)
   ```
2. From this repo:
   ```bash
   scripts/tailscale-bootstrap.sh
   ```
   It applies `tailscale/policy.hujson` (which defines `tag:fleet`), creates an OAuth client scoped to `policy_file` and `auth_keys` for that tag, stores it in `~/.config/fleet/tailscale.env` and in the repo's `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` secrets, then revokes and deletes the access token.

`scripts/tailscale-authkey.sh` uses that file to mint a single-use, pre-approved key tagged `tag:fleet` that expires in an hour. Tagged devices are also exempt from key expiry, so the VPS does not drop off the tailnet after 180 days.

### Per-VPS preparation

From your computer, copy only your own key (`install.sh` carries every key on root over to NixOS):

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@VPS_IP
```

Install right after: until nixos-infect reboots, the provider's root password still works over SSH and the VNC console.

## Install

From your computer, in this repo, so the Tailscale key is minted locally and never written down:

```bash
ssh -t root@VPS_IP "curl -fsSL https://raw.githubusercontent.com/flpdorea/fleet/main/install.sh | TS_AUTHKEY=$(scripts/tailscale-authkey.sh) bash"
```

| Variant | Command |
|---|---|
| One context only | add `FLEET_CONTEXTS=personal` before `bash` |
| No confirmation prompt | add `FLEET_YES=1` before `bash` |
| Different hostname | add `FLEET_HOSTNAME=name` before `bash` |
| Without a Tailscale key | omit `TS_AUTHKEY`; run `tailscale up --advertise-tags=tag:fleet` as root after the reboot |

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
