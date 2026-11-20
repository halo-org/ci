# Prints the path of the first image manifest in the OCI image layout $1.

set -euo pipefail

index=$(jq --raw-output '.manifests[0].digest | sub(":"; "/")' "$1/index.json")
echo "$1/blobs/$(jq --raw-output '.manifests[0].digest | sub(":"; "/")' "$1/blobs/$index")"
