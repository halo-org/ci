#!/usr/bin/env bash
# Sets the step outputs for the checks of the flake in the current directory.
# "checks" lists the ones this job builds: those with a builder in $BUILDERS,
# and those for this runner's system, $SYSTEM. "aarch64" says whether any are
# left for a runner of the other system.

set -euo pipefail

checks=$("$(dirname "$0")/instantiate.sh" checks)
{
  echo "checks=$(jq --compact-output --arg system "$SYSTEM" 'map(select(.store != "" or .system == $system))' <<< "$checks")"
  echo "aarch64=$(jq --arg system "$SYSTEM" 'any(.[]; .store == "" and .system != $system)' <<< "$checks")"
} >> "$GITHUB_OUTPUT"
