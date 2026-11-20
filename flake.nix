{
  description = "CI for Nix flakes";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      lib = import ./lib nixpkgs;

      # The publishing workflow runs this.
      packages = lib.genAttrs systems (system: {
        publish-oci-registry =
          with nixpkgs.legacyPackages.${system};
          writeShellApplication {
            name = "publish-oci-registry";
            runtimeInputs = [
              coreutils
              gnused
              jq
              skopeo
              wkg
            ];
            text = builtins.readFile ./scripts/publish-oci-registry.sh;
          };
      });

      checks = lib.genAttrs systems (
        system: self.lib.outputChecks self system // import ./tests { inherit self nixpkgs; } system
      );
    };
}
