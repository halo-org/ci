# Completes the OCI image layout in $1 with an image index that lists the
# manifests whose descriptors are in $2.

set -euo pipefail

out=$1

jq --compact-output --slurp '
  (map(.platform) | group_by(.) | map(select(length > 1)[0] | "\(.os)/\(.architecture)")) as $shared
  | if $shared != [] then error("more than one image for \($shared | join(", "))") else . end
  | {schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", manifests: .}
' "$2" > image-index.json
digest=$(sha256sum < image-index.json | cut --delimiter " " --fields 1)
cp image-index.json "$out/blobs/sha256/$digest"
jq --null-input --compact-output --arg digest "sha256:$digest" --argjson size "$(stat --format %s image-index.json)" '{
  schemaVersion: 2,
  mediaType: "application/vnd.oci.image.index.v1+json",
  manifests: [{mediaType: "application/vnd.oci.image.index.v1+json", $digest, $size}]
}' > "$out/index.json"
echo '{"imageLayoutVersion": "1.0.0"}' > "$out/oci-layout"
