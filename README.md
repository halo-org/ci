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

## Artifacts

A flake can say what kinds of artifact it produces with these outputs:

- `packages.<system>.<name>`: packages, as in any flake.
- `ociImages.<system>.<name>`: OCI images, as in the standard flake schemas.
  Each is a derivation whose output is an OCI image layout directory with
  `oci-layout`, `index.json` and `blobs/`. `index.json` refers to one image
  index, which has an image manifest per platform.
- `wasmComponents.<system>.<name>`: WebAssembly components. Each is a
  derivation whose output is a single component file.

Every output that holds derivations is keyed by the system that builds it,
like `packages`. The key says nothing about where the artifact runs. A
multi-platform image appears under each system that can assemble it.

The attribute name is the artifact's name. The flake carries no version,
destination or publishing policy. How an artifact is built is up to the
repository.

### Checks

`lib.outputChecks self system` returns a check for each artifact the flake
produces, to merge into `checks.<system>`:

- `package-<name>` builds a package. A package that is the same derivation as
  another, such as `default`, is not checked twice.
- `image-<name>` builds an image and checks the layout: its image index lists
  one image manifest per platform, and every blob is present with the size
  and digest that refer to it.
- `component-<name>` builds a component and checks that it is a valid
  WebAssembly component and not a core module.

The checks for a system cover the artifacts under that system. Outputs a flake
does not have produce no checks. The library depends only on nixpkgs.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ci = {
      url = "github:halo-org/ci";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, ci, ... }:
    {
      checks.x86_64-linux = ci.lib.outputChecks self "x86_64-linux" // {
        # Other checks.
      };
    };
}
```

### Schemas

The standard [flake schemas](https://manual.determinate.systems/protocols/flake-schemas.html)
in Determinate Nix already describe `ociImages`. `exportedSchemas.wasmComponents`
describes `wasmComponents` in the same way. A flake's `schemas` output replaces
the standard schemas rather than adding to them, so a flake that adds this
schema merges the two. Without it, Determinate Nix shows `wasmComponents` as an
unknown output.

```nix
{
  inputs.flake-schemas.url = "github:DeterminateSystems/flake-schemas";

  outputs =
    { flake-schemas, ci, ... }:
    {
      schemas = flake-schemas.exportedSchemas // ci.exportedSchemas;
    };
}
```

Nix without flake schemas ignores `schemas` and warns about outputs it does
not know.

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

The workflow does not manage the builder's store. Deciding what to keep and
what to garbage collect is up to the builder.

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
    secrets:
      builder-ssh-key: ${{ secrets.NIX_BUILDER_SSH_KEY }}
```

## Testing

On pull requests, this repository calls the workflow on its own flake. Its
checks come from `lib.outputChecks`. A trivial package for each supported
system covers the path without builders on both kinds of runner. A small image
and component cover their checks, and a core module must fail the component
check. Another job shows and checks the flake with Determinate Nix, using only
its exported schema.
