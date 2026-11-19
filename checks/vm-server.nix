# A cluster server as a node of a NixOS test: it boots from its own plain disk, so there's nothing to unlock, and
# reaches the outside through eth0 and its peers on eth1. A test that runs Ceph adds vm-ceph.nix, for its disks.
{
  config,
  pkgs,
  ...
}:
{
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

  # The tests run the upgrade's steps by hand; the timer would fire into a nightly run.
  systemd.timers.nixos-upgrade.enable = false;
  # The node's store is the host's under an overlay held in memory: optimising it would copy the closure up into that
  # memory, and collecting it has nothing of the node's own to free.
  systemd.timers.nix-optimise.enable = false;
  systemd.timers.nix-gc.enable = false;

  networking.hostId = "0400bdef";
  system.stateVersion = "26.05";

  suveraen = {
    storage = {
      systemDisks = [
        "/dev/disk/by-id/test-0"
        "/dev/disk/by-id/test-1"
      ];
      encrypted = false;
    };
    # "en*" would also match eth1, the test network, through its alternative names.
    network.interface = "eth0";
    alerts.smart = false;
    cluster = {
      enable = true;
      tokenFile = toString (pkgs.writeText "k3s-token" "suveraen-test-token");
      nodeIP = [
        config.networking.primaryIPAddress
        "fd00::2"
      ];
      stun.port = 3478;
    };
  };
}
