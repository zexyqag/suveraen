# Each tenant's mesh from the servers, with suveraen-mesh (mesh.sh):
#   check: what the servers' checks judge (host-checks.nix), with no credential;
#   sql TENANT: runs SQL from stdin in the tenant's mesh database, in a session that starts read-only, as check does;
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
      pkgs.gnugrep
    ];
    text = ''
      query=${./mesh.sql}
      idm=${lib.getExe config.suveraen.idm.command}
    ''
    + builtins.readFile ./mesh.sh;
  };
in
{
  options.suveraen.mesh.command = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    default = mesh;
    description = "suveraen-mesh, for other modules.";
  };

  config = lib.mkIf config.suveraen.cluster.enable {
    environment.systemPackages = [ mesh ];
  };
}
