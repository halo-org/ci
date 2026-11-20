# A check for each package, OCI image and WebAssembly component a flake has
# for a system, named after the output it comes from.
nixpkgs: flake: system:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};

  # default is usually another package under a second name.
  packages =
    let
      all = flake.packages.${system} or { };
      named = removeAttrs all [ "default" ];
    in
    if lib.any (package: package.drvPath == all.default.drvPath or null) (lib.attrValues named) then
      named
    else
      all;

  checks =
    prefix: tool: script:
    lib.mapAttrs' (
      name: artifact:
      lib.nameValuePair "${prefix}-${name}" (
        pkgs.runCommand "${prefix}-${name}" { nativeBuildInputs = [ tool ]; } ''
          bash ${script} ${artifact}
          touch $out
        ''
      )
    );
in
lib.mapAttrs' (name: lib.nameValuePair "package-${name}") packages
// checks "oci-image" pkgs.jq ./check-oci-image.sh (flake.ociImages.${system} or { })
// checks "wasm-component" pkgs.wasm-tools ./check-wasm-component.sh (
  flake.wasmComponents.${system} or { }
)
