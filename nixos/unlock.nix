{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.unlock;
  alert = lib.getExe config.suveraen.alerts.command;
  name = "ssh_host_ed25519_key";
  # In the initrd, which the signed boot stub carries by hash.
  sealed = "/etc/ssh/${name}.cred";
  efivars = "/sys/firmware/efi/efivars";
  global = "8be4df61-93ca-11d2-aa0d-00e098032b8c";
  images = "d719b2cb-3d3a-4596-a3bc-dad00e67656f";
  bootDevice = config.fileSystems."/boot".device;
  mirrored = lib.hasPrefix "/dev/md" bootDevice;

  # TPM2_ReadClock sent raw, so the initrd needs no TPM tools; the kernel takes a command only in one write, and printf
  # alone splits this one at its 0x0a byte. Prints the boot count (resetCount), the restarts that hid boots from it
  # (restartCount) and the start of PCR 0.
  tpmClock = ''
    tpm_clock() {
      local r pcr0
      r=$(exec 3<>/dev/tpmrm0 \
        && printf '\x80\x01\x00\x00\x00\x0a\x00\x00\x01\x81' | dd iflag=fullblock bs=10 count=1 status=none >&3 \
        && od -An -v -tx1 -N35 <&3 | tr -d ' \n') || return 1
      [ "''${#r}" = 70 ] && [ "''${r:12:8}" = 00000000 ] || return 1
      read -r pcr0 </sys/class/tpm/tpm0/pcr-sha256/0 || return 1
      echo "$((16#''${r:52:8})) $((16#''${r:60:8})) ''${pcr0:0:12}"
    }
  '';

  # Advice for the unlocker, who decides: it never blocks the prompt.
  shell = pkgs.writeShellScript "suveraen-unlock-shell" ''
    ${tpmClock}
    if out=$(tpm_clock); then
      read -r boot restarts firmware <<<"$out"
      echo "TPM boot $boot, restarts $restarts, firmware $firmware"
      [ "$restarts" = 0 ] || echo "STOP: a TPM restart can hide a boot from this count. Don't type before the cause is known."
    else
      echo "STOP: the TPM's boot count can't be read. Don't type before the cause is known."
    fi
    exec /bin/systemd-tty-ask-password-agent
  '';

  # The boot menu's enrollment files must give back exactly the variables the key is sealed under; the firmware also
  # measures dbt, and maybe dbr, which the boot menu never writes.
  enrolled = ''
    enrolled() {
      local v f len
      if [ -e ${efivars}/dbt-${images} ] || [ -e ${efivars}/dbr-${images} ]; then
        return 1
      fi
      for v in PK:${global} KEK:${global} db:${images} dbx:${images}; do
        f=/boot/loader/keys/auto/''${v%%:*}.auth
        [ -e "$f" ] || return 1
        len=$(od -An -tu4 -j16 -N4 "$f")
        cmp -s <(tail -c +$((17 + len)) "$f") <(tail -c +5 "${efivars}/''${v%%:*}-''${v#*:}") || return 1
      done
    }
  '';

  seal = pkgs.writeShellApplication {
    name = "suveraen-unlock-seal";
    runtimeInputs = [
      config.systemd.package
      config.programs.ssh.package
      pkgs.coreutils
      pkgs.diffutils
    ];
    text = ''
      ${enrolled}
      # A firmware variable's value, after its four bytes of attributes.
      flag() {
        od -An -tu1 -j4 -N1 "${efivars}/$1-${global}" | tr -d ' '
      }
      zero() {
        local v
        v=$(cat "/sys/class/tpm/tpm0/pcr-sha256/$1") && [ -n "$v" ] && [ -z "''${v//0/}" ]
      }
      if [ "$(flag SecureBoot)" != 1 ] || [ "$(flag SetupMode)" != 0 ]; then
        echo "Secure Boot is not on with enrolled keys." >&2
        exit 1
      fi
      if ! zero 12 || ! zero 13; then
        echo "This boot loaded credentials or extensions from the boot partition: remove them and reboot first." >&2
        exit 1
      fi
      if ! enrolled; then
        echo "The firmware's Secure Boot keys don't match /boot/loader/keys/auto, or it also holds dbt or dbr." >&2
        exit 1
      fi
      dir=$(mktemp -d -p /run)
      trap 'rm -rf "$dir"' EXIT
      ssh-keygen -q -t ed25519 -N "" -C "" -f "$dir/key"
      # Secure Boot state and keys (7), and nothing from the ESP: credentials (12), extensions (13).
      systemd-creds encrypt --with-key=tpm2 --tpm2-pcrs=7+12+13 --name=${name} "$dir/key" "$dir/key.cred"
      systemd-creds decrypt --name=${name} "$dir/key.cred" - | cmp -s - "$dir/key"
      cat "$dir/key.cred"
      cat "$dir/key.pub" >&2
    '';
  };

  # What the next boot needs doesn't change while the system runs, so what opens now opens then. It alerts on what it
  # finds by itself and exits 0; failing means the check itself broke.
  check = {
    after = [
      "tpm2.target"
      "secure-boot-keys.service"
    ];
    unitConfig.RequiresMountsFor = "/boot";
    path = [ pkgs.diffutils ] ++ lib.optional mirrored pkgs.mdadm;
    script = ''
      ${enrolled}
      systemd-analyze pcrs 0 1 2 3 4 5 7 12 13 --no-pager || true
      problems=()
      ${
        if cfg.sealedHostKey != null then
          ''
            systemd-creds decrypt --name=${name} ${cfg.sealedHostKey} - >/dev/null \
              || problems+=("The boot-time SSH host key doesn't open in this state with this generation's systemd, so the next boot won't offer SSH unlock.")
          ''
        else
          ''
            problems+=("The boot-time SSH server answers with a plaintext key from the boot partition: seal a key and switch to it.")
          ''
      }
      enrolled \
        || problems+=("The firmware's Secure Boot keys don't match /boot/loader/keys/auto, or it also holds dbt or dbr: the boot menu couldn't undo a firmware reset.")
      # The firmware finds an image's .extra directory whatever the case of its name; the stub takes .cred exactly.
      [ -z "$(find /boot/loader/credentials /boot/EFI/Linux -maxdepth 1 \( -name '*.cred' -o -iname '*.extra' \) 2>/dev/null)" ] \
        || problems+=("The boot partition holds files the boot stub would hand to the initrd.")
      [ -z "$(find /boot/loader/entries -type f 2>/dev/null)" ] \
        || problems+=("The boot partition holds boot entries this system didn't write.")
      [ -z "$(find /boot/loader/keys -mindepth 1 -maxdepth 1 ! -name auto 2>/dev/null)" ] \
        || problems+=("The boot partition offers Secure Boot keys other than auto.")
      ${lib.optionalString mirrored ''
        [ ! -e /boot/loader/random-seed ] \
          || problems+=("/boot/loader/random-seed exists: the boot loader rewrites it on one half of the mirrored boot partition.")
        md=/sys/block/$(basename "$(readlink -f ${bootDevice})")/md
        # Something that wrote to one half from outside the array would boot from that half unseen; while the array
        # resyncs, mdadm's own alerts speak.
        if [ "$(cat "$md/sync_action")" = idle ]; then
          echo check >"$md/sync_action"
          mdadm --wait ${bootDevice} || true
          [ "$(cat "$md/mismatch_cnt")" = 0 ] \
            || problems+=("The two halves of the boot partition differ.")
        fi
      ''}
      if [ ''${#problems[@]} -gt 0 ]; then
        printf '%s\n' "''${problems[@]}"
        ${alert} "boot unlock at risk" "$(printf '%s\n' "''${problems[@]}")" 5
      fi
    '';
  };
in
{
  options.suveraen.unlock = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 2222;
      description = "Port of the SSH server that runs during boot to take the disk passphrase.";
    };

    keys = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-z0-9@.-]+ [A-Za-z0-9+/=]+( [[:print:]]*)?");
      default = [ ];
      description = ''
        SSH public keys that may only answer the passphrase prompt at boot, for someone who should be able to unlock
        the disks without getting into the running system. Plain keys, without options of their own.
      '';
    };

    sealedHostKey = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Host key of the boot-time SSH server as `suveraen-unlock-seal` prints it on this host (its public key goes to
        standard error): sealed to the host's TPM, so only a boot chain signed with this host's key opens it, while
        Secure Boot holds the keys it was sealed under. The system that chain boots opens it too, and it boots only
        from this host's own volumes (suveraen.storage.volumeKeyIds). Root on the running system can take it, and so
        can whoever gets the TPM's secrets out of it, and a copy of all the host's disks put back whole boots as the
        host did when it was taken, with the key it held then. It is ciphertext and may be committed.
      '';
    };

    transitionHostKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/etc/secrets/initrd/ssh_host_ed25519_key";
      description = ''
        Host key file on this host for the boot-time SSH server while a sealed key is made or replaced: at install, or
        around a firmware update that clears the TPM. The boot loader writes it to the boot partition unencrypted, so
        whoever reads that partition can answer in this server's place to anyone who still trusts it; every boot
        alerts while it is set. The boot loader writes every generation it keeps anew at each switch and fails without
        the file, so it stays until the last generation that used it is gone. Never the system's own host key.
      '';
    };

    bootsPerReboot = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = ''
        How much the TPM's boot count grows over one reboot of this machine, which depends on its firmware. A count
        that grew by more since the last unlock alerts as boots in between that never unlocked.
      '';
    };
  };

  config = lib.mkIf config.suveraen.storage.encrypted (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = (cfg.sealedHostKey == null) != (cfg.transitionHostKey == null);
            message = "Encrypted hosts unlock over SSH with exactly one of suveraen.unlock.sealedHostKey and transitionHostKey.";
          }
          {
            assertion =
              lib.attrValues config.boot.initrd.secrets
              == lib.optional (cfg.transitionHostKey != null) cfg.transitionHostKey;
            message = "Encrypted hosts keep secrets out of the initrd, except a transition host key: the boot loader writes them to the boot partition in plaintext.";
          }
        ];

        # Credentials from the ESP or the firmware's tables would otherwise reach the signed initrd and the system.
        boot.kernelParams = [ "systemd.import_credentials=no" ];

        boot.initrd.network = {
          enable = true;
          ssh = {
            enable = true;
            inherit (cfg) port;
            authorizedKeys = config.suveraen.adminKeys ++ map (key: "restrict,pty ${key}") cfg.keys;
          };
        };

        # Logging in shows the TPM's boot count and asks for the passphrase straight away.
        boot.initrd.systemd.extraBin.suveraen-unlock-shell = shell;
        boot.initrd.systemd.users.root.shell = "/bin/suveraen-unlock-shell";
        # Ordering alone: tpm2.target is part of the boot where the firmware reports a TPM, so a box without one
        # doesn't wait for it.
        boot.initrd.systemd.services.sshd.after = [ "tpm2.target" ];

        environment.systemPackages = [ seal ];

        systemd.services.unlock-key-check = lib.mkMerge [
          check
          {
            description = "Check that the next boot can open the boot-time SSH host key";
            wantedBy = [ "multi-user.target" ];
            # Once the boot is done, which an alert that takes its time doesn't hold up.
            after = [ "multi-user.target" ];
            # Once per boot: each switch to a new generation starts multi-user.target again.
            restartIfChanged = false;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
          }
        ];

        # The unlocker saw these values before typing; this posts them for everyone who reads the alerts, against the
        # last unlock's.
        systemd.services.boot-count = {
          description = "Post the TPM's boot count once the disks are unlocked";
          wantedBy = [ "multi-user.target" ];
          after = [
            "multi-user.target"
            "tpm2.target"
          ];
          # Once per boot, as unlock-key-check.
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StateDirectory = "boot-count";
          };
          script = ''
            ${tpmClock}
            if ! out=$(tpm_clock); then
              echo "The TPM's boot count can't be read."
              exit 1
            fi
            read -r boot restarts firmware <<<"$out"
            message="TPM boot $boot, restarts $restarts, firmware $firmware."
            priority=2
            note() {
              message+=" $2"
              if [ "$1" -gt "$priority" ]; then priority=$1; fi
            }
            if [ -e "$STATE_DIRECTORY/last" ]; then
              read -r last_boot _ last_firmware <"$STATE_DIRECTORY/last"
              if [ "$boot" -lt "$last_boot" ]; then
                note 5 "The boot count went down since the last unlock, at boot $last_boot: the TPM was cleared, or its state rolled back."
              elif [ "$boot" -gt $((last_boot + ${toString cfg.bootsPerReboot})) ]; then
                note 5 "$((boot - last_boot)) boots since the last unlock, at boot $last_boot: the machine booted in between without unlocking."
              fi
              [ "$firmware" = "$last_firmware" ] \
                || note 4 "The firmware changed since the last unlock, from $last_firmware."
            fi
            [ "$restarts" = 0 ] || note 5 "A TPM restart can hide a boot from this count."
            ${alert} "disks unlocked" "$message" "$priority"
            echo "$out" >"$STATE_DIRECTORY/last"
          '';
        };

        suveraen.alerts.units = [
          "unlock-key-check"
          "boot-count"
        ];
      }

      (lib.mkIf (cfg.transitionHostKey != null) {
        boot.initrd.network.ssh.hostKeys = [ cfg.transitionHostKey ];
      })

      (lib.mkIf (cfg.sealedHostKey != null) {
        boot.initrd.network.ssh = {
          ignoreEmptyHostKeys = true;
          extraConfig = "HostKey /run/credentials/sshd.service/${name}";
        };
        boot.initrd.systemd.contents.${sealed}.source = cfg.sealedHostKey;
        # A key that doesn't open fails sshd, which leaves nothing listening.
        boot.initrd.systemd.services.sshd = {
          wants = [ "tpm2.target" ];
          serviceConfig.LoadCredentialEncrypted = "${name}:${sealed}";
        };

        # The upgraded generation's systemd opens the key in the state the next boot will be in. No target wants it,
        # so the switch inside the upgrade doesn't wait on it.
        systemd.services.unlock-key-recheck = lib.mkMerge [
          check
          {
            description = "Check that the upgraded system's next boot can open the boot-time SSH host key";
            wantedBy = [ "nixos-upgrade.service" ];
            after = [ "nixos-upgrade.service" ];
            serviceConfig.Type = "oneshot";
          }
        ];
        suveraen.alerts.units = [ "unlock-key-recheck" ];
      })
    ]
  );
}
