# Pushes an OCI image layout or a WebAssembly component to a repository in an
# OCI registry under each tag.

if (($# < 4)) || [[ $1 != oci-image && $1 != wasm-component ]]; then
  echo "usage: publish-oci-registry oci-image|wasm-component <path> <repository> <tag>..." >&2
  exit 2
fi

kind=$1 path=$2 repository=$3
shift 3

if [[ -n ${REGISTRY_USERNAME:-} ]]; then
  DOCKER_CONFIG=$(mktemp --directory)
  export DOCKER_CONFIG REGISTRY_AUTH_FILE=$DOCKER_CONFIG/config.json
  trap 'rm -rf "$DOCKER_CONFIG"' EXIT
  skopeo login --username "$REGISTRY_USERNAME" --password-stdin "${repository%%/*}" <<< "${REGISTRY_PASSWORD:-}"
fi

case $kind in
  oci-image)
    skopeo --insecure-policy copy --all --preserve-digests "oci:$path" "docker://$repository:$1"
    digest=$(jq --raw-output '.manifests[0].digest' "$path/index.json")
    ;;
  wasm-component)
    digest=$(wkg oci push "$repository:$1" "$path" | sed --quiet 's/^digest: //p')
    if [[ -z $digest ]]; then
      echo "wkg did not report the digest it pushed" >&2
      exit 1
    fi
    ;;
esac

for tag in "${@:2}"; do
  skopeo --insecure-policy copy --all --preserve-digests "docker://$repository@$digest" "docker://$repository:$tag"
done

for tag in "$@"; do
  echo "$repository:$tag@$digest"
done
