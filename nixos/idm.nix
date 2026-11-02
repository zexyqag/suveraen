# Each tenant's Kanidm from the servers, with suveraen-idm (idm.sh):
#   admin TENANT platform|tenant LOGIN DISPLAY-NAME [ATTESTATION-CA-LIST]: a new person in platform-admins or
#     tenant-admins, with a link to enrol passkeys within an hour, a platform admin's to open only pinned to this
#     server; platform-admins needs the list of the makes and models it trusts once (fido-mds-tool). It also sets
#     Kanidm's own groups, which no migration reaches;
#   sync [TENANT]: copies each confidential client's secret from Kanidm into its app's Secret sso where that doesn't
#     pass the probe, and sets the flags each client's attachment asks for, for apps a release added, and after an etcd
#     restore or a cluster rebuilt;
#   rotate TENANT CLIENT, rotate --all TENANT: a new secret for one client, or for all of them and the flags again,
#     after a restore of the tenant's Kanidm, whose secrets may since have been replaced;
#   check: what the servers' checks judge (host-checks.nix), with no credential.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.idm;

  idm = pkgs.writeShellApplication {
    name = "suveraen-idm";
    runtimeInputs = [
      config.services.k3s.package
      cfg.kanidm
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
      pkgs.util-linux
      pkgs.gnused
    ];
    text = ''
      run=/run/suveraen-idm
      cacert=${lib.escapeShellArg (if cfg.caFile == null then "" else cfg.caFile)}
      gateway=${lib.escapeShellArg (lib.head config.suveraen.cluster.nodeIP)}
      logscan=${./idm-migrations.jq}
    ''
    + builtins.readFile ./idm.sh;
  };
in
{
  options.suveraen.idm = {
    kanidm = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      default = pkgs.kanidm_1_11;
      description = ''
        The Kanidm client suveraen-idm runs. A client must match its server's version, so every tenant's Kanidm runs
        this one's (checks/render.sh).
      '';
    };

    caFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/test-ca.pem";
      description = "The CA the tenants' Kanidm certificates come from, for a test CA; null for the system's CAs.";
    };

    command = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = idm;
      description = "suveraen-idm, for other modules.";
    };
  };

  config = lib.mkIf config.suveraen.cluster.enable {
    environment.systemPackages = [ idm ];
  };
}
