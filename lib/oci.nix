# Builders for OCI image layouts. Every layout has one image index that lists
# an image manifest per platform.
nixpkgs: system:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (pkgs.stdenv.hostPlatform) go;

  # The store paths in a layer or layout are its contents, not its runtime
  # dependencies, so the output keeps no references to them.
  build =
    name: script:
    pkgs.runCommand name {
      __structuredAttrs = true;
      unsafeDiscardReferences.out = true;
      nativeBuildInputs = [ pkgs.jq ];
    } script;

  closure = roots: "${pkgs.closureInfo { rootPaths = roots; }}/store-paths";

  # A layer holds the closure of its roots, without the closure of the roots
  # of the layers below it and without the paths in omit.
  layer =
    name: roots: below: omit:
    build name ''
      bash ${./oci}/layer.sh "''${outputs[out]}" ${closure roots} ${closure below} ${toString omit}
    '';
in
{
  # An image for the platform of this system. It holds the closure of what
  # its configuration refers to. Each of layers gets a layer of its own, from
  # the bottom up, and the rest goes in the top layer.
  image =
    {
      name,
      entrypoint,
      env ? { },
      layers ? [ ],
    }:
    let
      config = pkgs.writeText "${name}-config.json" (
        builtins.toJSON {
          Entrypoint = entrypoint;
          Env = lib.mapAttrsToList (name: value: "${name}=${value}") env;
        }
      );
      lower = lib.imap0 (
        index: root: layer "${lib.getName root}-oci-layer" [ root ] (lib.take index layers) [ ]
      ) layers;
      # The configuration file is only here to say what the image refers to.
      top = layer "${name}-oci-layer" [ config ] layers [ config ];
    in
    build name ''
      bash ${./oci}/image.sh "''${outputs[out]}" ${go.GOOS} ${go.GOARCH} ${config} ${toString (lower ++ [ top ])}
    '';

  # One layout that holds the images for several platforms.
  imageIndex =
    { name, images }:
    build name ''
      bash ${./oci}/image-index.sh "''${outputs[out]}" ${toString images}
    '';
}
