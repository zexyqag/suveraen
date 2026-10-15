# Boots a hidden signer, two published secondaries (ns1 on the watcher, ns2 on its own), a provider's secondary
# without TSIG and a client that holds the parent zone. A signer refuses to start until it has the key whose DS the
# parent publishes; every nameserver answers with signatures that validate; the zones carry what the settings say;
# changes reach every nameserver by NOTIFY and IXFR; the ACME zone takes TXT records at _acme-challenge names with
# its key, which a restart replaces, and refuses everything else; the watcher's check runs on a timer, passes, and
# catches a lagging nameserver, a DS the parent shouldn't publish, signatures running out and a copy it can't read;
# and ns2 takes over signing from the key backup with the same keys, and gets them back from it after losing them,
# while the guard keeps knot down.
{ pkgs, module }:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  adminKey = keys.snakeOilEd25519PublicKey;
  transferKey = import ./transfer-key.nix pkgs;

  # Test only: example.test's key, made before the signer first starts, and its DS, which the parent publishes.
  exampleKey = pkgs.writeText "example.test.pem" ''
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgnNHrHZRJOzmgkwoH
    eV0MOHB1Rc32jAWI3+Ag7clyqtOhRANCAAQfuYjR8w6IWXedPioZ1mFmQfdyx2uF
    qLX54PXX0TOg5a/u6JTgU/saZ6Uy+keAJHAh7TuJfrHKNkm+uymuKC8i
    -----END PRIVATE KEY-----
  '';
  exampleDS = "34533 13 2 c5252d0bd05638256c4884ba430e61c899579ffb6f64f2d452da89185a52e105";

  gatusToken = "tk_suveraentestgatus000000000000";
  secrets = pkgs.runCommand "dns-test-secrets" { nativeBuildInputs = [ pkgs.ntfy-sh ]; } ''
    mkdir $out
    hash() { printf '%s\n%s\n' "$1" "$1" | ntfy user hash | grep -o '\$2a\$.*'; }
    cat > $out/ntfy.env <<EOF
    NTFY_AUTH_USERS='phone:$(hash unused):user,publisher:$(hash unused):user,gatus:$(hash unused):user'
    NTFY_AUTH_TOKENS='gatus:${gatusToken}'
    EOF
    cat > $out/gatus.env <<EOF
    NTFY_TOPIC=ops
    NTFY_TOKEN=${gatusToken}
    DNS_TOKEN=dnstesttoken
    EOF
  '';

  addresses = node: [
    node.networking.primaryIPAddress
    node.networking.primaryIPv6Address
  ];

  topology =
    nodes:
    { lib, ... }:
    {
      suveraen.dns = {
        signer = lib.mkDefault "signer";
        servers = {
          signer.addresses = addresses nodes.signer;
          ns1 = {
            name = "ns1.example.test";
            addresses = addresses nodes.ns1;
          };
          ns2 = {
            name = "ns2.example.test";
            addresses = addresses nodes.ns2;
          };
        };
        external.ext = {
          names = [ "ns3.ext.test" ];
          notify = [ nodes.ext.networking.primaryIPAddress ];
          transfer = [ nodes.ext.networking.primaryIPAddress ];
        };
        contact = "hostmaster@example.test";
        zones = {
          "example.test" = {
            mail = true;
            ds = [ exampleDS ];
            records = {
              "@".MX = [ "10 mail.example.test." ];
              "@".TXT = [ ''"v=spf1 mx -all"'' ];
              _dmarc.TXT = [ ''"v=DMARC1; p=reject"'' ];
              mail.A = [ "192.0.2.25" ];
            };
          };
          "one.test" = {
            records.idm.A = [ "192.0.2.10" ];
            certificates = [ "idm" ];
          };
        };
        acme = {
          zone = "acme.example.test";
          clients = [ nodes.client.networking.primaryIPAddress ];
        };
        caa.issuers = [ { domain = "letsencrypt.org"; } ];
        transferKeyFile = toString transferKey.file;
        backup.recipients = [ adminKey ];
      };
    };

  common =
    { nodes, ... }:
    {
      imports = [
        module
        (topology nodes)
      ];
      networking.hostId = "8425e349";
      system.stateVersion = "26.05";
      # age decrypts the key backup on ns2; for real, that happens on the key holder's machine.
      environment.systemPackages = [
        pkgs.jq
        pkgs.age
      ];
      suveraen = {
        adminKeys = [ adminKey ];
        storage = {
          systemDisks = [ "/dev/disk/by-id/test-0" ];
          encrypted = false;
        };
        network.interface = "eth0";
        alerts = {
          urlFile = toString (pkgs.writeText "alerts-url" "http://127.0.0.1:9/ops");
          tokenFile = toString (pkgs.writeText "alerts-token" "unused");
          smart = false;
        };
      };
    };

  promoted = {
    suveraen.dns.signer = "ns2";
  };
