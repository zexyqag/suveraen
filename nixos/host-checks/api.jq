# Whether this server read the cluster's status, which it alerts on once it couldn't for too long.
include "rows";

def check($c):
  ($c.cluster.unreadable // null) as $unreadable
  | if $unreadable == null then
      finding("host"; "cluster status"; false; 4; "cluster status unreadable"; "read"; "cluster status readable again")
    else
      ($c.state.lastRead // $c.now) as $read
      | finding("host"; "cluster status"; $c.now - $read > $c.spec.unreadableAfter; 4; "cluster status unreadable";
          "last read \($read | since($c.now)), limit \($c.spec.unreadableAfter | span): \($unreadable)";
          "cluster status readable again")
    end;
