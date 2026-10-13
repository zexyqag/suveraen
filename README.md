# suveraen

Free and open-source services for a small community, self-hosted: files and documents, photos, chat, passwords and more, federated where that applies. Everything is public, including the configuration of the servers it runs on, so all of it can be scrutinized.

It runs on Kubernetes (k3s) over NixOS, built to start on one server and grow to several with failover. A small separate watcher machine keeps an eye on it from outside.

**Status:** the server layer is in place. The cluster's own services (storage, databases, certificates, accounts) come next, then the apps.

## Layout

- `nixos/`: the server layer, NixOS modules configured under `suveraen.*`.
  - `storage.nix`: one disk or two mirrored (ZFS) for the system and local volumes, encrypted unless the machine must reboot unattended. Other disks are left for the cluster's storage. Hourly snapshots, scrubs, health checks.
  - `unlock.nix`: on encrypted machines, an SSH server during boot that takes the disk passphrase, also from keys that may do nothing else.
  - `network.nix`: static or DHCP IPv4, static IPv6.
  - `resolver.nix`: every machine resolves names itself with [Unbound](https://nlnetlabs.nl/projects/unbound/) (DNSSEC, no outside resolver), and so do the cluster's pods.
  - `time.nix`: clocks follow several independent time servers over NTS, which authenticates their replies.
  - `cluster.nix`: a k3s server with embedded etcd, secrets encrypted at rest, WireGuard between nodes, dual-stack networking. It installs [Flux](https://fluxcd.io), which keeps the cluster in sync with this repository; rights within a namespace don't extend to Flux, pods must meet the restricted Pod Security Standard unless the platform labels their namespace otherwise, and on the host they reach only the API server, the kubelet and the resolver.
  - `watcher.nix`: the watcher. [ntfy](https://ntfy.sh) for alerts (only known accounts, instant on Android and iPhone, no account API or attachments) and [Gatus](https://gatus.io), which checks the public services and raises an alert when a server stops reporting in.
  - `alerts.nix`: failed jobs and disk or RAID problems are posted to the watcher's ntfy on a secret topic, with a second channel for when the watcher can't be reached; servers report in to Gatus every few minutes.
  - `source.nix`: the repository and branch a machine and its cluster follow, and the release signers: with signers set, Nix on the machine and Flux in the cluster refuse a branch head that none of them signed.
  - `upgrade.nix`: machines switch to their configuration from that branch nightly. Unencrypted ones reboot by themselves when needed; encrypted ones send an alert instead. A machine also alerts when the configuration it runs gets old.
- `release/approve.sh`: `approve` shows what changed on `staging` since the last release, and once you confirm, signs it and publishes it to `main`.
- `checks/`: `server.nix` and `watcher.nix` build each kind of machine with stand-in values; `vm.nix` boots both in VMs and tests them together; `unlock.nix` boots an encrypted machine and unlocks it over SSH; `approve.nix` runs the release command against a scratch repository. CI runs them on every push.
- `.github/workflows/update.yml`: updates `flake.lock` daily once the checks pass. The checks run with a read-only token; only a separate small job can push. Actions are pinned to commit hashes.

## Releases

Changes land on `staging`, which the watcher runs first. The servers and the cluster only deploy `main`, and `main` only moves through releases signed with a key listed in `release/signers`. A server also refuses a release older than the one it runs.

To release, work in a clone of the repository with git's `user.signingkey` set to your SSH signing key (a security key works). The very first time, run `nix run .#approve -- --first-release`. After each release, approve prints the command for the next one: it runs approve from the last signed release, whose signature Nix checks first, so your working tree never decides what gets signed.

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
