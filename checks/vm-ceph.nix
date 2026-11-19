# Ceph's disks for a cluster server that is a node of a NixOS test: three empty disks stand in for Ceph's, and two more
# for the system disks' share of the DB array.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  hdds = [
    "hdd0"
    "hdd1"
    "hdd2"
  ];
  dbDisks = [
    "db0"
    "db1"
  ];
  disk = serial: "/dev/disk/by-id/virtio-${serial}";
  ceph = config.suveraen.storage.ceph;
  slots = lib.range 0 (ceph.dbSlots - 1);
  members = lib.concatMapStringsSep " " disk dbDisks;
  # The partition disko gives a slot's DB on the array, which nixos/storage.nix names as its volume group.
  name = slot: "osd${toString slot}-db";
  part = slot: config.disko.devices.mdadm.osd-db.content.partitions.${name slot};
in
{
  virtualisation.emptyDiskImages = map (serial: {
    size = 10240;
    driveConfig.deviceExtraOpts.serial = serial;
    # The DB array's first sync copies a whole disk of zeros, which QEMU would otherwise store on the host's disk.
    driveConfig.driveExtraOpts.detect-zeroes = "on";
  }) (hdds ++ dbDisks);

  # What disko makes on a real server's two system disks: a RAID1 array over both, on it a partition per slot at the
  # size disko gives it, and on each a volume group that a single logical volume fills.
  systemd.services.osd-db-volumes = {
    description = "Make the DB volumes of Ceph's OSDs";
    wantedBy = [ "k3s.service" ];
    before = [ "k3s.service" ];
    path = [
      pkgs.gptfdisk
      pkgs.mdadm
      config.services.lvm.package
      config.systemd.package
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      udevadm wait --timeout=60 ${members}
      if ! mdadm --examine ${disk (lib.head dbDisks)} >/dev/null 2>&1; then
        echo y | mdadm --create /dev/md/osd-db --run --level=1 --raid-devices=2 --bitmap=internal --homehost=any ${members}
        udevadm settle
        sgdisk --align-end ${
          lib.concatMapStringsSep " " (
            slot: "--new=${toString (part slot)._index}:0:${(part slot).end}"
          ) slots
        } /dev/md/osd-db
        udevadm settle
        ${lib.concatMapStrings (slot: ''
          pvcreate --yes ${(part slot).device}
          vgcreate ${name slot} ${(part slot).device}
          lvcreate --yes -l 100%FREE -n db ${name slot}
        '') slots}
      fi
      udevadm settle
      [ -e /dev/md/osd-db ] || mdadm --assemble /dev/md/osd-db ${members}
      udevadm settle
      udevadm wait --timeout=60 ${
        lib.concatMapStringsSep " " (slot: "/dev/disk/by-osd/osd${toString slot}-db") slots
      }
    '';
  };

  suveraen.storage.ceph = {
    disks = map disk hdds;
    dbSize = "3G";
  };
}
