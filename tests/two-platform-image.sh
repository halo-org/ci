# Writes an OCI image layout to $1 with the same small image for two
# platforms, using the functions in the file $2.

set -euo pipefail
# shellcheck source=lib/oci/layout.sh
source "$2"

out=$1

echo hello > hello
tar --create --file layer.tar --sort name --mtime @0 --owner 0 --group 0 --numeric-owner hello
layer=$(add_blob "$out" layer.tar application/vnd.oci.image.layer.v1.tar)

for architecture in amd64 arm64; do
  jq --null-input --arg architecture "$architecture" --argjson layer "$layer" \
    '{$architecture, os: "linux", rootfs: {type: "layers", diff_ids: [$layer.digest]}}' > config.json
  jq --null-input --argjson layer "$layer" \
    --argjson config "$(add_blob "$out" config.json application/vnd.oci.image.config.v1+json)" \
    '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", $config, layers: [$layer]}' > manifest.json
  add_blob "$out" manifest.json application/vnd.oci.image.manifest.v1+json |
    jq --compact-output --arg architecture "$architecture" '.platform = {$architecture, os: "linux"}' >> manifests.json
done
write_index "$out" manifests.json
