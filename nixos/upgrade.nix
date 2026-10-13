{ config, lib, ... }:
let
  cfg = config.suveraen.upgrade;
  alert = lib.getExe config.suveraen.alerts.command;
  # An encrypted host would sit at the passphrase prompt after rebooting.
  canReboot = !config.suveraen.storage.encrypted;
in
{
  options.suveraen.upgrade.flake = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "github:owner/repo";
    description = ''
      Flake the host follows: every night it switches to that flake's configuration for its hostname.
      Unencrypted hosts reboot by themselves when a new kernel needs it; encrypted ones send an alert instead,
      since their disks then wait for the passphrase. null leaves updates to manual deploys.
    '';
  };

  config = lib.mkIf (cfg.flake != null) {
    system.autoUpgrade = {
      enable = true;
      inherit (cfg) flake;
      flags = [
        "--refresh"
        "-L"
      ];
      dates = "04:00";
      randomizedDelaySec = "30min";
      allowReboot = canReboot;
      rebootWindow = lib.mkIf canReboot {
        lower = "04:00";
        upper = "06:00";
      };
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

    suveraen.alerts.units = [ "nixos-upgrade" ];
  };
}
