# A personal access token, a reusable key without end, and a revoked one-off key valid a week.
.cluster.mesh.tenants[0].mesh |= (
  .pats = [{id: "pat-1", user: "5d0c7a3e-8f41-4b6a-9e2d-1a7c3b9f0e01"}]
  | .setupKeys += [
      {id: "key-reusable", type: "reusable", revoked: false, usageLimit: 0, autoGroups: ["g-home1"], validSeconds: null},
      {id: "key-week", type: "one-off", revoked: true, usageLimit: 1, autoGroups: ["g-home2"], validSeconds: 604800}])
