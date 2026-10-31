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
2. Run `scripts/github-settings.sh` (needs `gh` logged in as a repo admin). It allows only squash merges, uses the pull request title as the commit title and its body as the commit body, deletes merged branches, and adds a ruleset so `main` only changes through a pull request that is up to date with `main` (rebase it, or use **Update branch**), has every review thread resolved and whose CI passes: `nix`, `tailscale`, and the `pr` workflow that checks the title is a Conventional Commit, the template is filled in, the base is `main` (or the branch below in a stack) and, for forks, that an open issue is linked. `main` keeps a linear history. A second ruleset limits branch names to `<owner>/...`, a Conventional Commit type (`feat/...`, `fix/...`, `perf/...`), `dependabot/...` or `revert-...`. It turns on private vulnerability reporting, Dependabot alerts and fixes, and generic secret scanning; makes workflows from every external contributor wait for approval; allows only actions from GitHub or a short list, pinned by commit SHA; and turns off the wiki and projects. It also creates the `deploy` and `tailscale` environments, which only workflow runs on `main` can use, so no pull request ever sees their secrets, and the write deploy key, stored in the `deploy` environment as `DEPLOY_KEY`, that the `nix` workflow uses to push `flake.lock`: deploy keys are the only actor allowed to bypass the ruleset.
3. Set up Tailscale (see [Tailscale access](#tailscale-access) below).
4. Wait for the `nix` workflow to pass. It creates `flake.lock` and evaluates the whole NixOS configuration. **Do not install until it is green**, so a Nix error shows up in CI rather than on the VPS.
5. Publish the first release: **Actions → release → Run workflow** on `main` (see [Releases](operations.md#releases)). The install command downloads `install.sh` from the latest release, so it fails until one exists.

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
   It applies `tailscale/policy.hujson` (which defines `tag:fleet`), creates two OAuth clients and stores both in `~/.config/fleet/tailscale.env`, then revokes and deletes the access token. The read-write client, scoped to `policy_file` and `auth_keys` for that tag, goes to the `tailscale` environment as `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET`: CI applies the policy with it on `main`. The read-only client, scoped to `policy_file:read`, goes to the repo secrets `TS_POLICY_TEST_CLIENT_ID` / `TS_POLICY_TEST_SECRET`: pull requests test the policy with it. Pull requests from forks get no secrets and skip the test. Run it after `scripts/github-settings.sh`; rerunning it only creates the clients missing from that file.

`scripts/tailscale-authkey.sh` uses that file to mint a single-use, pre-approved key tagged `tag:fleet` that expires in an hour. Tagged devices are also exempt from key expiry, so the VPS does not drop off the tailnet after 180 days.

### SSH key and config

Give the fleet its own key, with a passphrase. It opens root on a machine where agents run third-party code, and `install.sh` copies every key on root to root and to the context users on NixOS, so a shared key, or a CI or deploy key that happens to be in your agent, would end up with root there too.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/fleet -C fleet
```

Then add three hosts to `~/.ssh/config`:

```sshconfig
# Root goes over the public IP: the only route until install.sh finishes.
Host fleet
  HostName VPS_IP
  User root
  IdentityFile ~/.ssh/fleet
  IdentitiesOnly yes
  AddKeysToAgent yes

# The context users go over the tailnet (MagicDNS), so they keep working
# if port 22 is ever closed to the internet.
Host fleet-personal fleet-work
  HostName fleet.YOUR-TAILNET.ts.net
  IdentityFile ~/.ssh/fleet
  IdentitiesOnly yes
  AddKeysToAgent yes

Host fleet-personal
  User personal

Host fleet-work
  User work
```

| Setting | Why |
|---|---|
| `IdentitiesOnly yes` | Offers only `~/.ssh/fleet`, never the other keys in your agent. |
| `AddKeysToAgent yes` | You type the passphrase once per session, not on every connection. |
| `HostName fleet.YOUR-TAILNET.ts.net` | The machine joins the tailnet as `fleet` (`--hostname=fleet` in `nix/module.nix`). Your tailnet name is under **DNS** in the admin console. These two hosts only resolve after install. |

### Per-VPS preparation

From your computer, copy the fleet key to root. This is the one time you type the provider's root password:

```bash
ssh-copy-id -i ~/.ssh/fleet.pub fleet
```

Install right after: until nixos-infect reboots, the provider's root password still works over SSH and the VNC console.

## Install

From your computer, in this repo, so the Tailscale key is minted locally and never written down:

```bash
ssh -t fleet "curl -fsSL https://github.com/flpdorea/fleet/releases/latest/download/install.sh | TS_AUTHKEY=$(scripts/tailscale-authkey.sh) bash"
```

| Variant | Command |
|---|---|
| One context only | add `FLEET_CONTEXTS=personal` before `bash` |
| No confirmation prompt | add `FLEET_YES=1` before `bash` |
| Different hostname | add `FLEET_HOSTNAME=name` before `bash` |
| Follow `main` instead of releases | fetch `https://raw.githubusercontent.com/flpdorea/fleet/main/install.sh` instead |
| A specific release | fetch `https://github.com/flpdorea/fleet/releases/download/v0.1.0/install.sh` |
| Without a Tailscale key | omit `TS_AUTHKEY`; run `tailscale up --advertise-tags=tag:fleet` as root after the reboot |

### What the script does

1. **Checks:** root, Ubuntu/Debian, a supported architecture, at least one SSH key in `/root/.ssh/authorized_keys`, and a valid repo.
2. **Asks you to type `nixos`** to confirm wiping the machine.
3. **Sets the hostname** to `fleet`. Contabo's default (`vmi000000.contaboserver.net`) is not a valid NixOS hostname.
4. **Writes `/etc/nixos`:** the machine's `flake.nix`, `fleet.nix` (contexts and SSH keys), the Tailscale key, and `fleet-bootstrap.nix`. nixos-infect preserves this directory.
5. **Runs nixos-infect** at a pinned commit. It installs NixOS, moves the old system aside and **reboots**.

## First boot

The machine comes back as a minimal NixOS. The `fleet-bootstrap` service then builds the full configuration from this repo, makes it the boot default and reboots into it. SSH host keys are preserved, so you will not get a host key warning.

```bash
ssh fleet
journalctl -fu fleet-bootstrap
```

Wait for `fleet: ready, rebooting into the full system`; the connection drops right after. Most of the time goes to downloading packages from the NixOS and numtide caches. After the reboot, the context users exist, the machine joins the tailnet and both `fleet-setup-<ctx>` services run. If a step fails, the service retries every 30 seconds on its own.

Check that everything is up:

```bash
systemctl status fleet-setup-personal orca-serve-personal
tailscale ip -4
```

If the bootstrap failed, see [operations](operations.md#the-first-boot-did-not-finish).

## Sign in, per context

```bash
ssh fleet-personal
fleet login
```

`fleet login` walks you through:

| Step | How it works over SSH |
|---|---|
| Git identity | Prompts for the commit author name and email of this context. |
| GitHub | `gh auth login --web` prints a one-time code and a URL; open it on any device. Then `gh auth setup-git` makes git use it. |
| Pi (if `primary = "pi"`) | Opens Pi. Run `/login`, choose the ChatGPT subscription (`openai-codex`), open the link in your browser and paste the final redirect URL back. Then `/quit`. |
| Claude | Opens Claude Code. Sign in with this context's account, then `/exit`. |

Steps that are already done are skipped, so `fleet login` is safe to rerun. Repeat with `ssh fleet-work`.

## Pair the Orca app

```bash
fleet pair
```

It prints that context's pairing link. On your Mac or phone, with Tailscale connected: **Orca → Settings → Remote Orca Servers → Add Server**, name it (`fleet personal`) and paste the link. Repeat for `work`. Treat these links like passwords.

## Notifications on the phone

The VPS runs an [ntfy](https://ntfy.sh) server on port 2586, reachable only through the tailnet, with one topic per context. Each topic is named with a secret (`personal-<random>`), since anyone who knows a topic can read and publish to it. Hooks and scripts on the VPS publish to it with `fleet notify` when something needs you: an agent waiting for input or done with a long task, a Lavish board or a pull request it opened (see [Claude Code settings](configuration.md#claude-code-settings)), and a pull request ready to merge (`fleet-pr-ready-<ctx>`). Agents never send notifications themselves.

1. Install the ntfy app on the phone ([Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy), [iOS](https://apps.apple.com/app/ntfy/id1625396347)) and keep Tailscale connected.
2. On the VPS, as each context user, run `fleet pair`: it also prints the context's topic and server. In the app, add a subscription with that topic, **Use another server** and that server (`http://fleet:2586`). Repeat for `work`. On Android, turn on **Instant delivery** so messages arrive without Google's push service.
3. Check it from the VPS, as the context user:

   ```bash
   fleet notify "Hello" "from $(whoami)"
   ```

If the phone does not resolve the short name `fleet`, use the full MagicDNS name (`tailscale status` on the VPS shows it, such as `fleet.tail1234.ts.net`) in the app and set it in `/etc/nixos/fleet.nix`, so links in notifications use it too:

```nix
fleet.ntfyBaseUrl = "http://fleet.tail1234.ts.net:2586";
```

On iOS, the app only receives pushes from a self-hosted server through Apple's push service, which needs ntfy.sh as an upstream relay: the VPS then sends ntfy.sh a poll request (an ID, not the message) for each notification. fleet does not set one up, so without it iOS shows notifications only while the app is open; Android receives them directly. To relay through ntfy.sh, add `services.ntfy-sh.settings.upstream-base-url = "https://ntfy.sh";` to `/etc/nixos/fleet.nix`.

## First run

In the Orca app, open the paired server, add a repo and start an agent in one of its worktrees, for example:

```
> fix the flaky login test and open a pull request
```

The agent keeps running on the VPS when you close the app. Run `fleet` on the VPS to list the other commands.
