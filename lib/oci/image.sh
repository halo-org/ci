# Writes an OCI image layout to $1 with one image, for the operating system $2
# and architecture $3. $4 is its configuration as JSON, and the remaining
# arguments are its layers from the bottom up, as written by layer.sh.

set -euo pipefail
source "$(dirname "$0")/layout.sh"

out=$1 os=$2 architecture=$3 config=$4
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
