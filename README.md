# suveraen

Free and open-source services for a small community, self-hosted: files and documents, photos, chat, passwords and more, federated where that applies. Everything is public, including the configuration of the servers it runs on, so all of it can be scrutinized.

It runs on Kubernetes (k3s) over NixOS, built to start on one server and grow to several with failover. A small separate watcher machine keeps an eye on it from outside.

**Status:** the server layer is in place, and so is the frame for the cluster's own services: the gateway, certificates and the template every app follows. Storage, databases and accounts come next, then the apps.

## Layout

- `nixos/`: the server layer, NixOS modules configured under `suveraen.*`.
  - `storage.nix`: one disk or two mirrored (ZFS) for the system and the cluster's own state, encrypted unless the machine must reboot unattended. Container images and pods' scratch space are bounded, etcd and Ceph's monitors reserved space. The other disks are Ceph's, each under a stable name with a partition for its OSD's database on the system disks, mirrored over both, so losing either costs no OSD. Hourly snapshots, scrubs, health checks.
  - `unlock.nix`: on encrypted machines, an SSH server during boot that takes the disk passphrase, also from keys that may do nothing else.
  - `network.nix`: static or DHCP IPv4, static IPv6.
  - `resolver.nix`: every machine resolves names itself with [Unbound](https://nlnetlabs.nl/projects/unbound/) (DNSSEC, no outside resolver), and so do the cluster's pods.
  - `time.nix`: clocks follow several independent time servers over NTS, which authenticates their replies.
  - `cluster.nix`: a k3s server with embedded etcd, secrets encrypted at rest (secretbox), a cluster token read from a file, without which an etcd snapshot can't be restored, WireGuard between nodes, dual-stack networking. It installs [Flux](https://fluxcd.io), which keeps the cluster in sync with this repository; rights within a namespace don't extend to Flux, pods must meet the restricted Pod Security Standard (except in `rook-ceph`, where Ceph's daemons and CSI plugin run privileged), Services can't take external IPs, on the host pods reach only the API server, the kubelet, the resolver and, on the DNS signer, its Knot, and the platform's pods run ahead of tenants'.
  - `dns.nix`: authoritative DNS with [Knot](https://www.knot-dns.cz). A hidden server signs the zones (DNSSEC, one key per zone that never changes by itself) and is the only one that takes changes: certificate challenges, in a zone of their own, from cert-manager's key alone, which a restart of `knot-acme-key` replaces. Published secondaries, ours and a provider's, follow it. Zones get CAA records, and a null MX, SPF and DMARC unless they send mail. The keys are backed up after boot and daily, encrypted, and a secondary or a new signer takes them over from that backup, also while knot won't start without them.
  - `dns-check.nix`: the watcher checks every 15 minutes that all nameservers serve the same signed zones, that the signatures are being renewed, and that each parent delegates with the NS and DS records declared for the zone; problems reach ntfy through Gatus.
  - `watcher.nix`: the watcher. [ntfy](https://ntfy.sh) for alerts (only known accounts, instant on Android and iPhone, no account API or attachments) and [Gatus](https://gatus.io), which checks the public services and raises an alert when a server stops reporting in.
  - `alerts.nix`: failed jobs and disk or RAID problems are posted to the watcher's ntfy on a secret topic, with a second channel for when the watcher can't be reached; servers report in to Gatus every few minutes.
  - `source.nix`: the repository and branch a machine and its cluster follow, and the release signers: with signers set, Nix on the machine and Flux in the cluster refuse a branch head that none of them signed.
  - `upgrade.nix`: machines switch to their configuration from that branch nightly. Unencrypted ones reboot by themselves when needed; encrypted ones send an alert instead. A machine also alerts when the configuration it runs gets old.
- `kubernetes/`: what Flux applies, from the release branch.
  - `clusters/<name>/`: one directory per cluster, which a server's `suveraen.cluster.path` names. It lists the platform and the cluster's tenants, and holds its settings (including whether it is a test cluster, whose tenants are stand-ins), its secrets (the accounts at both CAs, encrypted on every cluster but a test one) and its hostname map, which gives each name to a tenant or one of its app namespaces; `test` is the one CI deploys.
    - `tenants/<id>/`: one tenant, under a random five-character ID: Kustomization and Secret `tenant-<id>` (its domains and keys, encrypted on every cluster but a test one) and the list of app templates it runs. The members are a tenant like any organisation.
  - `platform/`: the gateway (Gateway API on [Traefik](https://traefik.io)), certificates ([cert-manager](https://cert-manager.io)) from a public ACME CA with a second one on standby, over DNS-01 through the node's own nameserver, restarts on changed settings ([Reloader](https://github.com/stakater/Reloader)), storage on [Ceph](https://ceph.io) run by [Rook](https://rook.io) (encrypted disks, three copies of everything, block volumes with snapshots that go with their claims and an object store in the cluster; its namespace is the one privileged exception), copies of apps' volumes ([VolSync](https://volsync.readthedocs.io)) and the policies every tenant and app is held to.
  - `components/`: what a tenant's apps get: its own namespace per app, closed by default and held to a quota, whose charts can act only there (`app`); the tenant's label on all of it, and the tenant's own settings but never the cluster's secrets (`tenant`); an app's own database and role in its tenant's PostgreSQL, reached from its namespace alone (`db`, `db-client`); web ports anywhere outside the cluster, for the platform's backup jobs alone (`internet`); a volume copied to both providers with restic, encrypted with the app's own password, which the app's charts can't delete, and made anew from the latest restore from either provider (`volsync`).
  - `edge/`: one host of a tenant's app: a Gateway with a single listener for that name and its certificate, in the gateway namespace where no app reaches, and the route to the app. The host is on the tenant's app domain (`app`), on its own domain (`identity`), or that domain itself (`apex`).
  - `apps/`: one directory per app. `ks.yaml` is the template a tenant lists: the app, the hosts every tenant gets and its database, if it has one; `edge-<key>.yaml` adds a host a tenant may choose. `postgres` is the tenant's own PostgreSQL ([CloudNativePG](https://cloudnative-pg.io)), one cluster for all its apps, which archives its WAL and base backups to the tenant's bucket in the cluster, copies its running generation to two providers encrypted with the tenant's own key, and is restored as a new generation of itself, from the cluster's bucket or a provider's copy.
- `release/approve.sh`: `approve` shows what changed on `staging` since the last release, and once you confirm, signs it and publishes it to `main`. For a repository on GitHub it refuses until every check on the candidate has passed.
- `checks/`: `server.nix`, `watcher.nix` and `ns.nix` (a nameserver of its own) build each kind of machine with stand-in values; `vm.nix` boots both in VMs and tests them together, down to restoring the server from an etcd snapshot; `unlock.nix` boots an encrypted machine and unlocks it over SSH; `storage.nix` installs a server's disk layout onto blank disks, boots it and checks the partitions and datasets the cluster relies on; `dns.nix` boots a signer, its secondaries and a parent zone, and checks that answers validate, changes reach every nameserver, the challenge zone takes only what it should and a test CA validates through it, the watcher notices what goes wrong, and a secondary takes over signing from the key backup, as does a signer that lost its keys; `approve.nix` runs the release command against a scratch repository; `render.nix` renders every cluster under `kubernetes/` the way Flux would, through each tenant to its apps and hosts, and checks the rules tenants and apps are held to; `render-cases.nix` breaks copies of `kubernetes/` and checks render refuses each for the right reason. CI runs them on every push, each on a runner of its own. `e2e.nix` (`nix run .#e2e`) boots a server with internet access and lets Flux deploy `kubernetes/clusters/test`, two tenants side by side, from a signed commit, with a test ACME CA issuing every host's certificate over DNS-01 and two test S3 providers keeping the off-site copies, from which it restores a tenant's PostgreSQL and an app's volume; CI runs it after the others.
- `.github/workflows/update.yml`: updates `flake.lock` daily once the checks pass. The checks run with a read-only token; only a separate small job can push. Actions are pinned to commit hashes.

## Releases

Changes land on `staging`, which the watcher runs first. The servers and the cluster only deploy `main`, and `main` only moves through releases signed with a key listed in `release/signers`. A server also refuses a release older than the one it runs.

To release, work in a clone of the repository with git's `user.signingkey` set to your SSH signing key (a security key works). The very first time, run `nix run .#approve -- --first-release`. After each release, approve prints the command for the next one: it runs approve from the last signed release, whose signature Nix checks first, so your working tree never decides what gets signed.

Each release can carry a warrant canary: approve shows its statements and signs them into the release's commit message only if you type `true`. Anyone can read it on `main` and check its signature against `release/signers`. If the newest release has no canary, one of its statements may no longer hold.

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

`checks/server.nix`, `checks/watcher.nix` and `checks/ns.nix` show every setting each kind of machine needs.

## License

[AGPL-3.0-or-later](LICENSE).
