nixpkgs:
let
  oci = system: import ./oci.nix nixpkgs system;
in
{
  outputChecks = import ./output-checks.nix nixpkgs;
  ociImage = system: (oci system).image;
  ociImageIndex = system: (oci system).imageIndex;
}
