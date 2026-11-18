# A server's disk layout as disko installs it on two blank disks, booted: BlueStore DB volumes for Ceph's OSDs each fill
# a volume group of their own on a partition of a RAID1 array over both system disks, which keeps a write-intent
# bitmap, at least at their size and with nothing on them, LVM's commands reach them by an ordinary PATH, and all stay
# readable when one disk fails; k3s's and the monitors' datasets are bounded or reserved as set and mounted outside
# rpool/var; containerd's dataset takes overlay mounts, so k3s keeps its overlayfs snapshotter there; the journal, the
# metrics, and a dynamic user's state declared so, lie on bounded datasets outside the snapshots of /var; the pool's
# health check passes; and the metrics read how much of the pool, and of each bounded dataset, is taken.
{ lib, pkgs, ... }:
let
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
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
      logQuota = "128M";
      # A dynamic user's state on a dataset of its own, as the watcher keeps ntfy's.
      unsnapshotted.probe = {
        path = "/var/lib/private/probe";
        quota = "64M";
      };
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
    metrics.quota = "128M";
    alerts = {
      urlFile = "/run/secrets/alerts-url";
      tokenFile = "/run/secrets/alerts-token";
      smart = false;
    };
    offsite = {
      recipients = [ keys.snakeOilEd25519PublicKey ];
      targets = lib.genAttrs [ "1" "2" ] (n: {
        endpoint = "https://s3.example.org";
        region = "example";
        bucket = "example-platform";
        credentialsFile = "/run/secrets/offsite-${n}";
      });
    };
  };

  systemd.services.probe.serviceConfig = {
    Type = "oneshot";
    DynamicUser = true;
    StateDirectory = "probe";
    ExecStart = "${pkgs.coreutils}/bin/touch /var/lib/probe/written";
  };

  # Runs on the installed system once it has booted, from vda and vdb.
  disko.tests.extraChecks = ''
    machine.succeed("zpool status rpool | grep -qw mirror-0")
    # Healthy, so its check passes without alerting, which has no channel here.
    machine.succeed("systemctl start zfs-health")
    machine.succeed("mdadm --detail /dev/md/osd-db | grep -Eq 'Raid Level : raid1'")
    machine.succeed("mdadm --detail /dev/md/osd-db | grep -q 'Intent Bitmap : Internal'")
    volumes = [f"/dev/disk/by-osd/osd{slot}-db" for slot in range(4)]
    for slot, volume in enumerate(volumes):
        # LVM activates each group as its partition shows up, which may come after the file systems.
        machine.wait_for_file(volume)
        # The one logical volume of its own group, which it fills, on a partition of the array over both disks.
        machine.succeed(f"test $(readlink -f {volume}) = $(readlink -f /dev/osd{slot}-db/db)")
        counts = machine.succeed(f"vgs --noheadings -o pv_count,lv_count,vg_free_count osd{slot}-db").split()
        assert counts == ["1", "1", "0"], (slot, counts)
        below = machine.succeed(f"lsblk -snro NAME,TYPE $(readlink -f {volume})").split("\n")
        assert below[0].endswith(" lvm") and below[1].endswith(" part") and below[2].endswith(" raid1"), below
        for disk in ["vda", "vdb"]:
            assert f"{disk} disk" in below, (volume, below)
        machine.succeed(f"test $(lsblk -bno SIZE {volume}) -ge ${mib 64}")
        machine.succeed(f"test -z \"$(lsblk -no FSTYPE {volume})\"")
    machine.fail("test -e /dev/disk/by-osd/osd4-db")
    # As ceph-volume finds them from Rook's prepare pods: by a container image's PATH.
    machine.succeed("env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin lvs osd0-db/db")
    machine.succeed("mdadm /dev/md/osd-db --fail $(mdadm --detail /dev/md/osd-db | grep -o '/dev/vdb[0-9]*')")
    machine.succeed("mdadm --detail /dev/md/osd-db | grep -q degraded")
    for volume in volumes:
        machine.succeed(f"dd if={volume} of=/dev/null bs=1M count=1 iflag=direct")

    for dataset, prop, value, path in [
        ("containerd", "quota", ${mib 512}, "/var/lib/rancher/k3s/agent/containerd"),
        ("kubelet", "quota", ${mib 256}, "/var/lib/kubelet"),
        ("etcd", "reservation", ${mib 128}, "/var/lib/rancher/k3s/server/db"),
        ("rook", "reservation", ${mib 64}, "/var/lib/rook"),
        ("log", "quota", ${mib 128}, "/var/log"),
        ("probe", "quota", ${mib 64}, "/var/lib/private/probe"),
        ("host-checks", "quota", ${mib 64}, "/var/lib/private/host-checks"),
        ("metrics", "quota", ${mib 128}, "/var/lib/private/victoriametrics"),
    ]:
        machine.succeed(f"test $(zfs get -Hpo value {prop} rpool/{dataset}) = {value}")
        machine.succeed(f"test $(findmnt -no SOURCE {path}) = rpool/{dataset}")

    # The journal is kept there, and a dynamic user's state, under the private directory as systemd wants it.
    machine.succeed("journalctl --flush")
    machine.succeed("test $(findmnt -no SOURCE -T /var/log/journal/$(cat /etc/machine-id)) = rpool/log")
    machine.succeed("systemctl start probe")
    machine.succeed("test $(findmnt -no SOURCE -T /var/lib/private/probe/written) = rpool/probe")
    machine.succeed("test $(stat -c %a /var/lib/private) = 700")
    # And so do the metrics, as VictoriaMetrics keeps them.
    machine.wait_for_unit("victoriametrics.service")
    machine.succeed("test $(findmnt -no SOURCE -T /var/lib/private/victoriametrics/flock.lock) = rpool/metrics")
    # Snapshots of /var leave them out.
    machine.succeed("systemctl start --wait sanoid && test $(systemctl show -P Result sanoid) = success")
    machine.succeed("zfs list -Ho name -t snapshot -r rpool/var | grep -q '^rpool/var@'")
    machine.succeed("test -z \"$(zfs list -Ho name -t snapshot -r rpool/log rpool/probe rpool/host-checks rpool/metrics)\"")

    # What the metrics read of the pool, as root, but on a read-only system, and of each bounded dataset.
    machine.succeed("systemctl start suveraen-metrics-textfiles")
    machine.succeed("grep -Eqx 'pool_capacity_ratio\\{pool=\"rpool\"\\} 0(\\.[0-9]+)?' /run/suveraen-metrics-textfiles/pools.prom")
    for path in ["/var/lib/rancher/k3s/agent/containerd", "/var/lib/kubelet", "/var/log", "/var/lib/private/probe",
                 "/var/lib/private/victoriametrics"]:
        machine.succeed(f"grep -q '^dataset_avail_bytes{{mountpoint=\"{path}\"}} [0-9]' /run/suveraen-metrics-textfiles/datasets.prom")

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
