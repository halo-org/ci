#!/usr/bin/env bash
# Publishes one artifact of the flake in the current directory. It is built
# on the builder and copied here, or built here without one. $KIND, $DRV,
# $OUTPUT, $ATTRIBUTE and $REPOSITORY come from list-artifacts.sh, and $TAGS
# are the tags to publish it under.

set -euo pipefail
source "$(dirname "$0")/builders.sh"

set_up_builders
store=$(builder_for "$(nix config show system)")

if [[ -n $store ]]; then
  path=$(nix build -L --no-link --print-out-paths --store "$store" "$DRV^$OUTPUT")
  nix copy --no-check-sigs --from "$store" "$path"
else
  path=$(nix build -L --no-link --print-out-paths ".#$ATTRIBUTE^$OUTPUT")
fi

read -r -d "" -a tags <<< "$TAGS" || true
nix run "$(dirname "$0")/..#publish-oci-registry" -- "$KIND" "$path" "$REPOSITORY" "${tags[@]}"
