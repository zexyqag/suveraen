# suveraen

Free and open-source services for a small community, self-hosted: files and documents, photos, chat, passwords and more, federated where that applies. Everything is public, including the configuration of the servers it runs on, so all of it can be scrutinized.

It runs on Kubernetes (k3s) over NixOS, built to start on one server and grow to several with failover. A small separate watcher machine keeps an eye on it from outside.

**Status:** the server layer is in place. The cluster's own services (storage, databases, certificates, accounts) come next, then the apps.

## Layout

- `nixos/`: the server layer, NixOS modules configured under `suveraen.*`.
  - `storage.nix`: one disk or two mirrored (ZFS) for the system and local volumes, encrypted unless the machine must reboot unattended. Other disks are left for the cluster's storage. Hourly snapshots, scrubs, health checks.
  - `unlock.nix`: on encrypted machines, an SSH server during boot that takes the disk passphrase.
  - `network.nix`: static or DHCP IPv4, static IPv6.
  - `cluster.nix`: a k3s server with embedded etcd, secrets encrypted at rest, WireGuard between nodes, dual-stack networking. It installs [Flux](https://fluxcd.io), which keeps the cluster in sync with this repository.
  - `watcher.nix`: the watcher. [ntfy](https://ntfy.sh) for alerts (only known accounts, instant on Android and iPhone) and [Gatus](https://gatus.io), which checks the public services and raises an alert when a server stops reporting in.
  - `alerts.nix`: failed jobs and disk or RAID problems are posted to the watcher's ntfy; servers report in to Gatus every few minutes.
  - `upgrade.nix`: machines follow this repository nightly. Unencrypted ones reboot by themselves when needed; encrypted ones send an alert instead.
- `checks/`: `server.nix` and `watcher.nix` build each kind of machine with stand-in values; `vm.nix` boots both in VMs and tests them together. CI runs them on every push.
- `.github/workflows/update.yml`: updates `flake.lock` daily once the checks pass.

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

`checks/server.nix` and `checks/watcher.nix` show every setting each kind of machine needs.

## License

[AGPL-3.0-or-later](LICENSE).
