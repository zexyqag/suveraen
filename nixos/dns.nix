{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.dns;
  knot = config.services.knot.package;
  configFile = config.environment.etc."knot/knot.conf".source;
  socket = "/run/knot/knot.sock";

  self = cfg.servers.${cfg.self};
  signing = cfg.self == cfg.signer;
  published = self.name != null;
  others = lib.filterAttrs (name: _: name != cfg.self) cfg.servers;
  acme = cfg.acme.zone != null;

  v4 = lib.filter (a: !lib.hasInfix ":" a);
  v6 = lib.filter (lib.hasInfix ":");

  withCluster = signing && acme && config.suveraen.cluster.enable;
  podAddress = config.suveraen.cluster.nodeServices.dnsUpdates;
  updaters = lib.optionals withCluster config.suveraen.cluster.podCIDRs ++ cfg.acme.clients;

  acmeKey = "/var/lib/knot/acme-update.conf";

  publishedNames = lib.sort lib.lessThan (
    map (s: "${s.name}.") (lib.attrValues (lib.filterAttrs (_: s: s.name != null) cfg.servers))
  );
  providerNames = lib.concatMap (e: map (n: "${n}.") e.names) (lib.attrValues cfg.external);
  externalTransfer = lib.concatMap (e: e.transfer) (lib.attrValues cfg.external);

  relative =
    zone: name:
    if name == zone then
      "@"
    else if lib.hasSuffix ".${zone}" name then
      lib.removeSuffix ".${zone}" name
    else
      null;

  acmeParent = lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." cfg.acme.zone));

  # Each name that gets certificates by DNS-01 points its challenge into the ACME zone, under a label that
  # doesn't spell the name out.
  challenge =
    zone: name:
    let
      base = if name == "@" || name == "*" then "" else lib.removePrefix "*." name;
      domain = if base == "" then zone else "${base}.${zone}";
      owner = if base == "" then "_acme-challenge" else "_acme-challenge.${base}";
      label = builtins.substring 0 16 (builtins.hashString "sha256" domain);
    in
    lib.nameValuePair owner "_acme-challenge.${label}.${cfg.acme.zone}.";

  caaValue =
    issuer:
    lib.concatStringsSep "; " (
      [ issuer.domain ]
      ++ lib.optional (issuer.accountUri != null) "accounturi=${issuer.accountUri}"
      ++ lib.optional (
        cfg.caa.validationMethods != [ ]
      ) "validationmethods=${lib.concatStringsSep "," cfg.caa.validationMethods}"
    );

  # Every record of a zone as owner, type and data, the declared ones and those derived from the settings.
  records =
    name: zone:
    let
      declared = lib.concatLists (
        lib.mapAttrsToList (
          owner: types:
          lib.concatLists (
            lib.mapAttrsToList (
              type: values:
              map (data: {
                inherit owner type data;
              }) values
            ) types
          )
        ) zone.records
      );
      record = owner: type: data: { inherit owner type data; };
      glue = lib.concatLists (
        lib.mapAttrsToList (
          _: s:
          let
            owner = if s.name == null then null else relative name s.name;
          in
          lib.optionals (owner != null) (
            map (record owner "A") (v4 s.addresses) ++ map (record owner "AAAA") (v6 s.addresses)
          )
        ) cfg.servers
      );
      # Names with addresses would otherwise take mail at those addresses. A wildcard gets no TXT, which would
      # also answer for _acme-challenge names below it.
      hosts = lib.unique (
        [ "@" ] ++ map (r: r.owner) (lib.filter (r: r.type == "A" || r.type == "AAAA") (declared ++ glue))
      );
      noMail = lib.optionals (!zone.mail) (
        lib.concatMap (
          owner:
          [ (record owner "MX" "0 .") ]
          ++ lib.optional (!lib.hasPrefix "*" owner) (record owner "TXT" ''"v=spf1 -all"'')
        ) hosts
        ++ [ (record "_dmarc" "TXT" ''"v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s"'') ]
      );
      caa =
        (
          if cfg.caa.issuers == [ ] then
            [ (record "@" "CAA" ''0 issue ";"'') ]
          else
            map (i: record "@" "CAA" ''0 issue "${caaValue i}"'') cfg.caa.issuers
        )
        ++ (
          if zone.wildcard && cfg.caa.issuers != [ ] then
            map (i: record "@" "CAA" ''0 issuewild "${caaValue i}"'') cfg.caa.issuers
          else
            [ (record "@" "CAA" ''0 issuewild ";"'') ]
        );
      challenges = lib.mapAttrsToList (owner: target: record owner "CNAME" target) (
        lib.listToAttrs (map (challenge name) zone.certificates)
      );
      delegation =
        let
          label = relative name cfg.acme.zone;
        in
        lib.optionals (acme && acmeParent == name) (
          map (record label "NS") publishedNames ++ map (record label "DS") cfg.acme.ds
        );
    in
    map (record "@" "NS") cfg.signed.${name}.nameservers
    ++ glue
    ++ noMail
    ++ caa
    ++ challenges
    ++ delegation
    ++ declared;

  soa =
    { expire, negative }:
    "@ SOA ${lib.head publishedNames} ${
      lib.replaceStrings [ "@" ] [ "." ] cfg.contact
    }. 1 3600 900 ${toString expire} ${toString negative}";

  render = rs: lib.concatMapStrings (r: "${r.owner} ${r.type} ${r.data}\n") rs;

  # The serial is the server's (difference-no-serial); the one here is never used.
  zoneFile =
    name: zone:
    pkgs.writeText "${name}.zone" ''
      $ORIGIN ${name}.
      $TTL ${toString zone.ttl}
      ${soa {
        expire = cfg.expireDays * 86400;
        negative = zone.ttl;
      }}
      ${render (records name zone)}'';

  acmeZoneFile = pkgs.writeText "${cfg.acme.zone}.zone" ''
    $ORIGIN ${cfg.acme.zone}.
    $TTL 60
    ${soa {
      expire = cfg.expireDays * 86400;
      negative = 60;
    }}
    ${lib.concatMapStrings (ns: "@ NS ${ns}\n") cfg.signed.${cfg.acme.zone}.nameservers}'';

  # Answers "does a key in the KASP database match one of these DS records?", so a host never starts signing a
  # zone with a new key while the parent publishes the old one's DS.
  keysMatch = pkgs.writeShellApplication {
    name = "suveraen-dns-keys-match";
    runtimeInputs = [
      knot
      pkgs.gnugrep
    ];
    text = ''
      zone=$1
      shift
      keys=$(keymgr -c ${configFile} "$zone" ds)
      for ds in "$@"; do
        if grep -qiF -- "$zone. DS $ds" <<<"$keys"; then
          exit 0
        fi
      done
      echo "No key for $zone matches its published DS ($*). Restore the key backup: age -d ... | suveraen-dns-restore" >&2
      exit 1
    '';
  };

  # Takes a decrypted key backup (tar) on stdin and makes its KASP database this server's, then starts knot. It works
  # with knot down, as it is on a signer whose keys don't match the published DS.
  restore = pkgs.writeShellApplication {
    name = "suveraen-dns-restore";
    runtimeInputs = [
      knot
      pkgs.gnutar
      pkgs.coreutils
      config.systemd.package
    ];
    text = ''
      dir=/var/lib/knot/restore
      install -d -o knot -g knot -m 0700 /var/lib/knot
      rm -rf "$dir"
      mkdir -m 0700 "$dir"
      tar -x -C "$dir" --no-same-owner
      # A backup's KASP database is laid out as knot keeps its own (zone-backup +kaspdb).
      if [ ! -s "$dir/keys/data.mdb" ] || [ -z "$(ls -A "$dir/keys/keys")" ]; then
        echo "That isn't a key backup: it holds no KASP database or keys." >&2
        exit 1
      fi
      systemctl stop knot
      rm -rf /var/lib/knot/keys
      mv "$dir/keys" /var/lib/knot/keys
      rm -rf "$dir"
      for zone in ${lib.escapeShellArgs (lib.attrNames cfg.signed)}; do
        keymgr -c ${configFile} "$zone" ds
      done
      chown -R knot:knot /var/lib/knot/keys
      systemctl start knot
    '';
  };

  # Everyone with business at this server beyond queries: the other servers, the provider's and the ACME clients.
  peers =
    lib.concatMap (s: s.addresses) (lib.attrValues others)
    ++ externalTransfer
    ++ lib.optionals signing cfg.acme.clients;

  peerRules =
    let
      set = addresses: "{ ${lib.concatStringsSep ", " addresses} }";
    in
    lib.optionalString (v4 peers != [ ]) ''
      ip saddr ${set (v4 peers)} meta l4proto { tcp, udp } th dport 53 accept
    ''
    + lib.optionalString (v6 peers != [ ]) ''
      ip6 saddr ${set (v6 peers)} meta l4proto { tcp, udp } th dport 53 accept
    '';

  acls = {
    transfer-servers = {
      address = lib.concatMap (s: s.addresses) (lib.attrValues others);
      key = "transfer";
      action = "transfer";
    };
    # The watcher's checks read the zones from the server on the same host.
    transfer-self = {
      address = self.addresses;
      action = "transfer";
    };
    transfer-external = {
      address = externalTransfer;
      action = "transfer";
    };
    notify-signer = {
      address = cfg.servers.${cfg.signer}.addresses;
      key = "transfer";
      action = "notify";
    };
    acme-update = {
      address = if signing && acme then updaters else [ ];
      key = "acme-update";
      action = "update";
      update-type = [ "TXT" ];
      update-owner = "name";
      update-owner-match = "pattern";
      update-owner-name = [ "_acme-challenge.*" ];
    };
  };
  aclsFor = lib.filter (id: id != null && (acls.${id}.address != [ ]));

  zoneOptions =
    { name, ... }:
    {
      options = {
        records = lib.mkOption {
          type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf lib.types.str));
          default = { };
          example = {
            "@".A = [ "203.0.113.10" ];
            idm.AAAA = [ "2001:db8::10" ];
          };
          description = ''
            Records by owner (relative to the zone, `@` for the apex) and type, with data as in a zone file. The
            SOA, NS, CAA and the nameservers' own addresses are added; so are, unless `mail` is set, a null MX, SPF
            `-all` and a DMARC reject policy.
          '';
        };

        ttl = lib.mkOption {
          type = lib.types.ints.positive;
          default = 3600;
          description = "TTL of the zone's records, and how long resolvers remember that a name doesn't exist.";
        };

        mail = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether the zone's names send or receive mail. The zone then declares its own MX, SPF and DMARC.";
        };

        wildcard = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether the CAs in `suveraen.dns.caa` may issue wildcard certificates in the zone.";
        };

        certificates = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [
            "@"
            "idm"
            "*"
          ];
          description = ''
            Names (relative, `@` for the apex) that get certificates by DNS-01. Each gets an `_acme-challenge`
            CNAME into the ACME zone; a wildcard's challenge is its parent's.
          '';
        };

        ds = lib.mkOption {
          type = lib.types.listOf (lib.types.strMatching "[0-9]+ [0-9]+ [0-9]+ [0-9A-Fa-f]+");
          default = [ ];
          example = [ "12345 13 2 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ];
          description = ''
            DS records published at the registrar for ${name}, as key tag, algorithm, digest type and digest.
            While set, a signer refuses to start without a matching key, and the watcher compares them with the
            parent's.
          '';
        };
      };
    };
