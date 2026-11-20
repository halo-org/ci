#!/usr/bin/env bash
# Builds the checks that the flake in the current directory has for this
# runner's system, and keeps going when one fails. They build on the system's
# builder, or on this runner without one.

set -euo pipefail
source "$(dirname "$0")/builders.sh"

set_up_builders

# Evaluating every output for every system can fail the job, but the build
# does not need it, so it runs alongside.
evaluation=$(mktemp)
nix flake check --no-build --all-systems &> "$evaluation" &
evaluating=$!

system=$(nix config show system)
store=$(builder_for "$system")
derivations=$(
  nix eval --raw .#. --apply "
    flake:
    builtins.concatStringsSep \"\n\" (
      map (check: check.drvPath) (builtins.attrValues (flake.checks.$system or { }))
    )
  "
)
mapfile -t derivations <<< "$derivations"

failed=0
if [[ -z ${derivations[0]} ]]; then
  echo "The flake has no checks for $system."
else
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
    failed=1
  fi
fi

echo "::group::Evaluate flake"
wait "$evaluating" || failed=1
cat "$evaluation"
echo "::endgroup::"
if grep --quiet "^error" "$evaluation"; then
  echo "::error::The flake does not evaluate. See the Evaluate flake group."
fi
exit "$failed"
