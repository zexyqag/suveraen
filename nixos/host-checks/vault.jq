# Each tenant's vault as suveraen-vault check told of it (vault.nix), where this server checks the cluster:
# every account the vault still lets in, enabled or with a device's session, whose person Kanidm let go or that links to
# none of its people, as Kanidm can end none of the vault's sessions; and whether it told of every tenant, which the
# report keeps the time of.
include "rows";

# The title each part alerts under, and the one once it is ok again.
def titles: {leaver: ["vault leaver still in", "vault leavers out"], check: ["vault unchecked", "vault checked again"]};

def part($key; $part; $late; $detail): titles[$part] as [$t, $c] | finding("cluster"; $key; $late; 4; $t; $detail; $c);
def untold($key; $part; $detail): titles[$part] as [$t, $c] | unknown("cluster"; $key; $t; $detail; $c);

# Accounts by their IDs and people by their Kanidm IDs, never by name or mail.
def vault:
  .tenant as $t
  | "\($t)-vaultwarden leaver" as $key
  | if .unchecked != null then untold($key; "leaver"; "unchecked: \(.unchecked)")
    else
      .people as $people
      | [.accounts[] | select(.enabled or .devices > 0)] as $open
      | [$open[] | .person // empty | select(($people[.] // "unknown") == "unknown")] as $unanswered
      | if $unanswered != [] then
          untold($key; "leaver"; "no answer from Kanidm for \($unanswered | unique | join(", "))")
        else
          [$open[] | select(.person == null or ($people[.person] | IN("expired", "gone")))
            | (.devices | many("device"; "devices")) as $devices
            | "account \(.id), "
              + (if .person == null then "linked to no person of the tenant's Kanidm"
                 else "of \(.person), \($people[.person]) at Kanidm" end)
              + (if .enabled and .devices > 0 then ", is still enabled, with \($devices)"
                 elif .enabled then ", is still enabled"
                 else ", is disabled but still with \($devices)" end)
              + (if .person == null then ": its link is under another issuer, or it has none"
                 else ": run suveraen-vault offboard \($t) \(.id)" end)] as $left
          | part($key; "leaver"; $left != [];
              if $left == [] then "every open account's person still in at Kanidm" else $left | join("; ") end)
        end
    end;

def check($c):
  $c.told.vault as $v
  | (($v.tenants? | type) == "array") as $told
  | [$v.tenants[]? | vault] as $rows
  | [$rows[] | select(.[2] == "unknown") | .[1]] as $parts
  | (if ($v | type) != "object" then "no answer from suveraen-vault check"
     elif $v.failed != null then "suveraen-vault check: \($v.failed)"
     elif $parts != [] then "nothing told of \($parts | join(", "))"
     else null
     end) as $why
  | ($c.state.since["vault check"] // $c.now) as $unchecked
  # A cluster without a vault has nothing to tell of.
  | select($why != null or $rows != [])
  | (select($c.scope == "evaluated")
      | $rows[],
        part("vault check"; "check"; $why != null and $c.now - $unchecked > $c.spec.unreadableAfter;
          if $why == null then "every tenant's vault checked"
          else "every tenant's vault unchecked since \($unchecked | since($c.now)), limit"
            + " \($c.spec.unreadableAfter | span): \($why)"
          end),
        # While suveraen-vault check tells nothing, the tenants' vaults stand as they were found last.
        (select($told | not) | hold(""))),
    (select($why != null) | first_seen("vault check"; $unchecked));
