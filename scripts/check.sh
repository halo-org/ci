#!/usr/bin/env bash
# Builds the checks that the flake in the current directory has for this
# runner's system, and keeps going when one fails. They build on the system's
# builder, or on this runner without one.

set -euo pipefail
source "$(dirname "$0")/builders.sh"

set_up_builders
nix flake check --no-build --all-systems

system=$(nix config show system)
store=$(builder_for "$system")
mapfile -t derivations < <(
  nix eval --raw .#. --apply "
    flake:
    builtins.concatStringsSep \"\n\" (
      map (check: check.drvPath) (builtins.attrValues (flake.checks.$system or { }))
    )
  "
)
if ((${#derivations[@]} == 0)); then
  echo "The flake has no checks for $system."
  exit 0
fi

if [[ -n $store ]]; then
  nix copy --to "$store" "${derivations[@]}"
fi
log=$(mktemp)
if ! nix build -L --no-link --keep-going ${store:+--store "$store"} "${derivations[@]/%/^*}" 2>&1 | tee "$log"; then
  # Nix reports every derivation it could not build.
  {
    echo "Failed to build:"
    grep --only-matching "Cannot build '[^']*'" "$log" | sort --unique |
      sed --regexp-extended "s|.*/[a-z0-9]{32}-(.*)\.drv'|- \`\1\`|"
  } >> "$GITHUB_STEP_SUMMARY" || true
  exit 1
fi
