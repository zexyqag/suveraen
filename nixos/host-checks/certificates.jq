# Each of cert-manager's certificates, where this server checks the cluster: whether cert-manager issued it, and
# renewed it in time by the times it records, which it reaches long before the certificate runs out; at top priority
# once less than a share of its lifetime is left, as lifetimes keep shrinking.
include "rows";

def check($c):
  select($c.scope == "evaluated")
  | $c.spec.certificates as $s
  | ($c.cluster.certificates.items // []
      | .[]
      | "certificate \(.metadata.namespace)/\(.metadata.name)" as $key
      | (.status.notBefore // null | stamp) as $issued
      | (.status.notAfter // null | stamp) as $expires
      # One whose renewal cert-manager didn't schedule is due from when it was issued.
      | ((.status.renewalTime // null | stamp) // $issued) as $renewal
      | if $issued == null or $expires == null then
          (.metadata.creationTimestamp | time) as $made
          | finding("cluster"; $key; $c.now - $made > $s.issueGrace; 4; "certificate not issued";
              "not issued since \($made | since($c.now)), limit \($s.issueGrace | span)"; "certificates issued")
        else
          ($expires - $c.now) as $left
          | finding("cluster"; $key; $c.now - $renewal > $s.renewalGrace;
              (if $left * 100 < ($expires - $issued) * $s.urgentShare then 5 else 4 end);
              "certificate renewal late";
              if $c.now < $renewal then "renews \($renewal | todate), expires \($expires | todate)"
              else
                "renewal due \($renewal | since($c.now)), grace \($s.renewalGrace | span); expires \($expires | todate)"
              end;
              "certificates renewed")
        end),
    complete("certificate ");
