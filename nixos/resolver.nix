{ config, ... }:
{
  config = {
    assertions = [
      {
        assertion = config.networking.nameservers == [ ];
        message = "Hosts resolve names with their own Unbound; networking.nameservers would send queries elsewhere.";
      }
    ];

    # With no resolver configured, systemd-resolved falls back to Cloudflare, Google and Quad9.
    services.resolved.enable = false;

    services.unbound = {
      enable = true;
      settings.server = {
        interface = [
          "127.0.0.1"
          "::1"
        ];
        access-control = [
          "127.0.0.0/8 allow"
          "::1/128 allow"
        ];
        hide-identity = true;
        hide-version = true;
        prefetch = true;
        aggressive-nsec = true;
      };
    };
  };
}
