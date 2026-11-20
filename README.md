# CI for Nix flakes

Two reusable GitHub Actions workflows for a repository with a Nix flake. One
builds the flake's checks. The other publishes its OCI images and WebAssembly
components to an OCI registry. The flake is the source of truth, so there is
nothing to configure per repository.

```yaml
name: CI

on: push

jobs:
  check:
    uses: halo-org/ci/.github/workflows/ci.yml@main

  publish:
    needs: check
    if: github.ref == 'refs/heads/main'
    permissions:
      contents: read
      packages: write
    uses: halo-org/ci/.github/workflows/publish-oci-registry.yml@main
    with:
      to: ghcr.io/${{ github.repository_owner }}/{name}
      tags: ${{ github.sha }}
      username: ${{ github.actor }}
    secrets:
      password: ${{ secrets.GITHUB_TOKEN }}
```

The workflows read no variables or secrets of their own. Everything they use
is passed by the caller.

## Checking

`ci.yml` builds every attribute of `checks.<system>` and keeps going when one
fails. The run's summary lists the derivations that failed to build. Alongside
the build it runs `nix flake check --no-build --all-systems`, so an evaluation
error in any output for any system also fails the run.

- `systems`: the systems to build checks for, as a JSON list. The default is
  `["x86_64-linux"]`. `aarch64-linux` is the other system supported. Each
  system has its own job, on a GitHub-hosted runner of that system.
- `builders` and the `builder-ssh-key` secret: see [Builders](#builders).

## Builders

Without builders, everything builds on the GitHub-hosted runner, with
dependencies from the substituters the flake already uses.

`builders` is a list of remote builders in Nix's machines format, one per
line, as in the `builders` setting of `nix.conf`:

```
ssh-ng://ci@builder.example.com x86_64-linux - 16 1 - - c3NoLWVkMjU1MTkgQUFBQUMzTnph...
```

Three fields are used: the store URI, the systems, and the public host key,
base64 encoded as Nix defines it. Without a host key SSH refuses to connect.
The `builder-ssh-key` secret is the private key for every builder.

A system with a builder builds there, with `nix build --store <uri>`. The
outputs stay in the builder's store and nothing is copied back to the runner,
which is not what Nix's own distributed builds do. The builder's SSH user does
not need to be a trusted Nix user. What the builder keeps and what it garbage
collects is up to the builder.

## Artifacts

A flake says what it produces with these outputs:

- `packages.<system>.<name>`: packages, as in any flake.
- `ociImages.<system>.<name>`: OCI images. Each is a derivation whose output
  is an OCI image layout that holds one image, for one or more platforms.
- `wasmComponents.<system>.<name>`: WebAssembly components. Each is a
  derivation whose output is a single component file.

Like `packages`, they are keyed by the system that builds them. The key says
nothing about where an artifact runs. The attribute name is the artifact's
name. The flake carries no version, destination or publishing policy.

`lib.outputChecks self system` returns a check for each of them, so that
`nix flake check` and the checking workflow cover everything a flake produces:

```nix
checks.${system} = ci.lib.outputChecks self system // {
  # the flake's other checks
};
```

- `package-<name>` builds a package. `default` is left out when it is another
  package under a second name.
- `oci-image-<name>` builds an image and checks that skopeo can read the
  layout as one image.
- `wasm-component-<name>` builds a component and checks that it is a valid
  WebAssembly component and not a core module.

## Images

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

The image holds the closure of the store paths that `entrypoint`, `env` and
`layers` refer to, at their paths in `/nix/store`, and nothing else. There is
no shell and no `/etc` or `/tmp`. The image is for the platform of `system`,
which also builds it.

Each package in `layers` gets a layer that holds its closure, except what
lower layers hold. A last layer holds the rest. Each layer is its own
derivation, so when only the application changes, only the last layer is built
again and a registry that has the others does not receive them again. Give the
parts of the closure that rarely change their own layers, such as libc,
certificates or a language runtime.

The same derivation always builds the same image. Layers are gzip-compressed
tar archives with sorted entries and fixed times, owners and modes. The image
uses OCI media types and refers to no other store paths, so copying it copies
only the image.

`lib.ociImageIndex system { name, images }` combines images for different
platforms into one. Each image is built on its own system, so building the
result needs a builder for each. Two images for the same platform fail the
build.

```nix
ociImages.x86_64-linux.app = ci.lib.ociImageIndex "x86_64-linux" {
  name = "app";
  images = map image [ "x86_64-linux" "aarch64-linux" ];
};
```

## Publishing

`publish-oci-registry.yml` publishes every entry of `ociImages.x86_64-linux`
and `wasmComponents.x86_64-linux`, each in its own job named after the
artifact. A flake with neither publishes nothing. When to publish, where, and
with which tags and credentials are the caller's: the workflow has no triggers
or defaults of its own.

- `to`: the repository to publish to, with `{name}` replaced by the artifact's
  name, such as `ghcr.io/octo-org/{name}`. Two artifacts that would go to the
  same repository fail the run.
- `tags`: one or more tags, separated by whitespace. Every artifact is
  published under each, and all tags of an artifact refer to one digest.
- `username` and the `password` secret: the registry login. Optional.
- `builders` and the `builder-ssh-key` secret: see [Builders](#builders). An
  artifact is built on the builder and copied to the runner, which pushes it.
  The registry login never reaches the builder.

An image is copied as it is, with its digests. A component is pushed as an
OCI artifact in the format that `wkg oci push` writes.

The publishing jobs have the permissions of the calling job, so a caller that
publishes to ghcr.io grants `packages: write`.

The program the workflow runs can also publish an artifact that is already
built:

```sh
nix build .#ociImages.x86_64-linux.app
nix run github:halo-org/ci#publish-oci-registry -- oci-image ./result ghcr.io/octo-org/app 1.0 latest
```

The first argument is `oci-image` or `wasm-component`. With
`REGISTRY_USERNAME` and `REGISTRY_PASSWORD` set, it logs in with them.
Otherwise it uses the logins that `docker login` saved.

## This repository

- `.github/workflows` has the two workflows, and one that tests this
  repository on pull requests.
- `scripts` has what the workflows' jobs run: one script for each job, and
  what they share.
- `lib` is the flake's library: `default.nix`, and the shell that writes
  image layouts.
- `tests` has this repository's checks. Nothing in it is part of what the
  flake offers.

`nix flake check` runs the tests. They cover what the generated checks accept
and reject, what an image holds and refers to, and combining images. One
starts a registry that requires a login, publishes two images and a component
to it under two tags, and checks that the same artifacts come back.

A pull request runs the checking workflow on this flake for both systems,
without builders. The publishing workflow is not run on pull requests, because
its jobs need a registry they can reach.
