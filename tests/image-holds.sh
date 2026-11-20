# Checks that the layers of the first image in the OCI image layout $1 hold
# exactly the store paths listed in the file $2.

set -euo pipefail

manifest=$(bash "$(dirname "$0")/first-manifest.sh" "$1")
for layer in $(jq --raw-output '.layers[].digest | sub(":"; "/")' "$manifest"); do
  tar --list --file "$1/blobs/$layer"
done | sed --quiet 's|^nix/store/\([^/]\+\)/\?$|/nix/store/\1|p' | sort > paths
sort "$2" | diff - paths
