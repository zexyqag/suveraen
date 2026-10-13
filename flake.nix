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
    {
      nixosModules.default = {
        imports = [
          disko.nixosModules.disko
          ./nixos
        ];
      };

      checks.x86_64-linux = {
        example =
          (nixpkgs.lib.nixosSystem {
            modules = [
              self.nixosModules.default
              ./checks/example.nix
            ];
          }).config.system.build.toplevel;

        vm = import ./checks/vm.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          module = self.nixosModules.default;
        };
      };
    };
}
