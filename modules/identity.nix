{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.identity;
  fqdn = "${cfg.subdomain}.${config.suveraen.domain}";
  certDir = config.security.acme.certs.${fqdn}.directory;
  port = 8443;
in
{
  options.suveraen.identity = {
    enable = lib.mkEnableOption "Kanidm, one account for every service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "idm";
      description = "Kanidm's subdomain. Changing it later breaks passkeys and sign-ins, so pick it once.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.kanidm = {
      # Kanidm only supports upgrading one minor version at a time.
      package = lib.mkDefault pkgs.kanidm_1_11;
      server = {
        enable = true;
        settings = {
          domain = fqdn;
          origin = "https://${fqdn}";
          bindaddress = "127.0.0.1:${toString port}";
          tls_chain = "${certDir}/fullchain.pem";
          tls_key = "${certDir}/key.pem";
          http_client_address_info.x-forward-for = [ "127.0.0.1" ];
          online_backup.versions = 7;
        };
      };
      client = {
        enable = true;
        settings.uri = "https://${fqdn}";
      };
    };

    users.groups.idm-tls.members = [
      "nginx"
      "kanidm"
    ];
    security.acme.certs.${fqdn} = {
      group = "idm-tls";
      reloadServices = [ "kanidm" ];
    };

    systemd.services.kanidm = {
      wants = [ "acme-${fqdn}.service" ];
      after = [ "acme-${fqdn}.service" ];
      serviceConfig = {
        # Kanidm re-reads its certificate on SIGHUP.
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = 10;
      };
    };

    services.nginx.virtualHosts.${fqdn} = {
      forceSSL = true;
      enableACME = true;
      locations."/".proxyPass = "https://127.0.0.1:${toString port}";
      extraConfig = ''
        add_header Strict-Transport-Security "max-age=63072000" always;
      '';
    };
  };
}
