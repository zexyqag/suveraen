# Each tenant's mesh from the servers, with suveraen-mesh (mesh.sh):
#   check: what the servers' checks judge (host-checks.nix), with no credential;
#   sql TENANT: runs SQL from stdin in the tenant's mesh database, in a session that starts read-only, as check does,
#     with the peers' columns of peerColumns as psql's variables scrubbed and kept;
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
      scrubbed=${lib.escapeShellArg (builtins.toJSON cfg.peerColumns.scrubbed)}
      kept=${lib.escapeShellArg (builtins.toJSON cfg.peerColumns.kept)}
    ''
    + builtins.readFile ./mesh.sh;
  };
  cfg = config.suveraen.mesh;
in
{
  options.suveraen.mesh = {
    command = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = mesh;
      description = "suveraen-mesh, for other modules.";
    };

    peerColumns = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      internal = true;
      default = {
        scrubbed = {
          meta_system_serial_number = "";
          meta_system_product_name = "";
          meta_system_manufacturer = "";
          meta_network_addresses = [ ];
          meta_environment = {
            Cloud = "";
            Platform = "";
          };
          meta_files = [ ];
          meta_certificates = [ ];
        };
        kept = [
          "meta_capabilities"
          "meta_core"
          "meta_flags"
          "meta_go_os"
          "meta_hostname"
          "meta_kernel"
          "meta_kernel_version"
          "meta_os"
          "meta_os_version"
          "meta_platform"
          "meta_sync_message_version"
          "meta_ui_version"
          "meta_wt_version"
        ];
      };
      description = ''
        What NetBird's table of peers holds of a device, by column, at the release a tenant's mesh runs
        (checks/netbird.nix): what the scrub blanks (kubernetes/apps/netbird), as it writes it, and what it keeps, each
        reviewed. The check finds a column it blanks gone, and one of neither; render holds the scrub to these.
      '';
    };
  };

  config = lib.mkIf config.suveraen.cluster.enable {
    environment.systemPackages = [ mesh ];
  };
}
