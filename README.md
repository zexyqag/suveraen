# suveraen

Free and open-source services for a small community, self-hosted on NixOS: files and documents, photos, chat, passwords and more, federated where that applies. Everything is public, including the configuration of the servers it runs on, so all of it can be scrutinized.

**Status:** the foundation is in place (disks, boot, accounts, backups, alerts, updates). Services come next.

## Layout

- `modules/`: NixOS modules, configured under `suveraen.*`.
  - `storage.nix`: two mirrored, encrypted SSDs (ZFS) for the system, plus an optional mirrored, encrypted pair of bulk disks for files and photos. Hourly local snapshots, scrubs and health checks.
  - `unlock.nix`: an SSH server during boot that takes the disk passphrase.
  - `network.nix`: IPv4 from DHCP, static IPv6.
  - `web.nix`: nginx with Let's Encrypt certificates.
  - `identity.nix`: [Kanidm](https://kanidm.com), one account for every service.
  - `backup.nix`: nightly encrypted [Borg](https://www.borgbackup.org) backups to another machine, taken from snapshots.
  - `alerts.nix`: failed jobs and disk or RAID problems are posted to an [ntfy](https://ntfy.sh) topic.
  - `upgrade.nix`: hosts follow this repository nightly and never reboot by themselves.
- `checks/example.nix`: builds everything with stand-in values; CI runs it on every push.
- `.github/workflows/update.yml`: updates `flake.lock` daily once the check passes.

## Use

Add the flake as an input and import `nixosModules.default`:

```nix
{
  inputs.suveraen.url = "github:<owner>/suveraen";

  outputs = { suveraen, ... }: {
    nixosConfigurations.myhost = suveraen.inputs.nixpkgs.lib.nixosSystem {
      modules = [
        suveraen.nixosModules.default
        ./myhost.nix
      ];
    };
  };
}
```

`checks/example.nix` shows every setting a host needs.

## License

[AGPL-3.0-or-later](LICENSE).
