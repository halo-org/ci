# Writes the parts of an OCI image layout. An image layout has one image
# index, which lists an image manifest per platform.
#
# usage: oci.sh layer <out> <paths> <paths-below> [<omitted-path>...]
#        oci.sh image <out> <os> <architecture> <config> <layer>...
#        oci.sh index <out> <image>...

set -euo pipefail
export LC_ALL=C

# Copies a file into a layout as a blob and prints its descriptor.
add_blob() {
  local layout=$1 file=$2 media_type=$3 digest
  digest=$(sha256sum < "$file" | cut --delimiter " " --fields 1)
  mkdir -p "$layout/blobs/sha256"
  [[ -e $layout/blobs/sha256/$digest ]] || cp "$file" "$layout/blobs/sha256/$digest"
  jq --null-input --compact-output --arg mediaType "$media_type" --arg digest "sha256:$digest" \
    --argjson size "$(stat --format %s "$file")" '{$mediaType, $digest, $size}'
}

# Completes a layout with an image index for the image manifests whose
# descriptors are in a file, each with its platform.
write_index() {
  local layout=$1 manifests=$2 index
  jq --compact-output --slurp '
    (map(.platform) | group_by(.) | map(select(length > 1)[0] | "\(.os)/\(.architecture)")) as $shared
    | if $shared != [] then error("more than one image for \($shared | join(", "))") else . end
    | {schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", manifests: .}
  ' "$manifests" > image-index.json
  index=$(add_blob "$layout" image-index.json application/vnd.oci.image.index.v1+json)
  jq --null-input --compact-output --argjson index "$index" \
    '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", manifests: [$index]}' > "$layout/index.json"
  echo '{"imageLayoutVersion": "1.0.0"}' > "$layout/oci-layout"
}

# A layer holds the store paths listed in one file that are not listed in
# another and are not omitted. Its output has the layer as blob, a
# gzip-compressed tar archive, and its descriptor and diff ID in layer.json.
#
# The archive is the same however the store lays out its files: entries are
# sorted, hard links are stored as files, and times, owners and modes are
# normalised.
layer() {
  local out=$1 paths=$2 below=$3
  shift 3

  comm -23 <(sort "$paths") <(sort "$below" <(printf '%s\n' "$@")) | sed 's|^/||' > paths
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
}

# An image for one platform, from its configuration as JSON and its layers
# from the bottom up.
image() {
  local out=$1 os=$2 architecture=$3 config=$4 layer blob
  shift 4

  mkdir -p "$out/blobs/sha256"
  for layer in "$@"; do
    blob=$out/blobs/$(jq --raw-output '.descriptor.digest | sub(":"; "/")' "$layer/layer.json")
    [[ -e $blob ]] || cp "$layer/blob" "$blob"
    cat "$layer/layer.json"
  done > layers.json

  jq --compact-output --slurp --arg os "$os" --arg architecture "$architecture" --slurpfile config "$config" '{
    created: "1970-01-01T00:00:01Z",
    $architecture,
    $os,
    config: $config[0],
    rootfs: {type: "layers", diff_ids: map(.diffId)}
  }' layers.json > config.json

  jq --compact-output --slurp \
    --argjson config "$(add_blob "$out" config.json application/vnd.oci.image.config.v1+json)" \
    '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", $config, layers: map(.descriptor)}' \
    layers.json > manifest.json

  add_blob "$out" manifest.json application/vnd.oci.image.manifest.v1+json |
    jq --compact-output --arg os "$os" --arg architecture "$architecture" '.platform = {$architecture, $os}' > manifests.json
  write_index "$out" manifests.json
}

# The images of several layouts in one, each for its own platform.
index() {
  local out=$1 image index blob target
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
}

"$@"
