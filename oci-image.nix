nixpkgs: system:
{
  name,
  entrypoint,
  env ? { },
  layers ? [ ],
}:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (pkgs.stdenv.hostPlatform) go;

  configuration = {
    Entrypoint = entrypoint;
    Env = lib.mapAttrsToList (name: value: "${name}=${value}") env;
  };

  # Its references are the store paths the configuration refers to.
  references = pkgs.writeText "${name}-configuration.json" (builtins.toJSON configuration);

  # The store paths in an image are its contents, not its runtime dependencies.
  withoutReferences =
    name: attributes: script:
    pkgs.runCommand name (
      attributes
      // {
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
        nativeBuildInputs = [ pkgs.jq ];
      }
    ) script;

  layer =
    name: graph: paths:
    withoutReferences name { exportReferencesGraph = graph; } ''
      jq --raw-output ${lib.escapeShellArg paths} "$NIX_ATTRS_JSON_FILE" | bash ${./oci-layer.sh} "''${outputs[out]}"
    '';

  lower = lib.imap0 (
    index: root:
    layer "${lib.getName root}-oci-layer" {
      include = [ root ];
      exclude = lib.take index layers;
    } "[.include[].path] - [.exclude[]?.path] | .[]"
  ) layers;

  top =
    layer "${name}-oci-layer"
      {
        include = [ references ];
        exclude = layers;
      }
      ''
        ([.exclude[]?.path] - [.include[].path]) as $outside
        | if $outside != [] then error("not in the closure of the image: \($outside | join(", "))") else . end
        | [.include[].path] - [.exclude[]?.path] - ["${references}"]
        | .[]
      '';
in
withoutReferences name
  {
    inherit configuration;
    layers = lower ++ [ top ];
    platform = {
      architecture = go.GOARCH;
      os = go.GOOS;
    };
  }
  ''
    bash ${./oci-image.sh} "''${outputs[out]}" "$NIX_ATTRS_JSON_FILE"
    bash ${./oci-index.sh} "''${outputs[out]}" manifests.json
  ''
