# A cluster server as a node of a NixOS test: it boots from its own plain disk, so there's nothing to unlock,
# reaches the outside through eth0 and its peers on eth1, and loads k3s's own images from the release tarball. Three
# empty disks stand in for Ceph's, and two more for the system disks' share of the DB array.
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
        echo y | mdadm --create /dev/md/osd-db --run --level=1 --raid-devices=2 --homehost=any ${members}
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

  boot.initrd.network.enable = lib.mkForce false;

  # The test network has no IPv6 router; give the node an address and a route.
  networking.interfaces.eth1.ipv6 = {
    addresses = [
      {
        address = "fd00::2";
        prefixLength = 64;
      }
    ];
    routes = [
      {
        address = "::";
        prefixLength = 0;
        via = "fd00::1";
      }
    ];
  };

  services.k3s.images = [ config.services.k3s.package.airgap-images ];
  # With this file k3s remembers what it imported, rather than unpacking the tarball again on every start.
  systemd.tmpfiles.rules = [ "f /var/lib/rancher/k3s/agent/images/.cache.json" ];

  # The provider and key that encrypted each Secret, as etcd holds them.
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "secret-prefixes";
      runtimeInputs = [ pkgs.etcd ];
      text = ''
        tls=/var/lib/rancher/k3s/server/tls/etcd
        get() {
          etcdctl --endpoints=https://127.0.0.1:2379 --cacert="$tls/server-ca.crt" --cert="$tls/client.crt" \
            --key="$tls/client.key" get "$@"
        }
        value=$(mktemp)
        get /registry/secrets/ --prefix --keys-only | grep . | while read -r key; do
          get "$key" --print-value-only >"$value"
          head -c 34 "$value"
          echo
        done | sort -u
      '';
    })
  ];

  networking.hostId = "0400bdef";
  system.stateVersion = "26.05";

  suveraen = {
    storage = {
      systemDisks = [
        "/dev/disk/by-id/test-0"
        "/dev/disk/by-id/test-1"
      ];
      ceph = {
        disks = map disk hdds;
        dbSize = "3G";
      };
    };
    # "en*" would also match eth1, the test network, through its alternative names.
    network.interface = "eth0";
    cluster = {
      enable = true;
      tokenFile = toString (pkgs.writeText "k3s-token" "suveraen-test-token");
      nodeIP = [
        config.networking.primaryIPAddress
        "fd00::2"
      ];
    };
  };
}
