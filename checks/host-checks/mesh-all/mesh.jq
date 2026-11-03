# A policy from All to All, both ways.
.cluster.mesh.tenants[0].mesh.policies += [
  {id: "pol-all", enabled: true, postureChecks: ["pc-floor"], rules: [
    {id: "pol-all", enabled: true, action: "accept", sources: ["g-all"], destinations: ["g-all"],
     sourceResource: {ID: "", Type: ""}, destinationResource: {ID: "", Type: ""}, bidirectional: true, protocol: "all",
     ports: [], portRanges: [], authorizedGroups: {}, authorizedUser: ""}]}]
