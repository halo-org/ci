# This repository's tests, as checks for a system. Nothing here is part of
# what the flake offers. A pull request also runs the checking workflow on
# them.
{ self, nixpkgs }:
system:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (self.lib) outputChecks ociImage ociImageIndex;
  inherit (pkgs.testers) testBuildFailure';

  run =
    name: tools: script:
    pkgs.runCommand name { nativeBuildInputs = tools; } script;

  image = ociImage system {
    name = "hello-image";
    entrypoint = [ (lib.getExe pkgs.hello) ];
    env.SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    layers = [
      pkgs.glibc
      pkgs.cacert
    ];
  };

  # Made by hand, because the builder here cannot build a second platform.
  twoPlatforms = run "hello-two-platforms" [ pkgs.jq ] ''
    bash ${./two-platform-image.sh} $out ${../lib/oci/layout.sh}
  '';

  incomplete = run "incomplete-image" [ pkgs.jq ] ''
    bash ${./.}/remove-layer.sh ${twoPlatforms} $out
  '';

  module = run "hello-module.wasm" [ pkgs.wasm-tools ] ''
    wasm-tools component embed --dummy ${./hello.wit} --output $out
  '';

  component = run "hello.wasm" [ pkgs.wasm-tools ] ''
    wasm-tools component new ${module} --output $out
  '';

  hello = run "hello" [ pkgs.hello ] ''
    hello > $out
  '';

  # The outputs of a flake that uses the library. The images and the
  # component only build on one system.
  fixtures = {
    packages.${system} = {
      inherit hello;
      default = hello;
    };
    ociImages.x86_64-linux = {
      hello-image = image;
      hello-two-platforms = twoPlatforms;
    };
    wasmComponents.x86_64-linux.hello = component;
  };

  withoutReferences = drv: drv.overrideAttrs { outputChecks.out.allowedReferences = [ ]; };
in
outputChecks fixtures system
// lib.optionalAttrs (system == "x86_64-linux") {
  oci-image-rejects-incomplete-layout = testBuildFailure' {
    drv = (outputChecks { ociImages.${system} = { inherit incomplete; }; } system).oci-image-incomplete;
    expectedBuilderLogEntries = [ "is missing" ];
  };

  oci-image-holds-closure = run "oci-image-holds-closure" [ pkgs.jq ] ''
    bash ${./.}/image-holds.sh ${image} ${
      pkgs.closureInfo {
        rootPaths = [
          pkgs.hello
          pkgs.cacert
        ];
      }
    }/store-paths
    touch $out
  '';

  # jq is a tool the builders use themselves.
  oci-image-has-no-references = withoutReferences (
    ociImageIndex system {
      name = "jq-index";
      images = [
        (withoutReferences (
          ociImage system {
            name = "jq-image";
            entrypoint = [ (lib.getExe pkgs.jq) ];
          }
        ))
      ];
    }
  );

  oci-image-index-keeps-one-image = run "oci-image-index-keeps-one-image" [ ] ''
    cmp ${image}/index.json ${
      ociImageIndex system {
        name = "hello-index";
        images = [ image ];
      }
    }/index.json
    touch $out
  '';

  oci-image-index-rejects-shared-platform = testBuildFailure' {
    drv = ociImageIndex system {
      name = "hello-twice";
      images = [
        image
        image
      ];
    };
    expectedBuilderExitCode = 5;
    expectedBuilderLogEntries = [ "more than one image for linux/amd64" ];
  };

  wasm-component-rejects-module = testBuildFailure' {
    drv =
      (outputChecks { wasmComponents.${system} = { inherit module; }; } system).wasm-component-module;
    expectedBuilderLogEntries = [ "is a core WebAssembly module, not a component" ];
  };

  publish-oci-registry-pushes-artifacts =
    run "publish-oci-registry-pushes-artifacts"
      [
        pkgs.apacheHttpd
        pkgs.curl
        pkgs.distribution
        pkgs.jq
        pkgs.skopeo
        pkgs.wkg
        self.packages.${system}.publish-oci-registry
      ]
      ''
        export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        bash ${./publish.sh} ${image} ${twoPlatforms} ${component}
        touch $out
      '';

  scripts-pass-shellcheck = run "scripts-pass-shellcheck" [ pkgs.shellcheck ] ''
    cd ${../.}
    shellcheck --shell bash --severity warning $(find . -name "*.sh")
    touch $out
  '';

  wasm-component-schema-lists-components =
    let
      inventory = self.exportedSchemas.wasmComponents.inventory fixtures.wasmComponents;
    in
    assert inventory.children.${system}.children.hello.what == "WebAssembly component";
    pkgs.emptyFile;
}
