#!/usr/bin/env bash
# Prints the checks or the artifacts of the flake in the current directory as
# JSON, each with the store of the builder in $BUILDERS that builds it.
#
# usage: instantiate.sh checks|artifacts

set -euo pipefail

scripts=$(dirname "$0")

nix eval --json .#. --apply "$(< "$scripts/$1.nix")" |
  jq --compact-output --arg builders "${BUILDERS:-}" --from-file "$scripts/assign-builders.jq"
