# Each tenant's mesh from the servers, with suveraen-mesh (mesh.sh):
#   after-restore TENANT: once the tenant's PostgreSQL is back from a restore, raises its mesh's network serial past
#     every one its devices hold, and starts management again, so that running devices take the restored mesh.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  mesh = pkgs.writeShellApplication {
    name = "suveraen-mesh";
    runtimeInputs = [
      config.services.k3s.package
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./mesh.sh;
  };
in
{
  config = lib.mkIf config.suveraen.cluster.enable {
    environment.systemPackages = [ mesh ];
  };
}
