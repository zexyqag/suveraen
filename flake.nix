{
  description = "Self-hosted FLOSS services for a small community, on Kubernetes over NixOS";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-26.05/nixexprs.tar.xz";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
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
          coreutils
        ];
        text = builtins.readFile ./release/approve.sh;
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

      # What render checks each cluster's settings against: the ranges the servers give k3s.
      ranges =
        let
          cluster = (config ./checks/server.nix).suveraen.cluster;
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

        # `nix run .#e2e`: needs KVM and internet access, so it can't be one of the checks.
        e2e = {
          type = "app";
          program = "${
            (import ./checks/e2e.nix {
              inherit pkgs;
              module = self.nixosModules.default;
              kubernetes = ./kubernetes;
            }).driver
          }/bin/nixos-test-driver";
          meta.description = "Boot a server with internet access and let Flux deploy kubernetes/clusters/test onto it";
        };
      };

      checks.x86_64-linux = {
        server = build ./checks/server.nix;
        watcher = build ./checks/watcher.nix;
        ns = build ./checks/ns.nix;
        approve = import ./checks/approve.nix { inherit pkgs approve; };
        render = import ./checks/render.nix {
          inherit pkgs ranges;
          kubernetes = ./kubernetes;
        };
        render-cases = import ./checks/render-cases.nix {
          inherit pkgs ranges;
          kubernetes = ./kubernetes;
        };
        host-checks = import ./checks/host-checks.nix { inherit pkgs; };

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
      };
    };
}
