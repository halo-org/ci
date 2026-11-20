# The checks of a flake for the systems the workflow can build.
flake:
let
  checks = flake.checks or { };
in
builtins.concatMap
  (
    system:
    map (
      name:
      let
        check = checks.${system}.${name};
      in
      {
        inherit system name;
        drv = check.drvPath;
        outputs = map (output: check.${output}.outPath) check.outputs;
      }
    ) (builtins.attrNames (checks.${system} or { }))
  )
  [
    "x86_64-linux"
    "aarch64-linux"
  ]