in
{
  options.suveraen.dns = {
    self = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "This host's entry in `servers`; null when it serves no DNS.";
    };

    signer = lib.mkOption {
      type = lib.types.str;
      description = "The server that holds the keys, signs the zones and takes ACME updates; the others are its secondaries.";
    };

    servers = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            addresses = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              example = [
                "203.0.113.53"
                "2001:db8::53"
              ];
              description = "The server's public addresses. Knot listens on them and talks to the other servers from them.";
            };
            name = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "ns1.example.org";
              description = "Name the server is published under in the zones' NS records; null keeps it hidden, as the signer is.";
            };
          };
        }
      );
      description = "The Knot servers, the same on every host.";
    };

    external = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            names = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Their nameservers' names, published in the zones' NS records.";
            };
            notify = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Addresses the signer sends NOTIFY to.";
            };
            transfer = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Addresses they transfer the zones from; allowed without TSIG.";
            };
          };
        }
      );
      default = { };
      description = "Secondaries run by a provider, for every zone but the ACME zone.";
    };

    contact = lib.mkOption {
      type = lib.types.str;
      example = "hostmaster@example.org";
      description = "Mailbox in the zones' SOA records.";
    };

    zones = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule zoneOptions);
      default = { };
      description = "The zones, by name, each signed with a key of its own.";
    };

    acme = {
      zone = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "acme.example.org";
        description = ''
          Zone that cert-manager writes DNS-01 answers into over RFC 2136 and that only our own servers serve. Its
          key may only change TXT records at `_acme-challenge.<label>`. Its parent must be one of `zones`.
        '';
      };
      ds = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "[0-9]+ [0-9]+ [0-9]+ [0-9A-Fa-f]+");
        default = [ ];
        description = "The ACME zone's DS, published in its parent zone.";
      };
      clients = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Addresses besides this host's pods that may send updates to the ACME zone, with its key.";
      };
    };

    caa = {
      issuers = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              domain = lib.mkOption {
                type = lib.types.str;
                example = "letsencrypt.org";
              };
              accountUri = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Our ACME account; only it may get certificates from this CA.";
              };
            };
          }
        );
        default = [ ];
        description = "CAs that may issue for every zone's names. None at all forbids any.";
      };
      validationMethods = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "dns-01" ];
        description = "The only ACME challenges the CAs may validate with.";
      };
    };

    expireDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 28;
      description = "How long the secondaries keep answering without reaching the signer (SOA expire).";
    };

    signatureDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 45;
      description = "Validity of new signatures.";
    };

    refreshDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Signatures are renewed when they have this long left, so every signature always has at least this long.";
    };

    transferKeyFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        Knot configuration with the TSIG key `transfer` the servers authenticate transfers and NOTIFYs with
        (`keymgr -t transfer`), readable by the knot user.
      '';
    };

    signed = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf lib.types.str));
      readOnly = true;
      internal = true;
      default =
        lib.mapAttrs (_: zone: {
          inherit (zone) ds;
          provider = providerNames;
          nameservers = publishedNames ++ providerNames;
        }) cfg.zones
        # Only our own servers serve the ACME zone.
        // lib.optionalAttrs acme {
          ${cfg.acme.zone} = {
            inherit (cfg.acme) ds;
            provider = [ ];
            nameservers = publishedNames;
          };
        };
      description = "Every zone the signer signs, with its DS, the provider's nameservers and its whole NS set.";
    };

    backup = {
      recipients = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "age recipients the signer encrypts its daily key backup to, under /var/lib/knot-backup.";
      };
      keep = lib.mkOption {
        type = lib.types.ints.positive;
        default = 14;
        description = "How many backups to keep.";
      };
    };
  };

  config = lib.mkIf (cfg.self != null) (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.servers ? ${cfg.self} && cfg.servers ? ${cfg.signer};
            message = "suveraen.dns.self and signer must name entries of suveraen.dns.servers.";
          }
          {
            assertion = publishedNames != [ ];
            message = "suveraen.dns needs at least one published server.";
          }
          {
            assertion = !acme || cfg.zones ? ${acmeParent};
            message = "The ACME zone's parent ${acmeParent} must be one of suveraen.dns.zones.";
          }
          {
            assertion = cfg.expireDays < cfg.refreshDays && cfg.refreshDays < cfg.signatureDays;
            message = "suveraen.dns needs expireDays < refreshDays < signatureDays, so a secondary never serves an expired signature.";
          }
          {
            assertion = !signing || cfg.backup.recipients != [ ];
            message = "The signer needs suveraen.dns.backup.recipients: without a key backup it can't be replaced.";
          }
          {
            assertion = lib.all (z: z.certificates == [ ]) (lib.attrValues cfg.zones) || acme;
            message = "suveraen.dns zones list certificates, which need suveraen.dns.acme.zone.";
          }
          {
            assertion = lib.all (
              z: z.mail || !(z.records ? "_dmarc") && lib.all (types: !(types ? MX)) (lib.attrValues z.records)
            ) (lib.attrValues cfg.zones);
            message = "A suveraen.dns zone without mail gets its MX and DMARC records from the module.";
          }
        ];

        services.knot = {
          enable = true;
          keyFiles = [ cfg.transferKeyFile ] ++ lib.optional (signing && acme) acmeKey;
          settings = {
            server = {
              listen = map (a: "${a}@53") (self.addresses ++ lib.optional withCluster podAddress);
              identity = "";
              version = "";
              nsid = "";
            };
            log.syslog.any = "info";
            remote =
              lib.mapAttrs (_: s: {
                address = s.addresses;
                key = "transfer";
                via = self.addresses;
              }) others
              // lib.mapAttrs' (
                n: e:
                lib.nameValuePair "external-${n}" {
                  address = e.notify;
                  via = self.addresses;
                }
              ) cfg.external
              # Knot asks the validating resolver whether the parent publishes a new key's DS.
              // {
                resolver.address = [ "127.0.0.1" ];
              };
            # An ACL without addresses would match every address, so a rule whose list is empty is left out.
            acl = lib.filterAttrs (_: rule: rule.address != [ ]) acls;
            submission.parent = {
              parent = [ "resolver" ];
              check-interval = "1h";
            };
            policy.signed = {
              algorithm = "ecdsap256sha256";
              # One key per zone that never rolls by itself: the DS at the registrar changes only by hand, and any
              # key backup restores a key the parent still publishes.
              single-type-signing = true;
              ksk-lifetime = 0;
              ksk-submission = "parent";
              rrsig-lifetime = "${toString cfg.signatureDays}d";
              rrsig-refresh = "${toString cfg.refreshDays}d";
              nsec3 = true;
              nsec3-iterations = 0;
              nsec3-salt-length = 0;
              nsec3-salt-lifetime = 0;
            };
            "mod-rrl".default = {
              rate-limit = 200;
              slip = 2;
              # Its time limit also counts the handshakes of transfers and NOTIFYs.
              whitelist = peers;
            };
            template.default = {
              zonefile-sync = -1;
              journal-content = "all";
            }
            // (
              if signing then
                {
                  dnssec-signing = true;
                  dnssec-policy = "signed";
                  serial-policy = "unixtime";
                  zonefile-load = "difference-no-serial";
                  semantic-checks = true;
                }
              else
                {
                  master = [ cfg.signer ];
                  zonefile-load = "none";
                }
            )
            // lib.optionalAttrs published { global-module = "mod-rrl/default"; };
            zone =
              lib.mapAttrs (
                name: zone:
                {
                  acl = aclsFor [
                    "transfer-servers"
                    "transfer-self"
                    "transfer-external"
                    (if signing then null else "notify-signer")
                  ];
                }
                // lib.optionalAttrs signing {
                  file = zoneFile name zone;
                  notify = lib.attrNames others ++ map (n: "external-${n}") (lib.attrNames cfg.external);
                }
              ) cfg.zones
              // lib.optionalAttrs acme {
                ${cfg.acme.zone} = {
                  acl = aclsFor [
                    "transfer-servers"
                    "transfer-self"
                    (if signing then "acme-update" else "notify-signer")
                  ];
                }
                // lib.optionalAttrs signing {
                  file = acmeZoneFile;
                  notify = lib.attrNames others;
                  # Its TXT records come only from updates and survive restarts.
                  zonefile-skip = [ "TXT" ];
                };
              };
          };
        };

        # keyFiles turn off the module's own check; check with stand-in keys instead.
        system.checks = [
          (pkgs.runCommand "knot-config-check" { nativeBuildInputs = [ knot ]; } ''
            {
              printf 'key:\n'
              for id in transfer acme-update; do
                printf '  - id: %s\n    algorithm: hmac-sha256\n    secret: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n' "$id"
              done
              grep -v '^include: ' ${configFile}
            } > knot.conf
            knotc -c knot.conf conf-check
            ${lib.concatStrings (
              lib.mapAttrsToList (name: zone: ''
                kzonecheck -o ${name} ${zoneFile name zone}
              '') cfg.zones
            )}
            ${lib.optionalString acme "kzonecheck -o ${cfg.acme.zone} ${acmeZoneFile}"}
            touch $out
          '')
        ];

        # Knot sends NOTIFYs and transfers from the declared addresses, which must exist by then.
        systemd.services.knot = {
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
        };

        environment.systemPackages = [
          restore
          keysMatch
        ];

        suveraen.alerts.units = [ "knot" ];
      }

      (lib.mkIf published {
        networking.firewall = {
          allowedTCPPorts = [ 53 ];
          allowedUDPPorts = [ 53 ];
        };
      })

      (lib.mkIf (!published) {
        networking.firewall.extraInputRules = peerRules;
      })

      (lib.mkIf signing {
        systemd.services.knot.preStart = lib.concatStrings (
          lib.mapAttrsToList (
            zone: z:
            lib.optionalString (z.ds != [ ]) ''
              ${lib.getExe keysMatch} ${lib.escapeShellArgs ([ zone ] ++ z.ds)}
            ''
          ) cfg.signed
        );

        systemd.services.knot-backup = {
          description = "Back up the DNSSEC keys, encrypted";
          startAt = "daily";
          after = [ "knot.service" ];
          path = [
            knot
            pkgs.age
            pkgs.gnutar
            pkgs.coreutils
            pkgs.findutils
          ]
          # age encrypts to a YubiKey's recipient through its plugin.
          ++ lib.optional (lib.any (lib.hasPrefix "age1yubikey1") cfg.backup.recipients) pkgs.age-plugin-yubikey;
          serviceConfig = {
            Type = "oneshot";
            StateDirectory = "knot-backup";
            StateDirectoryMode = "0700";
            UMask = "0077";
          };
          script = ''
            work=/var/lib/knot/backup
            rm -rf "$work"
            knotc --socket ${socket} -b zone-backup +backupdir "$work" +kaspdb +nozonefile +notimers +nocatalog +noquic
            # knotc answers OK before knowing the outcome; a finished backup has its label and the keys.
            grep -q '^finished_time:' "$work/knot_backup.label"
            [ -n "$(ls -A "$work/keys/keys")" ]
            out=/var/lib/knot-backup/keys-$(date -u +%Y%m%dT%H%M%SZ).tar.age
            tar -C "$work" -c . | age ${
              lib.concatMapStringsSep " " (r: "-r ${lib.escapeShellArg r}") cfg.backup.recipients
            } -o "$out.tmp"
            mv "$out.tmp" "$out"
            rm -rf "$work"
            ls -1t /var/lib/knot-backup/keys-*.tar.age | tail -n +${toString (cfg.backup.keep + 1)} | xargs -r rm --
          '';
        };
        systemd.timers.knot-backup.timerConfig = {
          # Also soon after boot, so a new signer's keys have a backup before the night.
          OnBootSec = "15min";
          Persistent = true;
        };

        suveraen.alerts.units = [ "knot-backup" ];
      })

      (lib.mkIf (signing && acme) {
        # The key cert-manager updates the ACME zone with never leaves this host: knot reads it here, and the
        # cluster gets it as a Secret. Every start makes a new one, so `systemctl restart knot-acme-key` replaces it,
        # and knot and the Secret follow.
        systemd.services.knot-acme-key = {
          description = "Make the key the ACME zone takes updates with";
          wantedBy = [ "knot.service" ];
          before = [ "knot.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
          };
          script = ''
            install -d -o knot -g knot -m 0700 /var/lib/knot
            ${knot}/bin/keymgr -t acme-update hmac-sha256 | grep -v '^#' > ${acmeKey}.tmp
            chown knot:knot ${acmeKey}.tmp
            mv ${acmeKey}.tmp ${acmeKey}
          '';
          path = [ pkgs.gnugrep ];
        };
        systemd.services.knot.requires = [ "knot-acme-key.service" ];
      })

      (lib.mkIf withCluster {
        networking.firewall.extraInputRules =
          let
            pods = v4 config.suveraen.cluster.podCIDRs;
          in
          ''
            ip saddr { ${lib.concatStringsSep ", " pods} } ip daddr ${podAddress} meta l4proto { tcp, udp } th dport 53 accept
          '';

        systemd.services.knot-acme-secret = {
          description = "Give cert-manager the key to the ACME zone";
          after = [
            "k3s.service"
            "knot-acme-key.service"
          ];
          wants = [ "k3s.service" ];
          requires = [ "knot-acme-key.service" ];
          wantedBy = [ "multi-user.target" ];
          path = [
            config.services.k3s.package
            pkgs.gnused
            pkgs.coreutils
          ];
          environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
          serviceConfig = {
            Type = "oneshot";
            # Active after it ran, so a new key restarts it too.
            RemainAfterExit = true;
            Restart = "on-failure";
            RestartSec = 10;
          };
          script = ''
            until kubectl get namespace cert-manager >/dev/null 2>&1; do sleep 5; done
            kubectl -n cert-manager create secret generic acme-update \
              --from-file=secret=<(sed -n 's/^ *secret: *//p' ${acmeKey} | tr -d '\n') \
              --dry-run=client -o yaml | kubectl apply -f -
          '';
        };
      })
    ]
  );
}
