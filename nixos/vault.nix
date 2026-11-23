# Each tenant's password vault from the servers, with suveraen-vault (vault.sh), for what no page of the vault's offers:
#   check: what the servers' checks judge (host-checks/vault.jq), with no credential: each account, the Kanidm person
#     it is linked to, whether it is enabled and how many devices hold a session of it, and how Kanidm answers for
#     those people;
#   users TENANT: the same of one tenant, for the operator;
#   offboard TENANT ID: ends every way into the account of a person Kanidm let go, by the account's ID or its person's:
#     asks the relay to forget their phones, ends their devices' sessions and disables the account, its API key and its
#     Sends with it;
#   erase TENANT ID: does that, then deletes the account, its vault and its files;
#   relink TENANT PERSON NEW-PERSON: links the account of a person Kanidm lost to the person it made again for them.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  vault = pkgs.writeShellApplication {
    name = "suveraen-vault";
    runtimeInputs = [
      config.services.k3s.package
      pkgs.jq
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.util-linux
    ];
    text = ''
      idm=${lib.getExe config.suveraen.idm.command}
    ''
    + builtins.readFile ./tenant-apps.sh
    + builtins.readFile ./vault.sh;
  };
in
{
  config = lib.mkIf config.suveraen.cluster.enable {
    environment.systemPackages = [ vault ];
    suveraen.checks = {
      families.vault = ./host-checks/vault.jq;
      told.vault.command = vault;
    };
  };
}
