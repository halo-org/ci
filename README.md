# CI for Nix flakes

A reusable GitHub Actions workflow that builds every check in a flake. The
flake is the source of truth. There is nothing to configure per repository.
A second workflow [publishes](#publishing) the flake's images and components
to an OCI registry.

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
- `oci-image-<name>` builds an image and checks the layout: its image index
  lists one image manifest per platform, and every blob is present with the
  size and digest that refer to it.
- `wasm-component-<name>` builds a component and checks that it is a valid
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

### Images

`lib.ociImage system { ... }` builds an image for an `ociImages` entry. It
needs only nixpkgs: there is no Docker, daemon or base image.

```nix
ociImages.x86_64-linux.app = ci.lib.ociImage "x86_64-linux" {
  name = "app";
  entrypoint = [ (lib.getExe app) ];
  env.SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  layers = [ pkgs.glibc pkgs.cacert ];
};
```

- `name`: the name of the derivation.
- `entrypoint`: the command the image runs, as a list of strings.
- `env`: environment variables. Optional.
- `layers`: packages that get layers of their own, from the bottom up.
  Optional.

The image holds the closure of the store paths that `entrypoint` and `env`
refer to, at their paths in `/nix/store`, and nothing else. There is no shell
and no `/etc` or `/tmp`. The image is for the platform of `system`, which also
builds it.

Each package in `layers` gets a layer that holds its closure, except what lower
layers hold. A last layer holds the rest of the image. Each layer is its own
derivation and depends only on its packages and those below it. When only the
application changes, only the last layer is built again and the other layers
keep their digests, so a registry that has them does not receive them again.
Give the parts of the closure that rarely change their own layers, such as
libc, certificates or a language runtime. A package that is not in the image's
closure fails the build.

The same derivation always builds the same image. Layers are tar archives with
sorted entries, hard links stored as files, and fixed times, owners and modes.
They are compressed with gzip, without a name or time in the header. The
image's creation time is `1970-01-01T00:00:01Z`, and it uses OCI media types.
Every image holds a copy of its layers and refers to no other store paths, so
copying it copies only the image.

`lib.ociImageIndex system { name, images }` combines images for different
platforms into one image, built on `system`. Each image is an OCI image layout
like those `lib.ociImage` builds and is built on its own system, so building
the result needs a builder for each.

```nix
let
  image = system: ci.lib.ociImage system {
    name = "app";
    entrypoint = [ (lib.getExe self.packages.${system}.app) ];
  };
in
{
  ociImages.x86_64-linux.app = ci.lib.ociImageIndex "x86_64-linux" {
    name = "app";
    images = [ (image "x86_64-linux") (image "aarch64-linux") ];
  };
}
```

The result's image index lists the manifests of every image. Two images for
the same platform fail the build. An index of a single image that
`lib.ociImage` built is the same image.

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

## Publishing

`publish-oci-registry.yml` pushes every image and component the flake
declares to an OCI registry. It provides the mechanism only. When to publish,
where to, under which tags and with which credentials are up to the caller.

```yaml
name: CI

on: push

jobs:
  check:
    uses: halo-org/ci/.github/workflows/ci.yml@main

  publish:
    if: github.ref == 'refs/heads/main'
    needs: check
    permissions:
      contents: read
      packages: write
    uses: halo-org/ci/.github/workflows/publish-oci-registry.yml@main
    with:
      to: ghcr.io/${{ github.repository_owner }}/{name}
      tags: ${{ github.sha }} latest
      username: ${{ github.actor }}
    secrets:
      password: ${{ secrets.GITHUB_TOKEN }}
```

### What it publishes

The workflow checks out the calling repository and lists every attribute of
`ociImages.<system>` and `wasmComponents.<system>` for `x86_64-linux` and
`aarch64-linux`, the systems that `ci.yml` builds. An artifact under both
systems is published once, from `x86_64-linux`. Each artifact is built and
pushed in its own job, named after the artifact. A flake with neither output
publishes nothing and the run succeeds. There is no way to select artifacts:
what the flake declares is what gets published.

- An image is copied as it is with skopeo. The image index, the manifest for
  each platform and every blob keep their digests.
- A component is pushed with `wkg oci push`, as an OCI artifact with an
  `application/vnd.wasm.config.v0+json` config and a single `application/wasm`
  layer that holds the component unchanged. wkg records the time of the push
  in the config, so the manifest digest changes every time a component is
  published.

An artifact is pushed under the first tag and then tagged with the others, so
every tag refers to the same digest. Pushing an existing tag moves it. If two
artifacts would be pushed to the same repository, evaluation fails and nothing
is published.

The pushing tools come from this repository's flake, at the commit of the
workflow the caller uses, so the calling flake needs none.

With builders, an artifact is built in the builder's store, or found there if
`ci.yml` already built it, and copied to the runner, which pushes it. The
registry credentials stay on the runner and never reach a builder. Without
builders, each job checks out the repository and builds its artifact on a
GitHub-hosted runner of its system.

### Inputs

- `to`: the destination repository, including the registry host, with
  `{name}` replaced by the artifact's attribute name. Required.
- `tags`: one or more tags, separated by whitespace. Every artifact is pushed
  under each. Required.
- `username`: the registry username. Empty means no login, which suits a
  registry that accepts anonymous pushes.
- `builders`: remote builders, exactly as for [`ci.yml`](#builders).

### Secrets

- `password`: the registry password or token, used with `username`.
- `builder-ssh-key`: the SSH private key for every builder, exactly as for
  [`ci.yml`](#builder-ssh-key).

Like `ci.yml`, the workflow reads no variables or secrets of its own. Its
publishing jobs keep the permissions of the calling job, so a caller that
passes `secrets.GITHUB_TOKEN` to push to GitHub Packages grants
`packages: write`.

### By hand

The program the workflow runs pushes one artifact that is already built:

```sh
nix build .#ociImages.x86_64-linux.app
nix run github:halo-org/ci#publish-oci-registry -- oci-image ./result ghcr.io/octo-org/app 1.0 latest
```

The first argument is `oci-image` or `wasm-component`. With
`REGISTRY_USERNAME` and `REGISTRY_PASSWORD` set, it logs in to the registry
with them. Otherwise skopeo and wkg use the logins that `docker login` saved.
It prints each reference it pushed with its digest.

## Testing

On pull requests, this repository calls the workflow on its own flake. Its
checks come from `lib.outputChecks`. A trivial package for each supported
system covers the path without builders on both kinds of runner. An image built
with `lib.ociImage`, an image for two platforms built by hand and a component
cover their checks, and a core module must fail the component check. The image
built with `lib.ociImage` must hold exactly its closure, an index of it alone
must be the same image, and an index of it twice must fail. An image of a tool
the builder uses itself, and an index of it, must have no references in the Nix
store. Another job shows and checks the flake with Determinate Nix, using only
its exported schema.

The `publish-oci-registry-pushes-artifacts` check starts a registry that
requires a login inside the Nix build. It publishes both images and the
component under two tags with the program the publishing workflow runs, then
pulls them back. Each image must come back with the same image index digest
and every blob of the built layout, the component must match byte for byte,
and both tags must refer to the same manifest. The publishing workflow itself
is not run on pull requests, because its jobs cannot reach a registry without
credentials for a real one. Its evaluation, the jobs it starts and the way
they fetch from builders are only tested by calling it.
