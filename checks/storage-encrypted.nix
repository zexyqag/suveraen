# An encrypted server's disk layout as disko installs it on two blank disks, booted through lanzaboote: no BIOS boot
# partition, the passphrase typed at the console opens both system disks under rpool's mirror, and the boot partition
# is a RAID1 array that holds the signed boot files and the Secure Boot keys for enrolling, and no random seed, which
# the boot loader would rewrite on one half alone. The VM's firmware has no Secure Boot, so nothing is enrolled here.
{
  pkgs,
  nixosSystem,
  makeDiskoTest,
  module,
}:
let
  inherit (pkgs) lib;
  keys = import ./secure-boot-keys.nix pkgs;
  # nixpkgs' test host key for SSH during boot.
  bootKeys = pkgs.path + "/nixos/tests/initrd-network-ssh";
  passphrase = "storage-test-passphrase";

  host = nixosSystem {
    modules = [
      module
      ./storage.nix
      {
        suveraen.storage = {
          encrypted = lib.mkForce true;
          secureBootKeys = "${keys}/auth";
        };
      }
    ];
  };
in
# As disko's own installTest, which takes no postDisko.
makeDiskoTest {
  inherit pkgs;
  inherit (host) extendModules;
  name = "storage-encrypted";
  disko-config = removeAttrs host.config [ "_module" ];
  testMode = "direct";
  # disko guesses UEFI from systemd-boot or GRUB alone.
  efi = true;
  # disko reads the passphrase from here while formatting, where nixos-anywhere puts it.
  extraInstallerConfig.systemd.tmpfiles.rules = [ "f /tmp/disk.key 0600 - - - ${passphrase}" ];
  # What nixos-anywhere copies with --extra-files: the key lanzaboote signs with, and the boot-time SSH host key it
  # adds to the initrd.
  postDisko = ''
    machine.succeed("install -D -m 600 ${keys}/keys/db/db.key /mnt/var/lib/sbctl/keys/db/db.key")
    machine.succeed("install -D -m 600 ${keys}/keys/db/db.pem /mnt/var/lib/sbctl/keys/db/db.pem")
    machine.succeed("install -D -m 600 ${bootKeys}/ssh_host_ed25519_key /mnt/etc/secrets/initrd/ssh_host_ed25519_key")
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
        line.split()[0] for line in machine.succeed("zpool status -PL rpool").splitlines() if line.strip().startswith("/dev/")
    ]
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
  '';
}
