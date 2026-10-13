{ config, lib, ... }:
let
  cfg = config.suveraen.network;

  uplink = {
    matchConfig.Name = cfg.interface;
    networkConfig.DHCP = if cfg.ipv4 == null then "ipv4" else "no";
    address = lib.filter (a: a != null) [
      cfg.ipv4
      cfg.ipv6
    ];
    routes =
      lib.optional (cfg.ipv4Gateway != null) {
        Gateway = cfg.ipv4Gateway;
        # Hosts like Hetzner's put the gateway outside the address's own subnet.
        GatewayOnLink = true;
      }
      ++ lib.optional (cfg.ipv6Gateway != null) { Gateway = cfg.ipv6Gateway; };
  };
in
{
  options.suveraen.network = {
    interface = lib.mkOption {
      type = lib.types.str;
      default = "en*";
      description = "Name (glob) of the uplink interface.";
    };

    ipv4 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "203.0.113.10/32";
      description = "Static IPv4 address with prefix length; null takes one from DHCP.";
    };

    ipv4Gateway = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "203.0.113.1";
      description = "IPv4 default gateway for a static address.";
    };

    ipv6 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "2001:db8:1:2::1/64";
      description = "Static IPv6 address with prefix length.";
    };

    ipv6Gateway = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "fe80::1";
      description = "IPv6 default gateway.";
    };
  };

  config = {
    assertions = [
      {
        assertion = (cfg.ipv4 == null) == (cfg.ipv4Gateway == null);
        message = "suveraen.network.ipv4 and ipv4Gateway go together.";
      }
      {
        assertion = (cfg.ipv6 == null) == (cfg.ipv6Gateway == null);
        message = "suveraen.network.ipv6 and ipv6Gateway go together.";
      }
    ];

    networking.useNetworkd = true;
    networking.useDHCP = false;
    systemd.network.networks."10-uplink" = uplink;
    # The boot-time SSH server needs the network before the disks are unlocked.
    boot.initrd.systemd.network.networks."10-uplink" = uplink;
  };
}
