# Copies the OCI image layout $1 to $2 without the first layer of its first
# image.

set -euo pipefail

cp --recursive "$1" "$2"
chmod --recursive u+w "$2"
manifest=$(bash "$(dirname "$0")/first-manifest.sh" "$2")
rm "$2/blobs/$(jq --raw-output '.layers[0].digest | sub(":"; "/")' "$manifest")"
