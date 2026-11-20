#!/usr/bin/env bash
# Builds one artifact and sets the step output "path" to it on this runner.
# With a builder in $STORE, the derivation $DRV is built there and its output
# $OUTPUT copied here. Without one, the flake attribute $ATTRIBUTE is built
# here.

set -euo pipefail

if [[ -n $STORE ]]; then
  path=$(nix build -L --no-link --print-out-paths --store "$STORE" "$DRV^$OUTPUT")
  nix copy --no-check-sigs --from "$STORE" "$path"
else
  path=$(nix build -L --no-link --print-out-paths ".#$ATTRIBUTE^$OUTPUT")
fi
echo "path=$path" >> "$GITHUB_OUTPUT"
