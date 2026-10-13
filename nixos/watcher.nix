{
  config,
  lib,
  ...
}:
let
  cfg = config.suveraen.watcher;
  ntfyPort = 2586;
  gatusPort = 8080;

  ntfyAlert =
    description: extra:
    {
      type = "ntfy";
      inherit description;
      send-on-resolved = true;
    }
    // extra;
in
{
  options.suveraen.watcher = {
    enable = lib.mkEnableOption "the watcher: ntfy for alerts and Gatus for checks from outside the cluster";

    ntfyHost = lib.mkOption {
      type = lib.types.str;
      example = "alerts.example.org";
      description = "Host name ntfy is served at. Phones subscribe here.";
    };

    statusHost = lib.mkOption {
      type = lib.types.str;
      example = "status.example.org";
      description = "Host name of the Gatus status page and its heartbeat API.";
    };

    topic = lib.mkOption {
      type = lib.types.str;
      default = "ops";
      description = "ntfy topic that Gatus posts its alerts to.";
    };

    ntfyEnvironmentFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        Environment file declaring ntfy's users, their access and the publishing tokens
        (NTFY_AUTH_USERS, NTFY_AUTH_ACCESS, NTFY_AUTH_TOKENS). Everything else is denied.
      '';
    };

    gatusEnvironmentFile = lib.mkOption {
      type = lib.types.str;
      description = "Environment file with NTFY_TOKEN (Gatus publishing to ntfy) and HEARTBEAT_TOKEN (servers reporting in).";
    };

    servers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Hosts that report a heartbeat. Each gets the external endpoint `servers_<name>`.";
    };

    heartbeatTimeout = lib.mkOption {
      type = lib.types.str;
      default = "15m";
      description = "Silence after which a server counts as down.";
    };

    checks = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            url = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      default = [ ];
      description = "Public HTTPS endpoints checked from outside; each must answer 200 with a certificate valid for 10 more days.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.ntfy-sh = {
      enable = true;
      environmentFile = cfg.ntfyEnvironmentFile;
      settings = {
        base-url = "https://${cfg.ntfyHost}";
        listen-http = "127.0.0.1:${toString ntfyPort}";
        behind-proxy = true;
        auth-default-access = "deny-all";
        # iPhones only get instant notifications through ntfy.sh's push relay; it receives a content-free poll request.
        upstream-base-url = "https://ntfy.sh";
      };
    };

    services.gatus = {
      enable = true;
      environmentFile = cfg.gatusEnvironmentFile;
      settings = {
        web = {
          address = "127.0.0.1";
          port = gatusPort;
        };
        storage = {
          type = "sqlite";
          path = "/var/lib/gatus/data.db";
        };
        alerting.ntfy = {
          url = "http://127.0.0.1:${toString ntfyPort}";
          inherit (cfg) topic;
          token = "\${NTFY_TOKEN}";
          priority = 5;
        };
        external-endpoints = map (server: {
          name = server;
          group = "servers";
          token = "\${HEARTBEAT_TOKEN}";
          heartbeat.interval = cfg.heartbeatTimeout;
          # A missed heartbeat already means the whole interval was silent.
          alerts = [ (ntfyAlert "No heartbeat from ${server}" { failure-threshold = 1; }) ];
        }) cfg.servers;
        # Gatus refuses to start without a regular endpoint; ntfy's own health is a useful one.
        endpoints = [
          {
            name = "ntfy";
            group = "watcher";
            url = "http://127.0.0.1:${toString ntfyPort}/v1/health";
            interval = "1m";
            conditions = [
              "[STATUS] == 200"
              "[BODY].healthy == true"
            ];
          }
        ]
        ++ map (check: {
          inherit (check) name url;
          group = "checks";
          interval = "2m";
          conditions = [
            "[STATUS] == 200"
            "[CERTIFICATE_EXPIRATION] > 240h"
          ];
          alerts = [ (ntfyAlert "${check.name} is failing" { }) ];
        }) cfg.checks;
      };
    };

    services.nginx = {
      enable = true;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;
      recommendedProxySettings = true;
      virtualHosts = {
        # Requests for names we don't serve get no answer and no certificate.
        "_" = {
          default = true;
          rejectSSL = true;
          locations."/".return = "444";
        };
        ${cfg.ntfyHost} = {
          forceSSL = true;
          enableACME = true;
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString ntfyPort}";
            proxyWebsockets = true;
            # Subscriptions are long-lived streams.
            extraConfig = ''
              proxy_buffering off;
              proxy_request_buffering off;
              proxy_read_timeout 3m;
              proxy_send_timeout 3m;
            '';
          };
        };
        ${cfg.statusHost} = {
          forceSSL = true;
          enableACME = true;
          locations."/".proxyPass = "http://127.0.0.1:${toString gatusPort}";
        };
      };
    };

    security.acme.acceptTerms = true;

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
