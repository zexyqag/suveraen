{
  description = "Self-hosted FLOSS services for a small community, on Kubernetes over NixOS";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-26.05/nixexprs.tar.xz";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.2.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pre-commit.follows = "";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      lanzaboote,
    }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      approve = pkgs.writeShellApplication {
        name = "approve";
        runtimeInputs = with pkgs; [
          git
          openssh
          jq
          curl
          diffutils
          gawk
          gnused
          coreutils
          yq-go
        ];
        text = builtins.readFile ./release/approve.sh;
      };

      flux-images = pkgs.writeShellApplication {
        name = "flux-images";
        runtimeInputs = with pkgs; [
          git
          fluxcd
          yq-go
          jq
          regclient
          cosign
        ];
        text = builtins.readFile ./release/flux-images.sh;
      };

      charts = pkgs.writeShellApplication {
        name = "charts";
        runtimeInputs = with pkgs; [
          regclient
          cosign
          gnupg
          git
          curl
          jq
          yq-go
          gnutar
          gzip
          coreutils
          findutils
          diffutils
          gawk
          gnugrep
        ];
        text = builtins.readFile ./release/charts.sh;
      };

      config =
        host:
        (nixpkgs.lib.nixosSystem {
          modules = [
            self.nixosModules.default
            host
          ];
        }).config;
      machine = host: (config host).system.build;
      build = host: (machine host).toplevel;

      server = config ./checks/server.nix;

      e2e = import ./checks/e2e.nix {
        inherit pkgs netbird;
        module = self.nixosModules.default;
        kubernetes = ./kubernetes;
      };

      # The Kanidm client the servers run, whose version every tenant's Kanidm runs (checks/render.sh).
      inherit (server.suveraen.idm) kanidm;

      netbird = import ./checks/netbird.nix;
      # What NetBird keeps of a device that the servers' check knows, which the scrub keeps out (checks/render.sh).
      inherit (server.suveraen.mesh) peerColumns;

      # What render checks each cluster's settings against: the ranges the servers give k3s.
      ranges =
        let
          inherit (server.suveraen) cluster;
          named =
            kind: cidrs:
            map (cidr: "${kind}_CIDR_V${if pkgs.lib.hasInfix ":" cidr then "6" else "4"}=${cidr}") cidrs;
        in
        pkgs.lib.concatStringsSep " " (
          named "POD" cluster.podCIDRs ++ named "SERVICE" cluster.serviceCIDRs
        );
    in
    {
      nixosModules.default = {
        imports = [
          disko.nixosModules.disko
          lanzaboote.nixosModules.lanzaboote
          ./nixos
        ];
      };

      apps.x86_64-linux = {
        # `nix run .#approve`: sign what staging holds and publish it as the next release.
        approve = {
          type = "app";
          program = pkgs.lib.getExe approve;
          meta.description = "Sign the staging branch's head as the next release";
        };

        # `nix run .#flux-images`: pin the images the flake's Flux runs, as update.yml does after updating the lock.
        flux-images = {
          type = "app";
          program = pkgs.lib.getExe flux-images;
          meta.description = "Pin each image Flux runs to a digest signed by Flux's release workflow";
        };

        # `nix run .#charts -- add|bump ...`: vendor a chart, as update.yml does when given lines of arguments.
        charts = {
          type = "app";
          program = pkgs.lib.getExe charts;
          meta.description = "Vendor a chart from its upstream pin with its signature checked, or check the vendored ones";
        };

        # `nix run .#e2e`: needs KVM and internet access, so it can't be one of the checks.
        e2e = {
          type = "app";
          program = "${e2e.driver}/bin/nixos-test-driver";
          meta.description = "Boot a server with internet access and let Flux deploy kubernetes/clusters/test onto it";
        };
      };

      checks.x86_64-linux = {
        server = build ./checks/server.nix;
        watcher = build ./checks/watcher.nix;
        ns = build ./checks/ns.nix;
        approve = import ./checks/approve.nix { inherit pkgs approve; };
        charts = import ./checks/charts.nix {
          inherit pkgs charts;
          kubernetes = ./kubernetes;
          release = ./release;
        };
        render = import ./checks/render.nix {
          inherit
            pkgs
            ranges
            kanidm
            netbird
            peerColumns
            ;
          kubernetes = ./kubernetes;
        };
        host-checks = import ./checks/host-checks.nix {
          inherit pkgs;
          inherit (server.suveraen.checks) judge;
        };
        metrics-rules = import ./checks/metrics-rules.nix {
          inherit pkgs;
          inherit (server.suveraen.metrics) rulesFile;
          refused = map (a: a.message) (
            pkgs.lib.filter (a: !a.assertion)
              (config {
                imports = [
                  ./checks/server.nix
                  ./checks/metrics/refused.nix
                ];
              }).assertions
          );
        };
        test-scripts = import ./checks/test-scripts.nix {
          inherit pkgs;
          tests =
            pkgs.lib.filterAttrs (_: check: check ? config.testScriptString) (
              removeAttrs self.checks.x86_64-linux [ "test-scripts" ]
            )
            // {
              inherit e2e;
              unlock-seal = self.checks.x86_64-linux.unlock.sealing;
            };
        };
        pseudonym = import ./checks/pseudonym.nix {
          inherit pkgs;
          source = ./kubernetes/platform/gateway/app/pseudonym;
        };

        vm = import ./checks/vm.nix {
          inherit pkgs;
          module = self.nixosModules.default;
        };

        unlock = import ./checks/unlock.nix {
          inherit pkgs;
          module = self.nixosModules.default;
        };

        dns = import ./checks/dns.nix {
          inherit pkgs;
          module = self.nixosModules.default;
        };

        # disko installs the layout onto blank disks in a VM and boots it.
        storage = (machine ./checks/storage.nix).installTest;
        storage-encrypted = import ./checks/storage-encrypted.nix {
          inherit pkgs;
          inherit (nixpkgs.lib) nixosSystem;
          inherit (disko.lib.testLib) makeDiskoTest;
          module = self.nixosModules.default;
        };
      }
      // import ./checks/render-cases.nix {
        inherit
          pkgs
          ranges
          kanidm
          netbird
          peerColumns
          ;
        kubernetes = ./kubernetes;
        shards = 4;
      };
    };
}
