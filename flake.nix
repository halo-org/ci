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

      exportedSchemas = import ./lib/schemas.nix;

      packages = lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # The publishing workflow runs this.
          publish-oci-registry = pkgs.writeShellApplication {
            name = "publish-oci-registry";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.gnused
              pkgs.jq
              pkgs.skopeo
              pkgs.wkg
            ];
            text = builtins.readFile ./scripts/publish-oci-registry.sh;
          };
        }
      );

      checks = lib.genAttrs systems (
        system: self.lib.outputChecks self system // import ./tests { inherit self nixpkgs; } system
      );
    };
}
