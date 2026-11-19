nixpkgs: flake: system:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};

  packages = flake.packages.${system} or { };

  # Aliases such as default name a derivation that another package names too.
  packageNames =
    lib.foldl'
      (
        names: name:
        if lib.any (other: packages.${other}.drvPath == packages.${name}.drvPath) names then
          names
        else
          names ++ [ name ]
      )
      [ ]
      (lib.remove "default" (lib.attrNames packages) ++ lib.optional (packages ? default) "default");

  checks =
    kind: check: outputs:
    lib.mapAttrs' (name: drv: lib.nameValuePair "${kind}-${name}" (check name drv)) outputs;

  image =
    name: drv:
    pkgs.runCommand "image-${name}" { nativeBuildInputs = [ pkgs.jq ]; } ''
      bash ${./oci-layout.sh} ${drv}
      touch $out
    '';

  component =
    name: drv:
    pkgs.runCommand "component-${name}" { nativeBuildInputs = [ pkgs.wasm-tools ]; } ''
      wasm-tools validate --features all ${drv}
      wasm-tools print --skeleton ${drv} --output skeleton.wat
      if [[ $(head --bytes 10 skeleton.wat) != "(component" ]]; then
        echo "${drv} is a core WebAssembly module, not a component" >&2
        exit 1
      fi
      touch $out
    '';
in
checks "package" (_: drv: drv) (lib.getAttrs packageNames packages)
// checks "image" image (flake.ociImages.${system} or { })
// checks "component" component (flake.wasmComponents.${system} or { })
