#!/usr/bin/env bash
# Copies the derivations of the items on standard input to the builders that
# build them.

set -euo pipefail

items=$(cat)
for store in $(jq --raw-output '.[].store | select(. != "")' <<< "$items" | sort --unique); do
  jq --raw-output --arg store "$store" '.[] | select(.store == $store) | .drv' <<< "$items" |
    nix copy --stdin --to "$store"
done
