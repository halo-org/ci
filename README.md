# CI for Nix flakes

A reusable GitHub Actions workflow that builds every check in a flake. The
flake is the source of truth. There is nothing to configure per repository.

```yaml
name: CI

on: [push, pull_request]

jobs:
  check:
    uses: halo-org/ci/.github/workflows/ci.yml@main
```

## What it builds

The workflow checks out the calling repository and evaluates the flake at its
root. It runs `nix flake check --no-build`, so any evaluation error that
`nix flake check` would report still fails the run. It then lists every
attribute of `checks.x86_64-linux` and `checks.aarch64-linux` and builds each
one in its own job, named after the check. When the flake has checks for both
systems, the job names also include the system. Other systems are ignored for
now.

A failed build fails its job and the run. The other checks keep building.

## Without builders

With no inputs, each check builds on a GitHub-hosted runner of its system:
`ubuntu-latest` for `x86_64-linux` and `ubuntu-24.04-arm` for `aarch64-linux`.
Each job checks out the repository and builds its check with `nix build`.
Dependencies come from the substituters the flake already uses, such as
cache.nixos.org.

## Inputs

### `builders`

Remote builders in Nix's machines format, one per line. This is the same
format as the `builders` setting in `nix.conf`. Blank lines and `#` comments
are ignored. Empty means no builders.

```
ssh-ng://ci@builder.example.com x86_64-linux - 16 1 - - c3NoLWVkMjU1MTkgQUFBQUMzTnph...
```

Only three fields are used:

- The store URI. It is passed to `nix build --store`, so use `ssh-ng://`.
- The systems. A check builds on the first builder that lists its system.
- The public host key, base64 encoded as Nix defines it. It is added to
  `known_hosts`. Without it, SSH refuses to connect.

The SSH key, job count, speed factor and features are ignored. Every builder
uses the `builder-ssh-key` secret.

A check with a matching builder builds there with
`nix build --store <uri> <drv>^*`. Its outputs stay in the builder's store and
nothing is copied back to the runner. The evaluation job copies the
derivations to each builder once, so these jobs need no checkout and do not
evaluate the flake again. This is not Nix's distributed build mode, which
would copy every output back to the runner.

The builder's SSH user does not need to be a trusted Nix user.

### `pin`

A name to pin the checks under, using letters, digits, `.`, `_` and `-`.
Empty by default.

When set, after a push to the default branch and once every check has passed,
the workflow runs `ssh <host> pin <name>` on each builder that built a check.
It sends the derivation paths of the checks built there on stdin, one per
line.

This is not part of Nix. It is a command the builder has to provide. A
builder that garbage collects its store can use it to keep the latest
outputs of each repository. Each call should replace the set previously
pinned under that name.

## Secrets

### `builder-ssh-key`

The SSH private key for every builder. Optional.

The workflow reads no variables or secrets of its own. Pass them explicitly:

```yaml
jobs:
  check:
    uses: halo-org/ci/.github/workflows/ci.yml@main
    with:
      builders: ${{ vars.NIX_BUILDERS }}
      pin: ${{ github.event.repository.name }}
    secrets:
      builder-ssh-key: ${{ secrets.NIX_BUILDER_SSH_KEY }}
```

## Testing

On pull requests, this repository calls the workflow on its own flake, which
has a trivial check for each supported system. That covers the path without
builders on both kinds of runner.
