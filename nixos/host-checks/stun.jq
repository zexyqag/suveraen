# Whether each of this server's addresses answered a STUN binding request, where it answers them.
include "rows";

def check($c):
  $c.spec.stun // empty
  | .port as $port
  | .addresses[]
  | ($c.stun[.] // {answered: false, why: "not probed"}) as $probe
  | finding("host"; "STUN \(.)"; $probe.answered | not; 4; "STUN unanswered";
      if $probe.answered then "answered on UDP \($port)" else "no answer on UDP \($port): \($probe.why)" end;
      "STUN answered again");
