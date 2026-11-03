# Each setting the rules hold, but the DNS domain, the other way.
.cluster.mesh.tenants[0].mesh.settings += {userApproval: false, jwtGroups: true, groupsPropagation: false,
  metricsPush: true, autoUpdate: "latest", loginExpirySeconds: 2592000, ipv6Groups: ["g-all"]}
