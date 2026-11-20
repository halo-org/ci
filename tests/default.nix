# This repository's tests, as checks. Nothing here is part of what the flake
# offers.
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

  # The first image manifest of a layout.
  manifest = image: ''
    index=${image}/blobs/$(jq --raw-output '.manifests[0].digest | sub(":"; "/")' ${image}/index.json)
    manifest=${image}/blobs/$(jq --raw-output '.manifests[0].digest | sub(":"; "/")' $index)
  '';

  hello = run "hello" [ pkgs.hello ] ''
    hello > $out
  '';

  image = ociImage system {
    name = "hello-image";
    entrypoint = [ (lib.getExe pkgs.hello) ];
    env.SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    layers = [
      pkgs.glibc
      pkgs.cacert
    ];
  };

  # The same image listed for a second platform, which cannot be built here.
  twoPlatforms = run "hello-two-platforms" [ pkgs.jq ] ''
    ${manifest image}
    cp --recursive ${image} $out
    chmod --recursive u+w $out
    rm $out/blobs/sha256/$(basename $index)
    jq --compact-output '.manifests += [.manifests[0] | .platform.architecture = "riscv64"]' $index > index.json
    digest=$(sha256sum < index.json | cut --delimiter " " --fields 1)
    cp index.json $out/blobs/sha256/$digest
    jq --compact-output --arg digest sha256:$digest --argjson size $(stat --format %s index.json) \
      '.manifests[0] += {$digest, $size}' ${image}/index.json > $out/index.json
  '';

  # An image without its first layer.
  incomplete = run "incomplete-image" [ pkgs.jq ] ''
    ${manifest image}
    cp --recursive ${image} $out
    chmod --recursive u+w $out
    rm $out/blobs/$(jq --raw-output '.layers[0].digest | sub(":"; "/")' $manifest)
  '';

  # A core module that says which component it could become.
  module = run "hello-module.wasm" [ pkgs.wasm-tools ] ''
    wasm-tools component embed --dummy --output $out ${pkgs.writeText "hello.wit" ''
      package test:hello;

      world hello {
        export hello: func() -> string;
      }
    ''}
  '';

  component = run "hello.wasm" [ pkgs.wasm-tools ] ''
    wasm-tools component new ${module} --output $out
  '';

  withoutReferences = drv: drv.overrideAttrs { outputChecks.out.allowedReferences = [ ]; };
in
# The checks of a flake with one artifact of each kind.
outputChecks {
  packages.${system} = {
    inherit hello;
    default = hello;
  };
  ociImages.${system} = {
    hello = image;
    hello-two-platforms = twoPlatforms;
  };
  wasmComponents.${system} = { inherit component; };
} system
// {
  oci-image-rejects-incomplete-image = testBuildFailure' {
    drv = (outputChecks { ociImages.${system} = { inherit incomplete; }; } system).oci-image-incomplete;
    expectedBuilderLogEntries = [ "no such file or directory" ];
  };

  wasm-component-rejects-module = testBuildFailure' {
    drv =
      (outputChecks { wasmComponents.${system} = { inherit module; }; } system).wasm-component-module;
    expectedBuilderLogEntries = [ "is a core WebAssembly module, not a component" ];
  };

  oci-image-holds-closure = run "oci-image-holds-closure" [ pkgs.jq ] ''
    ${manifest image}
    for layer in $(jq --raw-output '.layers[].digest | sub(":"; "/")' $manifest); do
      tar --list --file ${image}/blobs/$layer
    done | sed --quiet 's|^nix/store/\([^/]\+\)/\?$|/nix/store/\1|p' | sort > paths
    sort ${
      pkgs.closureInfo {
        rootPaths = [
          pkgs.hello
          pkgs.cacert
        ];
      }
    }/store-paths | diff - paths
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

  oci-image-index-rejects-shared-platform = testBuildFailure' {
    drv = ociImageIndex system {
      name = "hello-twice";
      images = [
        image
        image
      ];
    };
    expectedBuilderExitCode = 5;
    expectedBuilderLogEntries = [ "more than one image for linux/" ];
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
}
