# Flux's Kustomizations, HelmReleases and sources, where this server checks the cluster: each that stays unready or
# suspended too long, and whether the release Flux applied last is the one this host's upgrade resolved last. Ready
# turns Unknown as Flux starts each retry, so how long one has been unready counts from when it was first found so. A
# condition's message can repeat what an object holds; only its reason is told.
include "rows";

def kinds:
  [["Kustomization", "kustomizations"], ["HelmRelease", "helmreleases"], ["GitRepository", "gitrepositories"],
   ["OCIRepository", "ocirepositories"]];

def listed($k):
  [kinds[] as [$kind, $list]
    | $k[$list].items // []
    | .[]
    | .metadata.namespace as $ns
    | (first(.status.conditions[]? | select(.type == "Ready")) // {}) as $ready
    | {kind: $kind, key: "Flux \($kind) \($ns)/\(.metadata.name)", name: .metadata.name, namespace: $ns,
       suspended: (.spec.suspend // false), ready: ($ready.status == "True"),
       reason: ($ready.reason // "no Ready condition"), applied: (.status.lastAppliedRevision // null),
       # An object depends on others of its kind.
       dependsOn: [.spec.dependsOn[]? | "Flux \($kind) \(.namespace // $ns)/\(.name)"]}];

def readiness($c; $all):
  $c.spec.flux as $f
  | ($c.state.since // {}) as $seen
  | [$all[] | select(.ready | not) | .key] as $unready
  | $all[]
  | . as $o
  | "\(.key) suspended" as $suspended
  | (select(.suspended)
      | ($seen[$suspended] // $c.now) as $at
      | finding("cluster"; $suspended; $c.now - $at > $f.suspendedAfter; 3; "Flux suspended";
          "suspended since \($at | since($c.now)), limit \($f.suspendedAfter | span)"; "Flux resumed"),
        first_seen($suspended; $at)),
    if .ready then finding("cluster"; .key; false; 4; "Flux not ready"; "ready"; "Flux ready again")
    # One Flux leaves alone isn't judged, nor one that waits for another not ready, which is judged in its place.
    elif .suspended or (.reason == "DependencyNotReady" and any(.dependsOn[]; IN($unready[]))) then
      unknown("cluster"; .key; "Flux not ready";
        if .suspended then "suspended, so not reconciled"
        else "waits for \([.dependsOn[] | select(IN($unready[]))] | join(", "))"
        end;
        "Flux ready again"),
      ($seen[.key] // empty | first_seen($o.key; .)),
      # Told, so the unknown above doesn't keep a suspension found before under its key.
      (select(.suspended | not)
        | finding("cluster"; $suspended; false; 3; "Flux suspended"; "not suspended"; "Flux resumed"))
    else
      ($seen[.key] // $c.now) as $at
      | finding("cluster"; .key; $c.now - $at > $f.notReadyAfter; 4; "Flux not ready";
          "\(.reason) since \($at | since($c.now)), limit \($f.notReadyAfter | span)"; "Flux ready again"),
        first_seen(.key; $at)
    end;

# The release the root Kustomization applied last against the one this host's upgrade resolved last, once it has: a
# Flux whose controllers stopped keeps saying it is ready. Flux may apply a newer release a day ahead of the host.
def release($c; $all):
  $c.revision // empty
  | . as $host
  | $c.spec.flux as $f
  | (first($all[] | select(.kind == "Kustomization" and .namespace == $f.root.namespace and .name == $f.root.name)
      | .applied) // "" | sub("^.*sha1:"; "")) as $flux
  | if $flux == $host then
      finding("cluster"; "Flux release"; false; 4; "Flux and the host on different releases"; "both on \($host[:12])";
        "Flux and the host on one release again")
    else
      ($c.state.since["Flux release"] // $c.now) as $at
      | finding("cluster"; "Flux release"; $c.now - $at > $f.behindAfter; 4; "Flux and the host on different releases";
          "Flux on \(if $flux == "" then "none" else $flux[:12] end), the host on \($host[:12]),"
          + " since \($at | since($c.now)), limit \($f.behindAfter | span)";
          "Flux and the host on one release again"),
        first_seen("Flux release"; $at)
    end;

def check($c):
  if $c.scope == "evaluated" then
    listed($c.cluster) as $all
    | readiness($c; $all), release($c; $all), complete("Flux ")
  elif $c.scope == "unreadable" then seen_before($c; "Flux ")
  else empty
  end;
