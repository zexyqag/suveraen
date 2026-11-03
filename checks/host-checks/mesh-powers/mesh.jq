# A process check beside the version's, a job, DNS of the mesh's own, and SSH.
.cluster.mesh.tenants[0].mesh |= (
  .postureChecks += [{id: "pc-process", checks: {ProcessCheck: {Processes: [{LinuxPath: "/x"}]},
    NBVersionCheck: {MinVersion: "0.78.0"}}}]
  | .counts += {jobs: 1, nameserverGroups: 1, zones: 1, records: 3}
  | .policies += [{id: "pol-ssh", enabled: true, postureChecks: ["pc-floor"], rules: [
      {id: "pol-ssh", enabled: true, action: "accept", sources: ["g-own1"], destinations: ["g-own1"],
       sourceResource: {ID: "", Type: ""}, destinationResource: {ID: "", Type: ""}, bidirectional: false,
       protocol: "netbird-ssh", ports: [], portRanges: [], authorizedGroups: {"g-own1": ["root"]}, authorizedUser: ""}]}])
