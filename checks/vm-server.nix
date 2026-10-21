# A cluster server as a node of a NixOS test: it boots from its own plain disk, so there's nothing to unlock,
# reaches the outside through eth0 and its peers on eth1, and loads k3s's own images from the release tarball. Three
# empty disks stand in for Ceph's, and two more for the system disks' DB partitions.
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
  half = lib.length dbDisks;
in
{
  virtualisation.emptyDiskImages = map (serial: {
    size = 10240;
    driveConfig.deviceExtraOpts.serial = serial;
  }) (hdds ++ dbDisks);

  # What disko makes on a real server's system disks, slot by slot on alternate disks.
  systemd.services.osd-db-partitions = {
    description = "Make the DB partitions of Ceph's OSDs";
    wantedBy = [ "k3s.service" ];
    before = [ "k3s.service" ];
    path = [
      pkgs.gptfdisk
      config.systemd.package
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      udevadm wait --timeout=60 ${lib.concatMapStringsSep " " disk dbDisks}
    ''
    + lib.concatMapStrings (
      slot:
      let
        label = "osd${toString slot}-db";
        number = toString (slot / half + 1);
      in
      ''
        [ -e /dev/disk/by-partlabel/${label} ] \
          || sgdisk --new=${number}:0:+${ceph.dbSize} --change-name=${number}:${label} ${disk (lib.elemAt dbDisks (lib.mod slot half))}
      ''
    ) slots
    + ''
      udevadm settle
      udevadm wait --timeout=60 ${lib.concatMapStringsSep " " (slot: "/dev/disk/by-partlabel/osd${toString slot}-db") slots}
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
