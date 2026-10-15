# Test only: the TSIG key the test nameservers authenticate transfers and NOTIFYs with, in the store.
pkgs: rec {
  secret = "3uWg0rTnLiwZ1WjWZGp4ADEpbgyOnzR5WwkbPmdE8Ls=";
  file = pkgs.writeText "transfer.conf" ''
    key:
      - id: transfer
        algorithm: hmac-sha256
        secret: ${secret}
  '';
}
