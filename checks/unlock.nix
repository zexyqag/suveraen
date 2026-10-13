# Boots a server whose disk waits for its passphrase. An unlock-only key gets no port forwarding at
# boot, answers the passphrase prompt over SSH so the boot goes on, and can't log in afterwards.
{ pkgs, module }:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  # nixpkgs' test keys for SSH during boot: a host key and a client key.
  bootKeys = pkgs.path + "/nixos/tests/initrd-network-ssh";
  passphrase = "unlock-test-passphrase";

  # Encrypted before the VM first boots, so that boot already waits for the passphrase.
  disk = pkgs.runCommand "encrypted.img" { nativeBuildInputs = [ pkgs.cryptsetup ]; } ''
    truncate -s 32M $out
    printf %s ${passphrase} | cryptsetup luksFormat --batch-mode --disable-locks \
      --pbkdf pbkdf2 --pbkdf-force-iterations 1000 $out -
  '';

  unlock = pkgs.writeText "unlock.exp" ''
    set timeout 60
    spawn ssh -tt -p 2222 -i /root/unlock server
    expect {
      "passphrase" {}
      timeout { exit 1 }
      eof { exit 1 }
    }
    send "${passphrase}\r"
    expect eof
  '';
in
pkgs.testers.runNixOSTest {
  name = "suveraen-unlock";

  nodes = {
    server =
      { lib, ... }:
      {
        imports = [ module ];

        virtualisation.qemu.drives = [
          {
            name = "encrypted";
            file = "${disk}";
            driveExtraOpts = {
              format = "raw";
              snapshot = "on";
            };
            deviceExtraOpts.serial = "encrypted";
          }
        ];
        # Stands in for the system disks: the boot doesn't go on until it is unlocked.
        boot.initrd.luks.devices = lib.mkVMOverride { data.device = "/dev/disk/by-id/virtio-encrypted"; };

        # The VM has no boot loader to add secrets to the initrd, so its host key comes from the store.
        boot.initrd.network.ssh.hostKeys = lib.mkForce [ (bootKeys + "/ssh_host_ed25519_key") ];

        networking.hostId = "0400bdef";
        system.stateVersion = "26.05";

        suveraen = {
          adminKeys = [ keys.snakeOilEd25519PublicKey ];
          storage.systemDisks = [ "/dev/disk/by-id/test-0" ];
          network.interface = "eth0";
          unlock.keys = [ (lib.fileContents (bootKeys + "/id_ed25519.pub")) ];
          alerts = {
            urlFile = toString (pkgs.writeText "alerts-url" "http://127.0.0.1:1/ops");
            tokenFile = toString (pkgs.writeText "alerts-token" "unused");
            smart = false;
          };
        };
      };

    client = {
      environment.systemPackages = [ pkgs.expect ];
      programs.ssh.knownHosts.server-boot = {
        hostNames = [ "[server]:2222" ];
        publicKeyFile = bootKeys + "/ssh_host_ed25519_key.pub";
      };
    };
  };

  testScript = ''
    start_all()
    server.wait_for_console_text("passphrase for disk data")
    client.wait_for_unit("multi-user.target")
    client.succeed(
        "install -m 600 ${bootKeys}/id_ed25519 /root/unlock"
        " && install -m 600 ${keys.snakeOilEd25519PrivateKey} /root/admin"
    )

    with subtest("An unlock-only key gets no port forwarding at boot"):
        client.wait_until_succeeds("nc -z -w 5 server 2222", timeout=120)
        # A forward that was set up would keep ssh running until the timeout, without this message.
        out = client.fail(
            "timeout 30 ssh -p 2222 -i /root/unlock -N -o ExitOnForwardFailure=yes -R 2000:127.0.0.1:22 server 2>&1"
        )
        assert "remote port forwarding failed" in out, out

    with subtest("An unlock-only key answers the passphrase prompt, and the boot goes on"):
        client.succeed("expect ${unlock}")
        server.wait_for_unit("multi-user.target")
        server.succeed("test -b /dev/mapper/data")

    with subtest("An unlock-only key can't log in to the running system"):
        login = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
        client.succeed(f"{login} -i /root/admin server true")
        client.fail(f"{login} -i /root/unlock server true")
  '';
}
