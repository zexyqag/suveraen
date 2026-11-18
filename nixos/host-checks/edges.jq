# Each Gateway of the gateway's, where this server checks the cluster: whether each of its HTTPS and TLS listeners
# answered this server's request for its host at each of the server's addresses, through the gateway's own Service, with
# a certificate valid for the host and a status below 500. By Gateway, which names no host. An edge whose certificate
# isn't valid yet, or any more, stands as it was, as the certificate's own finding tells why.
include "rows";

def failure($e):
  if . == null then "no answer within \($e.cap)s"
  elif .exit == 0 then "HTTP \(.code)"
  else
    {"7": "no connection", "28": "no answer within \($e.maxTime)s", "35": "TLS handshake failed", "52": "empty reply",
     "56": "connection broken", "60": "certificate not valid for its host"}["\(.exit)"] // "curl exit \(.exit)"
  end;

# The certificates a listener serves: those making the Secrets it names, or for one that passes TLS through to its app,
# those for its host.
def served($l; $ns; $certificates):
  if ($l.tls.certificateRefs // []) != [] then
    [$l.tls.certificateRefs[] as $r
      | $certificates[] | select(.spec.secretName == $r.name and .metadata.namespace == ($r.namespace // $ns))]
  else [$certificates[] | select(any(.spec.dnsNames[]?; . == $l.hostname))]
  end;

def valid($now):
  (.status.notBefore // null | stamp) as $from
  | (.status.notAfter // null | stamp) as $to
  | $from != null and $to != null and $from <= $now and $now < $to;

def check($c):
  if $c.scope == "evaluated" then
    $c.spec.edges as $e
    | ($c.cluster.certificates.items // []) as $certificates
    | ($c.edges // []) as $probes
    | ($c.cluster.gateways.items // []
        | .[]
        | .metadata.name as $gateway
        | .metadata.namespace as $ns
        | [.spec.listeners[]? | select((.protocol == "HTTPS" or .protocol == "TLS") and .hostname != null)] as $listeners
        | select($listeners != [])
        | "edge \($gateway)" as $key
        | [$listeners[] as $l
            | $e.addresses[] as $a
            | first($probes[] | select(.gateway == $gateway and .listener == $l.name and .address == $a)) // null
            | select(. == null or .exit != 0 or .code >= 500)
            | "\($l.name) over IPv\(if $a | contains(":") then 6 else 4 end): \(failure($e))"] as $failed
        | [$listeners[] as $l
            | served($l; $ns; $certificates)[]
            | select(valid($c.now) | not)
            | "\(.metadata.namespace)/\(.metadata.name)"]
          as $invalid
        | if $failed == [] then finding("cluster"; $key; false; 4; "edge unanswered"; "answered"; "edges answering again")
          else
            ($c.state.since[$key] // $c.now) as $at
            | (if $invalid != [] then
                 unknown("cluster"; $key; "edge unanswered";
                   "held while certificate \($invalid | unique | join(", ")) isn't valid: \($failed | join("; "))";
                   "edges answering again")
               else
                 finding("cluster"; $key; $c.now - $at > $e.unansweredAfter; 4; "edge unanswered";
                   "unanswered since \($at | since($c.now)), limit \($e.unansweredAfter | span): \($failed | join("; "))";
                   "edges answering again")
               end),
              first_seen($key; $at)
          end),
      complete("edge ")
  elif $c.scope == "unreadable" then seen_before($c; "edge ")
  else empty
  end;
