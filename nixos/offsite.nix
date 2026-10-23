# Copies this server's own state off the machine, to every provider under hosts/<host name>/<source>/: each source's
# newest files, encrypted with age to recipients that live offline, so nothing on the server can read a copy. A unit
# without network encrypts them into a spool; one with network, as a user of its own that holds only the providers'
# keys, uploads what the spool holds. It never deletes or changes a copy there: the bucket's default retention keeps
# each for as long as it lasts, and a copy that changed fails the upload.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.offsite;
  host = config.networking.hostName;
  spool = "/var/lib/offsite/spool";
  # The names collect has encrypted, kept for good: the providers keep what they hold, and a file that left its
  # directory can come back with a rollback.
  encrypted = "/var/lib/offsite/encrypted";
  state = "/var/lib/offsite/state";

  # age encrypts to a YubiKey's recipient through its plugin.
  age = [
    pkgs.age
  ]
  ++ lib.optional (lib.any (lib.hasPrefix "age1yubikey1") cfg.recipients) pkgs.age-plugin-yubikey;

  # A recipient age can't encrypt to fails the build rather than the first copy.
  recipients = pkgs.runCommand "offsite-recipients" { nativeBuildInputs = age; } ''
    printf '%s\n' ${lib.escapeShellArgs cfg.recipients} >$out
    age -R $out -o /dev/null </dev/null
  '';

  everyHours = lib.foldl' lib.min 24 (lib.mapAttrsToList (_: s: s.everyHours) cfg.sources);

  collect = pkgs.writeShellApplication {
    name = "offsite-collect";
    runtimeInputs = age ++ [
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      shopt -s nullglob
      broken=0

      # collect <source> <directory> <pattern> <how many> <verify command...>
      collect() {
        local to=${spool}/$1 seen=${encrypted}/$1 from=$2 pattern=$3 keep=$4 f files=()
        local -A wanted=()
        shift 4
        mkdir -p "$to" "$seen"
        # One younger than a minute may still be being written.
        if [ -d "$from" ]; then
          mapfile -t files < <(find "$from" -maxdepth 1 -type f -name "$pattern" -mmin +1 -printf '%T@ %f\n' \
            | sort -rn | head -n "$keep" | cut -d ' ' -f 2-)
        fi
        for f in "''${files[@]}"; do
          wanted["$f.age"]=1
          # age encrypts differently each time, which the providers would take for a changed copy, so a file is
          # encrypted once: one that comes back among the newest after its copy left the spool stays out.
          if [ -e "$to/$f.age" ] || [ -e "$seen/$f" ]; then continue; fi
          if ! "$@" "$from/$f"; then
            echo "$from/$f is broken, so it isn't copied."
            broken=1
            continue
          fi
          age -R ${recipients} -o "$to/$f.age.tmp" "$from/$f"
          touch -r "$from/$f" "$to/$f.age.tmp"
          mv "$to/$f.age.tmp" "$to/$f.age"
          touch "$seen/$f"
        done
        for f in "$to"/*; do
          [ -n "''${wanted[$(basename "$f")]:-}" ] || rm -f "$f"
        done
      }
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (name: s: ''
        collect ${
          lib.escapeShellArgs [
            name
            s.directory
            s.pattern
            (toString s.keep)
          ]
        } ${s.verify}
      '') cfg.sources
    )
    + ''
      exit $broken
    '';
  };

  upload = pkgs.writeShellApplication {
    name = "offsite";
    runtimeInputs = [
      pkgs.rclone
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnused
    ];
    text = ''
      export HOME=$RUNTIME_DIRECTORY

      sources=(${lib.escapeShellArgs (lib.attrNames cfg.sources)})
      # stamp <target>: when the newest copy of each source that the target now holds was made.
      stamp() {
        local source newest
        for source in "''${sources[@]}"; do
          newest=$(find "${spool}/$source" -maxdepth 1 -type f -name '*.age' -printf '%T@ %p\n' | sort -rn \
            | head -n 1 | cut -d ' ' -f 2-)
          [ -z "$newest" ] || touch -r "$newest" "${state}/$source.$1" || return 1
        done
      }

      # upload <target> <endpoint> <region> <provider> <bucket>. Each target in a subshell of its own, so that one
      # failing doesn't keep the others from their copies; errexit doesn't apply there, hence the &&. A provider that
      # is down fails in seconds with three tries per request, where rclone's ten take over ten minutes.
      failed=0
      upload() {
        (
          creds=$CREDENTIALS_DIRECTORY/$1
          key=$(sed -n 's/^AWS_ACCESS_KEY_ID=//p' "$creds") && secret=$(sed -n 's/^AWS_SECRET_ACCESS_KEY=//p' "$creds") \
            && export RCLONE_CONFIG_T_TYPE=s3 RCLONE_CONFIG_T_ENDPOINT="$2" RCLONE_CONFIG_T_REGION="$3" \
              RCLONE_CONFIG_T_PROVIDER="$4" RCLONE_CONFIG_T_ACCESS_KEY_ID="$key" \
              RCLONE_CONFIG_T_SECRET_ACCESS_KEY="$secret" RCLONE_CONFIG_T_NO_CHECK_BUCKET=true \
            && rclone copy ${spool} "T:$5/hosts/${host}/" --checksum --immutable --exclude '*.tmp' --transfers 2 \
              --contimeout 30s --timeout 5m --low-level-retries 3 -v \
            && stamp "$1"
        ) || {
          echo "The copy to $1 failed."
          failed=1
        }
      }
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (name: t: ''
        upload ${
          lib.escapeShellArgs [
            name
            t.endpoint
            t.region
            t.provider
            t.bucket
          ]
        }
      '') cfg.targets
    )
    + ''
      exit $failed
    '';
  };
in
{
  options.suveraen.offsite = {
    recipients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "age1yubikey1..." ];
      description = ''
        Public age recipients the copies are encrypted to, such as hardware keys' and a recovery key kept on paper:
        none whose identity is on a server.
      '';
    };

    targets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            endpoint = lib.mkOption {
              type = lib.types.str;
              example = "https://s3.example.org";
              description = "The provider's S3 endpoint.";
            };
            region = lib.mkOption {
              type = lib.types.str;
              description = "The bucket's region.";
            };
            provider = lib.mkOption {
              type = lib.types.str;
              default = "Other";
              description = "The provider as rclone's S3 backend names it.";
            };
            bucket = lib.mkOption {
              type = lib.types.str;
              description = ''
                The bucket, locked with a default retention, where this server's key may list, read and write under
                hosts/<host name>/ alone, and delete nothing.
              '';
            };
            credentialsFile = lib.mkOption {
              type = lib.types.str;
              example = "/run/secrets/offsite-1";
              description = ''
                File holding that key as two lines, AWS_ACCESS_KEY_ID=... and AWS_SECRET_ACCESS_KEY=..., read only
                when a copy runs.
              '';
            };
          };
        }
      );
      default = { };
      description = "The providers every copy goes to, by name.";
    };

    sources = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            directory = lib.mkOption {
              type = lib.types.str;
              description = "Where the source's files are.";
            };
            pattern = lib.mkOption {
              type = lib.types.str;
              description = "Which files there to copy, as find -name takes it.";
            };
            verify = lib.mkOption {
              type = lib.types.str;
              description = "A command that fails for a broken file, given its path.";
            };
            keep = lib.mkOption {
              type = lib.types.ints.positive;
              description = "How many of the newest files to keep encrypted for the next copies.";
            };
            everyHours = lib.mkOption {
              type = lib.types.ints.positive;
              description = "How often the source makes a new file, in hours.";
            };
          };
        }
      );
      internal = true;
      default = { };
      description = "What other modules copy off the machine, by name.";
    };
  };

  config = lib.mkIf (cfg.targets != { }) {
    assertions = [
      {
        assertion = cfg.recipients != [ ];
        message = "suveraen.offsite needs recipients: the copies are encrypted to them alone.";
      }
      {
        # They name files, findings and credentials.
        assertion = lib.all (name: builtins.match "[a-z0-9-]+" name != null) (
          lib.attrNames cfg.targets ++ lib.attrNames cfg.sources
        );
        message = "suveraen.offsite's targets and sources are named [a-z0-9-]+.";
      }
    ];

    users.users.offsite = {
      isSystemUser = true;
      group = "offsite";
    };
    users.groups.offsite = { };

    # Reads what may be plaintext, so it has no network and writes nothing but the spool.
    systemd.services.offsite-collect = {
      description = "Encrypt this server's own state for the providers";
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = [
          "offsite/spool"
          "offsite/encrypted"
        ];
        PrivateNetwork = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ExecStart = lib.getExe collect;
      };
    };

    # Sees nothing but the spool's ciphertext and its own keys.
    systemd.services.offsite = {
      description = "Copy this server's own state to the providers";
      # A file the collect unit found broken alerts through it and holds up no other copy; one it didn't finish
      # encrypting stays out (*.tmp).
      wants = [
        "offsite-collect.service"
        "network-online.target"
      ];
      after = [
        "offsite-collect.service"
        "network-online.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "offsite";
        Group = "offsite";
        LoadCredential = lib.mapAttrsToList (name: t: "${name}:${t.credentialsFile}") cfg.targets;
        RuntimeDirectory = "offsite";
        RuntimeDirectoryMode = "0700";
        StateDirectory = "offsite/state";
        StateDirectoryMode = "0700";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        # Under systemd, rclone logs to the journal's socket rather than to stderr.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        MemoryMax = "512M";
        ExecStart = lib.getExe upload;
      };
    };
    # Half an hour after each source's new file is due.
    systemd.timers.offsite = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 00/${toString everyHours}:30:00";
        OnBootSec = "15min";
        Persistent = true;
      };
    };

    suveraen.alerts.units = [
      "offsite-collect"
      "offsite"
    ];

    # A copy may be missed once.
    suveraen.checks.files = lib.listToAttrs (
      lib.concatLists (
        lib.mapAttrsToList (
          source: s:
          map (
            target:
            lib.nameValuePair "${source}-offsite-${target}" {
              path = "${state}/${source}.${target}";
              maxAge = "${toString (2 * s.everyHours + 1)}h";
            }
          ) (lib.attrNames cfg.targets)
        ) cfg.sources
      )
    );
  };
}
