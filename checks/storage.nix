# A server's disk layout as disko installs it on two blank disks, booted: BlueStore DB partitions for Ceph's OSDs lie on
# a RAID1 array over both system disks, at their size and with nothing on them, and all stay readable when one disk
# fails; k3s's and the monitors' datasets are bounded or reserved as set and mounted outside rpool/var; and
# containerd's dataset takes overlay mounts, so k3s keeps its overlayfs snapshotter there.
{ lib, pkgs, ... }:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  mib = n: toString (n * 1024 * 1024);
in
{
  nixpkgs.hostPlatform = "x86_64-linux";
  networking.hostName = "storage";
  networking.hostId = "0400bdef";
  system.stateVersion = "26.05";

  # Only the layout is tested.
  systemd.services.k3s.wantedBy = lib.mkForce [ ];

  suveraen = {
    adminKeys = [ keys.snakeOilEd25519PublicKey ];
    # disko's test disks are 4 GiB each.
    storage = {
      systemDisks = [
        "/dev/disk/by-id/test-0"
        "/dev/disk/by-id/test-1"
      ];
      encrypted = false;
      reserve = "64M";
      ceph = {
        disks = [
          "/dev/disk/by-id/test-hdd-0"
          "/dev/disk/by-id/test-hdd-1"
        ];
        dbSlots = 4;
        dbSize = "64M";
      };
      containerdQuota = "512M";
      kubeletQuota = "256M";
      etcdReservation = "128M";
      rookReservation = "64M";
    };
    network.interface = "eth0";
    source.repository = "https://example.org/suveraen.git";
    cluster = {
      enable = true;
      path = "./kubernetes/clusters/example";
      nodeIP = [
        "192.0.2.10"
        "2001:db8::10"
      ];
      tokenFile = "/run/secrets/k3s-token";
    };
    alerts = {
      urlFile = "/run/secrets/alerts-url";
      tokenFile = "/run/secrets/alerts-token";
      smart = false;
    };
  };

  # Runs on the installed system once it has booted, from vda and vdb.
  disko.tests.extraChecks = ''
    machine.succeed("zpool status rpool | grep -qw mirror-0")
    machine.succeed("mdadm --detail /dev/md/osd-db | grep -Eq 'Raid Level : raid1'")
    parts = [f"/dev/disk/by-osd/osd{slot}-db" for slot in range(4)]
    for part in parts:
        # Below it, the array and both disks.
        below = machine.succeed(f"lsblk -snro NAME,TYPE $(readlink -f {part})").split("\n")
        assert any(line.endswith(" raid1") for line in below), below
        for disk in ["vda", "vdb"]:
            assert f"{disk} disk" in below, (part, below)
        machine.succeed(f"test $(lsblk -bno SIZE {part}) = ${mib 64}")
        machine.succeed(f"test -z \"$(lsblk -no FSTYPE {part})\"")
    machine.fail("test -e /dev/disk/by-osd/osd4-db")
    machine.succeed("mdadm /dev/md/osd-db --fail $(mdadm --detail /dev/md/osd-db | grep -o '/dev/vdb[0-9]*')")
    machine.succeed("mdadm --detail /dev/md/osd-db | grep -q degraded")
    for part in parts:
        machine.succeed(f"dd if={part} of=/dev/null bs=1M count=1 iflag=direct")

    for dataset, prop, value, path in [
        ("containerd", "quota", ${mib 512}, "/var/lib/rancher/k3s/agent/containerd"),
        ("kubelet", "quota", ${mib 256}, "/var/lib/kubelet"),
        ("etcd", "reservation", ${mib 128}, "/var/lib/rancher/k3s/server/db"),
        ("rook", "reservation", ${mib 64}, "/var/lib/rook"),
    ]:
        machine.succeed(f"test $(zfs get -Hpo value {prop} rpool/{dataset}) = {value}")
        machine.succeed(f"test $(findmnt -no SOURCE {path}) = rpool/{dataset}")

    # Writes, whiteouts included, land in the upper directory on ZFS.
    probe = "/var/lib/rancher/k3s/agent/containerd/overlay-probe"
    machine.succeed(
        f"mkdir -p {probe}/lower {probe}/upper {probe}/work {probe}/merged && echo old > {probe}/lower/gone"
        f" && echo old > {probe}/lower/kept"
        f" && mount -t overlay overlay -o lowerdir={probe}/lower,upperdir={probe}/upper,workdir={probe}/work {probe}/merged"
        f" && echo new > {probe}/merged/kept && rm {probe}/merged/gone && umount {probe}/merged"
        f" && grep -qx new {probe}/upper/kept && test -c {probe}/upper/gone && grep -qx old {probe}/lower/kept"
    )
  '';
}
