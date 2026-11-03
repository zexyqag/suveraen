# Boots a server as it boots for real: UEFI under the host's own Secure Boot keys, a TPM, and a boot chain lanzaboote
# signed. A first run is install day: the firmware starts in setup mode, the boot menu enrolls the keys from the boot
# partition, the disks are unlocked over SSH with the transition host key pinned, which alerts, and the boot-time SSH
# host key is sealed in the booted system, after the seal refused boot menu keys that aren't the firmware's. On that
# TPM, a genuine boot then opens the sealed key: an unlock-only key gets no port forwarding, answers the passphrase
# prompt over SSH with the host key pinned, and can't log in afterwards; neither the boot's check nor the upgrade's
# alerts. A firmware reset to its factory keys is undone from the boot menu, and the key opens again. With a credential
# planted on the boot partition, or Secure Boot off, the key stays sealed and nothing listens. A volume with another key
# doesn't open, even to the passphrase.
{ pkgs, module }:
let
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  secureBootKeys = import ./secure-boot-keys.nix pkgs;
  # nixpkgs' test keys for SSH during boot: a client key, and a host key that stands in for the transition key.
  bootKeys = pkgs.path + "/nixos/tests/initrd-network-ssh";
  transitionKey = "${bootKeys}/ssh_host_ed25519_key";
  passphrase = "unlock-test-passphrase";
  ovmf = pkgs.OVMFFull.fd;
  # No platform key: setup mode, Secure Boot off.
  setupMode = "${ovmf}/FV/OVMF_VARS.fd";
  # The firmware's factory keys with the platform key gone, as a reset leaves them for the boot menu to enroll over.
  factory =
    pkgs.runCommand "factory-vars.fd" { nativeBuildInputs = [ pkgs.python3Packages.virt-firmware ]; }
      ''
        virt-fw-vars --input ${ovmf}/FV/OVMF_VARS.ms.fd --output $out --delete PK
      '';

  # Encrypted before the VM first boots, so that boot already waits for the passphrase, with a volume key of the test's
  # own. The host's volume has the key whose id it sets; another has the same passphrase and UUID and another key.
  volume =
    name:
    pkgs.runCommand "${name}.img" { nativeBuildInputs = [ pkgs.cryptsetup ]; } ''
      printf %s ${builtins.hashString "sha256" name} > volume.key
      truncate -s 32M $out
      printf %s ${passphrase} | cryptsetup luksFormat --batch-mode --disable-locks \
        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --uuid 9c5e2b7a-3d41-4f86-a0b9-1e2d3c4b5a69 \
        --volume-key-file volume.key $out -
    '';
  hostVolume = volume "host-volume";
  hostVolumeKeyId = "226e70e7126255ccf4329e9e34b1f1585fe5b744e0b7a80cc9f1b3dafea37656";
  anotherVolume = volume "another-volume";

  # Stands in for the alerts' ntfy: keeps each alert's title, priority and message.
  alerts = pkgs.writers.writePython3 "alerts" { } ''
    import http.server
    import json


    class Keep(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers["Content-Length"])
            alert = {
                "title": self.headers["Title"],
                "priority": self.headers["Priority"],
                "message": self.rfile.read(length).decode(),
            }
            with open("/var/lib/alerts/sent", "a") as sent:
                sent.write(json.dumps(alert) + "\n")
            self.send_response(200)
            self.end_headers()

        def log_message(self, *_):
            pass


    http.server.ThreadingHTTPServer(("", 80), Keep).serve_forever()
  '';

  server =
    unlock:
    {
      config,
      lib,
      modulesPath,
      ...
    }:
    {
      imports = [
        module
        "${modulesPath}/image/repart.nix"
      ];

      # A disk whose ESP lzbt filled and signed at build time, as on an installed host, with the keys for the boot menu
      # to enroll: the unit that copies them runs only once the system is up.
      image.repart = {
        name = "server";
        partitions = {
          esp = {
            contents."/".source =
              pkgs.runCommand "esp"
                {
                  # The transition key, which lzbt appends to the initrd from its path on the host: here the store.
                  inherit transitionKey;
                }
                ''
                  mkdir $out
                  ln -s ${config.system.build.toplevel} system-1-link
                  ${config.boot.lanzaboote.installCommand} --public-key ${secureBootKeys}/keys/db/db.pem \
                    --private-key ${secureBootKeys}/keys/db/db.key $out system-1-link
                  mkdir -p $out/loader/keys/auto
                  cp ${config.suveraen.storage.secureBootKeys}/*.auth $out/loader/keys/auto/
                '';
            repartConfig = {
              Type = "esp";
              Format = "vfat";
              Label = "esp";
              SizeMinBytes = "96M";
            };
          };
          root.repartConfig = {
            Type = "root";
            Format = "ext4";
            Label = "root";
            SizeMinBytes = "128M";
          };
        };
      };
      system.image = {
        id = "server";
        version = "1";
      };

      virtualisation = {
        directBoot.enable = false;
        useEFIBoot = true;
        efi.OVMF = ovmf;
        tpm.enable = true;
        rootDevice = "/dev/disk/by-partlabel/root";
        fileSystems."/boot" = {
          device = "/dev/disk/by-partlabel/esp";
          fsType = "vfat";
          options = [ "umask=0077" ];
        };
        # The tests put the volume there before each boot.
        qemu.drives = [
          {
            name = "encrypted";
            file = ''"$TMPDIR"/volume.img'';
            driveExtraOpts = {
              format = "raw";
              snapshot = "on";
            };
            deviceExtraOpts.serial = "encrypted";
          }
        ];
      };
      # Stands in for the system disk, with the settings the host gives it: the boot doesn't go on until it is unlocked.
      boot.initrd.luks.devices = lib.mkVMOverride {
        crypt-system0 = config.disko.devices.disk.system0.content.partitions.system.content.settings // {
          device = "/dev/disk/by-id/virtio-encrypted";
        };
      };
      boot.loader.timeout = 0;
      # lzbt appends the initrd's secrets on the ESP, as on a host. qemu-vm assumes a direct boot, which couldn't, and
      # says so with a VM override, which this outranks.
      boot.loader.supportsInitrdSecrets = lib.mkOverride 9 true;
      # Commands in the initrd, where a key that doesn't open leaves the boot waiting.
      testing.initrdBackdoor = unlock ? sealedHostKey;

      networking.hostId = "0400bdef";
      system.stateVersion = "26.05";

      suveraen = {
        adminKeys = [ keys.snakeOilEd25519PublicKey ];
        storage = {
          systemDisks = [ "/dev/disk/by-id/test-0" ];
          secureBootKeys = "${secureBootKeys}/auth";
          volumeKeyIds = [ hostVolumeKeyId ];
        };
        network.interface = "eth0";
        unlock = unlock // {
          keys = [ (lib.fileContents (bootKeys + "/id_ed25519.pub")) ];
        };
        alerts = {
          urlFile = toString (pkgs.writeText "alerts-url" "http://client/ops");
          tokenFile = toString (pkgs.writeText "alerts-token" "unused");
          smart = false;
        };
      };
    };

  client = {
    environment.systemPackages = [ pkgs.expect ];
    networking.firewall.allowedTCPPorts = [ 80 ];
    systemd.services.alerts = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = alerts;
        StateDirectory = "alerts";
      };
    };
  };

  answer = pkgs.writeText "unlock.exp" ''
    set timeout 60
    spawn ssh -tt -p 2222 -o StrictHostKeyChecking=yes -i /root/unlock server
    expect {
      "passphrase" {}
      timeout { exit 1 }
      eof { exit 1 }
    }
    send "${passphrase}\r"
    expect eof
  '';

  # Install day. The transition key's path carries no store reference, so the key reaches the initrd only as a host's
  # does: appended by lzbt.
  sealing = pkgs.testers.runNixOSTest {
    name = "suveraen-unlock-seal";
    nodes = {
      server = server { transitionHostKey = builtins.unsafeDiscardStringContext transitionKey; };
      inherit client;
    };
    testScript =
      { nodes, ... }:
      ''
        import json
        import os
        import re
        import shutil
        import subprocess

        tpm = server.state_dir / "tpm"
        variables = server.state_dir / "efi-vars.fd"
        disk = server.state_dir / "disk.qcow2"
        subprocess.run(
            [
                "${nodes.server.virtualisation.qemu.package}/bin/qemu-img", "create", "-f", "qcow2", "-F", "raw",
                "-b", "${nodes.server.system.build.image}/${nodes.server.image.fileName}", str(disk),
            ],
            check=True,
        )
        shutil.copyfile("${setupMode}", variables)
        os.chmod(variables, 0o644)
        shutil.copyfile("${hostVolume}", server.state_dir / "volume.img")

        client.start()
        client.wait_for_unit("alerts.service")
        client.succeed(
            "install -m 600 ${bootKeys}/id_ed25519 /root/unlock"
            " && mkdir -p /root/.ssh && echo \"[server]:2222 $(cat ${transitionKey}.pub)\" > /root/.ssh/known_hosts"
        )
        # For the server: every machine started from here on takes these.
        os.environ.update({"NIX_DISK_IMAGE": str(disk), "NIX_EFI_VARS": str(variables), "NIX_SWTPM_DIR": str(tpm)})

        with subtest("In setup mode the boot menu enrolls the host's keys, and the transition key unlocks the disks"):
            server.start(allow_reboot=True)
            client.wait_until_succeeds("nc -z -w 5 server 2222")
            client.succeed("expect ${answer}")
            server.wait_for_unit("unlock-key-check.service")
            sent = [json.loads(line) for line in client.succeed("cat /var/lib/alerts/sent").splitlines()]
            risks = [a for a in sent if a["title"] == "server: boot unlock at risk"]
            assert risks == [{
                "title": "server: boot unlock at risk",
                "priority": "5",
                "message": "The boot-time SSH server answers with a plaintext key from the boot partition:"
                " seal a key and switch to it.",
            }], sent

        with subtest("The seal refuses boot menu keys that aren't the firmware's"):
            server.succeed("cp /boot/loader/keys/auto/db.auth /boot/loader/keys/auto/dbx.auth")
            refused = server.fail("suveraen-unlock-seal 2>&1 >/dev/null")
            assert "don't match /boot/loader/keys/auto" in refused, refused
            server.succeed("systemctl restart secure-boot-keys.service")

        with subtest("The seal makes the boot-time SSH host key and seals it in this boot's state"):
            sealed = server.succeed("suveraen-unlock-seal 2>/run/key.pub")
            public = server.succeed("cat /run/key.pub")
            # One line, which pins the key; ssh-keygen ends it with a space for the empty comment.
            assert re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/]+=* ?\n", public), public
            server.shutdown()

        out = os.environ["out"]
        with open(f"{out}/ssh_host_ed25519_key.cred", "w") as f:
            f.write(sealed)
        with open(f"{out}/ssh_host_ed25519_key.pub", "w") as f:
            f.write(public)
        shutil.copytree(tpm, f"{out}/tpm", ignore=shutil.ignore_patterns("socket*", "pid", ".lock", "stdout"))
        shutil.copyfile(variables, f"{out}/efi-vars.fd")
      '';
  };
in
pkgs.testers.runNixOSTest {
  name = "suveraen-unlock";

  nodes = {
    server = server { sealedHostKey = "${sealing}/ssh_host_ed25519_key.cred"; };
    inherit client;
  };

  # For the check of the tests' scripts.
  passthru = { inherit sealing; };

  testScript =
    { nodes, ... }:
    ''
      import json
      import os
      import shutil
      import subprocess

      tpm = server.state_dir / "tpm"
      shutil.copytree("${sealing}/tpm", tpm)
      # A raw disk, so the test can write to its ESP between boots as someone with the disk would.
      disk = server.state_dir / "disk.img"
      shutil.copyfile("${nodes.server.system.build.image}/${nodes.server.image.fileName}", disk)
      subprocess.run(["chmod", "-R", "u+w", str(tpm), str(disk)], check=True)
      table = json.loads(subprocess.run(
          ["${pkgs.util-linux}/bin/sfdisk", "--json", str(disk)], check=True, capture_output=True
      ).stdout)["partitiontable"]
      offset = next(p["start"] for p in table["partitions"] if p["name"] == "esp") * table["sectorsize"]
      esp = f"{disk}@@{offset}"
      variables = server.state_dir / "efi-vars.fd"

      def boot(store, allow_reboot=False, volume="${hostVolume}"):
          shutil.copyfile(store, variables)
          os.chmod(variables, 0o644)
          shutil.copyfile(volume, server.state_dir / "volume.img")
          server.start(allow_reboot=allow_reboot)

      def on_esp(command, *args):
          subprocess.run(
              ["${pkgs.mtools}/bin/" + command, "-i", esp, *args], check=True, env={**os.environ, "MTOOLS_SKIP_CHECK": "1"}
          )

      # Neither check alerted, nor failed.
      def quiet():
          sent = [json.loads(line) for line in client.succeed("cat /var/lib/alerts/sent 2>/dev/null || true").splitlines()]
          assert not [a for a in sent if "unlock" in a["title"]], sent

      # Once the passphrase is in: the boot goes on, and its check finds nothing.
      def up():
          server.switch_root()
          server.wait_for_unit("unlock-key-check.service")
          server.succeed("test -b /dev/mapper/crypt-system0")
          quiet()

      def stays_sealed():
          server.wait_until_succeeds("systemctl is-failed sshd.service", timeout=300)
          journal = server.succeed("journalctl -b -u sshd.service -o cat --no-pager")
          assert "policy does not match" in journal, journal
          client.fail("nc -z -w 5 server 2222")
          server.crash()

      client.start()
      client.wait_for_unit("alerts.service")
      client.succeed(
          "install -m 600 ${bootKeys}/id_ed25519 /root/unlock"
          " && install -m 600 ${keys.snakeOilEd25519PrivateKey} /root/admin"
          " && mkdir -p /root/.ssh"
          " && echo \"[server]:2222 $(cat ${sealing}/ssh_host_ed25519_key.pub)\" > /root/.ssh/known_hosts"
      )
      # For the server: every machine started from here on takes these.
      os.environ.update({"NIX_DISK_IMAGE": str(disk), "NIX_EFI_VARS": str(variables), "NIX_SWTPM_DIR": str(tpm)})

      with subtest("A genuine boot opens the host key; an unlock-only key gets no port forwarding at boot"):
          boot("${sealing}/efi-vars.fd")
          server.wait_for_unit("sshd.service")
          client.wait_until_succeeds("nc -z -w 5 server 2222", timeout=120)
          # A forward that was set up would keep ssh running until the timeout, without this message.
          forward = client.fail(
              "timeout 30 ssh -p 2222 -o StrictHostKeyChecking=yes -i /root/unlock -N -o ExitOnForwardFailure=yes"
              " -R 2000:127.0.0.1:22 server 2>&1"
          )
          assert "remote port forwarding failed" in forward, forward

      with subtest("An unlock-only key answers the passphrase prompt, and the boot goes on"):
          client.succeed("expect ${answer}")
          up()
          server.succeed("grep -qw systemd.import_credentials=no /proc/cmdline")
          server.succeed("systemctl start unlock-key-recheck.service")
          quiet()

      with subtest("An unlock-only key can't log in to the running system"):
          login = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
          client.succeed(f"{login} -i /root/admin server true")
          client.fail(f"{login} -i /root/unlock server true")
          server.shutdown()

      with subtest("A firmware reset to its factory keys is undone from the boot menu, and the key opens again"):
          boot("${factory}", allow_reboot=True)
          server.wait_for_unit("sshd.service")
          client.wait_until_succeeds("nc -z -w 5 server 2222", timeout=120)
          client.succeed("expect ${answer}")
          up()
          server.shutdown()

      # Someone with the disk plants a credential on the ESP.
      planted = server.state_dir / "planted.cred"
      planted.write_text("planted\n")
      on_esp("mmd", "::/loader/credentials")
      on_esp("mcopy", str(planted), "::/loader/credentials/")

      with subtest("With a credential planted on the boot partition, the key stays sealed"):
          boot("${sealing}/efi-vars.fd")
          stays_sealed()

      on_esp("mdeltree", "::/loader/credentials")
      # Without keys to enroll, the firmware stays in setup mode, with Secure Boot off.
      on_esp("mdeltree", "::/loader/keys")

      with subtest("With Secure Boot off, the same signed chain boots and the key stays sealed"):
          boot("${setupMode}")
          stays_sealed()

      with subtest("A volume with another key doesn't open, even to the passphrase"):
          boot("${sealing}/efi-vars.fd", volume="${anotherVolume}")
          server.wait_for_unit("sshd.service")
          client.wait_until_succeeds("nc -z -w 5 server 2222", timeout=120)
          client.succeed("expect ${answer}")
          # Nothing of this VM's lies on it, so its boot goes on without.
          server.switch_root()
          server.fail("test -e /dev/mapper/crypt-system0")
          journal = server.succeed("journalctl -b -u 'systemd-cryptsetup@crypt\\x2dsystem0.service' -o cat --no-pager")
          assert "does not match the expectation: '${hostVolumeKeyId}'" in journal, journal
          server.shutdown()
    '';
}
