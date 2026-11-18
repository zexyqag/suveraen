{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.suveraen.source) flake;
  cfg = config.suveraen.upgrade;
  alert = lib.getExe config.suveraen.alerts.command;
  # An encrypted host would sit at the passphrase prompt after rebooting.
  canReboot = !config.suveraen.storage.encrypted;
  state = "/var/lib/suveraen-upgrade";

  # Resolves the branch head, which Nix only accepts with a valid signature when there are signers, and refuses a
  # head older than the release this host already runs: an old signed release is still signed, so resetting the
  # branch to one would otherwise roll the host back.
  resolve = pkgs.writeShellApplication {
    name = "suveraen-upgrade-resolve";
    runtimeInputs = [
      config.nix.package
      pkgs.jq
      pkgs.gitMinimal
      config.programs.ssh.package
    ];
    text = ''
      meta=$(nix flake metadata --json --refresh "$1")
      rev=$(jq -er .revision <<<"$meta")
      count=$(jq -er .revCount <<<"$meta")
      modified=$(jq -er .lastModified <<<"$meta")
      deployed=$(cat ${state}/revcount 2>/dev/null || echo 0)
      if [ "$count" -lt "$deployed" ]; then
        echo "Refusing $rev: it is older than the deployed release ($count commits, deployed $deployed)." >&2
        exit 1
      fi
      echo "$count" >/run/suveraen-upgrade/revcount
      echo "$rev" >/run/suveraen-upgrade/revision
      echo "$modified" >/run/suveraen-upgrade/lastmodified
      # When each followed input that the release locks was last changed, found by its name in the release's flake.nix.
      jq -c --argjson followed ${lib.escapeShellArg (builtins.toJSON cfg.followedInputs)} '
        .locks as $l
        | def node($path):
            reduce $path[] as $name ($l.root; $l.nodes[.].inputs[$name] | if type == "array" then node(.) else . end);
          [$followed[] as $i | (node([$i]) // empty) as $n | {key: $i, value: $l.nodes[$n].locked.lastModified}
            | select(.value != null)]
          | from_entries' <<<"$meta" >/run/suveraen-upgrade/inputs.json
      echo "$1&rev=$rev" >/run/suveraen-upgrade/flake
    '';
  };
in
{
  options.suveraen.upgrade = {
    staleAfterDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 14;
      description = ''
        Alert once a day when the configuration this host runs was committed longer ago than this. It catches releases
        that stopped coming as well as a branch someone keeps frozen.
      '';
    };

    revisionFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      default = "${state}/revision";
      description = "Where the host records the commit its last upgrade built, once it has upgraded.";
    };

    followedInputs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "nixpkgs" ];
      description = ''
        Inputs of the release, by their names in its flake.nix, that are meant to keep moving. While the configuration
        itself isn't old, the host alerts once a day when the release locks one of them at a revision older than
        staleAfterDays: the updates to the lock have stopped, or the branch it follows has come to its end. Inputs
        pinned on purpose, such as lanzaboote at its tag, don't belong here.
      '';
    };
  };

  # Every night the host switches to its configuration (named after its hostname) from suveraen.source.
  # Unencrypted hosts reboot by themselves when a new kernel needs it; encrypted ones send an alert instead,
  # since their disks then wait for the passphrase.
  config = lib.mkIf (flake != null) {
    system.autoUpgrade = {
      enable = true;
      # The service's script reads this unquoted, so it builds exactly the revision the resolve step checked.
      flake = ''"$(< /run/suveraen-upgrade/flake)"'';
      flags = [
        "-L"
      ];
      # Rebooting hosts (the watcher) go first, so they are back before the others' alerts arrive.
      dates = if canReboot then "02:30" else "04:00";
      randomizedDelaySec = "30min";
      allowReboot = canReboot;
      rebootWindow = lib.mkIf canReboot {
        lower = "02:30";
        upper = "03:45";
      };
    };

    systemd.services.nixos-upgrade = {
      serviceConfig = {
        RuntimeDirectory = "suveraen-upgrade";
        StateDirectory = "suveraen-upgrade";
      };
      preStart = "${lib.getExe resolve} ${lib.escapeShellArg flake}";
      postStart = "cp ${
        lib.concatMapStringsSep " " (file: "/run/suveraen-upgrade/${file}") [
          "revcount"
          "revision"
          "lastmodified"
          "inputs.json"
        ]
      } ${state}/";
    };

    systemd.services.release-age = {
      description = "Alert when this host's configuration, or what it locks, is old";
      startAt = "12:00";
      path = [ pkgs.jq ];
      serviceConfig.Type = "oneshot";
      script = ''
        # Nothing to compare before the first upgrade.
        [ -e ${state}/lastmodified ] || exit 0
        now=$(date +%s)
        modified=$(< ${state}/lastmodified)
        days=$(( (now - modified) / 86400 ))
        if [ "$days" -ge ${toString cfg.staleAfterDays} ]; then
          ${alert} "stale configuration" "The configuration this host runs dates from $(date -ud "@$modified" +%F), $days days ago."
          # What it locks is as old, and for the same reason.
          exit 0
        fi
        stale=$(jq -r --argjson now "$now" --argjson after ${toString cfg.staleAfterDays} '
          [to_entries[] | (($now - .value) / 86400 | floor) as $days | select($days >= $after)
            | "\(.key) from \(.value | todate[0:10]), \($days) days ago"]
          | join("; ")' ${state}/inputs.json)
        if [ -n "$stale" ]; then
          ${alert} "stale inputs" "The release this host runs locks $stale. Check update.yml, or move to the next NixOS release."
        fi
      '';
    };

    systemd.services.reboot-check = lib.mkIf (!canReboot) {
      description = "Alert when the running kernel is older than the installed one";
      wantedBy = [ "nixos-upgrade.service" ];
      after = [ "nixos-upgrade.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        booted=$(readlink /run/booted-system/{initrd,kernel,kernel-modules})
        installed=$(readlink /nix/var/nix/profiles/system/{initrd,kernel,kernel-modules})
        if [ "$booted" != "$installed" ]; then
          ${alert} "reboot needed" "A new kernel is installed. Reboot when convenient, then unlock the disks over SSH."
        fi
      '';
    };

    # An unsigned or older branch head makes the upgrade fail, which alerts.
    suveraen.alerts.units = [
      "nixos-upgrade"
      "release-age"
    ];
  };
}
