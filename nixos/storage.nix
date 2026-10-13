{ config, lib, ... }:
let
  cfg = config.suveraen.storage;
  zfs = config.boot.zfs.package;
  mirrored = lib.length cfg.systemDisks == 2;

  member = {
    type = "zfs";
    pool = "rpool";
  };

  # disko reads the passphrase from here while formatting; nixos-anywhere puts it there.
  luks = i: {
    type = "luks";
    name = "crypt-system${toString i}";
    passwordFile = "/tmp/disk.key";
    settings.allowDiscards = true;
    content = member;
  };

  esp =
    if mirrored then
      {
        type = "mdraid";
        name = "boot";
      }
    else
      bootFilesystem;

  bootFilesystem = {
    type = "filesystem";
    format = "vfat";
    mountpoint = "/boot";
    mountOptions = [ "umask=0077" ];
  };

  systemDisk = i: device: {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "1M";
          type = "EF02";
        };
        esp = {
          size = "1G";
          type = "EF00";
          content = esp;
        };
        system = {
          size = "100%";
          content = if cfg.encrypted then luks i else member;
        };
      };
    };
  };

  pool = datasets: {
    type = "zpool";
    mode = if mirrored then "mirror" else "";
    options = {
      ashift = "12";
      autotrim = "on";
    };
    rootFsOptions = {
      compression = "zstd";
      acltype = "posixacl";
      xattr = "sa";
      atime = "off";
      mountpoint = "none";
      canmount = "off";
    };
    datasets = datasets // {
      # Room to delete things when the pool is otherwise full.
      reserved = {
        type = "zfs_fs";
        options = {
          mountpoint = "none";
          refreservation = cfg.reserve;
        };
      };
    };
  };

  mounted = mountpoint: options: {
    type = "zfs_fs";
    inherit mountpoint;
    options = {
      mountpoint = "legacy";
    }
    // options;
  };

  diskNames = prefix: disks: lib.imap0 (i: _: "${prefix}${toString i}") disks;
in
{
  options.suveraen.storage = {
    systemDisks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [
        "/dev/disk/by-id/nvme-SAMSUNG_A"
        "/dev/disk/by-id/nvme-SAMSUNG_B"
      ];
      description = ''
        One disk, or two mirrored, for boot, the system and databases (pool `rpool`, mounted at /, /nix and /var).
        They are wiped on install. Other disks are left alone for the cluster's storage (Ceph).
      '';
    };

    encrypted = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Put the system pool on LUKS. The passphrase is typed over SSH at every boot, so such hosts never reboot by themselves.
        Hosts that must come back unattended, like the watcher, go without.
      '';
    };

    reserve = lib.mkOption {
      type = lib.types.str;
      default = "10G";
      description = "Space held back in the pool, so files can still be deleted when it is otherwise full.";
    };

    arcMax = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4 * 1024 * 1024 * 1024;
      defaultText = lib.literalExpression "4 * 1024 * 1024 * 1024";
      description = "Upper limit in bytes for ZFS's memory cache, leaving the rest to Ceph and the cluster's workloads.";
    };
  };

  config = {
    assertions = [
      {
        assertion = lib.elem (lib.length cfg.systemDisks) [
          1
          2
        ];
        message = "suveraen.storage.systemDisks needs one or two disks.";
      }
    ];

    disko.devices = {
      disk = lib.listToAttrs (
        lib.zipListsWith lib.nameValuePair (diskNames "system" cfg.systemDisks) (
          lib.imap0 systemDisk cfg.systemDisks
        )
      );

      # Metadata at the end, so firmware sees each half as a plain ESP.
      mdadm = lib.optionalAttrs mirrored {
        boot = {
          type = "mdadm";
          level = 1;
          metadata = "1.0";
          content = bootFilesystem;
        };
      };

      zpool.rpool = pool {
        root = mounted "/" { };
        nix = mounted "/nix" { };
        var = mounted "/var" { };
      };
    };

    # Both BIOS and UEFI boot; disko adds every disk with an EF02 partition to grub's devices.
    boot.loader.grub = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
      # /boot is FAT; the ZFS module would otherwise switch grub to an uncached ZFS build.
      zfsSupport = lib.mkForce false;
    };

    boot.supportedFilesystems.zfs = true;
    boot.kernelParams = [ "zfs.zfs_arc_max=${toString cfg.arcMax}" ];
    boot.zfs.forceImportRoot = false;
    # Unlocking over SSH takes longer than the import's own wait for the LUKS devices.
    boot.initrd.systemd.services.zfs-import-rpool = lib.mkIf cfg.encrypted {
      after = [ "cryptsetup.target" ];
      wants = [ "cryptsetup.target" ];
    };

    services.zfs = {
      autoScrub.enable = true;
      trim.enable = true;
    };

    services.sanoid = {
      enable = true;
      templates.local = {
        hourly = 24;
        daily = 14;
        monthly = 3;
        autosnap = true;
        autoprune = true;
      };
      datasets."rpool/var" = {
        useTemplate = [ "local" ];
        recursive = true;
      };
    };

    systemd.services.zfs-health = {
      description = "Check that every ZFS pool is healthy";
      serviceConfig.Type = "oneshot";
      script = ''
        status=$(${zfs}/sbin/zpool status -x)
        if [ "$status" != "all pools are healthy" ]; then
          echo "$status"
          ${lib.getExe config.suveraen.alerts.command} "ZFS pool unhealthy" "$status" 5
          exit 1
        fi
      '';
    };
    systemd.timers.zfs-health = {
      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = "hourly";
    };

    # zfs-health alerts by itself, at top priority.
    suveraen.alerts.units = [ "zfs-scrub" ];
  };
}
