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
    settings = {
      allowDiscards = true;
      # A wrong passphrase at boot asks again instead of giving up after three, which would need a hard reset.
      crypttabExtraOpts = [ "tries=0" ];
    };
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

  # kubernetes/platform/ceph lists this many OSD slots.
  maxSlots = 12;
  slots = lib.range 0 (cfg.ceph.dbSlots - 1);

  # Raw partitions for BlueStore's DB, one per OSD slot. ceph-volume formats them itself, and the cluster finds them
  # as /dev/disk/by-osd/osdN-db. On two system disks they lie on a RAID1 array over a partition of each: an OSD dies
  # with its DB, and with copies spread over the OSDs of one server, a disk taking half the DBs with it would take
  # every copy of some data.
  dbPartitions = lib.listToAttrs (
    map (
      slot:
      lib.nameValuePair "osd${toString slot}-db" {
        size = cfg.ceph.dbSize;
        label = "osd${toString slot}-db";
        priority = 1100 + slot;
      }
    ) slots
  );

  # Each disk's share of that array holds every DB, and room for the array's metadata (up to 128 MiB on large disks)
  # and the partition table on it.
  dbShare =
    let
      unit = lib.substring (lib.stringLength cfg.ceph.dbSize - 1) 1 cfg.ceph.dbSize;
      kib =
        lib.toInt (lib.removeSuffix unit cfg.ceph.dbSize)
        * {
          K = 1;
          M = 1024;
          G = 1024 * 1024;
          T = 1024 * 1024 * 1024;
        }
        .${unit};
    in
    {
      osd-db = {
        size = "${toString (cfg.ceph.dbSlots * kib + 256 * 1024)}K";
        priority = 1100;
        content = {
          type = "mdraid";
          name = "osd-db";
        };
      };
    };

  dbOnArray = mirrored && slots != [ ];

  systemDisk = i: device: {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions = (if dbOnArray then dbShare else dbPartitions) // {
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
        One disk, or two mirrored, for boot, the system and the cluster's own state (pool `rpool`), and the DBs of
        Ceph's OSDs. They are wiped on install. Other disks are left alone for Ceph (ceph.disks).
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

    ceph = {
      disks = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "/dev/disk/by-id/ata-HDD_A"
          "/dev/disk/by-id/ata-HDD_B"
        ];
        description = ''
          Disks Ceph takes as OSDs, in slot order. Slot N appears as /dev/disk/by-osd/osdN and keeps its BlueStore DB
          at /dev/disk/by-osd/osdN-db, which is how kubernetes/platform/ceph names them, for its ${toString maxSlots}
          slots. Wipe a disk before it is listed: Ceph skips disks that hold anything.
        '';
      };

      dbSlots = lib.mkOption {
        type = lib.types.ints.between 0 maxSlots;
        default = lib.length cfg.ceph.disks;
        defaultText = lib.literalExpression "length config.suveraen.storage.ceph.disks";
        description = ''
          BlueStore DB partitions made at install, on the system disk or mirrored over both. They can't be added later,
          so reserve one for every disk the machine may ever give Ceph.
        '';
      };

      dbSize = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[0-9]+[KMGT]");
        default = null;
        example = "150G";
        description = ''
          Size of each DB partition, about 1% of its disk. With two system disks each holds all of them, dbSlots times
          this size.
        '';
      };
    };

    containerdQuota = lib.mkOption {
      type = lib.types.str;
      default = "64G";
      description = "Most space container images and their writable layers may take.";
    };

    kubeletQuota = lib.mkOption {
      type = lib.types.str;
      default = "64G";
      description = "Most space pods' emptyDir volumes and writable state under /var/lib/kubelet may take.";
    };

    etcdReservation = lib.mkOption {
      type = lib.types.str;
      default = "8G";
      description = "Space kept for etcd and its snapshots, so it stays writable when pods fill the pool.";
    };

    rookReservation = lib.mkOption {
      type = lib.types.str;
      default = "8G";
      description = "Space kept for the Ceph monitors' stores under /var/lib/rook, which also hold the OSDs' disk keys.";
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
      {
        assertion = cfg.ceph.dbSlots >= lib.length cfg.ceph.disks;
        message = "suveraen.storage.ceph.dbSlots needs a DB partition for every disk in ceph.disks.";
      }
      {
        assertion = cfg.ceph.dbSlots == 0 || cfg.ceph.dbSize != null;
        message = "suveraen.storage.ceph.dbSize sets the size of the DB partitions.";
      }
      {
        assertion = lib.all (lib.hasPrefix "/dev/disk/") cfg.ceph.disks;
        message = "suveraen.storage.ceph.disks names disks by a stable link under /dev/disk/, such as by-id.";
      }
      {
        # Encrypted OSDs with their DB elsewhere are LVM volumes, which come back after a reboot only with lvm2's udev
        # rules on the host.
        assertion = cfg.ceph.disks == [ ] || (config.suveraen.cluster.enable && config.services.lvm.enable);
        message = "suveraen.storage.ceph.disks needs suveraen.cluster.enable and services.lvm.enable.";
      }
    ];

    disko.devices = {
      disk = lib.listToAttrs (
        lib.zipListsWith lib.nameValuePair (diskNames "system" cfg.systemDisks) (
          lib.imap0 systemDisk cfg.systemDisks
        )
      );

      mdadm =
        lib.optionalAttrs mirrored {
          # Metadata at the end, so firmware sees each half as a plain ESP.
          boot = {
            type = "mdadm";
            level = 1;
            metadata = "1.0";
            content = bootFilesystem;
          };
        }
        // lib.optionalAttrs dbOnArray {
          osd-db = {
            type = "mdadm";
            level = 1;
            content = {
              type = "gpt";
              partitions = dbPartitions;
            };
          };
        };

      # Apart from rpool/var and bounded, so a full disk of images or pods can't stop etcd or the monitors. Images and
      # pods' state go without snapshots.
      zpool.rpool = pool (
        {
          root = mounted "/" { };
          nix = mounted "/nix" { };
          var = mounted "/var" { };
        }
        // lib.optionalAttrs config.suveraen.cluster.enable {
          containerd = mounted "/var/lib/rancher/k3s/agent/containerd" { quota = cfg.containerdQuota; };
          kubelet = mounted "/var/lib/kubelet" { quota = cfg.kubeletQuota; };
          etcd = mounted "/var/lib/rancher/k3s/server/db" { reservation = cfg.etcdReservation; };
          rook = mounted "/var/lib/rook" { reservation = cfg.rookReservation; };
        }
      );
    };

    services.udev.extraRules =
      lib.concatImapStrings (i: disk: ''
        SUBSYSTEM=="block", SYMLINK=="${lib.removePrefix "/dev/" disk}", SYMLINK+="disk/by-osd/osd${toString (i - 1)}"
      '') cfg.ceph.disks
      # udev makes no by-partlabel links for partitions on an array.
      + ''
        SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_PART_ENTRY_NAME}=="osd[0-9]*-db", SYMLINK+="disk/by-osd/$env{ID_PART_ENTRY_NAME}"
      '';

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
      datasets = {
        "rpool/var" = {
          useTemplate = [ "local" ];
          recursive = true;
        };
        # The monitors' stores alone hold the keys to the OSDs' disks, and etcd the cluster's own state that Git can't
        # make anew.
        "rpool/rook" = lib.mkIf config.suveraen.cluster.enable { useTemplate = [ "local" ]; };
        "rpool/etcd" = lib.mkIf config.suveraen.cluster.enable { useTemplate = [ "local" ]; };
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
