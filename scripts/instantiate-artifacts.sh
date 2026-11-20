#!/usr/bin/env bash
# Sets the step output "artifacts" to the artifacts of the flake in the
# current directory, each with the repository it is published to and the
# runner that publishes it. $TO is the repository, with {name} for the
# artifact's name.

set -euo pipefail

artifacts=$(
  "$(dirname "$0")/instantiate.sh" artifacts | jq --compact-output --arg to "$TO" '
    map(
      .name as $name
      | .repository = ($to | gsub("\\{name\\}"; $name))
      | .runner = if .store == "" and .system == "aarch64-linux" then "ubuntu-24.04-arm" else "ubuntu-latest" end
    )
    | (group_by(.repository) | map(select(length > 1)[0].repository)) as $shared
    | if $shared != [] then error("more than one artifact would be pushed to \($shared | join(", "))") else . end
  '
)
echo "artifacts=$artifacts" >> "$GITHUB_OUTPUT"
