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

      checks.x86_64-linux = {
        server = build ./checks/server.nix;
        watcher = build ./checks/watcher.nix;

        vm = import ./checks/vm.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          module = self.nixosModules.default;
        };
      };
    };
}
