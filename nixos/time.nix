{ config, lib, ... }:
{
  options.suveraen.timeServers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    # One server per operator (Netnod, PTB, TimeNL, FAU), so each counts as an independent vote.
    default = [
      "nts.netnod.se"
      "ptbtime1.ptb.de"
      "any.time.nl"
      "ntp3.fau.de"
    ];
    description = ''
      NTP servers with Network Time Security (NTS), so a forged time reply is rejected. Clocks matter for TOTP,
      passkeys, certificates, etcd and Ceph. Use one server from each of several operators so one wrong clock is
      outvoted. Names containing "pool" become pool entries.
    '';
  };

  config = {
    services.chrony = {
      enable = true;
      servers = config.suveraen.timeServers;
      enableNTS = true;
      # A clock reset to the past (dead RTC battery, board swap) would fail DNSSEC and the servers' certificates,
      # so time could never be fetched; start from the last known time instead.
      extraFlags = [ "-s" ];
      extraConfig = ''
        minsources 2
      '';
    };
  };
}
