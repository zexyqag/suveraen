# Who can reach what changed: a new device, a share widened, a policy swapped for another, the camera's address, a
# person waiting for approval again and a new key.
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
