# Checks that a file is a valid WebAssembly component and not a core module.

set -euo pipefail

wasm-tools validate --features all "$1"
wasm-tools print --skeleton "$1" --output skeleton.wat
if [[ $(head --bytes 10 skeleton.wat) != "(component" ]]; then
  echo "$1 is a core WebAssembly module, not a component" >&2
  exit 1
fi
