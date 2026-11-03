# An encrypted server's disk layout as disko installs it on two blank disks, booted through lanzaboote: no BIOS boot
# partition, the passphrase typed at the console opens both system disks, each as the volume whose key the host names,
# with the ids disko printed for them, under rpool's mirror, which is imported from those volumes alone, and the boot
# partition is a RAID1 array that holds the signed boot files and the Secure Boot keys for enrolling, and no random
# seed, which the boot loader would rewrite on one half alone. With a volume of another key on one disk, the boot
# imports no rpool, even once the passphrase opened the other. The VM's firmware has no Secure Boot, so nothing is
# enrolled here.
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
  # One passphrase opens both disks: systemd-cryptsetup tries it on the second.
  bootCommands = ''
    machine.wait_for_console_text("Please enter passphrase for disk")
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

    # Someone with the disks and the passphrase puts a volume of another key on the second one. The passphrase still
    # opens the first, which now holds all of rpool, but the boot doesn't import it.
    machine.succeed("zpool detach rpool /dev/disk/rpool/crypt-system1")
    machine.succeed("cryptsetup close crypt-system1")
    machine.succeed(
        "printf %s ${passphrase} | cryptsetup luksFormat --batch-mode --pbkdf pbkdf2 --pbkdf-force-iterations 1000"
        " /dev/disk/by-partlabel/disk-system1-system -"
    )
    machine.shutdown()
    machine.start()
    machine.wait_for_console_text("Please enter passphrase for disk")
    machine.send_console("${passphrase}\n")
    machine.wait_for_console_text('(Dependency failed for|Failed to start|Finished) Import ZFS pool "rpool"')
    assert 'Finished Import ZFS pool "rpool"' not in machine.get_console_log(), "rpool was imported"
    machine.crash()
  '';
}
