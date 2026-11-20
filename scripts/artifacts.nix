# The OCI images and WebAssembly components of a flake. An artifact that
# several systems can build is listed once, for the first of them.
flake:
let
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];
  kinds = {
    ociImages = "oci-image";
    wasmComponents = "wasm-component";
  };
in
builtins.concatMap (
  output:
  builtins.attrValues (
    builtins.zipAttrsWith
      (
        name: candidates:
        let
          inherit (builtins.head candidates) system drv;
        in
        {
          inherit name system;
          kind = kinds.${output};
          attribute = "${output}.${system}.\"${name}\"";
          drv = drv.drvPath;
          output = drv.outputName;
        }
      )
      (
        map (
          system: builtins.mapAttrs (_: drv: { inherit system drv; }) (flake.${output}.${system} or { })
        ) systems
      )
  )
) (builtins.attrNames kinds)
