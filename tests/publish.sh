# Publishes the OCI image layouts $1 and $2 and the WebAssembly component $3
# to a registry that requires a login, under two tags, and checks that the
# same artifacts come back.

set -euo pipefail

image=$1 two_platforms=$2 component=$3
registry=127.0.0.1:5000

export HOME=$PWD
htpasswd -Bbn user password > htpasswd
cat > registry.yml << EOF
version: 0.1
storage:
  filesystem:
    rootdirectory: $PWD/registry
http:
  addr: $registry
auth:
  htpasswd:
    realm: test
    path: $PWD/htpasswd
EOF
registry serve registry.yml &> registry.log &
trap 'kill %1' EXIT
curl --silent --retry 30 --retry-connrefused --retry-delay 1 --output /dev/null "http://$registry/v2/"

cat > registries.conf << EOF
[[registry]]
location = "$registry"
insecure = true
EOF
export CONTAINERS_REGISTRIES_CONF=$PWD/registries.conf WKG_OCI_INSECURE=$registry

export REGISTRY_USERNAME=user REGISTRY_PASSWORD=password
publish-oci-registry oci-image "$image" "$registry/image" one two
publish-oci-registry oci-image "$two_platforms" "$registry/two-platforms" one two
publish-oci-registry wasm-component "$component" "$registry/component" one two

export DOCKER_CONFIG=$PWD/docker REGISTRY_AUTH_FILE=$PWD/docker/config.json
skopeo login --username user --password-stdin "$registry" <<< password
for tag in one two; do
  for published in "image=$image" "two-platforms=$two_platforms"; do
    repository=${published%%=*} layout=${published#*=}
    skopeo --insecure-policy copy --all --preserve-digests "docker://$registry/$repository:$tag" "oci:$repository-$tag"
    diff --recursive "$layout/blobs" "$repository-$tag/blobs"
    [[ $(jq '.manifests[0].digest' "$layout/index.json") == $(jq '.manifests[0].digest' "$repository-$tag/index.json") ]]
  done
  wkg oci pull "$registry/component:$tag" --output "component-$tag.wasm"
  cmp "$component" "component-$tag.wasm"
  skopeo inspect --raw "docker://$registry/component:$tag" > "component-$tag.json"
done
# Both tags of the component are the same manifest.
cmp component-one.json component-two.json
