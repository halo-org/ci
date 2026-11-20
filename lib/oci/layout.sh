# Functions for writing an OCI image layout. Source this file.

# Copies a file into a layout as a blob and prints its descriptor.
add_blob() {
  local layout=$1 file=$2 media_type=$3 digest
  digest=$(sha256sum < "$file" | cut --delimiter " " --fields 1)
  mkdir -p "$layout/blobs/sha256"
  [[ -e $layout/blobs/sha256/$digest ]] || cp "$file" "$layout/blobs/sha256/$digest"
  jq --null-input --compact-output --arg mediaType "$media_type" --arg digest "sha256:$digest" \
    --argjson size "$(stat --format %s "$file")" '{$mediaType, $digest, $size}'
}

# Completes a layout with an image index that lists the image manifests whose
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
