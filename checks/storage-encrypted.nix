# An encrypted server's disk layout as disko installs it on two blank disks, booted through lanzaboote: no BIOS boot
# partition, the passphrase typed at the console opens both system disks, each as the volume whose key the host names,
# with the ids disko printed for them, under rpool's mirror, which is imported from those volumes alone, and the boot
# partition is a RAID1 array that holds the signed boot files and the Secure Boot keys for enrolling, and no random
# seed, which the boot loader would rewrite on one half alone. With the first disk taken out, the second boots alone and
# rpool comes up degraded on its volume, not on a logical volume that goes by the first's volume name and holds a pool
# named rpool; with the disk back, the next boot attaches it and the mirror catches up. A volume of another key on the
# second disk, made with the same passphrase, doesn't open, and rpool comes up degraded on the first, with what it had
# missed. The VM's firmware has no Secure Boot, so nothing is enrolled here.
{
  pkgs,
  nixosSystem,
  makeDiskoTest,
  module,
}:
let
  inherit (pkgs) lib;
  keys = import ./secure-boot-keys.nix pkgs;
  passphrase = "storage-test-passphrase";
  # Each system disk's volume with a key and UUID of the test's own, and that key's id.
  volumes = [
    {
      uuid = "6f1d0c3b-2a94-4e57-8b6c-7d8e9f0a1b20";
      id = "3d7f3b54af7337d16af8fcca08e8710299cc9b64518536b1f574f2ce2ae65483";
    }
    {
      uuid = "6f1d0c3b-2a94-4e57-8b6c-7d8e9f0a1b21";
      id = "cc125099ee01e03ed7af3833fd51cd2e24993923dc991ebd3a1a86da6260f489";
    }
  ];
  volumeKey =
    i:
    pkgs.writeText "volume-${toString i}.key" (
      builtins.hashString "sha256" "storage-test-volume-key-${toString i}"
    );

  host = nixosSystem {
    modules = [
      module
      ./storage.nix
      {
        suveraen.storage = {
          encrypted = lib.mkForce true;
          secureBootKeys = "${keys}/auth";
          volumeKeyIds = map (volume: volume.id) volumes;
        };
        # Without a TPM the boot-time SSH server can't open it; the passphrase goes in at the console.
        suveraen.unlock.sealedHostKey = pkgs.writeText "stand-in.cred" "stand-in";
        # The VM has no TPM to wait for.
        boot.initrd.systemd.services.sshd.wants = lib.mkForce [ ];
        # A missing disk is given up on as on a host, not after the test instrumentation's 300 s.
        boot.initrd.systemd.settings.Manager.DefaultDeviceTimeoutSec = lib.mkForce 90;
      }
    ];
  };
