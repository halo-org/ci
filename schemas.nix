{
  wasmComponents = {
    version = 1;
    doc = ''
      The `wasmComponents` flake output contains derivations that build WebAssembly
      components, keyed by the system that builds them. Each output is a single
      component file.
    '';
    inventory = output: {
      children = builtins.mapAttrs (system: components: {
        forSystems = [ system ];
        children = builtins.mapAttrs (_: drv: {
          what = "WebAssembly component";
          shortDescription = drv.meta.description or "";
          derivationAttrPath = [ ];
          forSystems = [ system ];
        }) components;
      }) output;
    };
  };
}
