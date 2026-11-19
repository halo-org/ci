# Writes the blobs of an image for one platform to the layout in $1, from the
# layers, configuration and platform in the structured attributes in $2. The
# layers are outputs of oci-layer.sh, from the bottom up. Writes the
# manifest's descriptor to manifests.json.

set -euo pipefail

out=$1 attributes=$2

mkdir -p "$out/blobs/sha256"

add() {
  local digest
  digest=$(sha256sum < "$1" | cut --delimiter " " --fields 1)
  cp "$1" "$out/blobs/sha256/$digest"
  jq --null-input --arg mediaType "$2" --arg digest "sha256:$digest" --argjson size "$(stat --format %s "$1")" \
    '{$mediaType, $digest, $size}'
}

for layer in $(jq --raw-output '.layers[]' "$attributes"); do
  blob=$out/blobs/$(jq --raw-output '.descriptor.digest | sub(":"; "/")' "$layer/layer.json")
  [[ -e $blob ]] || cp "$layer/blob" "$blob"
  cat "$layer/layer.json"
done > layers.json

jq --compact-output --slurp --slurpfile attributes "$attributes" '$attributes[0] as {$configuration, $platform} | {
  created: "1970-01-01T00:00:01Z",
  architecture: $platform.architecture,
  os: $platform.os,
  config: $configuration,
  rootfs: {type: "layers", diff_ids: map(.diffId)}
}' layers.json > config.json
config=$(add config.json application/vnd.oci.image.config.v1+json)

jq --compact-output --slurp --argjson config "$config" '{
  schemaVersion: 2,
  mediaType: "application/vnd.oci.image.manifest.v1+json",
  $config,
  layers: map(.descriptor)
}' layers.json > manifest.json
add manifest.json application/vnd.oci.image.manifest.v1+json |
  jq --compact-output --slurpfile attributes "$attributes" '.platform = $attributes[0].platform' > manifests.json
