nixpkgs: system:
{ name, images }:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
in
pkgs.runCommand name {
  __structuredAttrs = true;
  unsafeDiscardReferences.out = true;
  nativeBuildInputs = [ pkgs.jq ];
} ''
  out=''${outputs[out]}
  mkdir -p $out/blobs/sha256
  for image in ${lib.escapeShellArgs images}; do
    index=$image/blobs/$(jq --raw-output '.manifests[0].digest | sub(":"; "/")' $image/index.json)
    jq --compact-output '.manifests[]' $index >> manifests.json
    for blob in $image/blobs/*/*; do
      target=$out/blobs/''${blob#$image/blobs/}
      if [[ $blob != "$index" && ! -e $target ]]; then
        mkdir -p ''${target%/*}
        cp $blob $target
      fi
    done
  done
  bash ${./oci-index.sh} $out manifests.json
''
