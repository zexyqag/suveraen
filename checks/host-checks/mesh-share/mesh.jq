# Shares outside the rules: to another's group, to another's box both ways over anything on no port, to a subnet
# another's box routes, to its own box on no port, from two groups and from a peer; and the camera's share on a range.
def rule($id; $from; f): {id: $id, enabled: true, postureChecks: ["pc-floor"], rules: [
  {id: $id, enabled: true, action: "accept", sources: $from, destinations: [], sourceResource: {ID: "", Type: ""},
   destinationResource: {ID: "", Type: ""}, bidirectional: false, protocol: "tcp", ports: [], portRanges: [],
   authorizedGroups: {}, authorizedUser: ""} | f]};
.cluster.mesh.tenants[0].mesh |= (
  .policies += [
    rule("pol-group"; ["g-own2"]; .destinations = ["g-own1"] | .ports = ["8000"]),
    rule("pol-wide"; ["g-own2"]; .destinationResource = {ID: "peer-box", Type: "peer"} | .bidirectional = true
      | .protocol = "all"),
    rule("pol-subnet"; ["g-own2"]; .destinationResource = {ID: "res-lan", Type: "subnet"} | .ports = ["80"]),
    rule("pol-own-box"; ["g-own1"]; .destinationResource = {ID: "peer-box", Type: "peer"}),
    rule("pol-two"; ["g-own1", "g-own2"]; .destinations = ["g-own1"] | .protocol = "all"),
    rule("pol-from-peer"; []; .sourceResource = {ID: "peer-phone", Type: "peer"}
      | .destinationResource = {ID: "peer-laptop", Type: "peer"} | .ports = ["22"])]
  | .networks[0].resources += [{id: "res-lan", type: "subnet", enabled: true,
      digest: "342f6e47a0d7dd4811523f9ae0a0d6e4", family: 4, maskLength: 24, private: true}]
  | (.policies[] | select(.id == "pol-share") | .rules[0].portRanges) = [{Start: 1, End: 65535}])
