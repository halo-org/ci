# Writes an image layer to $1. It holds the store paths listed in the file $2
# that are not listed in the file $3 and are not among the remaining
# arguments. $1/blob is the layer, a gzip-compressed tar archive, and
# $1/layer.json has its descriptor and diff ID.
#
# The archive is the same however the store lays out its files: entries are
# sorted, hard links are stored as files, and times, owners and modes are
# normalised.

set -euo pipefail
export LC_ALL=C

out=$1 include=$2 exclude=$3
shift 3

comm -23 <(sort "$include") <(sort "$exclude" <(printf '%s\n' "$@")) | sed 's|^/||' > paths
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