in
# As disko's own installTest, which takes no postDisko.
makeDiskoTest {
  inherit pkgs;
  inherit (host) extendModules;
  name = "storage-encrypted";
  # disko's types merge no partial definitions of a disk, so the keys go into the layout it formats.
  disko-config = lib.recursiveUpdate (removeAttrs host.config [ "_module" ]) {
    disko.devices.disk = lib.listToAttrs (
      lib.imap0 (
        i: volume:
        lib.nameValuePair "system${toString i}" {
          content.partitions.system.content.extraFormatArgs = [
            "--uuid=${volume.uuid}"
            "--volume-key-file=${volumeKey i}"
          ];
        }
      ) volumes
    );
  };
  testMode = "direct";
  # disko guesses UEFI from systemd-boot or GRUB alone.
  efi = true;
  # disko reads the passphrase from here while formatting, where nixos-anywhere puts it.
  extraInstallerConfig.systemd.tmpfiles.rules = [ "f /tmp/disk.key 0600 - - - ${passphrase}" ];
  # What nixos-anywhere copies with --extra-files: the key lanzaboote signs with.
  postDisko = ''
    machine.succeed("install -D -m 600 ${keys}/keys/db/db.key /mnt/var/lib/sbctl/keys/db/db.key")
    machine.succeed("install -D -m 600 ${keys}/keys/db/db.pem /mnt/var/lib/sbctl/keys/db/db.pem")
  '';
  # One passphrase opens both disks: systemd-cryptsetup tries it on the second. The console's log is polled:
  # wait_for_console_text, given a timeout, reads one line a second and falls behind.
  bootCommands = ''
    retry(lambda _: "Please enter passphrase for disk" in machine.get_console_log(), 600)
    machine.send_console("${passphrase}\n")
  '';
  extraTestScript = ''
    # An ESP on each disk, and no BIOS boot partition.
    for disk in ["vda", "vdb"]:
        types = machine.succeed(f"lsblk -nro PARTTYPE /dev/{disk}").split()
        assert "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" in types, (disk, types)
        assert "21686148-6449-6e6f-744e-656564454649" not in types, (disk, types)

    members = [
        line.split()[0] for line in machine.succeed("zpool status -P rpool").splitlines() if line.strip().startswith("/dev/")
    ]
    assert members == ["/dev/disk/rpool/crypt-system0", "/dev/disk/rpool/crypt-system1"], members
    volumes = sorted(machine.succeed(f"lsblk -ndo TYPE,NAME {member}").strip() for member in members)
    assert volumes == ["crypt crypt-system0", "crypt crypt-system1"], volumes
    machine.succeed("zpool status rpool | grep -qw mirror-0")

    machine.succeed("mdadm --detail /dev/md/boot | grep -Eq 'Raid Level : raid1'")
    machine.succeed("test $(findmnt -no SOURCE /boot) = $(readlink -f /dev/md/boot)")
    # Started by lanzaboote's stub, from a signed image of its own, with the boot menu's editor off.
    machine.succeed("test -e /sys/firmware/efi/efivars/StubInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f")
    machine.succeed("ls /boot/EFI/Linux/nixos-*.efi")
    machine.succeed("grep -qx 'editor false' /boot/loader/loader.conf")

    machine.wait_for_unit("secure-boot-keys.service")
    for name in ["PK", "KEK", "db", "dbx"]:
        machine.succeed(f"cmp /boot/loader/keys/auto/{name}.auth ${keys}/auth/{name}.auth")

    # systemd's seed unit ran and found no ESP to write a seed to, the array being no GPT partition.
    machine.succeed("test $(systemctl show -P ConditionResult systemd-boot-random-seed.service) = yes")
    machine.succeed("test $(systemctl show -P Result systemd-boot-random-seed.service) = success")
    machine.succeed("test ! -e /boot/loader/random-seed")

    # The ids from the volumes' headers and the passphrase, which disko printed at install, are those the boot took.
    ids = machine.succeed("echo ${passphrase} | suveraen-volume-key-ids").split()
    assert ids == [${lib.concatMapStringsSep ", " (volume: ''"${volume.id}"'') volumes}], ids

    def boot(m):
        m.start()
        retry(lambda _: "Please enter passphrase for disk" in m.get_console_log(), 600)
        m.send_console("${passphrase}\n")
        ends = [f'{end} Import ZFS pool "rpool"' for end in ["Dependency failed for", "Failed to start", "Finished"]]
        retry(lambda _: any(end in m.get_console_log() for end in ends), 600)
        assert ends[-1] in m.get_console_log(), "rpool was not imported"
        m.wait_for_unit("multi-user.target")

    def online(m):
        fields = [line.split() for line in m.succeed("zpool status -P rpool").splitlines()]
        return [f[0] for f in fields if len(f) > 1 and f[0].startswith("/dev/") and f[1] == "ONLINE"]

    def degraded(m, member, gone):
        status = m.succeed("zpool status -P rpool")
        assert m.succeed("zpool list -Ho health rpool").strip() == "DEGRADED", status
        assert online(m) == [f"/dev/disk/rpool/{member}"], status
        assert f"/dev/disk/rpool/{gone}" in status, status
        m.fail(f"test -e /dev/disk/rpool/{gone}")

    # Someone with the disks makes a logical volume named as the first disk's volume, which LVM in the initrd activates,
    # and puts a pool named rpool on it. With that disk taken out, the second boots alone, the first's volume unit gives
    # up on its disk, and rpool comes up degraded on the second's volume, the logical volume getting no link.
    pv = machine.succeed("pvs --noheadings -o pv_name -S vg_name=osd0-db").strip()
    machine.succeed(
        f"vgremove -f osd0-db && vgcreate squat {pv} && lvcreate -y -n system0 -l 100%FREE squat"
        " && zpool create -f -t squat -m none rpool /dev/squat/system0 && zpool export squat"
        " && vgchange -an squat && vgrename squat crypt"
    )
    installer = next(m for m in machines_qemu if m.name == "machine")
    first = " " + " ".join(disks(installer, 2)[:4])
    assert first in machine.start_command._cmd, machine.start_command._cmd
    detached = create_machine(start_command=machine.start_command._cmd.replace(first, ""), name="detached")
    machines_qemu.append(detached)
    machine.shutdown()
    boot(detached)
    degraded(detached, "crypt-system1", "crypt-system0")
    assert detached.succeed("lsblk -ndo TYPE /dev/mapper/crypt-system0").strip() == "lvm"
    assert "pool: rpool" in detached.succeed("zpool import -d /dev/mapper/crypt-system0")
    journal = detached.succeed("journalctl -b -o cat")
    assert "Timed out waiting for device /dev/disk/by-partlabel/disk-system0-system" in journal
    # What the first disk misses, and the logical volume gone again before that disk is back.
    detached.succeed("touch /var/degraded-boot && vgremove -f crypt")
    detached.shutdown()

    # Back in, the disk opens with the other and catches up on what it missed. The import may read some of that off it
    # before ZFS knows it is behind, which counts as checksum errors on it, mended from the other disk.
    boot(machine)
    machine.succeed("test -e /var/degraded-boot")
    machine.wait_until_succeeds("zpool status rpool | grep -q 'resilvered .* with 0 errors'", timeout=300)
    behind = machine.succeed("zpool status -P rpool")
    machine.succeed("zpool clear rpool")
    status = machine.succeed("zpool status -x")
    assert status.strip() == "all pools are healthy", (behind, status)
    assert online(machine) == members, machine.succeed("zpool status -P rpool")

    # Someone with the disks and the passphrase puts a volume of another key on the second one, made with the same
    # passphrase. It doesn't open, and rpool comes up degraded on the first, which the mirror brought up to date.
    machine.succeed("zpool offline -t rpool /dev/disk/rpool/crypt-system1")
    machine.succeed("cryptsetup close crypt-system1")
    machine.succeed(
        "printf %s ${passphrase} | cryptsetup luksFormat --batch-mode --pbkdf pbkdf2 --pbkdf-force-iterations 1000"
        " /dev/disk/by-partlabel/disk-system1-system -"
    )
    machine.shutdown()
    boot(machine)
    degraded(machine, "crypt-system0", "crypt-system1")
    machine.fail("test -e /dev/mapper/crypt-system1")
    machine.succeed("test -e /var/degraded-boot")
    journal = machine.succeed("journalctl -b -u 'systemd-cryptsetup@crypt\\x2dsystem1.service' -o cat --no-pager")
    assert "does not match the expectation: '${(lib.elemAt volumes 1).id}'" in journal, journal
    machine.crash()
  '';
}
