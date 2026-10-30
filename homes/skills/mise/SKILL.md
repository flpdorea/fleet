---
name: mise
description: Manage language runtimes (Node, Python, Ruby, Go, Java, Rust and others) with mise on the fleet VPS. Use whenever a project needs a specific runtime version, a version file is present (mise.toml, .tool-versions, .nvmrc, .node-version, .python-version, .ruby-version, .go-version, .java-version), a command fails with "command not found" or a wrong runtime version, the user asks to install, pin, upgrade or switch a language version, or to change the default runtimes. Use it instead of nix, apt, nvm, pyenv, rbenv or curl-pipe installers for language runtimes.
---

# mise

Language runtimes on this machine come from [mise](https://mise.jdx.dev). It is already installed and on the PATH through its shims (`~/.local/share/mise/shims`), so `node`, `python`, `ruby`, `go`, `java`, `cargo` and friends resolve to the version the current directory asks for, in interactive and non-interactive shells alike. No `mise activate` is needed.

## Where versions come from

From most to least specific:

1. The project: `mise.toml` or `.mise.toml`, `.tool-versions`, and the idiomatic files (`.nvmrc`, `.node-version`, `.python-version`, `.ruby-version`...), looked up from the current directory upward.
2. The user's global config: `~/.config/mise/config.toml`.
3. The fleet defaults: `/etc/mise/config.toml`, installed from `homes/mise.toml` in the fleet repo. Today: Node LTS, Python, Ruby, Go, Java (Temurin LTS) and Rust stable.

`mise ls --current` shows what is active here and which file set it. `mise doctor` diagnoses setup problems.

Config files under `~/orca/workspaces` are trusted automatically. Elsewhere, mise refuses a `mise.toml` until it is trusted: read it first (it can set env vars and run tasks), then `mise trust`.

## Working in a project

- **Start of a task in a repo with version files**: run `mise install` in the repo root. It installs whatever is missing and does nothing otherwise. Do this before running tests or builds, rather than after the first failure.
- **A command is missing or the wrong version**: `mise ls --current` and `mise which <cmd>` to see why, then `mise install`.
- **A one-off with another version**: `mise exec node@22 -- node script.js`, without touching any file.
- **Pinning a version for the project**: only when the user asks or the project clearly needs it. Prefer the format the repo already uses (edit `.nvmrc` if that is what it has). Otherwise `mise use node@24` writes `mise.toml` in the current directory. Pinning is a repo change: commit it with the rest of the work and mention it.
- **A tool beyond the main languages** (bun, deno, terraform, kubectl, uv, pnpm...): `mise use <tool>@<version>` in the project, or `mise exec <tool>@<version> -- ...` for a single run. `mise registry | grep <name>` finds the backend.

Never install language runtimes with `nix profile`, `apt`, nvm, pyenv, rbenv, rustup scripts or `curl | sh` installers: they fight with the shims. Python packages go in a virtualenv (`python -m venv .venv`) or through `uv`, not into the mise-managed interpreter with a bare `pip install`.

## NixOS specifics

- Runtimes are mise's prebuilt binaries, which run thanks to nix-ld. `all_compile = false` in the fleet config keeps it that way; don't set `compile` options back on, source builds fail here.
- `gcc`, `make` and `pkg-config` are installed for native extensions (node-gyp, gems, Python packages without wheels) and for linking Rust. If a build needs a system library's headers (openssl, libpq, libyaml...), run it inside a Nix shell that provides them, for example `nix shell nixpkgs#openssl.dev nixpkgs#pkg-config -c bundle install`.
- A prebuilt binary that fails with a missing shared library needs that library in `programs.nix-ld.libraries` in `nix/module.nix` of the fleet repo: propose it with the `self-improve` skill.

## Changing the defaults

The default runtimes belong to the fleet repo, not to this machine. To add one or bump a version (a new Node LTS, a new Python or Ruby release, the next Java LTS), edit `[tools]` in `homes/mise.toml` and open a PR, following the `self-improve` skill. Check the version exists first: `mise latest node@lts`, `mise ls-remote python | tail`. After the PR is merged, `fleet rebuild` installs the new defaults for every context.

`mise use -g` writes `~/.config/mise/config.toml`, which rebuilds don't touch: fine for something only this user wants, but say so, since it is invisible to the repo. Never edit `/etc/mise/config.toml`; it is read-only and rebuilt from the repo.

Old versions stay on disk after a bump. `mise prune` removes the ones no config file uses any more.
