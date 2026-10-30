# Security policy

fleet installs NixOS as root on a VPS and runs coding agents there, so a flaw in it can expose a whole machine and the accounts logged in on it. Please report vulnerabilities privately.

## Reporting a vulnerability

Use [Report a vulnerability](https://github.com/flpdorea/fleet/security/advisories/new) on this repository. Don't open a public issue or pull request for it.

Include what is affected (a script, the Nix module, a workflow, the Tailscale policy), how to reproduce it, and what an attacker gains. You'll get an answer within a week. Once a fix is released, the advisory is published with credit to you, unless you'd rather stay anonymous.

## Supported versions

Only the latest release and `main` get fixes. Update with `fleet rebuild`.

## Scope

In scope: everything in this repository, including the GitHub workflows and the settings that `scripts/github-settings.sh` applies.

Out of scope: vulnerabilities in Orca, Claude Code, Tailscale, NixOS or other upstream projects; report those to them. Behavior of the agents themselves, such as following a malicious prompt in a repo they work on, is out of scope unless something in this repository makes it worse.
