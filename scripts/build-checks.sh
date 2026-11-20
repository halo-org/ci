#!/usr/bin/env bash
# Builds the checks on standard input, each in its store, and keeps going
# when one fails. The run summary gets a table of results and the end of each
# failed check's log. This step's log gets each failed check's whole log in a
# group. Fails if any check did.

set -uo pipefail

checks=$(cat)
if [[ $checks == '[]' ]]; then
  echo "No checks to build."
  exit 0
fi

log=$(mktemp)
missing=$(mktemp)
mapfile -t stores < <(jq --raw-output '[.[].store] | unique | .[]' <<< "$checks")

# Prints a field of every check that builds in a store.
in_store() {
  jq --raw-output --arg store "$1" ".[] | select(.store == \$store) | $2" <<< "$checks"
}

build() {
  local derivations
  mapfile -t derivations < <(in_store "$1" '"\(.drv)^*"')
  nix build -L --no-link --keep-going ${1:+--store "$1"} "${derivations[@]}"
}

# Prints what a check logged. Nix starts each line with the name of the
# derivation without its version.
log_of() {
  local prefix
  prefix=$(basename "$1" .drv | sed --regexp-extended 's/^[^-]*-//; s/-[0-9].*$//')
  awk -v prefix="$prefix> " 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }' "$log"
}

{
  for store in "${stores[@]}"; do
    build "$store" &
  done
  wait
} 2>&1 | tee "$log"

# A check passed if every output it has is in its store afterwards.
for store in "${stores[@]}"; do
  if ! in_store "$store" '.outputs[]' |
    xargs nix-store ${store:+--store "$store"} --check-validity --print-invalid >> "$missing"; then
    echo "::error::Could not tell which checks were built"
    exit 1
  fi
done

systems=$(jq '[.[].system] | unique | length' <<< "$checks")
failed=0
details=
printf '| Check | Result |\n| --- | --- |\n' >> "$GITHUB_STEP_SUMMARY"

while IFS=$'\t' read -r name system drv passed; do
  if ((systems > 1)); then
    name="$name ($system)"
  fi
  if [[ $passed == true ]]; then
    echo "| $name | ✅ |" >> "$GITHUB_STEP_SUMMARY"
    continue
  fi
  failed=1
  echo "| $name | ❌ |" >> "$GITHUB_STEP_SUMMARY"
  echo "::error title=$name::Check failed"

  lines=$(log_of "$drv")
  if [[ -z $lines ]]; then
    lines="No log from this check. It failed without output, or something it depends on failed to build."
  fi
  printf '::group::%s\n%s\n::endgroup::\n' "$name" "$lines"
  details+=$(printf '\n<details><summary>%s</summary>\n\n````text\n%s\n````\n\n</details>' "$name" "$(tail --lines 50 <<< "$lines")")$'\n'
done < <(
  jq --raw-output --rawfile missing "$missing" '
    ($missing | split("\n")) as $missing
    | .[] | [.name, .system, .drv, (.outputs - $missing == .outputs)] | @tsv
  ' <<< "$checks"
)

echo "$details" >> "$GITHUB_STEP_SUMMARY"
exit "$failed"
