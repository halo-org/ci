# Checks that a directory is an OCI image layout for one image index with an
# image manifest per platform, and that every blob it refers to is intact.

set -euo pipefail

layout=$1

fail() {
  echo "$layout: $1" >&2
  exit 1
}

blob() {
  local algorithm=${1%%:*} encoded=${1#*:}
  [[ $algorithm == sha256 || $algorithm == sha512 ]] || fail "$1 uses an unsupported digest algorithm"
  echo "$layout/blobs/$algorithm/$encoded"
}

verify() {
  local digest size path
  while read -r digest size; do
    path=$(blob "$digest")
    [[ -f $path ]] || fail "blob $digest is missing"
    [[ $(stat --format %s "$path") == "$size" ]] || fail "blob $digest is not $size bytes"
    [[ $("${digest%%:*}sum" < "$path") == "${digest#*:}  -" ]] || fail "blob $digest does not match its digest"
  done
}

jq --exit-status '.imageLayoutVersion == "1.0.0"' "$layout/oci-layout" > /dev/null ||
  fail "oci-layout does not declare imageLayoutVersion 1.0.0"

jq --exit-status '
  .schemaVersion == 2
  and (.manifests | type == "array" and length == 1)
  and .manifests[0].mediaType == "application/vnd.oci.image.index.v1+json"
' "$layout/index.json" > /dev/null ||
  fail "index.json does not refer to exactly one image index"
jq --raw-output '.manifests[] | "\(.digest) \(.size)"' "$layout/index.json" | verify

index=$(blob "$(jq --raw-output '.manifests[0].digest' "$layout/index.json")")
jq --exit-status '
  .schemaVersion == 2
  and (.manifests | type == "array" and length > 0)
  and all(.manifests[];
    .mediaType == "application/vnd.oci.image.manifest.v1+json"
    and (.platform.os | type == "string")
    and (.platform.architecture | type == "string"))
  and ([.manifests[].platform] | length == (unique | length))
' "$index" > /dev/null ||
  fail "the image index does not list one image manifest per platform"
jq --raw-output '.manifests[] | "\(.digest) \(.size)"' "$index" | verify

jq --raw-output '.manifests[].digest' "$index" | while read -r digest; do
  manifest=$(blob "$digest")
  jq --exit-status '.schemaVersion == 2 and (.config | type == "object") and (.layers | type == "array")' "$manifest" > /dev/null ||
    fail "manifest $digest is not an image manifest"
  jq --raw-output '.config, .layers[] | "\(.digest) \(.size)"' "$manifest" | verify
done
