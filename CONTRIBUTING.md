# Contributing

fleet is my personal setup, published as a starting point for yours. Forking it and making it your own is the main way to use it. Contributions are welcome when they fix something or make the setup easier to adopt; changes that only fit a different workflow belong in your fork.

## Issues

Open issues from the **Bug** or **Feature** template; blank issues are disabled and a workflow flags issues with required fields left empty. Report security problems privately instead, as described in [SECURITY.md](SECURITY.md).

## Pull requests

1. Open an issue first and wait for a go-ahead. A pull request from a fork must close an open issue (`Closes #123` in its body), even for a typo.
2. Target `main`. Keep each pull request to one concern.
3. Title it as a [Conventional Commit](https://www.conventionalcommits.org): `type(scope): summary`, summary in lowercase, such as `fix(nix): ...` or `docs: ...`. It becomes the squash commit on `main`.
4. Fill in every section of the pull request template.
5. Check what you can locally: `nix eval --raw .#nixosConfigurations.ci.config.system.build.toplevel.drvPath` evaluates the whole configuration, and the shell scripts must pass `shellcheck -S warning`. Changes to the Nix module are best tested with a rebuild on a VPS of your own; say in **Testing** whether you did.

CI checks all of the above, and `main` only accepts squash merges of pull requests whose checks pass. Workflows from first-time and external contributors run only after a maintainer approves them.

## Code of conduct

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
