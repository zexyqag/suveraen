{ config, lib, ... }:
{
  options.suveraen.timeServers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    # Four independent operators: Netnod, PTB, TimeNL (SIDN Labs) and FAU.
    default = [
      "nts.netnod.se"
      "ptbtime1.ptb.de"
      "ptbtime2.ptb.de"
      "any.time.nl"
      "ntp3.fau.de"
    ];
    description = ''
      NTP servers with Network Time Security (NTS), so a forged time reply is rejected. Clocks matter for TOTP,
      passkeys, certificates, etcd and Ceph. Use several operators so one wrong clock is outvoted.
    '';
  };

  config = {
    services.chrony = {
      enable = true;
      servers = config.suveraen.timeServers;
      enableNTS = true;
      extraConfig = ''
        minsources 2
      '';
    };
  };
}
