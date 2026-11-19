{
  description = "CI for Nix flakes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      wit = pkgs.writeText "hello.wit" ''
        package test:hello;

        world hello {
          export hello: func() -> string;
        }
      '';

      image = pkgs.runCommand "hello-image" { nativeBuildInputs = [ pkgs.jq ]; } ''
        mkdir -p $out/blobs/sha256
        add() {
          local digest
          digest=$(sha256sum < "$1" | cut --delimiter " " --fields 1)
          cp "$1" $out/blobs/sha256/$digest
          jq --null-input --arg mediaType "$2" --arg digest "sha256:$digest" --argjson size "$(stat --format %s "$1")" \
            '{$mediaType, $digest, $size}'
        }

        echo hello > hello
        tar --create --file layer.tar --sort name --mtime @0 --owner 0 --group 0 --numeric-owner hello
        layer=$(add layer.tar application/vnd.oci.image.layer.v1.tar)
        for architecture in amd64 arm64; do
          jq --null-input --arg architecture $architecture --arg layer "sha256:$(sha256sum < layer.tar | cut --delimiter " " --fields 1)" \
            '{$architecture, os: "linux", rootfs: {type: "layers", diff_ids: [$layer]}}' > config.json
          config=$(add config.json application/vnd.oci.image.config.v1+json)
          jq --null-input --argjson config "$config" --argjson layer "$layer" \
            '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", $config, layers: [$layer]}' > manifest.json
          add manifest.json application/vnd.oci.image.manifest.v1+json |
            jq --arg architecture $architecture '.platform = {$architecture, os: "linux"}' >> manifests.json
        done
        jq --null-input --slurpfile manifests manifests.json \
          '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", $manifests}' > index.json
        add index.json application/vnd.oci.image.index.v1+json |
          jq '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", manifests: [.]}' > $out/index.json
        echo '{"imageLayoutVersion": "1.0.0"}' > $out/oci-layout
      '';

      module = pkgs.runCommand "hello-module.wasm" { nativeBuildInputs = [ pkgs.wasm-tools ]; } ''
        wasm-tools component embed --dummy ${wit} --output $out
      '';

      component = pkgs.runCommand "hello.wasm" { nativeBuildInputs = [ pkgs.wasm-tools ]; } ''
        wasm-tools component new ${module} --output $out
      '';

      incomplete = pkgs.runCommand "incomplete-image" { nativeBuildInputs = [ pkgs.jq ]; } ''
        cp --recursive ${image} $out
        chmod --recursive u+w $out
        index=$(jq --raw-output '.manifests[0].digest | sub(":"; "/")' $out/index.json)
        manifest=$(jq --raw-output '.manifests[0].digest | sub(":"; "/")' $out/blobs/$index)
        rm $out/blobs/$(jq --raw-output '.layers[0].digest | sub(":"; "/")' $out/blobs/$manifest)
      '';
    in
    {
      lib.outputChecks = import ./output-checks.nix nixpkgs;

      exportedSchemas = import ./schemas.nix;

      packages = lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          hello = pkgs.runCommand "hello" { nativeBuildInputs = [ pkgs.hello ]; } ''
            hello > $out
          '';
          default = hello;

          publish-oci-registry = pkgs.writeShellApplication {
            name = "publish-oci-registry";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.gnused
              pkgs.jq
              pkgs.skopeo
              pkgs.wkg
            ];
            text = builtins.readFile ./publish-oci-registry.sh;
          };
        }
      );

      ociImages.x86_64-linux.hello-image = image;

      wasmComponents.x86_64-linux.hello = component;

      checks = lib.genAttrs systems (
        system:
        self.lib.outputChecks self system
        // lib.optionalAttrs (system == "x86_64-linux") {
          oci-image-rejects-incomplete-layout = pkgs.testers.testBuildFailure' {
            drv =
              (self.lib.outputChecks { ociImages.${system}.incomplete = incomplete; } system).oci-image-incomplete;
            expectedBuilderLogEntries = [ "is missing" ];
          };
          wasm-component-rejects-module = pkgs.testers.testBuildFailure' {
            drv = (self.lib.outputChecks { wasmComponents.${system}.module = module; } system).wasm-component-module;
            expectedBuilderLogEntries = [ "is a core WebAssembly module, not a component" ];
          };
          publish-oci-registry-pushes-artifacts = pkgs.runCommand "publish-oci-registry-pushes-artifacts" {
            nativeBuildInputs = [
              pkgs.apacheHttpd
              pkgs.curl
              pkgs.distribution
              pkgs.skopeo
              pkgs.wkg
              self.packages.${system}.publish-oci-registry
            ];
          } ''
            export HOME=$PWD SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            htpasswd -Bbn user password > htpasswd
            cat > registry.yml <<EOF
            version: 0.1
            storage:
              filesystem:
                rootdirectory: $PWD/registry
            http:
              addr: 127.0.0.1:5000
            auth:
              htpasswd:
                realm: test
                path: $PWD/htpasswd
            EOF
            registry serve registry.yml &> registry.log &
            curl --silent --retry 30 --retry-connrefused --retry-delay 1 --output /dev/null http://127.0.0.1:5000/v2/

            cat > registries.conf <<EOF
            [[registry]]
            location = "127.0.0.1:5000"
            insecure = true
            EOF
            export CONTAINERS_REGISTRIES_CONF=$PWD/registries.conf WKG_OCI_INSECURE=127.0.0.1:5000

            export REGISTRY_USERNAME=user REGISTRY_PASSWORD=password
            publish-oci-registry oci-image ${image} 127.0.0.1:5000/image one two
            publish-oci-registry wasm-component ${component} 127.0.0.1:5000/component one two

            export DOCKER_CONFIG=$PWD/docker REGISTRY_AUTH_FILE=$PWD/docker/config.json
            skopeo login --username user --password-stdin 127.0.0.1:5000 <<< password
            for tag in one two; do
              skopeo --insecure-policy copy --all --preserve-digests docker://127.0.0.1:5000/image:$tag oci:image-$tag
              diff --recursive ${image}/blobs image-$tag/blobs
              wkg oci pull 127.0.0.1:5000/component:$tag --output component-$tag.wasm
              cmp ${component} component-$tag.wasm
              skopeo inspect --raw docker://127.0.0.1:5000/component:$tag > component-$tag.json
            done
            cmp component-one.json component-two.json
            kill %1
            touch $out
          '';
        }
      );
    };
}
