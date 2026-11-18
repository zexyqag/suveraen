{
  config,
  lib,
  pkgs,
  ...
}:
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

  config = lib.mkMerge [
    {
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
    }

    # The clock as chrony itself tells it: the kernel's flag, which node_exporter reads, stays unsynchronised under the
    # RTC trimming chrony does here, and its offset is one chrony doesn't keep.
    (lib.mkIf config.suveraen.metrics.enable {
      suveraen.metrics = {
        textfiles.chrony = {
          after = [ "chronyd.service" ];
          path = [
            config.services.chrony.package
            pkgs.gawk
          ];
          # Over chrony's command port, which answers this from loopback, as its socket wants a writable directory.
          script = ''
            chronyc -n -h 127.0.0.1 -c tracking | awk -F, '{
              leap = $14 == "Normal" ? 0 : $14 == "Insert second" ? 1 : $14 == "Delete second" ? 2 : 3
              print "# TYPE chrony_tracking_leap_status gauge"
              print "chrony_tracking_leap_status " leap
              print "# TYPE chrony_tracking_reference_timestamp_seconds gauge"
              print "chrony_tracking_reference_timestamp_seconds " $4
              print "# TYPE chrony_tracking_system_time_seconds gauge"
              print "chrony_tracking_system_time_seconds " $5
            }'
          '';
          families = [
            "chrony_tracking_leap_status"
            "chrony_tracking_reference_timestamp_seconds"
            "chrony_tracking_system_time_seconds"
          ];
        };
        rules = {
          # chrony keeps saying it is synchronised once its last source is gone, but sets the clock no more. Longer
          # than a test runs, whose VMs reach no time server.
          "clock unsynchronised" = {
            expr = "max(chrony_tracking_leap_status == 3 or time() - chrony_tracking_reference_timestamp_seconds > 3600)";
            for = "6h";
            title = "clock unsynchronised";
            cleared = "clock synchronised again";
            detail = "no time source has set the clock for six hours or more";
            reads = [
              "chrony_tracking_leap_status"
              "chrony_tracking_reference_timestamp_seconds"
            ];
          };
          "clock off" = {
            expr = "abs(chrony_tracking_system_time_seconds) > 1";
            title = "clock off";
            cleared = "clock right again";
            detail = "{{ $value | humanizeDuration }} off the time sources'";
            reads = [ "chrony_tracking_system_time_seconds" ];
          };
        };
      };
    })
  ];
}
