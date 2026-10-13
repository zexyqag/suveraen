{
  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;
    # Requests for names we don't serve get no answer and no certificate.
    virtualHosts."_" = {
      default = true;
      rejectSSL = true;
      locations."/".return = "444";
    };
  };

  security.acme.acceptTerms = true;

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
