{
  config,
  lib,
  ...
}:
let
  cfg = config.suveraen.watcher;
  ntfyPort = 2586;
  gatusPort = 8080;

  tokenVariable =
    server: "HEARTBEAT_TOKEN_" + lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] server);

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

    readers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "phone" ];
      description = "ntfy accounts (phones) that may read alerts. Everything not granted here is denied.";
    };

    ntfyEnvironmentFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        Environment file declaring ntfy's accounts: NTFY_AUTH_USERS with a bcrypt hash (`ntfy user hash`) for every reader
        plus `publisher` (servers) and `gatus`, and NTFY_AUTH_TOKENS with a token for `publisher` and `gatus`.
        It must not set NTFY_AUTH_ACCESS, which would replace the access rules declared here.
      '';
    };

    gatusEnvironmentFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        Environment file with NTFY_TOPIC (the secret alert topic), NTFY_TOKEN (the `gatus` account's ntfy token),
        one HEARTBEAT_TOKEN_<NAME> per server, the name upper-cased with `-` as `_`, and with suveraen.dns.check
        DNS_TOKEN. Values must be plain letters and digits (ntfy tokens keep their `tk_`); Gatus substitutes them
        into its YAML.
      '';
    };

    servers = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-z0-9-]+");
      default = [ ];
      description = "Hosts that report a heartbeat, each with its own token. Each gets the external endpoint `servers_<name>`.";
    };

    heartbeatTimeout = lib.mkOption {
      type = lib.types.str;
      default = "15m";
      description = "Silence after which a server counts as down; about three times the servers' reporting interval.";
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
        # Wildcards keep the topic name, which must stay secret, out of the public configuration.
        auth-access =
          map (reader: "${reader}:*:ro") cfg.readers
          ++ map (publisher: "${publisher}:*:wo") [
            "publisher"
            "gatus"
          ];
        # iPhones only get instant notifications through ntfy.sh's push relay. It receives the message ID and a
        # hash of the topic URL, never the content; the phone then fetches the message from here.
        upstream-base-url = "https://ntfy.sh";
        # Phones fetch and catch up from this cache; the default 12 hours is too short for a phone left off over a weekend.
        cache-duration = "72h";
        # Alerts are short text. Attachments would be downloadable without logging in, and the phone apps don't need the web app.
        attachment-cache-dir = lib.mkForce "";
        web-root = "disable";
      };
    };
    systemd.services.ntfy-sh.serviceConfig = {
      Restart = "on-failure";
      RestartSec = 5;
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
          topic = "\${NTFY_TOPIC}";
          token = "\${NTFY_TOKEN}";
          priority = 4;
          # A server gone silent matters more than a flapping check.
          overrides = [
            {
              group = "servers";
              priority = 5;
            }
          ];
        };
        external-endpoints = map (server: {
          name = server;
          group = "servers";
          token = "\${${tokenVariable server}}";
          heartbeat.interval = cfg.heartbeatTimeout;
          # A missed heartbeat already means the whole interval was silent, and one report means it's back.
          alerts = [
            (ntfyAlert "No heartbeat from ${server}, or its alerts aren't getting through" {
              failure-threshold = 1;
              success-threshold = 1;
            })
          ];
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
      # Phones' and visitors' addresses aren't kept: no access log, and error logs only for two weeks.
      commonHttpConfig = "access_log off;";
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
          # The account API mints tokens that outlive the declared ones, and the stats count alerts. Phones need neither.
          locations."/v1/account".return = "404";
          locations."= /v1/stats".return = "404";
        };
        ${cfg.statusHost} = {
          forceSSL = true;
          enableACME = true;
          locations."/".proxyPass = "http://127.0.0.1:${toString gatusPort}";
        };
      };
    };

    services.logrotate.settings.nginx.rotate = 2;

    security.acme.acceptTerms = true;

    # Gatus going down silences every check, and failed renewals end in expired certificates.
    suveraen.alerts.units = [
      "gatus"
      "acme-order-renew-${cfg.ntfyHost}"
      "acme-order-renew-${cfg.statusHost}"
    ];

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
