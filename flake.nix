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

      build =
        host:
        (nixpkgs.lib.nixosSystem {
          modules = [
            self.nixosModules.default
            host
          ];
        }).config.system.build.toplevel;
    in
    {
      nixosModules.default = {
        imports = [
          disko.nixosModules.disko
          ./nixos
        ];
      };

      # `nix run .#approve`: sign what staging holds and publish it as the next release.
      apps.x86_64-linux.approve = {
        type = "app";
        program = pkgs.lib.getExe approve;
        meta.description = "Sign the staging branch's head as the next release";
      };

      checks.x86_64-linux = {
        server = build ./checks/server.nix;
        watcher = build ./checks/watcher.nix;
        approve = import ./checks/approve.nix { inherit pkgs approve; };

        vm = import ./checks/vm.nix {
          inherit pkgs;
          module = self.nixosModules.default;
        };

        unlock = import ./checks/unlock.nix {
          inherit pkgs;
          module = self.nixosModules.default;
        };
      };
    };
}
