# Ceph's health as Rook last reported it, where this server checks the cluster. Rook lists muted checks without saying
# so; Ceph's own health leaves them out.
include "rows";

def check($c):
  select($c.scope == "evaluated" and $c.cluster.cephcluster != null)
  | $c.cluster.cephcluster as $cluster
  | ($cluster.status.ceph // {}) as $s
  | ($s.health // null) as $health
  | (($s.lastChecked // null | stamp) // ($cluster.metadata.creationTimestamp | time)) as $checked
  | ($cluster.spec.healthCheck.muteHealthWarning // {} | with_entries(select(.value.policy == "mute")) | keys) as $muted
  | finding("cluster"; "Ceph status"; $c.now - $checked > $c.spec.cephStaleAfter; 4; "Ceph status not updated";
      "\($health // "no health yet"), checked \($checked | since($c.now)), limit \($c.spec.cephStaleAfter | span)";
      "Ceph status updated again"),
    (select($health != null and $health != "HEALTH_OK")
      | [$s.details // {} | to_entries[] | select(.key | IN($muted[]) | not)] as $found
      | if $found == [] then
          finding("cluster"; "Ceph \($health)"; true; (if $health == "HEALTH_ERR" then 5 else 4 end); "Ceph \($health)";
            "nothing but muted checks: \($s.details // {} | keys | join(", "))"; "Ceph healthy again")
        else
          # Each check by its own severity, so one that breaks leaves the others as they were.
          $found[]
          | .value.severity as $severity
          | finding("cluster"; "Ceph \(.key)"; true;
              (if $severity == "HEALTH_ERR" or (.key | IN("POOL_FULL", "OSD_FULL")) then 5 else 4 end);
              "Ceph \($severity): \(.key)"; "\(.value.message // .value.severity); ceph health detail says more";
              "Ceph healthy again")
        end),
    # Each check Ceph no longer raises has cleared.
    complete("Ceph ");
