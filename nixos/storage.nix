{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.suveraen.storage;
  zfs = config.boot.zfs.package;
  mirrored = lib.length cfg.systemDisks == 2;

  member = {
    type = "zfs";
    pool = "rpool";
  };

  # The system disks' LUKS volumes, in the order of systemDisks.
  volumes = lib.imap0 (i: _: "crypt-system${toString i}") cfg.systemDisks;

  # disko reads the passphrase from here while formatting; nixos-anywhere puts it there.
  passwordFile = "/tmp/disk.key";

  luks = i: {
    type = "luks";
    name = lib.elemAt volumes i;
    inherit passwordFile;
    settings = {
      allowDiscards = true;
      crypttabExtraOpts = [
        # A wrong passphrase at boot asks again instead of giving up after three, which would need a hard reset.
        "tries=0"
      ]
      # Only the volume this host was installed with opens, by its key's id. disko's script, which makes the volumes
      # these ids come from, is built without them; no system is (assertions).
      ++ lib.optional (cfg.volumeKeyIds != [ ]) "fixate-volume-key=${lib.elemAt cfg.volumeKeyIds i}";
    };
    content = member;
  };

  # The system disks' volumes as systemd-cryptsetup opened them, by their name and the UUID cryptsetup gives a LUKS2
  # mapping, which no logical volume of the same name has. rpool is imported from these alone.
  poolMembers = lib.concatMapStrings (name: ''
    SUBSYSTEM=="block", ENV{DM_NAME}=="${name}", ENV{DM_UUID}=="CRYPT-LUKS2-*-${name}", SYMLINK+="disk/rpool/${name}"
  '') volumes;

  # What fixate-volume-key compares: HMAC-SHA256 of "cryptsetup:<name>:<LUKS UUID>", keyed with the volume key, which
  # the header gives up for the passphrase. For each volume open now, in the order of systemDisks.
  keyIds = pkgs.writeShellApplication {
    name = "suveraen-volume-key-ids";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.cryptsetup
      pkgs.gnused
      pkgs.python3
    ];
    text = ''
      # From the terminal, or all of standard input, as disko reads its password file.
      if [ -t 0 ]; then
        IFS= read -rsp "Disk passphrase: " passphrase
        echo >&2
      else
        passphrase=$(cat)
      fi
      dir=$(mktemp -d -p /run)
      trap 'rm -rf "$dir"' EXIT
      volumes=(${lib.escapeShellArgs volumes})
      for name in "''${volumes[@]}"; do
        if ! status=$(cryptsetup status "$name"); then
          echo "$name is not open: open its volume under that name first." >&2
          exit 1
        fi
        device=$(sed -n 's/^ *device: *//p' <<<"$status")
        printf %s "$passphrase" | cryptsetup luksDump --dump-volume-key --batch-mode --key-file=- \
          --volume-key-file="$dir/$name" "$device" >/dev/null
        python3 -I -c 'import hashlib, hmac, sys; print(hmac.new(open(sys.argv[1], "rb").read(), sys.argv[2].encode(), hashlib.sha256).hexdigest())' \
          "$dir/$name" "cryptsetup:$name:$(cryptsetup luksUUID "$device")"
      done
    '';
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
  withDb = slots != [ ];

  # BlueStore's DBs, a logical volume per OSD slot, which the cluster finds as /dev/disk/by-osd/osdN-db. Volumes, not
  # partitions: ceph-volume 20.2 fails to prepare an encrypted OSD whose DB is a partition. Each fills a group of its
  # own on a partition of its own: Rook's OSD activation resizes the group its DB lies in from inside the pod, outside
  # the host's LVM locks, so OSDs starting together would tear a shared group's metadata, and a full group leaves it
  # nothing to grow. On two system disks the partitions lie on a RAID1 array over a partition of each: an OSD dies with
  # its DB, and with copies spread over the OSDs of one server, a disk taking half the DBs with it would take every copy
  # of some data.
  dbName = slot: "osd${toString slot}-db";

  dbKiB =
    let
      unit = lib.substring (lib.stringLength cfg.ceph.dbSize - 1) 1 cfg.ceph.dbSize;
    in
    lib.toInt (lib.removeSuffix unit cfg.ceph.dbSize)
    * {
      K = 1;
      M = 1024;
      G = 1024 * 1024;
      T = 1024 * 1024 * 1024;
    }
    .${unit};

  # Each with room for LVM's metadata and the rounding to whole extents.
  dbPartitionKiB = dbKiB + 8 * 1024;
  dbPartitions = lib.listToAttrs (
    map (
      slot:
      lib.nameValuePair (dbName slot) {
        size = "${toString dbPartitionKiB}K";
        priority = 1100 + slot;
        content = {
          type = "lvm_pv";
          vg = dbName slot;
        };
      }
    ) slots
  );

  # Each disk's share of that array holds every DB partition, and room for the array's metadata (up to 128 MiB on
  # large disks) and the partition table on it.
  dbShare = {
    osd-db = {
      size = "${toString (cfg.ceph.dbSlots * dbPartitionKiB + 256 * 1024)}K";
      priority = 1100;
      content = {
        type = "mdraid";
        name = "osd-db";
      };
    };
  };

  systemDisk = i: device: {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions =
        lib.optionalAttrs withDb (if mirrored then dbShare else dbPartitions)
        // lib.optionalAttrs (!cfg.encrypted) {
          bios = {
            size = "1M";
            type = "EF02";
          };
        }
        // {
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
    # At install, once every volume is made: the ids volumeKeyIds takes.
    postCreateHook = lib.optionalString cfg.encrypted "${lib.getExe keyIds} <${passwordFile}";
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

    secureBootKeys = lib.mkOption {
      type = lib.types.path;
      description = ''
        Directory with PK.auth, KEK.auth, db.auth and dbx.auth: the firmware's Secure Boot variables as this host
        enrolls them. They are copied to the boot partition, from where the boot menu enrolls them in setup mode: at
        install, and again after a firmware reset, which gives back the state the boot-time SSH host key is sealed in.
        Public data. Encrypted hosts only.
      '';
    };

    volumeKeyIds = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[0-9a-f]{64}");
      default = [ ];
      description = ''
        Ids of the system disks' volume keys, one per disk in the order of systemDisks. disko prints them at install
        once it made the volumes, before anything is built for the host, and `suveraen-volume-key-ids` prints them for
        the volumes open now, from their headers and the passphrase. The boot opens a system disk only if its volume
        has that key, which nobody without the passphrase can give a volume of their own, so a disk replaced in place
        needs its new id here before the next boot: a boot whose ids its disks don't have stops, and only a fix from
        outside it, such as from rescue, brings the host back. Public data. Required on encrypted hosts.
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
          BlueStore DB volumes made at install, on the system disk or mirrored over both. There is room for these
          alone, so reserve one for every disk the machine may ever give Ceph.
        '';
      };

      dbSize = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[0-9]+[KMGT]");
        default = null;
        example = "150G";
        description = ''
          Least size of each DB volume, about 1% of its disk: each fills a partition 8 MiB larger, less LVM's
          metadata. With two system disks each holds all of them, dbSlots times this size.
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
        assertion = cfg.encrypted -> lib.length cfg.volumeKeyIds == lib.length cfg.systemDisks;
        message = "Encrypted hosts name one id per system disk in suveraen.storage.volumeKeyIds, as disko prints them at install.";
      }
      {
        assertion = cfg.ceph.dbSlots >= lib.length cfg.ceph.disks;
        message = "suveraen.storage.ceph.dbSlots needs a DB volume for every disk in ceph.disks.";
      }
      {
        assertion = cfg.ceph.dbSlots == 0 || cfg.ceph.dbSize != null;
        message = "suveraen.storage.ceph.dbSize sets the size of the DB volumes.";
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
        // lib.optionalAttrs (mirrored && withDb) {
          osd-db = {
            type = "mdadm";
            level = 1;
            # An unclean stop then resyncs only what was written since, not the whole array.
            extraArgs = [ "--bitmap=internal" ];
            content = {
              type = "gpt";
              partitions = dbPartitions;
            };
          };
        };

      lvm_vg = lib.listToAttrs (
        map (
          slot:
          lib.nameValuePair (dbName slot) {
            type = "lvm_vg";
            lvs.db.size = "100%";
          }
        ) slots
      );

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
      + lib.optionalString withDb ''
        SUBSYSTEM=="block", ENV{DM_VG_NAME}=="osd[0-9]*-db", ENV{DM_LV_NAME}=="db", SYMLINK+="disk/by-osd/$env{DM_VG_NAME}"
      ''
      + lib.optionalString cfg.encrypted poolMembers;
    boot.initrd.services.udev.rules = lib.mkIf cfg.encrypted poolMembers;

    # ceph-volume, in Rook's OSD prepare pods, runs LVM's commands on the host through nsenter, found by the
    # container's PATH, which names none of NixOS's directories.
    systemd.tmpfiles.rules = lib.optionals (cfg.ceph.disks != [ ]) [
      "L+ /usr/sbin - - - - ${lib.getBin config.services.lvm.package}/bin"
    ];

    # Both BIOS and UEFI boot; disko adds every disk with an EF02 partition to grub's devices.
    boot.loader.grub = lib.mkIf (!cfg.encrypted) {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
      # /boot is FAT; the ZFS module would otherwise switch grub to an uncached ZFS build.
      zfsSupport = lib.mkForce false;
    };

    # UEFI under Secure Boot with this host's own keys, so the firmware starts only boot files this host signed, and the
    # TPM releases the boot-time SSH host key to them alone (unlock.nix). The signing key stays on the encrypted pool.
    boot.lanzaboote = lib.mkIf cfg.encrypted {
      enable = true;
      pkiBundle = lib.mkDefault "/var/lib/sbctl";
      # Nightly upgrades keep a month of generations, whose kernels and initrds would outgrow the 1G boot partition.
      configurationLimit = lib.mkDefault 10;
      settings.editor = false;
    };

    environment.systemPackages = lib.mkIf cfg.encrypted [ keyIds ];

    # "auto": a VM enrolls this set by itself; real hardware only from the boot menu (systemd-boot's if-safe default).
    # lanzaboote's autoEnrollKeys would need PK's and KEK's private keys on the host, and enrolls no dbx.
    systemd.services.secure-boot-keys = lib.mkIf cfg.encrypted {
      description = "Copy the Secure Boot keys to the boot partition for enrolling them";
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = "/boot";
      restartTriggers = [ cfg.secureBootKeys ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        rm -rf /boot/loader/keys/auto
        mkdir -p /boot/loader/keys
        cp -r ${cfg.secureBootKeys} /boot/loader/keys/auto
      '';
    };

    boot.supportedFilesystems.zfs = true;
    boot.kernelParams = [ "zfs.zfs_arc_max=${toString cfg.arcMax}" ];
    boot.zfs.forceImportRoot = false;
    # rpool is imported only once every system disk opened as this host's own volume, and from those alone: the signed
    # boot chain takes no pool of that name from anywhere else. Unlocking over SSH also takes longer than the import's
    # own wait for its devices.
    boot.zfs.pools.rpool = lib.mkIf cfg.encrypted { devNodes = "/dev/disk/rpool"; };
    boot.initrd.systemd.services.zfs-import-rpool = lib.mkIf cfg.encrypted (
      let
        opened = map (name: "systemd-cryptsetup@${utils.escapeSystemdPath name}.service") volumes;
        links = map (name: "/dev/disk/rpool/${name}") volumes;
      in
      {
        requires = opened;
        after = opened;
        # systemd-cryptsetup passes over a volume whose name a device already has, which then gets no link.
        preStart = "udevadm wait --timeout=60 ${toString links}";
      }
    );

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
