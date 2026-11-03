# A legacy route, resources beyond a home's private range, a router by group and rows of the agent network.
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
