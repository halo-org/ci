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

      image = self.lib.ociImage "x86_64-linux" {
        name = "hello-image";
        entrypoint = [ (lib.getExe pkgs.hello) ];
        env.SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        layers = [ pkgs.glibc pkgs.cacert ];
      };

      twoPlatforms = pkgs.runCommand "hello-two-platforms" { nativeBuildInputs = [ pkgs.jq ]; } ''
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
        cp --recursive ${twoPlatforms} $out
        chmod --recursive u+w $out
        index=$(jq --raw-output '.manifests[0].digest | sub(":"; "/")' $out/index.json)
        manifest=$(jq --raw-output '.manifests[0].digest | sub(":"; "/")' $out/blobs/$index)
        rm $out/blobs/$(jq --raw-output '.layers[0].digest | sub(":"; "/")' $out/blobs/$manifest)
      '';
    in
    {
      lib = {
        outputChecks = import ./output-checks.nix nixpkgs;
        ociImage = import ./oci-image.nix nixpkgs;
        ociImageIndex = import ./oci-image-index.nix nixpkgs;
      };

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

      ociImages.x86_64-linux = {
        hello-image = image;
        hello-two-platforms = twoPlatforms;
      };

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
          oci-image-holds-closure = pkgs.runCommand "oci-image-holds-closure" { nativeBuildInputs = [ pkgs.jq ]; } ''
            index=$(jq --raw-output '.manifests[0].digest | sub(":"; "/")' ${image}/index.json)
            manifest=$(jq --raw-output '.manifests[0].digest | sub(":"; "/")' ${image}/blobs/$index)
            for layer in $(jq --raw-output '.layers[].digest | sub(":"; "/")' ${image}/blobs/$manifest); do
              tar --list --file ${image}/blobs/$layer
            done | sed --quiet 's|^nix/store/\([^/]\+\)/\?$|/nix/store/\1|p' | sort > paths
            sort ${pkgs.closureInfo { rootPaths = [ pkgs.hello pkgs.cacert ]; }}/store-paths | diff - paths
            touch $out
          '';
          oci-image-has-no-references =
            let
              withoutReferences = drv: drv.overrideAttrs { outputChecks.out.allowedReferences = [ ]; };
              jq = withoutReferences (self.lib.ociImage system {
                name = "jq-image";
                entrypoint = [ (lib.getExe pkgs.jq) ];
              });
            in
            withoutReferences (self.lib.ociImageIndex system { name = "jq-index"; images = [ jq ]; });
          oci-image-index-keeps-one-image = pkgs.runCommand "oci-image-index-keeps-one-image" { } ''
            cmp ${image}/index.json ${self.lib.ociImageIndex system { name = "hello-index"; images = [ image ]; }}/index.json
            touch $out
          '';
          oci-image-index-rejects-shared-platform = pkgs.testers.testBuildFailure' {
            drv = self.lib.ociImageIndex system {
              name = "hello-twice";
              images = [ image image ];
            };
            expectedBuilderExitCode = 5;
            expectedBuilderLogEntries = [ "more than one image for linux/amd64" ];
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
              pkgs.jq
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
            publish-oci-registry oci-image ${twoPlatforms} 127.0.0.1:5000/two-platforms one two
            publish-oci-registry wasm-component ${component} 127.0.0.1:5000/component one two

            export DOCKER_CONFIG=$PWD/docker REGISTRY_AUTH_FILE=$PWD/docker/config.json
            skopeo login --username user --password-stdin 127.0.0.1:5000 <<< password
            for tag in one two; do
              for image in image=${image} two-platforms=${twoPlatforms}; do
                repository=''${image%%=*} layout=''${image#*=}
                skopeo --insecure-policy copy --all --preserve-digests docker://127.0.0.1:5000/$repository:$tag oci:$repository-$tag
                diff --recursive $layout/blobs $repository-$tag/blobs
                [[ $(jq '.manifests[0].digest' $layout/index.json) == $(jq '.manifests[0].digest' $repository-$tag/index.json) ]]
              done
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