in
pkgs.testers.runNixOSTest {
  name = "suveraen-dns";

  nodes = {
    signer = {
      imports = [ common ];
      suveraen.dns.self = "signer";
      specialisation.changed.configuration.suveraen.dns.zones."one.test".records.www.A = [ "192.0.2.80" ];
    };

    ns1 =
      { lib, nodes, ... }:
      {
        imports = [ common ];
        suveraen = {
          dns = {
            self = "ns1";
            check.enable = true;
          };
          watcher = {
            enable = true;
            ntfyHost = "alerts.test";
            statusHost = "status.test";
            readers = [ "phone" ];
            ntfyEnvironmentFile = "${secrets}/ntfy.env";
            gatusEnvironmentFile = "${secrets}/gatus.env";
          };
        };
        services.nginx.virtualHosts = lib.genAttrs [ "alerts.test" "status.test" ] (_: {
          forceSSL = lib.mkForce false;
          enableACME = lib.mkForce false;
        });
        # The client holds the parent zone; it isn't signed.
        services.unbound.settings = {
          server = {
            local-zone = [ ''"test." nodefault'' ];
            domain-insecure = [ "test." ];
          };
          stub-zone = [
            {
              name = "test.";
              stub-addr = [ nodes.client.networking.primaryIPAddress ];
            }
          ];
        };
        specialisation.promoted.configuration = promoted;
      };

    ns2 = {
      imports = [ common ];
      suveraen.dns.self = "ns2";
      specialisation.promoted.configuration = promoted;
    };

    # Stands in for the provider's secondary: transfers by address, no TSIG, both possible signers as primaries.
    ext =
      { nodes, ... }:
      {
        networking.firewall = {
          allowedTCPPorts = [ 53 ];
          allowedUDPPorts = [ 53 ];
        };
        services.knot = {
          enable = true;
          settings = {
            server.listen = map (a: "${a}@53") (addresses nodes.ext);
            remote = {
              signer.address = [ nodes.signer.networking.primaryIPAddress ];
              ns2.address = [ nodes.ns2.networking.primaryIPAddress ];
            };
            acl.notify = {
              address = addresses nodes.signer ++ addresses nodes.ns2;
              action = "notify";
            };
            template.default = {
              master = [
                "signer"
                "ns2"
              ];
              acl = [ "notify" ];
              zonefile-sync = -1;
              zonefile-load = "none";
              journal-content = "all";
            };
            zone = {
              "example.test" = { };
              "one.test" = { };
            };
          };
        };
      };

    # Holds the parent zone test., sends updates the way cert-manager does, and validates answers.
    client =
      { nodes, ... }:
      {
        networking.firewall = {
          allowedTCPPorts = [ 53 ];
          allowedUDPPorts = [ 53 ];
        };
        environment.systemPackages = [ pkgs.unbound ];
        services.knot = {
          enable = true;
          settings = {
            server.listen = [ "${nodes.client.networking.primaryIPAddress}@53" ];
            template.default = {
              zonefile-sync = -1;
              journal-content = "all";
            };
            zone."test".file = pkgs.writeText "test.zone" ''
              $ORIGIN test.
              $TTL 60
              @ SOA client.test. hostmaster.test. 1 3600 900 604800 60
              @ NS client.test.
              client A ${nodes.client.networking.primaryIPAddress}
              example NS ns1.example.test.
              example NS ns2.example.test.
              example NS ns3.ext.test.
              example DS ${exampleDS}
              ns1.example A ${nodes.ns1.networking.primaryIPAddress}
              ns1.example AAAA ${nodes.ns1.networking.primaryIPv6Address}
              ns2.example A ${nodes.ns2.networking.primaryIPAddress}
              ns2.example AAAA ${nodes.ns2.networking.primaryIPv6Address}
              one NS ns1.example.test.
              one NS ns2.example.test.
              one NS ns3.ext.test.
              ns3.ext A ${nodes.ext.networking.primaryIPAddress}
            '';
          };
        };
      };
  };

  testScript =
    { nodes, ... }:
    let
      ip = node: nodes.${node}.networking.primaryIPAddress;
      ip6 = node: nodes.${node}.networking.primaryIPv6Address;
    in
    ''
      import re

      start_all()
      for m in [ns1, ns2, ext, client]:
          m.wait_for_unit("knot.service")

      with subtest("A new signer refuses to start until it has the key whose DS the parent publishes"):
          signer.wait_until_succeeds("journalctl -u knot | grep -q 'No key for example.test matches its published DS'")
          signer.wait_until_succeeds("systemctl is-failed knot")
          signer.succeed(
              "keymgr example.test import-pem ${exampleKey} ksk=yes zsk=yes && chown -R knot:knot /var/lib/knot/keys"
              " && systemctl start knot"
          )

      top = ["example.test", "one.test"]
      acme = "acme.example.test"
      servers = {"ns1": "${ip "ns1"}", "ns2": "${ip "ns2"}", "ext": "${ip "ext"}"}

      def soa(machine, address, zone):
          out = machine.succeed(f"kdig @{address} +norec +short SOA {zone}").split()
          return out[2] if len(out) > 2 else None

      def serving(zone):
          return [n for n in servers if n != "ext" or zone != acme]

      def in_sync(zone, signer_machine, signer_address):
          want = soa(signer_machine, signer_address, zone)
          for n in serving(zone):
              client.wait_until_succeeds(
                  f"[ \"$(kdig @{servers[n]} +norec +short SOA {zone} | cut -d' ' -f3)\" = {want} ]", timeout=60
              )
          return want

      with subtest("The secondaries take every zone from the signer"):
          for zone in top + [acme]:
              signer.wait_until_succeeds(f"kdig @${ip "signer"} +short SOA {zone} | grep -q .")
              in_sync(zone, signer, "${ip "signer"}")

      with subtest("The signer is hidden: only its peers reach it"):
          # The client may send ACME updates from its IPv4 address; its IPv6 address is nobody the signer knows.
          client.fail("kdig @${ip6 "signer"} +tcp +timeout=2 +retry=0 SOA one.test | grep -q 'status: NOERROR'")
          client.succeed("kdig @${ip6 "ns1"} +tcp +timeout=2 +retry=0 SOA one.test | grep -q 'status: NOERROR'")
          ns1.succeed("kdig @${ip6 "signer"} +norec SOA one.test | grep -q 'status: NOERROR'")

      ds = {}
      for zone in top + [acme]:
          ds[zone] = signer.succeed(
              f"keymgr {zone} ds | awk '$5 == 2 {{ print $1, $2, $3, $4, $5, $6 }}'"
          ).strip()
      assert ds["example.test"] == "example.test. DS ${exampleDS}", ds

      def resolver(zone, address, anchor, port):
          # A validating resolver that trusts only this DS and asks only this server.
          client.succeed(
              f"mkdir -p /run/v && cat > /run/v/{port}.conf <<EOF\n"
              "server:\n"
              f"  interface: 127.0.0.1@{port}\n"
              "  username: \"\"\n  chroot: \"\"\n  directory: /run/v\n"
              f"  pidfile: /run/v/{port}.pid\n"
              "  local-zone: \"test.\" nodefault\n"
              f"  trust-anchor: \"{anchor}\"\n"
              f"stub-zone:\n  name: {zone}\n  stub-addr: {address}\n"
              "EOF\n"
              f"unbound -c /run/v/{port}.conf"
          )
          return f"kdig @127.0.0.1 -p {port} +dnssec"

      def validates(zone, address, port):
          ask = resolver(zone, address, ds[zone], port)
          client.wait_until_succeeds(f"{ask} SOA {zone} | grep -q 'Flags: qr rd ra ad'")
          out = client.succeed(f"{ask} nothing.{zone}")
          assert "status: NXDOMAIN" in out and "Flags: qr rd ra ad" in out, out
          client.succeed(f"kill $(cat /run/v/{port}.pid)")

      with subtest("Every nameserver answers with signatures that validate"):
          port = 5300
          for zone in top + [acme]:
              for n in serving(zone):
                  port += 1
                  validates(zone, servers[n], port)
          # A trust anchor that matches no key fails, so the passes above mean something.
          wrong = ds["one.test"][:-4] + ("0000" if not ds["one.test"].endswith("0000") else "1111")
          ask = resolver("one.test", servers["ns1"], wrong, 5399)
          client.wait_until_succeeds(f"{ask} SOA one.test | grep -q 'status: SERVFAIL'")

      with subtest("The zones carry what the settings say"):
          q = "kdig @${ip "ns1"} +short"
          assert client.succeed(f"{q} MX one.test").strip() == "0 .", "null MX"
          assert client.succeed(f"{q} TXT one.test").strip() == '"v=spf1 -all"'
          assert "p=reject; sp=reject" in client.succeed(f"{q} TXT _dmarc.one.test")
          assert client.succeed(f"{q} MX idm.one.test").strip() == "0 ."
          caa = client.succeed(f"{q} CAA one.test")
          assert '0 issue "letsencrypt.org"' in caa and '0 issuewild ";"' in caa, caa
          assert client.succeed(f"{q} MX example.test").strip() == "10 mail.example.test."
          target = client.succeed(f"{q} CNAME _acme-challenge.idm.one.test").strip()
          assert re.fullmatch(r"_acme-challenge\.[0-9a-f]{16}\.acme\.example\.test\.", target), target
          ns = sorted(client.succeed(f"{q} NS one.test").split())
          assert ns == ["ns1.example.test.", "ns2.example.test.", "ns3.ext.test."], ns
          assert sorted(client.succeed(f"{q} NS {acme}").split()) == ["ns1.example.test.", "ns2.example.test."]
          # The provider's secondary only refers to our own servers for the ACME zone.
          assert client.succeed(f"kdig @${ip "ext"} +norec +short SOA {acme}").strip() == "", "ext must not serve the ACME zone"

      key = signer.succeed("sed -n 's/^ *secret: *//p' /var/lib/knot/acme-update.conf").strip()

      def update(server, lines, secret=None, name="acme-update", zone=acme, signed=True):
          # The signer's key by default, as cert-manager holds it.
          secret = key if secret is None else secret
          tsig = f"key hmac-sha256:{name} {secret}\n" if signed else ""
          return client.execute(
              f"printf 'server {server}\\nzone {zone}.\\norigin {zone}.\\n{tsig}{lines}send\\nanswer\\n' | knsupdate -t 5 -r 0 2>&1"
          )[1]

      def accepted(out):
          return "status: NOERROR" in out

      label = target.split(".")[1]

      with subtest("The ACME zone takes TXT records at _acme-challenge names with its key, and nothing else"):
          out = update("${ip "signer"}", f"add _acme-challenge.{label} 60 TXT token1\\n")
          assert accepted(out), out
          serial = in_sync(acme, signer, "${ip "signer"}")
          for n in serving(acme):
              client.succeed(f"kdig @{servers[n]} +dnssec TXT {target} | grep -q RRSIG")
              assert client.succeed(f"kdig @{servers[n]} +short TXT {target}").strip() == '"token1"'
          refused = {
              "another type at a challenge name": f"add _acme-challenge.{label} 60 A 192.0.2.1\\n",
              "a name without the prefix": f"add {label} 60 TXT x\\n",
              "the apex": "add @ 60 TXT x\\n",
              "a deeper name": f"add _acme-challenge.a.{label} 60 TXT x\\n",
              "the NS set": "add @ 60 NS ns.evil.test.\\n",
              "everything at a name": f"del _acme-challenge.{label}\\n",
              "TXT next to a forbidden record": "add _acme-challenge.b 60 TXT x\\nadd _acme-challenge.b 60 AAAA ::1\\n",
          }
          for what, lines in refused.items():
              out = update("${ip "signer"}", lines)
              assert not accepted(out), f"{what}: {out}"
          assert not accepted(update("${ip "signer"}", f"add _acme-challenge.{label} 60 TXT x\\n", signed=False))
          assert not accepted(update("${ip "signer"}", f"add _acme-challenge.{label} 60 TXT x\\n", secret="${transferKey.secret}", name="transfer"))
          assert not accepted(update("${ip "signer"}", "add _acme-challenge.idm 60 TXT x\\n", zone="one.test"))
          assert not accepted(update("${ip "ns1"}", f"add _acme-challenge.{label} 60 TXT x\\n"))
          assert soa(signer, "${ip "signer"}", acme) == serial, "a refused update changed the zone"
          # The records come only from updates, and a restart keeps them.
          signer.succeed("systemctl restart knot")
          signer.wait_until_succeeds(f"kdig @${ip "signer"} +short TXT {target} | grep -q token1")
          out = update("${ip "signer"}", f"del _acme-challenge.{label} TXT\\n")
          assert accepted(out), out

      with subtest("Restarting its unit replaces the ACME zone's key"):
          old = key
          signer.succeed("systemctl restart knot-acme-key")
          signer.wait_for_unit("knot.service")
          key = signer.succeed("sed -n 's/^ *secret: *//p' /var/lib/knot/acme-update.conf").strip()
          assert key != old
          assert not accepted(update("${ip "signer"}", f"add _acme-challenge.{label} 60 TXT x\\n", secret=old))
          assert accepted(update("${ip "signer"}", f"add _acme-challenge.{label} 60 TXT x\\n"))
          assert accepted(update("${ip "signer"}", f"del _acme-challenge.{label} TXT\\n"))

      with subtest("A changed zone reaches every nameserver by NOTIFY and IXFR"):
          signer.succeed("/run/booted-system/specialisation/changed/bin/switch-to-configuration test")
          for n in serving("one.test"):
              client.wait_until_succeeds(f"kdig @{servers[n]} +short A www.one.test | grep -q 192.0.2.80", timeout=60)
          ns1.succeed("journalctl -u knot | grep -q 'one.test.\\] IXFR, incoming'")

      def check(ok, contains=None, everywhere=False):
          ns1.succeed("systemctl start dns-check")
          results = {}
          for zone in top + [acme]:
              key = "dns_" + zone.replace(".", "-")
              r = ns1.succeed(f"curl -fsS http://127.0.0.1:8080/api/v1/endpoints/{key}/statuses | jq -c '.results[-1]'")
              results[zone] = r
          bad = {z: r for z, r in results.items() if '"success":false' in r}
          if ok:
              assert not bad, bad
          elif everywhere:
              assert len(bad) == len(results) and all(contains in r for r in bad.values()), results
          else:
              assert bad and any(contains in r for r in bad.values()), results

      with subtest("The watcher's check runs on a timer, passes, and catches a lagging nameserver, a wrong DS, old signatures and a copy it can't read"):
          ns1.wait_for_unit("gatus.service")
          ns1.wait_until_succeeds("curl -fsS http://127.0.0.1:8080/health")
          # From here on the test runs the check itself.
          ns1.succeed("systemctl is-active dns-check.timer && systemctl stop dns-check.timer")
          ns1.wait_until_succeeds("systemctl show -p ActiveState --value dns-check.service | grep -qx -e inactive -e failed")
          check(True)
          ns2.succeed(f"knotc zone-freeze {acme}")
          assert accepted(update("${ip "signer"}", f"add _acme-challenge.{label} 60 TXT token2\\n"))
          check(False, "serials differ")
          ns2.succeed(f"knotc zone-thaw {acme}")
          in_sync(acme, signer, "${ip "signer"}")
          client.succeed("knotc zone-begin test && knotc zone-set test one 60 DS 12345 13 2 " + "00" * 32 + " && knotc zone-commit test")
          check(False, "publishes DS")
          client.succeed("knotc zone-begin test && knotc zone-unset test one DS && knotc zone-commit test")
          check(True)
          ns1.succeed("date -s @$(( $(date +%s) + 20 * 86400 ))")
          check(False, "signature expires")
          ns1.succeed("date -s @$(( $(date +%s) - 20 * 86400 ))")
          # Every zone still gets its report.
          ns1.succeed("systemctl stop knot")
          check(False, "can't transfer the zone from this server", everywhere=True)
          ns1.succeed("systemctl start knot")
          for zone in top + [acme]:
              in_sync(zone, signer, "${ip "signer"}")

      with subtest("ns2 takes over signing from the key backup, with the same keys"):
          signer.succeed("systemctl start knot-backup")
          backup = signer.succeed("ls -1t /var/lib/knot-backup/keys-*.tar.age | head -n 1").strip()
          data = signer.succeed(f"base64 -w0 {backup}")
          ns2.succeed(f"echo {data} | base64 -d > /root/keys.tar.age")
          ns2.succeed("install -m 600 ${keys.snakeOilEd25519PrivateKey} /root/id")
          restored = ns2.succeed("age -d -i /root/id /root/keys.tar.age | suveraen-dns-restore")
          for zone in top + [acme]:
              assert ds[zone].split(" DS ")[1] in restored, (zone, restored)
          signer.succeed("systemctl stop knot")
          before = {zone: soa(client, "${ip "ns1"}", zone) for zone in top}
          ns2.succeed("/run/booted-system/specialisation/promoted/bin/switch-to-configuration test")
          ns1.succeed("/run/booted-system/specialisation/promoted/bin/switch-to-configuration test")
          ns2.wait_for_unit("knot.service")
          key = ns2.succeed("sed -n 's/^ *secret: *//p' /var/lib/knot/acme-update.conf").strip()
          assert accepted(update("${ip "ns2"}", f"add _acme-challenge.{label} 60 TXT token3\\n"))
          ns2.succeed("knotc zone-sign one.test")
          for zone in top + [acme]:
              in_sync(zone, ns2, "${ip "ns2"}")
          for zone in top:
              assert int(soa(client, "${ip "ns1"}", zone)) >= int(before[zone]), zone
          client.succeed(f"kdig @${ip "ns1"} +short TXT {target} | grep -q token3")
          port = 5400
          for zone in top + [acme]:
              for n in serving(zone):
                  port += 1
                  validates(zone, servers[n], port)

      with subtest("A signer that lost its keys refuses to start, and gets them back from the backup while knot is down"):
          ns2.succeed(f"suveraen-dns-keys-match one.test '{ds['one.test'].split(' DS ')[1]}'")
          ns2.fail("suveraen-dns-keys-match one.test '12345 13 2 " + "00" * 32 + "'")
          ns2.succeed("systemctl stop knot && rm -rf /var/lib/knot/keys")
          ns2.fail("systemctl start knot")
          ns2.succeed("journalctl -u knot | grep -q 'No key for example.test matches its published DS'")
          restored = ns2.succeed("age -d -i /root/id /root/keys.tar.age | suveraen-dns-restore")
          for zone in top + [acme]:
              assert ds[zone].split(" DS ")[1] in restored, (zone, restored)
          ns2.wait_for_unit("knot.service")
          port = 5500
          for zone in top + [acme]:
              for n in serving(zone):
                  port += 1
                  validates(zone, servers[n], port)
    '';
}
