# A subnet alice's box routes, in bob's home group, which a rule from bob's own group reaches on a port, one way.
.cluster.mesh.tenants[0].mesh |= (
  .networks[0].resources += [{id: "res-lan", type: "subnet", enabled: true,
    digest: "342f6e47a0d7dd4811523f9ae0a0d6e4", family: 4, maskLength: 24, private: true}]
  | (.groups[] | select(.id == "g-home2") | .resources) = [{ID: "res-lan", Type: "subnet"}]
  | .policies += [{id: "pol-home2", enabled: true, postureChecks: ["pc-floor"], rules: [
      {id: "pol-home2", enabled: true, action: "accept", sources: ["g-own2"], destinations: ["g-home2"],
       sourceResource: {ID: "", Type: ""}, destinationResource: {ID: "", Type: ""}, bidirectional: false,
       protocol: "tcp", ports: ["80"], portRanges: [], authorizedGroups: {}, authorizedUser: ""}]}])
