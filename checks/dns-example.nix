# Stand-in DNS settings shared by the example hosts: a hidden signer, two published servers and a provider's.
{
  suveraen.dns = {
    signer = "example";
    servers = {
      example.addresses = [
        "203.0.113.10"
        "2001:db8::2"
      ];
      example-watcher = {
        name = "ns1.example.net";
        addresses = [
          "203.0.113.20"
          "2001:db8:2::1"
        ];
      };
      example-ns = {
        name = "ns2.example.net";
        addresses = [
          "203.0.113.30"
          "2001:db8:3::1"
        ];
      };
    };
    external.provider = {
      names = [ "ns3.example.com" ];
      notify = [ "198.51.100.53" ];
      transfer = [ "198.51.100.54" ];
    };
    contact = "hostmaster@example.net";
    zones = {
      "example.net" = {
        mail = true;
        records = {
          "@".MX = [ "10 mail.example.net." ];
          "@".TXT = [ ''"v=spf1 mx -all"'' ];
          _dmarc.TXT = [ ''"v=DMARC1; p=reject"'' ];
          mail.A = [ "203.0.113.10" ];
        };
        certificates = [ "mail" ];
      };
      "example.org" = {
        records.idm.A = [ "203.0.113.10" ];
        certificates = [ "idm" ];
        ds = [ "12345 13 2 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ];
      };
      "example.app" = {
        records."*".A = [ "203.0.113.10" ];
        wildcard = true;
        certificates = [ "*" ];
      };
    };
    acme.zone = "acme.example.net";
    caa = {
      issuers = [
        {
          domain = "letsencrypt.org";
          accountUri = "https://acme-v02.api.letsencrypt.org/acme/acct/1";
        }
        { domain = "sectigo.com"; }
      ];
      validationMethods = [ "dns-01" ];
    };
    transferKeyFile = "/run/secrets/knot-transfer";
    backup.recipients = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN9QsUU2i+9+MwdvtxOsPVD6L24UHYJXVJRI2oe+9oHP example"
    ];
  };
}
