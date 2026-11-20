# The OCI images and WebAssembly components a flake has for a system.
system: flake:
let
  artifacts =
    output: kind:
    builtins.attrValues (
      builtins.mapAttrs (name: artifact: {
        inherit name kind;
        attribute = "${output}.${system}.\"${name}\"";
        drv = artifact.drvPath;
        output = artifact.outputName;
      }) (flake.${output}.${system} or { })
    );
in
artifacts "ociImages" "oci-image" ++ artifacts "wasmComponents" "wasm-component"
