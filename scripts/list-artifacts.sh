#!/usr/bin/env bash
# Sets the step output "artifacts" to the artifacts of the flake in the
# current directory, each with the repository to publish it to. $TO is that
# repository, with {name} for the artifact's name. With a builder, the
# artifacts' derivations are copied to it.

set -euo pipefail
source "$(dirname "$0")/builders.sh"

set_up_builders
system=$(nix config show system)

artifacts=$(
  nix eval --json .#. --apply "($(< "$(dirname "$0")/artifacts.nix")) \"$system\"" |
    jq --compact-output --arg to "$TO" '
      map(.name as $name | .repository = ($to | gsub("\\{name\\}"; $name)))
      | (group_by(.repository) | map(select(length > 1)[0].repository)) as $shared
      | if $shared != [] then error("more than one artifact would be published to \($shared | join(", "))") else . end
    '
)

store=$(builder_for "$system")
if [[ -n $store && $artifacts != '[]' ]]; then
  jq --raw-output '.[].drv' <<< "$artifacts" | nix copy --stdin --to "$store"
fi
echo "artifacts=$artifacts" >> "$GITHUB_OUTPUT"
