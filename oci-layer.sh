# Writes an image layer that holds the store paths listed on standard input.
# The layer is a gzip-compressed tar archive in $1/blob, and $1/layer.json
# holds its descriptor and diff ID. The archive is the same however the store
# lays out its files: entries are sorted, hard links are stored as files, and
# times, owners and modes are normalised.

set -euo pipefail

out=$1

sed 's|^/||' | LC_ALL=C sort > paths
mkdir -p root/nix/store
tar --create --file layer.tar \
  --format posix --pax-option exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
  --sort name --mtime @1 --owner 0 --group 0 --numeric-owner --mode a=rX --hard-dereference \
  --directory root --no-recursion nix nix/store --directory / --recursion --files-from paths
mkdir "$out"
gzip --no-name < layer.tar > "$out/blob"

jq --null-input \
  --arg digest "sha256:$(sha256sum < "$out/blob" | cut --delimiter " " --fields 1)" \
  --argjson size "$(stat --format %s "$out/blob")" \
  --arg diffId "sha256:$(sha256sum < layer.tar | cut --delimiter " " --fields 1)" \
  '{descriptor: {mediaType: "application/vnd.oci.image.layer.v1.tar+gzip", $digest, $size}, $diffId}' > "$out/layer.json"
