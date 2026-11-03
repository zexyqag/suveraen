# An exit and a change of who can reach what at once: one alert for both.
.cluster.mesh.tenants[0].mesh |= (
  .routes = ["route-legacy"]
  | .networks[0].resources += [
      {id: "res-any", type: "subnet", enabled: true, digest: "91f8675bc4a9dc8c9d4877e798831376", family: 4,
       maskLength: 0, private: false},
      {id: "res-v6", type: "subnet", enabled: true, digest: "f95625f6ae9c7ce8286ed1b211206764", family: 6,
       maskLength: 0, private: false},
      {id: "res-name", type: "domain", enabled: true, digest: "891835e479b1600312c720357a51a543", family: null,
       maskLength: null, private: false},
      {id: "res-wide", type: "subnet", enabled: false, digest: "9286d40eec6e1aebe1781917a8ac70c8", family: 4,
       maskLength: 8, private: true}]
  | .networks[0].routers += [{id: "router-group", peer: null, peerGroups: ["g-home1"]}]
  | .counts.agentNetwork = 2)
|
.cluster.mesh.tenants[0].mesh |= (
  (.groups[] | select(.id == "g-own2" or .id == "g-all") | .peers) += ["peer-tablet"]
  | .peers += [{id: "peer-tablet", user: "c2f19b7d-5e83-4a0c-8d6f-3b1e7a9c5f03", version: "0.82.0",
      loginExpiry: true, embeddedProxy: false}]
  | (.policies[] | select(.id == "pol-share") | .rules[0].ports) = ["8080", "8081"]
  | .policies |= map(select(.id != "pol-box"))
  | .policies += [{id: "pol-share-box", enabled: true, postureChecks: ["pc-floor"], rules: [
      {id: "pol-share-box", enabled: true, action: "accept", sources: ["g-own2"], destinations: [],
       sourceResource: {ID: "", Type: ""}, destinationResource: {ID: "peer-box", Type: "peer"}, bidirectional: false,
       protocol: "tcp", ports: ["3389"], portRanges: [], authorizedGroups: {}, authorizedUser: ""}]}]
  | .networks[0].resources[0].digest = "0e7b2c0e3d44a7f1b9a8c6d5e4f3a2b1"
  | .users[2].pending = true
  | .setupKeys += [{id: "key-box2", type: "one-off", revoked: false, usageLimit: 1, autoGroups: ["g-home2"],
      validSeconds: 86399.999994}])
