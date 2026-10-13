# suveraen

Free and open-source services for a small community, self-hosted: files and documents, photos, chat, passwords and more, federated where that applies. Everything is public, including the configuration of the servers it runs on, so all of it can be scrutinized.

It runs on Kubernetes (k3s) over NixOS, built to start on one server and grow to several with failover.

**Status:** the server layer is in place. The cluster's own services (storage, databases, certificates, accounts) come next, then the apps.

## Layout

- `nixos/`: the server layer, NixOS modules configured under `suveraen.*`.
  - `storage.nix`: two mirrored, encrypted SSDs (ZFS) for the system and local volumes. Other disks are left for the cluster's storage. Hourly snapshots, scrubs, health checks.
  - `unlock.nix`: an SSH server during boot that takes the disk passphrase.
  - `network.nix`: static or DHCP IPv4, static IPv6.
  - `cluster.nix`: a k3s server with embedded etcd, secrets encrypted at rest, WireGuard between nodes, dual-stack networking. It installs [Flux](https://fluxcd.io), which keeps the cluster in sync with this repository.
  - `alerts.nix`: failed jobs and disk or RAID problems are posted to an [ntfy](https://ntfy.sh) topic.
  - `upgrade.nix`: servers follow this repository nightly and never reboot by themselves.
- `checks/`: `example.nix` builds a server with stand-in values; `vm.nix` boots one in a VM and tests it. CI runs both on every push.
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

`checks/example.nix` shows every setting a server needs.

## License

[AGPL-3.0-or-later](LICENSE).
