# The flake's library. Its functions take the system that builds the result.
nixpkgs:
let
  inherit (nixpkgs) lib;

  # Runs oci.sh. The store paths in a layer or an image are its contents, not
  # its runtime dependencies, so the output keeps no references to them.
  oci =
    pkgs: name: arguments:
    pkgs.runCommand name {
      __structuredAttrs = true;
      unsafeDiscardReferences.out = true;
      nativeBuildInputs = [ pkgs.jq ];
    } "bash ${./oci.sh} ${arguments}";

  out = ''"''${outputs[out]}"'';
in
{
  # A check for each package, OCI image and WebAssembly component a flake has
  # for a system, to merge into its checks.
  outputChecks =
    flake: system:
    let
      pkgs = nixpkgs.legacyPackages.${system};

      checks =
        prefix: tools: script:
        lib.mapAttrs' (
          name: artifact:
          lib.nameValuePair "${prefix}-${name}" (
            pkgs.runCommand "${prefix}-${name}" { nativeBuildInputs = tools; } ''
              ${script artifact}
              touch $out
            ''
          )
        );

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
    in
    lib.mapAttrs' (name: lib.nameValuePair "package-${name}") packages
    # An image is a layout that skopeo can read as one image.
    // checks "oci-image" [ pkgs.skopeo ] (image: ''
      skopeo --insecure-policy --tmpdir "$TMPDIR" copy --all oci:${image} oci:copy
    '') (flake.ociImages.${system} or { })
    // checks "wasm-component" [ pkgs.wasm-tools ] (component: ''
      wasm-tools validate --features all ${component}
      if [[ $(wasm-tools print --skeleton ${component} | head --bytes 10) != "(component" ]]; then
        echo "${component} is a core WebAssembly module, not a component" >&2
        exit 1
      fi
    '') (flake.wasmComponents.${system} or { });

  # An OCI image layout for the platform of a system. The image holds the
  # closure of what its entrypoint, environment and layers refer to. Each of
  # layers gets a layer of its own, from the bottom up, and the rest goes in
  # a last layer.
  ociImage =
    system:
    {
      name,
      entrypoint,
      env ? { },
      layers ? [ ],
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs.stdenv.hostPlatform) go;

      config = pkgs.writeText "${name}-config.json" (
        builtins.toJSON {
          Entrypoint = entrypoint;
          Env = lib.mapAttrsToList (name: value: "${name}=${value}") env;
        }
      );

      closure = roots: "${pkgs.closureInfo { rootPaths = roots; }}/store-paths";

      # A layer holds the closure of its roots, without the closure of the
      # layers below and without the omitted paths.
      layer =
        name: roots: below: omitted:
        oci pkgs name "layer ${out} ${closure roots} ${closure below} ${toString omitted}";

      lower = lib.imap0 (
        index: root: layer "${lib.getName root}-oci-layer" [ root ] (lib.take index layers) [ ]
      ) layers;

      # The configuration file is only a root to find what the image refers to.
      top = layer "${name}-oci-layer" [ config ] layers [ config ];
    in
    oci pkgs name "image ${out} ${go.GOOS} ${go.GOARCH} ${config} ${toString (lower ++ [ top ])}";

  # An OCI image layout that holds the images of several, one per platform.
  ociImageIndex =
    system:
    { name, images }:
    oci nixpkgs.legacyPackages.${system} name "index ${out} ${toString images}";
}
