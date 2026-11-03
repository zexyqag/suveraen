# A policy from a home's group, the box's policy both ways, a key into a person's own group, and a person who joins
# their home's group too.
.cluster.mesh.tenants[0].mesh |= (
  .policies += [{id: "pol-from-home", enabled: true, postureChecks: ["pc-floor"], rules: [
    {id: "pol-from-home", enabled: true, action: "accept", sources: ["g-home1"], destinations: ["g-own1"],
     sourceResource: {ID: "", Type: ""}, destinationResource: {ID: "", Type: ""}, bidirectional: false,
     protocol: "tcp", ports: ["22"], portRanges: [], authorizedGroups: {}, authorizedUser: ""}]}]
  | (.policies[] | select(.id == "pol-box") | .rules[0].bidirectional) = true
  | .setupKeys += [{id: "key-own", type: "one-off", revoked: false, usageLimit: 1, autoGroups: ["g-own1"],
      validSeconds: 3600}]
  | .users[2].autoGroups = ["g-own2", "g-home2"])
