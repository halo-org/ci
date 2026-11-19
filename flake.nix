{
  description = "Checks that test the CI workflow";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    {
      checks = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          hello = pkgs.runCommand "hello" { nativeBuildInputs = [ pkgs.hello ]; } ''
            hello > $out
          '';
        }
      );
    };
}
