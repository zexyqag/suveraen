# Boots the modules in VMs: sign-on through nginx with certificates from a test ACME server,
# an alert reaching ntfy, and a backup to another machine restored again.
{ pkgs, module }:
let
  domain = "example.test";
  idm = "idm.${domain}";

  keys = pkgs.runCommand "test-keys" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir $out
    ssh-keygen -q -t ed25519 -N "" -C backup-client -f $out/client
    ssh-keygen -q -t ed25519 -N "" -C backup-host -f $out/host
  '';
  readPub = name: builtins.readFile "${keys}/${name}.pub";
in
pkgs.testers.runNixOSTest {
  name = "suveraen";

  nodes = {
    acme = {
      imports = [ "${pkgs.path}/nixos/tests/common/acme/server" ];
    };

    ntfy = {
      services.ntfy-sh = {
        enable = true;
        settings = {
          base-url = "http://ntfy";
          listen-http = ":80";
        };
      };
      networking.firewall.allowedTCPPorts = [ 80 ];
    };

    backup = {
      services.borgbackup.repos.server = {
        authorizedKeys = [ (readPub "client") ];
        path = "/var/lib/borgbackup/server";
      };
      environment.etc."ssh/test_host_key" = {
        source = "${keys}/host";
        mode = "0600";
      };
      services.openssh.hostKeys = [
        {
          path = "/etc/ssh/test_host_key";
          type = "ed25519";
        }
      ];
    };

    server =
      { lib, nodes, ... }:
      {
        imports = [ module ];

        virtualisation = {
          memorySize = 2048;
          emptyDiskImages = [ 1024 ];
          # The test creates this pool itself; on a real host disko does.
          fileSystems."/srv" = {
            device = "tank/srv";
            fsType = "zfs";
            options = [ "noauto" ];
          };
        };

        # No LUKS or boot-time SSH in the VM: it boots from its own plain disk.
        boot.initrd.luks.devices = lib.mkForce { };
        boot.initrd.network.enable = lib.mkForce false;

        networking.hostId = "0400bdef";
        networking.hosts."127.0.0.1" = [ idm ];
        security.acme.defaults.server = "https://${nodes.acme.test-support.acme.caDomain}/dir";
        security.pki.certificateFiles = [ nodes.acme.test-support.acme.caCert ];

        environment.etc."backup-key" = {
          source = "${keys}/client";
          mode = "0600";
        };

        suveraen = {
          inherit domain;
          adminKeys = [ (readPub "client") ];
          storage = {
            systemDisks = [
              "/dev/disk/by-id/test-0"
              "/dev/disk/by-id/test-1"
            ];
            bulkDisks = [
              "/dev/disk/by-id/test-2"
              "/dev/disk/by-id/test-3"
            ];
          };
          identity.enable = true;
          backup = {
            enable = true;
            repo = "borg@backup:.";
            knownHosts = "backup ${readPub "host"}";
            passphraseFile = toString (pkgs.writeText "passphrase" "test passphrase");
            sshKeyFile = "/etc/backup-key";
            paths = [ "/srv" ];
          };
          alerts.ntfyUrlFile = toString (pkgs.writeText "ntfy-url" "http://ntfy/alerts");
        };

        system.stateVersion = "26.05";
      };
  };

  testScript = ''
    start_all()

    acme.wait_for_unit("pebble.service")
    ntfy.wait_for_unit("ntfy-sh.service")
    backup.wait_for_unit("sshd.service")
    server.wait_for_unit("multi-user.target")

    with subtest("Kanidm answers through nginx with a certificate from the ACME server"):
        server.wait_for_unit("kanidm.service")
        server.wait_until_succeeds("curl -fsS https://${idm}/status | grep true", timeout=300)
        server.succeed("curl -fsS https://${idm}/ui/login")

    with subtest("Unknown names get no answer"):
        server.fail("curl -fsS --resolve other.${domain}:443:127.0.0.1 https://other.${domain}/")

    with subtest("A failing check sends an alert"):
        # The VM has no ZFS pools yet, so the health check fails.
        server.fail("systemctl start zfs-health.service")
        ntfy.wait_until_succeeds("curl -fsS 'http://localhost/alerts/json?poll=1' | grep zfs-health")

    with subtest("Backup from a snapshot and restore"):
        server.succeed(
            "zpool create -O mountpoint=none tank /dev/vdb",
            "zfs create -o mountpoint=legacy tank/srv",
            "mount /srv",
            "echo precious > /srv/file",
        )
        server.succeed("systemctl start borgbackup-job-suveraen.service")
        server.fail("zfs list -t snapshot tank/srv@backup")
        server.succeed(
            "rm /srv/file",
            "cd / && borg-job-suveraen extract ::$(borg-job-suveraen list --short --last 1) tmp/snapshot/srv/file",
            "grep precious /tmp/snapshot/srv/file",
        )
  '';
}
