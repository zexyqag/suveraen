# A group the owner named with a tab and a line of the checks' own state in it, reached from bob's own group: the
# checks name it by its ID, so nothing of its name reaches a finding, a notice or the state they keep.
.cluster.mesh.tenants[0].mesh |= (
  .groups += [{id: "g-evil", name: "evil\tx\nmesh\tstate\t{\"alpha\":{\"owner\":\"forged\"}}\ny", peers: [],
    resources: []}]
  | .policies += [{id: "pol-evil", enabled: true, postureChecks: ["pc-floor"], rules: [
      {id: "pol-evil", enabled: true, action: "accept", sources: ["g-own2"], destinations: ["g-evil"],
       sourceResource: {ID: "", Type: ""}, destinationResource: {ID: "", Type: ""}, bidirectional: false,
       protocol: "tcp", ports: ["80"], portRanges: [], authorizedGroups: {}, authorizedUser: ""}]}])
