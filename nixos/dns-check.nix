# The watcher's checks of the zones, reported to its Gatus: every nameserver answers with the signer's serial and
# signed keys, no signature is about to expire, and each parent delegates with the NS and DS in suveraen.dns.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.dns;
  gatusPort = config.services.gatus.settings.web.port;

  spec = pkgs.writeText "dns-check.json" (
    builtins.toJSON {
      self = lib.head cfg.servers.${cfg.self}.addresses;
      servers = lib.concatLists (
        lib.mapAttrsToList (name: s: map (address: { inherit name address; }) s.addresses) cfg.servers
      );
      # A signature must never get closer to expiring than the signer's renewal leaves it, plus a day's slack.
      minSeconds = (cfg.refreshDays - 1) * 86400;
      zones = lib.mapAttrsToList (zone: z: {
        inherit zone;
        inherit (z) provider;
        ns = map lib.toLower z.nameservers;
        ds = map lib.toUpper z.ds;
      }) cfg.signed;
    }
  );

  # The check gets the one token it reports with, not the watcher's others.
  token = pkgs.writeShellScript "dns-check-token" ''
    ${lib.getExe pkgs.gnused} -n 's/^DNS_TOKEN=//p' ${lib.escapeShellArg config.suveraen.watcher.gatusEnvironmentFile} \
      >"$RUNTIME_DIRECTORY/token"
  '';

  check = pkgs.writeShellApplication {
    name = "suveraen-dns-check";
    runtimeInputs = [
      config.services.knot.package
      pkgs.jq
      pkgs.curl
      pkgs.gawk
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
    ];
    text = ''
      spec=${spec}
      token=$(cat "$RUNTIME_DIRECTORY/token")
      self=$(jq -r .self "$spec")
      min_seconds=$(jq -r .minSeconds "$spec")

      ask() { kdig +norec +timeout=3 +retry=1 "$@" 2>/dev/null || true; }
      # Addresses through this host's validating resolver.
      addresses() { for type in A AAAA; do kdig +short +timeout=3 "$1" "$type" 2>/dev/null | grep -v '^;' || true; done; }

      serials() {
        for t in "''${targets[@]}"; do
          echo "''${t%%=*} $(ask @"''${t#*=}" +short SOA "$zone" | awk 'NR == 1 { print $3 }')"
        done
      }

      report() {
        if [ -z "$2" ]; then
          query="success=true"
        else
          query="success=false&error=$(jq -rn --arg e "$2" '$e | @uri')"
        fi
        printf 'header = "Authorization: Bearer %s"\n' "$token" | curl --config - -fsS -X POST \
          "http://127.0.0.1:${toString gatusPort}/api/v1/endpoints/dns_''${1//./-}/external?$query"
      }

      while read -r z; do
        zone=$(jq -r .zone <<<"$z")
        problems=()

        targets=()
        while read -r t; do targets+=("$t"); done < <(jq -r '.servers[] | "\(.name)=\(.address)"' "$spec")
        while read -r name; do
          for a in $(addresses "$name"); do targets+=("$name=$a"); done
        done < <(jq -r '.provider[]' <<<"$z")

        for t in "''${targets[@]}"; do
          keys=$(ask @"''${t#*=}" +dnssec DNSKEY "$zone")
          if ! awk '$4 == "DNSKEY" { k = 1 } $4 == "RRSIG" && $5 == "DNSKEY" { s = 1 } END { exit !(k && s) }' <<<"$keys"; then
            problems+=("''${t%%=*} (''${t#*=}) has no signed DNSKEY")
          fi
        done

        # A NOTIFY takes a moment to reach everyone; only a difference that lasts counts.
        got=$(serials)
        if [ "$(awk '{ print $2 }' <<<"$got" | sort -u | wc -l)" -ne 1 ]; then
          sleep 60
          got=$(serials)
          if [ "$(awk '{ print $2 }' <<<"$got" | sort -u | wc -l)" -ne 1 ]; then
            problems+=("serials differ: $(tr '\n' ' ' <<<"$got")")
          fi
        fi

        if ! copy=$(kdig @"$self" +timeout=3 AXFR "$zone" 2>/dev/null); then
          problems+=("can't transfer the zone from this server")
        else
          oldest=$(awk '$4 == "RRSIG" { print $9 }' <<<"$copy" | sort | awk 'NR == 1')
          if [ -z "$oldest" ]; then
            problems+=("no signatures in this server's copy")
          else
            expires=$(date -u -d "''${oldest:0:4}-''${oldest:4:2}-''${oldest:6:2} ''${oldest:8:2}:''${oldest:10:2}:''${oldest:12:2}" +%s)
            left=$((expires - $(date +%s)))
            if [ "$left" -lt "$min_seconds" ]; then
              problems+=("a signature expires in $((left / 86400)) days: the signer has stopped renewing them")
            fi
          fi
        fi

        # Each server of the parent zone, asked directly, delegates with the declared NS and DS.
        want_ns=$(jq -r '.ns[]' <<<"$z" | sort -u)
        want_ds=$(jq -r '.ds[]' <<<"$z" | sort -u)
        for pns in $(kdig +short +timeout=3 NS "''${zone#*.}." 2>/dev/null | grep -v '^;'); do
          for a in $(addresses "$pns"); do
            ns=$(ask @"$a" NS "$zone" | awk -v z="$zone." 'tolower($1) == z && $4 == "NS" { print tolower($5) }' | sort -u)
            ds=$(ask @"$a" DS "$zone" | awk -v z="$zone." 'tolower($1) == z && $4 == "DS" { print $5, $6, $7, toupper($8) }' | sort -u)
            [ "$ns" = "$want_ns" ] || problems+=("$pns ($a) delegates to: $(tr '\n' ' ' <<<"$ns")")
            [ "$ds" = "$want_ds" ] || problems+=("$pns ($a) publishes DS: $(tr '\n' ' ' <<<"$ds")")
          done
        done

        report "$zone" "$(printf '%s; ' "''${problems[@]}" | sed 's/; $//')"
      done < <(jq -c '.zones[]' "$spec")
    '';
  };
in
{
  options.suveraen.dns.check = {
    enable = lib.mkEnableOption "the watcher's checks of every nameserver, the signatures and the parents' NS and DS";
    interval = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      description = "How often to check.";
    };
  };

  config = lib.mkIf cfg.check.enable {
    assertions = [
      {
        assertion = config.suveraen.watcher.enable && cfg.self != null;
        message = "suveraen.dns.check runs on the watcher, next to one of the servers, and reports to its Gatus.";
      }
    ];

    systemd.services.dns-check = {
      description = "Check every nameserver, the signatures and the parents' delegation";
      after = [
        "gatus.service"
        "knot.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        RuntimeDirectory = "dns-check";
        RuntimeDirectoryMode = "0700";
        ExecStartPre = "+${token}";
        ExecStart = lib.getExe check;
      };
    };
    suveraen.alerts.units = [ "dns-check" ];
    systemd.timers.dns-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = cfg.check.interval;
      };
    };

    # A missed report means the check itself stopped.
    services.gatus.settings.external-endpoints = map (zone: {
      name = zone;
      group = "dns";
      token = "\${DNS_TOKEN}";
      heartbeat.interval = "1h";
      alerts = [
        {
          type = "ntfy";
          description = "DNS for ${zone} has a problem";
          send-on-resolved = true;
          failure-threshold = 2;
          success-threshold = 1;
        }
      ];
    }) (lib.attrNames cfg.signed);
  };
}
