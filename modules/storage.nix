{ config, lib, ... }:
let
  cfg = config.suveraen.storage;
  zfs = config.boot.zfs.package;
  hasBulk = cfg.bulkDisks != [ ];

  # disko reads the passphrase from here while formatting; nixos-anywhere puts it there.
  luks = name: allowDiscards: pool: {
    type = "luks";
    inherit name;
    passwordFile = "/tmp/disk.key";
    settings = lib.optionalAttrs allowDiscards { allowDiscards = true; };
    content = {
      type = "zfs";
      inherit pool;
    };
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
          content = {
            type = "mdraid";
            name = "boot";
          };
        };
        crypt = {
          size = "100%";
          content = luks "crypt-system${toString i}" true "rpool";
        };
      };
    };
  };

  bulkDisk = i: device: {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions.crypt = {
        size = "100%";
        content = luks "crypt-bulk${toString i}" false "tank";
      };
    };
  };

  pool = datasets: {
    type = "zpool";
    mode = "mirror";
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
          refreservation = "10G";
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
      description = "The two disks mirrored for boot, the system and databases (pool `rpool`, mounted at /, /nix and /var). They are wiped on install.";
    };

    bulkDisks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Two disks mirrored for files and photos (pool `tank`, mounted at /srv), or none. They are wiped on install.";
    };
  };

  config = {
    assertions = [
      {
        assertion = lib.length cfg.systemDisks == 2;
        message = "suveraen.storage.systemDisks needs exactly two disks.";
      }
      {
        assertion = lib.elem (lib.length cfg.bulkDisks) [
          0
          2
        ];
        message = "suveraen.storage.bulkDisks needs two disks, or none.";
      }
    ];

    disko.devices = {
      disk =
        lib.listToAttrs (
          lib.zipListsWith lib.nameValuePair (diskNames "system" cfg.systemDisks) (
            lib.imap0 systemDisk cfg.systemDisks
          )
        )
        // lib.listToAttrs (
          lib.zipListsWith lib.nameValuePair (diskNames "bulk" cfg.bulkDisks) (
            lib.imap0 bulkDisk cfg.bulkDisks
          )
        );

      # Metadata at the end, so firmware sees each half as a plain ESP.
      mdadm.boot = {
        type = "mdadm";
        level = 1;
        metadata = "1.0";
        content = {
          type = "filesystem";
          format = "vfat";
          mountpoint = "/boot";
          mountOptions = [ "umask=0077" ];
        };
      };

      zpool = {
        rpool = pool {
          root = mounted "/" { };
          nix = mounted "/nix" { };
          var = mounted "/var" { };
        };
      }
      // lib.optionalAttrs hasBulk {
        tank = pool {
          srv = mounted "/srv" { recordsize = "1M"; };
        };
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
    boot.zfs.forceImportRoot = false;
    # The pool sits on LUKS, and unlocking over SSH takes longer than the import's own wait.
    boot.initrd.systemd.services.zfs-import-rpool = {
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
      datasets = {
        "rpool/var" = {
          useTemplate = [ "local" ];
          recursive = true;
        };
      }
      // lib.optionalAttrs hasBulk {
        "tank/srv" = {
          useTemplate = [ "local" ];
          recursive = true;
        };
      };
    };

    systemd.services.zfs-health = {
      description = "Check that every ZFS pool is healthy";
      serviceConfig.Type = "oneshot";
      script = ''
        status=$(${zfs}/sbin/zpool status -x)
        if [ "$status" != "all pools are healthy" ]; then
          echo "$status"
          exit 1
        fi
      '';
    };
    systemd.timers.zfs-health = {
      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = "hourly";
    };

    suveraen.alerts.units = [
      "zfs-health"
      "zfs-scrub"
    ];
  };
}
