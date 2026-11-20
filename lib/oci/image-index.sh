# Writes an OCI image layout to $1 that holds the images of the layouts in
# the remaining arguments, one per platform.

set -euo pipefail
source "$(dirname "$0")/layout.sh"

out=$1
shift

mkdir -p "$out/blobs/sha256"
for image in "$@"; do
  index=$image/blobs/$(jq --raw-output '.manifests[0].digest | sub(":"; "/")' "$image/index.json")
  jq --compact-output '.manifests[]' "$index" >> manifests.json
  # Every blob but the image's own index, which the new one replaces.
  for blob in "$image"/blobs/*/*; do
    target=$out/blobs/${blob#"$image"/blobs/}
    if [[ $blob != "$index" && ! -e $target ]]; then
      mkdir -p "${target%/*}"
      cp "$blob" "$target"
    fi
  done
done
write_index "$out" manifests.json
